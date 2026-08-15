import Foundation
@testable import MailAutomation
import Testing

/// The guarantees that keep a slow Mail from becoming a *wrong* answer.
///
/// Every test here corresponds to a way the previous implementation failed
/// silently: a timeout that read as "no results", a `limit` that bounded
/// nothing, an error swallowed by a per-mailbox `try`.
@Suite("MailService bounds and failure reporting")
struct MailBoundsTests {
    /// A runner that blocks for `delay` before answering, so the operation
    /// bound can be exercised without waiting on real Mail.
    final class SlowRunner: AppleScriptRunner, @unchecked Sendable {
        let delay: Duration
        let reply: String
        private(set) var calls: [String] = []

        init(delay: Duration, reply: String = "") {
            self.delay = delay
            self.reply = reply
        }

        func run(source: String) async throws -> String {
            calls.append(source)
            try await Task.sleep(for: delay)
            return reply
        }
    }

    private var fastTimeouts: MailTimeouts {
        MailTimeouts(perEventSeconds: 1, operationSeconds: 0.15, sendSeconds: 0.15)
    }

    // ─── A timeout is never an empty result ────────────────────────────────

    @Test("a search that outruns its bound throws timedOut, not an empty array")
    func searchTimeoutIsNotEmpty() async throws {
        let runner = SlowRunner(delay: .seconds(5))
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        do {
            let results = try await svc.search(query: "invoice", account: "Google")
            Issue.record("expected a timeout, got \(results.count) results")
        } catch let e as MailServiceError {
            guard case let .timedOut(operation, seconds) = e else {
                Issue.record("expected .timedOut, got \(e)")
                return
            }
            // The error has to name what timed out and what bound was hit —
            // "it failed" is not actionable when the fix is "narrow the query".
            #expect(operation.contains("search"))
            #expect(seconds == 0.15)
        }
    }

