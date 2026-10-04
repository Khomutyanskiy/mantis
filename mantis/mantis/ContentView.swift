//
//  ContentView.swift
//  mantis
//
//  Корневой экран с нижним меню: Анализ видео · Камера · Настройки.
//

import SwiftUI

struct ContentView: View {
    enum AppTab: Hashable {
        case video, camera, settings, profile
    }

    @State private var selection: AppTab = .video

    var body: some View {
        TabView(selection: $selection) {
            Tab("Анализ", systemImage: "film.stack", value: AppTab.video) {
                VideoHomeView()
            }
            Tab("Камера", systemImage: "camera.viewfinder", value: AppTab.camera) {
                CameraView()
            }
            Tab("Настройки", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                SettingsView()
            }
            Tab("Профиль", systemImage: "person.fill", value: AppTab.profile) {
                ProfileView()
            }
        }
        .tint(Theme.moon)
        .toolbarBackground(Theme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.moon)
    }
}

#Preview {
    ContentView()
}
