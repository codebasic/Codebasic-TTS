import SwiftUI

/// The management window. TTS is the core function (first tab); 해설 (code →
/// commentary) is a feeder that hands its prose to TTS via "TTS로 보내기".
struct RootView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        TabView(selection: $app.selectedTab) {
            GenerateView().tabItem { Label("TTS", systemImage: "waveform") }.tag(0)
            CommentaryView().tabItem { Label("해설", systemImage: "text.book.closed") }.tag(1)
            HistoryView().tabItem { Label("히스토리", systemImage: "clock.arrow.circlepath") }.tag(2)
            BacklogView().tabItem { Label("백로그", systemImage: "flag") }.tag(3)
            SettingsView().tabItem { Label("설정", systemImage: "slider.horizontal.3") }.tag(4)
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
