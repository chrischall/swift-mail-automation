import Foundation
import Testing
@testable import MailAutomation

@Suite("SpotlightMailSearch")
struct SpotlightMailSearchTests {
    // ─── predicate construction ────────────────────────────────────────────

    @Test("buildPredicate matches subject OR body case-insensitively")
    func predicateSubjectOrBody() {
        let p = SpotlightMailSearch.buildPredicate(query: "invoice", sinceDaysAgo: nil)
        #expect(p.contains("kMDItemSubject == '*invoice*'c"))
        #expect(p.contains("kMDItemTextContent == '*invoice*'c"))
        #expect(p.contains("kMDItemKind == 'Mail Message'"))
    }

    @Test("buildPredicate appends a date bound when requested")
    func predicateDateBound() {
        let p = SpotlightMailSearch.buildPredicate(query: "q", sinceDaysAgo: 30)
        #expect(p.contains("kMDItemContentCreationDate"))
        #expect(p.contains("$time.iso("))
    }

    @Test("buildPredicate escapes single quotes in the query")
    func predicateEscapesQuotes() {
        let p = SpotlightMailSearch.buildPredicate(query: "it's a test", sinceDaysAgo: nil)
        #expect(p.contains("it\\'s a test"))
    }

    // ─── attr output parsing ───────────────────────────────────────────────

    @Test("parseAttrOutput extracts subject, sender, date, and mailbox")
    func parseAttrs() {
        let raw = """
        /Users/me/Library/Mail/V10/ABC123/INBOX.mbox/uuid/Data/.../Messages/42.emlx \
        kMDItemSubject = "Invoice #123" \
        kMDItemAuthors = ("billing@example.com") \
        kMDItemContentCreationDate = 2026-04-01 09:00:00 +0000
        """
        let msgs = SpotlightMailSearch.parseAttrOutput(raw, limit: 10)
        #expect(msgs.count == 1)
        #expect(msgs[0].subject == "Invoice #123")
        #expect(msgs[0].sender == "billing@example.com")
        #expect(msgs[0].mailbox == "INBOX")
        #expect(msgs[0].dateSent.contains("2026-04-01"))
    }

    @Test("parseAttrOutput honors the limit")
    func parseLimit() {
        let line = "/x kMDItemSubject = \"A\" kMDItemAuthors = (\"a@b.com\") kMDItemContentCreationDate = 2026-04-01 00:00:00 +0000"
        let raw = Array(repeating: line, count: 10).joined(separator: "\n")
        let msgs = SpotlightMailSearch.parseAttrOutput(raw, limit: 3)
        #expect(msgs.count == 3)
    }

    @Test("parseAttrOutput skips lines missing a subject")
    func parseSkipsBad() {
        let raw = "/no/subject/here kMDItemSomethingElse = \"x\"\n"
        #expect(SpotlightMailSearch.parseAttrOutput(raw, limit: 10).isEmpty)
    }

    @Test("mailboxFromPath extracts the .mbox name")
    func mailboxParse() {
        #expect(SpotlightMailSearch.mailboxFromPath(
            "/U/me/Library/Mail/V10/A/INBOX.mbox/u/Data/0/Messages/1.emlx"
        ) == "INBOX")
        #expect(SpotlightMailSearch.mailboxFromPath(
            "/U/me/Library/Mail/V10/A/[Gmail]/All Mail.mbox/u/Data/0/Messages/2.emlx"
        ) == "All Mail")
    }

    // ─── end-to-end via injected runner ────────────────────────────────────

    @Test("search passes the query into the runner and returns parsed results")
    func searchIntegrated() async throws {
        let box = ArgBox()
        let runner: SpotlightMailSearch.Runner = { args in
            await box.record(args)
            return """
            /U/me/Library/Mail/V10/A/INBOX.mbox/u/Data/0/Messages/1.emlx \
            kMDItemSubject = "Hello" \
            kMDItemAuthors = ("a@b.com") \
            kMDItemContentCreationDate = 2026-04-01 00:00:00 +0000
            """
        }
        let search = SpotlightMailSearch(runner: runner)

        let msgs = try await search.search(query: "hello", limit: 5, sinceDaysAgo: 30)

        #expect(msgs.count == 1)
        #expect(msgs[0].subject == "Hello")
        let captured = await box.args
        #expect(captured.contains("-onlyin"))
    }

    @Test("search returns [] for empty query without running mdfind")
    func searchEmpty() async throws {
        let box = ArgBox()
        let runner: SpotlightMailSearch.Runner = { _ in
            await box.set(true)
            return ""
        }
        let search = SpotlightMailSearch(runner: runner)

        let msgs = try await search.search(query: "  ")
        #expect(msgs.isEmpty)
        let called = await box.called
        #expect(called == false)
    }
}

/// Tiny actor used by the integration tests above to capture what the
/// runner was called with. Can't nest an actor inside a `@Suite` struct.
private actor ArgBox {
    var args: [String] = []
    var called = false
    func record(_ a: [String]) { args = a }
    func set(_ v: Bool) { called = v }
}
