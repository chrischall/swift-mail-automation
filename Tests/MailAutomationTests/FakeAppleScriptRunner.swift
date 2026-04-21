import Foundation
import MailAutomation

/// In-memory AppleScriptRunner for tests. Records every script it was asked
/// to run, and replies with a queued result or a constant.
final class FakeAppleScriptRunner: AppleScriptRunner, @unchecked Sendable {
    /// Responses to hand out in FIFO order. When empty, returns
    /// `defaultResponse`.
    var responses: [Result<String, AppleScriptError>] = []
    var defaultResponse: Result<String, AppleScriptError> = .success("")

    private(set) var calls: [String] = []

    func run(source: String) async throws -> String {
        calls.append(source)
        let r = responses.isEmpty ? defaultResponse : responses.removeFirst()
        switch r {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }

    func queue(_ result: String) {
        responses.append(.success(result))
    }
    func queueError(_ msg: String) {
        responses.append(.failure(.runtime(msg)))
    }
}
