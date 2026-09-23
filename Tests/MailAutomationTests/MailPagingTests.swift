import Foundation
@testable import MailAutomation
import Testing

/// Paging must not switch backends between pages.
///
/// Page 1 of an unscoped query used to come from Spotlight (subject-or-body
/// match, globally newest-first) while page 2+ came from AppleScript
/// (subject-or-sender match, mailbox-iteration order). Walking the pages
/// then skipped, duplicated, and invented results.
@Suite("MailService search paging")
struct MailPagingTests {
    /// Three hits, deliberately listed out of date order so the test also
    /// proves the page is cut *after* the global sort.
    private static let mdfindThreeHits = [
        "/m/INBOX.mbox/1.emlx kMDItemSubject = \"Middle\" kMDItemAuthors = (\"a@x.com\") kMDItemContentCreationDate = 2026-05-01 00:00:00 +0000",
        "/m/INBOX.mbox/2.emlx kMDItemSubject = \"Newest\" kMDItemAuthors = (\"b@x.com\") kMDItemContentCreationDate = 2026-08-01 00:00:00 +0000",
        "/m/INBOX.mbox/3.emlx kMDItemSubject = \"Oldest\" kMDItemAuthors = (\"c@x.com\") kMDItemContentCreationDate = 2026-01-01 00:00:00 +0000",
    ].joined(separator: "\n") + "\n"

    @Test("an unscoped page past the first is answered by Spotlight, like page 1")
    func laterPagesStayOnSpotlight() async throws {
        let runner = FakeAppleScriptRunner()
        let spotlight = SpotlightMailSearch(runner: { _ in Self.mdfindThreeHits })
        let svc = MailService(runner: runner, spotlight: spotlight)

        let page1 = try await svc.search(query: "invoice", limit: 1, offset: 0)
        let page2 = try await svc.search(query: "invoice", limit: 1, offset: 1)
        let page3 = try await svc.search(query: "invoice", limit: 1, offset: 2)

        #expect(page1.map(\.subject) == ["Newest"])
        #expect(page2.map(\.subject) == ["Middle"])
        #expect(page3.map(\.subject) == ["Oldest"])
        #expect(runner.calls.isEmpty, "a later page must not switch to the AppleScript backend")
    }

    @Test("a page past the last Spotlight hit is empty, not an AppleScript re-query")
    func pagePastTheEndIsEmpty() async throws {
        let runner = FakeAppleScriptRunner()
        runner.queue("Other\tz@x\td\tINBOX\tGoogle\ttrue\t\t<z@x>\t2026-09-01T00:00:00\n")
        let spotlight = SpotlightMailSearch(runner: { _ in Self.mdfindThreeHits })
        let svc = MailService(runner: runner, spotlight: spotlight)

        let page = try await svc.search(query: "invoice", limit: 5, offset: 3)

        #expect(page.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("a query Spotlight can't answer pages on AppleScript for every page, page 1 included")
    func emptySpotlightFallsBackOnEveryPage() async throws {
        let runner = FakeAppleScriptRunner()
        let spotlight = SpotlightMailSearch(runner: { _ in "" })
        let svc = MailService(runner: runner, spotlight: spotlight)

        _ = try await svc.search(query: "invoice", limit: 5, offset: 0)
        _ = try await svc.search(query: "invoice", limit: 5, offset: 5)

        #expect(runner.calls.count == 2, "both pages come from the same backend")
        #expect(runner.calls[1].contains("skipped < 5"))
    }

    @Test("a huge offset does not overflow the Spotlight request size")
    func hugeOffsetDoesNotOverflow() async throws {
        let runner = FakeAppleScriptRunner()
        let spotlight = SpotlightMailSearch(runner: { _ in Self.mdfindThreeHits })
        let svc = MailService(runner: runner, spotlight: spotlight)

        let page = try await svc.search(query: "invoice", limit: 100, offset: Int.max)

        #expect(page.isEmpty)
        #expect(runner.calls.isEmpty)
    }
}
