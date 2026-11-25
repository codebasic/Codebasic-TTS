import Darwin
import Foundation
import SQLite3

/// Everything one document in the draft list needs to come back exactly as it was
/// left: the received original, the user's edits, and the review state.
struct DraftDocument: Codable {
    var original: ExplanationDraft?
    var display: String
    var speech: String
    var speechNeedsReview: Bool
    var confirmedDisplayHash: String?
    var confirmedSpeechHash: String?
    var provenance: AgentDraftOrigin?
    var origin: ExplanationDraftWorkspace.Origin?
    var hasManualEdits: Bool
    var createdAt = Date()

    var dirty: Bool {
        guard let original else { return !display.isEmpty || !speech.isEmpty }
        return !AgentBytes.same(display, original.display) || !AgentBytes.same(speech, original.speech ?? "")
    }

    /// The sender's title if it gave one, else the first line that is not blank.
    /// Shown in lists only; never part of the text that is edited, copied or read.
    var title: String {
        if let given = original?.title { return given }
        let line = (original?.display ?? display).split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String($0.prefix(AgentLimits.titleCharacters)) } ?? "직접 입력"
    }
}

/// What the list shows for a document without loading its text.
struct DraftSummary: Identifiable, Equatable {
    let id: String
    var title: String
    var dirty: Bool
    var date: Date
    var received: Bool
    /// Fingerprint of the received original, for duplicate and conflict answers.
    var fingerprint: String?
    var unseen = false

    init(id: String, document: DraftDocument, unseen: Bool = false) {
        self.id = id
        title = document.title
        dirty = document.dirty
        date = document.createdAt
        received = document.original != nil
        fingerprint = document.original?.fingerprintHex
        self.unseen = unseen
    }

    init(id: String, title: String, dirty: Bool, date: Date, received: Bool, fingerprint: String?) {
        self.id = id; self.title = title; self.dirty = dirty; self.date = date
        self.received = received; self.fingerprint = fingerprint
    }
}

/// Where the documents that are not in the editor live. Order is arrival order.
protocol DraftStoring: AnyObject {
    func summaries() -> [DraftSummary]
    func load(_ id: String) -> DraftDocument?
    /// Insert or replace. False means nothing changed on disk.
    func save(_ id: String, _ document: DraftDocument) -> Bool
    func delete(_ id: String)
    var activeID: String? { get set }
}

/// For tests and for running without a usable data folder. Nothing survives the process.
final class MemoryDraftStore: DraftStoring {
    private var documents: [String: DraftDocument] = [:]
    private var order: [String] = []
    var activeID: String?
    var failWrites = false
    /// Refuse writes for these ids only, to test one failing document.
    var failWritesFor: Set<String> = []

    func summaries() -> [DraftSummary] { order.compactMap { id in documents[id].map { DraftSummary(id: id, document: $0) } } }
    func load(_ id: String) -> DraftDocument? { documents[id] }
    func save(_ id: String, _ document: DraftDocument) -> Bool {
        guard !failWrites, !failWritesFor.contains(id) else { return false }
        if documents[id] == nil { order.append(id) }
        documents[id] = document
        return true
    }
    func delete(_ id: String) {
        documents[id] = nil
        order.removeAll { $0 == id }
    }
}

/// One private SQLite file. The list columns are kept beside the document so a
/// long history opens without reading every text.
final class SQLiteDraftStore: DraftStoring {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created private before SQLite ever writes text into it.
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var meta = stat()
        let usable = fstat(fd, &meta) == 0 && (meta.st_mode & S_IFMT) == S_IFREG && meta.st_uid == getuid()
            && fchmod(fd, 0o600) == 0
        close(fd)
        guard usable, sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              exec("PRAGMA journal_mode=DELETE;"), exec("PRAGMA secure_delete=ON;"),
              exec("""
                CREATE TABLE IF NOT EXISTS drafts(
                  seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, title TEXT NOT NULL,
                  dirty INTEGER NOT NULL, createdAt REAL NOT NULL, received INTEGER NOT NULL,
                  fingerprint TEXT, body BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
                """) else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK ? statement : nil
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(statement, index, text, -1, Self.transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    func summaries() -> [DraftSummary] {
        guard let statement = prepare("SELECT id,title,dirty,createdAt,received,fingerprint FROM drafts ORDER BY seq") else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [DraftSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { continue }
            rows.append(DraftSummary(id: String(cString: id), title: String(cString: title),
                                     dirty: sqlite3_column_int(statement, 2) != 0,
                                     date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                                     received: sqlite3_column_int(statement, 4) != 0,
                                     fingerprint: sqlite3_column_text(statement, 5).map { String(cString: $0) }))
        }
        return rows
    }

    func load(_ id: String) -> DraftDocument? {
        guard let statement = prepare("SELECT body FROM drafts WHERE id=?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try? JSONDecoder().decode(DraftDocument.self, from: data)
    }

    func save(_ id: String, _ document: DraftDocument) -> Bool {
        guard let body = try? JSONEncoder().encode(document), let statement = prepare("""
            INSERT INTO drafts(id,title,dirty,createdAt,received,fingerprint,body) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, dirty=excluded.dirty, received=excluded.received,
              fingerprint=excluded.fingerprint, body=excluded.body
            """) else { return false }
        defer { sqlite3_finalize(statement) }
        let summary = DraftSummary(id: id, document: document)
        bind(statement, 1, id)
        bind(statement, 2, summary.title)
        sqlite3_bind_int(statement, 3, summary.dirty ? 1 : 0)
        sqlite3_bind_double(statement, 4, document.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 5, summary.received ? 1 : 0)
        bind(statement, 6, summary.fingerprint)
        _ = body.withUnsafeBytes { sqlite3_bind_blob(statement, 7, $0.baseAddress, Int32($0.count), Self.transient) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func delete(_ id: String) {
        guard let statement = prepare("DELETE FROM drafts WHERE id=?") else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        sqlite3_step(statement)
    }

    var activeID: String? {
        get {
            guard let statement = prepare("SELECT value FROM meta WHERE key='active'") else { return nil }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_text(statement, 0).map { String(cString: $0) } : nil
        }
        set {
            guard let statement = prepare("INSERT INTO meta(key,value) VALUES('active',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value") else { return }
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, newValue)
            sqlite3_step(statement)
        }
    }
}
