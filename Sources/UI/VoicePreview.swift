import AVFoundation
import Combine

/// A short, cancellable audition, independent of the document, queue and history.
@MainActor
final class VoicePreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var generation = UUID()

    func start(app: AppState, text: String) {
        stop()
        let backend: TTSBackend
        if app.backendKind == .elevenlabs {
            guard let key = Secrets.elevenLabsKey else { status = "먼저 API 키를 저장하세요."; return }
            backend = ElevenLabsBackend(apiKey: key, settings: app.voiceSettings)
        } else {
            guard let url = serviceURL(app.localBaseURL) else { status = "서버 주소를 확인하세요."; return }
            backend = Qwen3MLXBackend(baseURL: url)
        }
        let voice = VoiceConfig(voiceId: app.voiceId, modelId: app.modelId, settingsHash: app.settingsHash)
        let token = generation
        busy = true
        status = "음성 생성 중…"
        task = Task { [weak self] in
            do {
                var audio = Data()
                for try await chunk in backend.stream(segment: String(text.prefix(300)), voice: voice) {
                    try Task.checkCancellation()
                    audio.append(chunk)
                }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                let player = try AVAudioPlayer(data: audio)
                self.player = player
                player.delegate = self
                guard player.play() else { throw URLError(.cannotDecodeContentData) }
                self.status = "재생 중"
            } catch {
                guard let self, self.generation == token else { return }
                self.busy = false
                self.status = "미리 듣기 실패: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        busy = false
        status = ""
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.busy = false
            self.status = flag ? "재생 완료" : "재생 실패"
            self.player = nil
        }
    }
}
