import Foundation
import Synchronization

/// Timeout bounds applied to Mail.app work.
///
/// Two layers, because one is not enough:
///
/// 1. **`with timeout of N seconds`** inside the AppleScript, which bounds
///    each individual Apple Event. Without it AppleScript's implicit 60 s
///    default applies — and 60 s per event, across 28 Gmail mailboxes, is
///    a 28-minute script that no caller asked for.
/// 2. **``withTimeout(seconds:operation:_:)``** around the whole call, so
///    the *caller* is freed even when the script ignores its own bound.
///    `NSAppleScript.executeAndReturnError` is a synchronous C call that
///    cannot be cancelled, so this frees the request handler, not the work.
public struct MailTimeouts: Sendable, Equatable {
    /// Per-Apple-Event bound written into every generated script.
    ///
    /// Deliberately well under AppleScript's 60 s default: a single event
    /// that takes longer than this against Mail is not going to succeed on
    /// a retry either, and every second spent waiting is a second Mail
    /// spends accumulating abandoned work.
    public var perEventSeconds: Int

    /// Whole-operation bound for a list/search/get.
    public var operationSeconds: Double

    /// Bound for a send. Higher than a read: an SMTP handshake
    /// legitimately takes longer than an index lookup, and a half-sent
    /// message is worse than a slow one.
    ///
    /// Applied per Apple Event inside the script, and in Swift only to the
    /// wait for the script to *start*: a send that has started is awaited
    /// rather than abandoned, because Mail may still deliver it and a
    /// caller told `timedOut` would retry and send it twice.
    public var sendSeconds: Double

    public init(
        perEventSeconds: Int = 20,
        operationSeconds: Double = 45,
        sendSeconds: Double = 90
    ) {
        self.perEventSeconds = perEventSeconds
        self.operationSeconds = operationSeconds
        self.sendSeconds = sendSeconds
    }

    /// The bounds used unless a caller overrides them. Tests dial these
    /// right down so the timeout paths are exercised in milliseconds.
    public static let `default` = MailTimeouts()

    /// Wraps AppleScript source in `with timeout of N seconds`.
    ///
    /// Applied at the outermost level of the script's top-level statements,
    /// so it covers every event they send. Handler definitions (`on name(…)`
    /// … `end name`) are moved after the block: AppleScript can't define a
    /// handler inside one, and a script wrapped whole fails to compile
    /// ("Expected "end" but found "on"", -2741), so every call through it
    /// fails. The handlers this package generates only reshape text and
    /// send no Apple Events.
    func bound(_ source: String, seconds: Int? = nil) -> String {
        let lines = source.components(separatedBy: "\n")
        let firstHandler = lines.firstIndex(where: Self.isHandlerDefinition) ?? lines.count
        let statements = lines[..<firstHandler].joined(separator: "\n")
        let handlers = lines[firstHandler...].joined(separator: "\n")
        return """
        with timeout of \(seconds ?? perEventSeconds) seconds
        \(statements)
        end timeout
        \(handlers)
        """
    }

    /// Whether a line opens a handler definition (`on sanitize(s)`), as
    /// opposed to an `on error` clause inside a `try`.
    private static func isHandlerDefinition(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^on \w+\("#, options: .regularExpression) != nil
    }
}

/// First-resume-wins handoff between the work, the timer, and cancellation.
///
/// Holds whichever arrives first — a result before the caller attached its
/// continuation, or a continuation waiting for a result — and lets exactly
/// one resume through.
///
/// Typed on `Failure`: the outcome travels as a `Result` through a
/// non-throwing continuation, because a checked continuation can only throw
/// `any Error`.
final class MailTimeoutBox<T: Sendable, Failure: Error>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Result<T, Failure>, Never>?
        var pending: Result<T, Failure>?
        var finished = false
    }

    private let state = Mutex(State())

    func attach(_ c: CheckedContinuation<Result<T, Failure>, Never>) {
        let pending: Result<T, Failure>? = state.withLock { state in
            guard let pending = state.pending else {
                state.continuation = c
                return nil
            }
            state.finished = true
            return pending
        }
        if let pending {
            c.resume(returning: pending)
        }
    }

    func resume(_ result: Result<T, Failure>) {
        let waiter: CheckedContinuation<Result<T, Failure>, Never>? = state.withLock { state in
            guard !state.finished else { return nil }
            guard let c = state.continuation else {
                // The timer can fire as the work returns, so a later producer
                // must not overwrite the first result.
                if state.pending == nil {
                    state.pending = result
                }
                return nil
            }
            state.finished = true
            state.continuation = nil
            return c
        }
        waiter?.resume(returning: result)
    }

    /// Suspends until the first result arrives. Not cancellation-aware: a
    /// caller that must react to cancellation resumes the box itself.
    func outcome() async -> Result<T, Failure> {
        await withCheckedContinuation { attach($0) }
    }
}

