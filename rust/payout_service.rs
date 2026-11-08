//! Payout dispatch service for Meridian Payments.
//!
//! Sealed settlement batches arrive on a channel; the service sends each one
//! to the merchant's bank rail, retries transient failures with jittered
//! exponential backoff, and records the outcome. Rails and the outcome store
//! are traits, so the service can be exercised end to end with in-memory
//! fakes and run in production against real adapters.
//!
//! Dependencies: tokio (rt-multi-thread, macros, sync, time) only. Traits use
//! native `async fn` and return-position `impl Future`, so no macro crates.

use std::collections::HashMap;
use std::fmt;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::{mpsc, Mutex, Semaphore};
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BatchId(pub String);

impl fmt::Display for BatchId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.pad(&self.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Rail {
    Sepa,
    FasterPayments,
    Bankgiro,
}

#[derive(Debug, Clone)]
pub struct PayoutRequest {
    pub batch: BatchId,
    pub rail: Rail,
    pub account: String,
    pub amount_minor: i64,
    pub currency: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RailError {
    /// Worth retrying: timeouts, 5xx, rate limits.
    Transient(String),
    /// Retrying will not help: closed account, invalid IBAN, limit exceeded.
    Rejected(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Sent { rail_reference: String, attempts: u32 },
    Rejected { reason: String, attempts: u32 },
    GaveUp { last_error: String, attempts: u32 },
    Skipped { reason: &'static str },
}

/// A bank rail adapter. One implementation per scheme.
pub trait PayoutRail: Send + Sync + 'static {
    fn rail(&self) -> Rail;
    fn send(&self, req: &PayoutRequest) -> impl Future<Output = Result<String, RailError>> + Send;
}

/// Durable record of what happened to each batch.
pub trait OutcomeStore: Send + Sync + 'static {
    fn already_sent(&self, batch: &BatchId) -> impl Future<Output = bool> + Send;
    fn record(&self, batch: &BatchId, outcome: &Outcome) -> impl Future<Output = ()> + Send;
}

#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub max_attempts: u32,
    pub base_delay: Duration,
    pub max_delay: Duration,
    pub attempt_timeout: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 5,
            base_delay: Duration::from_millis(200),
            max_delay: Duration::from_secs(20),
            attempt_timeout: Duration::from_secs(10),
        }
    }
}

impl RetryPolicy {
    /// "Full jitter" backoff: a random delay between zero and the exponential cap.
    /// The seed keeps it deterministic per batch, so a replay sleeps the same way.
    fn delay(&self, attempt: u32, seed: u64) -> Duration {
        let cap = self.base_delay.saturating_mul(1 << attempt.min(16)).min(self.max_delay);
        let mixed = splitmix64(seed ^ u64::from(attempt));
        let fraction = (mixed >> 11) as f64 / (1u64 << 53) as f64;
        cap.mul_f64(fraction)
    }
}

fn splitmix64(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^ (x >> 31)
}

fn seed_for(batch: &BatchId) -> u64 {
    batch.0.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3))
}

pub struct PayoutService<R, S> {
    rails: HashMap<Rail, Arc<R>>,
    store: Arc<S>,
    policy: RetryPolicy,
    in_flight: Arc<Semaphore>,
}

impl<R: PayoutRail, S: OutcomeStore> PayoutService<R, S> {
    pub fn new(rails: impl IntoIterator<Item = R>, store: S, policy: RetryPolicy, concurrency: usize) -> Self {
        Self {
            rails: rails.into_iter().map(|r| (r.rail(), Arc::new(r))).collect(),
            store: Arc::new(store),
            policy,
            in_flight: Arc::new(Semaphore::new(concurrency)),
        }
    }

