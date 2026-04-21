import Foundation
import Testing
@testable import MailAutomation

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

    // ─── parseEmailLines edge cases ────────────────────────────────────────

    @Test("parseEmailLines handles empty / whitespace-only input")
    func parseEmpty() {
        #expect(MailService.parseEmailLines("", defaultRead: false).isEmpty)
        #expect(MailService.parseEmailLines("\n\n\n", defaultRead: false).isEmpty)
    }

    @Test("parseEmailLines preserves unicode")
    func parseUnicode() {
        let raw = "メッセージ 📧\tmio@ex.com\tWed\tINBOX\tGoogle\t本文\n"
        let out = MailService.parseEmailLines(raw, defaultRead: false)
        #expect(out.count == 1)
        #expect(out[0].subject == "メッセージ 📧")
        #expect(out[0].content == "本文")
    }

    @Test("parseEmailLines handles empty account name in mailbox composition")
    func parseEmptyAccount() {
        let raw = "Hi\tfrom@x\tdate\tINBOX\t\tbody\n"
        let out = MailService.parseEmailLines(raw, defaultRead: false)
        #expect(out.count == 1)
        // When account is empty, mailbox falls back to just the folder
        #expect(out[0].mailbox == "INBOX")
    }

    @Test("parseEmailLines treats unknown isRead values as false in search mode")
    func parseUnknownIsRead() {
        let raw = "Subj\tx@y\tdate\tINBOX\tGoogle\tgibberish\tbody\n"
        let out = MailService.parseEmailLines(raw, defaultRead: true, includeReadField: true)
        #expect(out.count == 1)
        #expect(out[0].isRead == false)  // anything other than "true" → false
    }

    @Test("parseEmailLines returns records in source order")
    func parseOrder() {
        let raw = (1...3).map { "S\($0)\tfrom\td\tINBOX\tGoogle\tbody\($0)\n" }.joined()
        let out = MailService.parseEmailLines(raw, defaultRead: false)
        #expect(out.map(\.subject) == ["S1", "S2", "S3"])
    }

    // ─── getUnread — more edge cases ───────────────────────────────────────

    @Test("getUnread caps the limit at 20 regardless of caller")
    func getUnreadCapsLimit() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.getUnread(limit: 999)

        // The script interpolates the cap into a `\u{2265} <N> then exit`
        // clause — we check that N is 20 (the cap), not 999.
        let src = runner.calls[0]
        #expect(src.contains("\u{2265} 20"))
        #expect(!src.contains("\u{2265} 999"))
    }

    @Test("getUnread scopes to a specific account when given")
    func getUnreadScoped() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.getUnread(limit: 5, account: "Google")

        let src = runner.calls[0]
        #expect(src.contains("first account whose name is \"Google\""))
    }

    @Test("getUnread propagates runner errors")
    func getUnreadPropagates() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queueError("Not authorized")
        let svc = MailService(runner: runner)

        await #expect(throws: AppleScriptError.self) {
            _ = try await svc.getUnread()
        }
    }

    // ─── search — backend selection ────────────────────────────────────────

    @Test("search uses AppleScript when account is provided (Spotlight doesn't know accounts)")
    func searchScopedUsesAppleScript() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        // Pass a Spotlight mock that would return something so we'd notice
        // if it were called — here the runner is the only one that should
        // fire.
        let svc = MailService(runner: runner)

        _ = try await svc.search(
            query: "invoice",
            account: "Google",
            mailbox: "INBOX"
        )

        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].contains("name is \"Google\""))
    }

    @Test("search forceBackend=.applescript ignores any Spotlight configuration")
    func searchForcesAppleScript() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(query: "x", forceBackend: .applescript)

        // AppleScript path should fire
        #expect(runner.calls.count == 1)
    }

    @Test("search forceBackend=.spotlight never falls back to AppleScript when Spotlight returns empty")
    func searchForcesSpotlight() async throws {
        // Wire a MailService with no Spotlight backend (nil) — calling
        // search(forceBackend: .spotlight) should return [] without
        // touching the runner.
        let runner = FakeAppleScriptRunner()
        let svc = MailService(runner: runner, spotlight: nil)

        let results = try await svc.search(
            query: "invoice",
            forceBackend: .spotlight
        )

        #expect(results.isEmpty)
        #expect(runner.calls.isEmpty, "should never consult AppleScript when backend is forced to spotlight")
    }

    @Test("search sinceDaysAgo is embedded in the AppleScript")
    func searchDateBound() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(query: "x", account: "iCloud", sinceDaysAgo: 45)

        let src = runner.calls[0]
        #expect(src.contains("45 * days"))
    }

    @Test("search escapes double-quotes in the query")
    func searchEscapesQuery() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(query: "she said \"hi\"", account: "iCloud")

        let src = runner.calls[0]
        #expect(src.contains("\\\"hi\\\""))
    }

    // ─── listMailboxes — more cases ────────────────────────────────────────

    @Test("listMailboxes propagates runner errors unchanged")
    func listMailboxesPropagates() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queueError("account not found")
        let svc = MailService(runner: runner)

        await #expect(throws: AppleScriptError.self) {
            _ = try await svc.listMailboxes(account: "Nonexistent")
        }
    }

    @Test("listMailboxes filters out blank lines and trims whitespace")
    func listMailboxesCleanup() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("INBOX\n   \n  Sent  \nDrafts\n\n")
        let svc = MailService(runner: runner)

        let boxes = try await svc.listMailboxes(account: "iCloud")

        #expect(boxes == ["INBOX", "Sent", "Drafts"])
    }

    // ─── send — more escaping / error cases ────────────────────────────────

    @Test("send escapes double-quotes in to/subject")
    func sendEscapes() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("SENT")
        let svc = MailService(runner: runner)

        try await svc.send(
            to: "weird\"addr@x.com",
            subject: "Re: \"Hi\"",
            body: "b"
        )

        let src = runner.calls[0]
        #expect(src.contains("weird\\\"addr@x.com"))
        #expect(src.contains("\\\"Hi\\\""))
    }

    @Test("send writes the body to a temp file so multi-line / quoted content survives")
    func sendUsesTempFile() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("SENT")
        let svc = MailService(runner: runner)

        try await svc.send(
            to: "a@b.com",
            subject: "s",
            body: "Line 1\nLine 2\n\"with quotes\""
        )

        let src = runner.calls[0]
        // Script references the POSIX file path pattern, not inlined content
        #expect(src.contains("POSIX file"))
        #expect(src.contains("read file"))
    }

    @Test("send propagates runner errors")
    func sendPropagates() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queueError("Mail not running")
        let svc = MailService(runner: runner)

        await #expect(throws: AppleScriptError.self) {
            try await svc.send(to: "a@b.com", subject: "s", body: "b")
        }
    }
}
