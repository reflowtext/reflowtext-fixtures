import java.math.BigDecimal;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Objects;
import java.util.Optional;

/**
 * The lifecycle of a Meridian payment, modelled with sealed interfaces,
 * records and pattern-matching {@code switch}.
 *
 * <p>Every state is a record that carries exactly the data that exists in
 * that state: an {@link Authorized} payment has an authorisation code, a
 * {@link Created} one cannot. Every event is a record too. The transition
 * function is a single exhaustive {@code switch} over (state, event) pairs;
 * adding a state or an event without handling it is a compile error, not
 * a production incident.
 *
 * <p>Run with {@code java PaymentStateMachine.java} (Java 21+).
 */
public final class PaymentStateMachine {

    // ------------------------------------------------------------------
    // Values
    // ------------------------------------------------------------------

    public record Money(BigDecimal amount, String currency) {
        public Money {
            Objects.requireNonNull(amount);
            if (amount.signum() < 0) {
                throw new IllegalArgumentException("negative amount: " + amount);
            }
            if (!currency.matches("[A-Z]{3}")) {
                throw new IllegalArgumentException("not an ISO 4217 code: " + currency);
            }
        }

        public static Money of(String amount, String currency) {
            return new Money(new BigDecimal(amount), currency);
        }

        public Money minus(Money other) {
            requireSameCurrency(other);
            return new Money(amount.subtract(other.amount), currency);
        }

        public boolean exceeds(Money other) {
            requireSameCurrency(other);
            return amount.compareTo(other.amount) > 0;
        }

        private void requireSameCurrency(Money other) {
            if (!currency.equals(other.currency)) {
                throw new IllegalArgumentException(currency + " vs " + other.currency);
            }
        }

        @Override
        public String toString() {
            return amount.toPlainString() + " " + currency;
        }
    }

    // ------------------------------------------------------------------
    // States
    // ------------------------------------------------------------------

    public sealed interface State permits Created, Authorized, Captured, PartiallyRefunded,
            Refunded, Declined, Voided, Disputed {

        String paymentId();

        default boolean isTerminal() {
            return switch (this) {
                case Refunded r -> true;
                case Declined d -> true;
                case Voided v -> true;
                default -> false;
            };
        }
    }

    public record Created(String paymentId, Money amount, Instant at) implements State {}

    public record Authorized(String paymentId, Money amount, String authCode, Instant expiresAt)
            implements State {}

    public record Captured(String paymentId, Money captured, Instant at) implements State {}

    public record PartiallyRefunded(String paymentId, Money captured, Money refunded) implements State {
        Money remaining() {
            return captured.minus(refunded);
        }
    }

    public record Refunded(String paymentId, Money total) implements State {}

    public record Declined(String paymentId, String reason) implements State {}

    public record Voided(String paymentId, Instant at) implements State {}

    public record Disputed(String paymentId, Money atStake, String reasonCode, State before)
            implements State {}

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    public sealed interface Event permits Authorize, Decline, Capture, Refund, Cancel, OpenDispute,
            ResolveDispute {}

    public record Authorize(String authCode, Duration validFor) implements Event {}

    public record Decline(String reason) implements Event {}

    public record Capture(Optional<Money> amount) implements Event {}

    public record Refund(Money amount) implements Event {}

    public record Cancel() implements Event {}

    public record OpenDispute(String reasonCode) implements Event {}

    public enum Outcome { WON, LOST }

    public record ResolveDispute(Outcome outcome) implements Event {}

    /** A transition that the current state does not allow. */
    public static final class IllegalTransition extends RuntimeException {
        IllegalTransition(State state, Event event, String why) {
            super("%s in %s: %s".formatted(event.getClass().getSimpleName(),
                    state.getClass().getSimpleName(), why));
        }
    }

    // ------------------------------------------------------------------
    // Transition function
    // ------------------------------------------------------------------

