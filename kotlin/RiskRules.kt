package com.meridian.risk

import java.math.BigDecimal

/**
 * A small, type-safe DSL for Meridian's payment risk rules.
 *
 * Analysts write rules that read like the policy document they come from:
 *
 * ```
 * val policy = riskPolicy("eu-cards") {
 *     rule("card testing") {
 *         whenever { allOf(amount below 2.eur, cardAgeDays lessThan 1, attemptsLastHour atLeast 5) }
 *         decline("velocity")
 *     }
 * }
 * ```
 *
 * One Kotlin detail shapes the syntax: every named infix function has the
 * same precedence and they associate to the left, so `a below x and b above y`
 * would parse as `((a below x) and b) above y`. Hence [Fields.allOf] and
 * [Fields.anyOf] for lists of tests, with `and` / `or` kept for two
 * parenthesised conditions.
 *
 * The builder produces an immutable [Policy], a plain tree of [Condition]s
 * that can be evaluated, printed, and diffed between versions.
 */

// ---------------------------------------------------------------------------
// The model the DSL builds
// ---------------------------------------------------------------------------

data class Money(val amount: BigDecimal, val currency: String) : Comparable<Money> {
    override fun compareTo(other: Money): Int {
        require(currency == other.currency) { "cannot compare $currency with ${other.currency}" }
        return amount.compareTo(other.amount)
    }

    override fun toString() = "${amount.toPlainString()} $currency"
}

val Int.eur get() = Money(BigDecimal(this), "EUR")
val Int.gbp get() = Money(BigDecimal(this), "GBP")

/** Everything a rule may look at. Built once per payment attempt. */
data class Attempt(
    val amount: Money,
    val cardCountry: String,
    val ipCountry: String,
    val cardAgeDays: Int,
    val attemptsLastHour: Int,
    val merchantCategory: String,
    val isRecurring: Boolean,
)

sealed interface Decision {
    data object Allow : Decision
    data class Review(val queue: String) : Decision
    data class Challenge(val method: String = "3ds") : Decision
    data class Decline(val reason: String) : Decision
}

sealed interface Condition {
    fun test(a: Attempt): Boolean
    fun render(): String

    data class Compare<T : Comparable<T>>(
        val field: Field<T>,
        val op: Op,
        val value: T,
    ) : Condition {
        override fun test(a: Attempt): Boolean {
            val c = field.read(a).compareTo(value)
            return when (op) {
                Op.LT -> c < 0
                Op.LE -> c <= 0
                Op.EQ -> c == 0
                Op.GE -> c >= 0
                Op.GT -> c > 0
            }
        }

        override fun render() = "${field.name} ${op.symbol} $value"
    }

    data class OneOf(val field: Field<String>, val values: Set<String>) : Condition {
        override fun test(a: Attempt) = field.read(a) in values
        override fun render() = "${field.name} in ${values.sorted()}"
    }

    data class Differ(val left: Field<String>, val right: Field<String>) : Condition {
        override fun test(a: Attempt) = left.read(a) != right.read(a)
        override fun render() = "${left.name} != ${right.name}"
    }

    data class Flag(val field: Field<Boolean>) : Condition {
        override fun test(a: Attempt) = field.read(a)
        override fun render() = field.name
    }

    data class All(val parts: List<Condition>) : Condition {
        override fun test(a: Attempt) = parts.all { it.test(a) }
        override fun render() = parts.joinToString(" and ") { it.renderNested() }
    }

    data class AnyOf(val parts: List<Condition>) : Condition {
        override fun test(a: Attempt) = parts.any { it.test(a) }
        override fun render() = parts.joinToString(" or ") { it.renderNested() }
    }

    data class Not(val inner: Condition) : Condition {
        override fun test(a: Attempt) = !inner.test(a)
        override fun render() = "not ${inner.renderNested()}"
    }
}

private fun Condition.renderNested() =
    if (this is Condition.All || this is Condition.AnyOf) "(${render()})" else render()

enum class Op(val symbol: String) { LT("<"), LE("<="), EQ("=="), GE(">="), GT(">") }

class Field<T>(val name: String, val read: (Attempt) -> T)

data class Rule(val name: String, val condition: Condition, val decision: Decision)

data class Policy(val name: String, val rules: List<Rule>, val fallback: Decision) {
    /** First matching rule wins; the trace records why. */
    fun evaluate(a: Attempt): Pair<Decision, String> {
        val hit = rules.firstOrNull { it.condition.test(a) }
        return if (hit != null) hit.decision to "rule '${hit.name}'" else fallback to "no rule matched"
    }

    fun render(): String = buildString {
        appendLine("policy $name")
        rules.forEachIndexed { i, r ->
            appendLine("  ${i + 1}. ${r.name}")
            appendLine("     when ${r.condition.render()}")
            appendLine("     then ${r.decision}")
        }
        appendLine("  otherwise $fallback")
    }
}

// ---------------------------------------------------------------------------
// The DSL
// ---------------------------------------------------------------------------

@DslMarker
annotation class RiskDsl

