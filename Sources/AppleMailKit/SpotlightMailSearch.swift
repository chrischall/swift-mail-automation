import Foundation
import Logging

/// Spotlight-backed mail search. Apple indexes every `.emlx` file in
/// `~/Library/Mail/` with subject, sender, date, and body — `mdfind` hits
/// that index in milliseconds vs. the tens-of-seconds our AppleScript
/// `whose()` takes iterating Gmail labels.
///
/// Implementation note: we subprocess `mdfind` rather than using
/// `NSMetadataQuery` because the latter requires a running RunLoop and
/// cooperates poorly with Swift 6 strict concurrency. `mdfind` is a
/// stable, decades-old CLI that emits one path per line; trivially
/// wrapped and easy to test against a fake process runner.
public struct SpotlightMailSearch: Sendable {
    /// Abstraction over `Process` invocation so the search logic can be
    /// unit-tested without touching the file system.
    public typealias Runner = @Sendable (_ args: [String]) async throws -> String

    private let runner: Runner
    private let log: Logger

    public init(runner: Runner? = nil, log: Logger? = nil) {
        self.runner = runner ?? SpotlightMailSearch.defaultRunner
        // Library default: a per-module logger named after the package.
        // Server wires its own `AppLog.root` in when it constructs us.
        self.log = log ?? Logger(label: "com.chall.apple-mail-kit.spotlight")
    }

    /// Search mail by subject/body substring. Returns `.emlx` paths and a
    /// small amount of indexed metadata — enough to present a result list
    /// without re-parsing every file.
    public func search(
        query: String,
        limit: Int = 20,
        sinceDaysAgo: Int? = 90
    ) async throws -> [EmailMessage] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        let predicate = Self.buildPredicate(query: needle, sinceDaysAgo: sinceDaysAgo)
        // `-onlyin ~/Library/Mail` restricts to the Mail store — without it
        // Spotlight would also return Messages attachments, calendar invites,
        // and anything else that happens to match.
        let mailDir = NSString(string: "~/Library/Mail").expandingTildeInPath
        let args = [
            "-onlyin", mailDir,
            "-attr", "kMDItemSubject",
            "-attr", "kMDItemAuthors",
            "-attr", "kMDItemContentCreationDate",
            predicate,
        ]

        log.debug("mdfind: \(predicate)")
        let output = try await runner(args)
        return Self.parseAttrOutput(output, limit: limit)
    }

    // ─── Predicate construction ────────────────────────────────────────────

    /// Build the `mdfind` predicate string. We match on subject OR body
    /// (case-insensitive, substring via `*…*c`) and optionally bound the
    /// date to reduce noise on long-running indexes.
    static func buildPredicate(query: String, sinceDaysAgo: Int?) -> String {
        let escaped = query.replacingOccurrences(of: "'", with: "\\'")
        let text = """
        (kMDItemKind == 'Mail Message') && \
        ((kMDItemSubject == '*\(escaped)*'c) || (kMDItemTextContent == '*\(escaped)*'c))
        """
        guard let days = sinceDaysAgo, days > 0 else { return text }
        // mdfind supports `$time.today(-30)` style but parses the `-` as
        // subtraction inside a compound predicate, so we use ISO dates.
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let iso = ISODate.string(from: cutoff)
        return "\(text) && (kMDItemContentCreationDate > \(formatMDFindDate(iso)))"
    }

    /// `mdfind` wants dates as `$time.iso(YYYY-MM-DDTHH:mm:ssZ)`.
    static func formatMDFindDate(_ iso: String) -> String {
        "$time.iso(\(iso))"
    }

    // ─── Parsing ───────────────────────────────────────────────────────────

    /// Parse `mdfind -attr a -attr b …` output. Format is one line per hit:
    ///
    ///     /path/to/file.emlx kMDItemSubject = "Invoice" kMDItemAuthors = ("a@b.com") kMDItemContentCreationDate = 2026-04-01 09:00:00 +0000
    ///
    /// We use a pragmatic regex split rather than a full parser — attributes
    /// appear in the order we passed to `mdfind`.
    static func parseAttrOutput(_ raw: String, limit: Int) -> [EmailMessage] {
        var out: [EmailMessage] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            if out.count >= limit { break }
            let s = String(line)
            guard let subjectRange = s.range(of: "kMDItemSubject = ") else { continue }
            let path = String(s[..<subjectRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[subjectRange.upperBound...])
            guard let subject = extractQuoted(from: rest) else { continue }

            let sender = rest.range(of: "kMDItemAuthors = ").flatMap { r in
                extractParenthesized(from: String(rest[r.upperBound...]))
            } ?? "(unknown)"

            let dateSent = rest.range(of: "kMDItemContentCreationDate = ").map { r in
                String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } ?? ""

            let mailbox = Self.mailboxFromPath(path)

            out.append(EmailMessage(
                subject: subject,
                sender: sender,
                dateSent: dateSent,
                content: "", // body not fetched here — caller can open the .emlx if needed
                isRead: true, // Spotlight doesn't index read state; optimistic default
                mailbox: mailbox
            ))
        }
        return out
    }

    /// Pull "Foo" out of `"Foo" rest…` → `Foo`.
    static func extractQuoted(from s: String) -> String? {
        let trimmed = s.drop(while: { $0 == " " })
        guard trimmed.first == "\"" else { return nil }
        let body = trimmed.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return nil }
        return String(body[..<end])
    }

    /// Pull `a@b.com` out of `("a@b.com") rest…`. Spotlight serializes
    /// `kMDItemAuthors` as a parenthesized list.
    static func extractParenthesized(from s: String) -> String? {
        let trimmed = s.drop(while: { $0 == " " })
        guard trimmed.first == "(" else { return nil }
        let body = trimmed.dropFirst()
        guard let end = body.firstIndex(of: ")") else { return nil }
        // Might be multiple addresses — take the first.
        let list = String(body[..<end])
        let first = list.split(separator: ",").first.map(String.init) ?? list
        return first.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    /// Derive "account — mailbox" from the `.emlx` path. Mail stores files
    /// under `~/Library/Mail/V*/<AccountUUID>/INBOX.mbox/…/Messages/xxxxx.emlx`.
    /// We pull the two folder names one or two levels above "Messages".
    static func mailboxFromPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard let messagesIdx = parts.lastIndex(of: "Messages"),
              messagesIdx >= 2 else { return "" }
        // Usually: …/<AccountUUID>/<MailboxName>.mbox/<uuid>/Data/.../Messages/foo.emlx
        // Walk back until we hit something ending in `.mbox`.
        for i in stride(from: messagesIdx - 1, through: max(0, messagesIdx - 5), by: -1) {
            let name = String(parts[i])
            if name.hasSuffix(".mbox") {
                return String(name.dropLast(".mbox".count))
            }
        }
        return ""
    }

    // ─── Default runner: spawn `mdfind` ────────────────────────────────────

    private static let defaultRunner: Runner = { args in
        try await withCheckedThrowingContinuation { cont in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            task.arguments = args
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            task.terminationHandler = { _ in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let s = String(data: data ?? Data(), encoding: .utf8) ?? ""
                cont.resume(returning: s)
            }
            do {
                try task.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
