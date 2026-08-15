import Foundation

/// Errors surfaced by `MailService` operations.
public enum MailServiceError: Error, Equatable, Sendable {
    /// AppleScript ran but Mail.app reported a non-success result, or the
    /// returned payload couldn't be parsed. The string carries Mail's
    /// response for debugging.
    case scriptFailure(String)
    /// Caller passed empty / whitespace-only strings for a required
    /// parameter (account name, subject, recipient, etc.).
    case invalidInput(String)
    /// The operation exceeded its time bound.
    ///
    /// **Must never be reported as an empty result set.** Before this case
    /// existed, an Apple Event timeout was caught by a per-mailbox `try`
    /// and the search returned `[]` — so a caller could truthfully be told
    /// "no matching mail exists" when the query had simply never finished.
    /// Measured: a 45-day subject search of one Gmail mailbox holding 153
    /// matches blocked for 120 s and returned zero results, silently.
    case timedOut(operation: String, seconds: Double)
    /// The query would have to scan more than the backend can do safely.
    /// Carries a caller-facing suggestion for narrowing it.
    case tooBroad(String)
}

/// Which search backend to use.
///
/// Ordered by preference, best first:
///
/// - ``index`` — reads Mail's own Envelope Index (SQLite) directly. Fast
///   (tens of milliseconds), date-sorted, knows accounts / mailboxes /
///   read state / recipients, and never asks Mail.app to do anything.
///   Needs Full Disk Access.
/// - ``spotlight`` — `mdfind` over `~/Library/Mail`. Fast and the only
///   backend that searches message *bodies*, but has no notion of
///   account, mailbox, or read state.
/// - ``applescript`` — drives Mail.app. The fallback of last resort: it is
///   the only backend that works with no disk permissions at all, and the
///   only one that can search when the index is missing. On a large
///   account it is unusably slow no matter how small a `limit` is passed
///   (see ``MailIndexReader`` for measurements), so it is bounded
///   aggressively and reports a timeout rather than an empty result.
public enum SearchBackend: String, Sendable {
    case index
    case spotlight
    case applescript
}

/// Mail.app wrapper over `AppleScriptRunner`. Mail has no public Swift
/// framework, so AppleScript is the only supported path — same performance
/// ceiling as a Node port, just without the per-call `osascript`
/// subprocess overhead.
///
/// Operations:
/// - ``getUnread(limit:account:)`` — read unread, optionally scoped to one
///   account (iterating all accounts is slow on Gmail-heavy setups).
/// - ``search(query:limit:account:mailbox:sinceDaysAgo:forceBackend:)`` —
///   substring search, date-bounded, with a Spotlight fast path.
/// - ``send(to:subject:body:cc:bcc:)`` — compose + send.
/// - ``listAccounts()`` / ``listMailboxes(account:)`` — discovery.
///
/// `MailService` is a value type and `Sendable`. Construct once, share
/// across concurrent contexts freely.
public struct MailService: Sendable {
    private let runner: any AppleScriptRunner
    private let spotlight: SpotlightMailSearch?
    private let index: MailIndexReader?
    private let timeouts: MailTimeouts

    /// Create a `MailService`.
    ///
    /// - Parameters:
    ///   - runner: AppleScript executor. In production, pass
    ///     `NSAppleScriptRunner()`. Inject a fake for tests.
    ///   - spotlight: Optional Spotlight-backed search used as a fast path
    ///     for unscoped `search` calls. Pass `nil` to disable the fast
    ///     path entirely (e.g. in sandboxed environments where `mdfind`
    ///     can't read `~/Library/Mail`).
    public init(
        runner: any AppleScriptRunner,
        spotlight: SpotlightMailSearch? = SpotlightMailSearch(),
        index: MailIndexReader? = nil,
        timeouts: MailTimeouts = .default
    ) {
        self.runner = runner
        self.spotlight = spotlight
        self.index = index
        self.timeouts = timeouts
    }

