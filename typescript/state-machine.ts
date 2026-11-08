/**
 * A small, fully typed finite state machine.
 *
 * States and events are discriminated unions. The transition table is typed
 * so that each state lists only the events it accepts, and each handler
 * receives the narrowed state and event: no casts, no `any`, and a missing
 * or misspelled transition is a compile error, not a runtime surprise.
 *
 * The example at the bottom models a payout at Meridian Payments, from
 * queued through retries to a final outcome.
 */

// ---------------------------------------------------------------- types --

type Tagged<K extends string = string> = { readonly type: K };

/** Pick the member of a union whose `type` is K. */
type Narrow<U extends Tagged, K extends U["type"]> = Extract<U, { type: K }>;

/** A transition either returns the next state or a state plus side effects. */
type Step<S extends Tagged, E extends Tagged> =
  | S
  | { readonly next: S; readonly effects: ReadonlyArray<Effect<E>> };

/** Side effects are data. The runner executes them; handlers stay pure. */
export type Effect<E extends Tagged> =
  | { readonly kind: "emit"; readonly event: E; readonly afterMs?: number }
  | { readonly kind: "log"; readonly level: "info" | "warn"; readonly message: string };

type Handler<S extends Tagged, E extends Tagged, SK extends S["type"], EK extends E["type"]> = (
  state: Narrow<S, SK>,
  event: Narrow<E, EK>,
) => Step<S, E>;

/**
 * The transition table: for each state, an optional handler per event.
 * States without an entry are final.
 */
export type Transitions<S extends Tagged, E extends Tagged> = {
  readonly [SK in S["type"]]?: {
    readonly [EK in E["type"]]?: Handler<S, E, SK, EK>;
  };
};

export interface Machine<S extends Tagged, E extends Tagged> {
  readonly initial: S;
  readonly transitions: Transitions<S, E>;
}

export type Outcome<S extends Tagged, E extends Tagged> =
  | { readonly ok: true; readonly state: S; readonly effects: ReadonlyArray<Effect<E>> }
  | { readonly ok: false; readonly state: S; readonly reason: "final-state" | "event-not-accepted" };

// ------------------------------------------------------------- functions --

export function defineMachine<S extends Tagged, E extends Tagged>(
  initial: S,
  transitions: Transitions<S, E>,
): Machine<S, E> {
  return Object.freeze({ initial, transitions });
}

function isWrapped<S extends Tagged, E extends Tagged>(
  step: Step<S, E>,
): step is { next: S; effects: ReadonlyArray<Effect<E>> } {
  return "next" in step;
}

/** Pure: given a state and an event, compute what happens. */
export function transition<S extends Tagged, E extends Tagged>(
  machine: Machine<S, E>,
  state: S,
  event: E,
): Outcome<S, E> {
  const table = machine.transitions[state.type as S["type"]];
  if (table === undefined) return { ok: false, state, reason: "final-state" };

  // The table is indexed by the runtime tags, so the handler matches the
  // narrowed state and event by construction; TypeScript cannot follow the
  // correlation through two indexed lookups, hence this one widening.
  const handler = table[event.type as E["type"]] as
    | ((s: S, e: E) => Step<S, E>)
    | undefined;
  if (handler === undefined) return { ok: false, state, reason: "event-not-accepted" };

  const step = handler(state, event);
  if (isWrapped(step)) return { ok: true, state: step.next, effects: step.effects };
  // Not wrapped, so it is a bare state (generic unions do not narrow by `in`).
  return { ok: true, state: step as S, effects: [] };
}

/** Which events the machine would accept in this state. Handy for UIs. */
export function acceptedEvents<S extends Tagged, E extends Tagged>(
  machine: Machine<S, E>,
  state: S,
): Array<E["type"]> {
  const table = machine.transitions[state.type as S["type"]];
  return table ? (Object.keys(table) as Array<E["type"]>) : [];
}

export function isFinal<S extends Tagged, E extends Tagged>(machine: Machine<S, E>, state: S): boolean {
  return machine.transitions[state.type as S["type"]] === undefined;
}

// --------------------------------------------------------------- runner --

export interface RunnerOptions<S extends Tagged, E extends Tagged> {
  /** Start somewhere other than the machine's initial state (e.g. restored from storage). */
  initial?: S;
  onChange?: (state: S, previous: S, event: E) => void;
  onRejected?: (state: S, event: E, reason: string) => void;
  log?: (level: "info" | "warn", message: string) => void;
  schedule?: (fn: () => void, ms: number) => unknown;
}

/**
 * Holds the current state, applies events in order, and executes effects.
 * Events emitted by effects are queued, never applied re-entrantly.
 */
export class Runner<S extends Tagged, E extends Tagged> {
  #state: S;
  #queue: E[] = [];
  #draining = false;
  readonly #history: Array<{ at: number; from: S["type"]; event: E["type"]; to: S["type"] }> = [];

  constructor(
    private readonly machine: Machine<S, E>,
    private readonly options: RunnerOptions<S, E> = {},
  ) {
    this.#state = options.initial ?? machine.initial;
  }

  get state(): S {
    return this.#state;
  }

