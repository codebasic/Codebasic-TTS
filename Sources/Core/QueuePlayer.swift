import AVFoundation

/// Plays a sequence of audio files back-to-back via AVQueuePlayer. Chunks
/// (paragraphs) are enqueued as they become ready (cache hit = immediately,
/// miss = after synthesis), so playback starts on the first chunk and the rest
/// stream in. pause()/resume() keep position; prev()/next() navigate by
/// paragraph (rebuilding the queue when jumping back). Small gaps between items
/// fall on paragraph boundaries (natural pauses).
final class QueuePlayer {
    private let player = AVQueuePlayer()
    var onFinish: (() -> Void)?

    private var urls: [URL] = []          // every chunk URL, in order
    private var playIndex = 0             // index of the currently-playing chunk
    private var expected = 0
    private var observers: [NSObjectProtocol] = []

    init() { player.actionAtItemEnd = .advance }

    var isPlaying: Bool { player.rate != 0 }
    var finishedCount: Int { playIndex }
    var expectedCount: Int { expected }
    var canNext: Bool { playIndex + 1 < urls.count }   // a synthesized next chunk exists
    var canPrev: Bool { playIndex > 0 }

    /// Begin a new sequence of `expected` chunks.
    func start(expected: Int) {
        stop()
        self.expected = expected
    }

    func enqueue(_ url: URL) {
        urls.append(url)
        addItem(url)
        if player.rate == 0 { player.play() }
    }

    private func addItem(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.itemFinished() }
        observers.append(obs)
        player.insert(item, after: nil)
    }

    private func itemFinished() {
        playIndex += 1
        if playIndex >= expected, expected > 0 { onFinish?() }
    }

    /// Skip to the next already-synthesized paragraph.
    func next() {
        guard canNext else { return }
        playIndex += 1
        player.advanceToNextItem()
        player.play()
    }

    /// Jump back to the previous paragraph (rebuilds the queue from there).
    func prev() {
        guard canPrev else { return }
        rebuild(from: playIndex - 1)
    }

    private func rebuild(from index: Int) {
        clearObservers()
        player.removeAllItems()
        playIndex = index
        for i in index..<urls.count { addItem(urls[i]) }
        player.play()
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        player.pause()
        player.removeAllItems()
        clearObservers()
        urls.removeAll()
        playIndex = 0
        expected = 0
    }

    private func clearObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Overall progress across the whole sequence (0…1).
    var progress: Double {
        guard expected > 0 else { return 0 }
        return min(1, (Double(playIndex) + currentItemFraction) / Double(expected))
    }

    private var currentItemFraction: Double {
        guard let item = player.currentItem else { return 0 }
        let dur = item.duration.seconds
        guard dur.isFinite, dur > 0 else { return 0 }
        return min(1, item.currentTime().seconds / dur)
    }
}
