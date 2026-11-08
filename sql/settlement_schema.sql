-- Meridian Payments: settlement ledger schema and reporting views.
-- PostgreSQL 16.
--
-- Money is stored as bigint minor units with an explicit currency column;
-- numeric is used only inside reports, never for balances. Every table that
-- the business reads from is append-only: corrections are new rows.

BEGIN;

CREATE SCHEMA IF NOT EXISTS settlement;
SET search_path = settlement, public;

-- ---------------------------------------------------------------- types --

CREATE TYPE entry_kind  AS ENUM ('capture', 'refund', 'chargeback', 'adjustment', 'fee');
CREATE TYPE batch_state AS ENUM ('open', 'sealed', 'paid', 'cancelled');

CREATE DOMAIN currency_code AS char(3)
    CHECK (VALUE ~ '^[A-Z]{3}$');

CREATE DOMAIN public_id AS text
    CHECK (VALUE ~ '^[a-z]{3}_[A-Za-z0-9]{4,24}$');

-- --------------------------------------------------------------- tables --

CREATE TABLE merchant (
    merchant_id     public_id      PRIMARY KEY,
    legal_name      text           NOT NULL CHECK (length(trim(legal_name)) > 0),
    country         char(2)        NOT NULL,
    payout_currency currency_code  NOT NULL,
    fee_bp          integer        NOT NULL DEFAULT 145 CHECK (fee_bp BETWEEN 0 AND 1000),
    onboarded_at    timestamptz    NOT NULL DEFAULT now(),
    offboarded_at   timestamptz,
    CONSTRAINT offboard_after_onboard CHECK (offboarded_at IS NULL OR offboarded_at > onboarded_at)
);

CREATE TABLE batch (
    batch_id     public_id      PRIMARY KEY,
    merchant_id  public_id      NOT NULL REFERENCES merchant ON DELETE RESTRICT,
    currency     currency_code  NOT NULL,
    state        batch_state    NOT NULL DEFAULT 'open',
    opened_at    timestamptz    NOT NULL DEFAULT now(),
    sealed_at    timestamptz,
    value_date   date,
    CONSTRAINT sealed_has_date CHECK (
        (state = 'open' AND sealed_at IS NULL AND value_date IS NULL)
        OR (state = 'cancelled')
        OR (state IN ('sealed', 'paid') AND sealed_at IS NOT NULL AND value_date IS NOT NULL)
    )
);

-- At most one open batch per merchant and currency at any time.
CREATE UNIQUE INDEX batch_one_open
    ON batch (merchant_id, currency)
    WHERE state = 'open';

CREATE TABLE ledger_entry (
    entry_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id      public_id      NOT NULL REFERENCES batch ON DELETE RESTRICT,
    reference     text           NOT NULL,
    kind          entry_kind     NOT NULL,
    amount_minor  bigint         NOT NULL CHECK (amount_minor <> 0),
    currency      currency_code  NOT NULL,
    booked_at     timestamptz    NOT NULL,
    recorded_at   timestamptz    NOT NULL DEFAULT clock_timestamp(),
    -- The provider's reference is the idempotency key: a webhook delivered
    -- twice must not become two entries.
    CONSTRAINT entry_reference_unique UNIQUE (batch_id, reference),
    -- Captures are positive; refunds, chargebacks and fees are negative.
    CONSTRAINT entry_sign CHECK (
        CASE kind
            WHEN 'capture'    THEN amount_minor > 0
            WHEN 'adjustment' THEN true
            ELSE amount_minor < 0
        END
    )
);

CREATE INDEX ledger_entry_batch_kind ON ledger_entry (batch_id, kind);
CREATE INDEX ledger_entry_booked     ON ledger_entry USING brin (booked_at);

CREATE TABLE payout (
    batch_id        public_id     PRIMARY KEY REFERENCES batch,
    net_minor       bigint        NOT NULL,
    rail            text          NOT NULL CHECK (rail IN ('sepa', 'faster-payments', 'bankgiro')),
    rail_reference  text,
    sent_at         timestamptz,
    attempts        smallint      NOT NULL DEFAULT 0 CHECK (attempts >= 0)
);

-- ------------------------------------------------------------- triggers --

-- An entry's currency must match its batch, and sealed batches are frozen.
CREATE FUNCTION ledger_entry_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    b settlement.batch%ROWTYPE;
BEGIN
    SELECT * INTO b FROM settlement.batch WHERE batch_id = NEW.batch_id FOR SHARE;
    IF b.state <> 'open' THEN
        RAISE EXCEPTION 'batch % is %, entries are frozen', b.batch_id, b.state
            USING ERRCODE = 'check_violation';
    END IF;
    IF b.currency <> NEW.currency THEN
        RAISE EXCEPTION 'entry % is in %, batch % is in %',
            NEW.reference, NEW.currency, b.batch_id, b.currency
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER ledger_entry_guard
    BEFORE INSERT ON ledger_entry
    FOR EACH ROW EXECUTE FUNCTION ledger_entry_guard();

