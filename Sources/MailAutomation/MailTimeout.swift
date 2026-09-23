import Foundation

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
    /// Applied at the outermost level so it covers every event the script
    /// sends, including ones inside handlers it calls.
    func bound(_ source: String, seconds: Int? = nil) -> String {
        """
        with timeout of \(seconds ?? perEventSeconds) seconds
        \(source)
        end timeout
        """
    }
}

/// First-resume-wins handoff between the work, the timer, and cancellation.
///
/// Holds whichever arrives first — a result before the caller attached its
/// continuation, or a continuation waiting for a result — and lets exactly
/// one resume through.
final class MailTimeoutBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var finished = false

    func attach(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            finished = true
            lock.unlock()
            c.resume(with: pending)
            return
        }
        continuation = c
        lock.unlock()
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        guard let c = continuation else {
            // The timer can fire as the work returns, so a later producer
            // must not overwrite the first result.
            if pending == nil {
                pending = result
            }
            lock.unlock()
            return
        }
        finished = true
        continuation = nil
        lock.unlock()
        c.resume(with: result)
    }
}

/// Runs `body`, throwing ``MailServiceError/timedOut(operation:seconds:)``
/// if it hasn't finished within
/// `seconds`.
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
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = MailTimeoutBox<T>()

    let work = Task {
        do { try await box.resume(.success(body())) }
        catch { box.resume(.failure(error)) }
    }

    let timer = DispatchWorkItem {
        box.resume(.failure(MailServiceError.timedOut(operation: operation, seconds: seconds)))
        work.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    defer { timer.cancel() }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { box.attach($0) }
    } onCancel: {
        work.cancel()
        box.resume(.failure(CancellationError()))
    }
}

/// Records whether a script has started executing, so a caller whose bound
/// expired can tell "never ran, and now never will" from "running — the
/// outcome is still coming".
///
/// Passed to a runner as its `beforeExecute` hook via ``begin()``. Start
/// and abandonment are decided under one lock, so exactly one wins: either
/// the script starts and the caller must await it, or the caller abandons
/// it and the hook throws, so it never runs.
final class ScriptStartGate: @unchecked Sendable {
    private enum State { case waiting, started, abandoned }

    private let lock = NSLock()
    private var state = State.waiting
    /// Resolves when the script starts, or when the work ends without ever
    /// starting (a failure before execution), so a waiter never hangs.
    private let settled = MailTimeoutBox<Void>()

    /// The runner's pre-execution hook. Throws `CancellationError` if the
    /// caller abandoned the script first.
    func begin() throws {
        try lock.withLock {
            guard state == .waiting else { throw CancellationError() }
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
        lock.withLock {
            if state == .waiting {
                state = .abandoned
            }
            return state == .abandoned
        }
    }

    /// Suspends until the script starts or the work ends.
    func waitUntilSettled() async throws {
        try await withCheckedThrowingContinuation { settled.attach($0) }
    }
}
