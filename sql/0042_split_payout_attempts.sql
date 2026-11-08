-- Migration 0042: move payout attempts into their own table.
--
-- Until now `payout` kept a bare `attempts` counter, so support could see
-- that a payout took four tries but not why. This migration:
--
--   1. creates `payout_attempt`, one row per try, with the rail's answer;
--   2. backfills one synthetic row per existing attempt so history adds up;
--   3. replaces `payout.attempts` with a view-derived count;
--   4. adds a function the dispatcher calls instead of updating rows by hand.
--
-- Safe to run online: the backfill copies in chunks and the only exclusive
-- locks are the brief DROP VIEW and ALTER TABLE ... DROP COLUMN.
-- Rollback is at the bottom, commented out.

SET lock_timeout = '3s';
SET statement_timeout = '15min';

-- ------------------------------------------------------------- 1. table --

CREATE TYPE settlement.attempt_result AS ENUM ('sent', 'transient', 'rejected', 'timeout');

CREATE TABLE settlement.payout_attempt (
    batch_id     settlement.public_id       NOT NULL REFERENCES settlement.payout ON DELETE CASCADE,
    attempt_no   smallint                   NOT NULL CHECK (attempt_no > 0),
    started_at   timestamptz                NOT NULL,
    finished_at  timestamptz,
    result       settlement.attempt_result,
    detail       text,
    synthetic    boolean                    NOT NULL DEFAULT false,
    PRIMARY KEY (batch_id, attempt_no),
    CONSTRAINT finished_has_result CHECK ((finished_at IS NULL) = (result IS NULL)),
    CONSTRAINT finish_after_start  CHECK (finished_at IS NULL OR finished_at >= started_at)
);

COMMENT ON TABLE  settlement.payout_attempt IS 'One row per attempt to send a payout over its rail.';
COMMENT ON COLUMN settlement.payout_attempt.synthetic IS
    'True for rows backfilled by migration 0042 from the old counter: their timings are unknown.';

-- Exactly one successful attempt per payout, at most.
CREATE UNIQUE INDEX payout_attempt_one_success
    ON settlement.payout_attempt (batch_id)
    WHERE result = 'sent';

-- ---------------------------------------------------------- 2. backfill --

DO $$
DECLARE
    chunk   constant integer := 5000;
    copied  integer;
    total   integer := 0;
    last_id text    := '';
BEGIN
    LOOP
        WITH next_batches AS (
            SELECT batch_id, attempts, sent_at, rail_reference
            FROM settlement.payout
            WHERE batch_id > last_id AND attempts > 0
            ORDER BY batch_id
            LIMIT chunk
        ), inserted AS (
            INSERT INTO settlement.payout_attempt
                (batch_id, attempt_no, started_at, finished_at, result, detail, synthetic)
            SELECT nb.batch_id,
                   n,
                   coalesce(nb.sent_at, now()),
                   coalesce(nb.sent_at, now()),
                   CASE WHEN n = nb.attempts AND nb.sent_at IS NOT NULL
                        THEN 'sent'::settlement.attempt_result
                        ELSE 'transient'::settlement.attempt_result
                   END,
                   CASE WHEN n = nb.attempts THEN nb.rail_reference END,
                   true
            FROM next_batches nb
            CROSS JOIN LATERAL generate_series(1, nb.attempts) AS n
            ON CONFLICT DO NOTHING
        )
        -- Count what was read, not what was inserted: a re-run that inserts
        -- nothing (ON CONFLICT) must still walk forward. The INSERT runs
        -- whether or not the outer query reads it.
        SELECT count(*), max(nb.batch_id)
        INTO copied, last_id
        FROM next_batches nb;

        EXIT WHEN copied = 0 OR last_id IS NULL;
        total := total + copied;
        RAISE NOTICE 'backfilled % payouts (up to %)', total, last_id;
        COMMIT;
    END LOOP;
END;
$$;

-- Check the backfill before removing the source of truth.
DO $$
DECLARE
    mismatches integer;