CREATE FUNCTION forbid_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; record a correcting entry instead', TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER ledger_entry_append_only
    BEFORE UPDATE OR DELETE ON ledger_entry
    FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- ---------------------------------------------------------------- views --

-- One row per batch with gross, fees and net, computed from the entries.
CREATE VIEW batch_totals AS
SELECT
    b.batch_id,
    b.merchant_id,
    b.currency,
    b.state,
    b.value_date,
    count(*) FILTER (WHERE e.kind = 'capture')                         AS captures,
    coalesce(sum(e.amount_minor) FILTER (WHERE e.kind <> 'fee'), 0)    AS gross_minor,
    coalesce(-sum(e.amount_minor) FILTER (WHERE e.kind = 'fee'), 0)    AS fees_minor,
    coalesce(sum(e.amount_minor), 0)                                   AS net_minor
FROM batch b
LEFT JOIN ledger_entry e USING (batch_id)
GROUP BY b.batch_id;

-- Batches sealed more than two days ago that still have no successful payout.
CREATE VIEW overdue_payouts AS
SELECT t.batch_id, t.merchant_id, t.currency, t.net_minor, t.value_date,
       p.attempts, current_date - t.value_date AS days_late
FROM batch_totals t
LEFT JOIN payout p USING (batch_id)
WHERE t.state = 'sealed'
  AND t.net_minor > 0
  AND t.value_date < current_date - 2
  AND p.sent_at IS NULL;

COMMIT;

-- --------------------------------------------------------------- reports --

-- Weekly volume per merchant, with week-over-week change and the merchant's
-- rank inside its currency. Window functions over a grouped CTE.
WITH weekly AS (
    SELECT
        b.merchant_id,
        e.currency,
        date_trunc('week', e.booked_at)::date                  AS week,
        sum(e.amount_minor) FILTER (WHERE e.kind = 'capture')  AS captured_minor,
        count(*) FILTER (WHERE e.kind = 'chargeback')          AS chargebacks
    FROM settlement.ledger_entry e
    JOIN settlement.batch b USING (batch_id)
    WHERE e.booked_at >= date_trunc('week', now()) - interval '8 weeks'
    GROUP BY 1, 2, 3
)
SELECT
    merchant_id,
    currency,
    week,
    captured_minor / 100.0                                                   AS captured,
    round(100.0 * (captured_minor - lag(captured_minor) OVER w)
          / nullif(lag(captured_minor) OVER w, 0), 1)                        AS wow_change_pct,
    sum(captured_minor) OVER (PARTITION BY merchant_id, currency
                              ORDER BY week
                              ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) / 100.0 AS rolling_4w,
    rank() OVER (PARTITION BY currency, week ORDER BY captured_minor DESC)    AS rank_in_currency,
    chargebacks
FROM weekly
WINDOW w AS (PARTITION BY merchant_id, currency ORDER BY week)
ORDER BY currency, week DESC, rank_in_currency;

-- Chargeback ratio by merchant over the last 90 days, flagging any merchant
-- above 0.9 % with at least 100 captures (small samples are noise).
WITH last_90 AS (
    SELECT b.merchant_id,
           count(*) FILTER (WHERE e.kind = 'capture')    AS captures,
           count(*) FILTER (WHERE e.kind = 'chargeback') AS chargebacks
    FROM settlement.ledger_entry e
    JOIN settlement.batch b USING (batch_id)
    WHERE e.booked_at >= now() - interval '90 days'
    GROUP BY b.merchant_id
)
SELECT m.merchant_id,
       m.legal_name,
       l.captures,
       l.chargebacks,
       round(100.0 * l.chargebacks / l.captures, 2) AS ratio_pct,
       (l.captures >= 100 AND l.chargebacks::numeric / l.captures > 0.009) AS flagged
FROM last_90 l
JOIN settlement.merchant m USING (merchant_id)
WHERE l.captures > 0
ORDER BY flagged DESC, ratio_pct DESC;

-- Days between capture and payout: median and 95th percentile per rail.
SELECT p.rail,
       count(*)                                                        AS payouts,
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY days)              AS median_days,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY days)              AS p95_days
FROM (
    SELECT p.batch_id, p.rail,
           extract(epoch FROM p.sent_at - min(e.booked_at)) / 86400.0 AS days
    FROM settlement.payout p
    JOIN settlement.ledger_entry e USING (batch_id)
    WHERE p.sent_at IS NOT NULL
    GROUP BY p.batch_id, p.rail, p.sent_at
) AS p
GROUP BY p.rail
ORDER BY median_days;
