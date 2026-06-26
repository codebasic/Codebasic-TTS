import SwiftUI

/// The management window: four tabs.
struct RootView: View {
    var body: some View {
        TabView {
            GenerateView().tabItem { Label("생성", systemImage: "waveform") }
            HistoryView().tabItem { Label("히스토리", systemImage: "clock.arrow.circlepath") }
            SettingsView().tabItem { Label("설정", systemImage: "slider.horizontal.3") }
            ConnectionView().tabItem { Label("연결", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}