    public static State apply(State state, Event event, Instant now) {
        return switch (state) {
            case Created c -> switch (event) {
                case Authorize a -> new Authorized(c.paymentId(), c.amount(), a.authCode(),
                        now.plus(a.validFor()));
                case Decline d -> new Declined(c.paymentId(), d.reason());
                default -> throw new IllegalTransition(state, event, "not yet authorised");
            };

            case Authorized a -> switch (event) {
                case Capture cap when now.isAfter(a.expiresAt()) ->
                        throw new IllegalTransition(state, event, "authorisation expired at " + a.expiresAt());
                case Capture cap -> {
                    Money amount = cap.amount().orElse(a.amount());
                    if (amount.exceeds(a.amount())) {
                        throw new IllegalTransition(state, event,
                                "capture %s exceeds authorised %s".formatted(amount, a.amount()));
                    }
                    yield new Captured(a.paymentId(), amount, now);
                }
                case Cancel c -> new Voided(a.paymentId(), now);
                default -> throw new IllegalTransition(state, event, "capture or cancel first");
            };

            case Captured c -> switch (event) {
                case Refund r -> refund(c.paymentId(), c.captured(), r.amount(), state, event);
                case OpenDispute d -> new Disputed(c.paymentId(), c.captured(), d.reasonCode(), c);
                default -> throw new IllegalTransition(state, event, "already captured");
            };

            case PartiallyRefunded p -> switch (event) {
                case Refund r -> {
                    if (r.amount().exceeds(p.remaining())) {
                        throw new IllegalTransition(state, event,
                                "only %s left to refund".formatted(p.remaining()));
                    }
                    Money total = new Money(p.refunded().amount().add(r.amount().amount()),
                            p.refunded().currency());
                    yield total.amount().compareTo(p.captured().amount()) == 0
                            ? new Refunded(p.paymentId(), total)
                            : new PartiallyRefunded(p.paymentId(), p.captured(), total);
                }
                case OpenDispute d -> new Disputed(p.paymentId(), p.remaining(), d.reasonCode(), p);
                default -> throw new IllegalTransition(state, event, "partially refunded");
            };

            case Disputed d -> switch (event) {
                case ResolveDispute(Outcome outcome) when outcome == Outcome.WON -> d.before();
                case ResolveDispute r -> new Refunded(d.paymentId(), d.atStake());
                default -> throw new IllegalTransition(state, event, "dispute in progress");
            };

            case Refunded r -> throw new IllegalTransition(state, event, "payment is closed");
            case Declined r -> throw new IllegalTransition(state, event, "payment is closed");
            case Voided r -> throw new IllegalTransition(state, event, "payment is closed");
        };
    }

    private static State refund(String id, Money captured, Money amount, State state, Event event) {
        if (amount.exceeds(captured)) {
            throw new IllegalTransition(state, event, "refund exceeds capture");
        }
        return amount.amount().compareTo(captured.amount()) == 0
                ? new Refunded(id, amount)
                : new PartiallyRefunded(id, captured, amount);
    }

    /** One line a human can read, for logs and the dashboard. */
    public static String describe(State s) {
        return switch (s) {
            case Created(var id, var amount, var at) -> "%s created for %s".formatted(id, amount);
            case Authorized(var id, var amount, var code, var exp) ->
                    "%s authorised %s (code %s)".formatted(id, amount, code);
            case Captured(var id, var amount, var at) -> "%s captured %s".formatted(id, amount);
            case PartiallyRefunded p -> "%s refunded %s, %s remaining".formatted(
                    p.paymentId(), p.refunded(), p.remaining());
            case Refunded(var id, var total) -> "%s fully refunded (%s)".formatted(id, total);
            case Declined(var id, var reason) -> "%s declined: %s".formatted(id, reason);
            case Voided(var id, var at) -> "%s voided".formatted(id);
            case Disputed(var id, var stake, var code, var before) ->
                    "%s disputed (%s), %s at stake".formatted(id, code, stake);
        };
    }

    // ------------------------------------------------------------------
    // Demo
    // ------------------------------------------------------------------

    public static void main(String[] args) {
        Instant t = Instant.parse("2026-03-13T09:41:00Z");
        State s = new Created("pay_7Qd1A9", Money.of("120.00", "EUR"), t);

        List<Event> script = List.of(
                new Authorize("483920", Duration.ofDays(7)),
                new Capture(Optional.of(Money.of("110.00", "EUR"))),
                new Refund(Money.of("30.00", "EUR")),
                new Refund(Money.of("90.00", "EUR")),      // too much: rejected
                new OpenDispute("4853"),
                new ResolveDispute(Outcome.WON),
                new Refund(Money.of("80.00", "EUR")),
                new Cancel()                                // closed: rejected
        );

        System.out.println("  " + describe(s));
        for (Event e : script) {
            t = t.plus(Duration.ofHours(5));
            try {
                s = apply(s, e, t);
                System.out.println("  " + describe(s) + (s.isTerminal() ? "  [closed]" : ""));
            } catch (IllegalTransition ex) {
                System.out.println("! " + ex.getMessage());
            }
        }
    }
}
