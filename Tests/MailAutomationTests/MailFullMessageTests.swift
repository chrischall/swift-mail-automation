import Foundation
@testable import MailAutomation
import Testing

/// Tests for the full-body read path and pagination added alongside the
/// original preview-only surface: `messageId` on `EmailMessage`,
/// `MailService.getMessage(id:)` (complete untruncated body), and the
/// `offset` parameter on getUnread/search.
@Suite("Mail full-message get / pagination")
struct MailFullMessageTests {
    private var sep: String { MailService.detailFieldSeparator }

    // MARK: - messageId on EmailMessage + list/search parse

    @Test("EmailMessage carries a messageId (defaulting to empty)")
    func messageIdField() {
        let m = EmailMessage(
            subject: "Hi", sender: "a@x", dateSent: "today",
            content: "body", isRead: false, mailbox: "iCloud — INBOX",
            messageId: "<abc@x>"
        )
        #expect(m.messageId == "<abc@x>")
        // Back-compat: the id is optional at the call site.
        let legacy = EmailMessage(
            subject: "Hi", sender: "a@x", dateSent: "t",
            content: "b", isRead: false, mailbox: "m"
        )
        #expect(legacy.messageId == "")
    }

    @Test("parseEmailLines reads a trailing messageId when present")
    func parseWithMessageId() {
        // unread: subject,sender,date,mailbox,account,body,messageId (7)
        let unread = "Lunch\ta@x\tFri\tINBOX\tiCloud\tHello\t<id-1@x>\n"
        let u = MailService.parseEmailLines(unread, defaultRead: false)
        #expect(u.count == 1)
        #expect(u[0].content == "Hello")
        #expect(u[0].messageId == "<id-1@x>")

        // search: subject,sender,date,mailbox,account,isRead,body,messageId (8)
        let search = "R\tb@x\tThu\tINBOX\tGoogle\ttrue\tYour receipt\t<id-2@x>\n"
        let s = MailService.parseEmailLines(search, defaultRead: true, includeReadField: true)
        #expect(s[0].messageId == "<id-2@x>")
        #expect(s[0].isRead == true)
    }

    @Test("parseEmailLines still accepts the legacy id-less format")
    func parseLegacyNoMessageId() {
        let unread = "Lunch\ta@x\tFri\tINBOX\tiCloud\tHello\n"
        let u = MailService.parseEmailLines(unread, defaultRead: false)
        #expect(u.count == 1)
        #expect(u[0].content == "Hello")
        #expect(u[0].messageId == "")
    }

    // MARK: - getMessage script + parse

    @Test("getMessageScript looks up by message id and reads full content")
    func getScriptShape() {
        let s = MailService.getMessageScript(id: "<msg-42@host>")
        #expect(s.contains("tell application \"Mail\""))
        #expect(s.contains("message id is \"<msg-42@host>\""))
        #expect(s.contains("content of"))
    }

    @Test("getMessageScript escapes quotes/backslashes in the id")
    func getScriptEscapes() {
        let s = MailService.getMessageScript(id: "a\"b\\c")
        #expect(s.contains("a\\\"b\\\\c"))
    }

    @Test("getMessageScript scopes to one account when given, escaped")
    func getScriptAccountScope() {
        let s = MailService.getMessageScript(id: "<msg-1@x>", account: "Wo\"rk")
        #expect(s.contains("mailboxes of (first account whose name is \"Wo\\\"rk\")"))
        // Scoped scripts must not fall back to iterating every account.
        #expect(!s.contains("repeat with a in accounts"))
    }

    @Test("parseMessageDetail preserves newlines in the full body")
    func parseDetailBody() {
        let raw = [
            "<id-9@x>", "Quarterly", "boss@x", "Mon Apr 20",
            "INBOX", "iCloud", "false",
            "Line 1\nLine 2\n\nLine 4",
        ].joined(separator: sep)
        let d = MailService.parseMessageDetail(raw)
        #expect(d?.messageId == "<id-9@x>")
        #expect(d?.subject == "Quarterly")
        #expect(d?.mailbox == "iCloud — INBOX")
        #expect(d?.isRead == false)
        #expect(d?.body == "Line 1\nLine 2\n\nLine 4")
    }

    @Test("parseMessageDetail returns nil for too-few fields")
    func parseDetailMalformed() {
        #expect(MailService.parseMessageDetail("a\u{001E}b") == nil)
        #expect(MailService.parseMessageDetail("") == nil)
    }

    // MARK: - getMessage dispatch

    @Test("getMessage rejects an empty id without running a script")
    func getRejectsEmpty() async throws {
        let runner = FakeAppleScriptRunner()
        let svc = MailService(runner: runner, spotlight: nil)
        await #expect(throws: MailServiceError.self) {
            _ = try await svc.getMessage(id: "  ")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test("getMessage returns the full untruncated body")
    func getFullBody() async throws {
        let runner = FakeAppleScriptRunner()
        let long = String(repeating: "paragraph. ", count: 100) // ~1100 chars
        runner.queue([
            "<id-1@x>", "Essay", "a@x", "Mon", "INBOX", "iCloud", "true", long,
        ].joined(separator: sep))
        let svc = MailService(runner: runner, spotlight: nil)

        let d = try await svc.getMessage(id: "<id-1@x>")
        #expect(d.body == long)
        #expect(d.body.count > 300) // NOT the 300-char preview
        #expect(runner.calls[0].contains("content of"))
    }

    @Test("getMessage throws scriptFailure when nothing parses")
    func getParseFailure() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner, spotlight: nil)
        await #expect(throws: MailServiceError.self) {
            _ = try await svc.getMessage(id: "<nope@x>")
        }
    }

    // MARK: - pagination

    @Test("getUnread emits a message id and honors offset")
    func unreadOffset() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner, spotlight: nil)
        _ = try await svc.getUnread(limit: 5, account: nil, offset: 10)
        let src = runner.calls[0]
        #expect(src.contains("message id of msg"))
        #expect(src.contains("10")) // the offset value appears in the skip logic
    }

    @Test("search emits a message id and honors offset")
    func searchOffset() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner, spotlight: nil)
        _ = try await svc.search(query: "invoice", account: "iCloud", offset: 7)
        let src = runner.calls[0]
        #expect(src.contains("message id of msg"))
        #expect(src.contains("7"))
    }

    // MARK: - non-positive limits

    @Test("getUnread with a non-positive limit returns [] without a script", arguments: [0, -3])
    func unreadNonPositiveLimit(limit: Int) async throws {
        let runner = FakeAppleScriptRunner()
        let svc = MailService(runner: runner, spotlight: nil)
        let result = try await svc.getUnread(limit: limit)
        #expect(result.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("search with a non-positive limit returns [] without a script", arguments: [0, -3])
    func searchNonPositiveLimit(limit: Int) async throws {
        let runner = FakeAppleScriptRunner()
        let svc = MailService(runner: runner, spotlight: nil)
        let result = try await svc.search(query: "invoice", limit: limit)
        #expect(result.isEmpty)
        #expect(runner.calls.isEmpty)
    }
}
