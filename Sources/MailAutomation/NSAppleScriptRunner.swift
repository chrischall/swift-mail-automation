import Foundation

#if canImport(OSAKit)
import OSAKit
#else
// `NSAppleScript` is declared in Foundation/CoreServices on macOS; no
// explicit import needed beyond Foundation for the bridged API.
#endif

/// Production `AppleScriptRunner` backed by `NSAppleScript`. Executes on a
/// detached Task so async callers don't block the event loop on long scripts.
public struct NSAppleScriptRunner: AppleScriptRunner {
    /// Construct a runner. No configuration — all state lives in the
    /// per-call `NSAppleScript` instance.
    public init() {}

    /// Compile and execute `source` on a detached task. Returns the
    /// scalar result as a string. Throws `AppleScriptError.compile` if
    /// the script can't be constructed, `.runtime` if AppleScript
    /// signals an error during execution (typically: application not
    /// running, user denied the automation permission prompt, or the
    /// script referenced something that doesn't exist).
    public func run(source: String) async throws -> String {
        // NSAppleScript isn't Sendable; construct + execute it entirely
        // inside a detached Task so its lifecycle stays on one thread.
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            guard let script = NSAppleScript(source: source) else {
                throw AppleScriptError.compile("Failed to construct NSAppleScript")
            }
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let msg = errorInfo[NSAppleScript.errorMessage] as? String
                    ?? errorInfo[NSAppleScript.errorBriefMessage] as? String
                    ?? "AppleScript error \(errorInfo[NSAppleScript.errorNumber] ?? "?")"
                throw AppleScriptError.runtime(msg)
            }
            return descriptor.stringValue ?? ""
        }.value
    }
}
