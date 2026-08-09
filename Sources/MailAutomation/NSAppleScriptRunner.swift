import Foundation

#if canImport(OSAKit)
import OSAKit
#else
// `NSAppleScript` is declared in Foundation/CoreServices on macOS; no
// explicit import needed beyond Foundation for the bridged API.
#endif

/// Production `AppleScriptRunner` backed by `NSAppleScript`, executed on
/// the **main thread** via ``onMainThread(_:)``.
///
/// ## Why the main thread is mandatory
///
/// Every script this package emits begins `tell application "Mail"`, so
/// each one sends an Apple Event and blocks awaiting the reply.
/// AppleScript waits inside Carbon's `AEDefaultActiveProc`, which pumps
/// for that reply with `GetNextEventMatchingMask` — a call that services
/// only the **main** thread's event queue, which is also where the reply
/// is delivered.
///
/// Executed on any other thread the reply is not serviced while the
/// calling thread sits in `mach_msg`. Measured cost of getting this
/// wrong: a script that takes ~0.1s on the main thread took ~32s off it,
/// and inside a long-lived server process had still not returned after
/// ten minutes. No timeout fires and no error is raised — it simply
/// stalls.
///
/// Self-contained scripts (`return "hello"`) send no Apple Event and
/// complete from any thread, which is what makes this easy to miss.
///
/// ## Consequences for callers
///
/// ``run(source:)`` occupies the main actor for the script's duration,
/// so AppleScript calls serialize. That is correct regardless:
/// `NSAppleScript` is neither `Sendable` nor reentrant, and a single
/// application serializes the events it receives anyway.
public struct NSAppleScriptRunner: AppleScriptRunner {
    /// Construct a runner. No configuration — all state lives in the
    /// per-call `NSAppleScript` instance.
    public init() {}

    /// Hops to the main thread and runs `body` there.
    ///
    /// The single seam through which every `NSAppleScript` invocation
    /// passes, so the main-thread invariant is established in one place
    /// and can be asserted by tests without needing Mail.app or an
    /// Automation permission grant.
    static func onMainThread<T: Sendable>(
        _ body: @MainActor @Sendable () throws -> T
    ) async rethrows -> T {
        try await MainActor.run(body: body)
    }

    /// Compile and execute `source` on the main thread. Returns the
    /// scalar result as a string. Throws `AppleScriptError.compile` if
    /// the script can't be constructed, `.runtime` if AppleScript
    /// signals an error during execution (typically: application not
    /// running, user denied the automation permission prompt, or the
    /// script referenced something that doesn't exist).
    public func run(source: String) async throws -> String {
        // NSAppleScript isn't Sendable; construct + execute it entirely
        // inside the hop so its lifecycle stays on one thread.
        try await Self.onMainThread { () throws -> String in
            guard let script = NSAppleScript(source: source) else {
                throw AppleScriptError.compile("Failed to construct NSAppleScript")
            }
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo[NSAppleScript.errorMessage] as? String
                    ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
                    ?? "AppleScript error \(errorInfo[NSAppleScript.errorNumber] ?? "?")"
                throw AppleScriptError.runtime(message)
            }
            return descriptor.stringValue ?? ""
        }
    }
}
