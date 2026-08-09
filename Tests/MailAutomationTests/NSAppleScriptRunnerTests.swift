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
@Suite("NSAppleScriptRunner thread affinity")
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
