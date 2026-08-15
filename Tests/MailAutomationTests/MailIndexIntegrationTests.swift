import Foundation
@testable import MailAutomation
import Testing

/// Opt-in tests against the real Mail index on this machine.
///
/// Read-only throughout — they open Mail's Envelope Index with
/// `PRAGMA query_only`, never write, and never touch Mail.app.
///
/// ```bash
/// MAIL_INDEX_INTEGRATION=1 swift test --filter MailIndexIntegration
/// ```
///
/// Requires **Full Disk Access** for the test binary. Without the env var
/// the whole suite is skipped so CI stays deterministic.
@Suite("MailIndex integration", .serialized)
struct MailIndexIntegrationTests {
    private static let enabled =
        ProcessInfo.processInfo.environment["MAIL_INDEX_INTEGRATION"] == "1"

    /// The account to exercise. Defaults to the first account found.
    private static let account =
        ProcessInfo.processInfo.environment["MAIL_INDEX_ACCOUNT"]
            .flatMap { $0.isEmpty ? nil : $0 }

    /// A term expected to match a reasonable number of messages.
    private static let term =
        ProcessInfo.processInfo.environment["MAIL_INDEX_TERM"] ?? "invoice"

    private func reader() throws -> MailIndexReader { try MailIndexReader() }

    @Test("the index opens and names real accounts", .enabled(if: enabled))
    func opensAndListsAccounts() async throws {
        let accounts = try await reader().listAccounts()
        #expect(!accounts.isEmpty, "no accounts — is Mail configured?")
        // Display names, not raw UUIDs.
        #expect(!accounts.contains { $0.contains("-") && $0.count == 36 })
    }

    @Test("a bounded search over a large mailbox returns well inside the timeout",
          .enabled(if: enabled), .timeLimit(.minutes(1)))
    func boundedSearchIsFast() async throws {
        let reader = try reader()
        let start = Date()
        let out = try await reader.search(
            query: MailQuery.parse(Self.term),
            account: Self.account,
            sinceDaysAgo: 45,
            limit: 25
        )
        let elapsed = Date().timeIntervalSince(start)

        // The AppleScript path this replaces took 154 s for the same shape
        // of query on a 275k-message mailbox — and then returned nothing.
        #expect(elapsed < 5, "index search took \(elapsed)s; expected sub-second")
        #expect(out.count <= 25, "limit was not honoured")
        print("[integration] \(out.count) results in \(String(format: "%.3f", elapsed))s")
    }

    @Test("results are strictly newest-first", .enabled(if: enabled))
    func resultsAreDateSorted() async throws {
        let out = try await reader().search(
            query: MailQuery.parse(Self.term),
            account: Self.account, sinceDaysAgo: 365, limit: 50
        )
        try #require(out.count > 1, "need at least 2 results to check ordering")

        let dates = out.compactMap { ISODate.parse($0.dateSent) }
        #expect(dates.count == out.count, "every result should carry a parseable date")
        #expect(dates == dates.sorted(by: >), "results are not newest-first")
    }

    @Test("limit and offset page without overlap", .enabled(if: enabled))
    func pagingIsConsistent() async throws {
        let reader = try reader()
        let all = try await reader.search(
            query: MailQuery.parse(Self.term),
            account: Self.account, sinceDaysAgo: 365, limit: 10
        )
        try #require(all.count >= 4, "need at least 4 results to page")

        let page1 = try await reader.search(
            query: MailQuery.parse(Self.term),
            account: Self.account, sinceDaysAgo: 365, limit: 2, offset: 0
        )
        let page2 = try await reader.search(
            query: MailQuery.parse(Self.term),
            account: Self.account, sinceDaysAgo: 365, limit: 2, offset: 2
        )
        #expect(page1.map(\.messageId) == all.prefix(2).map(\.messageId))
        #expect(page2.map(\.messageId) == all.dropFirst(2).prefix(2).map(\.messageId))
    }

    @Test("an AND query is a subset of each of its terms", .enabled(if: enabled))
    func andIsIntersection() async throws {
        let reader = try reader()
        let a = try await reader.search(
            query: MailQuery.parse(Self.term),
            account: Self.account, sinceDaysAgo: 365, limit: 100
        )
        let both = try await reader.search(
            query: MailQuery.parse("\(Self.term) \(Self.term)"),
            account: Self.account, sinceDaysAgo: 365, limit: 100
        )
        // `x AND x` must equal `x`.
        #expect(both.map(\.messageId) == a.map(\.messageId))
    }

    @Test("an OR query is a superset of each of its branches", .enabled(if: enabled))
    func orIsUnion() async throws {
        let reader = try reader()
        let a = try await reader.search(
            query: MailQuery.parse("subject:\(Self.term)"),
            account: Self.account, sinceDaysAgo: 365, limit: 100
        )
        let union = try await reader.search(
            query: MailQuery.parse("subject:\(Self.term) OR subject:zzqqxx-improbable"),
            account: Self.account, sinceDaysAgo: 365, limit: 100
        )
        let unionIDs = Set(union.map(\.messageId))
        #expect(Set(a.map(\.messageId)).isSubset(of: unionIDs))
    }

    @Test("scoping to an account only returns that account's mail", .enabled(if: enabled))
    func accountScopingHolds() async throws {
        let reader = try reader()
        let accounts = try await reader.listAccounts()
        let target = try #require(accounts.first)

        let out = try await reader.search(
            query: MailQuery.parse(Self.term),
            account: target, sinceDaysAgo: 365, limit: 25
        )
        try #require(!out.isEmpty, "no results for '\(Self.term)' in \(target)")
        #expect(out.allSatisfy { $0.mailbox.hasPrefix("\(target) — ") })
    }

    @Test("an empty query is refused against the real index", .enabled(if: enabled))
    func emptyQueryRefused() throws {
        #expect(throws: MailQueryError.self) { _ = try MailQuery.parse("  ") }
    }
}
