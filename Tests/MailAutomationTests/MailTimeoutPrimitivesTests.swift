import Foundation
@testable import MailAutomation
import Synchronization
import Testing

/// Direct coverage of the concurrency primitives behind every timeout path:
/// `MailTimeoutBox`, `withTimeout`, and `ScriptStartGate`. `MailService`
/// tests reach them only through generated-script fakes.
@Suite("Timeout primitives")
struct MailTimeoutPrimitivesTests {
    // MARK: MailTimeoutBox

    @Test("a result that arrives before the continuation is delivered on attach")
    func boxResultBeforeAttach() async throws {
        let box = MailTimeoutBox<Int, MailServiceError>()
        box.resume(.success(1))
        let value = try await box.outcome().get()
        #expect(value == 1)
    }

    @Test("only the first result wins, before or after attach")
    func boxFirstResumeWins() async throws {
        let early = MailTimeoutBox<Int, MailServiceError>()
        early.resume(.success(1))
        early.resume(.success(2))
        #expect(try await early.outcome().get() == 1)

        let late = MailTimeoutBox<Int, MailServiceError>()
        async let value = late.outcome()
        // Give the attach a moment to land so the resume takes the
        // continuation path rather than the pending one.
        try await Task.sleep(for: .milliseconds(20))
        late.resume(.success(3))
        late.resume(.failure(.cancelled))
        #expect(try await value.get() == 3)
    }

    // MARK: withTimeout

    @Test("withTimeout returns the body's value when it finishes in time")
    func timeoutPassesValueThrough() async throws {
        let value = try await withTimeout(seconds: 5, operation: "op") { 42 }
        #expect(value == 42)
    }

    @Test("withTimeout rethrows the body's own error")
    func timeoutPassesErrorThrough() async {
        await #expect(throws: MailServiceError.appleScript(.runtime("boom"))) {
            try await withTimeout(seconds: 5, operation: "op") { () async throws(MailServiceError) -> Int in
                throw .appleScript(.runtime("boom"))
            }
        }
    }

    @Test("withTimeout frees the caller even when the body ignores cancellation")
    func timeoutFreesCaller() async {
        let started = ContinuousClock.now
        await #expect(throws: MailServiceError.timedOut(operation: "slow", seconds: 0.05)) {
            try await withTimeout(seconds: 0.05, operation: "slow") { () async throws(MailServiceError) -> Int in
                // A blocking, cancellation-blind body: the case the
                // first-resume-wins design exists for.
                usleep(500_000)
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .milliseconds(400))
    }

    @Test("withTimeout throws .cancelled when the caller is cancelled")
    func timeoutHonoursCallerCancellation() async {
        let task = Task {
            try await withTimeout(seconds: 5, operation: "op") { () async throws(MailServiceError) -> Int in
                try? await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        task.cancel()
        await #expect(throws: MailServiceError.cancelled) { try await task.value }
    }

    @Test("withTimeout's timer fires while the caller's actor is blocked")
    func timeoutTimerIgnoresBusyCallerActor() async throws {
        let fired = try await BlockedCaller().timerLatencyWhileBlocked(
            timeout: .milliseconds(50), blockFor: .milliseconds(600)
        )
        // A timer inheriting the caller's actor would wait out the whole
        // block (600 ms) before it could cancel the work.
        #expect(fired < .milliseconds(400), "timer fired after \(fired)")
    }

    @Test("withTimeout runs its body off the caller's actor")
    @MainActor
    func timeoutBodyLeavesCallerActor() async throws {
        let onMain = try await withTimeout(seconds: 5, operation: "op") { currentThreadIsMain() }
        #expect(!onMain)
    }

    // MARK: ScriptStartGate

    @Test("a gate abandoned before start refuses to begin")
    func gateAbandonBeforeBegin() {
        let gate = ScriptStartGate()
        #expect(gate.abandon())
        #expect(throws: AppleScriptError.cancelled) { try gate.begin() }
    }

    @Test("a gate that has begun cannot be abandoned")
    func gateBeginBeforeAbandon() throws {
        let gate = ScriptStartGate()
        try gate.begin()
        #expect(!gate.abandon())
    }

    @Test("waitUntilSettled resolves on begin and on finish")
    func gateSettles() async throws {
        let begun = ScriptStartGate()
        try begun.begin()
        await begun.waitUntilSettled()

        let finished = ScriptStartGate()
        finished.finish()
        await finished.waitUntilSettled()
    }
}

/// An actor that calls `withTimeout` and then, while that call is
/// suspended, is kept busy by a blocking job queued behind it. Under
/// `NonisolatedNonsendingByDefault` a nonisolated async function runs on
/// its caller's actor, so this is the shape that would starve a timer that
/// inherited the caller's isolation.
private actor BlockedCaller {
    func timerLatencyWhileBlocked(timeout: Duration, blockFor: Duration) async throws -> Duration {
        let start = ContinuousClock.now
        let cancelledAt = Mutex<ContinuousClock.Instant?>(nil)
        // Queued on this actor; runs as soon as the call below suspends.
        Task { self.block(for: blockFor) }
        _ = try? await withTimeout(seconds: timeout / .seconds(1), operation: "busy") {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(5))
            } onCancel: {
                cancelledAt.withLock { $0 = .now }
            }
        }
        let fired = try #require(cancelledAt.withLock { $0 })
        return fired - start
    }

    private func block(for duration: Duration) {
        usleep(useconds_t(duration / .microseconds(1)))
    }
}

/// `Thread.isMainThread` is unavailable from async contexts; read it from a
/// synchronous one.
private func currentThreadIsMain() -> Bool { Thread.isMainThread }
