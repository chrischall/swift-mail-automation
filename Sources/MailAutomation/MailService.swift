import Foundation

public enum MailServiceError: Error, Equatable, Sendable {
    case scriptFailure(String)
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
/// ceiling as the Node port, just with no subprocess-spawn overhead.
///
/// Operations:
/// - `unread`: read unread across all accounts (slow on Gmail-heavy setups)
/// - `search`: subject substring, bounded by a date range (same whose()
///   pattern we found 10× faster in the Node port)
/// - `send`: create and send, with optional cc/bcc
/// - `listAccounts` / `listMailboxes`: discovery
public struct MailService: Sendable {
    private let runner: any AppleScriptRunner
    private let spotlight: SpotlightMailSearch?

    public init(
        runner: any AppleScriptRunner,
        spotlight: SpotlightMailSearch? = SpotlightMailSearch()
    ) {
        self.runner = runner
        self.spotlight = spotlight
    }

    // MARK: - Discovery

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

    public func listMailboxes(account: String) async throws -> [String] {
        guard !account.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MailServiceError.invalidInput("account name required")
        }
        let esc = account.replacingOccurrences(of: "\"", with: "\\\"")
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

    public func getUnread(limit: Int = 10, account: String? = nil) async throws -> [EmailMessage] {
        let maxN = min(limit, 20)
        let accountClause: String
        if let account, !account.isEmpty {
            let esc = account.replacingOccurrences(of: "\"", with: "\\\"")
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
                                    set out to out & subj & "\t" & sndr & "\t" & dateStr & "\t" & (name of m) & "\t" & acctName & "\t" & my sanitize(body) & linefeed
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

    /// Search by subject/body substring.
    ///
    /// Two backends, in priority order:
    ///   1. **Spotlight** (`mdfind`) — instant, searches subject+body across
    ///      every .emlx on disk. Read status isn't indexed so results
    ///      always show `isRead=true`. If `account` or `mailbox` is passed,
    ///      we fall through to AppleScript instead since Spotlight doesn't
    ///      know about Mail's account/mailbox grouping beyond the path.
    ///   2. **AppleScript whose() with date bound** — slower but exposes
    ///      account + mailbox scoping and real read status.
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
        let escQuery = query.replacingOccurrences(of: "\"", with: "\\\"")

        let mailboxScope: String
        if let account, !account.isEmpty {
            let ea = account.replacingOccurrences(of: "\"", with: "\\\"")
            if let mailbox, !mailbox.isEmpty {
                let em = mailbox.replacingOccurrences(of: "\"", with: "\\\"")
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
                            set out to out & subj & "\t" & sndr & "\t" & dateStr & "\t" & (name of m) & "\t" & acctName & "\t" & (isRead as string) & "\t" & my sanitize(body) & linefeed
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

    public func send(
        to: String, subject: String, body: String,
        cc: String? = nil, bcc: String? = nil
    ) async throws {
        guard !to.trimmingCharacters(in: .whitespaces).isEmpty,
              !subject.trimmingCharacters(in: .whitespaces).isEmpty,
              !body.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MailServiceError.invalidInput("to, subject, and body are all required")
        }
        // File-based body to avoid AppleScript string-escaping hell for
        // multi-line content. Same trick the Node port uses.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apple-mcp-mail-\(UUID().uuidString).txt")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let esc: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "\\\"") }
        let ccLine = cc.flatMap { $0.isEmpty ? nil : $0 }.map {
            "make new cc recipient with properties {address:\"\(esc($0))\"}"
        } ?? ""
        let bccLine = bcc.flatMap { $0.isEmpty ? nil : $0 }.map {
            "make new bcc recipient with properties {address:\"\(esc($0))\"}"
        } ?? ""

        let source = """
        tell application "Mail"
            activate
            set emailBody to read file POSIX file "\(tmp.path)" as «class utf8»
            set newMessage to make new outgoing message with properties {subject:"\(esc(subject))", content:emailBody, visible:false}
            tell newMessage
                make new to recipient with properties {address:"\(esc(to))"}
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
