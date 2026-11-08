// settlement_batcher.cpp
//
// Meridian Payments nets a day's card captures into settlement batches, one
// per (merchant, currency). This is a self-contained model of that step:
//
//   1. parse a stream of ledger events (captures, refunds, chargebacks),
//   2. reject what cannot settle and say why,
//   3. net the rest per merchant and currency,
//   4. apply each merchant's fee schedule, and
//   5. print the batches the payout service would receive.
//
// Money is held in minor units (cents) as 64-bit integers throughout; no
// value ever passes through a double.
//
//     c++ -std=c++20 -O2 -Wall -Wextra settlement_batcher.cpp -o batcher
//     ./batcher

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <map>
#include <optional>
#include <ranges>
#include <span>
#include <sstream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <variant>
#include <vector>

namespace meridian {

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

struct Currency {
    char code[4]{};
    int minor_digits{2};

    friend bool operator==(const Currency& a, const Currency& b) {
        return std::string_view{a.code} == std::string_view{b.code};
    }
    friend auto operator<=>(const Currency& a, const Currency& b) {
        return std::string_view{a.code} <=> std::string_view{b.code};
    }
};

std::optional<Currency> currency_from(std::string_view code) {
    static constexpr std::pair<std::string_view, int> known[] = {
        {"EUR", 2}, {"USD", 2}, {"GBP", 2}, {"JPY", 0}, {"KWD", 3}, {"SEK", 2},
    };
    for (auto [c, digits] : known) {
        if (c == code) {
            Currency cur;
            std::copy(c.begin(), c.end(), cur.code);
            cur.minor_digits = digits;
            return cur;
        }
    }
    return std::nullopt;
}

// An amount in minor units of a specific currency.
struct Money {
    std::int64_t minor{};
    Currency currency;

    Money& operator+=(const Money& o) { minor += o.minor; return *this; }
    Money operator-() const { return {-minor, currency}; }
};

std::ostream& operator<<(std::ostream& os, const Money& m) {
    const int d = m.currency.minor_digits;
    std::int64_t scale = 1;
    for (int i = 0; i < d; ++i) scale *= 10;

    const std::int64_t abs = m.minor < 0 ? -m.minor : m.minor;
    std::ostringstream out;
    out << (m.minor < 0 ? "-" : "") << abs / scale;
    if (d > 0) out << '.' << std::setw(d) << std::setfill('0') << abs % scale;
    out << ' ' << m.currency.code;
    return os << out.str();
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

struct Capture    { std::string payment_id; Money amount; };
struct Refund     { std::string payment_id; Money amount; };
struct Chargeback { std::string payment_id; Money amount; std::string reason_code; };

using Event = std::variant<Capture, Refund, Chargeback>;

struct LedgerLine {
    std::uint64_t sequence;
    std::string merchant_id;
    Event event;
};

struct Rejection {
    std::uint64_t sequence;
    std::string reason;
};

// Helper so std::visit can take a set of lambdas.
template <class... F> struct overloaded : F... { using F::operator()...; };

// ---------------------------------------------------------------------------
// Parsing:  seq|merchant|kind|payment|amount|currency[|reason]
// ---------------------------------------------------------------------------

std::vector<std::string_view> split(std::string_view s, char sep) {
    std::vector<std::string_view> parts;
    for (auto part : s | std::views::split(sep)) {
        parts.emplace_back(part.begin(), part.end());
    }
    return parts;
}

template <class Int>
std::optional<Int> parse_int(std::string_view s) {
    Int v{};
    auto [ptr, ec] = std::from_chars(s.data(), s.data() + s.size(), v);
    if (ec != std::errc{} || ptr != s.data() + s.size()) return std::nullopt;
    return v;
}

std::variant<LedgerLine, Rejection> parse_line(std::string_view text) {
    const auto f = split(text, '|');
    const auto seq = f.empty() ? std::nullopt : parse_int<std::uint64_t>(f[0]);
    if (!seq) return Rejection{0, "unreadable sequence number"};
    if (f.size() < 6) return Rejection{*seq, "expected at least 6 fields"};

    const auto amount = parse_int<std::int64_t>(f[4]);
    if (!amount || *amount <= 0) return Rejection{*seq, "amount must be a positive integer"};

    const auto currency = currency_from(f[5]);
    if (!currency) return Rejection{*seq, "unsupported currency " + std::string{f[5]}};

    const Money money{*amount, *currency};
    std::string merchant{f[1]};
    std::string payment{f[3]};

    if (f[2] == "CAPTURE") return LedgerLine{*seq, merchant, Capture{payment, money}};
    if (f[2] == "REFUND") return LedgerLine{*seq, merchant, Refund{payment, money}};
    if (f[2] == "CHARGEBACK") {
        if (f.size() < 7) return Rejection{*seq, "chargeback without a reason code"};
        return LedgerLine{*seq, merchant, Chargeback{payment, money, std::string{f[6]}}};
    }
    return Rejection{*seq, "unknown event kind " + std::string{f[2]}};
}

// ---------------------------------------------------------------------------
// Fees
// ---------------------------------------------------------------------------

struct FeeSchedule {
    std::int64_t basis_points;       // per capture, on the gross amount
    std::int64_t fixed_minor;        // per capture
    std::int64_t chargeback_minor;   // flat, per chargeback
};

// Round half to even, so a large batch of half-cent fees does not drift.
std::int64_t apply_bps(std::int64_t amount, std::int64_t bps) {
    const std::int64_t num = amount * bps;
    std::int64_t q = num / 10'000;
    const std::int64_t r = num % 10'000;
    if (r * 2 > 10'000 || (r * 2 == 10'000 && (q % 2) != 0)) ++q;
    return q;
}

// ---------------------------------------------------------------------------
// Batching
// ---------------------------------------------------------------------------

struct BatchKey {
    std::string merchant_id;
    Currency currency;
    auto operator<=>(const BatchKey&) const = default;
};

struct Batch {
    Money gross_captures;
    Money refunds;
    Money chargebacks;
    Money fees;
    int captures = 0;
    int reversals = 0;

