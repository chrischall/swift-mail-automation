import Foundation
@testable import MailAutomation
import Testing

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
            + "ok\tsender\tdate\tbox\tacct\t\n" // empty body → default placeholder
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
        #expect(out[0].isRead == false) // anything other than "true" → false
    }

    @Test("parseEmailLines returns records in source order")
    func parseOrder() {
        let raw = (1 ... 3).map { "S\($0)\tfrom\td\tINBOX\tGoogle\tbody\($0)\n" }.joined()
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

    // ─── search — Spotlight-success path ───────────────────────────────────

    /// Shared mdfind output used by the Spotlight-branch tests.
    private static let mdfindOneHit = """
    /U/me/Library/Mail/V10/A/INBOX.mbox/u/Data/0/Messages/1.emlx \
    kMDItemSubject = "Invoice" \
    kMDItemAuthors = ("billing@x.com") \
    kMDItemContentCreationDate = 2026-04-01 00:00:00 +0000
    """

    @Test("search returns Spotlight hits without running AppleScript when unscoped and Spotlight has results")
    func searchUsesSpotlightWhenAvailable() async throws {
        let runner = FakeAppleScriptRunner()
        let spotlight = SpotlightMailSearch(runner: { _ in Self.mdfindOneHit })
        let svc = MailService(runner: runner, spotlight: spotlight)

        let results = try await svc.search(query: "invoice")

        #expect(results.count == 1)
        #expect(results[0].subject == "Invoice")
        #expect(runner.calls.isEmpty, "AppleScript should not run when Spotlight found a hit")
    }

    @Test("search falls back to AppleScript when Spotlight returns empty")
    func searchFallsBackToAppleScriptOnEmptySpotlight() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("Fallback\tf@x.com\tWed\tINBOX\tGoogle\ttrue\tbody\n")
        let spotlight = SpotlightMailSearch(runner: { _ in "" })
        let svc = MailService(runner: runner, spotlight: spotlight)

        let results = try await svc.search(query: "invoice")

        #expect(runner.calls.count == 1, "AppleScript fallback must fire when Spotlight yields nothing")
        #expect(results.count == 1)
        #expect(results[0].subject == "Fallback")
    }

    @Test("search forceBackend=.spotlight returns Spotlight hits and skips AppleScript entirely")
    func searchForcesSpotlightWithHits() async throws {
        let runner = FakeAppleScriptRunner()
        let spotlight = SpotlightMailSearch(runner: { _ in Self.mdfindOneHit })
        let svc = MailService(runner: runner, spotlight: spotlight)

        let results = try await svc.search(query: "invoice", forceBackend: .spotlight)

        #expect(results.count == 1)
        #expect(runner.calls.isEmpty)
    }

    // ─── getUnread — empty-string account coerces to unscoped ──────────────

    @Test("getUnread treats an empty-string account the same as nil (all accounts)")
    func getUnreadEmptyAccount() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.getUnread(limit: 5, account: "")

        let src = runner.calls[0]
        // Unscoped path sets `acctList to accounts`; scoped would embed a
        // `first account whose name is "..."` clause.
        #expect(src.contains("set acctList to accounts"))
        #expect(!src.contains("first account whose name is"))
    }

    // ─── search — misc scope + arg plumbing ────────────────────────────────

    @Test("search with only mailbox (no account) still bypasses Spotlight")
    func searchMailboxOnlyBypassesSpotlight() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        // Spotlight would have returned a hit — but the mailbox-scope should
        // force the AppleScript path, so Spotlight is never consulted.
        let spotlight = SpotlightMailSearch(runner: { _ in Self.mdfindOneHit })
        let svc = MailService(runner: runner, spotlight: spotlight)

        _ = try await svc.search(query: "x", mailbox: "INBOX")

        #expect(runner.calls.count == 1, "AppleScript must run when mailbox scope is set")
    }

    @Test("search escapes double-quotes in the account name")
    func searchEscapesAccount() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(query: "q", account: "Work \"Tmp\"")

        let src = runner.calls[0]
        #expect(src.contains("\\\"Tmp\\\""))
    }

    @Test("search escapes double-quotes in the mailbox name")
    func searchEscapesMailbox() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(query: "q", account: "Google", mailbox: "Weird \"Box\"")

        let src = runner.calls[0]
        #expect(src.contains("\\\"Box\\\""))
    }

    // ─── listMailboxes — escapes account quotes too ────────────────────────

    @Test("listMailboxes escapes double-quotes in the account name")
    func listMailboxesEscapes() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.listMailboxes(account: "Weird \"Name\"")

        let src = runner.calls[0]
        #expect(src.contains("\\\"Name\\\""))
    }

    // ─── Backslash escaping (AppleScript injection hardening) ──────────────
    //
    // A field ending in `\` — or containing `\"` — must not break out of the
    // double-quoted AppleScript string literal. The escaper doubles
    // backslashes *before* escaping quotes, so a trailing `\` becomes `\\`
    // (an escaped backslash) rather than escaping the closing quote.

    /// Single backslash, as its own constant to keep the byte-counting sane.
    private static let bs = "\\"

    @Test("escapeForAppleScript doubles backslashes before escaping quotes")
    func escaperBackslashThenQuote() {
        let bs = MailServiceTests.bs
        let q = "\""
        // Input `a\"b` (backslash then quote) → `a\\\"b`.
        #expect(
            MailService.escapeForAppleScript("a" + bs + q + "b")
                == "a" + bs + bs + bs + q + "b"
        )
        // Trailing backslash doubles: `path\` → `path\\`.
        #expect(MailService.escapeForAppleScript("path" + bs) == "path" + bs + bs)
        // Plain quotes still escape: `say "hi"` → `say \"hi\"`.
        #expect(
            MailService.escapeForAppleScript("say " + q + "hi" + q)
                == "say " + bs + q + "hi" + bs + q
        )
        // Plain text is untouched.
        #expect(MailService.escapeForAppleScript("plain") == "plain")
    }

    @Test("send escapes a trailing backslash in the subject so it stays inside the literal")
    func sendEscapesTrailingBackslash() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("SENT")
        let svc = MailService(runner: runner)
        let bs = MailServiceTests.bs

        try await svc.send(to: "a@b.com", subject: "danger" + bs, body: "b")

        let src = runner.calls[0]
        // Correctly escaped: subject:"danger\\"  (doubled backslash, quote intact).
        #expect(src.contains("subject:\"danger" + bs + bs + "\""))
    }

    @Test("send escapes backslash-then-quote in a recipient address")
    func sendEscapesBackslashQuoteRecipient() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("SENT")
        let svc = MailService(runner: runner)
        let bs = MailServiceTests.bs

        // to = a\"@b.com → escaped a\\\"@b.com
        try await svc.send(to: "a" + bs + "\"@b.com", subject: "s", body: "b")

        let src = runner.calls[0]
        #expect(src.contains("a" + bs + bs + bs + "\"@b.com"))
    }

    @Test("search escapes a trailing backslash in the query")
    func searchEscapesTrailingBackslash() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)
        let bs = MailServiceTests.bs

        _ = try await svc.search(query: "inv" + bs, account: "iCloud")

        let src = runner.calls[0]
        // subject contains "inv\\"  — doubled backslash keeps the literal closed.
        #expect(src.contains("subject contains \"inv" + bs + bs + "\""))
    }

    @Test("getUnread escapes a trailing backslash in the account name")
    func getUnreadEscapesTrailingBackslash() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)
        let bs = MailServiceTests.bs

        _ = try await svc.getUnread(account: "Acct" + bs)

        let src = runner.calls[0]
        #expect(src.contains("name is \"Acct" + bs + bs + "\""))
    }

    @Test("listMailboxes escapes a trailing backslash in the account name")
    func listMailboxesEscapesTrailingBackslash() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)
        let bs = MailServiceTests.bs

        _ = try await svc.listMailboxes(account: "Acct" + bs)

        let src = runner.calls[0]
        #expect(src.contains("name is \"Acct" + bs + bs + "\""))
    }

    // ─── Output-field sanitization (tab/newline desync) ────────────────────
    //
    // subject and sender share the emitted `\t`-delimited record with body;
    // a raw tab/newline in either would add stray fields/lines and desync
    // parseEmailLines. They must run through the same `sanitize` helper as
    // body before being emitted.

    @Test("getUnread routes subject and sender through sanitize before emitting")
    func getUnreadSanitizesSubjectAndSender() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.getUnread()

        let src = runner.calls[0]
        #expect(src.contains("my sanitize(subj)"))
        #expect(src.contains("my sanitize(sndr)"))
    }

    @Test("search routes subject and sender through sanitize before emitting")
    func searchSanitizesSubjectAndSender() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(query: "q", forceBackend: .applescript)

        let src = runner.calls[0]
        #expect(src.contains("my sanitize(subj)"))
        #expect(src.contains("my sanitize(sndr)"))
    }

    // Mailbox and account names come straight from Mail.app's `name of m` /
    // `name of a` and are just as user-renameable as subject/sender — a tab
    // in either would desync parseEmailLines the same way. They must go
    // through `sanitize` too, not just subject/sender/body.

    @Test("getUnread routes mailbox and account name through sanitize before emitting")
    func getUnreadSanitizesMailboxAndAccountName() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.getUnread()

        let src = runner.calls[0]
        #expect(src.contains("my sanitize(name of m)"))
        #expect(src.contains("my sanitize(acctName)"))
    }

    @Test("search routes mailbox and account name through sanitize before emitting")
    func searchSanitizesMailboxAndAccountName() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("")
        let svc = MailService(runner: runner)

        _ = try await svc.search(query: "q", forceBackend: .applescript)

        let src = runner.calls[0]
        #expect(src.contains("my sanitize(name of m)"))
        #expect(src.contains("my sanitize(acctName)"))
    }
}
