import Foundation
@testable import MailAutomation
import Testing

@Suite("SpotlightMailSearch")
struct SpotlightMailSearchTests {
    // ─── predicate construction ────────────────────────────────────────────

    @Test("buildPredicate matches subject OR body case-insensitively")
    func predicateSubjectOrBody() throws {
        let p = try SpotlightMailSearch.buildPredicate(query: MailQuery.parse("invoice"), sinceDaysAgo: nil)
        #expect(p.contains("kMDItemSubject == '*invoice*'c"))
        #expect(p.contains("kMDItemTextContent == '*invoice*'c"))
        #expect(p.contains("kMDItemKind == 'Mail Message'"))
    }

    @Test("buildPredicate appends a date bound when requested")
    func predicateDateBound() throws {
        let p = try SpotlightMailSearch.buildPredicate(query: MailQuery.parse("q"), sinceDaysAgo: 30)
        #expect(p.contains("kMDItemContentCreationDate"))
        #expect(p.contains("$time.iso("))
    }

    @Test("buildPredicate escapes single quotes in the query")
    func predicateEscapesQuotes() throws {
        // A bare phrase is three ANDed terms; assert the quote inside the
        // first one is escaped so it can't terminate the mdfind literal.
        let p = try SpotlightMailSearch.buildPredicate(
            query: MailQuery.parse("it's a test"), sinceDaysAgo: nil
        )
        #expect(p.contains("it\\'s"))
        #expect(!p.contains("'it's'"))

        // And a quoted phrase stays one term, spaces intact.
        let phrase = try SpotlightMailSearch.buildPredicate(
            query: MailQuery.parse("\"it's a test\""), sinceDaysAgo: nil
        )
        #expect(phrase.contains("it\\'s a test"))
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

        let msgs = try await search.search(query: MailQuery.parse("hello"), limit: 5, sinceDaysAgo: 30)

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

        await #expect(throws: MailQueryError.self) {
            _ = try await search.search(query: MailQuery.parse("  "))
        }
        let called = await box.called
        #expect(called == false)
    }

    @Test("search propagates errors thrown by the runner")
    func searchPropagatesRunnerError() async throws {
        struct Boom: Error {}
        let runner: SpotlightMailSearch.Runner = { _ in throw Boom() }
        let search = SpotlightMailSearch(runner: runner)

        await #expect(throws: Boom.self) {
            _ = try await search.search(query: MailQuery.parse("x"))
        }
    }

    @Test("buildPredicate omits the date bound when sinceDaysAgo is nil or <= 0")
    func predicateNoDateBound() throws {
        let pNil = try SpotlightMailSearch.buildPredicate(query: MailQuery.parse("x"), sinceDaysAgo: nil)
        #expect(!pNil.contains("kMDItemContentCreationDate"))
        let pZero = try SpotlightMailSearch.buildPredicate(query: MailQuery.parse("x"), sinceDaysAgo: 0)
        #expect(!pZero.contains("kMDItemContentCreationDate"))
        let pNeg = try SpotlightMailSearch.buildPredicate(query: MailQuery.parse("x"), sinceDaysAgo: -5)
        #expect(!pNeg.contains("kMDItemContentCreationDate"))
    }

    @Test("mailboxFromPath returns empty when no .mbox ancestor is present")
    func mailboxFromPathNoMbox() {
        // Plausibly-shaped path but no `.mbox` component anywhere near Messages.
        let s = SpotlightMailSearch.mailboxFromPath(
            "/U/me/Library/Mail/V10/A/just/a/dir/Data/0/Messages/1.emlx"
        )
        #expect(s == "")
    }

    @Test("mailboxFromPath returns empty when there is no Messages folder at all")
    func mailboxFromPathNoMessagesDir() {
        #expect(SpotlightMailSearch.mailboxFromPath("/some/random/path.txt") == "")
        #expect(SpotlightMailSearch.mailboxFromPath("") == "")
    }

    @Test("parseAttrOutput treats missing authors as (unknown)")
    func parseMissingAuthors() {
        let raw = "/p kMDItemSubject = \"Only subject\" kMDItemContentCreationDate = 2026-04-01\n"
        let out = SpotlightMailSearch.parseAttrOutput(raw, limit: 10)
        #expect(out.count == 1)
        #expect(out[0].sender == "(unknown)")
    }

    @Test("parseAttrOutput takes the first author from a multi-author list")
    func parseMultipleAuthors() {
        let raw = "/p kMDItemSubject = \"Hi\" kMDItemAuthors = (\"a@x.com\", \"b@x.com\") kMDItemContentCreationDate = 2026-04-01\n"
        let out = SpotlightMailSearch.parseAttrOutput(raw, limit: 10)
        #expect(out.count == 1)
        #expect(out[0].sender == "a@x.com")
    }

    @Test("formatMDFindDate wraps an ISO string in $time.iso(...)")
    func formatMDFindDateWraps() {
        let s = SpotlightMailSearch.formatMDFindDate("2026-04-21T00:00:00Z")
        #expect(s == "$time.iso(2026-04-21T00:00:00Z)")
    }

    /// Exercises the real `/usr/bin/mdfind` subprocess path. macOS always
    /// ships mdfind so this is safe on CI; we query for an improbable
    /// needle and only assert it completes without throwing. The point is
    /// coverage of the `defaultRunner` closure, not asserting on results.
    @Test("default runner (mdfind subprocess) runs end-to-end")
    func defaultRunnerExecutes() async throws {
        let search = SpotlightMailSearch()
        let results = try await search.search(
            query: MailQuery.parse("ZZXXYY_MailAutomation_Unlikely_Needle_\(UUID().uuidString)"),
            limit: 1,
            sinceDaysAgo: 1
        )
        #expect(results.isEmpty)
    }

    @Test("process runner throws when the executable can't be launched")
    func processRunnerLaunchFailureThrows() async throws {
        let runner = SpotlightMailSearch.makeProcessRunner(
            executableURL: URL(fileURLWithPath: "/definitely/not/a/binary-\(UUID().uuidString)")
        )
        await #expect(throws: (any Error).self) {
            _ = try await runner(["-help"])
        }
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
