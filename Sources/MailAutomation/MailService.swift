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
}

/// Which search backend to use. `spotlight` is fast (sub-second) but has
/// no notion of account/mailbox or read-state. `applescript` is slower
/// but scopes by account/mailbox and knows read state.
public enum SearchBackend: String, Sendable {
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
        spotlight: SpotlightMailSearch? = SpotlightMailSearch()
    ) {
        self.runner = runner
        self.spotlight = spotlight
    }

    // MARK: - Discovery

    /// Returns the names of every account configured in Mail.app
    /// (`"iCloud"`, `"Google"`, `"Work"`, …). Use these strings as the
    /// `account` parameter to `listMailboxes`, `getUnread`, and `search`.
    ///
    /// - Returns: Account names in Mail.app's configured order.
    /// - Throws: `AppleScriptError.runtime` if Mail is not running or
    ///   Automation permission is denied.
    public func listAccounts() async throws -> [String] {
        let result = try await runner.run(source: """
        tell application "Mail"
            set out to ""
            repeat with a in accounts
                try
                    set out to out & (name of a) & linefeed
                end try
            end repeat
            return out
        end tell
        """)
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
        let result = try await runner.run(source: """
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
        """)
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
    ///   - limit: Maximum messages to return. Internally capped at 20.
    ///   - account: Optional account name from `listAccounts()` to scope
    ///     the search. When `nil`, iterates all accounts.
    /// - Returns: Messages in mailbox-iteration order (not strictly date-
    ///   sorted). Each `EmailMessage` has `isRead == false`.
    public func getUnread(limit: Int = 10, account: String? = nil) async throws -> [EmailMessage] {
        let maxN = min(limit, 20)
        let accountClause: String
        if let account, !account.isEmpty {
            let esc = Self.escapeForAppleScript(account)
            accountClause = "set acctList to {first account whose name is \"\(esc)\"}"
        } else {
            accountClause = "set acctList to accounts"
        }
        let source = """
        tell application "Mail"
            set out to ""
            set found to 0
            \(accountClause)
            repeat with a in acctList
                if found \u{2265} \(maxN) then exit repeat
                try
                    set acctName to name of a
                    repeat with m in mailboxes of a
                        if found \u{2265} \(maxN) then exit repeat
                        try
                            set unreadMsgs to (messages of m whose read status is false)
                            repeat with msg in unreadMsgs
                                if found \u{2265} \(maxN) then exit repeat
                                try
                                    set subj to subject of msg
                                    set sndr to sender of msg
                                    set dateStr to (date sent of msg) as string
                                    set body to ""
                                    try
                                        set body to content of msg
                                        if (length of body) > 300 then set body to (text 1 thru 300 of body) & "..."
                                    end try
                                    set out to out & my sanitize(subj) & "\t" & my sanitize(sndr) & "\t" & dateStr & "\t" & (name of m) & "\t" & acctName & "\t" & my sanitize(body) & linefeed
                                    set found to found + 1
                                end try
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
            return out
        end tell

        on sanitize(s)
            set s to do shell script "printf %s " & quoted form of s & " | tr '\\t\\n\\r' '   '"
            return s
        end sanitize
        """
        let raw = try await runner.run(source: source)
        return Self.parseEmailLines(raw, defaultRead: false)
    }

    // MARK: - Search

    /// Search by subject/body substring, using the fastest available
    /// backend.
    ///
    /// Two backends, in priority order:
    ///   1. **Spotlight** (`mdfind`) — instant, searches subject+body across
    ///      every `.emlx` on disk. Read status isn't indexed so results
    ///      always show `isRead == true`. Skipped when `account` or
    ///      `mailbox` is passed, since Spotlight doesn't understand Mail's
    ///      account/mailbox grouping beyond the on-disk path.
    ///   2. **AppleScript `whose()` with date bound** — slower but exposes
    ///      account + mailbox scoping and real read status.
    ///
    /// - Parameters:
    ///   - query: Substring to match against subject (AppleScript path)
    ///     or subject+body (Spotlight). Whitespace-only returns `[]`.
    ///   - limit: Maximum messages to return. Internally capped at 20 on
    ///     the AppleScript path; Spotlight honors the limit directly.
    ///   - account: Optional account scope. Setting this forces the
    ///     AppleScript path.
    ///   - mailbox: Optional mailbox scope. Ignored unless `account` is
    ///     also set. Setting this forces the AppleScript path.
    ///   - sinceDaysAgo: Lower bound on message date, in days. Defaults
    ///     to 90.
    ///   - forceBackend: Override the automatic backend selection. When
    ///     `.spotlight` is forced and Spotlight yields nothing (or is not
    ///     configured), returns `[]` without consulting AppleScript. When
    ///     `.applescript` is forced, Spotlight is skipped entirely.
    /// - Returns: Matching messages. Order is backend-defined (path order
    ///   from `mdfind`, mailbox-iteration order from AppleScript).
    /// - Throws: `AppleScriptError` or anything the Spotlight runner
    ///   throws.
    public func search(
        query: String,
        limit: Int = 10,
        account: String? = nil,
        mailbox: String? = nil,
        sinceDaysAgo: Int = 90,
        forceBackend: SearchBackend? = nil
    ) async throws -> [EmailMessage] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        // Pick backend. Spotlight is fast but depends on user system state
        // (Mail indexed, not excluded in Search Privacy, this binary having
        // FDA). When available and not explicitly overridden, try it
        // first; fall back to AppleScript if it yields nothing — that
        // covers both "Spotlight is disabled" and "legitimately no
        // matches, but AppleScript is also going to return nothing fast".
        //
        // Account/mailbox scoping → skip Spotlight straight away, it
        // doesn't know about Mail's account/mailbox grouping beyond
        // what we parse from the file path.
        let scoped = account?.isEmpty == false || mailbox?.isEmpty == false
        let allowSpotlight: Bool = {
            if let forced = forceBackend { return forced == .spotlight }
            if scoped { return false }
            return spotlight != nil
        }()

        if allowSpotlight, let spotlight {
            let hits = try await spotlight.search(
                query: query, limit: limit, sinceDaysAgo: sinceDaysAgo
            )
            if !hits.isEmpty {
                return hits
            }
            // empty → continue to AppleScript fallback below
        }
        // Explicitly requested Spotlight but fell through → don't run the
        // AppleScript path, just return empty.
        if forceBackend == .spotlight {
            return []
        }
        let maxN = min(limit, 20)
        let escQuery = Self.escapeForAppleScript(query)

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
                try
                    set mbList to mbList & mailboxes of a
                end try
            end repeat
            """
        }

        let source = """
        set cutoff to (current date) - (\(sinceDaysAgo) * days)
        tell application "Mail"
            set out to ""
            set found to 0
            \(mailboxScope)
            repeat with m in mbList
                if found \u{2265} \(maxN) then exit repeat
                try
                    set matchMsgs to (messages of m whose (subject contains "\(escQuery)") and (date sent > cutoff))
                    set acctName to ""
                    try
                        set acctName to name of (first account whose mailboxes contains m)
                    end try
                    repeat with msg in matchMsgs
                        if found \u{2265} \(maxN) then exit repeat
                        try
                            set subj to subject of msg
                            set sndr to sender of msg
                            set dateStr to (date sent of msg) as string
                            set isRead to read status of msg
                            set body to ""
                            try
                                set body to content of msg
                                if (length of body) > 300 then set body to (text 1 thru 300 of body) & "..."
                            end try
                            set out to out & my sanitize(subj) & "\t" & my sanitize(sndr) & "\t" & dateStr & "\t" & (name of m) & "\t" & acctName & "\t" & (isRead as string) & "\t" & my sanitize(body) & linefeed
                            set found to found + 1
                        end try
                    end repeat
                end try
            end repeat
            return out
        end tell

        on sanitize(s)
            try
                set s to do shell script "printf %s " & quoted form of s & " | tr '\\t\\n\\r' '   '"
            end try
            return s
        end sanitize
        """
        let raw = try await runner.run(source: source)
        return Self.parseEmailLines(raw, defaultRead: true, includeReadField: true)
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
        let result = try await runner.run(source: source)
        guard result.trimmingCharacters(in: .whitespaces) == "SENT" else {
            throw MailServiceError.scriptFailure("Mail returned: \(result)")
        }
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
            if includeReadField {
                isRead = fields[5].lowercased() == "true"
                body = fields[6]
            } else {
                isRead = defaultRead
                body = fields[5]
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
                mailbox: mailbox
            )
        }
    }
}