    /// Drain the queue until every sender is dropped, then wait for the
    /// payouts still in flight. Returns how many batches were processed.
    pub async fn run(self, mut queue: mpsc::Receiver<PayoutRequest>) -> usize {
        let this = Arc::new(self);
        let mut tasks = JoinSet::new();

        while let Some(req) = queue.recv().await {
            let permit = Arc::clone(&this.in_flight).acquire_owned().await.expect("semaphore closed");
            let svc = Arc::clone(&this);
            tasks.spawn(async move {
                let outcome = svc.dispatch(&req).await;
                svc.store.record(&req.batch, &outcome).await;
                drop(permit);
            });
        }

        let mut done = 0;
        while let Some(joined) = tasks.join_next().await {
            if let Err(panic) = joined {
                eprintln!("payout task panicked: {panic}");
            }
            done += 1;
        }
        done
    }

    async fn dispatch(&self, req: &PayoutRequest) -> Outcome {
        if req.amount_minor <= 0 {
            return Outcome::Skipped { reason: "non-positive amount is collected, not paid out" };
        }
        if self.store.already_sent(&req.batch).await {
            return Outcome::Skipped { reason: "already sent" };
        }
        let Some(rail) = self.rails.get(&req.rail) else {
            return Outcome::Skipped { reason: "no adapter configured for this rail" };
        };

        let seed = seed_for(&req.batch);
        let mut last_error = String::new();

        for attempt in 1..=self.policy.max_attempts {
            match timeout(self.policy.attempt_timeout, rail.send(req)).await {
                Ok(Ok(rail_reference)) => return Outcome::Sent { rail_reference, attempts: attempt },
                Ok(Err(RailError::Rejected(reason))) => return Outcome::Rejected { reason, attempts: attempt },
                Ok(Err(RailError::Transient(e))) => last_error = e,
                Err(_) => last_error = format!("no answer within {:?}", self.policy.attempt_timeout),
            }
            if attempt < self.policy.max_attempts {
                sleep(self.policy.delay(attempt, seed)).await;
            }
        }

        Outcome::GaveUp { last_error, attempts: self.policy.max_attempts }
    }
}

// ---------------------------------------------------------------------------
// In-memory fakes, used by the tests and by `main` as a demonstration.
// ---------------------------------------------------------------------------

pub struct ScriptedRail {
    rail: Rail,
    script: Mutex<HashMap<String, Vec<Result<String, RailError>>>>,
}

impl ScriptedRail {
    pub fn new(rail: Rail) -> Self {
        Self { rail, script: Mutex::new(HashMap::new()) }
    }

    /// Queue the answers the rail will give for an account, in order.
    pub async fn answer(&self, account: &str, replies: Vec<Result<String, RailError>>) {
        let mut replies = replies;
        replies.reverse();
        self.script.lock().await.insert(account.to_owned(), replies);
    }
}

impl PayoutRail for ScriptedRail {
    fn rail(&self) -> Rail {
        self.rail
    }

    async fn send(&self, req: &PayoutRequest) -> Result<String, RailError> {
        let mut script = self.script.lock().await;
        script
            .get_mut(&req.account)
            .and_then(Vec::pop)
            .unwrap_or_else(|| Ok(format!("{:?}-{}", self.rail, req.batch)))
    }
}

#[derive(Default, Clone)]
pub struct MemoryStore {
    pub outcomes: Arc<Mutex<HashMap<BatchId, Outcome>>>,
}

impl OutcomeStore for MemoryStore {
    async fn already_sent(&self, batch: &BatchId) -> bool {
        matches!(self.outcomes.lock().await.get(batch), Some(Outcome::Sent { .. }))
    }

    async fn record(&self, batch: &BatchId, outcome: &Outcome) {
        self.outcomes.lock().await.insert(batch.clone(), outcome.clone());
    }
}

fn request(batch: &str, account: &str, amount_minor: i64) -> PayoutRequest {
    PayoutRequest {
        batch: BatchId(batch.into()),
        rail: Rail::Sepa,
        account: account.into(),
        amount_minor,
        currency: "EUR",
    }
}

