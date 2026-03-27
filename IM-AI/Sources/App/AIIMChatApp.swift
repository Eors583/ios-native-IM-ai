import SwiftUI

/// 注意：工程入口使用 `IM_AIApp`（位于 `IM-AI/IM_AIApp.swift`）。
/// 这个类型保留为历史/复用，但不能标记为 `@main`，否则会出现多个入口导致无法编译。
struct AIIMChatApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}

