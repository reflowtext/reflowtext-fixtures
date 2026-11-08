/**
 * @module money
 *
 * Exact money arithmetic for the Meridian merchant console.
 *
 * Amounts are held as BigInt minor units, so `0.1 + 0.2` problems cannot
 * happen, and every value carries its currency. Formatting is delegated to
 * `Intl.NumberFormat`, cached per (locale, currency).
 *
 * @example
 * import { Money, allocate } from "./money.mjs";
 *
 * const total = Money.parse("100.00", "EUR");
 * const [a, b, c] = allocate(total, [1, 1, 1]);
 * // a = 33.34 EUR, b = 33.33 EUR, c = 33.33 EUR: nothing lost, nothing invented
 */

/**
 * Minor-unit exponents for the currencies the console shows. Anything not
 * listed is assumed to use two decimal places.
 * @type {Readonly<Record<string, number>>}
 */
export const MINOR_UNITS = Object.freeze({
  JPY: 0, KRW: 0, ISK: 0, CLP: 0,
  BHD: 3, KWD: 3, JOD: 3, TND: 3,
});

/** @param {string} currency */
const exponentOf = (currency) => MINOR_UNITS[currency] ?? 2;

/** @typedef {"half-even" | "half-up" | "down"} RoundingMode */

/**
 * Divide `n` by `d` (both BigInt, d > 0) and round.
 * @param {bigint} n
 * @param {bigint} d
 * @param {RoundingMode} mode
 * @returns {bigint}
 */
function divRound(n, d, mode) {
  const negative = n < 0n;
  const abs = negative ? -n : n;
  let q = abs / d;
  const r = abs % d;
  const twice = r * 2n;

  if (mode === "half-up" && twice >= d) q += 1n;
  if (mode === "half-even" && (twice > d || (twice === d && q % 2n === 1n))) q += 1n;
  return negative ? -q : q;
}

export class CurrencyMismatchError extends Error {
  /** @param {string} a @param {string} b */
  constructor(a, b) {
    super(`Cannot combine ${a} with ${b}`);
    this.name = "CurrencyMismatchError";
  }
}

/**
 * An immutable amount of one currency.
 */
export class Money {
  /** @type {bigint} */ #minor;
  /** @type {string} */ #currency;

  /**
   * @param {bigint} minor amount in minor units (cents, pence, yen)
   * @param {string} currency ISO 4217 code
   */
  constructor(minor, currency) {
    if (typeof minor !== "bigint") throw new TypeError("minor units must be a BigInt");
    if (!/^[A-Z]{3}$/.test(currency)) throw new RangeError(`Not a currency code: ${currency}`);
    this.#minor = minor;
    this.#currency = currency;
    Object.freeze(this);
  }

  /**
   * Parse a decimal string such as `"1234.5"` or `"-0.07"`. Refuses more
   * decimal places than the currency has, rather than rounding silently.
   * @param {string} text
   * @param {string} currency
   * @returns {Money}
   */
  static parse(text, currency) {
    const match = /^(-)?(\d+)(?:\.(\d+))?$/.exec(text.trim());
    if (!match) throw new SyntaxError(`Not an amount: "${text}"`);
    const [, sign, whole, frac = ""] = match;
    const exp = exponentOf(currency);
    if (frac.length > exp) {
      throw new RangeError(`${currency} has ${exp} decimal places; got "${text}"`);
    }
    const minor = BigInt(whole + frac.padEnd(exp, "0"));
    return new Money(sign ? -minor : minor, currency);
  }

  /** @param {string} currency */
  static zero(currency) {
    return new Money(0n, currency);
  }