/// Runs `body`, throwing ``MailServiceError/timedOut(operation:seconds:)``
/// if it hasn't finished within `seconds`, and
/// ``MailServiceError/cancelled`` if the caller is cancelled first.
///
/// Deliberately **not** built on `withThrowingTaskGroup`: a group awaits
/// every child before it unwinds, so a body that can't observe cancellation
/// gets waited out in full and the timeout becomes decorative for exactly
/// the case it exists to handle. Racing through a first-resume-wins box
/// returns the moment either side settles.
///
/// The consequence is that this is unstructured — on timeout the work keeps
/// running, detached, until whatever it's blocked in returns. That is the
/// intended trade: it frees the *caller* rather than pretending a
/// synchronous Apple Event can be aborted.
///
/// ## Isolation
///
/// The function itself is `nonisolated(nonsending)`: it runs on the caller's
/// actor only to set up the race and then suspends, which frees that actor.
/// The work, the timer and `body` are `@concurrent` and never run there.
/// That is load-bearing: a caller's actor (often the main actor) can be
/// blocked — by `NSAppleScriptRunner` executing a script on it, for one —
/// and a timer queued behind that block could not fire until it ended,
/// which is exactly when a timeout is no longer needed.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: String,
    _ body: @escaping @Sendable @concurrent () async throws(MailServiceError) -> T
) async throws(MailServiceError) -> T {
    let box = MailTimeoutBox<T, MailServiceError>()

    let work = Task { @concurrent in
        do throws(MailServiceError) { try await box.resume(.success(body())) }
        catch { box.resume(.failure(error)) }
    }

    let timer = Task { @concurrent in
        // Cancelled (below) once the caller has its answer; a cancelled
        // sleep throws, so a timer that lost the race never reports.
        try await Task.sleep(for: .seconds(seconds))
        box.resume(.failure(.timedOut(operation: operation, seconds: seconds)))
        work.cancel()
    }
    defer { timer.cancel() }

    return try await withTaskCancellationHandler {
        await box.outcome()
    } onCancel: {
        work.cancel()
        box.resume(.failure(.cancelled))
    }.get()
}

/// Records whether a script has started executing, so a caller whose bound
/// expired can tell "never ran, and now never will" from "running — the
/// outcome is still coming".
///
/// Passed to a runner as its `beforeExecute` hook via ``begin()``. Start
/// and abandonment are decided under one lock, so exactly one wins: either
/// the script starts and the caller must await it, or the caller abandons
/// it and the hook throws, so it never runs.
final class ScriptStartGate: Sendable {
    private enum State { case waiting, started, abandoned }

    private let state = Mutex(State.waiting)
    /// Resolves when the script starts, or when the work ends without ever
    /// starting (a failure before execution), so a waiter never hangs.
    private let settled = MailTimeoutBox<Void, Never>()

    /// The runner's pre-execution hook. Throws
    /// ``AppleScriptError/cancelled`` if the caller abandoned the script
    /// first.
    func begin() throws(AppleScriptError) {
        try state.withLock { state throws(AppleScriptError) in
            guard state == .waiting else { throw .cancelled }
            state = .started
        }
        settled.resume(.success(()))
    }

    /// Called when the work ends, however it ends.
    func finish() {
        settled.resume(.success(()))
    }

    /// Abandons the script if it hasn't started. Returns `true` when the
    /// script is guaranteed never to run, `false` when it already started.
    func abandon() -> Bool {
        state.withLock { state in
            if state == .waiting {
                state = .abandoned
            }
            return state == .abandoned
        }
    }

    /// Suspends until the script starts or the work ends.
    func waitUntilSettled() async {
        _ = await settled.outcome()
    }
}