    [[nodiscard]] Money net() const {
        return {gross_captures.minor - refunds.minor - chargebacks.minor - fees.minor,
                gross_captures.currency};
    }
};

class Batcher {
public:
    explicit Batcher(std::unordered_map<std::string, FeeSchedule> schedules)
        : schedules_{std::move(schedules)} {}

    void ingest(const LedgerLine& line) {
        const auto schedule = schedules_.find(line.merchant_id);
        if (schedule == schedules_.end()) {
            rejections_.push_back({line.sequence, "no fee schedule for " + line.merchant_id});
            return;
        }
        const FeeSchedule& fees = schedule->second;

        std::visit(overloaded{
            [&](const Capture& c) {
                Batch& b = batch_for(line.merchant_id, c.amount.currency);
                b.gross_captures += c.amount;
                b.fees.minor += apply_bps(c.amount.minor, fees.basis_points) + fees.fixed_minor;
                ++b.captures;
                captured_[c.payment_id] += c.amount.minor;
            },
            [&](const Refund& r) {
                if (!refundable(r.payment_id, r.amount.minor)) {
                    rejections_.push_back({line.sequence, "refund exceeds capture for " + r.payment_id});
                    return;
                }
                Batch& b = batch_for(line.merchant_id, r.amount.currency);
                b.refunds += r.amount;
                ++b.reversals;
                captured_[r.payment_id] -= r.amount.minor;
            },
            [&](const Chargeback& cb) {
                Batch& b = batch_for(line.merchant_id, cb.amount.currency);
                b.chargebacks += cb.amount;
                b.fees.minor += fees.chargeback_minor;
                ++b.reversals;
            },
        }, line.event);
    }

    void reject(Rejection r) { rejections_.push_back(std::move(r)); }