#[tokio::main]
async fn main() {
    let rail = ScriptedRail::new(Rail::Sepa);
    rail.answer("DE00-HARBOURLINE", vec![Err(RailError::Transient("503 from gateway".into())), Ok("SEPA-88213".into())])
        .await;
    rail.answer("DE00-CLOSED", vec![Err(RailError::Rejected("account closed".into()))]).await;

    let store = MemoryStore::default();
    let outcomes = Arc::clone(&store.outcomes);
    let policy = RetryPolicy { base_delay: Duration::from_millis(5), ..RetryPolicy::default() };
    let service = PayoutService::new([rail], store, policy, 4);

    let (tx, rx) = mpsc::channel(64);
    let runner = tokio::spawn(service.run(rx));

    for req in [
        request("btc_7Q2M", "DE00-HARBOURLINE", 12_500),
        request("btc_7Q2N", "DE00-CLOSED", 4_990),
        request("btc_7Q2P", "DE00-TIDEWATER", -3_150),
    ] {
        tx.send(req).await.expect("service stopped early");
    }
    drop(tx);

    let processed = runner.await.expect("service panicked");
    let mut report: Vec<_> = outcomes.lock().await.clone().into_iter().collect();
    report.sort_by(|a, b| a.0 .0.cmp(&b.0 .0));

    println!("{processed} batches processed");
    for (batch, outcome) in report {
        println!("  {batch:<10} {outcome:?}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quick() -> RetryPolicy {
        RetryPolicy { max_attempts: 3, base_delay: Duration::from_millis(1), ..RetryPolicy::default() }
    }

    #[tokio::test]
    async fn retries_transient_errors_then_succeeds() {
        let rail = ScriptedRail::new(Rail::Sepa);
        rail.answer("A", vec![Err(RailError::Transient("timeout".into())), Ok("ref-1".into())]).await;
        let svc = PayoutService::new([rail], MemoryStore::default(), quick(), 1);

        let outcome = svc.dispatch(&request("b1", "A", 100)).await;
        assert_eq!(outcome, Outcome::Sent { rail_reference: "ref-1".into(), attempts: 2 });
    }

    #[tokio::test]
    async fn rejection_is_final() {
        let rail = ScriptedRail::new(Rail::Sepa);
        rail.answer("A", vec![Err(RailError::Rejected("invalid account".into()))]).await;
        let svc = PayoutService::new([rail], MemoryStore::default(), quick(), 1);

        let outcome = svc.dispatch(&request("b1", "A", 100)).await;
        assert!(matches!(outcome, Outcome::Rejected { attempts: 1, .. }));
    }

    #[tokio::test]
    async fn gives_up_after_the_last_attempt() {
        let rail = ScriptedRail::new(Rail::Sepa);
        rail.answer("A", vec![Err(RailError::Transient("503".into())); 5]).await;
        let svc = PayoutService::new([rail], MemoryStore::default(), quick(), 1);

        let outcome = svc.dispatch(&request("b1", "A", 100)).await;
        assert_eq!(outcome, Outcome::GaveUp { last_error: "503".into(), attempts: 3 });
    }

    #[tokio::test]
    async fn a_sent_batch_is_never_sent_twice() {
        let store = MemoryStore::default();
        store.record(&BatchId("b1".into()), &Outcome::Sent { rail_reference: "r".into(), attempts: 1 }).await;
        let svc = PayoutService::new([ScriptedRail::new(Rail::Sepa)], store, quick(), 1);

        let outcome = svc.dispatch(&request("b1", "A", 100)).await;
        assert_eq!(outcome, Outcome::Skipped { reason: "already sent" });
    }

    #[test]
    fn backoff_stays_under_its_cap_and_is_deterministic() {
        let policy = RetryPolicy::default();
        for attempt in 1..10 {
            let d = policy.delay(attempt, 42);
            assert!(d <= policy.max_delay);
            assert_eq!(d, policy.delay(attempt, 42));
        }
    }
}
