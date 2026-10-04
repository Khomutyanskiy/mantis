//
//  mantisApp.swift
//  mantis
//
//  Created by Khomutyanskiy Aleksey on 03.10.2026.
//

import SwiftUI

@main
struct mantisApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Cloud.configure()            // Firebase (если пакет и GoogleService-Info.plist на месте)
        AccountModel.shared.start()  // слушаем вход/выход
    }

    var body: some Scene {
        WindowGroup {
            RootView()   // экран загрузки → вкладки
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { HourlyStore.shared.flush() }   // не терять статистику при сворачивании
        }
    }
}
