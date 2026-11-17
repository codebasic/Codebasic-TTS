import Foundation
import Combine

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
/// Durable conversation/visual records are independent of disposable audio cache.
@MainActor final class ChatSession: ObservableObject {
    typealias Generate = (ExplanationConversation) -> AsyncThrowingStream<String, Error>
    typealias Synthesize = (String) async throws -> Data
    @Published private(set) var threads: [ChatThread] = []
    @Published var selected: UUID?
    @Published private(set) var generating = false
    @Published private(set) var playing: UUID?
    @Published var error = ""
    private let root: URL
    private var storageAvailable = true
    private var generation: Task<Void, Never>?
    private var audio: Task<Void, Never>?
    private var generationID = UUID()
    private var audioID = UUID()
    var playAudio: (Data) throws -> Void = { _ in }
    var stopAudio: () -> Void = {}
    var current: ChatThread? { threads.first { $0.id == selected } }
    init(root: URL) {
        self.root = root
        do {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("conversations.json").path) {
                threads = try JSONDecoder().decode([ChatThread].self, from: Data(contentsOf: root.appendingPathComponent("conversations.json")))
                // Interrupted responses remain visible but never enter future model context.
                for i in threads.indices { for j in threads[i].messages.indices {
                    if threads[i].messages[j].state == "generating" { threads[i].messages[j].state = "interrupted" }
                }}
            }
        } catch { self.storageAvailable = false; self.error = "대화 복원 실패: " + error.localizedDescription }
        selected = threads.first?.id
    }
    func newThread() {
        guard persist() else { return }
        let thread = ChatThread(); threads.insert(thread, at: 0); selected = thread.id
        _ = persist()
    }
    @discardableResult private func persist() -> Bool {
        guard storageAvailable else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(threads).write(to: root.appendingPathComponent("conversations.json"), options: .atomic)
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
                    guard self.persist() else { self.cancelGeneration(); return }
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
        audioID = UUID(); audio?.cancel(); audio = nil; playing = nil; stopAudio()
    }
    func audioFinished() { stop() }
    func play(_ message: ChatMessage, identity: String, synthesize: @escaping Synthesize) {
        guard message.role == .assistant, message.state == "complete", !message.text.isEmpty, playing != message.id else { return }
        stop(); error = ""; playing = message.id
        let token = audioID
        let key = ExplanationConversation(system: identity, messages: [ConversationMessage(role: .assistant, text: message.text)]).resultCacheKey(endpointIdentity: "elevenlabs-v2", model: identity, temperature: 0, reasoning: "")
        let file = root.appendingPathComponent("audio-cache").appendingPathComponent(key + ".mp3")
        audio = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if let cached = try? Data(contentsOf: file) { data = cached }
                else {
                    data = try await synthesize(message.text)
                    guard token == self.audioID, !Task.isCancelled else { return }
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                }
                guard token == self.audioID, !Task.isCancelled else { return }
                try self.playAudio(data)
            } catch {
                guard token == self.audioID else { return }
                try? FileManager.default.removeItem(at: file)
                self.error = "음성 재생 실패: " + error.localizedDescription; self.stop()
            }
        }
    }
}
