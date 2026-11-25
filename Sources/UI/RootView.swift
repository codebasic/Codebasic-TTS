import SwiftUI
struct RootView: View {
    let app: AppState
    var body: some View {
        TabView {
            ChatView().tabItem { Label("대화", systemImage: "bubble.left.and.bubble.right") }
            SettingsView().disabled(V2Runtime.liveValidation).tabItem { Label("설정", systemImage: "slider.horizontal.3") }
        }.frame(minWidth: 800, minHeight: 580)
    }
}
