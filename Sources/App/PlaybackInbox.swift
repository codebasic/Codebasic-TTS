import Foundation
import Combine

/// Hermes 세션 → 앱 재생 수신함.
///
/// 계약: Hermes 세션(대화 에이전트)이 LLM 3단(해설·대본·검수)을 수행한 뒤
/// ~/Library/Application Support/Codebasic TTS/tts-inbox/ 에 재생 패키지
/// JSON을 쓰면, 앱이 이를 감지해 재생 준비(또는 즉시 재생) 상태로 가져온다.
/// LLM·엔드포인트는 전부 Hermes 게이트웨이 소유 — 앱은 전달받은 두 텍스트의
/// 재생과 재생 제어만 담당한다.
///
/// 감시 방식: **vnode 이벤트(kqueue 기반 DispatchSource)** — 디렉터리에 파일이
/// 생기는 순간 이벤트 1건이 오고, 그때만 1회 스캔한다. 폴링 없음.
/// 작성자(Hermes)는 tmp 쓰기 후 rename(원자적)하므로, 이벤트 시점에 파일은
/// 항상 온전하다. 성공 처리된 파일은 .done, 실패는 .failed로 개명(처리 기록).
///
/// 패키지 형식 (JSON, UTF-8):
/// {
///   "id": "20260902-153000",
///   "narration":  "자막용 해설…",   // 자막에 표시
///   "script":     "음성용 대본…",   // 실제 합성 입력
///   "topic":      "표시용 제목",    // 선택
///   "autoplay":   true|false        // 수신 즉시 재생 여부
/// }
@MainActor
final class PlaybackInbox: ObservableObject {
    static let shared = PlaybackInbox()

    static let dir: URL = URL(fileURLWithPath:
        (Secrets.appSupportDir as NSString).appendingPathComponent("tts-inbox"))

    @Published var lastReceived: PlaybackPackage?
    @Published var status: String = ""

    struct PlaybackPackage: Equatable {
        let id: String
        let narration: String   // 자막용 해설 (원문)
        let script: String      // 음성용 대본 (TTS 입력)
        let topic: String
        let autoplay: Bool      // true = 수신 즉시 재생 (세션이 "바로 재생" 요청 시)
    }

    private var source: DispatchSourceFileSystemObject?
    private var scanWork: DispatchWorkItem?
    private var rewatchWork: DispatchWorkItem?
    private var watchFailed = false
    private var processed = Set<String>()

    /// open() 실패 후 재시도 간격. 수신함은 세션→앱의 유일한 채널이라 조용히 죽으면 안 된다.
    static let rewatchRetryDelay: TimeInterval = 5

    private init() {}

    func start() {
        watch()   // 디렉터리 생성 포함
        scanOnce()   // 앱이 닫혀 있던 동안 쌓인 것 기동 시 1회 로드
    }

    func stop() {
        scanWork?.cancel(); scanWork = nil
        rewatchWork?.cancel(); rewatchWork = nil
        if let src = source { src.cancel() }
        source = nil
    }

    /// 디렉터리 vnode 감시 — 이벤트 도착 시에만 스캔한다 (폴링 없음).
    ///
    /// fd 소유권: 각 DispatchSource가 자기 fd를 소유하고, **cancel 핸들러에서만**
    /// 닫는다 (Apple 계약). cancel 핸들러는 비동기로 실행되므로 fd를 공유 프로퍼티
    /// 대신 값으로 캡처해야 한다 — 그렇지 않으면 재감시 때 이전 소스의 핸들러가
    /// 새 소스의 fd를 닫아 감시가 조용히 죽는다.
    private func watch() {
        rewatchWork?.cancel(); rewatchWork = nil
        source?.cancel(); source = nil   // 이전 소스는 자기 fd를 스스로 닫는다
        // 기동 시, 그리고 디렉터리가 삭제/치환된 뒤의 재감시: 없으면 만들어야 open이 성공한다
        do {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        } catch {
            Log.app.error("inbox: mkdir failed: \(error.localizedDescription, privacy: .public)")
        }
        let fd = open(Self.dir.path, O_EVTONLY)
        guard fd >= 0 else {
            // 조용히 죽지 않는다: 로그 + 상태 표시 + 재시도 예약
            let err = String(cString: strerror(errno))
            Log.app.error("inbox: open failed (\(err, privacy: .public)); retry in \(Self.rewatchRetryDelay, privacy: .public)s")
            watchFailed = true
            status = "수신함 감시 실패: \(err) — \(Int(Self.rewatchRetryDelay))초 후 재시도"
            let work = DispatchWorkItem { [weak self] in self?.watch() }
            rewatchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.rewatchRetryDelay, execute: work)
            return
        }
        if watchFailed {
            // 복구: 감시가 끊긴 동안 도착한 패키지를 한 번 훑는다
            watchFailed = false
            status = ""
            Log.app.info("inbox: watching resumed")
            scheduleScan()
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let mask = src.data
            if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
                self.watch()   // 디렉터리 자체가 치환됨 → 재감시
            }
            self.scheduleScan()
        }
        src.setCancelHandler { close(fd) }   // 이 소스의 fd만, 값으로 캡처
        source = src
        src.resume()
    }

    /// 이벤트 버스트를 살짝 모아 1회만 스캔 (rename 원자성과 합쳐 충분).
    private func scheduleScan() {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanOnce() }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 미처리 .json 패키지 전부 스캔 → 최신 1건 재생 준비. 재생 자체는 사용자가
    /// 트리거(autoplay 패키지 제외). 파일은 성공/실패 무관 개명해 재처리 방지.
    func scanOnce() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let fresh = items
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // 스템프 정렬 = 시간순
        guard !fresh.isEmpty else { return }
        // 가장 최신 1건만 재생 준비로 — 나머지는 done 처리해 쌓이지 않게 한다.
        for old in fresh.dropLast() { markProcessed(old, suffix: "done") }
        load(url: fresh.last!)
    }

    /// 하나의 패키지 파일을 로드해 재생 준비 상태로 올린다.
    private func load(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let narration = obj["narration"] as? String, !narration.isEmpty,
                  let script = obj["script"] as? String, !script.isEmpty else {
                throw NSError(domain: "PlaybackInbox", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "narration/script 필드가 필요합니다"])
            }
            let id = (obj["id"] as? String) ?? url.deletingPathExtension().lastPathComponent
            guard !processed.contains(id) else {
                markProcessed(url, suffix: "done")
                return
            }
            processed.insert(id)
            let pkg = PlaybackPackage(id: id,
                                      narration: narration,
                                      script: script,
                                      topic: (obj["topic"] as? String) ?? "",
                                      autoplay: (obj["autoplay"] as? Bool) ?? false)
            lastReceived = pkg
            status = "수신: \(pkg.topic.isEmpty ? id : pkg.topic)"
            markProcessed(url, suffix: "done")
        } catch {
            status = "수신 실패: \(error.localizedDescription)"
            markProcessed(url, suffix: "failed")
        }
    }

    private func markProcessed(_ url: URL, suffix: String) {
        var renamed = url.deletingPathExtension()
        renamed.appendPathExtension(suffix)
        try? FileManager.default.removeItem(at: renamed)          // 동일 스템프 재수신 시 덮어쓰기
        try? FileManager.default.moveItem(at: url, to: renamed)
    }
}
