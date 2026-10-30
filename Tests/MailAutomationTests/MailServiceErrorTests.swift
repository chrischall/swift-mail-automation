import Foundation
@testable import MailAutomation
import Synchronization
import Testing

/// The public `MailService` surface throws exactly one type,
/// ``MailServiceError``. Each failure a caller could tell apart under the old
/// untyped API — an AppleScript failure, a malformed query, an index error, a
/// timeout, a cancellation — must still be a distinct case, reachable without
/// a cast.
@Suite("MailService typed errors")
struct MailServiceErrorTests {
    private let fast = MailTimeouts(perEventSeconds: 1, operationSeconds: 0.15, sendSeconds: 0.15)

    @Test("errors are statically MailServiceError, so they match without a cast")
    func errorIsStaticallyTyped() async {
        let runner = FakeAppleScriptRunner()
        runner.queueError("Not authorized")
        let svc = MailService(runner: runner, spotlight: nil)
        do {
            _ = try await svc.listAccounts()
            Issue.record("expected a throw")
        } catch {
            // `error` is `MailServiceError` here: no `as` needed.
            guard case let .appleScript(.runtime(message)) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(message == "Not authorized")
        }
    }

    @Test("a runner failure becomes .appleScript, keeping the runner's error")
    func runnerErrorIsWrapped() async {
        let runner = FakeAppleScriptRunner()
        runner.responses = [.failure(.compile("bad source"))]
        let svc = MailService(runner: runner, spotlight: nil)
        await #expect(throws: MailServiceError.appleScript(.compile("bad source"))) {
            _ = try await svc.getUnread()
        }
    }

    @Test("a malformed query becomes .query, keeping the parser's case")
    func queryErrorIsWrapped() async {
        let svc = MailService(runner: FakeAppleScriptRunner(), spotlight: nil)
        await #expect(throws: MailServiceError.query(.empty)) {
            _ = try await svc.search(query: "   ")
        }
        await #expect(throws: MailServiceError.query(.danglingField("from"))) {
            _ = try await svc.search(query: "from:")
        }
    }

    @Test("a runner reporting cancellation surfaces as .cancelled, not as an AppleScript error")
    func runnerCancellationIsCancelled() async {
        let runner = FakeAppleScriptRunner()
        runner.responses = [.failure(.cancelled)]
        let svc = MailService(runner: runner, spotlight: nil)
        await #expect(throws: MailServiceError.cancelled) {
            _ = try await svc.listAccounts()
        }
    }

    @Test("cancelling the caller surfaces as .cancelled")
    func callerCancellationIsCancelled() async {
        let svc = MailService(runner: SleepingRunner(), spotlight: nil)
        let task = Task { try await svc.listAccounts() }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        guard case let .failure(error) = result else {
            Issue.record("expected a throw")
            return
        }
        #expect(error as? MailServiceError == .cancelled)
    }

    @Test("a timeout is still .timedOut")
    func timeoutIsTimedOut() async {
        let svc = MailService(runner: SleepingRunner(), spotlight: nil, timeouts: fast)
        await #expect(throws: MailServiceError.timedOut(operation: "mail accounts", seconds: 0.15)) {
            _ = try await svc.listAccounts()
        }
    }

    @Test("a non-Mail failure (here: the Spotlight runner) becomes .systemFailure with its description")
    func foreignErrorIsSystemFailure() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "mdfind exploded" }
        }
        let spotlight = SpotlightMailSearch(runner: { _ in throw Boom() })
        let svc = MailService(runner: FakeAppleScriptRunner(), spotlight: spotlight)
        await #expect(throws: MailServiceError.systemFailure("mdfind exploded")) {
            _ = try await svc.search(query: "x")
        }
    }

    @Test("a MailServiceError thrown by the Spotlight runner is passed through unchanged")
    func serviceErrorFromSpotlightIsUnchanged() async {
        let spotlight = SpotlightMailSearch(runner: { _ in throw MailServiceError.tooBroad("narrow it") })
        let svc = MailService(runner: FakeAppleScriptRunner(), spotlight: spotlight)
        await #expect(throws: MailServiceError.tooBroad("narrow it")) {
            _ = try await svc.search(query: "x")
        }
    }

    @Test("the README's catch-by-case patterns match without a cast")
    func readmeCatchPatterns() async {
        let svc = MailService(runner: FakeAppleScriptRunner(), spotlight: nil)
        var matched = ""
        do {
            _ = try await svc.search(query: "  ")
        } catch let .timedOut(operation, seconds) {
            matched = "timedOut \(operation) \(seconds)"
        } catch .query(.empty) {
            matched = "empty"
        } catch let .appleScript(.runtime(message)) {
            matched = "runtime \(message)"
        } catch {
            matched = "other \(error)"
        }
        #expect(matched == "empty")
    }

    @Test("wrapping maps each source error to its case")
    func wrappingTable() {
        #expect(MailServiceError(AppleScriptError.runtime("r")) == .appleScript(.runtime("r")))
        #expect(MailServiceError(AppleScriptError.cancelled) == .cancelled)
        #expect(MailServiceError(wrapping: MailQueryError.empty) == .query(.empty))
        #expect(MailServiceError(wrapping: MailIndexReaderError.sqliteError("s")) == .index(.sqliteError("s")))
        #expect(MailServiceError(wrapping: CancellationError()) == .cancelled)
        #expect(MailServiceError(wrapping: MailServiceError.invalidInput("i")) == .invalidInput("i"))
        #expect(MailServiceError(wrapping: AppleScriptError.compile("c")) == .appleScript(.compile("c")))
    }

    /// Sleeps well past any bound, honouring cancellation the way the real
    /// runner does: by reporting ``AppleScriptError/cancelled``.
    final class SleepingRunner: AppleScriptRunner, Sendable {
        func run(source _: String) async throws(AppleScriptError) -> String {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                throw .cancelled
            }
            return ""
        }
    }
}
