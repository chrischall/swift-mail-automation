import Foundation
import MailAutomation
import Synchronization

/// In-memory AppleScriptRunner for tests. Records every script it was asked
/// to run, and replies with a queued result or a constant.
final class FakeAppleScriptRunner: AppleScriptRunner, Sendable {
    private struct State {
        var responses: [Result<String, AppleScriptError>] = []
        var defaultResponse: Result<String, AppleScriptError> = .success("")
        var calls: [String] = []
    }

    private let state = Mutex(State())

    /// Responses to hand out in FIFO order. When empty, returns
    /// `defaultResponse`.
    var responses: [Result<String, AppleScriptError>] {
        get { state.withLock { $0.responses } }
        set { state.withLock { $0.responses = newValue } }
    }

    var defaultResponse: Result<String, AppleScriptError> {
        get { state.withLock { $0.defaultResponse } }
        set { state.withLock { $0.defaultResponse = newValue } }
    }

    var calls: [String] { state.withLock { $0.calls } }

    func run(source: String) async throws(AppleScriptError) -> String {
        let r = state.withLock { state in
            state.calls.append(source)
            return state.responses.isEmpty ? state.defaultResponse : state.responses.removeFirst()
        }
        switch r {
        case let .success(s): return s
        case let .failure(e): throw e
        }
    }

    func queue(_ result: String) {
        state.withLock { $0.responses.append(.success(result)) }
    }

    func queueError(_ msg: String) {
        state.withLock { $0.responses.append(.failure(.runtime(msg))) }
    }
}
