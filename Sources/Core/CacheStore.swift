import Foundation
import SQLite3
import CryptoKit

/// One cached/generated clip.
struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: String            // cache key
    let text: String
    let backend: String       // "elevenlabs" / "qwen3-..."
    let voiceId: String
    let voiceName: String
    let modelId: String
    let createdAt: Date
    let audioFile: String     // filename within the cache dir
    let bytes: Int
}

/// Sort options for the history view.
enum HistorySort: String, CaseIterable, Identifiable {
    case recent, newest, oldest, largest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent:  return "최근 사용순"
        case .newest:  return "생성 최신순"
        case .oldest:  return "생성 오래된순"
        case .largest: return "용량 큰순"
        }
    }
    fileprivate var orderBy: String {
        switch self {
        case .recent:  return "touchedAt DESC"
        case .newest:  return "createdAt DESC"
        case .oldest:  return "createdAt ASC"
        case .largest: return "bytes DESC"
        }
    }
}

/// History + audio cache, backed by SQLite so it stays fast and searchable/
/// sortable as it grows. Audio files sit on disk in the cache dir; the DB holds
/// only metadata. Synthesis cache-hit lookups (`fileURL`/`data`/`save`/`touch`)
/// hit the indexed primary key; the history view pages via SQL.
final class CacheStore {
    static let dir: URL = {
        let base = (Secrets.appSupportDir as NSString).appendingPathComponent("cache")
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return URL(fileURLWithPath: base)
    }()

    private var db: OpaquePointer?
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let selectCols = "SELECT id,text,backend,voiceId,voiceName,modelId,createdAt,audioFile,bytes FROM history"

    init() {
        let dbPath = Self.dir.appendingPathComponent("history.sqlite").path
        sqlite3_open(dbPath, &db)
        exec("PRAGMA journal_mode=WAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS history(
              id TEXT PRIMARY KEY, text TEXT, backend TEXT, voiceId TEXT, voiceName TEXT,
              modelId TEXT, createdAt REAL, audioFile TEXT, bytes INTEGER, touchedAt REAL);
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_touched ON history(touchedAt DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_created ON history(createdAt DESC);")
        migrateFromJSONIfNeeded()
    }

    deinit { sqlite3_close(db) }

    static func key(text: String, backend: String, voiceId: String,
                    modelId: String, settingsHash: String) -> String {
        let raw = [text, backend, voiceId, modelId, settingsHash].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func audioURL(_ e: HistoryEntry) -> URL { Self.dir.appendingPathComponent(e.audioFile) }

    // MARK: - Synthesis cache (hot path: indexed key lookup)

    func entry(forKey key: String) -> HistoryEntry? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "\(selectCols) WHERE id=? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt, 1, key)
        return sqlite3_step(stmt) == SQLITE_ROW ? readRow(stmt) : nil
    }

    func data(forKey key: String) -> Data? {
        guard let e = entry(forKey: key) else { return nil }
        return try? Data(contentsOf: audioURL(e))
    }

    /// File URL for a cached key, only if the audio file actually exists.
    func fileURL(forKey key: String) -> URL? {
        guard let e = entry(forKey: key) else { return nil }
        let url = audioURL(e)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func save(key: String, text: String, backend: String, voiceId: String,
              voiceName: String, modelId: String, ext: String, data: Data) -> HistoryEntry {
        let file = "\(key).\(ext)"
        try? data.write(to: Self.dir.appendingPathComponent(file))
        let e = HistoryEntry(id: key, text: text, backend: backend, voiceId: voiceId,
                             voiceName: voiceName, modelId: modelId, createdAt: Date(),
                             audioFile: file, bytes: data.count)
        upsert(e, touchedAt: e.createdAt.timeIntervalSince1970)   // re-generate → fresh + to front
        return e
    }

    /// Bump an existing entry's recency (on cache-hit replay) without altering its
    /// creation time.
    func touch(_ key: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE history SET touchedAt=? WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        bind(stmt, 2, key)
        sqlite3_step(stmt)
    }

    func delete(_ id: String) {
        if let e = entry(forKey: id) { try? FileManager.default.removeItem(at: audioURL(e)) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        if sqlite3_prepare_v2(db, "DELETE FROM history WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, id); sqlite3_step(stmt)
        }
    }

    func clear() {
        // Remove audio files for everything, then drop all rows.
        for e in page(search: "", sort: .recent, limit: Int.max, offset: 0) {
            try? FileManager.default.removeItem(at: audioURL(e))
        }
        exec("DELETE FROM history;")
    }

    // MARK: - History view (search / sort / paginate)

    func total(search: String) -> Int {
        let q = search.trimmingCharacters(in: .whitespaces)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = q.isEmpty
            ? "SELECT COUNT(*) FROM history"
            : "SELECT COUNT(*) FROM history WHERE text LIKE ? OR voiceName LIKE ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        if !q.isEmpty { let like = "%\(q)%"; bind(stmt, 1, like); bind(stmt, 2, like) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func page(search: String, sort: HistorySort, limit: Int, offset: Int) -> [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let whereClause = q.isEmpty ? "" : "WHERE text LIKE ? OR voiceName LIKE ?"
        let sql = "\(selectCols) \(whereClause) ORDER BY \(sort.orderBy) LIMIT ? OFFSET ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var idx: Int32 = 1
        if !q.isEmpty { let like = "%\(q)%"; bind(stmt, idx, like); idx += 1; bind(stmt, idx, like); idx += 1 }
        sqlite3_bind_int64(stmt, idx, Int64(limit)); idx += 1
        sqlite3_bind_int64(stmt, idx, Int64(offset))
        var out: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(readRow(stmt)) }
        return out
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, Self.TRANSIENT)
    }

    private func readRow(_ stmt: OpaquePointer?) -> HistoryEntry {
        func str(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        return HistoryEntry(
            id: str(0), text: str(1), backend: str(2), voiceId: str(3), voiceName: str(4),
            modelId: str(5), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            audioFile: str(7), bytes: Int(sqlite3_column_int64(stmt, 8)))
    }

    private func upsert(_ e: HistoryEntry, touchedAt: TimeInterval) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            INSERT INTO history(id,text,backend,voiceId,voiceName,modelId,createdAt,audioFile,bytes,touchedAt)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text, backend=excluded.backend,
              voiceId=excluded.voiceId, voiceName=excluded.voiceName, modelId=excluded.modelId,
              createdAt=excluded.createdAt, audioFile=excluded.audioFile, bytes=excluded.bytes,
              touchedAt=excluded.touchedAt;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, e.id); bind(stmt, 2, e.text); bind(stmt, 3, e.backend)
        bind(stmt, 4, e.voiceId); bind(stmt, 5, e.voiceName); bind(stmt, 6, e.modelId)
        sqlite3_bind_double(stmt, 7, e.createdAt.timeIntervalSince1970)
        bind(stmt, 8, e.audioFile); sqlite3_bind_int64(stmt, 9, Int64(e.bytes))
        sqlite3_bind_double(stmt, 10, touchedAt)
        sqlite3_step(stmt)
    }

    /// Import the legacy JSON index once, then rename it so it isn't re-imported.
    private func migrateFromJSONIfNeeded() {
        let indexURL = Self.dir.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        if total(search: "") == 0, let data = try? Data(contentsOf: indexURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let list = try? dec.decode([HistoryEntry].self, from: data) {
                for e in list { upsert(e, touchedAt: e.createdAt.timeIntervalSince1970) }
            }
        }
        try? FileManager.default.moveItem(at: indexURL, to: indexURL.appendingPathExtension("imported"))
    }
}
