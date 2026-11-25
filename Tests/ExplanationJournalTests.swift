import Foundation
@main struct JournalTests {
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: root) }
  let dir = root.appendingPathComponent("events")
  let journal = ExplanationJournal(directory: dir)
  let date = Date(timeIntervalSince1970: 1700000000.125)
  let a = try journal.record("해설\n본문", kind: .full, origin: .generated, now: date)!
  let b = try journal.record("해설\n본문", kind: .full, origin: .cache, now: date)!
  precondition(a != b)
  let data = try Data(contentsOf: a)
  let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  precondition(Set(json.keys) == Set(["version","id","createdAt","kind","origin","text"]))
  precondition(json["text"] as? String == "해설\n본문")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .custom { decoder in
   let value = try decoder.singleValueContainer().decode(String.self)
   let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
   guard let date = formatter.date(from: value) else { throw CocoaError(.fileReadCorruptFile) }
   return date
  }
  let entry = try decoder.decode(ExplanationJournal.Entry.self, from: data)
  precondition(entry.createdAt == date && entry.kind == .full && entry.origin == .generated)
  let cached = try decoder.decode(ExplanationJournal.Entry.self, from: Data(contentsOf: b))
  precondition(cached.origin == .cache)
  let empty = try journal.record(" \n", kind: .full, origin: .cache); precondition(empty == nil)
  let c = try journal.record("추가", kind: .continuation, origin: .generated)!
  let continuation = try decoder.decode(ExplanationJournal.Entry.self, from: Data(contentsOf: c)); precondition(continuation.kind == .continuation)
  let fileMode = try fm.attributesOfItem(atPath: a.path)[.posixPermissions] as! NSNumber; precondition(fileMode.intValue == 0o600)
  let dirMode = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as! NSNumber; precondition(dirMode.intValue == 0o700)
  let link = root.appendingPathComponent("link")
  try fm.createSymbolicLink(at: link, withDestinationURL: dir)
  do { _ = try ExplanationJournal(directory: link).record("bad",kind:.full,origin:.cache); fatalError("symlink accepted") } catch {}
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
  do { _ = try journal.record("bad",kind:.full,origin:.cache); fatalError("unsafe permissions accepted") } catch {}
  print("ExplanationJournal: schema, Unicode, timestamps, repeated/cache events, continuation, empty, modes, symlink and permission failure PASS")
 }
}
