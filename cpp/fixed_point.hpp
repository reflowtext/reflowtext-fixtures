// fixed_point.hpp -- a header-only, constexpr-first fixed-point number type.
//
// Halcyon Instruments uses this on the control-rate side of its firmware,
// where the target has no FPU and every sample of jitter is audible.
// The type is a thin wrapper over an integer with a compile-time number of
// fractional bits; all arithmetic is checked at compile time where possible
// and every operation is usable in constant expressions.
//
//     using q16 = hx::fixed<int32_t, 16>;
//     constexpr q16 gain = q16::from(0.75);
//     static_assert((gain * q16{2}).to<double>() == 1.5);
//
// Requires C++20.

#pragma once

#include <bit>
#include <compare>
#include <concepts>
#include <cstdint>
#include <limits>
#include <ostream>
#include <type_traits>

namespace hx {

namespace detail {

// The next-wider integer for intermediate products, so `a * b` cannot
// overflow before it is shifted back down.
template <typename T> struct wider;
template <> struct wider<std::int8_t>   { using type = std::int16_t; };
template <> struct wider<std::int16_t>  { using type = std::int32_t; };
template <> struct wider<std::int32_t>  { using type = std::int64_t; };
template <> struct wider<std::uint8_t>  { using type = std::uint16_t; };
template <> struct wider<std::uint16_t> { using type = std::uint32_t; };
template <> struct wider<std::uint32_t> { using type = std::uint64_t; };

template <typename T>
using wider_t = typename wider<T>::type;

template <typename T>
concept narrow_integer = std::integral<T> && requires { typename wider<T>::type; };

// Round-half-away-from-zero division by a power of two.
template <std::integral W>
constexpr W shift_round(W value, int bits) noexcept {
    if (bits <= 0) return value << -bits;
    const W half = W{1} << (bits - 1);
    if constexpr (std::is_signed_v<W>) {
        return value >= 0 ? (value + half) >> bits : -((-value + half) >> bits);
    } else {
        return (value + half) >> bits;
    }
}

template <std::integral T, std::integral W>
constexpr T saturate(W value) noexcept {
    constexpr W lo = static_cast<W>(std::numeric_limits<T>::min());
    constexpr W hi = static_cast<W>(std::numeric_limits<T>::max());
    return static_cast<T>(value < lo ? lo : (value > hi ? hi : value));
}

} // namespace detail

// Overflow policy, chosen per type. Audio paths want saturation (a clipped
// sample is a click; a wrapped one is a bang); counters want wrap-around.
enum class overflow { saturate, wrap };

template <detail::narrow_integer Rep, int FracBits, overflow Policy = overflow::saturate>
class fixed {
    static_assert(FracBits >= 0, "negative fractional bits are not supported");
    static_assert(FracBits <= std::numeric_limits<Rep>::digits,
                  "more fractional bits than the representation holds");

public:
    using rep = Rep;
    using wide = detail::wider_t<Rep>;
    static constexpr int frac_bits = FracBits;
    static constexpr int int_bits = std::numeric_limits<Rep>::digits - FracBits;
    // Held in the wide type: for q15 the value 1.0 itself is not representable.
    static constexpr wide one_raw = wide{1} << FracBits;

    // --- construction -------------------------------------------------

    constexpr fixed() noexcept = default;

    // Integers convert exactly (or saturate, per policy).
    template <std::integral I>
    constexpr explicit fixed(I whole) noexcept
        : raw_{narrow(static_cast<wide>(whole) << FracBits)} {}

    // Floating point converts with rounding. Constexpr, so table entries
    // are computed by the compiler rather than at boot.
    template <std::floating_point F>
    static constexpr fixed from(F value) noexcept {
        const F scaled = value * static_cast<F>(one_raw);
        const F rounded = scaled >= 0 ? scaled + F(0.5) : scaled - F(0.5);
        return from_raw(narrow(static_cast<wide>(rounded)));
    }

