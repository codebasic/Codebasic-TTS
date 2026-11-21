import Foundation

/// A separate, opt-in, process-scoped inbox. It cannot read instructions, edit
/// the current text, or start any provider or player.
@MainActor
final class LocalExplanationDraftSocket {
    private let transport: LocalApprovedSocket

    init(peer: LocalInstructionPeer, directory: String = LocalApprovedSocket.defaultDirectory,
         lifetime: DispatchTimeInterval = .seconds(600),
         receive: @escaping @MainActor (ExplanationDraft) -> ExplanationDraftWorkspace.Receipt) {
        transport = LocalApprovedSocket(peer: peer, endpoint: "d.sock", directory: directory,
                                        lifetime: lifetime, maxFrame: 100 * 1024) { bytes, stillAllowed in
            guard let draft = Self.decode(bytes) else { return Self.reply("invalid") }
            let signal = DispatchSemaphore(value: 0)
            let result = Result()
            let deadline = DispatchTime.now() + .milliseconds(750)
            DispatchQueue.main.async {
                defer { signal.signal() }
                guard DispatchTime.now() < deadline, stillAllowed() else { return }
                result.store(receive(draft).rawValue)
            }
            guard signal.wait(timeout: deadline) == .success else { return Self.reply("unconfirmed") }
            return Self.reply(result.load())
        }
    }

    func start() -> Bool { transport.start() }
    func stop() { transport.stop() }

    private nonisolated static func decode(_ bytes: Data) -> ExplanationDraft? {
        guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil,
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              Set(object.keys).isSubset(of: ["idempotency_key", "display_text", "speech_text"]),
              let id = object["idempotency_key"] as? String,
              let display = object["display_text"] as? String else { return nil }
        if let value = object["speech_text"] {
            guard let speech = value as? String else { return nil }
            return ExplanationDraft(id: id, display: display, speech: speech)
        }
        return ExplanationDraft(id: id, display: display, speech: nil)
    }

    private nonisolated static func reply(_ status: String) -> Data {
        Data("{\"status\":\"\(status)\"}".utf8)
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var status = "disabled"
        func store(_ newStatus: String) { lock.lock(); defer { lock.unlock() }; status = newStatus }
        func load() -> String { lock.lock(); defer { lock.unlock() }; return status }
    }
}