    /// Creates a `MailService` with the index backend enabled when it can
    /// be opened.
    ///
    /// Opening the index requires Full Disk Access. Failure is expected and
    /// non-fatal — the service falls back to Spotlight and AppleScript, the
    /// same way ``NoteStoreReader`` degrades in the sibling Notes kit. The
    /// error is returned rather than thrown so callers can log *why* the
    /// fast path is off; a server that silently ran 2000× slower than it
    /// should would be very hard to diagnose from the outside.
    ///
    /// - Returns: The service, and the error that kept the index closed
    ///   (`nil` when the index is live).
    public static func withIndexIfAvailable(
        runner: any AppleScriptRunner,
        spotlight: SpotlightMailSearch? = SpotlightMailSearch(),
        timeouts: MailTimeouts = .default
    ) -> (service: MailService, indexError: Error?) {
        do {
            let reader = try MailIndexReader()
            return (
                MailService(runner: runner, spotlight: spotlight, index: reader, timeouts: timeouts),
                nil
            )
        } catch {
            return (
                MailService(runner: runner, spotlight: spotlight, index: nil, timeouts: timeouts),
                error
            )
        }
    }

    /// Whether the fast index backend is available on this service.
    public var isIndexAvailable: Bool { index != nil }

    // MARK: - Discovery

