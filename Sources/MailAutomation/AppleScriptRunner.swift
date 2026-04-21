import Foundation

/// Runs AppleScript source and returns the result as a string. Swappable for
/// a fake in unit tests so services that drive Mail/Messages/Notes/etc.
/// can be exercised without a real system bridge.
///
/// We use `NSAppleScript` instead of spawning `osascript` subprocesses —
/// one less process per call and no shell-escaping concerns for the source.
public protocol AppleScriptRunner: Sendable {
    /// Execute `source` and return the scalar result as a string. On
    /// AppleScript runtime errors, throws `AppleScriptError.runtime`.
    func run(source: String) async throws -> String
}

/// Errors surfaced by an `AppleScriptRunner` execution.
public enum AppleScriptError: Error, Equatable, Sendable {
    /// The script executed but AppleScript itself signaled an error (e.g.
    /// application not running, permission denied). Message is from the
    /// `NSAppleScriptErrorMessage` key.
    case runtime(String)
    /// The script couldn't be constructed (syntax error, etc).
    case compile(String)
}