BEGIN
    SELECT count(*) INTO mismatches
    FROM settlement.payout p
    LEFT JOIN (
        SELECT batch_id, count(*) AS n
        FROM settlement.payout_attempt
        GROUP BY batch_id
    ) a USING (batch_id)
    WHERE p.attempts <> coalesce(a.n, 0);

    IF mismatches > 0 THEN
        RAISE EXCEPTION 'backfill incomplete: % payouts disagree with their attempt rows', mismatches;
    END IF;
END;
$$;

-- --------------------------------------------- 3. replace the counter --

-- overdue_payouts reads p.attempts, so it goes first and returns below.
DROP VIEW settlement.overdue_payouts;
ALTER TABLE settlement.payout DROP COLUMN attempts;

CREATE OR REPLACE VIEW settlement.payout_status AS
SELECT p.batch_id,
       p.rail,
       p.net_minor,
       p.sent_at,
       count(a.*)                                        AS attempts,
       max(a.finished_at)                                AS last_attempt_at,
       (array_agg(a.result ORDER BY a.attempt_no DESC))[1] AS last_result,
       bool_or(a.synthetic)                              AS has_synthetic_history
FROM settlement.payout p
LEFT JOIN settlement.payout_attempt a USING (batch_id)
GROUP BY p.batch_id;

-- Rebuilt on the status view; attempts is now a bigint count.
CREATE VIEW settlement.overdue_payouts AS
SELECT t.batch_id, t.merchant_id, t.currency, t.net_minor, t.value_date,
       coalesce(s.attempts, 0) AS attempts, current_date - t.value_date AS days_late
FROM settlement.batch_totals t
LEFT JOIN settlement.payout_status s USING (batch_id)
WHERE t.state = 'sealed'
  AND t.net_minor > 0
  AND t.value_date < current_date - 2
  AND s.sent_at IS NULL;

-- ------------------------------------------------ 4. dispatcher API --

CREATE FUNCTION settlement.begin_attempt(p_batch settlement.public_id)
RETURNS smallint
LANGUAGE sql AS $$
    INSERT INTO settlement.payout_attempt (batch_id, attempt_no, started_at)
    SELECT p_batch, coalesce(max(attempt_no), 0) + 1, clock_timestamp()
    FROM settlement.payout_attempt
    WHERE batch_id = p_batch
    RETURNING attempt_no;
$$;

CREATE FUNCTION settlement.finish_attempt(
    p_batch      settlement.public_id,
    p_attempt    smallint,
    p_result     settlement.attempt_result,
    p_detail     text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE settlement.payout_attempt
       SET finished_at = clock_timestamp(),
           result      = p_result,
           detail      = p_detail
     WHERE batch_id = p_batch
       AND attempt_no = p_attempt
       AND finished_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'attempt % of % is unknown or already finished', p_attempt, p_batch;
    END IF;

    IF p_result = 'sent' THEN
        UPDATE settlement.payout
           SET sent_at = clock_timestamp(), rail_reference = p_detail
         WHERE batch_id = p_batch;
    END IF;
END;
$$;

GRANT SELECT ON settlement.payout_attempt, settlement.payout_status TO ledger_reader;
GRANT EXECUTE ON FUNCTION settlement.begin_attempt(settlement.public_id),
                          settlement.finish_attempt(settlement.public_id, smallint, settlement.attempt_result, text)
      TO ledger_dispatcher;

-- ------------------------------------------------------------ rollback --
--
-- ALTER TABLE settlement.payout ADD COLUMN attempts smallint NOT NULL DEFAULT 0;
-- UPDATE settlement.payout p SET attempts = s.attempts
--   FROM settlement.payout_status s WHERE s.batch_id = p.batch_id;
-- (restore overdue_payouts from settlement_schema.sql)
-- DROP FUNCTION settlement.finish_attempt, settlement.begin_attempt;
-- DROP VIEW settlement.payout_status;
-- DROP TABLE settlement.payout_attempt;
-- DROP TYPE settlement.attempt_result;
