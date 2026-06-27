import SwiftUI

/// The management window: five tabs. The 해설 tab leads the pipeline
/// (코드 → 해설), then hands off to 생성 (해설 → 대본 → 음성).
struct RootView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        TabView(selection: $app.selectedTab) {
            CommentaryView().tabItem { Label("해설", systemImage: "text.book.closed") }.tag(0)
            GenerateView().tabItem { Label("생성", systemImage: "waveform") }.tag(1)
            HistoryView().tabItem { Label("히스토리", systemImage: "clock.arrow.circlepath") }.tag(2)
            SettingsView().tabItem { Label("설정", systemImage: "slider.horizontal.3") }.tag(3)
            ConnectionView().tabItem { Label("연결", systemImage: "antenna.radiowaves.left.and.right") }.tag(4)
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
