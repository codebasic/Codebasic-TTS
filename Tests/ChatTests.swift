import Foundation

@main struct Tests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }; count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatSession(root: root)
        var captured: ExplanationConversation?
        var calls = 0
        let generate: ChatSession.Generate = { conversation in
            captured = conversation; calls += 1
            return AsyncThrowingStream { continuation in continuation.yield("hello"); continuation.finish() }
        }
        let image = Data([1,2,3])
        check(chat.send(text: "question", images: [image], provider: "Google", model: "gemini-flash-lite-latest", system: "assistant", generate: generate), "accept send")
        check(!chat.send(text: "duplicate", images: [], provider: "", model: "", system: "", generate: generate), "duplicate generation blocked")
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(calls == 1 && !chat.generating, "one generation completes")
        check(captured?.messages.first?.images == [image], "image reaches generator")
        check(chat.current?.messages.last?.text == "hello", "stream persists response")
        check(chat.playing == nil, "generation does not synthesize")
        let restored = ChatSession(root: root)
        check(restored.current?.messages == chat.current?.messages, "restart restores messages images timestamps model")
        let answer = chat.current!.messages.last!
        var voiceCalls = 0; var played = 0; var stopped = 0
        chat.playAudio = { _ in played += 1 }; chat.stopAudio = { stopped += 1 }
        let voice: ChatSession.Synthesize = { _ in voiceCalls += 1; return Data([4,5]) }
        chat.play(answer, identity: "voice1", synthesize: voice)
        chat.play(answer, identity: "voice1", synthesize: voice)
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(voiceCalls == 1 && played == 1, "duplicate audio blocked")
        chat.stop(); check(chat.playing == nil && stopped > 0, "stop independent")
        chat.play(answer, identity: "voice1", synthesize: voice)
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(voiceCalls == 1 && played == 2, "audio cache reused")
        chat.stop()
        chat.play(answer, identity: "voice2", synthesize: { _ in throw URLError(.notConnectedToInternet) })
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(chat.playing == nil && !chat.error.isEmpty && chat.current!.messages.last!.text == "hello", "voice failure preserves conversation")
        var late: AsyncThrowingStream<String, Error>.Continuation?
        check(chat.send(text: "cancel me", images: [], provider: "mock", model: "mock", system: "", generate: { _ in AsyncThrowingStream { late = $0 } }), "second turn accepted")
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        chat.cancelGeneration(); late?.yield("stale"); late?.finish()
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(chat.current!.messages.last!.state == "cancelled" && chat.current!.messages.last!.text.isEmpty, "late cancelled response ignored")
        check(chat.send(text: "failure", images: [], provider: "mock", model: "mock", system: "", generate: { _ in AsyncThrowingStream { $0.finish(throwing: URLError(.timedOut)) } }), "failure turn accepted")
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(!chat.generating && chat.current!.messages.last!.state == "failed", "generation failure settles")
        var pendingVoice: CheckedContinuation<Data, Error>?
        chat.play(answer, identity: "late", synthesize: { _ in try await withCheckedThrowingContinuation { pendingVoice = $0 } })
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        chat.stop(); pendingVoice?.resume(returning: Data([7]))
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(played == 2 && chat.playing == nil, "late cancelled voice ignored")
        check(chat.send(text: "interrupted", images: [], provider: "mock", model: "mock", system: "", generate: { _ in AsyncThrowingStream { late = $0 } }), "interrupted turn accepted")
        let interrupted = ChatSession(root: root)
        check(interrupted.current!.messages.last!.state == "interrupted", "restart marks unfinished response")
        chat.cancelGeneration(); late?.finish()
        let brokenRoot = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
        let brokenFile = brokenRoot.appendingPathComponent("conversations.json")
        let corrupt = Data("invalid json".utf8); try corrupt.write(to: brokenFile)
        let broken = ChatSession(root: brokenRoot); broken.newThread()
        check(!broken.error.isEmpty && broken.threads.isEmpty, "corrupt history blocks destructive overwrite")
        let preserved = try Data(contentsOf: brokenFile)
        check(preserved == corrupt, "corrupt original preserved")
        try FileManager.default.removeItem(at: root.appendingPathComponent("audio-cache"))
        let withoutAudio = ChatSession(root: root)
        check(withoutAudio.current?.messages.count == chat.current?.messages.count, "clearing audio cache preserves conversation")
        print("PASS: \(count) chat checks; mock generation and synthesis only")
    }
}