/** Field references and comparison operators, available inside `whenever { }`. */
@RiskDsl
object Fields {
    val amount = Field("amount") { it.amount }
    val cardCountry = Field("cardCountry") { it.cardCountry }
    val ipCountry = Field("ipCountry") { it.ipCountry }
    val cardAgeDays = Field("cardAgeDays") { it.cardAgeDays }
    val attemptsLastHour = Field("attemptsLastHour") { it.attemptsLastHour }
    val merchantCategory = Field("merchantCategory") { it.merchantCategory }
    val recurring = Condition.Flag(Field("isRecurring") { it.isRecurring })

    infix fun <T : Comparable<T>> Field<T>.below(v: T): Condition = Condition.Compare(this, Op.LT, v)
    infix fun <T : Comparable<T>> Field<T>.above(v: T): Condition = Condition.Compare(this, Op.GT, v)
    infix fun <T : Comparable<T>> Field<T>.atLeast(v: T): Condition = Condition.Compare(this, Op.GE, v)
    infix fun <T : Comparable<T>> Field<T>.lessThan(v: T): Condition = Condition.Compare(this, Op.LT, v)
    infix fun <T : Comparable<T>> Field<T>.equalTo(v: T): Condition = Condition.Compare(this, Op.EQ, v)
    infix fun Field<String>.oneOf(values: Collection<String>): Condition = Condition.OneOf(this, values.toSet())
    infix fun Field<String>.differsFrom(other: Field<String>): Condition = Condition.Differ(this, other)

    infix fun Condition.and(other: Condition): Condition = Condition.All(flatten<Condition.All>(this) + flatten<Condition.All>(other))
    infix fun Condition.or(other: Condition): Condition = Condition.AnyOf(flatten<Condition.AnyOf>(this) + flatten<Condition.AnyOf>(other))
    operator fun Condition.not(): Condition = Condition.Not(this)

    fun allOf(vararg parts: Condition): Condition = Condition.All(parts.flatMap { flatten<Condition.All>(it) })
    fun anyOf(vararg parts: Condition): Condition = Condition.AnyOf(parts.flatMap { flatten<Condition.AnyOf>(it) })

    // `(a and b) and c` becomes one All of three, not All(All(a, b), c).
    private inline fun <reified G : Condition> flatten(c: Condition): List<Condition> = when (c) {
        is G -> when (c) {
            is Condition.All -> c.parts
            is Condition.AnyOf -> c.parts
            else -> listOf(c)
        }
        else -> listOf(c)
    }
}

@RiskDsl
class RuleBuilder(private val name: String) {
    private var condition: Condition? = null
    private var decision: Decision? = null

    fun whenever(block: Fields.() -> Condition) {
        check(condition == null) { "rule '$name' already has a condition" }
        condition = Fields.block()
    }

    fun then(d: Decision) {
        decision = d
    }

    fun decline(reason: String) = then(Decision.Decline(reason))
    fun review(queue: String) = then(Decision.Review(queue))
    fun challenge() = then(Decision.Challenge())

    internal fun build() = Rule(
        name,
        checkNotNull(condition) { "rule '$name' has no condition" },
        checkNotNull(decision) { "rule '$name' has no decision" },
    )
}

@RiskDsl
class PolicyBuilder(private val name: String) {
    private val rules = mutableListOf<Rule>()
    private var fallback: Decision = Decision.Allow

    fun rule(name: String, block: RuleBuilder.() -> Unit) {
        require(rules.none { it.name == name }) { "duplicate rule '$name'" }
        rules += RuleBuilder(name).apply(block).build()
    }

    fun otherwise(d: Decision) {
        fallback = d
    }

    internal fun build() = Policy(name, rules.toList(), fallback)
}

fun riskPolicy(name: String, block: PolicyBuilder.() -> Unit): Policy =
    PolicyBuilder(name).apply(block).build()

// ---------------------------------------------------------------------------
// Example
// ---------------------------------------------------------------------------

val euCards = riskPolicy("eu-cards v12") {
    rule("card testing") {
        whenever { allOf(amount below 2.eur, cardAgeDays lessThan 1, attemptsLastHour atLeast 5) }
        decline("velocity")
    }
    rule("high-risk category, new card") {
        whenever {
            allOf(
                merchantCategory oneOf listOf("electronics", "gift_cards", "travel"),
                cardAgeDays lessThan 7,
                !recurring,
            )
        }
        challenge()
    }
    rule("country mismatch on large amounts") {
        whenever { (cardCountry differsFrom ipCountry) and (amount above 500.eur) }
        review("geo")
    }
    rule("trusted recurring") {
        whenever { recurring and (attemptsLastHour lessThan 3) }
        then(Decision.Allow)
    }
    otherwise(Decision.Allow)
}

fun main() {
    print(euCards.render())
    println()

    val attempts = listOf(
        Attempt(1.eur, "DE", "DE", 0, 9, "digital_goods", false),
        Attempt(240.eur, "FR", "FR", 3, 1, "electronics", false),
        Attempt(880.eur, "IE", "PT", 400, 1, "furniture", false),
        Attempt(12.eur, "NL", "NL", 900, 1, "streaming", true),
        Attempt(64.eur, "ES", "ES", 30, 2, "books", false),
    )
    for (a in attempts) {
        val (decision, why) = euCards.evaluate(a)
        println("%-10s %-14s -> %-28s (%s)".format(a.amount, a.merchantCategory, decision, why))
    }
}