    static constexpr fixed from_raw(Rep raw) noexcept {
        fixed f;
        f.raw_ = raw;
        return f;
    }

    // Re-scale from a type with a different number of fractional bits.
    template <typename R2, int F2, overflow P2>
    static constexpr fixed convert(fixed<R2, F2, P2> other) noexcept {
        using W = std::common_type_t<wide, typename fixed<R2, F2, P2>::wide>;
        const W v = detail::shift_round(static_cast<W>(other.raw()), F2 - FracBits);
        return from_raw(narrow(v));
    }

    // --- observers ----------------------------------------------------

    [[nodiscard]] constexpr Rep raw() const noexcept { return raw_; }

    template <std::floating_point F>
    [[nodiscard]] constexpr F to() const noexcept {
        return static_cast<F>(raw_) / static_cast<F>(one_raw);
    }

    template <std::integral I>
    [[nodiscard]] constexpr I to() const noexcept {
        return static_cast<I>(raw_ >> FracBits); // floor
    }

    [[nodiscard]] constexpr fixed fractional() const noexcept {
        return from_raw(static_cast<Rep>(static_cast<wide>(raw_) & (one_raw - 1)));
    }

    static constexpr fixed min() noexcept { return from_raw(std::numeric_limits<Rep>::min()); }
    static constexpr fixed max() noexcept { return from_raw(std::numeric_limits<Rep>::max()); }
    static constexpr fixed epsilon() noexcept { return from_raw(Rep{1}); }

    // --- arithmetic ---------------------------------------------------

    constexpr fixed operator-() const noexcept { return from_raw(narrow(-static_cast<wide>(raw_))); }
    constexpr fixed operator+() const noexcept { return *this; }

    friend constexpr fixed operator+(fixed a, fixed b) noexcept {
        return from_raw(narrow(static_cast<wide>(a.raw_) + b.raw_));
    }
    friend constexpr fixed operator-(fixed a, fixed b) noexcept {
        return from_raw(narrow(static_cast<wide>(a.raw_) - b.raw_));
    }
    friend constexpr fixed operator*(fixed a, fixed b) noexcept {
        const wide p = static_cast<wide>(a.raw_) * b.raw_;
        return from_raw(narrow(detail::shift_round(p, FracBits)));
    }
    friend constexpr fixed operator/(fixed a, fixed b) noexcept {
        if (b.raw_ == 0) {
            return a.raw_ >= 0 ? max() : min(); // defined, not UB
        }
        const wide n = static_cast<wide>(a.raw_) << FracBits;
        return from_raw(narrow(n / b.raw_));
    }

    constexpr fixed& operator+=(fixed o) noexcept { return *this = *this + o; }
    constexpr fixed& operator-=(fixed o) noexcept { return *this = *this - o; }
    constexpr fixed& operator*=(fixed o) noexcept { return *this = *this * o; }
    constexpr fixed& operator/=(fixed o) noexcept { return *this = *this / o; }

    friend constexpr auto operator<=>(fixed, fixed) noexcept = default;
    friend constexpr bool operator==(fixed, fixed) noexcept = default;

    friend std::ostream& operator<<(std::ostream& os, fixed f) {
        return os << f.template to<double>();
    }

private:
    template <std::integral W>
    static constexpr Rep narrow(W v) noexcept {
        if constexpr (Policy == overflow::saturate) {
            return detail::saturate<Rep>(v);
        } else {
            return static_cast<Rep>(v);
        }
    }

