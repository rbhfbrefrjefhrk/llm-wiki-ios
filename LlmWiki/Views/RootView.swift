import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            BrowseView()
                .tabItem { Label("知识库", systemImage: "doc.text") }
            ChatView()
                .tabItem { Label("问答", systemImage: "bubble.left.and.bubble.right") }
            SettingsView()
                .tabItem { Label("设置与同步", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}
