import Foundation
import Darwin

/// Manual, explicitly authorized integration probe. Never part of build.sh test.
@main struct LiveConnectionProbe {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.dropFirst().first == "--authorized-single-probe", V2Runtime.liveValidation, !V2Runtime.offline else {
            print("Explicit --authorized-single-probe and CODEBASIC_V2_LIVE_VALIDATION=1 required."); exit(2)
        }
        let root = URL(fileURLWithPath: V2Runtime.dataRoot)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("chat/conversations.json").path) else { throw CocoaError(.fileWriteFileExists) }
        let original = URL(fileURLWithPath: ("~/Library/Application Support/Codebasic TTS" as NSString).expandingTildeInPath)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("settings.json"))) as? [String: Any] ?? [:]
        let endpoints = try JSONDecoder().decode([CustomEndpoint].self, from: JSONSerialization.data(withJSONObject: object["endpoints"] ?? []))
        guard let selected = object["explainEndpointID"] as? String,
              let endpoint = endpoints.first(where: { $0.id.uuidString == selected && $0.isEnabled }),
              endpoint.resolvedProvider == .google, !endpoint.usesPlan,
              URL(string: endpoint.baseURL)?.host == "generativelanguage.googleapis.com",
              let roles = object["explainRoleModels"] as? [String: String],
              let voiceID = object["voiceId"] as? String,
              let voiceModel = object["modelId"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let model = (roles[selected]?.isEmpty == false ? roles[selected] : nil) ?? endpoint.defaultModel
        guard model == "gemini-flash-lite-latest" else { throw CocoaError(.featureUnsupported) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Empty opt-in marker; credentials remain only in their original files/memory.
        try Data().write(to: root.appendingPathComponent("reuse-v1-credentials"), options: .withoutOverwriting)
        guard let googleKey = Secrets.endpointKey(endpoint.id), let voiceKey = Secrets.elevenLabsKey else { throw CocoaError(.fileReadNoSuchFile) }
        guard V2Runtime.consumeLivePermit("google") else { throw CocoaError(.fileWriteFileExists) }
        let generator = EndpointGenerator(endpoint: endpoint, apiKey: googleKey, model: model, instruction: "", temperature: 0.2, reasoningLevel: .medium)
        let chat = ChatSession(root: root.appendingPathComponent("chat"))
        let prompt = "다른 말 없이 정확히 ‘음성 연결 테스트입니다.’ 한 문장만 답하세요."
        _ = chat.send(text: prompt, images: [], provider: endpoint.name, model: model, system: "This is a short synthetic connection test. Output only the requested sentence.", generate: { generator.generate("", conversation: $0) })
        let generationDeadline = Date().addingTimeInterval(45)
        while chat.generating && Date() < generationDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard !chat.generating, let answer = chat.current?.messages.last, answer.state == "complete", !answer.text.isEmpty, answer.text.count < 300 else {
            chat.shutdown(); print("Google generation did not complete a short response; no voice request made."); exit(1)
        }
        var settings = ElevenVoiceSettings()
        settings.stability = object["stability"] as? Double ?? settings.stability
        settings.similarityBoost = object["similarity"] as? Double ?? settings.similarityBoost
        settings.style = object["style"] as? Double ?? settings.style
        settings.useSpeakerBoost = object["speakerBoost"] as? Bool ?? settings.useSpeakerBoost
        let catalog = ElevenModelCatalog.load(from: original.appendingPathComponent("eleven_models.json"))
        let backend = ElevenLabsBackend(apiKey: voiceKey, settings: settings, models: catalog)
        let voice = VoiceConfig(voiceId: voiceID, modelId: voiceModel, settingsHash: settings.hash)
        guard ChatSpeechPlan.chunks(answer.text).count == 1, V2Runtime.consumeLivePermit("elevenlabs") else { throw CocoaError(.featureUnsupported) }
        let player = QueuePlayer()
        var playbackCompleted = false; var playbackFailed = false
        chat.beginAudio = { player.start(expected: $0) }; chat.enqueueAudio = { player.enqueue($0) }; chat.stopAudio = { player.stop() }
        player.onFinish = {
            playbackCompleted = true
            V2Runtime.recordLiveEvidence("playback", ["completed": true, "completed_chunks": player.finishedCount, "expected_chunks": player.expectedCount])
            chat.audioFinished()
        }
        player.onFailure = { playbackFailed = true; V2Runtime.recordLiveEvidence("playback", ["completed": false, "failed": true]); chat.stop() }
        chat.play(answer, identity: voiceID + "|" + voiceModel + "|" + settings.hash) { text in
            var data = Data()
            for try await chunk in backend.stream(segment: text, voice: voice) { data.append(chunk) }
            return data
        }
        let audioDeadline = Date().addingTimeInterval(45)
        while chat.playing != nil && Date() < audioDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let summary: [String: Any] = ["google_model": model, "google_requests": 1, "prompt_characters": prompt.count, "response_characters": answer.text.count, "elevenlabs_model": voiceModel, "elevenlabs_requests": 1, "voice_id": voiceID, "playback_completed": playbackCompleted, "playback_failed_event": playbackFailed, "audio_timeout": chat.playing != nil, "audibility_independently_recorded": false]
        try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]).write(to: root.appendingPathComponent("live-probe-summary.json"), options: .atomic)
        chat.shutdown()
        print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
        if !playbackCompleted { exit(1) }
    }
}
