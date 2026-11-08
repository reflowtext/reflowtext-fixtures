<?php

declare(strict_types=1);

namespace Meridian\Settlement;

use DateTimeImmutable;
use DateTimeZone;
use InvalidArgumentException;
use LogicException;

/**
 * Settlement batching for Meridian Payments.
 *
 * A batch collects captured payments for one merchant and one currency,
 * nets out refunds and chargebacks, applies the merchant's fee schedule,
 * and produces a payout instruction. Money is always carried in minor
 * units (cents, pence, öre) as integers; floats never touch a balance.
 */

enum Currency: string
{
    case EUR = 'EUR';
    case GBP = 'GBP';
    case SEK = 'SEK';
    case JPY = 'JPY';

    /** Number of minor units in one major unit. */
    public function exponent(): int
    {
        return match ($this) {
            self::JPY => 0,
            default   => 2,
        };
    }

    public function format(int $minor): string
    {
        $exp   = $this->exponent();
        $sign  = $minor < 0 ? '-' : '';
        $abs   = abs($minor);
        $major = intdiv($abs, 10 ** $exp);
        $frac  = $exp > 0 ? '.' . str_pad((string) ($abs % 10 ** $exp), $exp, '0', STR_PAD_LEFT) : '';

        return sprintf('%s%s %s%s', $sign, $this->value, number_format($major, 0, '.', ','), $frac);
    }
}

enum EntryKind: string
{
    case Capture    = 'capture';
    case Refund     = 'refund';
    case Chargeback = 'chargeback';
    case Adjustment = 'adjustment';

    /** Whether the entry moves money toward the merchant (+1) or away (-1). */
    public function direction(): int
    {
        return match ($this) {
            self::Capture                  => 1,
            self::Refund, self::Chargeback => -1,
            self::Adjustment               => 1, // sign is carried by the amount itself
        };
    }
}

enum BatchState: string
{
    case Open      = 'open';
    case Sealed    = 'sealed';
    case Paid      = 'paid';
    case Cancelled = 'cancelled';

    public function canTransitionTo(self $next): bool
    {
        return match ($this) {
            self::Open      => in_array($next, [self::Sealed, self::Cancelled], true),
            self::Sealed    => in_array($next, [self::Paid, self::Cancelled], true),
            self::Paid,
            self::Cancelled => false,
        };
    }
}

final readonly class Money
{
    public function __construct(
        public int $minor,
        public Currency $currency,
    ) {}

    public static function zero(Currency $currency): self
    {
        return new self(0, $currency);
    }

    public function plus(self $other): self
    {
        $this->assertSameCurrency($other);
        return new self($this->minor + $other->minor, $this->currency);
    }

    public function minus(self $other): self
    {
        return $this->plus(new self(-$other->minor, $other->currency));
    }

    /**
     * Basis-point fee, rounded half away from zero. 1 bp = 0.01 %.
     */
    public function basisPoints(int $bp): self
    {
        $raw     = $this->minor * $bp;
        $rounded = intdiv($raw + ($raw >= 0 ? 5_000 : -5_000), 10_000);
        return new self($rounded, $this->currency);
    }

    public function isNegative(): bool
    {
        return $this->minor < 0;
    }

    public function __toString(): string
    {
        return $this->currency->format($this->minor);
    }

    private function assertSameCurrency(self $other): void
    {
        if ($other->currency !== $this->currency) {
            throw new InvalidArgumentException(sprintf(
                'Cannot combine %s with %s',
                $this->currency->value,
                $other->currency->value,
            ));
        }
    }
}

final readonly class LedgerEntry
{
    public function __construct(
        public string $reference,
        public EntryKind $kind,
        public Money $amount,
        public DateTimeImmutable $bookedAt,
    ) {
        if ($amount->minor === 0) {
            throw new InvalidArgumentException("Entry {$reference} has a zero amount");
        }
    }

    public function signedAmount(): Money
    {
        return new Money($this->amount->minor * $this->kind->direction(), $this->amount->currency);
    }
}

final readonly class FeeSchedule
{
    /**
     * @param int $captureBp      percentage fee on gross captures, in basis points
     * @param int $fixedPerCapture fixed fee per capture, minor units
     * @param int $chargebackFee   flat fee for each chargeback, minor units
     */
    public function __construct(
        public int $captureBp,
        public int $fixedPerCapture,
        public int $chargebackFee,
    ) {}
}

final readonly class PayoutInstruction
{
    public function __construct(
        public string $batchId,
        public string $merchantId,
        public Money $gross,
        public Money $fees,
        public Money $net,
        public DateTimeImmutable $valueDate,
    ) {}

    /** @return array<string, string> */
    public function toArray(): array
    {
        return [
            'batch'      => $this->batchId,
            'merchant'   => $this->merchantId,
            'gross'      => (string) $this->gross,
            'fees'       => (string) $this->fees,
            'net'        => (string) $this->net,
            'value_date' => $this->valueDate->format('Y-m-d'),
        ];
    }
}

final class SettlementBatch
{
    /** @var list<LedgerEntry> */
    private array $entries = [];

    /** @var array<string, true> */
    private array $seenReferences = [];

    private BatchState $state = BatchState::Open;

    public function __construct(
        public readonly string $id,
        public readonly string $merchantId,
        public readonly Currency $currency,
    ) {}

    public function state(): BatchState
    {
        return $this->state;
    }

