import Foundation
@testable import MailAutomation
import Testing

@Suite("MailIndexReader")
struct MailIndexReaderTests {
    /// Builds a reader over a fixture, runs `body`, and always tears down.
    private func withReader(
        seeds: [MailIndexFixture.Seed],
        _ body: (MailIndexReader) async throws -> Void
    ) async throws {
        let fixture = try MailIndexFixture(seeds: seeds)
        defer { fixture.tearDown() }
        let reader = try MailIndexReader(
            path: fixture.indexPath, accountsPath: fixture.accountsPath
        )
        try await body(reader)
    }

    private var standardSeeds: [MailIndexFixture.Seed] {
        [
            .init(subject: "Invoice 001 overdue", sender: "Billing <billing@acme.com>",
                  recipients: ["chris@example.com"], daysAgo: 1, rfcID: "<a@acme>"),
            .init(subject: "Receipt for your order", sender: "Shop <shop@store.com>",
                  recipients: ["chris@example.com"], daysAgo: 2, isRead: false, rfcID: "<b@store>"),
            .init(subject: "Weekly digest", sender: "News <news@paper.com>",
                  recipients: ["list@example.com"], daysAgo: 3),
            .init(subject: "Invoice 002", sender: "Billing <billing@acme.com>",
                  recipients: ["other@example.com"], daysAgo: 200),
            .init(subject: "Invoice 003 iCloud", sender: "Billing <billing@acme.com>",
                  daysAgo: 4, mailboxURL: "imap://ACCT-I/INBOX"),
            .init(subject: "Deleted invoice", sender: "Billing <billing@acme.com>",
                  daysAgo: 1, deleted: true),
        ]
    }

    // ─── Ordering ──────────────────────────────────────────────────────────

