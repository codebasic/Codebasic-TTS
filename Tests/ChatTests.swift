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
        let performanceRoot = root.appendingPathComponent("checkpoint")
        let buffered = ChatSession(root: performanceRoot, checkpointInterval: 30_000_000)
        let largeImage = Data(repeating: 17, count: 1_000_000)
        var stream: AsyncThrowingStream<String, Error>.Continuation?
        check(buffered.send(text: "burst", images: [largeImage], provider: "mock", model: "mock", system: "", generate: { _ in AsyncThrowingStream { stream = $0 } }), "buffered stream accepted")
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 1_000_000) }
        let beforeBurst = buffered.storageWriteCount
        for _ in 0..<1000 { stream?.yield("x") }
        for _ in 0..<100 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(buffered.storageWriteCount <= beforeBurst + 2, "1000 chunks produce throttled checkpoints")
        check(buffered.attachmentWriteCount == 1, "historical image written once")
        let metadata = try Data(contentsOf: performanceRoot.appendingPathComponent("conversations.json"))
        check(metadata.count < 10_000, "checkpoint metadata excludes image bytes")
        let partial = ChatSession(root: performanceRoot)
        check(partial.current?.messages.last?.text.count == 1000 && partial.current?.messages.last?.state == "interrupted", "checkpoint restores partial stream")
        stream?.finish()
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(ChatSession(root: performanceRoot).current?.messages.last?.state == "complete", "completion flushes final state")
        let afterCompletion = buffered.storageWriteCount
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(buffered.storageWriteCount == afterCompletion, "no pending checkpoint overwrites completion")
        _ = buffered.send(text: "shutdown", images: [], provider: "mock", model: "mock", system: "", generate: { _ in AsyncThrowingStream { stream = $0 } })
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        stream?.yield("last partial text")
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        buffered.shutdown(); stream?.finish()
        let shutdown = ChatSession(root: performanceRoot)
        check(shutdown.current?.messages.last?.state == "cancelled" && shutdown.current?.messages.last?.text == "last partial text", "termination flushes pending text and status")
        _ = buffered.send(text: "partial error", images: [], provider: "mock", model: "mock", system: "", generate: { _ in AsyncThrowingStream { $0.yield("visible partial"); $0.finish(throwing: URLError(.timedOut)) } })
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        let failed = ChatSession(root: performanceRoot)
        check(failed.current?.messages.last?.state == "failed" && failed.current?.messages.last?.text == "visible partial", "error flushes partial text")
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyThread = ChatThread(messages: [ChatMessage(role: .user, text: "old", images: [image])])
        try JSONEncoder().encode([legacyThread]).write(to: legacyRoot.appendingPathComponent("conversations.json"))
        let migrated = ChatSession(root: legacyRoot); migrated.shutdown()
        check(ChatSession(root: legacyRoot).current?.messages.first?.images == [image], "old V2 inline image archive upgrades without loss")
        let longAudio = ChatSession(root: root.appendingPathComponent("long-audio"))
        let longMessage = ChatMessage(role: .assistant, text: (0..<400).map { "token\($0)" }.joined(separator: " "))
        var lengths: [Int] = []; var queued = 0
        var secondChunk: CheckedContinuation<Data, Error>?
        longAudio.playAudio = { _ in queued += 1 }
        longAudio.play(longMessage, identity: "long") { text in
            lengths.append(text.count)
            if lengths.count == 2 { return try await withCheckedThrowingContinuation { secondChunk = $0 } }
            return Data([1])
        }
        for _ in 0..<30 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(lengths.count == 2 && lengths.allSatisfy { $0 <= 700 }, "long audio requests bounded at 700 characters")
        check(queued == 1 && secondChunk != nil, "first audio queued while next chunk still synthesizes")
        longAudio.stop(); secondChunk?.resume(returning: Data([2]))
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 1_000_000) }
        check(queued == 1 && lengths.count == 2, "audio stop prevents later chunks and stale enqueue")
        longAudio.play(ChatMessage(role: .assistant, text: String(repeating: "x", count: 20_001)), identity: "too-long") { _ in fatalError("over-limit request must not synthesize") }
        check(longAudio.playing == nil && !longAudio.error.isEmpty, "over-limit audio rejected without synthesis")
        check(ChatSpeechPlan.chunks("# Title\n**Hello** [world](https://example.invalid)\n```swift\nprint(1)\n```") == ["Title", "Hello world", "print(1)"], "speech removes Markdown delimiters without another API")
        _ = buffered.send(text: "cancel partial", images: [], provider: "mock", model: "mock", system: "", generate: { _ in AsyncThrowingStream { stream = $0 } })
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        stream?.yield("cancelled partial")
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        buffered.cancelGeneration(); stream?.finish()
        let cancelled = ChatSession(root: performanceRoot)
        check(cancelled.current?.messages.last?.state == "cancelled" && cancelled.current?.messages.last?.text == "cancelled partial", "cancel flushes pending text before checkpoint")
        let unwritable = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: unwritable)
        let failedThread = ChatSession(root: unwritable)
        failedThread.newThread()
        check(failedThread.threads.isEmpty && failedThread.selected == nil && !failedThread.error.isEmpty, "new thread rolls back on persistence failure")
        print("PASS: \(count) chat checks; mock generation and synthesis only")
    }
}