    Rep raw_{};
};

// --- common aliases ---------------------------------------------------

using q7    = fixed<std::int8_t, 7>;
using q15   = fixed<std::int16_t, 15>;
using q31   = fixed<std::int32_t, 31>;
using q16_16 = fixed<std::int32_t, 16>;
using uq8_8 = fixed<std::uint16_t, 8>;

// --- functions --------------------------------------------------------

template <typename R, int F, overflow P>
constexpr fixed<R, F, P> abs(fixed<R, F, P> x) noexcept {
    return x < fixed<R, F, P>{} ? -x : x;
}

// Linear interpolation, `t` in [0, 1].
template <typename R, int F, overflow P>
constexpr fixed<R, F, P> lerp(fixed<R, F, P> a, fixed<R, F, P> b, fixed<R, F, P> t) noexcept {
    return a + (b - a) * t;
}

// Square root by digit-by-digit (restoring) method: exact to the last bit,
// no floating point, and a fixed number of iterations.
template <typename R, int F, overflow P>
constexpr fixed<R, F, P> sqrt(fixed<R, F, P> x) noexcept {
    using T = fixed<R, F, P>;
    using U = std::make_unsigned_t<typename T::wide>;
    if (x.raw() <= 0) return T{};

    U n = static_cast<U>(x.raw()) << F;
    U result = 0;
    U bit = U{1} << (std::bit_width(n) & ~1u);
    while (bit > n) bit >>= 2;

    while (bit != 0) {
        if (n >= result + bit) {
            n -= result + bit;
            result = (result >> 1) + bit;
        } else {
            result >>= 1;
        }
        bit >>= 2;
    }
    return T::from_raw(static_cast<R>(result));
}

// A sine lookup table generated entirely at compile time, using a Taylor
// series in long double so the build machine's libm is never consulted.
template <typename T, std::size_t N>
struct sine_table {
    static_assert(std::has_single_bit(N), "table size must be a power of two");

    T values[N]{};

    constexpr sine_table() noexcept {
        constexpr long double pi = 3.141592653589793238462643383279502884L;
        for (std::size_t i = 0; i < N; ++i) {
            long double x = 2 * pi * static_cast<long double>(i) / N;
            if (x > pi) x -= 2 * pi;
            long double term = x, sum = x;
            for (int k = 1; k < 12; ++k) {
                term *= -x * x / ((2 * k) * (2 * k + 1));
                sum += term;
            }
            values[i] = T::from(static_cast<double>(sum));
        }
    }

    // `phase` is a full-range unsigned accumulator, as in a DDS oscillator.
    constexpr T operator()(std::uint32_t phase) const noexcept {
        constexpr int shift = 32 - std::countr_zero(N);
        return values[phase >> shift];
    }
};

// --- compile-time checks ---------------------------------------------

namespace checks {

constexpr q16_16 half = q16_16::from(0.5);
static_assert(half.raw() == 0x8000);
static_assert((half + half) == q16_16{1});
static_assert((q16_16{3} * half).to<double>() == 1.5);
static_assert((q16_16{1} / q16_16{4}).to<double>() == 0.25);
static_assert(q16_16::from(-2.75).to<int>() == -3); // floor semantics

// Saturation rather than wrap-around.
static_assert(q15::from(0.9) + q15::from(0.9) == q15::max());
static_assert(-q15::min() == q15::max());

// Wrap-around when asked for.
using wrap8 = fixed<std::uint8_t, 0, overflow::wrap>;
static_assert((wrap8{250} + wrap8{10}).raw() == 4);

static_assert(sqrt(q16_16{9}) == q16_16{3});
static_assert(abs(sqrt(q16_16{2}) - q16_16::from(1.41421356)) <= q16_16::epsilon());

static_assert(lerp(q16_16{10}, q16_16{20}, q16_16::from(0.25)) == q16_16::from(12.5));

static_assert(q16_16::convert(q15::from(0.5)) == half);

constexpr sine_table<q15, 256> sine{};
static_assert(sine(0).raw() == 0);
static_assert(sine(0x4000'0000u) == q15::max()); // a quarter turn, clipped to just under 1
static_assert(sine(0xC000'0000u) == q15::from(-1.0));

} // namespace checks

} // namespace hx
