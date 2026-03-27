//
//  IM_AIApp.swift
//  IM-AI
//
//  Created by chuzu on 2026/3/26.
//

import SwiftUI

@main
struct IM_AIApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
        }
    }
}