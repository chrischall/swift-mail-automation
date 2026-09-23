import Foundation

/// Runs AppleScript source and returns the result as a string. Swappable
/// for a fake in unit tests so services that drive Mail / Messages / Notes
/// / etc. can be exercised without a real system bridge.
///
/// We use `NSAppleScript` instead of spawning `osascript` subprocesses —
/// one less process per call and no shell-escaping concerns for the source.
public protocol AppleScriptRunner: Sendable {
    /// Execute `source` and return the scalar result as a string.
    ///
    /// - Parameter source: AppleScript source to compile and run.
    /// - Returns: The script's result, coerced to a string. Scripts that
    ///   don't yield a string (or yield no value) return `""`.
    /// - Throws: `AppleScriptError.compile` if the source can't be parsed;
    ///   `AppleScriptError.runtime` if execution fails (app not running,
    ///   Automation permission denied, script-level error, …).
    func run(source: String) async throws -> String

    /// Execute `source`, first calling `beforeExecute` at the last moment
    /// the script can still be abandoned.
    ///
    /// The hook is the runner's promise about *when* execution begins: if
    /// it returns, the script runs; if it throws, the script does not run
    /// and the error propagates. ``MailService/send(to:subject:body:cc:bcc:)``
    /// uses it to tell a send that never started (safe to report as timed
    /// out) from one that did (must be awaited — Mail may deliver it).
    ///
    /// Has a default implementation that calls the hook and then
    /// ``run(source:)``, which is correct for any runner that begins
    /// executing as soon as it is called.
    func run(
        source: String,
        beforeExecute: @escaping @Sendable () throws -> Void
    ) async throws -> String
}

public extension AppleScriptRunner {
    func run(
        source: String,
        beforeExecute: @escaping @Sendable () throws -> Void
    ) async throws -> String {
        try beforeExecute()
        return try await run(source: source)
    }
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
