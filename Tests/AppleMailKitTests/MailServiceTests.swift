import Foundation
import Testing
@testable import AppleMailKit

@Suite("MailService")
struct MailServiceTests {

    // ─── parseEmailLines ───────────────────────────────────────────────────

    @Test("parseEmailLines parses 6-field unread format")
    func parseUnread() {
        let raw = "Lunch\talice@example.com\tFri Apr 20\tINBOX\tiCloud\tHello\n"
        let out = MailService.parseEmailLines(raw, defaultRead: false)
        #expect(out.count == 1)
        #expect(out[0].subject == "Lunch")
        #expect(out[0].sender == "alice@example.com")
        #expect(out[0].mailbox == "iCloud — INBOX")
        #expect(out[0].isRead == false)
        #expect(out[0].content == "Hello")
    }

    @Test("parseEmailLines parses 7-field search format with isRead flag")
    func parseSearchWithRead() {
        let raw = "Receipt\tbilling@ex.com\tThu\tINBOX\tGoogle\ttrue\tYour receipt\n"
            + "Offer\tads@ex.com\tWed\tPromos\tGoogle\tfalse\tLimited offer\n"
        let out = MailService.parseEmailLines(raw, defaultRead: true, includeReadField: true)
        #expect(out.count == 2)
        #expect(out[0].isRead == true)
        #expect(out[1].isRead == false)
        #expect(out[1].mailbox == "Google — Promos")
    }

    @Test("parseEmailLines fills defaults and skips malformed rows")
    func parseDefaults() {
        let raw = "short row\n"
            + "ok\tsender\tdate\tbox\tacct\t\n"  // empty body → default placeholder
            + "\n"
        let out = MailService.parseEmailLines(raw, defaultRead: false)
        #expect(out.count == 1)
        #expect(out[0].content == "[Content not available]")
    }

    // ─── Dispatch: listAccounts ────────────────────────────────────────────

    @Test("listAccounts splits newline-separated script output")
    func listAccounts() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("iCloud\nGoogle\n  \nWork\n")
        let svc = MailService(runner: runner)

        let accts = try await svc.listAccounts()

        #expect(accts == ["iCloud", "Google", "Work"])
    }

    @Test("listMailboxes rejects empty account name")
    func listMailboxesEmpty() async throws {
        let svc = MailService(runner: FakeAppleScriptRunner())
        await #expect(throws: MailServiceError.self) {
            _ = try await svc.listMailboxes(account: "  ")
        }
    }

    @Test("listMailboxes passes the account through to the script")
    func listMailboxesScoped() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("INBOX\nSent\n")
        let svc = MailService(runner: runner)

        _ = try await svc.listMailboxes(account: "Google")

        #expect(runner.calls[0].contains("name is \"Google\""))
    }

    // ─── Dispatch: search plumbing ─────────────────────────────────────────

    @Test("search returns [] immediately for empty query without running a script")
    func searchEmptyQuery() async throws {
        let runner = FakeAppleScriptRunner()
        let svc = MailService(runner: runner)

        let r = try await svc.search(query: "   ")

        #expect(r.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("search passes query, account, mailbox, and date bound into the script")
    func searchPlumbsParams() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(
            query: "invoice",
            limit: 5,
            account: "Google",
            mailbox: "Important",
            sinceDaysAgo: 30
        )

        let src = runner.calls[0]
        #expect(src.contains("subject contains \"invoice\""))
        #expect(src.contains("name is \"Google\""))
        #expect(src.contains("name is \"Important\""))
        #expect(src.contains("30 * days"))
    }

    // ─── Dispatch: send validation ─────────────────────────────────────────

    @Test("send rejects missing to/subject/body")
    func sendValidation() async throws {
        let svc = MailService(runner: FakeAppleScriptRunner())

        await #expect(throws: MailServiceError.self) {
            try await svc.send(to: "", subject: "s", body: "b")
        }
        await #expect(throws: MailServiceError.self) {
            try await svc.send(to: "a@b.com", subject: "", body: "b")
        }
        await #expect(throws: MailServiceError.self) {
            try await svc.send(to: "a@b.com", subject: "s", body: "  ")
        }
    }

    @Test("send throws when script does not return SENT")
    func sendFailure() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("FAILED")
        let svc = MailService(runner: runner)

        await #expect(throws: MailServiceError.self) {
            try await svc.send(to: "a@b.com", subject: "s", body: "b")
        }
    }

    @Test("send succeeds on SENT")
    func sendSuccess() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("SENT")
        let svc = MailService(runner: runner)

        try await svc.send(to: "a@b.com", subject: "s", body: "b")
        #expect(runner.calls.count == 1)
    }

    @Test("send wires cc and bcc into the script when provided")
    func sendCcBcc() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("SENT")
        let svc = MailService(runner: runner)

        try await svc.send(
            to: "a@b.com", subject: "s", body: "b",
            cc: "cc@b.com", bcc: "bcc@b.com"
        )

        let src = runner.calls[0]
        #expect(src.contains("cc recipient"))
        #expect(src.contains("cc@b.com"))
        #expect(src.contains("bcc recipient"))
        #expect(src.contains("bcc@b.com"))
    }
}