    @Test("results come back newest-first")
    func dateSorted() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365)
            #expect(out.count == 3)
            #expect(out.map(\.subject) == ["Invoice 001 overdue", "Invoice 003 iCloud", "Invoice 002"])
        }
    }

    @Test("dateSent is rendered as a parseable ISO instant, not a locale string")
    func isoDates() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365)
            for m in out {
                #expect(ISODate.parse(m.dateSent) != nil, "not ISO-parseable: \(m.dateSent)")
            }
        }
    }

    // ─── Bounding ──────────────────────────────────────────────────────────

    @Test("limit is honoured exactly")
    func limitHonoured() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("invoice"), sinceDaysAgo: 365, limit: 2
            )
            #expect(out.count == 2)
            #expect(out.map(\.subject) == ["Invoice 001 overdue", "Invoice 003 iCloud"])
        }
    }

    @Test("limit keeps the newest, not an arbitrary mailbox's worth")
    func limitKeepsNewest() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("invoice"), sinceDaysAgo: 365, limit: 1
            )
            #expect(out.map(\.subject) == ["Invoice 001 overdue"])
        }
    }

    @Test("offset pages without dropping or repeating results")
    func offsetPages() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let q = { try MailQuery.parse("invoice") }
            let first = try await reader.search(query: q(), sinceDaysAgo: 365, limit: 2, offset: 0)
            let second = try await reader.search(query: q(), sinceDaysAgo: 365, limit: 2, offset: 2)
            #expect(first.map(\.subject) == ["Invoice 001 overdue", "Invoice 003 iCloud"])
            #expect(second.map(\.subject) == ["Invoice 002"])
        }
    }

    @Test("a non-positive limit returns nothing rather than everything")
    func nonPositiveLimit() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let zero = try await reader.search(query: MailQuery.parse("invoice"), limit: 0)
            let negative = try await reader.search(query: MailQuery.parse("invoice"), limit: -5)
            #expect(zero.isEmpty)
            #expect(negative.isEmpty)
        }
    }

    // ─── Filtering ─────────────────────────────────────────────────────────

    @Test("sinceDaysAgo excludes older messages")
    func dateBound() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 30)
            #expect(out.map(\.subject) == ["Invoice 001 overdue", "Invoice 003 iCloud"])
        }
    }

    @Test("deleted messages never surface")
    func deletedExcluded() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365)
            #expect(!out.contains { $0.subject == "Deleted invoice" })
        }
    }

    @Test("account scoping filters to that account and labels results with it")
    func accountScope() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("invoice"), account: "iCloud", sinceDaysAgo: 365
            )
            #expect(out.map(\.subject) == ["Invoice 003 iCloud"])
            #expect(out[0].mailbox == "iCloud — INBOX")
        }
    }

    @Test("an unknown account returns nothing rather than everything")
    func unknownAccount() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("invoice"), account: "Nope", sinceDaysAgo: 365
            )
            #expect(out.isEmpty)
        }
    }

    @Test("mailbox scoping matches the leaf name of a nested path")
    func mailboxLeafMatch() async throws {
        let seeds: [MailIndexFixture.Seed] = [
            .init(subject: "In all mail", daysAgo: 1,
                  mailboxURL: "imap://ACCT-G/%5BGmail%5D/All%20Mail"),
            .init(subject: "In inbox", daysAgo: 1, mailboxURL: "imap://ACCT-G/INBOX"),
        ]
        try await withReader(seeds: seeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("in"), mailbox: "All Mail", sinceDaysAgo: 365
            )
            #expect(out.map(\.subject) == ["In all mail"])
            #expect(out[0].mailbox == "Google — [Gmail]/All Mail")
        }
    }

    @Test("unread returns only unread messages")
    func unreadOnly() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.unread()
            #expect(out.map(\.subject) == ["Receipt for your order"])
            #expect(out.allSatisfy { !$0.isRead })
        }
    }

    // ─── Boolean queries ───────────────────────────────────────────────────

    @Test("multi-term AND returns the intersection")
    func andIntersection() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("invoice overdue"), sinceDaysAgo: 365
            )
            #expect(out.map(\.subject) == ["Invoice 001 overdue"])
        }
    }

    @Test("OR returns the union, deduplicated and still date-sorted")
    func orUnion() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("overdue OR digest"), sinceDaysAgo: 365
            )
            #expect(out.map(\.subject) == ["Invoice 001 overdue", "Weekly digest"])
        }
    }

    @Test("from: matches the sender, not the subject")
    func fromScope() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("from:news@paper.com"), sinceDaysAgo: 365
            )
            #expect(out.map(\.subject) == ["Weekly digest"])
        }
    }

    @Test("to: matches a recipient")
    func toScope() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("to:list@example.com"), sinceDaysAgo: 365
            )
            #expect(out.map(\.subject) == ["Weekly digest"])
        }
    }

    @Test("subject: does not match a term that only appears in the sender")
    func subjectScopeExcludesSender() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("subject:acme"), sinceDaysAgo: 365
            )
            #expect(out.isEmpty)
        }
    }

    @Test("an unscoped term matches subject or sender")
    func anyMatchesEither() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let bySender = try await reader.search(
                query: MailQuery.parse("paper.com"), sinceDaysAgo: 365
            )
            #expect(bySender.map(\.subject) == ["Weekly digest"])
        }
    }

    @Test("combining from: and subject: ANDs the two constraints")
    func combinedScopes() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let hit = try await reader.search(
                query: MailQuery.parse("from:billing@acme.com subject:overdue"),
                sinceDaysAgo: 365
            )
            #expect(hit.map(\.subject) == ["Invoice 001 overdue"])

            let miss = try await reader.search(
                query: MailQuery.parse("from:news@paper.com subject:overdue"),
                sinceDaysAgo: 365
            )
            #expect(miss.isEmpty)
        }
    }

    @Test("a message with several recipients yields one row, not one per recipient")
    func recipientFanOutDoesNotDuplicate() async throws {
        let seeds: [MailIndexFixture.Seed] = [
            .init(subject: "Group note", recipients: ["a@x.com", "b@x.com", "c@x.com"], daysAgo: 1),
        ]
        try await withReader(seeds: seeds) { reader in
            let out = try await reader.search(query: MailQuery.parse("group"), sinceDaysAgo: 365)
            #expect(out.count == 1)
        }
    }

    @Test("LIKE wildcards in a query are matched literally")
    func wildcardsLiteral() async throws {
        let seeds: [MailIndexFixture.Seed] = [
            .init(subject: "100% off today", daysAgo: 1),
            .init(subject: "nothing special", daysAgo: 2),
        ]
        try await withReader(seeds: seeds) { reader in
            let percent = try await reader.search(query: MailQuery.parse("100%"), sinceDaysAgo: 365)
            #expect(percent.count == 1)
            // A bare `%` must not become "match everything".
            let underscore = try await reader.search(
                query: MailQuery.parse("nothing_special"), sinceDaysAgo: 365
            )
            #expect(underscore.isEmpty)
        }
    }

    // ─── Metadata ──────────────────────────────────────────────────────────

    @Test("the RFC Message-ID comes through for get()")
    func messageIDPresent() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(
                query: MailQuery.parse("subject:\"Invoice 001\""), sinceDaysAgo: 365
            )
            #expect(out.first?.messageId == "<a@acme>")
        }
    }

    @Test("read state comes from the index, not an optimistic default")
    func readState() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let out = try await reader.search(query: MailQuery.parse("receipt"), sinceDaysAgo: 365)
            #expect(out.first?.isRead == false)
        }
    }

    @Test("listAccounts returns display names, not UUIDs")
    func accountsByName() async throws {
        try await withReader(seeds: standardSeeds) { reader in
            let accts = try await reader.listAccounts()
            #expect(accts == ["Google", "iCloud"])
        }
    }

    @Test("listMailboxes decodes percent-encoded mailbox paths")
    func mailboxesDecoded() async throws {
        let seeds: [MailIndexFixture.Seed] = [
            .init(subject: "x", daysAgo: 1, mailboxURL: "imap://ACCT-G/%5BGmail%5D/All%20Mail"),
            .init(subject: "y", daysAgo: 1, mailboxURL: "imap://ACCT-G/INBOX"),
        ]
        try await withReader(seeds: seeds) { reader in
            let boxes = try await reader.listMailboxes(account: "Google")
            #expect(boxes == ["INBOX", "[Gmail]/All Mail"])
        }
    }

    // ─── Failure modes ─────────────────────────────────────────────────────

    @Test("a missing database throws rather than reporting an empty mailbox")
    func missingDatabaseThrows() {
        #expect(throws: MailIndexReaderError.self) {
            _ = try MailIndexReader(path: "/nonexistent/dir/Envelope Index", accountsPath: "/nope")
        }
    }

    @Test("an unreadable accounts DB degrades to UUIDs instead of failing the search")
    func accountsDBOptional() async throws {
        let fixture = try MailIndexFixture(seeds: standardSeeds)
        defer { fixture.tearDown() }
        let reader = try MailIndexReader(path: fixture.indexPath, accountsPath: "/nonexistent")
        let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365)
        #expect(out.count == 3, "search must still work without account names")
        #expect(out[0].mailbox.contains("ACCT-G"))
    }

    // ─── URL helpers ───────────────────────────────────────────────────────

    @Test("account UUID and mailbox name parse out of a Mail URL")
    func urlParsing() {
        let url = "imap://FB14FC5F-1234/%5BGmail%5D/All%20Mail"
        #expect(MailIndexReader.accountUUID(fromURL: url) == "FB14FC5F-1234")
        #expect(MailIndexReader.mailboxName(fromURL: url) == "[Gmail]/All Mail")
        #expect(MailIndexReader.mailboxName(fromURL: "local://ACCT/") == "")
    }

    @Test("mailbox filter matches whole path or leaf, case-insensitively")
    func mailboxMatching() {
        #expect(MailIndexReader.mailbox("[Gmail]/All Mail", matches: "All Mail"))
        #expect(MailIndexReader.mailbox("[Gmail]/All Mail", matches: "[gmail]/all mail"))
        #expect(MailIndexReader.mailbox("INBOX", matches: "inbox"))
        #expect(!MailIndexReader.mailbox("INBOX", matches: "Sent"))
    }
}
