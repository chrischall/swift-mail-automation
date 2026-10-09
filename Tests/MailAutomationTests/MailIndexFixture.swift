import Foundation
import SQLite3

/// Builds a throwaway Envelope Index / Accounts pair on disk so
/// ``MailIndexReader`` can be exercised without Full Disk Access, without
/// Mail.app, and without touching the user's real mail.
///
/// Only the columns the reader actually reads are recreated — the real
/// `messages` table has ~30 more. If the reader starts using a new column
/// it must be added here too, which is the point: the fixture pins the
/// schema contract the reader depends on.
struct MailIndexFixture {
    let dir: URL
    var indexPath: String { dir.appendingPathComponent("Envelope Index").path }
    var accountsPath: String { dir.appendingPathComponent("Accounts4.sqlite").path }

    /// One message to seed.
    struct Seed {
        let subject: String
        let sender: String
        /// Bare addresses of recipients.
        let recipients: [String]
        let daysAgo: Double
        let mailboxURL: String
        let isRead: Bool
        let rfcID: String
        let deleted: Bool

        init(
            subject: String,
            sender: String = "someone@example.com",
            recipients: [String] = [],
            daysAgo: Double = 1,
            mailboxURL: String = "imap://ACCT-G/INBOX",
            isRead: Bool = true,
            rfcID: String = "",
            deleted: Bool = false
        ) {
            self.subject = subject
            self.sender = sender
            self.recipients = recipients
            self.daysAgo = daysAgo
            self.mailboxURL = mailboxURL
            self.isRead = isRead
            self.rfcID = rfcID
            self.deleted = deleted
        }
    }

    /// Creates the fixture. `accounts` maps account UUID → display name.
    init(
        seeds: [Seed],
        accounts: [String: String] = ["ACCT-G": "Google", "ACCT-I": "iCloud"]
    ) throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mail-index-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try buildIndex(seeds: seeds)
        try buildAccounts(accounts)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Building

    private func buildIndex(seeds: [Seed]) throws {
        let db = try open(indexPath)
        defer { sqlite3_close_v2(db) }

        try exec(db, """
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, address TEXT NOT NULL, comment TEXT NOT NULL);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL);
        CREATE TABLE messages (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER NOT NULL DEFAULT 0,
            sender INTEGER, subject INTEGER NOT NULL, date_sent INTEGER,
            mailbox INTEGER NOT NULL, read INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER NOT NULL, address INTEGER NOT NULL);
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER, message_id_header TEXT);
        """)

        var subjectIDs: [String: Int] = [:]
        var addressIDs: [String: Int] = [:]
        var mailboxIDs: [String: Int] = [:]

        func subjectID(_ s: String) throws -> Int {
            if let id = subjectIDs[s] {
                return id
            }
            try exec(db, "INSERT INTO subjects (subject) VALUES ('\(esc(s))')")
            let id = Int(sqlite3_last_insert_rowid(db))
            subjectIDs[s] = id
            return id
        }
        /// Splits `"Name <addr>"` back into the two columns Mail stores.
        func addressID(_ s: String) throws -> Int {
            if let id = addressIDs[s] {
                return id
            }
            var address = s, comment = ""
            if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">") {
                comment = String(s[s.startIndex ..< lt]).trimmingCharacters(in: .whitespaces)
                address = String(s[s.index(after: lt) ..< gt])
            }
            try exec(db, "INSERT INTO addresses (address, comment) VALUES ('\(esc(address))', '\(esc(comment))')")
            let id = Int(sqlite3_last_insert_rowid(db))
            addressIDs[s] = id
            return id
        }
        func mailboxID(_ s: String) throws -> Int {
            if let id = mailboxIDs[s] {
                return id
            }
            try exec(db, "INSERT INTO mailboxes (url) VALUES ('\(esc(s))')")
            let id = Int(sqlite3_last_insert_rowid(db))
            mailboxIDs[s] = id
            return id
        }

        for (i, seed) in seeds.enumerated() {
            let epoch = Int(Date().addingTimeInterval(-seed.daysAgo * 86400).timeIntervalSince1970)
            let messageID = 1000 + i
            try exec(db, """
            INSERT INTO messages (message_id, sender, subject, date_sent, mailbox, read, deleted)
            VALUES (\(messageID), \(addressID(seed.sender)), \(subjectID(seed.subject)),
                    \(epoch), \(mailboxID(seed.mailboxURL)),
                    \(seed.isRead ? 1 : 0), \(seed.deleted ? 1 : 0))
            """)
            let rowid = Int(sqlite3_last_insert_rowid(db))
            for r in seed.recipients {
                try exec(db, "INSERT INTO recipients (message, address) VALUES (\(rowid), \(addressID(r)))")
            }
            if !seed.rfcID.isEmpty {
                try exec(db, """
                INSERT INTO message_global_data (message_id, message_id_header)
                VALUES (\(messageID), '\(esc(seed.rfcID))')
                """)
            }
        }
    }

    private func buildAccounts(_ accounts: [String: String]) throws {
        let db = try open(accountsPath)
        defer { sqlite3_close_v2(db) }
        try exec(db, """
        CREATE TABLE ZACCOUNT (
            Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT,
            ZACCOUNTDESCRIPTION TEXT, ZPARENTACCOUNT INTEGER);
        """)
        var pk = 1
        for (uuid, name) in accounts.sorted(by: { $0.key < $1.key }) {
            // Mirror the real shape: the child row carries the UUID with an
            // empty description, the parent carries the display name.
            let parentPK = pk
            try exec(db, """
            INSERT INTO ZACCOUNT (Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZPARENTACCOUNT)
            VALUES (\(parentPK), NULL, '\(esc(name))', NULL)
            """)
            pk += 1
            try exec(db, """
            INSERT INTO ZACCOUNT (Z_PK, ZIDENTIFIER, ZACCOUNTDESCRIPTION, ZPARENTACCOUNT)
            VALUES (\(pk), '\(esc(uuid))', '', \(parentPK))
            """)
            pk += 1
        }
    }

    // MARK: - Tiny SQLite helpers

    private func open(_ path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        )
        guard rc == SQLITE_OK, let handle else {
            throw FixtureError.sqlite("open \(path) failed: rc=\(rc)")
        }
        return handle
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw FixtureError.sqlite("exec failed: \(msg) — \(sql)")
        }
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    enum FixtureError: Error { case sqlite(String) }
}