  get minor() { return this.#minor; }
  get currency() { return this.#currency; }
  get isZero() { return this.#minor === 0n; }
  get isNegative() { return this.#minor < 0n; }

  /** @param {Money} other */
  #check(other) {
    if (other.currency !== this.#currency) throw new CurrencyMismatchError(this.#currency, other.currency);
  }

  /** @param {Money} other */
  plus(other) {
    this.#check(other);
    return new Money(this.#minor + other.minor, this.#currency);
  }

  /** @param {Money} other */
  minus(other) {
    this.#check(other);
    return new Money(this.#minor - other.minor, this.#currency);
  }

  negate() {
    return new Money(-this.#minor, this.#currency);
  }

  /**
   * Multiply by a rate given in basis points (1 bp = 0.01 %).
   * @param {number | bigint} bps
   * @param {RoundingMode} [mode="half-even"]
   */
  timesBps(bps, mode = "half-even") {
    return new Money(divRound(this.#minor * BigInt(bps), 10_000n, mode), this.#currency);
  }

  /**
   * Convert at a decimal rate given as a string, so the rate itself is exact.
   * @param {string} rate e.g. `"1.0871"`
   * @param {string} to target currency
   * @param {RoundingMode} [mode="half-even"]
   */
  convert(rate, to, mode = "half-even") {
    const [w, f = ""] = rate.split(".");
    const rateScaled = BigInt(w + f);
    const fromExp = exponentOf(this.#currency);
    const toExp = exponentOf(to);
    // minor_to = minor_from * rate * 10^(toExp - fromExp)
    let n = this.#minor * rateScaled;
    let d = 10n ** BigInt(f.length);
    const shift = toExp - fromExp;
    if (shift > 0) n *= 10n ** BigInt(shift);
    else d *= 10n ** BigInt(-shift);
    return new Money(divRound(n, d, mode), to);
  }

  /** @param {Money} other @returns {-1 | 0 | 1} */
  compare(other) {
    this.#check(other);
    return this.#minor < other.minor ? -1 : this.#minor > other.minor ? 1 : 0;
  }

  /** @param {Money} other */
  equals(other) {
    return other.currency === this.#currency && other.minor === this.#minor;
  }

  /** A plain decimal string, e.g. `"-12.05"`. */
  toDecimalString() {
    const exp = exponentOf(this.#currency);
    const abs = this.#minor < 0n ? -this.#minor : this.#minor;
    const digits = abs.toString().padStart(exp + 1, "0");
    const whole = digits.slice(0, digits.length - exp);
    const frac = exp ? "." + digits.slice(-exp) : "";
    return (this.#minor < 0n ? "-" : "") + whole + frac;
  }

  /**
   * Format for display.
   * @param {string} [locale="en-GB"]
   * @param {{ signDisplay?: "auto" | "always" | "exceptZero" }} [options]
   */
  format(locale = "en-GB", options = {}) {
    return formatterFor(locale, this.#currency, options.signDisplay ?? "auto")
      .format(/** @type {any} */ (this.toDecimalString()));
  }

  toString() {
    return `${this.toDecimalString()} ${this.#currency}`;
  }

  toJSON() {
    return { amount: this.toDecimalString(), currency: this.#currency };
  }
}

/** @type {Map<string, Intl.NumberFormat>} */
const formatters = new Map();

/**
 * @param {string} locale
 * @param {string} currency
 * @param {"auto" | "always" | "exceptZero"} signDisplay
 */
function formatterFor(locale, currency, signDisplay) {
  const key = `${locale}|${currency}|${signDisplay}`;
  let f = formatters.get(key);
  if (!f) {
    const digits = exponentOf(currency);
    f = new Intl.NumberFormat(locale, {
      style: "currency",
      currency,
      signDisplay,
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    });
    formatters.set(key, f);
  }
  return f;
}

/**
 * Split an amount in proportion to `weights`, giving any remainder one
 * minor unit at a time to the largest shares first. The parts always sum
 * to the original amount exactly.
 *
 * @param {Money} total
 * @param {number[]} weights non-negative, at least one positive
 * @returns {Money[]}
 */
export function allocate(total, weights) {
  if (weights.length === 0 || weights.some((w) => w < 0) || !weights.some((w) => w > 0)) {
    throw new RangeError("weights must be non-negative with at least one positive");
  }
  const scaled = weights.map((w) => BigInt(Math.round(w * 1e6)));
  const sum = scaled.reduce((a, b) => a + b, 0n);
  const sign = total.minor < 0n ? -1n : 1n;
  const abs = total.minor * sign;

  const parts = scaled.map((w) => (abs * w) / sum);
  let remainder = abs - parts.reduce((a, b) => a + b, 0n);

  const order = scaled
    .map((w, i) => ({ i, rest: (abs * w) % sum }))
    .sort((a, b) => (b.rest > a.rest ? 1 : b.rest < a.rest ? -1 : a.i - b.i));
  for (let k = 0; remainder > 0n; k = (k + 1) % order.length, remainder -= 1n) {
    parts[order[k].i] += 1n;
  }
  return parts.map((p) => new Money(p * sign, total.currency));
}

/**
 * Sum a list of amounts of one currency.
 * @param {Iterable<Money>} amounts
 * @param {string} currency used when the list is empty
 */
export function sum(amounts, currency) {
  let acc = Money.zero(currency);
  for (const m of amounts) acc = acc.plus(m);
  return acc;
}

/**
 * Group amounts by currency and total each group.
 * @param {Iterable<Money>} amounts
 * @returns {Map<string, Money>}
 */
export function totalsByCurrency(amounts) {
  /** @type {Map<string, Money>} */
  const totals = new Map();
  for (const m of amounts) {
    totals.set(m.currency, (totals.get(m.currency) ?? Money.zero(m.currency)).plus(m));
  }
  return totals;
}

// Run directly (`node money.mjs`) for a quick demonstration.
if (import.meta.url === `file://${process.argv[1]}`) {
  const fee = Money.parse("249.99", "EUR").timesBps(175);
  const split = allocate(Money.parse("100.00", "EUR"), [1, 1, 1]);
  const yen = Money.parse("80.00", "EUR").convert("162.83", "JPY");

  console.log("fee on 249.99 EUR at 175 bp:", fee.toString());
  console.log("100 EUR in thirds:", split.map(String).join(" + "));
  console.log("80 EUR in yen:", yen.format("ja-JP"));
  console.log("refund shown with sign:", fee.negate().format("de-DE", { signDisplay: "always" }));
  console.log([...totalsByCurrency([fee, yen, fee])].map(([c, m]) => `${c}: ${m}`).join(", "));
}
