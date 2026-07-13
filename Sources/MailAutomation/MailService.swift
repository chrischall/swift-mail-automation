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
    public func getUnread(
        limit: Int = 10,
        account: String? = nil,
        offset: Int = 0
    ) async throws -> [EmailMessage] {
        let maxN = Self.cappedLimit(limit)
        let skip = max(0, offset)
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
            set skipped to 0
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
                                if skipped < \(skip) then
                                    set skipped to skipped + 1
                                else
                                    try
                                        set subj to subject of msg
                                        set sndr to sender of msg
                                        set dateStr to (date sent of msg) as string
                                        set mid to ""
                                        try
                                            set mid to message id of msg
                                        end try
                                        set body to ""
                                        try
                                            set body to content of msg
                                            if (length of body) > \(Self.previewMaxLength) then set body to (text 1 thru \(Self.previewMaxLength) of body) & "..."
                                        end try
                                        set out to out & my sanitize(subj) & "\t" & my sanitize(sndr) & "\t" & dateStr & "\t" & my sanitize(name of m) & "\t" & my sanitize(acctName) & "\t" & my sanitize(body) & "\t" & my sanitize(mid) & linefeed
                                        set found to found + 1
                                    end try
                                end if
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
        offset: Int = 0,
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
        // Spotlight can't scope by account/mailbox and can't page, so any of
        // those forces the AppleScript path.
        let scoped = account?.isEmpty == false || mailbox?.isEmpty == false || offset > 0
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
        let maxN = Self.cappedLimit(limit)
        let skip = max(0, offset)
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
            set skipped to 0
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
                        if skipped < \(skip) then
                            set skipped to skipped + 1
                        else
                            try
                                set subj to subject of msg
                                set sndr to sender of msg
                                set dateStr to (date sent of msg) as string
                                set isRead to read status of msg
                                set mid to ""
                                try
                                    set mid to message id of msg
                                end try
                                set body to ""
                                try
                                    set body to content of msg
                                    if (length of body) > \(Self.previewMaxLength) then set body to (text 1 thru \(Self.previewMaxLength) of body) & "..."
                                end try
                                set out to out & my sanitize(subj) & "\t" & my sanitize(sndr) & "\t" & dateStr & "\t" & my sanitize(name of m) & "\t" & my sanitize(acctName) & "\t" & (isRead as string) & "\t" & my sanitize(body) & "\t" & my sanitize(mid) & linefeed
                                set found to found + 1
                            end try
                        end if
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
    /// with `offset` to page beyond this.
    static func cappedLimit(_ limit: Int) -> Int { min(max(limit, 1), 100) }

    /// Fetches a single message's **complete, untruncated** body by its RFC
    /// `Message-ID` (as returned in ``EmailMessage/messageId`` from
    /// ``getUnread(limit:account:offset:)`` / ``search(query:limit:account:mailbox:sinceDaysAgo:offset:forceBackend:)``).
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
        let raw = try await runner.run(source: Self.getMessageScript(id: id, account: account))
        guard let detail = Self.parseMessageDetail(raw) else {
            throw MailServiceError.scriptFailure(
                "no message found with id \(id)"
            )
        }
        return detail
    }

    /// Builds the get-message-by-id AppleScript. Emits seven
    /// ``detailFieldSeparator``-delimited fields: messageId, subject,
    /// sender, date, mailbox, account, isRead, and the full body last (it
    /// can contain newlines/tabs).
    static func getMessageScript(id: String, account: String? = nil) -> String {
        let escId = escapeForAppleScript(id)
        let scope: String
        if let account, !account.isEmpty {
            let ea = escapeForAppleScript(account)
            scope = """
            set mbList to mailboxes of (first account whose name is "\(ea)")
            """
        } else {
            scope = """
            set mbList to {}
            repeat with a in accounts
                try
                    set mbList to mbList & mailboxes of a
                end try
            end repeat
            """
        }
        return """
        tell application "Mail"
            set sep to (ASCII character 30)
            \(scope)
            repeat with m in mbList
                try
                    set hits to (messages of m whose message id is "\(escId)")
                    if (count of hits) > 0 then
                        set msg to item 1 of hits
                        set acctName to ""
                        try
                            set acctName to name of (first account whose mailboxes contains m)
                        end try
                        set body to ""
                        try
                            set body to content of msg
                        end try
                        return (message id of msg) & sep & my ln(subject of msg) & sep & my ln(sender of msg) & sep & ((date sent of msg) as string) & sep & my ln(name of m) & sep & my ln(acctName) & sep & (read status of msg as string) & sep & body
                    end if
                end try
            end repeat
            return ""
        end tell

        on ln(s)
            try
                set s to do shell script "printf %s " & quoted form of s & " | tr '\\t\\n\\r' '   '"
            end try
            return s
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
