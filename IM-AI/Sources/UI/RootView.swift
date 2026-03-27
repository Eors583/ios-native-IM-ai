import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            TabView(selection: $app.selectedTab) {
                ConnectionView()
                    .tabItem { Label("首页", systemImage: "house") }
                    .tag(BottomTab.home)

                ChatRoomsView()
                    .tabItem { Label("聊天室", systemImage: "bubble.left.and.bubble.right") }
                    .tag(BottomTab.chatRooms)

                AiChatView()
                    .tabItem { Label("AI聊天", systemImage: "sparkles") }
                    .tag(BottomTab.ai)

                ProfileView()
                    .tabItem { Label("我的", systemImage: "person") }
                    .tag(BottomTab.profile)
            }

            if app.mainScreen == .chatRoom {
                ChatRoomView()
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.mainScreen == .chatRoom)
        .alert("提示", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}

