import Foundation

/// A token-bucket rate limiter for calls to the Meridian Payments API.
///
/// The API allows a sustained rate with short bursts. Rather than sleeping a
/// fixed interval between requests, callers `await` a permit: the actor hands
/// tokens out as they refill, in arrival order, and cancelled waiters leave
/// the queue without taking a token with them.
///
///     let limiter = RateLimiter(rate: 25, burst: 50)
///     try await limiter.acquire()
///     let (data, _) = try await session.data(for: request)
///
/// The limiter is clock-agnostic so tests can drive time by hand.
public actor RateLimiter<C: Clock> where C.Duration == Duration {
    public struct Snapshot: Sendable, CustomStringConvertible {
        public let available: Double
        public let waiting: Int

        public var description: String {
            "\(String(format: "%.2f", available)) tokens available, \(waiting) waiting"
        }
    }

    private struct Waiter {
        let id: UInt64
        let cost: Double
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let clock: C
    private let ratePerSecond: Double
    private let capacity: Double
    private var tokens: Double
    private var lastRefill: C.Instant
    private var queue: [Waiter] = []
    private var nextID: UInt64 = 0
    private var drainTask: Task<Void, Never>?

    public init(rate ratePerSecond: Double, burst capacity: Int, clock: C) {
        precondition(ratePerSecond > 0, "rate must be positive")
        precondition(capacity >= 1, "burst must allow at least one request")
        self.clock = clock
        self.ratePerSecond = ratePerSecond
        self.capacity = Double(capacity)
        self.tokens = Double(capacity)
        self.lastRefill = clock.now
    }

    /// Wait until `cost` tokens are available, then take them.
    ///
    /// Throws `CancellationError` if the calling task is cancelled while it waits.
    public func acquire(cost: Double = 1) async throws {
        precondition(cost > 0 && cost <= capacity, "cost must be within 0..<burst")
        try Task.checkCancellation()

        refill()
        if queue.isEmpty, tokens >= cost {
            tokens -= cost
            return
        }

        let id = nextID
        nextID &+= 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Waiter(id: id, cost: cost, continuation: continuation))
                scheduleDrain()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Try to take tokens without waiting. Returns whether it succeeded.
    public func tryAcquire(cost: Double = 1) -> Bool {
        refill()
        guard queue.isEmpty, tokens >= cost else { return false }
        tokens -= cost
        return true
    }

    public var snapshot: Snapshot {
        refill()
        return Snapshot(available: tokens, waiting: queue.count)
    }

    // MARK: Internals

    private func refill() {
        let now = clock.now
        let elapsed = lastRefill.duration(to: now)
        lastRefill = now
        tokens = min(capacity, tokens + elapsed.seconds * ratePerSecond)
    }

    private func scheduleDrain() {
        guard drainTask == nil else { return }
        drainTask = Task { await self.drain() }
    }

    /// Serve waiters strictly in order, sleeping exactly until the head can go.
    private func drain() async {
        defer { drainTask = nil }

        while let head = queue.first {
            refill()
            if tokens >= head.cost {
                tokens -= head.cost
                queue.removeFirst()
                head.continuation.resume()
                continue
            }

            let deficit = head.cost - tokens
            let wait = Duration.seconds(deficit / ratePerSecond)
            do {
                try await clock.sleep(for: wait, tolerance: .milliseconds(1))
            } catch {
                return // the drain task itself was cancelled; a new acquire restarts it
            }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

extension RateLimiter where C == ContinuousClock {
    public init(rate ratePerSecond: Double, burst capacity: Int) {
        self.init(rate: ratePerSecond, burst: capacity, clock: ContinuousClock())
    }
}

private extension Duration {
    var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}

// MARK: - Using it

/// A thin client that keeps every call under the limit and retries 429s.
public actor SettlementClient {
    public enum ClientError: Error, Equatable {
        case http(status: Int)
        case exhaustedRetries
    }

    private let limiter: RateLimiter<ContinuousClock>
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let baseURL: URL

    public init(
        baseURL: URL,
        limiter: RateLimiter<ContinuousClock> = RateLimiter(rate: 25, burst: 50),
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) {
        self.baseURL = baseURL
        self.limiter = limiter
        self.send = send
    }

    public func batch(_ id: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "v2/batches/\(id)"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer REPLACE_ME", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    /// Fetch many batches concurrently; the limiter, not the caller, sets the pace.
    public func batches(_ ids: [String]) async throws -> [String: Data] {
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            for id in ids {
                group.addTask { (id, try await self.batch(id)) }
            }
            var results: [String: Data] = [:]
            for try await (id, data) in group {
                results[id] = data
            }
            return results
        }
    }

    private func perform(_ request: URLRequest, attempts: Int = 4) async throws -> Data {
        for attempt in 1...attempts {
            try await limiter.acquire()
            let (data, response) = try await send(request)

            switch response.statusCode {
            case 200..<300:
                return data
            case 429, 503:
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
                let backoff = min(retryAfter * Double(attempt), 30)
                try await Task.sleep(for: .seconds(backoff))
            default:
                throw ClientError.http(status: response.statusCode)
            }
        }
        throw ClientError.exhaustedRetries
    }
}
