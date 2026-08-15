import Foundation
import SQLite3

/// Errors raised by ``MailIndexReader``.
public enum MailIndexReaderError: Error, Equatable, Sendable {
    /// The Envelope Index couldn't be opened — missing, or (much more
    /// commonly) the calling binary lacks Full Disk Access. Message names
    /// the path and the underlying SQLite reason.
    case databaseNotAccessible(String)
    /// A query failed. Usually means Apple changed the schema; fail loudly
    /// so the caller can fall back rather than silently returning nothing.
    case sqliteError(String)
}

/// Read-only view of Mail.app's **Envelope Index** — the SQLite database
/// Mail maintains of every message's envelope (subject, sender,
/// recipients, date, mailbox, read state).
///
/// ## Why this exists
///
/// Driving Mail.app over AppleScript to search is not merely slow, it is
/// unusable on a large account, and the cost is not in any part the caller
/// controls. Measured on a Gmail account of ~458,000 messages across 28
/// mailboxes, searching subjects over a 45-day window:
///
/// | matches in one mailbox | Mail.app `whose` | this reader |
/// |---|---|---|
/// | 0 | 0.5 s | — |
/// | 18 | 23.7 s | — |
/// | 153 | **154 s** | **0.05 s** |
///
/// The `whose` cost tracks the number of *matches*, not the limit, because
/// Mail instantiates every match before it can answer. A `count of` costs
/// the same as fetching, so there is no cheap way to ask Mail "how many
/// would this return?" before committing. That rules out bounding the
/// AppleScript backend by pre-counting, and is why the index is the
/// primary backend rather than an optimisation.
///
/// The same query that takes Mail 154 s takes this reader 0.05 s, returns
/// results sorted newest-first (Mail's `whose` has no ordering at all),
/// and applies `limit` inside the query rather than after the work is
/// already done.
///
/// ## Permissions
///
/// The index lives under `~/Library/Mail/`, which macOS gates behind
/// **Full Disk Access**. FDA is not an `Info.plist` key — it's a user
/// toggle in *System Settings → Privacy & Security → Full Disk Access*.
/// ``init(path:accountsPath:)`` throws
/// ``MailIndexReaderError/databaseNotAccessible(_:)`` when it can't open
/// the file; callers should treat that as "fall back to another backend",
/// not as a fatal error.
///
/// ## Concurrent safety
///
/// An `actor`, so concurrent callers serialise. Each query opens its own
/// handle read-write + `PRAGMA query_only = 1`; Mail commits through WAL
/// while we read, and a long-lived read-only handle can't refresh its
/// snapshot (it can't write the `-shm` file that coordinates one), so it
/// would serve staler and staler results the longer the server ran.
///
/// ## Schema assumptions
///
/// Targets the Mail schema on macOS 14+ (`~/Library/Mail/V10/`):
/// `messages` joined to `subjects`, `addresses`, `mailboxes`, `recipients`
/// and `message_global_data` (which carries the RFC `Message-ID` header).
/// `messages.date_sent` is Unix epoch seconds. If Apple renames these the
/// queries throw ``MailIndexReaderError/sqliteError(_:)`` rather than
/// quietly returning nothing.
public actor MailIndexReader {
    /// Default location of Mail's Envelope Index.
    ///
    /// Resolved by globbing `~/Library/Mail/V*/MailData/Envelope Index` and
    /// taking the highest version directory, so a future `V11` is picked up
    /// without a code change.
    public static var defaultDatabasePath: String? {
        let root = "\(NSHomeDirectory())/Library/Mail"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root))?
            .filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
            .sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
        guard let latest = versions?.last else { return nil }
        return "\(root)/\(latest)/MailData/Envelope Index"
    }

    /// Default location of the system Accounts database, which maps Mail's
    /// account UUIDs to the display names users actually type (`"Google"`,
    /// `"iCloud"`).
    public static var defaultAccountsPath: String {
        "\(NSHomeDirectory())/Library/Accounts/Accounts4.sqlite"
    }

    private let path: String
    private let accountsPath: String
    /// account UUID → display name, resolved once at init.
    private let accountNames: [String: String]

    /// Opens the Envelope Index.
    ///
    /// - Parameters:
    ///   - path: Absolute path to `Envelope Index`. Defaults to
    ///     ``defaultDatabasePath``. Tests pass a fixture here.
    ///   - accountsPath: Absolute path to `Accounts4.sqlite`, used only to
    ///     resolve account display names. A missing or unreadable file is
    ///     tolerated — accounts then surface by UUID.
    /// - Throws: ``MailIndexReaderError/databaseNotAccessible(_:)``.
    public init(
        path: String? = MailIndexReader.defaultDatabasePath,
        accountsPath: String = MailIndexReader.defaultAccountsPath
    ) throws {
        guard let path else {
            throw MailIndexReaderError.databaseNotAccessible(
                "No ~/Library/Mail/V*/MailData/Envelope Index found. Is Mail.app configured?"
            )
        }
        self.path = path
        self.accountsPath = accountsPath
        // Verify access eagerly so callers learn at startup, not on the
        // first user-visible query.
        let handle = try Self.openHandle(path: path)
        sqlite3_close_v2(handle)
        accountNames = Self.loadAccountNames(path: accountsPath)
    }

    // MARK: - Handle management

    /// Opens a fresh SQLite handle for one query. Callers must close it.
    ///
    /// Read-write + `PRAGMA query_only = 1` rather than
    /// `SQLITE_OPEN_READONLY`, for the WAL-refresh reason in the type docs.
    /// The pragma is the guardrail that keeps a writable handle from ever
    /// mutating Mail's index, so its failure is fatal, never swallowed.
    private static func openHandle(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned \(rc)"
            if let h = handle {
                sqlite3_close_v2(h)
            }
            throw MailIndexReaderError.databaseNotAccessible(
                "Cannot open \(path): \(msg). On macOS, grant Full Disk Access " +
                    "to the calling binary in System Settings → Privacy & Security → " +
                    "Full Disk Access."
            )
        }
        let pragmaRC = sqlite3_exec(handle, "PRAGMA query_only = 1", nil, nil, nil)
        guard pragmaRC == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_close_v2(handle)
            throw MailIndexReaderError.databaseNotAccessible(
                "Failed to set PRAGMA query_only on \(path): \(msg). Refusing to " +
                    "return a writable handle to Mail's index."
            )
        }
        return handle
    }

    // MARK: - Account names

    /// Maps Mail account UUIDs to display names via `Accounts4.sqlite`.
    ///
    /// Mail's own store only ever refers to accounts by UUID (embedded in
    /// `mailboxes.url`), while users type `"Google"`. The friendly name
    /// lives on the *parent* account row for IMAP children, so both are
    /// consulted. Best-effort throughout: this is a nicety, and a failure
    /// here must not stop mail search working.
    private static func loadAccountNames(path: String) -> [String: String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle
        else {
            if let h = handle {
                sqlite3_close_v2(h)
            }
            return [:]
        }
        defer { sqlite3_close_v2(db) }

        let sql = """
        SELECT a.ZIDENTIFIER,
               COALESCE(NULLIF(a.ZACCOUNTDESCRIPTION, ''), p.ZACCOUNTDESCRIPTION)
        FROM ZACCOUNT a
        LEFT JOIN ZACCOUNT p ON p.Z_PK = a.ZPARENTACCOUNT
        WHERE a.ZIDENTIFIER IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let uuid = sqlite3_column_text(stmt, 0),
                  let name = sqlite3_column_text(stmt, 1)
            else { continue }
            out[String(cString: uuid)] = String(cString: name)
        }
        return out
    }

    /// Extracts the account UUID from a `mailboxes.url`.
    ///
    /// Mail encodes them as `imap://<UUID>/<percent-encoded path>` or
    /// `local://<UUID>/`.
    static func accountUUID(fromURL url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        let uuid = rest.prefix { $0 != "/" }
        return uuid.isEmpty ? nil : String(uuid)
    }

    /// Extracts the human-readable mailbox path from a `mailboxes.url`,
    /// percent-decoding it (`%5BGmail%5D/All%20Mail` → `[Gmail]/All Mail`).
    static func mailboxName(fromURL url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        let rest = String(url[schemeEnd.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else { return "" }
        let raw = String(rest[rest.index(after: slash)...])
        return raw.removingPercentEncoding ?? raw
    }

    /// Display name for an account UUID, falling back to the UUID itself.
    private func accountName(forUUID uuid: String?) -> String {
        guard let uuid else { return "" }
        return accountNames[uuid] ?? uuid
    }

    // MARK: - Discovery

    /// Every account that owns at least one mailbox in the index, by
    /// display name.
    public func listAccounts() throws -> [String] {
        let rows = try query(
            sql: "SELECT DISTINCT url FROM mailboxes", args: [],
            columns: 1
        ) { $0[0] ?? "" }
        var seen = Set<String>()
        var out: [String] = []
        for url in rows {
            let name = accountName(forUUID: Self.accountUUID(fromURL: url))
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out.sorted()
    }

    /// Mailbox names inside one account, by display name.
    public func listMailboxes(account: String) throws -> [String] {
        let rows = try query(
            sql: "SELECT url FROM mailboxes", args: [], columns: 1
        ) { $0[0] ?? "" }
        var out: [String] = []
        for url in rows {
            let name = accountName(forUUID: Self.accountUUID(fromURL: url))
            guard name.caseInsensitiveCompare(account) == .orderedSame else { continue }
            let mb = Self.mailboxName(fromURL: url)
            if !mb.isEmpty {
                out.append(mb)
            }
        }
        return out.sorted()
    }

    // MARK: - Search

    /// Searches the index.
    ///
    /// - Parameters:
    ///   - query: Parsed query. See ``MailQuery``.
    ///   - account: Optional account display name to scope to.
    ///   - mailbox: Optional mailbox name to scope to. Matched against the
    ///     decoded mailbox path, case-insensitively, and also against its
    ///     last path component so `"All Mail"` finds `"[Gmail]/All Mail"`.
    ///   - sinceDaysAgo: Lower bound on `date_sent`. `nil` or non-positive
    ///     disables the bound.
    ///   - limit: Maximum results. Applied *in the query*.
    ///   - offset: Results to skip, for paging.
    ///   - unreadOnly: Restrict to unread messages.
    /// - Returns: Matches sorted newest-first.
    public func search(
        query mailQuery: MailQuery,
        account: String? = nil,
        mailbox: String? = nil,
        sinceDaysAgo: Int? = 90,
        limit: Int = 20,
        offset: Int = 0,
        unreadOnly: Bool = false
    ) throws -> [EmailMessage] {
        try runMessageQuery(
            predicate: mailQuery.sqlPredicate(),
            account: account, mailbox: mailbox, sinceDaysAgo: sinceDaysAgo,
            limit: limit, offset: offset, unreadOnly: unreadOnly
        )
    }

    /// Unread messages, newest-first. Same scoping as ``search``, with no
    /// text predicate.
    public func unread(
        account: String? = nil,
        mailbox: String? = nil,
        limit: Int = 10,
        offset: Int = 0
    ) throws -> [EmailMessage] {
        try runMessageQuery(
            predicate: ("1=1", []),
            account: account, mailbox: mailbox, sinceDaysAgo: nil,
            limit: limit, offset: offset, unreadOnly: true
        )
    }

    /// The `SELECT` every message query shares.
    ///
    /// `recipient_text` is aggregated as a correlated subquery rather than
    /// a join so a message with many recipients yields one row, not one
    /// row per recipient — otherwise `limit` would count duplicates and
    /// silently return fewer messages than asked for.
    private static let messageSelect = """
    SELECT s.subject                                        AS subject_text,
           COALESCE(a.comment || ' <' || a.address || '>', a.address, '') AS sender_text,
           m.date_sent                                      AS date_sent,
           mb.url                                           AS mailbox_url,
           m.read                                           AS is_read,
           COALESCE(g.message_id_header, '')                AS rfc_id,
           COALESCE((SELECT GROUP_CONCAT(ra.address, ' ')
                     FROM recipients r
                     JOIN addresses ra ON ra.ROWID = r.address
                     WHERE r.message = m.ROWID), '')        AS recipient_text
    FROM messages m
    JOIN subjects  s  ON s.ROWID  = m.subject
    JOIN mailboxes mb ON mb.ROWID = m.mailbox
    LEFT JOIN addresses a ON a.ROWID = m.sender
    LEFT JOIN message_global_data g ON g.message_id = m.message_id
    """

    private func runMessageQuery(
        predicate: (sql: String, args: [String]),
        account: String?,
        mailbox: String?,
        sinceDaysAgo: Int?,
        limit: Int,
        offset: Int,
        unreadOnly: Bool
    ) throws -> [EmailMessage] {
        guard limit > 0 else { return [] }

        var wheres = ["m.deleted = 0", predicate.sql]
        let args = predicate.args

        if let days = sinceDaysAgo, days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            wheres.append("m.date_sent > \(Int(cutoff.timeIntervalSince1970))")
        }
        if unreadOnly {
            wheres.append("m.read = 0")
        }
        // Account/mailbox scoping resolves to concrete mailbox row ids
        // *before* the message query, then applies as `m.mailbox IN (…)`.
        //
        // Filtering after the fact instead would mean over-fetching and
        // hoping: a mailbox whose matches all sat outside the over-fetch
        // window would come back empty, indistinguishable from "no matching
        // mail" — precisely the conflation `timedOut` exists to eliminate.
        if account?.isEmpty == false || mailbox?.isEmpty == false {
            let ids = try mailboxRowIDs(account: account, mailbox: mailbox)
            guard !ids.isEmpty else { return [] }
            wheres.append("m.mailbox IN (\(ids.map(String.init).joined(separator: ",")))")
        }

        // Bounded in the query. Nothing is fetched that isn't returned.
        let sql = """
        \(Self.messageSelect)
        WHERE \(wheres.joined(separator: " AND "))
        ORDER BY m.date_sent DESC
        LIMIT \(limit) OFFSET \(max(0, offset))
        """

        let rows = try query(sql: sql, args: args, columns: 7) { cols -> Row in
            Row(
                subject: cols[0] ?? "",
                sender: cols[1] ?? "",
                dateSent: cols[2].flatMap { Double($0) },
                mailboxURL: cols[3] ?? "",
                isRead: (cols[4] ?? "0") != "0",
                rfcID: cols[5] ?? "",
                recipients: cols[6] ?? ""
            )
        }

        return rows.map { row in
            let mbName = Self.mailboxName(fromURL: row.mailboxURL)
            let acct = accountName(forUUID: Self.accountUUID(fromURL: row.mailboxURL))
            return EmailMessage(
                subject: row.subject,
                sender: row.sender,
                dateSent: Self.formatDate(row.dateSent),
                content: "",
                isRead: row.isRead,
                mailbox: acct.isEmpty ? mbName : "\(acct) — \(mbName)",
                messageId: row.rfcID
            )
        }
    }

    /// Resolves an account name and/or mailbox name to concrete
    /// `mailboxes.ROWID`s.
    ///
    /// Done in Swift rather than SQL because the match is against the
    /// *decoded* mailbox path (`[Gmail]/All Mail`, not
    /// `%5BGmail%5D/All%20Mail`) and SQLite can't percent-decode. The table
    /// is small enough (tens of rows) that reading all of it is cheaper
    /// than being clever.
    ///
    /// - Returns: Matching row ids. Empty means "no such account/mailbox",
    ///   which callers turn into an empty result — correct, and distinct
    ///   from a truncated one.
    private func mailboxRowIDs(account: String?, mailbox: String?) throws -> [Int] {
        let rows = try query(
            sql: "SELECT ROWID, url FROM mailboxes", args: [], columns: 2
        ) { (rowid: Int($0[0] ?? "") ?? -1, url: $0[1] ?? "") }

        return rows.compactMap { row in
            guard row.rowid >= 0 else { return nil }
            if let account, !account.isEmpty {
                let name = accountName(forUUID: Self.accountUUID(fromURL: row.url))
                guard name.caseInsensitiveCompare(account) == .orderedSame else { return nil }
            }
            if let mailbox, !mailbox.isEmpty {
                let mbName = Self.mailboxName(fromURL: row.url)
                guard Self.mailbox(mbName, matches: mailbox) else { return nil }
            }
            return row.rowid
        }
    }

    private struct Row {
        let subject: String
        let sender: String
        let dateSent: Double?
        let mailboxURL: String
        let isRead: Bool
        let rfcID: String
        let recipients: String
    }

    /// Whether a mailbox path satisfies a caller's mailbox filter.
    ///
    /// Matches the whole path or its last component, so `"All Mail"` finds
    /// `"[Gmail]/All Mail"` — Mail's own naming differs between the
    /// AppleScript surface and the on-disk URL, and callers shouldn't have
    /// to know which one they're holding.
    static func mailbox(_ name: String, matches filter: String) -> Bool {
        if name.caseInsensitiveCompare(filter) == .orderedSame {
            return true
        }
        let leaf = name.split(separator: "/").last.map(String.init) ?? name
        return leaf.caseInsensitiveCompare(filter) == .orderedSame
    }

    /// Renders a stored epoch as an ISO-8601 timestamp.
    ///
    /// The AppleScript backend returns a locale-formatted string; this one
    /// returns ISO because the index stores a real instant and throwing
    /// that away would be a regression. Both land in
    /// ``EmailMessage/dateSent``.
    static func formatDate(_ epoch: Double?) -> String {
        guard let epoch, epoch > 0 else { return "" }
        return ISODate.string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: - SQLite plumbing

    /// Runs a query, mapping each row through `transform`.
    ///
    /// All arguments bind as text; nothing caller-supplied is ever
    /// interpolated into `sql`.
    private func query<T>(
        sql: String,
        args: [String],
        columns: Int,
        transform: ([String?]) -> T
    ) throws -> [T] {
        let db = try Self.openHandle(path: path)
        defer { sqlite3_close_v2(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MailIndexReaderError.sqliteError(
                "prepare failed: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT: SQLite must copy the bytes, since the Swift
        // string backing them is free to die before the step.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient) == SQLITE_OK else {
                throw MailIndexReaderError.sqliteError(
                    "bind \(i + 1) failed: \(String(cString: sqlite3_errmsg(db)))"
                )
            }
        }

        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE {
                break
            }
            guard rc == SQLITE_ROW else {
                throw MailIndexReaderError.sqliteError(
                    "step failed: \(String(cString: sqlite3_errmsg(db)))"
                )
            }
            let cols = (0 ..< columns).map { idx -> String? in
                sqlite3_column_text(stmt, Int32(idx)).map { String(cString: $0) }
            }
            out.append(transform(cols))
        }
        return out
    }
}
