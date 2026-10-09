import Foundation
@testable import MailAutomation
import SQLite3
import Testing

/// The reader must never write to Mail's store.
@Suite("MailIndexReader store safety")
struct MailIndexStoreSafetyTests {
    // MARK: - Helpers

    private static func open(_ path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw StoreError.sqlite("open \(path): rc=\(rc)")
        }
        return handle
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite("\(msg) — \(sql)")
        }
    }

    enum StoreError: Error { case sqlite(String) }

    private static func bytes(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    // MARK: - Never writes Mail's store

    /// Mail can leave committed transactions in `-wal` that have not been
    /// checkpointed into the main file (it was killed, or it was quit with
    /// the WAL persisted). When our handle is the last one to close, SQLite
    /// would normally checkpoint those frames into Mail's database file and
    /// delete the WAL — a write to another app's store. `query_only` does not
    /// stop that; only a read-only connection does.
    @Test("a search never checkpoints Mail's WAL into its database file")
    func neverCheckpoints() async throws {
        let fixture = try MailIndexFixture(seeds: [.init(subject: "Base invoice")])
        defer { fixture.tearDown() }

        // Snapshot a store with un-checkpointed WAL frames, the way Mail
        // leaves one: convert to WAL, commit a row, copy the files while the
        // writer still holds them (so its close-time checkpoint never lands
        // in the copy).
        let snapDir = fixture.dir.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let snapIndex = snapDir.appendingPathComponent("Envelope Index").path
        do {
            let writer = try Self.open(fixture.indexPath)
            defer { sqlite3_close_v2(writer) }
            try Self.exec(writer, "PRAGMA journal_mode = WAL")
            try Self.exec(writer, "PRAGMA wal_autocheckpoint = 0")
            try Self.exec(writer, """
            INSERT INTO subjects (subject) VALUES ('WAL-only invoice');
            INSERT INTO messages (message_id, sender, subject, date_sent, mailbox, read, deleted)
            VALUES (9999, 1, last_insert_rowid(), \(Int(Date().timeIntervalSince1970) - 60), 1, 1, 0);
            """)
            for suffix in ["", "-wal"] {
                try FileManager.default.copyItem(
                    atPath: fixture.indexPath + suffix, toPath: snapIndex + suffix
                )
            }
        }

        let dbBefore = try #require(Self.bytes(snapIndex))
        let walBefore = try #require(Self.bytes(snapIndex + "-wal"))
        #expect(!walBefore.isEmpty, "precondition: the WAL holds the uncheckpointed commit")

        let reader = try MailIndexReader(path: snapIndex, accountsPath: fixture.accountsPath)
        let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365)

        // It still reads what Mail committed to the WAL…
        #expect(Set(out.map(\.subject)) == ["WAL-only invoice", "Base invoice"])
        // …without folding it into Mail's database or deleting Mail's WAL.
        #expect(Self.bytes(snapIndex) == dbBefore, "Mail's database file was modified")
        #expect(Self.bytes(snapIndex + "-wal") == walBefore, "Mail's WAL was checkpointed or removed")
    }

    /// Mail quit cleanly: the store is in WAL mode but no `-wal` file is
    /// on disk. A read-only handle must still open and read it.
    @Test("a WAL-mode store with no -wal file on disk still reads")
    func walModeWithoutWalFile() async throws {
        let fixture = try MailIndexFixture(seeds: [.init(subject: "Quiet invoice")])
        defer { fixture.tearDown() }
        do {
            let writer = try Self.open(fixture.indexPath)
            try Self.exec(writer, "PRAGMA journal_mode = WAL")
            sqlite3_close_v2(writer)
        }
        try? FileManager.default.removeItem(atPath: fixture.indexPath + "-wal")
        try? FileManager.default.removeItem(atPath: fixture.indexPath + "-shm")

        let reader = try MailIndexReader(path: fixture.indexPath, accountsPath: fixture.accountsPath)
        let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365)
        #expect(out.map(\.subject) == ["Quiet invoice"])
    }

    /// Each query opens its own handle, so a commit Mail makes after the
    /// reader was created is visible to the next search.
    @Test("a commit made after the reader opened is visible to the next search")
    func seesLaterCommits() async throws {
        let fixture = try MailIndexFixture(seeds: [.init(subject: "First invoice")])
        defer { fixture.tearDown() }
        let writer = try Self.open(fixture.indexPath)
        defer { sqlite3_close_v2(writer) }
        try Self.exec(writer, "PRAGMA journal_mode = WAL")

        let reader = try MailIndexReader(path: fixture.indexPath, accountsPath: fixture.accountsPath)
        #expect(try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365).count == 1)

        try Self.exec(writer, """
        INSERT INTO subjects (subject) VALUES ('Second invoice');
        INSERT INTO messages (message_id, sender, subject, date_sent, mailbox, read, deleted)
        VALUES (9998, 1, last_insert_rowid(), \(Int(Date().timeIntervalSince1970) - 60), 1, 1, 0);
        """)
        let out = try await reader.search(query: MailQuery.parse("invoice"), sinceDaysAgo: 365)
        #expect(Set(out.map(\.subject)) == ["First invoice", "Second invoice"])
    }
}