    /// Returns the names of every account configured in Mail.app
    /// (`"iCloud"`, `"Google"`, `"Work"`, …). Use these strings as the
    /// `account` parameter to `listMailboxes`, `getUnread`, and `search`.
    ///
    /// - Returns: Account names in Mail.app's configured order.
    /// - Throws: `AppleScriptError.runtime` if Mail is not running or
    ///   Automation permission is denied.
    public func listAccounts() async throws -> [String] {
        let result = try await withTimeout(
            seconds: timeouts.operationSeconds, operation: "mail accounts"
        ) {
            try await runner.run(source: timeouts.bound("""
            tell application "Mail"
                set out to ""
                repeat with a in accounts
                    try
                        set out to out & (name of a) & linefeed
                    end try
                end repeat
                return out
            end tell
            """))
        }
        return result
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Returns the mailbox names inside a given account. On Gmail this
    /// includes every user label (not just INBOX/Sent/…); on iCloud/IMAP
    /// it matches the folder hierarchy you'd see in Mail.app's sidebar.
    ///
    /// - Parameter account: Account name from `listAccounts()`. Must be
    ///   non-empty.
    /// - Throws: `MailServiceError.invalidInput` if `account` is empty
    ///   or whitespace-only; `AppleScriptError.runtime` if the account
    ///   doesn't exist in Mail.
    public func listMailboxes(account: String) async throws -> [String] {
        guard !account.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MailServiceError.invalidInput("account name required")
        }
        let esc = Self.escapeForAppleScript(account)
        let result = try await withTimeout(
            seconds: timeouts.operationSeconds, operation: "mail mailboxes"
        ) {
            try await runner.run(source: timeouts.bound("""
            tell application "Mail"
                try
                    set a to first account whose name is "\(esc)"
                    set out to ""
                    repeat with m in mailboxes of a
                        try
                            set out to out & (name of m) & linefeed
                        end try
                    end repeat
                    return out
                on error errMsg
                    error errMsg
                end try
            end tell
            """))
        }
        return result
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Unread

    /// Reads unread messages in Mail.app. Iterates every mailbox (so on
    /// Gmail-heavy setups this can take tens of seconds — pass `account`
    /// to scope to one account and speed up considerably).
    ///
    /// - Parameters:
    ///   - limit: Maximum messages to return. Internally capped at 100;
    ///     combine with `offset` to page beyond the cap. Non-positive
    ///     values return `[]`.
    ///   - account: Optional account name from `listAccounts()` to scope
    ///     the search. When `nil`, iterates all accounts.
    ///   - offset: Number of matching messages to skip before collecting
    ///     results (in mailbox-iteration order). Defaults to 0.
    /// - Returns: Messages in mailbox-iteration order (not strictly date-
    ///   sorted). Each `EmailMessage` has `isRead == false`.
    public func getUnread(
        limit: Int = 10,
        account: String? = nil,
        offset: Int = 0
    ) async throws -> [EmailMessage] {
        guard limit > 0 else { return [] }
        let maxN = Self.cappedLimit(limit)
        let skip = max(0, offset)

        if let index {
            return try await withTimeout(
                seconds: timeouts.operationSeconds, operation: "mail unread (index)"
            ) {
                try await index.unread(account: account, limit: maxN, offset: skip)
            }
        }

        let accountClause: String
        if let account, !account.isEmpty {
            let esc = Self.escapeForAppleScript(account)
            accountClause = "set acctList to {first account whose name is \"\(esc)\"}"
        } else {
            accountClause = "set acctList to accounts"
        }
        // No `try` around the mailbox walk: one that swallowed an Apple
        // Event timeout here would skip the mailbox and report the rest as
        // the complete answer.
        let body = """
        tell application "Mail"
            set out to ""
            set found to 0
            set skipped to 0
            \(accountClause)
            repeat with a in acctList
                if found \u{2265} \(maxN) then exit repeat
                set acctName to name of a
                repeat with m in mailboxes of a
                    if found \u{2265} \(maxN) then exit repeat
                    set unreadMsgs to (messages of m whose read status is false)
                    repeat with msg in unreadMsgs
                        if found \u{2265} \(maxN) then exit repeat
                        if skipped < \(skip) then
                            set skipped to skipped + 1
                        else
                            set subj to subject of msg
                            set sndr to sender of msg
                            set dateStr to (date sent of msg) as string
                            set mid to ""
                            try
                                set mid to message id of msg
                            end try
                            set out to out & my sanitize(subj) & "\t" & my sanitize(sndr) & "\t" & dateStr & "\t" & my sanitize(name of m) & "\t" & my sanitize(acctName) & "\t" & "" & "\t" & my sanitize(mid) & linefeed
                            set found to found + 1
                        end if
                    end repeat
                end repeat
            end repeat
            return out
        end tell

        on sanitize(s)
            set t to s as string
            set saved to AppleScript's text item delimiters
            set AppleScript's text item delimiters to {tab, linefeed, return}
            set parts to text items of t
            set AppleScript's text item delimiters to " "
            set t to parts as string
            set AppleScript's text item delimiters to saved
            return t
        end sanitize
        """
        let raw = try await withTimeout(
            seconds: timeouts.operationSeconds, operation: "mail unread (Mail.app)"
        ) {
            try await runner.run(source: timeouts.bound(body))
        }
        return Self.parseEmailLines(raw, defaultRead: false)
    }

    // MARK: - Search

    /// Default result limit when a caller supplies none.
    ///
    /// An unbounded search is never attempted: on the AppleScript backend
    /// it is the shape of query that wedges Mail.app, and on any backend it
    /// is a request nobody can use the answer to.
    public static let defaultLimit = 20

    /// Search mail, using the fastest backend available.
    ///
    /// Backends are tried in order — see ``SearchBackend``. The index is
    /// preferred for everything; Spotlight is consulted when the index is
    /// unavailable *and* the query isn't scoped to an account or mailbox
    /// (Spotlight can't express those); AppleScript is the last resort and
    /// is bounded on both sides.
    ///
    /// - Parameters:
    ///   - query: The search string. Supports multiple terms, `AND`/`OR`,
    ///     and `from:` / `to:` / `subject:` scoping — see ``MailQuery``.
    ///     An empty query throws rather than matching everything.
    ///   - limit: Maximum messages to return. Defaults to
    ///     ``defaultLimit``; capped at 100 per call — page with `offset`.
    ///   - account: Optional account scope.
    ///   - mailbox: Optional mailbox scope.
    ///   - sinceDaysAgo: Lower bound on message date, in days. Defaults
    ///     to 90.
    ///   - offset: Number of matching messages to skip, for paging.
    ///   - forceBackend: Pin the backend instead of letting the service
    ///     choose. Used by tests and by the diagnostics probe.
    /// - Returns: Matching messages, **newest first**.
    /// - Throws: ``MailQueryError/empty`` for a query with no terms;
    ///   ``MailServiceError/timedOut(operation:seconds:)`` when a backend
    ///   exceeded its bound — never an empty array;
    ///   ``MailServiceError/tooBroad(_:)`` when the only available backend
    ///   can't answer the query safely.
    public func search(
        query: String,
        limit: Int = MailService.defaultLimit,
        account: String? = nil,
        mailbox: String? = nil,
        sinceDaysAgo: Int = 90,
        offset: Int = 0,
        forceBackend: SearchBackend? = nil
    ) async throws -> [EmailMessage] {
        guard limit > 0 else { return [] }
        // Parse first: a malformed or empty query must fail as a query
        // problem, before any backend spends time on it.
        let parsed = try MailQuery.parse(query)
        let maxN = Self.cappedLimit(limit)
        let skip = max(0, offset)
        let scoped = account?.isEmpty == false || mailbox?.isEmpty == false

        // ── 1. Index ──────────────────────────────────────────────────────
        if forceBackend == nil || forceBackend == .index {
            if let index {
                return try await withTimeout(
                    seconds: timeouts.operationSeconds, operation: "mail search (index)"
                ) {
                    try await index.search(
                        query: parsed, account: account, mailbox: mailbox,
                        sinceDaysAgo: sinceDaysAgo, limit: maxN, offset: skip
                    )
                }
            }
            if forceBackend == .index {
                throw MailServiceError.tooBroad(
                    "The mail index is unavailable, so this query can't be answered " +
                        "quickly. Grant Full Disk Access to this binary in System Settings → " +
                        "Privacy & Security → Full Disk Access."
                )
            }
        }

        // ── 2. Spotlight ──────────────────────────────────────────────────
        // Can't scope by account/mailbox and can't page, so those force it
        // out. It is the only backend that reads message bodies.
        let allowSpotlight: Bool = {
            if let forced = forceBackend {
                return forced == .spotlight
            }
            return spotlight != nil && !scoped && skip == 0
        }()
        if allowSpotlight, let spotlight {
            let hits = try await withTimeout(
                seconds: timeouts.operationSeconds, operation: "mail search (spotlight)"
            ) {
                try await spotlight.search(
                    query: parsed, limit: maxN, sinceDaysAgo: sinceDaysAgo
                )
            }
            if !hits.isEmpty {
                return hits
            }
        }
        if forceBackend == .spotlight {
            return []
        }

        // ── 3. AppleScript ────────────────────────────────────────────────
        return try await searchViaAppleScript(
            parsed, limit: maxN, account: account, mailbox: mailbox,
            sinceDaysAgo: sinceDaysAgo, offset: skip
        )
    }

    /// The Mail.app-driving fallback.
    ///
    /// Every event is bounded by `with timeout`, and — critically — the
    /// per-mailbox `try` that used to wrap the `whose` is gone. That `try`
    /// swallowed Apple Event timeouts, skipped the mailbox, and let the
    /// script return `""`, which the caller read as "no matching mail".
    /// Now a timeout propagates and the caller is told which mailbox and
    /// which bound.
    ///
    /// The result is still not *fast* — nothing can make this path fast,
    /// because Mail's `whose` cost scales with the number of matches — but
    /// it is now bounded and honest about failing.
    private func searchViaAppleScript(
        _ parsed: MailQuery,
        limit maxN: Int,
        account: String?,
        mailbox: String?,
        sinceDaysAgo: Int,
        offset skip: Int
    ) async throws -> [EmailMessage] {
        // `to:` has no `whose` equivalent — Mail rejects it with
        // "Can't make … into type to recipient". Fail rather than silently
        // dropping the constraint and returning wrong results.
        let predicate: String
        do {
            predicate = try parsed.appleScriptPredicate()
        } catch let e as MailQueryError {
            if case .unsupportedField = e {
                throw MailServiceError.tooBroad(
                    "`to:` search needs the mail index, which is unavailable. Grant " +
                        "Full Disk Access to this binary, or search by `from:` or " +
                        "`subject:` instead."
                )
            }
            throw e
        }

        let mailboxScope: String
        if let account, !account.isEmpty {
            let ea = Self.escapeForAppleScript(account)
            if let mailbox, !mailbox.isEmpty {
                let em = Self.escapeForAppleScript(mailbox)
                mailboxScope = """
                set targetAcct to first account whose name is "\(ea)"
                set mbList to {first mailbox of targetAcct whose name is "\(em)"}
                """
            } else {
                mailboxScope = """
                set targetAcct to first account whose name is "\(ea)"
                set mbList to mailboxes of targetAcct
                """
            }
        } else {
            mailboxScope = """
            set mbList to {}
            repeat with a in accounts
                set mbList to mbList & mailboxes of a
            end repeat
            """
        }

        // The account name is resolved once, not once per mailbox: the old
        // `first account whose mailboxes contains m` ran inside the loop and
        // made Mail enumerate every mailbox of every account each time.
        let acctResolve = (account?.isEmpty == false)
            ? "set acctName to \"\(Self.escapeForAppleScript(account!))\""
            : "set acctName to \"\""

        let body = """
        set cutoff to (current date) - (\(sinceDaysAgo) * days)
        tell application "Mail"
            set out to ""
            set found to 0
            set skipped to 0
            \(mailboxScope)
            \(acctResolve)
            repeat with m in mbList
                if found \u{2265} \(maxN) then exit repeat
                set matchMsgs to (messages of m whose \(predicate) and (date sent > cutoff))
                repeat with msg in matchMsgs
                    if found \u{2265} \(maxN) then exit repeat
                    if skipped < \(skip) then
                        set skipped to skipped + 1
                    else
                        set subj to subject of msg
                        set sndr to sender of msg
                        set dateStr to (date sent of msg) as string
                        set d to date sent of msg
                        set sortKey to (year of d as string) & "-" & my pad2(month of d as integer) & "-" & my pad2(day of d) & "T" & my pad2(hours of d) & ":" & my pad2(minutes of d) & ":" & my pad2(seconds of d)
                        set isRead to read status of msg
                        set mid to ""
                        try
                            set mid to message id of msg
                        end try
                        set out to out & my sanitize(subj) & "\t" & my sanitize(sndr) & "\t" & dateStr & "\t" & my sanitize(name of m) & "\t" & my sanitize(acctName) & "\t" & (isRead as string) & "\t" & "" & "\t" & my sanitize(mid) & "\t" & (sortKey as string) & linefeed
                        set found to found + 1
                    end if
                end repeat
            end repeat
            return out
        end tell

        on sanitize(s)
            set t to s as string
            set saved to AppleScript's text item delimiters
            set AppleScript's text item delimiters to {tab, linefeed, return}
            set parts to text items of t
            set AppleScript's text item delimiters to " "
            set t to parts as string
            set AppleScript's text item delimiters to saved
            return t
        end sanitize

        on pad2(n)
            set v to n as integer
            if v < 10 then return "0" & (v as string)
            return v as string
        end pad2
        """

        let raw = try await withTimeout(
            seconds: timeouts.operationSeconds, operation: "mail search (Mail.app)"
        ) {
            try await runner.run(source: timeouts.bound(body))
        }
        // Mail returns matches in mailbox-iteration order, so sorting is
        // ours to do — the AppleScript surface offers no ordering at all.
        return Self.parseSearchLines(raw)
    }

    // MARK: - Send

    /// Composes and sends a new message through Mail.app. The body is
    /// written to a temp file and read back inside the AppleScript so
    /// multi-line content and embedded quotes pass through verbatim
    /// without manual escaping.
    ///
    /// - Parameters:
    ///   - to: Primary recipient email. Required, non-empty.
    ///   - subject: Subject line. Required, non-empty.
    ///   - body: Body text (UTF-8, multi-line OK). Required, non-empty.
    ///   - cc: Optional CC recipient.
    ///   - bcc: Optional BCC recipient.
    /// - Throws: `MailServiceError.invalidInput` when any required
    ///   parameter is empty; `MailServiceError.scriptFailure` if Mail
    ///   doesn't confirm the send; `AppleScriptError.runtime` for a
    ///   permissions error or Mail not running.
    public func send(
        to: String, subject: String, body: String,
        cc: String? = nil, bcc: String? = nil
    ) async throws {
        guard !to.trimmingCharacters(in: .whitespaces).isEmpty,
              !subject.trimmingCharacters(in: .whitespaces).isEmpty,
              !body.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw MailServiceError.invalidInput("to, subject, and body are all required")
        }
        // File-based body to avoid AppleScript string-escaping hell for
        // multi-line content. Same trick the Node port uses.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apple-mcp-mail-\(UUID().uuidString).txt")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let esc: (String) -> String = { Self.escapeForAppleScript($0) }
        let subjectQ = esc(subject)
        let toQ = esc(to)
        let ccLine = (cc?.nonEmpty).map {
            "make new cc recipient with properties {address:\"\(esc($0))\"}"
        } ?? ""
        let bccLine = (bcc?.nonEmpty).map {
            "make new bcc recipient with properties {address:\"\(esc($0))\"}"
        } ?? ""

        let source = """
        tell application "Mail"
            activate
            set emailBody to read file POSIX file "\(tmp.path)" as «class utf8»
            set newMessage to make new outgoing message with properties {subject:"\(subjectQ)", content:emailBody, visible:false}
            tell newMessage
                make new to recipient with properties {address:"\(toQ)"}
                \(ccLine)
                \(bccLine)
            end tell
            send newMessage
            return "SENT"
        end tell
        """
        let result = try await withTimeout(
            seconds: timeouts.sendSeconds, operation: "mail send"
        ) {
            try await runner.run(source: timeouts.bound(source, seconds: Int(timeouts.sendSeconds)))
        }
        guard result.trimmingCharacters(in: .whitespaces) == "SENT" else {
            throw MailServiceError.scriptFailure("Mail returned: \(result)")
        }
    }

