// SettlementReport.cs
//
// Builds the end-of-day reconciliation report for Meridian Payments: every
// acquirer file is matched against the internal ledger, differences are
// classified, and the result is rendered as a fixed-width text report.
//
// Written as a single-file program (top-level statements, .NET 8 / C# 12).

using System.Collections.Immutable;
using System.Globalization;
using System.Text;

var ledger = SampleData.Ledger();
var acquirer = SampleData.AcquirerFile();

var reconciliation = Reconciler.Match(ledger, acquirer, tolerance: 0.00m);
var report = ReportWriter.Render(reconciliation, new DateOnly(2026, 3, 14));

Console.Write(report);
return reconciliation.Breaks.Any(b => b.Severity == Severity.Blocking) ? 1 : 0;

// ---------------------------------------------------------------------------
// Domain
// ---------------------------------------------------------------------------

public readonly record struct Money(decimal Amount, string Currency)
{
    public static Money Zero(string currency) => new(0m, currency);

    public static Money operator +(Money a, Money b) =>
        a.Currency == b.Currency
            ? a with { Amount = a.Amount + b.Amount }
            : throw new InvalidOperationException($"Cannot add {a.Currency} to {b.Currency}.");

    public static Money operator -(Money a, Money b) => a + (b with { Amount = -b.Amount });

    public override string ToString() =>
        $"{Amount.ToString("#,##0.00;-#,##0.00", CultureInfo.InvariantCulture)} {Currency}";
}

public enum Scheme { Visa, Mastercard, Amex, Local }

public sealed record LedgerEntry(
    string PaymentId,
    string MerchantId,
    Scheme Scheme,
    Money Amount,
    DateTimeOffset CapturedAt);

public sealed record AcquirerLine(
    string AcquirerReference,
    string? PaymentId,          // some acquirers drop our reference on partial captures
    Money Gross,
    Money InterchangeFee,
    DateOnly ValueDate);

public enum Severity { Info, Warning, Blocking }

public abstract record Break(string Key, Severity Severity)
{
    public abstract string Describe();
}

public sealed record MissingAtAcquirer(LedgerEntry Entry)
    : Break(Entry.PaymentId, Severity.Blocking)
{
    public override string Describe() =>
        $"captured {Entry.Amount} for {Entry.MerchantId}, absent from the acquirer file";
}

public sealed record UnknownAtAcquirer(AcquirerLine Line)
    : Break(Line.AcquirerReference, Severity.Warning)
{
    public override string Describe() =>
        $"acquirer settled {Line.Gross} with no matching ledger entry";
}

public sealed record AmountMismatch(LedgerEntry Entry, AcquirerLine Line)
    : Break(Entry.PaymentId, Math.Abs(Line.Gross.Amount - Entry.Amount.Amount) > 1m ? Severity.Blocking : Severity.Warning)
{
    public Money Difference => Line.Gross - Entry.Amount;

    public override string Describe() =>
        $"ledger {Entry.Amount}, acquirer {Line.Gross} (difference {Difference})";
}

public sealed record LateValueDate(LedgerEntry Entry, AcquirerLine Line, int DaysLate)
    : Break(Entry.PaymentId, Severity.Info)
{
    public override string Describe() => $"value date {Line.ValueDate:yyyy-MM-dd}, {DaysLate} day(s) later than T+1";
}

public sealed record Reconciliation(
    ImmutableArray<(LedgerEntry Entry, AcquirerLine Line)> Matched,
    ImmutableArray<Break> Breaks);

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

