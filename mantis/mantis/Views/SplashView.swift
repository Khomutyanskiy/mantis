//
//  SplashView.swift
//  mantis
//
//  Экран загрузки при запуске: логотип, название и прогрев нейросети в фоне,
//  чтобы первый анализ и камера стартовали быстрее.
//

import SwiftUI

struct RootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            ContentView()
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            let started = Date()
            // загрузка модели Core ML в фоне (первый запуск модели — самый долгий)
            await Task.detached(priority: .userInitiated) {
                _ = try? PoseDetector()
            }.value
            let rest = 1.4 - Date().timeIntervalSince(started)
            if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
            withAnimation(.easeOut(duration: 0.45)) { showSplash = false }
        }
    }
}

struct SplashView: View {
    @State private var appeared = false
    @State private var scanning = false

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    // «прицел» вокруг логотипа — как рамка детекции
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Theme.moon.opacity(0.18), lineWidth: 1)
                        .frame(width: 168, height: 168)
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .trim(from: 0, to: 0.22)
                        .stroke(Theme.moon.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 168, height: 168)
                        .rotationEffect(.degrees(scanning ? 360 : 0))
                    Image("Logo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                }
                .scaleEffect(appeared ? 1 : 0.92)

                VStack(spacing: 6) {
                    Text("Mantis")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.moon)
                    Text("Аналитика витрины и торгового зала")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.moonDim)
                }
                .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 10) {
                Spacer()
                ProgressView()
                    .tint(Theme.moonDim)
                Text("Загружаем нейросеть…")
                    .font(.caption)
                    .foregroundStyle(Theme.moonDim)
                Text("РСМ АйТи")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.moonDim.opacity(0.7))
                    .padding(.top, 18)
            }
            .padding(.bottom, 28)
            .opacity(appeared ? 1 : 0)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { scanning = true }
        }
    }
}
