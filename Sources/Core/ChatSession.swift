import Foundation
import Combine

/// All serialization and disk I/O run on one serial queue. Attachments are immutable
/// files written once; metadata checkpoints never base64-encode historical images.
private final class ChatDiskStore {
    struct Archive: Codable { var version = 1; var threads: [StoredThread] }
    struct StoredThread: Codable { var id: UUID; var title: String; var createdAt: Date; var messages: [StoredMessage] }
    struct StoredMessage: Codable { var message: ChatMessage; var attachments: [String] }
    private let root: URL
    private let queue = DispatchQueue(label: "com.seongjoo.CodebasicTTSV2.chat-storage", qos: .utility)
    private var writes = 0
    private var attachmentWrites = 0
    // Existing messages are immutable; only the last response text/state changes.
    private struct Revision: Equatable {
        let title: String; let count: Int; let lastID: UUID?; let text: String?; let state: String?
    }
    private var encodedThreads: [UUID: (Revision, Data)] = [:]
    var writeCount: Int { queue.sync { writes } }
    var attachmentWriteCount: Int { queue.sync { attachmentWrites } }
    init(root: URL) { self.root = root }
    func load() throws -> [ChatThread] { try queue.sync {
        let file = root.appendingPathComponent("conversations.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        if let legacy = try? JSONDecoder().decode([ChatThread].self, from: data) { return legacy }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return try archive.threads.map { thread in
            let messages = try thread.messages.map { stored in
                var message = stored.message
                message.images = try stored.attachments.map { name in
                    guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw CocoaError(.fileReadCorruptFile) }
                    return try Data(contentsOf: root.appendingPathComponent("attachments").appendingPathComponent(name))
                }
                return message
            }
            return ChatThread(id: thread.id, title: thread.title, createdAt: thread.createdAt, messages: messages)
        }
    }}
    private func write(_ threads: [ChatThread]) throws {
        let directory = root.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records: [Data] = try threads.map { thread in
            let revision = Revision(title: thread.title, count: thread.messages.count, lastID: thread.messages.last?.id, text: thread.messages.last?.text, state: thread.messages.last?.state)
            if let cached = encodedThreads[thread.id], cached.0 == revision { return cached.1 }
            let messages = try thread.messages.map { message in
                var metadata = message; metadata.images = []
                let names = try message.images.enumerated().map { index, data in
                    let name = message.id.uuidString + "-" + String(index) + ".png"
                    let file = directory.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try data.write(to: file, options: .atomic); attachmentWrites += 1
                    }
                    return name
                }
                return StoredMessage(message: metadata, attachments: names)
            }
            let record = StoredThread(id: thread.id, title: thread.title, createdAt: thread.createdAt, messages: messages)
            let data = try JSONEncoder().encode(record)
            encodedThreads[thread.id] = (revision, data)
            return data
        }
        var archive = Data("{\"version\":1,\"threads\":[".utf8)
        for (index, record) in records.enumerated() { if index > 0 { archive.append(44) }; archive.append(record) }
        archive.append(contentsOf: "]}".utf8)
        try archive.write(to: root.appendingPathComponent("conversations.json"), options: .atomic)
        writes += 1
    }
    func save(_ threads: [ChatThread]) throws { try queue.sync { try write(threads) } }
    func checkpoint(_ threads: [ChatThread], completion: @escaping (Error?) -> Void) {
        queue.async {
            do { try self.write(threads); completion(nil) } catch { completion(error) }
        }
    }
}


struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: ConversationMessage.Role
    var text: String
    var images: [Data] = []
    var createdAt = Date()
    var state = "complete"
    var provider = ""
    var model = ""
}
struct ChatThread: Codable, Identifiable {
    var id = UUID()
    var title = "새 대화"
    var createdAt = Date()
    var messages: [ChatMessage] = []
}
/// Small deterministic cleanup, without another LLM/API request. Code content is
/// retained; delimiter lines and common presentation-only Markdown are removed.
enum ChatSpeechPlan {
    static func chunks(_ text: String) -> [String] {
        var speech = text.replacingOccurrences(of: "(?m)^\\s*```[^\\n]*$", with: "", options: .regularExpression)
        speech = speech.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        speech = speech.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        for marker in ["**", "__", "`"] { speech = speech.replacingOccurrences(of: marker, with: "") }
        return TextSplitter.paragraphs(speech, maxChars: 700)
    }
}
/// Durable conversation/visual records are independent of disposable audio cache.
@MainActor final class ChatSession: ObservableObject {
    typealias Generate = (ExplanationConversation) -> AsyncThrowingStream<String, Error>
    typealias Synthesize = (String) async throws -> Data
    @Published private(set) var threads: [ChatThread] = []
    @Published var selected: UUID?
    @Published private(set) var generating = false
    @Published private(set) var playing: UUID?
    @Published var error = ""
    @Published private(set) var audioStatus = ""
    private let root: URL
    private var storageAvailable = true
    private let disk: ChatDiskStore
    private var checkpointTask: Task<Void, Never>?
    private let checkpointInterval: UInt64
    var storageWriteCount: Int { disk.writeCount }
    var attachmentWriteCount: Int { disk.attachmentWriteCount }
    private var generation: Task<Void, Never>?
    private var audio: Task<Void, Never>?
    private var generationID = UUID()
    private var audioID = UUID()
    var playAudio: (Data) throws -> Void = { _ in }
    var stopAudio: () -> Void = {}
    var beginAudio: (Int) -> Void = { _ in }
    var enqueueAudio: ((URL) throws -> Void)?
    static let maxSpeechCharacters = 20_000
    var current: ChatThread? { threads.first { $0.id == selected } }
    init(root: URL, checkpointInterval: UInt64 = 1_000_000_000) {
        self.root = root; self.disk = ChatDiskStore(root: root); self.checkpointInterval = checkpointInterval
        do {
            threads = try disk.load()
            // Preserve partial output after an unclean exit, excluding it from context.
            for i in threads.indices { for j in threads[i].messages.indices {
                if threads[i].messages[j].state == "generating" { threads[i].messages[j].state = "interrupted" }
            }}
        } catch { self.storageAvailable = false; self.error = "대화 복원 실패: " + error.localizedDescription }
        selected = threads.first?.id
    }
    private func scheduleCheckpoint() {
        guard checkpointTask == nil else { return }
        checkpointTask = Task { [weak self] in
            guard let interval = self?.checkpointInterval else { return }
            do { try await Task.sleep(nanoseconds: interval) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.checkpointTask = nil
            self.disk.checkpoint(self.threads) { [weak self] error in
                if let error { Task { @MainActor [weak self] in self?.error = "대화 저장 실패: " + error.localizedDescription } }
            }
        }
    }
    /// Normal completion, cancellation and application termination flush synchronously.
    /// The serial disk queue drains any older asynchronous checkpoint before this save.
    func shutdown() { cancelGeneration(); stop() }
    func newThread() {
        guard storageAvailable else { return }
        let previous = selected
        let thread = ChatThread(); threads.insert(thread, at: 0); selected = thread.id
        if !persist() { threads.removeFirst(); selected = previous }
    }
    @discardableResult private func persist() -> Bool {
        checkpointTask?.cancel(); checkpointTask = nil
        guard storageAvailable else { return false }
        do {
            try disk.save(threads)
            return true
        } catch { self.error = "대화 저장 실패: " + error.localizedDescription; return false }
    }
    private func update(_ thread: UUID, _ message: UUID, _ body: (inout ChatMessage) -> Void) {
        guard let i = threads.firstIndex(where: { $0.id == thread }), let j = threads[i].messages.firstIndex(where: { $0.id == message }) else { return }
        body(&threads[i].messages[j])
    }
    @discardableResult func send(text: String, images: [Data], provider: String, model: String, system: String, generate: @escaping Generate) -> Bool {
        guard !generating, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return false }
        if selected == nil { newThread() }
        guard let i = threads.firstIndex(where: { $0.id == selected }) else { return false }
        error = ""
        let user = ChatMessage(role: .user, text: text, images: images)
        let response = ChatMessage(role: .assistant, text: "", state: "generating", provider: provider, model: model)
        let history = threads[i].messages.filter { $0.state == "complete" }.map { ConversationMessage(role: $0.role, text: $0.text, images: $0.images) }
        let conversation = ExplanationConversation(system: system, messages: history + [ConversationMessage(role: .user, text: text, images: images)])
        if threads[i].messages.isEmpty { threads[i].title = String(text.isEmpty ? "이미지 대화" : text.prefix(40)) }
        threads[i].messages += [user, response]
        guard persist() else { threads[i].messages.removeLast(2); return false }
        let thread = threads[i].id
        generationID = UUID(); let token = generationID; generating = true
        generation = Task { [weak self] in
            guard let self else { return }
            do {
                for try await part in generate(conversation) {
                    guard token == self.generationID, !Task.isCancelled else { return }
                    self.update(thread, response.id) { $0.text += part }
                    self.scheduleCheckpoint()
                }
                guard token == self.generationID, !Task.isCancelled else { return }
                self.update(thread, response.id) { $0.state = $0.text.isEmpty ? "failed" : "complete" }
            } catch {
                guard token == self.generationID else { return }
                self.update(thread, response.id) { $0.state = "failed" }
                self.error = "응답 생성 실패: " + error.localizedDescription
            }
            self.generating = false; self.generation = nil; _ = self.persist()
        }
        return true
    }
    func cancelGeneration() {
        generationID = UUID(); generation?.cancel(); generation = nil; generating = false
        for i in threads.indices { for j in threads[i].messages.indices {
            if threads[i].messages[j].state == "generating" { threads[i].messages[j].state = "cancelled" }
        }}
        _ = persist()
    }
    func stop() {
        audioID = UUID(); audio?.cancel(); audio = nil; playing = nil; audioStatus = ""; stopAudio()
    }
    func audioFinished() { stop() }
    func play(_ message: ChatMessage, identity: String, synthesize: @escaping Synthesize) {
        guard message.role == .assistant, message.state == "complete", !message.text.isEmpty, playing != message.id else { return }
        guard message.text.count <= Self.maxSpeechCharacters else {
            error = "음성 재생은 응답당 20,000자까지 지원합니다. 더 짧은 응답을 요청하세요."; return
        }
        stop(); error = ""; playing = message.id
        let token = audioID
        let chunks = ChatSpeechPlan.chunks(message.text)
        guard !chunks.isEmpty else { stop(); error = "읽을 텍스트가 없습니다."; return }
        beginAudio(chunks.count)
        audio = Task { [weak self] in
            guard let self else { return }
            var activeFile: URL?
            do {
                for (index, text) in chunks.enumerated() {
                    guard token == self.audioID, !Task.isCancelled else { return }
                    self.audioStatus = "음성 준비 \(index + 1)/\(chunks.count) · 첫 조각부터 순서대로 재생"
                    let key = ExplanationConversation(system: identity, messages: [ConversationMessage(role: .assistant, text: text)]).resultCacheKey(endpointIdentity: "elevenlabs-v2-chunk700", model: identity, temperature: 0, reasoning: "")
                    let file = self.root.appendingPathComponent("audio-cache").appendingPathComponent(key + ".mp3")
                    activeFile = file
                    let data: Data
                    if let cached = try? Data(contentsOf: file) { data = cached }
                    else {
                        data = try await synthesize(text)
                        guard token == self.audioID, !Task.isCancelled else { return }
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: file, options: .atomic)
                    }
                    guard token == self.audioID, !Task.isCancelled else { return }
                    if let enqueue = self.enqueueAudio { try enqueue(file) } else { try self.playAudio(data) }
                }
                self.audioStatus = "재생 중 · \(chunks.count)개 조각"
            } catch {
                guard token == self.audioID else { return }
                if let file = activeFile { try? FileManager.default.removeItem(at: file) }
                self.error = "음성 재생 실패: " + error.localizedDescription; self.stop()
            }
        }
    }
}
