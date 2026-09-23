import Foundation
@testable import MailAutomation
import Testing

/// Unit tests for `NSAppleScriptRunner`.
///
/// These run actual AppleScript through `NSAppleScript`. They do **not**
/// target other applications (no Mail, no Finder), so they require no
/// Automation permissions and are safe to run on CI.
///
/// The suite is serialized because Apple's AppleScript component manager
/// carries shared process-global state; running executions in parallel
/// interleaves their error reporting and makes failures look as if one
/// test's error leaked into another.
@Suite("NSAppleScriptRunner", .serialized)
struct NSAppleScriptRunnerTests {
    @Test("runs a trivial script and returns its scalar result as a string")
    func runsTrivialScript() async throws {
        let runner = NSAppleScriptRunner()
        // Wrap in an explicit `on run` handler — a top-level `return` is
        // rejected by NSAppleScript on some OS versions.
        let out = try await runner.run(source: """
        on run
            return "hello"
        end run
        """)
        #expect(out == "hello")
    }

    @Test("returns empty string when the script has no expressible string value")
    func runsScriptWithoutStringResult() async throws {
        let runner = NSAppleScriptRunner()
        // A script that ends without returning a string — the descriptor's
        // `stringValue` is nil so we coerce to "".
        let out = try await runner.run(source: """
        on run
            set x to {1, 2, 3}
            return x
        end run
        """)
        // `{1,2,3}` is a list descriptor; `stringValue` is nil → "".
        #expect(out.isEmpty)
    }

    @Test("throws AppleScriptError on runtime failure (division by zero)")
    func runtimeErrorThrows() async {
        let runner = NSAppleScriptRunner()
        await #expect(throws: AppleScriptError.self) {
            _ = try await runner.run(source: """
            on run
                return 1 / 0
            end run
            """)
        }
    }

    @Test("throws AppleScriptError when the source is not valid AppleScript")
    func compileErrorThrows() async {
        let runner = NSAppleScriptRunner()
        await #expect(throws: AppleScriptError.self) {
            // Nonsense tokens — NSAppleScript reports a compile failure
            // either via a nil constructor result (`.compile`) or via
            // `errorInfo` at execute time (`.runtime`). Either surfaces
            // as `AppleScriptError`.
            _ = try await runner.run(source: "@@@not@@@ valid @@@applescript@@@")
        }
    }
}

/// Thread-affinity tests for `NSAppleScriptRunner`.
///
/// `NSAppleScript` must execute on the **main thread**. A script that
/// targets another application (`tell application "Mail" …`) sends an
/// Apple Event and waits for the reply via Carbon's
/// `AEDefaultActiveProc` → `GetNextEventMatchingMask`, which pumps only
/// the *main* thread's event queue — where the reply is delivered. Off
/// the main thread the reply goes unserviced and the call stalls: ~32s
/// measured for a script that takes ~0.1s done correctly, and no return
/// at all after ten minutes inside a long-lived server process.
///
/// The tests above cannot catch this: they run self-contained scripts
/// that send no Apple Event and so succeed from any thread. These assert
/// the invariant directly, and need neither Mail.app nor an Automation
/// grant.
///
/// Carries `.serialized` to match the repo's convention for suites
/// touching `NSAppleScriptRunner`. Unlike the live suites it needs no
/// env-var gate: it never reaches the `NSAppleScript` bridge, hopping
/// only plain Swift closures through `onMainThread`, so it is safe and
/// useful on CI — where it is the sole guard against this regression.
@Suite("NSAppleScriptRunner thread affinity", .serialized)
struct NSAppleScriptRunnerThreadAffinityTests {
    @Test("script execution is confined to the main thread")
    func executesOnMainThread() async {
        let ranOnMain = await NSAppleScriptRunner.onMainThread { Thread.isMainThread }
        #expect(
            ranOnMain,
            """
            NSAppleScript must execute on the main thread — Apple Event \
            replies are delivered to the main run loop, so running it \
            elsewhere stalls every `tell application` script.
            """
        )
    }

    @Test("the result of the main-thread hop reaches the caller")
    func propagatesResult() async {
        let value = await NSAppleScriptRunner.onMainThread { 6 * 7 }
        #expect(value == 42)
    }

    @Test("errors thrown on the main thread propagate to the caller")
    func propagatesThrow() async {
        await #expect(throws: AppleScriptError.self) {
            try await NSAppleScriptRunner.onMainThread {
                throw AppleScriptError.compile("boom")
            }
        }
    }
}

/// A script whose caller has gone must not run.
///
/// `withTimeout` frees the caller and cancels the work, but the work is a
/// hop onto the main actor that `MainActor.run` does not abandon on
/// cancellation. Without a check at the head of the hop, every timed-out
/// call still ran later, in order, keeping the main actor busy and timing
/// out the calls queued behind it.
@Suite("NSAppleScriptRunner cancellation", .serialized)
struct NSAppleScriptRunnerCancellationTests {
    /// Counts calls to the pre-execution hook, which runs on the main
    /// thread immediately before `NSAppleScript` would execute.
    final class HookCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var mainThread = true
        func hit() {
            lock.withLock {
                count += 1
                mainThread = mainThread && Thread.isMainThread
            }
        }

        var hits: Int { lock.withLock { count } }
        var allOnMain: Bool { lock.withLock { mainThread } }
    }

    private let script = """
    on run
        return "ran"
    end run
    """

    @Test("a call whose task is already cancelled is dropped, not executed")
    func cancelledBeforeHopIsDropped() async {
        let runner = NSAppleScriptRunner()
        let hook = HookCounter()
        let source = script
        let task = Task { () async throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(source: source, beforeExecute: { hook.hit() })
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(hook.hits == 0)
    }

    @Test("a call cancelled while queued behind a busy main actor is dropped when its turn comes")
    func cancelledWhileQueuedIsDropped() async throws {
        let runner = NSAppleScriptRunner()
        let hook = HookCounter()
        let source = script

        // Occupy the main actor the way a slow AppleScript search does.
        let busy = Task { @MainActor in _ = usleep(400_000) }
        try await Task.sleep(for: .milliseconds(50))

        let queued = Task { () async throws -> String in
            try await runner.run(source: source, beforeExecute: { hook.hit() })
        }
        try await Task.sleep(for: .milliseconds(100))
        queued.cancel()

        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        await busy.value
        #expect(hook.hits == 0, "a script whose caller timed out must not run later")
    }

    @Test("an uncancelled call runs its hook on the main thread, then the script")
    func hookRunsOnMainBeforeScript() async throws {
        let runner = NSAppleScriptRunner()
        let hook = HookCounter()

        let out = try await runner.run(source: script, beforeExecute: { hook.hit() })

        #expect(out == "ran")
        #expect(hook.hits == 1)
        #expect(hook.allOnMain)
    }

    @Test("a hook that throws stops the script and its error reaches the caller")
    func throwingHookStopsScript() async {
        let runner = NSAppleScriptRunner()
        await #expect(throws: CancellationError.self) {
            _ = try await runner.run(source: script, beforeExecute: { throw CancellationError() })
        }
    }
}