  get history(): ReadonlyArray<{ at: number; from: S["type"]; event: E["type"]; to: S["type"] }> {
    return this.#history;
  }

  send(event: E): void {
    this.#queue.push(event);
    if (this.#draining) return;
    this.#draining = true;
    try {
      for (let next = this.#queue.shift(); next !== undefined; next = this.#queue.shift()) {
        this.#apply(next);
      }
    } finally {
      this.#draining = false;
    }
  }

  #apply(event: E): void {
    const previous = this.#state;
    const outcome = transition(this.machine, previous, event);
    if (!outcome.ok) {
      this.options.onRejected?.(previous, event, outcome.reason);
      return;
    }

    this.#state = outcome.state;
    this.#history.push({ at: Date.now(), from: previous.type, event: event.type, to: outcome.state.type });
    this.options.onChange?.(outcome.state, previous, event);

    for (const effect of outcome.effects) {
      switch (effect.kind) {
        case "log":
          this.options.log?.(effect.level, effect.message);
          break;
        case "emit":
          if (effect.afterMs && this.options.schedule) {
            this.options.schedule(() => this.send(effect.event), effect.afterMs);
          } else {
            this.#queue.push(effect.event);
          }
          break;
        default: {
          const unreachable: never = effect;
          throw new Error(`unknown effect ${JSON.stringify(unreachable)}`);
        }
      }
    }
  }
}

// ---------------------------------------------------- example: a payout --

type PayoutState =
  | { type: "queued"; batchId: string; amountMinor: number }
  | { type: "sending"; batchId: string; amountMinor: number; attempt: number }
  | { type: "waiting"; batchId: string; amountMinor: number; attempt: number; lastError: string }
  | { type: "sent"; batchId: string; railReference: string; attempts: number }
  | { type: "rejected"; batchId: string; reason: string }
  | { type: "abandoned"; batchId: string; lastError: string; attempts: number };

type PayoutEvent =
  | { type: "dispatch" }
  | { type: "railAccepted"; reference: string }
  | { type: "railFailed"; error: string; retryable: boolean }
  | { type: "retryTimerFired" }
  | { type: "operatorCancelled"; reason: string };

const MAX_ATTEMPTS = 4;
const backoffMs = (attempt: number): number => Math.min(30_000, 250 * 2 ** attempt);

export const payoutMachine = defineMachine<PayoutState, PayoutEvent>(
  { type: "queued", batchId: "", amountMinor: 0 },
  {
    queued: {
      dispatch: (s) => ({ type: "sending", batchId: s.batchId, amountMinor: s.amountMinor, attempt: 1 }),
      operatorCancelled: (s, e) => ({ type: "rejected", batchId: s.batchId, reason: e.reason }),
    },
    sending: {
      railAccepted: (s, e) => ({
        next: { type: "sent", batchId: s.batchId, railReference: e.reference, attempts: s.attempt },
        effects: [{ kind: "log", level: "info", message: `${s.batchId} sent as ${e.reference}` }],
      }),
      railFailed: (s, e) => {
        if (!e.retryable) return { type: "rejected", batchId: s.batchId, reason: e.error };
        if (s.attempt >= MAX_ATTEMPTS) {
          return {
            next: { type: "abandoned", batchId: s.batchId, lastError: e.error, attempts: s.attempt },
            effects: [{ kind: "log", level: "warn", message: `${s.batchId} gave up: ${e.error}` }],
          };
        }
        return {
          next: { ...s, type: "waiting", lastError: e.error },
          effects: [{ kind: "emit", event: { type: "retryTimerFired" }, afterMs: backoffMs(s.attempt) }],
        };
      },
    },
    waiting: {
      retryTimerFired: (s) => ({
        type: "sending",
        batchId: s.batchId,
        amountMinor: s.amountMinor,
        attempt: s.attempt + 1,
      }),
      operatorCancelled: (s, e) => ({ type: "rejected", batchId: s.batchId, reason: e.reason }),
    },
    // sent, rejected and abandoned have no entry: they are final.
  },
);

export function describe(state: PayoutState): string {
  switch (state.type) {
    case "queued":
      return `Queued: ${(state.amountMinor / 100).toFixed(2)}`;
    case "sending":
      return `Sending (attempt ${state.attempt} of ${MAX_ATTEMPTS})`;
    case "waiting":
      return `Retrying soon after: ${state.lastError}`;
    case "sent":
      return `Sent as ${state.railReference} after ${state.attempts} attempt(s)`;
    case "rejected":
      return `Rejected: ${state.reason}`;
    case "abandoned":
      return `Abandoned after ${state.attempts} attempts: ${state.lastError}`;
  }
}

// Usage:
//
//   const runner = new Runner(payoutMachine, {
//     initial: { type: "queued", batchId: "btc_7Q2M", amountMinor: 12_500 },
//     schedule: (fn, ms) => setTimeout(fn, ms),
//     onChange: (s) => console.log(describe(s)),
//   });
//   runner.send({ type: "dispatch" });
//   runner.send({ type: "railFailed", error: "503 from gateway", retryable: true });
