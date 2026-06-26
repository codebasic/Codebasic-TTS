import AVFoundation

/// Plays a sequence of audio files back-to-back via AVQueuePlayer. Chunks
/// (paragraphs) are enqueued as they become ready (cache hit = immediately,
/// miss = after synthesis), so playback starts on the first chunk and the rest
/// stream in. pause()/resume() keep position; small gaps between items fall on
/// paragraph boundaries (natural pauses).
final class QueuePlayer {
    private let player = AVQueuePlayer()
    var onFinish: (() -> Void)?

    private var expected = 0
    private var finished = 0
    private var observers: [NSObjectProtocol] = []

    init() { player.actionAtItemEnd = .advance }

    var isPlaying: Bool { player.rate != 0 }
    var finishedCount: Int { finished }
    var expectedCount: Int { expected }

    /// Begin a new sequence of `expected` chunks.
    func start(expected: Int) {
        stop()
        self.expected = expected
        self.finished = 0
    }

    func enqueue(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.itemFinished() }
        observers.append(obs)
        player.insert(item, after: nil)
        if player.rate == 0 { player.play() }
    }

    private func itemFinished() {
        finished += 1
        if finished >= expected, expected > 0 { onFinish?() }
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        player.pause()
        player.removeAllItems()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        expected = 0
        finished = 0
    }

    /// Overall progress across the whole sequence (0…1).
    var progress: Double {
        guard expected > 0 else { return 0 }
        return min(1, (Double(finished) + currentItemFraction) / Double(expected))
    }

    private var currentItemFraction: Double {
        guard let item = player.currentItem else { return 0 }
        let dur = item.duration.seconds
        guard dur.isFinite, dur > 0 else { return 0 }
        return min(1, item.currentTime().seconds / dur)
    }
}
