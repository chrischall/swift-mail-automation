import Foundation
@testable import MailAutomation
import Testing

/// A send that times out must not be sent later.
///
/// `send` used to race the whole script against `sendSeconds`. On timeout
/// the caller was told `timedOut`, but the script kept going: already
/// running, Mail still sent the message; still queued, it ran later against
/// a body file the `defer` had already deleted. A caller that retried on
/// `timedOut` then sent the email twice.
///
/// Now the bound covers only the wait for the script to *start*. A script
/// that never started is dropped, so `timedOut` means "not sent"; one that
/// started is awaited, so its real outcome is reported.
@Suite("MailService send outcome")
struct MailSendOutcomeTests {
    /// Models `NSAppleScriptRunner`: waits `queueDelay` for the main actor,
    /// drops the call if its task was cancelled meanwhile, runs the
    /// pre-execution hook, then "executes" for `execDelay`.
    final class QueueingRunner: AppleScriptRunner, @unchecked Sendable {
        let queueDelay: Duration
        let execDelay: Duration
        private let lock = NSLock()
        private var _executed = 0
        private var _bodyFileExistedAtEnd: Bool?

        init(queueDelay: Duration, execDelay: Duration) {
            self.queueDelay = queueDelay
            self.execDelay = execDelay
        }

        var executed: Int { lock.withLock { _executed } }
        var bodyFileExistedAtEnd: Bool? { lock.withLock { _bodyFileExistedAtEnd } }

        func run(source: String) async throws -> String {
            try await run(source: source, beforeExecute: {})
        }

        func run(
            source: String,
            beforeExecute: @escaping @Sendable () throws -> Void
        ) async throws -> String {
            // A sleep that ignores cancellation, like a queued main-actor hop.
            let clock = ContinuousClock()
            let until = clock.now.advanced(by: queueDelay)
            while clock.now < until {
                try? await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            try beforeExecute()
            lock.withLock { _executed += 1 }
            // Execution is synchronous in the real runner: not cancellable.
            let execUntil = clock.now.advanced(by: execDelay)
            while clock.now < execUntil {
                try? await Task.sleep(for: .milliseconds(5))
            }
            let exists = Self.bodyPath(in: source).map {
                FileManager.default.fileExists(atPath: $0)
            } ?? false
            lock.withLock { _bodyFileExistedAtEnd = exists }
            return "SENT"
        }

        static func bodyPath(in source: String) -> String? {
            guard let r = source.range(of: "read file POSIX file \"") else { return nil }
            let rest = source[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
    }

    private let timeouts = MailTimeouts(perEventSeconds: 1, operationSeconds: 0.15, sendSeconds: 0.15)

    @Test("a send still queued when the bound expires times out and is never executed")
    func queuedSendIsDropped() async throws {
        let runner = QueueingRunner(queueDelay: .milliseconds(400), execDelay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: timeouts)

        do {
            try await svc.send(to: "a@b.com", subject: "s", body: "b")
            Issue.record("expected a timeout")
        } catch let e as MailServiceError {
            guard case let .timedOut(operation, _) = e else {
                Issue.record("expected .timedOut, got \(e)")
                return
            }
            #expect(operation.contains("send"))
        }

        // Give the abandoned work time to reach the front of the queue.
        try await Task.sleep(for: .milliseconds(500))
        #expect(runner.executed == 0, "a send reported as timed out must never run later")
    }

    @Test("a send that started before the bound is awaited, so its real outcome is reported")
    func startedSendIsAwaited() async throws {
        let runner = QueueingRunner(queueDelay: .zero, execDelay: .milliseconds(400))
        let svc = MailService(runner: runner, spotlight: nil, timeouts: timeouts)

        // Longer than sendSeconds, but it started: reporting timedOut here
        // is what invited the duplicate-send retry.
        try await svc.send(to: "a@b.com", subject: "s", body: "b")

        #expect(runner.executed == 1)
    }

    @Test("the body file outlives the script that reads it")
    func bodyFileKeptUntilScriptFinishes() async throws {
        let runner = QueueingRunner(queueDelay: .zero, execDelay: .milliseconds(300))
        let svc = MailService(runner: runner, spotlight: nil, timeouts: timeouts)

        try await svc.send(to: "a@b.com", subject: "s", body: "b")

        #expect(runner.bodyFileExistedAtEnd == true)
    }

    @Test("the body file is removed once the send completes")
    func bodyFileRemovedAfterwards() async throws {
        let recorder = FakeAppleScriptRunner()
        recorder.queue("SENT")
        let svc = MailService(runner: recorder, spotlight: nil, timeouts: timeouts)

        try await svc.send(to: "a@b.com", subject: "s", body: "b")

        let path = try #require(QueueingRunner.bodyPath(in: recorder.calls[0]))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a failure before the script starts is reported as itself, not as a timeout")
    func earlyFailureIsNotATimeout() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queueError("Not authorized")
        let svc = MailService(runner: runner, spotlight: nil, timeouts: timeouts)

        await #expect(throws: AppleScriptError.runtime("Not authorized")) {
            try await svc.send(to: "a@b.com", subject: "s", body: "b")
        }
    }
}
