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
    ///
    /// Implementations receive the argv that would normally be passed to
    /// `mdfind` and return the captured stdout as a single string.
    public typealias Runner = @Sendable (_ args: [String]) async throws -> String

    private let runner: Runner
    private let log: Logger
    private let maxOutputBytes: Int

    /// Create a Spotlight-backed search.
    ///
    /// - Parameters:
    ///   - runner: Process runner to invoke. Pass `nil` (the default) to
    ///     spawn the real `/usr/bin/mdfind`. Inject a fake in tests.
    ///   - log: Logger for debug tracing of generated predicates. When
    ///     `nil`, a per-module logger is used.
    public init(
        runner: Runner? = nil,
        log: Logger? = nil,
        maxOutputBytes: Int = SpotlightMailSearch.defaultMaxOutputBytes
    ) {
        self.maxOutputBytes = maxOutputBytes
        self.runner = runner
            ?? SpotlightMailSearch.makeProcessRunner(
                executableURL: SpotlightMailSearch.mdfindURL,
                maxOutputBytes: maxOutputBytes
            )
        self.log = log ?? Logger(label: "com.chall.apple-mail-kit.spotlight")
    }

    /// Search mail by subject/body substring via Spotlight.
    ///
    /// Hits `mdfind` against `~/Library/Mail/` with a predicate built from
    /// `query` and an optional recency bound. Returns a small amount of
    /// indexed metadata (subject, sender, date, mailbox derived from the
    /// `.emlx` path) — enough to present a result list without re-parsing
    /// every file. Body content and read status are not indexed by
    /// Spotlight; `content` is always `""` and `isRead` is always `true`.
    ///
    /// - Parameters:
    ///   - query: Parsed query. Unscoped terms match subject **or body** —
    ///     Spotlight is the only backend with body text. An empty query is
    ///     impossible here: ``MailQuery/parse(_:)`` rejects one first.
    ///   - limit: Maximum number of results to return.
    ///   - sinceDaysAgo: Optional date bound. `nil` or a non-positive value
    ///     disables the bound. Defaults to 90 days.
    /// - Returns: Matching messages, **newest first**. Empty if `mdfind`
    ///   returned nothing.
    /// - Throws: Whatever the injected `Runner` throws — for the default
    ///   runner, this is a `Foundation.Process` launch error (e.g. the
    ///   binary is missing or can't be executed).
    public func search(
        query: MailQuery,
        limit: Int = 20,
        sinceDaysAgo: Int? = 90
    ) async throws -> [EmailMessage] {
        guard limit > 0 else { return [] }
        let predicate = Self.buildPredicate(query: query, sinceDaysAgo: sinceDaysAgo)
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
        // Truncation is detected by the runner, which counts the bytes it
        // actually read. Inferring it here from the decoded string's length
        // does not work: `String.count` counts grapheme clusters, so 8MB of
        // non-ASCII mail decodes to far fewer than 8_388_608 characters and
        // the check never fires — and a cut through a multi-byte sequence
        // can fail to decode at all, yielding `""` and a *zero*-result
        // "success". Both are the silent-incomplete-scan failure this exists
        // to prevent.
        let output = try await runner(args)
        return Self.parseAttrOutput(output, limit: limit)
    }

    // ─── Predicate construction ────────────────────────────────────────────

    /// Build the `mdfind` predicate from a parsed query.
    ///
    /// Spotlight is the only backend that reads message *bodies*, so an
    /// unscoped term matches subject or body here (unlike the index, which
    /// has no body text to match). `from:` maps to `kMDItemAuthors` and
    /// `to:` to `kMDItemRecipients`; `subject:` narrows to the subject
    /// alone.
    static func buildPredicate(query: MailQuery, sinceDaysAgo: Int?) -> String {
        func clause(_ term: MailQuery.Term) -> String {
            let v = escape(term.value)
            switch term.field {
            case .subject:
                return "(kMDItemSubject == '*\(v)*'c)"
            case .from:
                return "(kMDItemAuthors == '*\(v)*'c)"
            case .to:
                return "(kMDItemRecipients == '*\(v)*'c)"
            case .any:
                return "((kMDItemSubject == '*\(v)*'c) || (kMDItemTextContent == '*\(v)*'c))"
            }
        }

        let groups = query.groups.map { group in
            "(" + group.map(clause).joined(separator: " && ") + ")"
        }
        let text = "(kMDItemKind == 'Mail Message') && (" + groups.joined(separator: " || ") + ")"

        guard let days = sinceDaysAgo, days > 0 else { return text }
        // mdfind supports `$time.today(-30)` style but parses the `-` as
        // subtraction inside a compound predicate, so we use ISO dates.
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let iso = ISODate.string(from: cutoff)
        return "\(text) && (kMDItemContentCreationDate > \(formatMDFindDate(iso)))"
    }

    /// Escapes a term for an `mdfind` single-quoted literal.
    ///
    /// Backslashes go first, or escaping the quote would then be
    /// double-escaped. `*` is escaped so a user searching for a literal
    /// asterisk doesn't get a wildcard.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    /// `mdfind` wants dates as `$time.iso(YYYY-MM-DDTHH:mm:ssZ)`.
    static func formatMDFindDate(_ iso: String) -> String {
        "$time.iso(\(iso))"
    }

    // ─── Parsing ───────────────────────────────────────────────────────────

    /// Parse `mdfind -attr a -attr b …` output, returning hits newest
    /// first. Format is one line per hit:
    ///
    ///     /path/to/file.emlx kMDItemSubject = "Invoice" kMDItemAuthors = ("a@b.com") kMDItemContentCreationDate =
    /// 2026-04-01 09:00:00 +0000
    ///
    /// We use a pragmatic regex split rather than a full parser — attributes
    /// appear in the order we passed to `mdfind`.
    static func parseAttrOutput(_ raw: String, limit: Int) -> [EmailMessage] {
        guard limit > 0 else { return [] }
        var parsed: [(message: EmailMessage, date: Date?)] = []

        // Every line is parsed before anything is dropped. Truncating to
        // `limit` in `mdfind`'s own order — which is unspecified — would
        // discard newer matches in favour of older ones, the same defect
        // this backend exists to avoid on the Mail.app path.
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
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

            parsed.append((
                EmailMessage(
                    subject: subject,
                    sender: sender,
                    dateSent: dateSent,
                    content: "", // body not fetched here — caller can open the .emlx if needed
                    isRead: true, // Spotlight doesn't index read state; optimistic default
                    mailbox: mailbox
                ),
                parseSpotlightDate(dateSent)
            ))
        }

        // Newest first, matching the other backends. Undated hits sort last
        // rather than being dropped; ties keep source order so the result is
        // deterministic.
        return parsed
            .enumerated()
            .sorted { a, b in
                switch (a.element.date, b.element.date) {
                case let (l?, r?):
                    if l == r {
                        return a.offset < b.offset
                    }
                    return l > r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return a.offset < b.offset
                }
            }
            .prefix(limit)
            .map(\.element.message)
    }

    /// Parses the timestamp `mdfind -attr` prints for
    /// `kMDItemContentCreationDate`, e.g. `2026-04-01 09:00:00 +0000`.
    ///
    /// Fixed `en_US_POSIX` locale and UTC: the format is `mdfind`'s, not the
    /// user's, so a locale-sensitive parser would fail on non-US systems.
    /// Returns `nil` for `(null)` and anything unparseable — those sort last
    /// rather than being discarded.
    static func parseSpotlightDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "(null)" else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
            fmt.dateFormat = pattern
            if let d = fmt.date(from: trimmed) {
                return d
            }
        }
        return ISODate.parse(trimmed)
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

    /// The `mdfind` binary path. Hard-coded because macOS always ships it
    /// at this location and relying on `$PATH` would add an environment
    /// dependency we don't need.
    static let mdfindURL = URL(fileURLWithPath: "/usr/bin/mdfind")

    /// Build a `Runner` that spawns the given executable and collects its
    /// stdout. Factored out so tests can point at a non-existent URL to
    /// exercise the launch-error branch of `Process.run()`.
    ///
    /// ## Why the pipes are drained concurrently
    ///
    /// The obvious implementation — set a `Pipe`, read it in
    /// `terminationHandler` — deadlocks. A pipe holds 64 KB; once `mdfind`
    /// fills it, it blocks in `write()` and never exits, so the
    /// termination handler never runs, so nothing ever drains the pipe, so
    /// `mdfind` never unblocks. The continuation is then never resumed:
    /// an unbounded hang with no error and no diagnostics. `mdfind -attr`
    /// output crosses 64 KB easily on a large mail store.
    ///
    /// Both stdout *and* stderr are drained — an undrained stderr wedges
    /// the child exactly the same way.
    /// ## Why truncation throws rather than returning what fit
    ///
    /// The sort in ``parseAttrOutput(_:limit:)`` is global over this output,
    /// so dropping the tail can drop the *newest* hits — the ones the caller
    /// most wants. Returning the survivors would be an incomplete scan that
    /// looks complete, the same failure ``MailServiceError/timedOut(operation:seconds:)``
    /// exists to prevent. The byte count is kept here, where the bytes are,
    /// rather than inferred from the decoded string's length by a caller.
    static func makeProcessRunner(
        executableURL: URL,
        maxOutputBytes: Int = SpotlightMailSearch.defaultMaxOutputBytes
    ) -> Runner {
        { args in
            let task = Process()
            task.executableURL = executableURL
            task.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            do {
                try task.run()
            } catch {
                throw error
            }

            // Read both pipes to EOF off the calling thread before waiting
            // on exit. Reading to EOF is what lets the child finish — the
            // read must continue past the cap even though the excess is
            // discarded, or the child blocks in write() forever.
            async let out = Self.readToEnd(
                outPipe.fileHandleForReading, keeping: maxOutputBytes
            )
            async let err = Self.readToEnd(
                errPipe.fileHandleForReading, keeping: 0
            )
            let (stdout, _) = await (out, err)

            task.waitUntilExit()

            if stdout.truncated {
                throw MailServiceError.tooBroad(
                    "Spotlight returned more than \(maxOutputBytes / (1024 * 1024))MB of " +
                        "matches, too many to rank reliably. Narrow the query: add more " +
                        "terms, or reduce sinceDaysAgo."
                )
            }
            // Lossy conversion, not `?? ""`: a byte the decoder dislikes
            // must not turn a full read into a silent zero-result success.
            return String(decoding: stdout.data, as: UTF8.self)
        }
    }

    /// Default hard cap on bytes read from a child process.
    ///
    /// A broad Spotlight query can match a whole mail store; without a cap
    /// the reply is bounded only by how much mail the user has. 8 MB is far
    /// more than any sane result set and still keeps the read bounded.
    /// Overridable via ``init(runner:log:maxOutputBytes:)`` so tests can
    /// exercise the truncation path without generating 8 MB.
    public static let defaultMaxOutputBytes = 8 * 1024 * 1024

    /// Bytes read from a child, plus whether the cap was hit.
    ///
    /// The flag is the point: it records truncation at the moment bytes are
    /// counted, so no later stage has to infer it from a decoded length.
    struct CappedRead: Sendable {
        let data: Data
        let truncated: Bool
    }

    /// Reads a file handle to EOF on a background thread, keeping at most
    /// `keeping` bytes and reporting whether more arrived.
    ///
    /// Always reads to EOF regardless of the cap — draining is what lets the
    /// child exit.
    private static func readToEnd(
        _ handle: FileHandle, keeping cap: Int
    ) async -> CappedRead {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var kept = Data()
                var total = 0
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        break
                    }
                    total += chunk.count
                    if kept.count < cap {
                        kept.append(chunk.prefix(cap - kept.count))
                    }
                }
                cont.resume(returning: CappedRead(data: kept, truncated: total > cap))
            }
        }
    }
}
