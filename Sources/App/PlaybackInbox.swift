import Foundation
import Combine

/// Hermes 세션 → 앱 재생 수신함.
///
/// 계약: Hermes 세션(대화 에이전트)이 LLM 3단(해설·대본·검수)을 수행한 뒤
/// ~/.hermes/tts-inbox/에 재생 패키지 JSON을 쓰면, 앱은 이를 감지해
/// 재생 준비 상태로 가져온다. LLM·엔드포인트는 전부 Hermes 쪽 소유 —
/// 앱은 전달받은 두 텍스트의 재생과 재생 제어만 담당한다.
///
/// 패키지 형식 (JSON, UTF-8):
/// {
///   "id": "20260902-153000",          // 파일명 스템프와 동일, 중복 처리 방지용
///   "narration":  "자막용 해설…",      // 자막에 표시 (원문)
///   "script":     "음성용 대본…",      // 실제 합성 입력
///   "topic":      "선택 표시용 제목"   // 선택
/// }
///
/// 처리 성공 시 파일은 .done 접미사로 개명(처리 기록), 실패 시 .failed.
/// 앱이 없는 동안 쌓인 패키지는 기동 시 최신 1건을 자동 로드한다.
@MainActor
final class PlaybackInbox: ObservableObject {
    static let shared = PlaybackInbox()

    static let dir: URL = URL(fileURLWithPath:
        (("~/Library/Application Support/Codebasic TTS/tts-inbox" as NSString).expandingTildeInPath))

    @Published var lastReceived: PlaybackPackage?
    @Published var status: String = ""

    struct PlaybackPackage: Equatable {
        let id: String
        let narration: String   // 자막용 해설 (원문)
        let script: String      // 음성용 대본 (TTS 입력)
        let topic: String
    }

    private var timer: AnyCancellable?
    private var processed = Set<String>()

    private init() {}

    func start() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        // 디스크 기반 감시: 1초 폴링이 가장 단순하고 확실하다 (FSEvents 대비 수십 줄).
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.poll() }
        poll()   // 기동 직후 1회 — 앱이 닫혀 있던 동안 쌓인 것 처리
    }

    func stop() {
        timer?.cancel(); timer = nil
    }

    /// 새 .json 패키지 스캔 → 최신 1건 로드 → .done 개명. 재생은 사용자가
    /// "재생" 버튼으로 트리거(앱이 임의로 소리를 내지 않는다).
    private func poll() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) else { return }
        let fresh = items
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // 스템프 정렬 = 시간순
        guard let newest = fresh.last else { return }
        load(url: newest)
    }

    /// 하나의 패키지 파일을 로드해 재생 준비 상태로 올린다. 성공/실패와 무관하게
    /// 파일을 개명해 다음 폴링에서 재처리되지 않게 한다.
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
                                      topic: (obj["topic"] as? String) ?? "")
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