    [[nodiscard]] const std::map<BatchKey, Batch>& batches() const { return batches_; }
    [[nodiscard]] std::span<const Rejection> rejections() const { return rejections_; }

private:
    Batch& batch_for(const std::string& merchant, const Currency& cur) {
        auto [it, inserted] = batches_.try_emplace(BatchKey{merchant, cur});
        if (inserted) {
            const Money zero{0, cur};
            it->second = Batch{zero, zero, zero, zero};
        }
        return it->second;
    }

    bool refundable(const std::string& payment_id, std::int64_t amount) const {
        const auto it = captured_.find(payment_id);
        return it != captured_.end() && it->second >= amount;
    }

    std::unordered_map<std::string, FeeSchedule> schedules_;
    std::unordered_map<std::string, std::int64_t> captured_;
    std::map<BatchKey, Batch> batches_;
    std::vector<Rejection> rejections_;
};

} // namespace meridian

// ---------------------------------------------------------------------------

constexpr std::string_view kLedger = R"(1001|m_harbor_coffee|CAPTURE|pay_7Qd1|1250|EUR
1002|m_harbor_coffee|CAPTURE|pay_7Qd2|480|EUR
1003|m_northwind_books|CAPTURE|pay_8Kx0|3999|GBP
1004|m_harbor_coffee|REFUND|pay_7Qd1|250|EUR
1005|m_tidepool_tickets|CAPTURE|pay_2Zr4|125000|JPY
1006|m_northwind_books|CAPTURE|pay_8Kx1|1549|GBP
1007|m_northwind_books|CHARGEBACK|pay_8Kx0|3999|GBP|4837
1008|m_harbor_coffee|REFUND|pay_7Qd2|900|EUR
1009|m_tidepool_tickets|CAPTURE|pay_2Zr5|8800|XTS
1010|m_lantern_studio|CAPTURE|pay_5Lm3|20000|USD
1011|m_tidepool_tickets|CAPTURE|pay_2Zr6|43000|JPY
1012|m_harbor_coffee|CAPTURE|pay_7Qd3|-300|EUR
1013|m_northwind_books|CHARGEBACK|pay_8Kx1|1549|GBP
1014|m_harbor_coffee|CAPTURE|pay_7Qd4|2210|SEK
oops
1015|m_tidepool_tickets|REFUND|pay_2Zr4|25000|JPY)";

int main() {
    using namespace meridian;

    Batcher batcher{{
        {"m_harbor_coffee",    {.basis_points = 140, .fixed_minor = 10, .chargeback_minor = 1500}},
        {"m_northwind_books",  {.basis_points = 175, .fixed_minor = 20, .chargeback_minor = 1500}},
        {"m_tidepool_tickets", {.basis_points = 95,  .fixed_minor = 0,  .chargeback_minor = 2000}},
    }};

    for (auto line : kLedger | std::views::split('\n')) {
        const std::string_view text{line.begin(), line.end()};
        if (text.empty()) continue;
        std::visit(overloaded{
            [&](const LedgerLine& l) { batcher.ingest(l); },
            [&](Rejection r) { batcher.reject(std::move(r)); },
        }, parse_line(text));
    }

    std::cout << "Settlement batches\n"
              << "------------------\n";
    for (const auto& [key, b] : batcher.batches()) {
        std::cout << std::left << std::setw(20) << key.merchant_id << ' ' << key.currency.code
                  << "  captures " << b.captures << ", reversals " << b.reversals << '\n'
                  << "    gross       " << b.gross_captures << '\n'
                  << "    refunds     " << -b.refunds << '\n'
                  << "    chargebacks " << -b.chargebacks << '\n'
                  << "    fees        " << -b.fees << '\n'
                  << "    net payout  " << b.net() << "\n\n";
    }

    const auto rejected = batcher.rejections();
    std::cout << rejected.size() << " line(s) held back:\n";
    for (const auto& r : rejected) {
        std::cout << "  #" << r.sequence << "  " << r.reason << '\n';
    }
}
