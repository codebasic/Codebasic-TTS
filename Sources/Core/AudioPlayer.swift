import AVFoundation

/// Minimal playback: hold an AVAudioPlayer and play in-memory audio (mp3 Data).
/// Retaining the player is required — otherwise it deallocates and goes silent.
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(_ data: Data) throws {
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        player = p
        p.prepareToPlay()
        p.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