    public function add(LedgerEntry $entry): void
    {
        if ($this->state !== BatchState::Open) {
            throw new LogicException("Batch {$this->id} is {$this->state->value}; entries are frozen");
        }
        if ($entry->amount->currency !== $this->currency) {
            throw new InvalidArgumentException("Entry {$entry->reference} is not in {$this->currency->value}");
        }
        if (isset($this->seenReferences[$entry->reference])) {
            return; // idempotent: the same webhook delivered twice is not two payments
        }

        $this->seenReferences[$entry->reference] = true;
        $this->entries[] = $entry;
    }

    /** @return list<LedgerEntry> */
    public function entries(): array
    {
        return $this->entries;
    }

    public function transition(BatchState $next): void
    {
        if (!$this->state->canTransitionTo($next)) {
            throw new LogicException(sprintf(
                'Batch %s cannot go from %s to %s',
                $this->id,
                $this->state->value,
                $next->value,
            ));
        }
        $this->state = $next;
    }
}

interface BusinessCalendar
{
    public function isBusinessDay(DateTimeImmutable $day): bool;
}

final readonly class WeekdayCalendar implements BusinessCalendar
{
    /** @param list<string> $holidays ISO dates, e.g. "2026-12-25" */
    public function __construct(private array $holidays = []) {}

    public function isBusinessDay(DateTimeImmutable $day): bool
    {
        $weekday = (int) $day->format('N');
        return $weekday < 6 && !in_array($day->format('Y-m-d'), $this->holidays, true);
    }
}

final readonly class SettlementBatchService
{
    public function __construct(
        private BusinessCalendar $calendar,
        private int $settlementDelayDays = 2,
        private DateTimeZone $zone = new DateTimeZone('UTC'),
    ) {}

    /**
     * Seal a batch and compute what the merchant is owed.
     *
     * A negative net is legal (refunds can exceed captures in a quiet week);
     * the instruction then represents a debit, and the caller decides
     * whether to carry it forward or collect it.
     */
    public function seal(SettlementBatch $batch, FeeSchedule $fees, DateTimeImmutable $now): PayoutInstruction
    {
        $currency = $batch->currency;
        $gross    = Money::zero($currency);
        $feeTotal = Money::zero($currency);
        $captures = 0;

        foreach ($batch->entries() as $entry) {
            $gross = $gross->plus($entry->signedAmount());

            switch ($entry->kind) {
                case EntryKind::Capture:
                    $captures++;
                    $feeTotal = $feeTotal->plus($entry->amount->basisPoints($fees->captureBp));
                    break;
                case EntryKind::Chargeback:
                    $feeTotal = $feeTotal->plus(new Money($fees->chargebackFee, $currency));
                    break;
                case EntryKind::Refund:
                case EntryKind::Adjustment:
                    break;
            }
        }

        $feeTotal = $feeTotal->plus(new Money($captures * $fees->fixedPerCapture, $currency));
        $batch->transition(BatchState::Sealed);

        return new PayoutInstruction(
            batchId:    $batch->id,
            merchantId: $batch->merchantId,
            gross:      $gross,
            fees:       $feeTotal,
            net:        $gross->minus($feeTotal),
            valueDate:  $this->valueDate($now),
        );
    }

    /**
     * Value date is N business days after the sealing day, in the
     * settlement zone, never on a weekend or listed holiday.
     */
    public function valueDate(DateTimeImmutable $sealedAt): DateTimeImmutable
    {
        $day       = $sealedAt->setTimezone($this->zone)->setTime(0, 0);
        $remaining = $this->settlementDelayDays;

        while ($remaining > 0) {
            $day = $day->modify('+1 day');
            if ($this->calendar->isBusinessDay($day)) {
                $remaining--;
            }
        }

        return $day;
    }
}

// --- A short worked example, runnable with `php SettlementBatchService.php` ---

if (PHP_SAPI === 'cli' && realpath($argv[0] ?? '') === __FILE__) {
    $at    = static fn (string $iso) => new DateTimeImmutable($iso);
    $batch = new SettlementBatch('btc_7Q2M', 'mrc_harbourline', Currency::EUR);

    $batch->add(new LedgerEntry('pay_001', EntryKind::Capture, new Money(12_500, Currency::EUR), $at('2026-11-02T09:14:00Z')));
    $batch->add(new LedgerEntry('pay_002', EntryKind::Capture, new Money(4_990, Currency::EUR), $at('2026-11-02T11:02:00Z')));
    $batch->add(new LedgerEntry('pay_002', EntryKind::Capture, new Money(4_990, Currency::EUR), $at('2026-11-02T11:02:00Z')));
    $batch->add(new LedgerEntry('ref_001', EntryKind::Refund, new Money(2_000, Currency::EUR), $at('2026-11-03T15:40:00Z')));
    $batch->add(new LedgerEntry('cbk_001', EntryKind::Chargeback, new Money(4_990, Currency::EUR), $at('2026-11-04T08:00:00Z')));

    $service = new SettlementBatchService(new WeekdayCalendar(['2026-11-11']));
    $payout  = $service->seal($batch, new FeeSchedule(captureBp: 145, fixedPerCapture: 25, chargebackFee: 1_500), $at('2026-11-06T17:30:00Z'));

    foreach ($payout->toArray() as $label => $value) {
        printf("%-11s %s\n", $label, $value);
    }
}
