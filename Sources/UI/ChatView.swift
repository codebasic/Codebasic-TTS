import SwiftUI
import AppKit
import AVFoundation

@MainActor final class ChatAudio: NSObject, AVAudioPlayerDelegate {
    var player: AVAudioPlayer?
    var finished: () -> Void = {}
    func play(_ data: Data) throws {
        player = try AVAudioPlayer(data: data); player?.delegate = self
        guard player?.play() == true else { throw URLError(.cannotDecodeContentData) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor [weak self] in self?.finished() } }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { Task { @MainActor [weak self] in self?.finished() } }
}
struct ChatView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var chat = ChatSession(root: URL(fileURLWithPath: Secrets.appSupportDir).appendingPathComponent("chat"))
    @State private var draft = ""
    @State private var images: [Data] = []
    @State private var audio = ChatAudio()
    @State private var notice = ""
    var body: some View {
        HSplitView {
            VStack {
                Button("새 대화") { chat.newThread() }
                List(selection: $chat.selected) {
                    ForEach(chat.threads) { thread in
                        VStack(alignment: .leading) { Text(thread.title).lineLimit(2); Text(thread.createdAt, style: .date).font(.caption).foregroundStyle(.secondary) }.tag(thread.id)
                    }
                }
            }.frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
            VStack(alignment: .leading, spacing: 10) {
                LLMModelPicker(label: "응답 모델", endpointID: $app.explainEndpointID, roleModels: $app.explainRoleModels, onChange: { app.saveSettings() })
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(chat.current?.messages ?? []) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(message.role == .user ? "나" : message.provider + " · " + message.model).font(.caption).foregroundStyle(.secondary)
                                        Spacer(); Text(message.createdAt, style: .time).font(.caption2)
                                    }
                                    Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                                        if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180) }
                                    }
                                    if message.state != "complete" { Text(message.state).font(.caption).foregroundStyle(.secondary) }
                                    if message.role == .assistant && message.state == "complete" {
                                        Button(chat.playing == message.id ? "중지" : "음성 재생") {
                                            if chat.playing == message.id { chat.stop() } else { play(message) }
                                        }
                                    }
                                }.padding(12).background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)).cornerRadius(10).id(message.id)
                            }
                        }
                    }.onChange(of: chat.current?.messages.last?.text) { _, _ in if let id = chat.current?.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                if !chat.error.isEmpty { Text(chat.error).foregroundStyle(.red).textSelection(.enabled) }
                if !notice.isEmpty { Text(notice).font(.caption) }
                TextEditor(text: $draft).frame(height: 85).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                HStack {
                    Button("이미지 첨부") { attach() }.disabled(chat.generating)
                    if !images.isEmpty { Button("첨부 \(images.count)개 제거") { images = [] } }
                    Spacer()
                    if chat.generating { Button("생성 취소") { chat.cancelGeneration() } }
                    Button("보내기") { send() }.keyboardShortcut(.return, modifiers: .command).disabled(chat.generating || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
                }
                DisclosureGroup("V1 연결 재사용 (선택)") {
                    Text("버튼을 누르면 V1의 제공자·모델 설정만 V2에 반영하고 키는 원래 파일에서 읽기 전용으로 참조합니다. V1 기록은 가져오지 않습니다.").font(.caption)
                    Button("V1 연결 설정 사용") { reuseConnections() }
                    Button("V1 키 참조 해제") {
                        do {
                            let marker = URL(fileURLWithPath: Secrets.appSupportDir + "/reuse-v1-credentials")
                            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
                            app.keyPresent = Secrets.elevenLabsKey != nil; notice = "V1 키 참조를 해제했습니다."
                        } catch { notice = error.localizedDescription }
                    }
                }
            }.padding().frame(minWidth: 540)
        }.onAppear {
            chat.playAudio = { try audio.play($0) }; chat.stopAudio = { audio.player?.stop() }
            let session = chat
            audio.finished = { [weak session] in session?.audioFinished() }
        }.onDisappear { chat.cancelGeneration(); chat.stop() }
    }
    private func send() {
        guard let endpoint = app.activeEndpoint(byID: app.explainEndpointID), !app.explainModel.isEmpty else { notice = "설정에서 응답 제공자와 모델을 선택하세요."; return }
        let generator = EndpointGenerator(endpoint: endpoint, apiKey: app.endpointKey(endpoint), model: app.explainModel, instruction: "", temperature: app.explainTemperature, reasoningLevel: app.explainReasoningLevel)
        if chat.send(text: draft, images: images, provider: endpoint.name, model: app.explainModel, system: "You are a helpful assistant. Respond naturally to the user's request.", generate: { generator.generate("", conversation: $0) }) { draft = ""; images = []; notice = "" }
    }
    private func play(_ message: ChatMessage) {
        guard let key = Secrets.elevenLabsKey else { notice = "설정에서 ElevenLabs 키를 입력하세요."; return }
        let voice = VoiceConfig(voiceId: app.voiceId, modelId: app.modelId, settingsHash: app.voiceSettings.hash)
        let backend = ElevenLabsBackend(apiKey: key, settings: app.voiceSettings, models: app.elevenModels)
        chat.play(message, identity: app.voiceId + "|" + app.modelId + "|" + app.voiceSettings.hash) { text in
            var data = Data()
            for try await chunk in backend.stream(segment: text, voice: voice) { data.append(chunk) }
            return data
        }
    }
    private func attach() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let source = try? Data(contentsOf: url), source.count <= 10_000_000,
                  let image = NSImage(data: source), let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]), png.count <= 10_000_000 else { notice = "이미지는 10MB 이하 PNG/JPEG를 사용하세요."; continue }
            if images.count < 8 { images.append(png) }
        }
    }
    private func reuseConnections() {
        do {
            let old = ("~/Library/Application Support/Codebasic TTS/settings.json" as NSString).expandingTildeInPath
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: old))) as? [String: Any] ?? [:]
            guard let endpoints = object["endpoints"] else { notice = "V1 제공자 설정을 찾을 수 없습니다."; return }
            let decoded = try JSONDecoder().decode([CustomEndpoint].self, from: JSONSerialization.data(withJSONObject: endpoints))
            try FileManager.default.createDirectory(atPath: Secrets.appSupportDir, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: Secrets.appSupportDir + "/reuse-v1-credentials"), options: .atomic)
            app.endpoints = decoded
            app.explainEndpointID = object["explainEndpointID"] as? String ?? ""
            app.explainRoleModels = object["explainRoleModels"] as? [String: String] ?? [:]
            app.scriptEndpointID = object["scriptEndpointID"] as? String ?? ""
            app.scriptRoleModels = object["scriptRoleModels"] as? [String: String] ?? [:]
            app.visionEndpointID = object["visionEndpointID"] as? String ?? ""
            app.visionRoleModels = object["visionRoleModels"] as? [String: String] ?? [:]
            app.keyPresent = Secrets.elevenLabsKey != nil
            app.voiceId = object["voiceId"] as? String ?? app.voiceId
            app.modelId = object["modelId"] as? String ?? app.modelId
            app.saveSettings(); notice = "V1 연결 설정을 반영했습니다. 키 파일과 V1 데이터는 변경하지 않았습니다."
        } catch { notice = "설정 참조 실패: " + error.localizedDescription }
    }
}
