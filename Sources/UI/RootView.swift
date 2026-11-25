import SwiftUI
import Combine

/// The management window. TTS remains independent from the external-agent
/// workspace and its explicitly enabled legacy explanation view.
struct RootView: View {
    let app: AppState
    @State private var selectedTab: Int
    @State private var unseenDrafts = 0

    init(app: AppState) {
        self.app = app
        _selectedTab = State(initialValue: app.selectedTab)
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tab in
                selectedTab = tab
                if app.selectedTab != tab { app.selectedTab = tab }
            }
        )
    }
    private var agentWorkspace: some View {
        ExplainWorkspace(drafts: app.explanationDrafts, catalog: app.agentCatalog, access: app.agentAccess)
    }

    var body: some View {
        if TTSRuntime.isPreview {
            agentWorkspace.frame(minWidth: 560, minHeight: 520)
        } else {
            productTabs
        }
    }

    private var productTabs: some View {
        TabView(selection: tabSelection) {
            GenerateView().tabItem { Label("TTS", systemImage: "waveform") }.tag(0)
            agentWorkspace
                .tabItem {
                    // Drafts open in this tab without stealing focus from the one in use.
                    Label(unseenDrafts > 0 ? "에이전트 · 새 대본 \(unseenDrafts)" : "에이전트", systemImage: "person.crop.circle")
                }
                .tag(1)
            HistoryView().tabItem { Label("히스토리", systemImage: "clock.arrow.circlepath") }.tag(2)
            BacklogView().tabItem { Label("백로그", systemImage: "flag") }.tag(3)
            SettingsView().tabItem { Label("설정", systemImage: "slider.horizontal.3") }.tag(4)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onReceive(app.$selectedTab.removeDuplicates()) { tab in
            if selectedTab != tab { selectedTab = tab }
        }
        .onReceive(app.explanationDrafts.$unseenArrivals.removeDuplicates()) { count in
            if selectedTab == 1 && count > 0 { app.explanationDrafts.markArrivalsSeen() }
            else { unseenDrafts = count }
        }
    }
}
