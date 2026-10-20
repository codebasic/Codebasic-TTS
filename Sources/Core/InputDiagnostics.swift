import AppKit
import os

/// App-local metadata only. Never reads key characters, text or pasteboard data.
/// The common-mode timer measures responsiveness after a stall recovers, not
/// keystroke-to-pixel latency. Keep this separate from memory measurements.
@MainActor
final class InputDiagnostics {
    static let shared = InputDiagnostics()
    private let logger = Logger(subsystem: Log.subsystem, category: "responsiveness")
    private var timer: Timer?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var lastTick: TimeInterval?
    private var keys = 0
    private var changes = 0
    private var markedChanges = 0
    private var maxTextLength = 0
    private var maxKeyAge: TimeInterval = 0
    private var maxTimerDelay: TimeInterval = 0
    private var stalls = 0
    private var work: [String: (count: Int, maxMS: Double)] = [:]

    func start() {
        guard timer == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keys += 1
                self.maxKeyAge = max(self.maxKeyAge, max(0, ProcessInfo.processInfo.systemUptime - event.timestamp))
            }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let view = note.object as? NSTextView else { return }
                self.changes += 1
                self.maxTextLength = max(self.maxTextLength, view.textStorage?.length ?? 0)
                if view.hasMarkedText() { self.markedChanges += 1 }
            }
        })
        // Reset across focus changes so inactive time isn't classified as a stall.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lastTick = nil }
            })
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if NSApp.isActive, let last = self.lastTick {
                    let delay = max(0, now - last - 0.25)
                    self.maxTimerDelay = max(self.maxTimerDelay, delay)
                    if delay >= 0.1 { self.stalls += 1 }
                }
                self.lastTick = NSApp.isActive ? now : nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func recordWork(_ name: String, since start: TimeInterval) {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let previous = work[name] ?? (0, 0)
        work[name] = (previous.count + 1, max(previous.maxMS, ms))
    }

    func flush() {
        let fields = "keys=\(keys) textChanges=\(changes) markedChanges=\(markedChanges) maxTextUTF16=\(maxTextLength) stallsOver100ms=\(stalls)"
        let timing = String(format: "maxKeyQueueMS=%.1f maxMainTimerDelayMS=%.1f", maxKeyAge * 1000, maxTimerDelay * 1000)
        let durations = work.keys.sorted().map { name in
            let value = work[name]!
            return String(format: "%@:%d/maxMS:%.2f", name, value.count, value.maxMS)
        }.joined(separator: ",")
        logger.notice("[INPUT-DIAG] \(fields, privacy: .public) \(timing, privacy: .public) work=\(durations, privacy: .public)")
        keys = 0; changes = 0; markedChanges = 0; maxTextLength = 0
        maxKeyAge = 0; maxTimerDelay = 0; stalls = 0
        work.removeAll(keepingCapacity: true)
    }
}