    @Test("an unread listing that outruns its bound throws rather than reporting an empty inbox")
    func unreadTimeoutIsNotEmpty() async throws {
        let runner = SlowRunner(delay: .seconds(5))
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        await #expect(throws: MailServiceError.self) {
            _ = try await svc.getUnread(limit: 10, account: "Google")
        }
    }

    @Test("a get that outruns its bound throws timedOut, not 'no message found'")
    func getTimeoutIsNotNotFound() async throws {
        let runner = SlowRunner(delay: .seconds(5))
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        do {
            _ = try await svc.getMessage(id: "<a@b>", account: "Google")
            Issue.record("expected a timeout")
        } catch let e as MailServiceError {
            // "no message found" would be a lie: we never finished looking.
            guard case .timedOut = e else {
                Issue.record("expected .timedOut, got \(e)")
                return
            }
        }
    }

    @Test("a timeout leaves the operation name and bound on the error for every operation")
    func timeoutErrorsAreLabelled() async throws {
        let runner = SlowRunner(delay: .seconds(5))
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        var seen: [String] = []
        for probe in [
            { try await svc.search(query: "x") },
            { try await svc.getUnread() },
        ] {
            do { _ = try await probe() } catch let e as MailServiceError {
                if case let .timedOut(op, _) = e {
                    seen.append(op)
                }
            }
        }
        #expect(seen.count == 2)
        #expect(seen.allSatisfy { !$0.isEmpty })
    }

    // ─── Unbounded queries are refused, not attempted ──────────────────────

    @Test("an empty query is refused before any backend runs")
    func emptyQueryRefused() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        for q in ["", "   ", "OR", "AND OR"] {
            await #expect(throws: MailQueryError.self) {
                _ = try await svc.search(query: q)
            }
        }
        #expect(runner.calls.isEmpty, "no script should ever run for an unbounded query")
    }

    @Test("a non-positive limit returns nothing without running a script")
    func nonPositiveLimitRefused() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        #expect(try await svc.search(query: "x", limit: 0).isEmpty)
        #expect(try await svc.search(query: "x", limit: -1).isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test("limit is capped so one call can't ask Mail for an unbounded scan")
    func limitCapped() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        _ = try await svc.search(query: "x", limit: 100_000, account: "Google")

        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].contains("100"), "expected the capped limit in the script")
        #expect(!runner.calls[0].contains("100000"))
    }

    @Test("search defaults to a bounded limit when the caller gives none")
    func defaultLimitApplied() {
        #expect(MailService.defaultLimit > 0)
        #expect(MailService.defaultLimit <= 100)
    }

    // ─── Every generated script carries its own bound ──────────────────────

    @Test("every Mail.app script is wrapped in `with timeout`")
    func everyScriptIsBounded() async {
        let runner = SlowRunner(delay: .zero, reply: "SENT")
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        _ = try? await svc.search(query: "x", account: "Google")
        _ = try? await svc.getUnread()
        _ = try? await svc.getMessage(id: "<a@b>")
        _ = try? await svc.listAccounts()
        _ = try? await svc.listMailboxes(account: "Google")
        _ = try? await svc.send(to: "a@b.com", subject: "s", body: "b")

        #expect(runner.calls.count == 6)
        for (i, call) in runner.calls.enumerated() {
            #expect(call.contains("with timeout of"), "script \(i) is unbounded")
            #expect(call.contains("end timeout"), "script \(i) is unbounded")
        }
    }

    @Test("the search script no longer swallows a failing mailbox")
    func noSwallowingTryAroundTheWhoseClause() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        _ = try await svc.search(query: "x", account: "Google")
        let src = runner.calls[0]

        // The old script wrapped the per-mailbox `whose` in `try`, so an
        // Apple Event timeout skipped that mailbox and the script returned
        // "" — which the caller rendered as "no results".
        let whoseLine = src
            .split(separator: "\n")
            .first { $0.contains("set matchMsgs to") }
        #expect(whoseLine != nil)
        let linesBeforeWhose = src
            .split(separator: "\n")
            .prefix { !$0.contains("set matchMsgs to") }
        #expect(
            !linesBeforeWhose.contains { $0.trimmingCharacters(in: .whitespaces) == "try" },
            "a bare `try` before the whose clause would swallow timeouts again"
        )
    }

    @Test("the search script does not fetch message bodies")
    func searchDoesNotFetchBodies() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        _ = try await svc.search(query: "x", account: "Google")

        // `content of msg` is a per-message round trip that the preview is
        // then truncated to 300 chars from — paying a full body fetch to
        // keep a snippet. Callers wanting the body call `get`.
        #expect(!runner.calls[0].contains("content of msg"))
    }

    @Test("scripts spawn no subprocesses per field")
    func noShellOutPerField() async {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        _ = try? await svc.search(query: "x", account: "Google")
        _ = try? await svc.getUnread()
        _ = try? await svc.getMessage(id: "<a@b>")

        for (i, call) in runner.calls.enumerated() {
            // The sanitizer used to `do shell script` once per field per
            // message — 7 forks per result.
            #expect(!call.contains("do shell script"), "script \(i) still shells out")
        }
    }

    @Test("the account name is resolved once, not per mailbox")
    func accountResolvedOnce() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        _ = try await svc.search(query: "x", account: "Google")

        // `first account whose mailboxes contains m` inside the loop makes
        // Mail enumerate every mailbox of every account per iteration.
        #expect(!runner.calls[0].contains("whose mailboxes contains"))
    }

    // ─── Ordering ──────────────────────────────────────────────────────────

    @Test("AppleScript results are sorted newest-first, not in mailbox order")
    func appleScriptResultsAreDateSorted() {
        // Mail yields matches in mailbox-iteration order; the trailing
        // field is the sort key.
        let raw = [
            "Old\tal@x\tdisplay-old\tINBOX\tGoogle\ttrue\t\t<1@x>\t2026-01-02T03:04:05",
            "Newest\tbo@x\tdisplay-new\tPromos\tGoogle\ttrue\t\t<2@x>\t2026-08-14T09:00:00",
            "Middle\tcy@x\tdisplay-mid\tSent\tGoogle\tfalse\t\t<3@x>\t2026-05-05T12:00:00",
        ].joined(separator: "\n") + "\n"

        let out = MailService.parseSearchLines(raw)

        #expect(out.map(\.subject) == ["Newest", "Middle", "Old"])
    }

    @Test("rows with no sort key sort last instead of being dropped")
    func missingSortKeySortsLast() {
        let raw = [
            "NoKey\tal@x\td\tINBOX\tGoogle\ttrue\t\t<1@x>",
            "Keyed\tbo@x\td\tINBOX\tGoogle\ttrue\t\t<2@x>\t2026-08-14T09:00:00",
        ].joined(separator: "\n") + "\n"

        let out = MailService.parseSearchLines(raw)

        #expect(out.map(\.subject) == ["Keyed", "NoKey"])
        #expect(out.count == 2, "a missing sort key must not drop the result")
    }

    @Test("the generated script emits a locale-independent sort key")
    func sortKeyIsLocaleIndependent() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        _ = try await svc.search(query: "x", account: "Google")
        let src = runner.calls[0]

        // Built from date components. A `date "…"` literal would parse in
        // the user's locale and break wherever that isn't en-US.
        #expect(src.contains("year of d"))
        #expect(!src.contains("date \"Thursday"))
    }

    // ─── Backend selection ─────────────────────────────────────────────────

    @Test("forcing the index backend without an index reports why, rather than falling back silently")
    func forcedIndexWithoutIndexExplains() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        do {
            _ = try await svc.search(query: "x", forceBackend: .index)
            Issue.record("expected a tooBroad error")
        } catch let e as MailServiceError {
            guard case let .tooBroad(msg) = e else {
                Issue.record("expected .tooBroad, got \(e)")
                return
            }
            #expect(msg.contains("Full Disk Access"))
        }
        #expect(runner.calls.isEmpty)
    }

    @Test("a to: query with no index says so instead of dropping the constraint")
    func toQueryWithoutIndexIsRefused() async throws {
        let runner = SlowRunner(delay: .zero)
        let svc = MailService(runner: runner, spotlight: nil, timeouts: fastTimeouts)

        // Mail's `whose` cannot express to-recipients. Running the query
        // without that clause would return confidently wrong results.
        await #expect(throws: MailServiceError.self) {
            _ = try await svc.search(query: "to:alice@example.com", account: "Google")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test("isIndexAvailable reports the backend actually in use")
    func indexAvailabilityIsVisible() {
        let runner = SlowRunner(delay: .zero)
        #expect(MailService(runner: runner, spotlight: nil).isIndexAvailable == false)
    }
}
