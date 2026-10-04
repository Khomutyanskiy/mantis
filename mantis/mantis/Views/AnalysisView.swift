//
//  AnalysisView.swift
//  mantis
//
//  Экран видео: разметка на кадре (зона, линия) → анализ с прогрессом → результат.
//  Кнопка ↺: обнулить счётчики с текущего момента или изменить разметку и пересчитать.
//

import SwiftUI

@Observable
final class ProgressBox {
    var value: Double = 0
}

struct AnalysisView: View {
    enum Phase {
        case setup, analyzing, done, failed
    }

    let url: URL

    @AppStorage(SettingsKeys.markup) private var markupJSON = ""
    @AppStorage(SettingsKeys.showcaseDirection) private var direction = ShowcaseDirection.camera.rawValue
    @AppStorage(SettingsKeys.videoLens) private var lens = Lens.main.rawValue

    @State private var markup = Markup()
    @State private var phase: Phase = .setup
    @State private var progress = ProgressBox()
    @State private var result: AnalysisResult?
    @State private var errorText: String?
    @State private var runID = UUID()
    @State private var showResetConfirm = false
    @State private var resetToken = 0

    var body: some View {
        Group {
            switch phase {
            case .setup:
                MarkupEditorView(url: url, markup: $markup) { start() }
            case .analyzing:
                VStack(spacing: 16) {
                    ProgressView(value: progress.value)
                        .progressViewStyle(.linear)
                        .tint(Theme.moon)
                    Text("Анализ видео… \(Int(progress.value * 100))%")
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.moon)
                    Text("Распознавание идёт на телефоне, видео никуда не отправляется")
                        .font(.footnote)
                        .foregroundStyle(Theme.moonDim)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            case .done:
                if let result {
                    ResultView(result: result, resetToken: resetToken)
                        .id(runID)  // после пересчёта — новый плеер с нуля
                }
            case .failed:
                VStack(spacing: 16) {
                    ContentUnavailableView("Не удалось проанализировать",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(errorText ?? ""))
                    Button("Изменить разметку") { phase = .setup }
                        .foregroundStyle(Theme.moon)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedScreen()
        .navigationTitle(phase == .setup ? "Разметка" : "Анализ")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .toolbar {
            if phase == .done {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showResetConfirm = true
                    } label: {
                        Label("Сбросить", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .confirmationDialog("Сброс", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Обнулить счётчики") { resetToken += 1 }
            Button("Изменить разметку и пересчитать") { phase = .setup }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("«Обнулить» — счёт начнётся заново с текущего момента видео. «Изменить разметку» — откроется кадр с зоной и линией, затем видео будет проанализировано заново.")
        }
        .onAppear {
            // Для нового видео зона всегда начинается со всего кадра (точки в углах),
            // настройка линии берётся из прошлой разметки.
            var m = Markup.decode(markupJSON)
            m.zone = Markup.fullFrame
            markup = m
        }
        .task(id: runID) {
            if phase == .analyzing { await run() }
        }
    }

    private func start() {
        markupJSON = markup.json   // запоминаем разметку для следующих видео
        result = nil
        errorText = nil
        progress.value = 0
        phase = .analyzing
        runID = UUID()             // запускает .task(id:)
    }

    private func run() async {
        var config = markup.analyticsConfig(direction: ShowcaseDirection(rawValue: direction) ?? .camera)
        config.slowdown.focalRatio = (Lens(rawValue: lens) ?? .main).focalRatio
        let analyzer = VideoAnalyzer(config: config, entrance: markup.entranceForAnalysis)
        let url = self.url
        let box = progress
        let job = Task.detached(priority: .userInitiated) {
            try await analyzer.analyze(url: url) { p in
                Task { @MainActor in box.value = p }
            }
        }
        do {
            let r = try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
            result = r
            phase = .done
        } catch is CancellationError {
            // ушли с экрана — ничего не показываем
        } catch {
            errorText = error.localizedDescription
            phase = .failed
        }
    }
}