public static class Reconciler
{
    public static Reconciliation Match(
        IReadOnlyCollection<LedgerEntry> ledger,
        IReadOnlyCollection<AcquirerLine> acquirer,
        decimal tolerance)
    {
        var byPaymentId = acquirer
            .Where(l => l.PaymentId is not null)
            .ToLookup(l => l.PaymentId!);

        var matched = ImmutableArray.CreateBuilder<(LedgerEntry, AcquirerLine)>();
        var breaks = ImmutableArray.CreateBuilder<Break>();
        var consumed = new HashSet<AcquirerLine>(ReferenceEqualityComparer.Instance);

        foreach (var entry in ledger.OrderBy(e => e.CapturedAt))
        {
            var candidate = byPaymentId[entry.PaymentId].FirstOrDefault(l => !consumed.Contains(l));
            if (candidate is null)
            {
                breaks.Add(new MissingAtAcquirer(entry));
                continue;
            }

            consumed.Add(candidate);
            matched.Add((entry, candidate));

            if (Math.Abs(candidate.Gross.Amount - entry.Amount.Amount) > tolerance)
            {
                breaks.Add(new AmountMismatch(entry, candidate));
            }

            var expected = DateOnly.FromDateTime(entry.CapturedAt.UtcDateTime).AddDays(1);
            var late = candidate.ValueDate.DayNumber - expected.DayNumber;
            if (late > 0)
            {
                breaks.Add(new LateValueDate(entry, candidate, late));
            }
        }

        breaks.AddRange(acquirer
            .Where(l => !consumed.Contains(l))
            .Select(l => new UnknownAtAcquirer(l)));

        return new Reconciliation(matched.ToImmutable(), breaks.ToImmutable());
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

public static class ReportWriter
{
    private const int Width = 78;

    public static string Render(Reconciliation r, DateOnly businessDay)
    {
        var sb = new StringBuilder();
        Rule(sb, '=');
        sb.AppendLine(Center($"MERIDIAN PAYMENTS  -  RECONCILIATION  {businessDay:yyyy-MM-dd}"));
        Rule(sb, '=');

        // Totals per scheme and currency for everything that matched.
        var totals =
            from m in r.Matched
            group m by (m.Entry.Scheme, m.Entry.Amount.Currency) into g
            orderby g.Key.Scheme, g.Key.Currency
            select new
            {
                g.Key.Scheme,
                g.Key.Currency,
                Count = g.Count(),
                Gross = g.Aggregate(Money.Zero(g.Key.Currency), (acc, x) => acc + x.Line.Gross),
                Fees = g.Aggregate(Money.Zero(g.Key.Currency), (acc, x) => acc + x.Line.InterchangeFee),
            };

        sb.AppendLine();
        sb.AppendLine($"{"Scheme",-12}{"Ccy",-5}{"Count",7}{"Gross",20}{"Interchange",18}{"Net",16}");
        Rule(sb, '-');
        foreach (var t in totals)
        {
            var net = t.Gross - t.Fees;
            sb.AppendLine(
                $"{t.Scheme,-12}{t.Currency,-5}{t.Count,7}{Num(t.Gross),20}{Num(t.Fees),18}{Num(net),16}");
        }

        // Breaks, most severe first, then by key for a stable diff between runs.
        var grouped = r.Breaks
            .OrderByDescending(b => b.Severity)
            .ThenBy(b => b.Key, StringComparer.Ordinal)
            .GroupBy(b => b.Severity);

        foreach (var group in grouped)
        {
            sb.AppendLine();
            sb.AppendLine($"{group.Key.ToString().ToUpperInvariant()} ({group.Count()})");
            Rule(sb, '-');
            foreach (var b in group)
            {
                sb.AppendLine($"  {b.Key,-16} {b.GetType().Name,-18} {b.Describe()}");
            }
        }

        var blocking = r.Breaks.Count(b => b.Severity == Severity.Blocking);
        sb.AppendLine();
        Rule(sb, '=');
        sb.AppendLine(blocking == 0
            ? Center("READY TO RELEASE PAYOUTS")
            : Center($"PAYOUTS HELD: {blocking} blocking break(s) need an operator"));
        Rule(sb, '=');
        return sb.ToString();
    }

    private static string Num(Money m) => m.Amount.ToString("#,##0.00", CultureInfo.InvariantCulture);

    private static string Center(string s) => s.PadLeft((Width + s.Length) / 2).PadRight(Width);

    private static void Rule(StringBuilder sb, char c) => sb.AppendLine(new string(c, Width));
}

// ---------------------------------------------------------------------------
// Fixture data (fictional merchants)
// ---------------------------------------------------------------------------

internal static class SampleData
{
    private static readonly DateTimeOffset Day = new(2026, 3, 13, 0, 0, 0, TimeSpan.Zero);

    public static IReadOnlyCollection<LedgerEntry> Ledger() =>
    [
        new("pay_01HV2A", "m_harbor_coffee",    Scheme.Visa,       new(18.40m, "EUR"),  Day.AddHours(7.2)),
        new("pay_01HV2B", "m_harbor_coffee",    Scheme.Mastercard, new(6.10m, "EUR"),   Day.AddHours(7.9)),
        new("pay_01HV2C", "m_northwind_books",  Scheme.Visa,       new(42.00m, "GBP"),  Day.AddHours(10.5)),
        new("pay_01HV2D", "m_northwind_books",  Scheme.Amex,       new(129.95m, "GBP"), Day.AddHours(11.0)),
        new("pay_01HV2E", "m_tidepool_tickets", Scheme.Visa,       new(310.00m, "EUR"), Day.AddHours(13.3)),
        new("pay_01HV2F", "m_tidepool_tickets", Scheme.Mastercard, new(95.50m, "EUR"),  Day.AddHours(14.1)),
        new("pay_01HV2G", "m_lantern_studio",   Scheme.Local,      new(1200.00m, "SEK"),Day.AddHours(15.8)),
        new("pay_01HV2H", "m_harbor_coffee",    Scheme.Visa,       new(3.80m, "EUR"),   Day.AddHours(16.4)),
        new("pay_01HV2J", "m_northwind_books",  Scheme.Mastercard, new(18.75m, "GBP"),  Day.AddHours(19.0)),
    ];

    public static IReadOnlyCollection<AcquirerLine> AcquirerFile() =>
    [
        new("ACQ-55120", "pay_01HV2A", new(18.40m, "EUR"),   new(0.06m, "EUR"),  new(2026, 3, 14)),
        new("ACQ-55121", "pay_01HV2B", new(6.10m, "EUR"),    new(0.02m, "EUR"),  new(2026, 3, 14)),
        new("ACQ-55122", "pay_01HV2C", new(42.00m, "GBP"),   new(0.13m, "GBP"),  new(2026, 3, 14)),
        new("ACQ-55123", "pay_01HV2D", new(129.95m, "GBP"),  new(2.27m, "GBP"),  new(2026, 3, 16)),
        new("ACQ-55124", "pay_01HV2E", new(301.00m, "EUR"),  new(0.93m, "EUR"),  new(2026, 3, 14)),
        new("ACQ-55125", "pay_01HV2F", new(95.49m, "EUR"),   new(0.29m, "EUR"),  new(2026, 3, 14)),
        new("ACQ-55126", "pay_01HV2G", new(1200.00m, "SEK"), new(8.40m, "SEK"),  new(2026, 3, 14)),
        new("ACQ-55127", null,         new(12.00m, "EUR"),   new(0.04m, "EUR"),  new(2026, 3, 14)),
        new("ACQ-55128", "pay_01HV2J", new(18.75m, "GBP"),   new(0.06m, "GBP"),  new(2026, 3, 14)),
    ];
}