    // MARK: - Get full message

    /// Field delimiter for ``getMessageScript(id:)`` output. ASCII record
    /// separator (`U+001E`) — a full message body contains arbitrary
    /// newlines and tabs, so the tab/newline scheme used by list/search
    /// can't be reused here.
    public static let detailFieldSeparator = "\u{001E}"

    /// Preview-body cap for list/search snippets (``EmailMessage/content``).
    /// A preview is scannable, not complete — use ``getMessage(id:account:)``
    /// for the full body.
    static let previewMaxLength = 300

    /// Safety ceiling on list/search result counts. AppleScript is ~per-
    /// message slow, so an unbounded limit could hang Mail; combine `limit`
    /// with `offset` to page beyond this. Callers guard non-positive
    /// limits (returning `[]`) before this is applied.
    static func cappedLimit(_ limit: Int) -> Int { min(limit, 100) }

    /// Fetches a single message's **complete, untruncated** body by its RFC
    /// `Message-ID` (as returned in ``EmailMessage/messageId`` from
    /// ``getUnread(limit:account:offset:)`` /
    /// ``search(query:limit:account:mailbox:sinceDaysAgo:offset:forceBackend:)``).
    ///
    /// - Parameters:
    ///   - id: The message's `Message-ID`. Empty/whitespace throws
    ///     ``MailServiceError/invalidInput(_:)`` without running a script.
    ///   - account: Optional account name to scope (and speed up) the
    ///     lookup. When `nil`, every account's mailboxes are searched,
    ///     which can be slow on large libraries.
    /// - Returns: The message's full contents.
    /// - Throws: ``MailServiceError/invalidInput(_:)`` for an empty id;
    ///   ``MailServiceError/scriptFailure(_:)`` when no message with that
    ///   id was found; `AppleScriptError` when Mail isn't running or
    ///   Automation is denied.
    public func getMessage(id: String, account: String? = nil) async throws -> MailMessageDetail {
        guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MailServiceError.invalidInput("message id required")
        }
        let raw = try await withTimeout(
            seconds: timeouts.operationSeconds, operation: "mail get"
        ) {
            try await runner.run(
                source: timeouts.bound(Self.getMessageScript(id: id, account: account))
            )
        }
        guard let detail = Self.parseMessageDetail(raw) else {
            throw MailServiceError.scriptFailure(
                "no message found with id \(id)"
            )
        }
        return detail
    }

    /// Builds the get-message-by-id AppleScript. Emits eight
    /// ``detailFieldSeparator``-delimited fields: messageId, subject,
    /// sender, date, mailbox, account, isRead, and the full body last (it
    /// can contain newlines/tabs, which is why the parser rejoins
    /// `fields[7...]` rather than taking a single element).
    static func getMessageScript(id: String, account: String? = nil) -> String {
        let escId = escapeForAppleScript(id)
        let scope: String
        if let account, !account.isEmpty {
            let ea = escapeForAppleScript(account)
            scope = """
            set mbList to mailboxes of (first account whose name is "\(ea)")
            set acctName to "\(ea)"
            """
        } else {
            // The old version resolved the account per mailbox with
            // `first account whose mailboxes contains m`, which makes Mail
            // enumerate every mailbox of every account on each iteration.
            scope = """
            set mbList to {}
            set acctName to ""
            repeat with a in accounts
                set mbList to mbList & mailboxes of a
            end repeat
            """
        }
        return """
        tell application "Mail"
            set sep to (ASCII character 30)
            \(scope)
            repeat with m in mbList
                set hits to (messages of m whose message id is "\(escId)")
                if (count of hits) > 0 then
                    set msg to item 1 of hits
                    set body to ""
                    try
                        set body to content of msg
                    end try
                    return (message id of msg) & sep & my ln(subject of msg) & sep & my ln(sender of msg) & sep & ((date sent of msg) as string) & sep & my ln(name of m) & sep & my ln(acctName) & sep & (read status of msg as string) & sep & body
                end if
            end repeat
            return ""
        end tell

        on ln(s)
            set t to s as string
            set saved to AppleScript's text item delimiters
            set AppleScript's text item delimiters to {tab, linefeed, return}
            set parts to text items of t
            set AppleScript's text item delimiters to " "
            set t to parts as string
            set AppleScript's text item delimiters to saved
            return t
        end ln
        """
    }

    /// Parses the record-separated output of ``getMessageScript(id:account:)``
    /// into a ``MailMessageDetail``. The body (last field) is preserved
    /// verbatim — newlines intact. Returns `nil` for an empty/short result.
    static func parseMessageDetail(_ raw: String) -> MailMessageDetail? {
        let sep = Character(detailFieldSeparator)
        let fields = raw.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 8 else { return nil }
        let body = fields[7...].joined(separator: detailFieldSeparator)
        let mailbox = fields[5].isEmpty ? fields[4] : "\(fields[5]) — \(fields[4])"
        return MailMessageDetail(
            messageId: fields[0],
            subject: fields[1],
            sender: fields[2],
            dateSent: fields[3],
            mailbox: mailbox,
            isRead: fields[6].lowercased() == "true",
            body: body
        )
    }

    // MARK: - AppleScript escaping

    /// Escapes a string for interpolation inside a double-quoted AppleScript
    /// string literal. Backslashes are doubled *first*, then quotes are
    /// escaped — so a value ending in `\` (or containing `\"`) can't break
    /// out of the literal and execute as AppleScript. Same approach the
    /// sibling swift-photos-automation kit uses.
    ///
    /// Exposed as `internal static` so tests can hit it directly.
    static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Parse

    /// Parses the AppleScript search format and returns results
    /// **newest-first**.
    ///
    /// The wire format carries a trailing locale-independent sort key
    /// (`YYYY-MM-DDTHH:MM:SS`, built from the date's components rather than
    /// its string rendering) because Mail's `whose` has no ordering: it
    /// yields matches in mailbox-iteration order, so an unsorted `limit`
    /// returns whichever label Mail happened to walk first rather than the
    /// most recent mail. Rows with no usable key sort last rather than
    /// being dropped.
    static func parseSearchLines(_ raw: String) -> [EmailMessage] {
        let rows: [(EmailMessage, String)] = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count >= 7 else { return nil }
                let mailbox = fields[4].isEmpty
                    ? fields[3]
                    : "\(fields[4]) — \(fields[3])"
                let body = fields[6]
                let msg = EmailMessage(
                    subject: fields[0],
                    sender: fields[1],
                    dateSent: fields[2],
                    content: body.isEmpty ? "[Content not available]" : body,
                    isRead: fields[5].lowercased() == "true",
                    mailbox: mailbox,
                    messageId: fields.count >= 8 ? fields[7] : ""
                )
                return (msg, fields.count >= 9 ? fields[8] : "")
            }
        return rows
            .enumerated()
            .sorted { a, b in
                // Empty keys sort last; ties keep source order so the
                // result is deterministic.
                switch (a.element.1.isEmpty, b.element.1.isEmpty) {
                case (true, false): return false
                case (false, true): return true
                case (true, true): return a.offset < b.offset
                case (false, false):
                    if a.element.1 == b.element.1 {
                        return a.offset < b.offset
                    }
                    return a.element.1 > b.element.1
                }
            }
            .map(\.element.0)
    }

    /// Parse the tab-delimited email records produced by our AppleScript.
    /// Exposed as `internal static` so tests can hit it directly.
    static func parseEmailLines(
        _ raw: String,
        defaultRead: Bool,
        includeReadField: Bool = false
    ) -> [EmailMessage] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            // Expected shape:
            //   unread/includeReadField=false: subject, sender, date, mailbox, account, body  (6)
            //   search/includeReadField=true:  subject, sender, date, mailbox, account, isRead, body  (7)
            let needed = includeReadField ? 7 : 6
            guard fields.count >= needed else { return nil }
            let isRead: Bool
            let body: String
            let messageId: String
            if includeReadField {
                isRead = fields[5].lowercased() == "true"
                body = fields[6]
                // Optional trailing Message-ID (8-field format). Absent in
                // the legacy 7-field format.
                messageId = fields.count >= 8 ? fields[7] : ""
            } else {
                isRead = defaultRead
                body = fields[5]
                // Optional trailing Message-ID (7-field format).
                messageId = fields.count >= 7 ? fields[6] : ""
            }
            let mailbox = fields[4].isEmpty
                ? fields[3]
                : "\(fields[4]) — \(fields[3])"
            return EmailMessage(
                subject: fields[0],
                sender: fields[1],
                dateSent: fields[2],
                content: body.isEmpty ? "[Content not available]" : body,
                isRead: isRead,
                mailbox: mailbox,
                messageId: messageId
            )
        }
    }
}
