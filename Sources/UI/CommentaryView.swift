import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The 해설 panel: code → commentary. Top = source code, bottom = the generated
/// spoken-style explanation. From here you either hand the commentary to the
/// 생성 tab (코드 → 해설 → 대본 → 음성, each stage visible/editable) or speak it
/// directly. The actual 대본 + 음성 stages live in GenerateView.
struct CommentaryView: View {
    @EnvironmentObject var app: AppState
    @State private var showPrompt = false

    private var codeEmpty: Bool {
        app.codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var explanationEmpty: Bool {
        app.explanationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var border: some View { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }

    // Vision bindings: show the effective endpoint+model (override, else follow
    // the 해설 role) and store a remembered override once the user picks one.
    private var visionEndpointBinding: Binding<String> {
        Binding(get: { app.visionOverridden ? app.visionEndpointID : app.explainEndpointID },
                set: { app.visionEndpointID = $0; app.visionOverridden = true })
    }
    private var visionRoleModelsBinding: Binding<[String: String]> {
        Binding(get: { app.visionOverridden ? app.visionRoleModels : app.explainRoleModels },
                set: { app.visionRoleModels = $0; app.visionOverridden = true })
    }

    var body: some View {
        HSplitView {
            main
            if showPrompt {
                StageInspector(title: "해설 설정",
                               temperature: $app.explainTemperature,
                               prompt: $app.explainPrompt,
                               promptCaption: "해설 지시문 — 코드를 어떻게 해설할지 LLM에게 주는 규칙",
                               restore: { app.explainPrompt = CodeExplanation.defaultInstruction },
                               onChange: { app.saveSettings() })
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("코드").font(.headline)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    let imgs = (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]) ?? []
                    attach(imgs)
                    if let s = pb.string(forType: .string) { app.codeText = s }
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .help("클립보드의 코드/스크린샷을 붙여넣습니다 (텍스트는 코드로, 이미지는 첨부)")
                Button { showPrompt.toggle() } label: { Image(systemName: "sidebar.right") }
                    .controlSize(.small)
                    .help("프롬프트·생성 매개변수 패널 열기/닫기")
            }
            TextEditor(text: $app.codeText)
                .font(.body.monospaced()).frame(minHeight: 150)
                .overlay(border)
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in dropImages(providers); return true }
            Text("코드 입력창에 ⌘V — 텍스트는 코드로, 스크린샷은 이미지로 첨부됩니다.")
                .font(.caption2).foregroundStyle(.tertiary)

            if app.hasImages {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(app.codeImages.enumerated()), id: \.offset) { idx, data in
                            ZStack(alignment: .topTrailing) {
                                if let img = NSImage(data: data) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 96, height: 64).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                }
                                Button { app.removeImage(at: idx) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain).padding(2)
                            }
                        }
                        Button { app.clearImages() } label: { Label("모두 지우기", systemImage: "trash") }
                            .controlSize(.small)
                    }
                }
                .frame(height: 70)
            }

            HintField(placeholder: "추가 지시 (해설, 선택) — 맥락이나 재생성 방향. 예: 더 간결하게, 초보자 기준으로",
                      text: $app.explainHint,
                      help: "코드→해설 생성·이어서 해설·재생성에만 적용되는 일회성 지시 (프롬프트엔 저장 안 됨)")

            HStack(spacing: 8) {
                Button {
                    app.generateExplanation()
                } label: {
                    Label("해설 생성", systemImage: "wand.and.stars")
                }
                .disabled((codeEmpty && !app.hasImages) || app.explaining)
                .help("코드(텍스트·스크린샷)를 처음부터 해설합니다 (기존 해설을 대체)")

                Button {
                    app.continueExplanation()
                } label: {
                    Label("이어서 해설", systemImage: "text.append")
                }
                .disabled(codeEmpty || app.explaining)
                .help("이전 해설 이후 추가·변경된 부분만 이어서 해설에 덧붙입니다")

                Button { app.generateExplanation(force: true) } label: {
                    Label("재생성", systemImage: "arrow.clockwise")
                }
                .disabled((codeEmpty && !app.hasImages) || app.explaining)
                .help("해설 캐시를 무시하고 전체를 다시 생성")

                if app.explaining {
                    ProgressView().controlSize(.small)
                    Text("해설 생성 중…").font(.caption).foregroundStyle(.secondary)
                    Button { app.cancelGeneration() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .controlSize(.small)
                    .help("해설 생성을 중단합니다 (지금까지 스트림된 부분은 유지)")
                }
                Spacer()
                Toggle("생성 후 바로 재생", isOn: $app.explainAutoPlay)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("단축키(⌃⌥⌘E)·Services ‘코드 해설’로 만든 해설을 바로 읽습니다. 끄면 생성만 하고 창을 띄워, 검토 후 ‘전체 재생’으로 읽습니다.")
                    .onChange(of: app.explainAutoPlay) { _, _ in app.saveSettings() }
            }
            HStack(spacing: 16) {
                LLMModelPicker(label: "해설 모델",
                               endpointID: $app.explainEndpointID,
                               roleModels: $app.explainRoleModels,
                               onChange: { app.saveSettings() })
                LLMModelPicker(label: "비전 모델",
                               endpointID: visionEndpointBinding,
                               roleModels: visionRoleModelsBinding,
                               onChange: { app.saveSettings() })
                if app.visionOverridden {
                    Button {
                        app.visionOverridden = false; app.saveSettings()
                    } label: { Image(systemName: "arrow.uturn.backward") }
                        .controlSize(.small)
                        .help("비전 모델을 해설 모델로 되돌리기 (추종)")
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("해설").font(.headline)
                if app.canContinueExplain {
                    Text("· 이어쓰기 기준 설정됨").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.recordIssue(.explain) } label: { Label("이슈 기록", systemImage: "flag") }
                    .controlSize(.small)
                    .disabled(explanationEmpty)
                    .help("현재 해설 생성 컨텍스트(코드·프롬프트·추가 지시·해설)를 백로그에 기록")
                Button { app.clearCommentary() } label: { Label("비우기", systemImage: "trash") }
                    .controlSize(.small)
                    .disabled(explanationEmpty && !app.canContinueExplain)
                    .help("해설·이어쓰기 기준을 비우고 처음부터 시작")
            }

            TextEditor(text: $app.explanationText)
                .font(.body).frame(minHeight: 150)
                .overlay(border)

            HStack(spacing: 10) {
                Button { app.speakExplanation() } label: { Label("전체 재생", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(explanationEmpty || app.isBusy || app.explaining)
                    .help("해설을 재생합니다. 자막은 이 해설 그대로, 음성은 내부 대본(설정 → 음성 대본 정규화가 켜져 있으면 정규화)으로 읽습니다")
                Button { app.speakContinue() } label: { Label("이어서 읽기", systemImage: "forward.end.fill") }
                    .disabled(!app.hasLastSegment || app.explaining)
                    .help("마지막에 추가된 해설을 이어서 읽습니다 (재생 중이면 멈추고 그 부분을 재생)")
                Button { app.stop() } label: { Label("중지", systemImage: "stop.fill") }
                    .disabled(!app.isBusy && !app.explaining)

                Button { app.sendExplanationToGenerate() } label: {
                    Label("TTS로 보내기", systemImage: "arrow.right.circle")
                }
                .disabled(explanationEmpty)
                .help("해설을 TTS 탭으로 보내 음성 대본을 직접 보고 다듬은 뒤 재생합니다 (고급)")
                if app.isBusy { ProgressView().controlSize(.small) }
                Text(app.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            Text("모델은 위에서 선택 (등록된 엔드포인트별 통합 목록) · 엔드포인트 추가·삭제는 설정 탭")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 420, maxWidth: .infinity)
    }

    // MARK: - Image input (screenshots)

    private func pngData(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Attach pasted/dropped images as PNG (skips zero-size).
    private func attach(_ imgs: [NSImage]) {
        for img in imgs where !img.size.equalTo(.zero) {
            if let d = pngData(img) { app.codeImages.append(d) }
        }
    }

    private func dropImages(_ providers: [NSItemProvider]) {
        for p in providers where p.canLoadObject(ofClass: NSImage.self) {
            _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage else { return }
                Task { @MainActor in attach([img]) }
            }
        }
    }
}
