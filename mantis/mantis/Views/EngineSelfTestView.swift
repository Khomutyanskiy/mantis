//
//  EngineSelfTestView.swift
//  mantis
//
//  Проверка движка: прогоняет эталонные данные (golden.json, получены Python-версией на тестовом ролике)
//  через Swift-трекер и подсчёт и сравнивает счётчики с Python.
//    A. Подсчёт: вход — люди уже с ID от Python-трекера → счётчики должны совпасть точно.
//    B. Трекер + подсчёт: вход — сырые детекции нейросети → Swift ByteTrack → счётчики должны совпасть.
//

import SwiftUI

nonisolated struct GoldenData: Decodable {
    nonisolated struct Expected: Decodable {
        var passed: Int
        var passedForward: Int
        var passedBackward: Int
        var slowed: Int
        var looked: Int
    }

    nonisolated struct Frame: Decodable {
        var t: Double
        var raw: [[Double]]
        var tracked: [[Double]]
    }

    var source: String
    var fps: Double
    var width: Double
    var height: Double
    var config: AnalyticsConfig
    var expected: Expected
    var expectedTracks: Int
    var frames: [Frame]
}

nonisolated struct SelfTestOutcome: Sendable {
    var name: String
    var expected: Counters
    var expectedTracks: Int
    var actual: Counters
    var actualTracks: Int
    var seconds: Double

    var passed: Bool { expected == actual && expectedTracks == actualTracks }
}

nonisolated enum EngineSelfTest {
    enum TestError: LocalizedError {
        case noGolden
        var errorDescription: String? { "В приложении нет golden.json — добавьте его в папку проекта mantis" }
    }

    static func keypoints(_ row: [Double], from start: Int) -> [Keypoint] {
        (0..<17).map { n in Keypoint(x: row[start + 3 * n], y: row[start + 3 * n + 1], conf: row[start + 3 * n + 2]) }
    }

    static func run() throws -> (source: String, frames: Int, outcomes: [SelfTestOutcome]) {
        guard let url = Bundle.main.url(forResource: "golden", withExtension: "json") else { throw TestError.noGolden }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let g = try decoder.decode(GoldenData.self, from: Data(contentsOf: url))
        let exp = Counters(passed: g.expected.passed, passedForward: g.expected.passedForward,
                           passedBackward: g.expected.passedBackward, slowed: g.expected.slowed,
                           looked: g.expected.looked)
        let line = Geometry.toPixels(g.config.countLine, width: g.width, height: g.height)
        let zone = Geometry.toPixels(g.config.showcaseZone, width: g.width, height: g.height)

        // A. Только подсчёт
        var start = Date()
        let a = Analytics(config: g.config, line: line, zone: zone, frameWidth: g.width, frameHeight: g.height)
        for (i, f) in g.frames.enumerated() {
            let people = f.tracked.map { r in
                TrackedPerson(trackId: Int(r[0]), box: Box(x1: r[1], y1: r[2], x2: r[3], y2: r[4]),
                              keypoints: keypoints(r, from: 5))
            }
            a.update(t: Double(i) / g.fps, people: people)
        }
        a.closeAll()
        let outA = SelfTestOutcome(name: "Подсчёт (ID от Python)", expected: exp, expectedTracks: g.expectedTracks,
                                   actual: a.counters, actualTracks: a.finished.count,
                                   seconds: Date().timeIntervalSince(start))

        // B. Трекер + подсчёт
        start = Date()
        let tracker = ByteTracker()
        let b = Analytics(config: g.config, line: line, zone: zone, frameWidth: g.width, frameHeight: g.height)
        for (i, f) in g.frames.enumerated() {
            let raw = f.raw.map { r in
                RawDetection(box: Box(x1: r[0], y1: r[1], x2: r[2], y2: r[3]), score: r[4],
                             keypoints: keypoints(r, from: 5))
            }
            let out = tracker.update(raw, width: g.width, height: g.height)
            let people = out.map { TrackedPerson(trackId: $0.trackId, box: $0.box, keypoints: raw[$0.detIndex].keypoints) }
            b.update(t: Double(i) / g.fps, people: people)
        }
        b.closeAll()
        let outB = SelfTestOutcome(name: "Трекер ByteTrack + подсчёт", expected: exp, expectedTracks: g.expectedTracks,
                                   actual: b.counters, actualTracks: b.finished.count,
                                   seconds: Date().timeIntervalSince(start))
        return (g.source, g.frames.count, [outA, outB])
    }
}

struct EngineSelfTestView: View {
    @State private var outcomes: [SelfTestOutcome] = []
    @State private var info = ""
    @State private var errorText: String?
    @State private var running = false

    var body: some View {
        List {
            Section {
                Text("Эталон — результат Python-версии на тестовом ролике. Swift-движок должен дать те же цифры.")
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
                if !info.isEmpty { Text(info).font(.footnote) }
            }
            .listRowBackground(Theme.surface)
            if running {
                ProgressView("Проверка…")
                    .listRowBackground(Theme.surface)
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, o in
                Section {
                    row("Прошли", o.expected.passed, o.actual.passed)
                    row("  вперёд", o.expected.passedForward, o.actual.passedForward)
                    row("  назад", o.expected.passedBackward, o.actual.passedBackward)
                    row("Притормозили", o.expected.slowed, o.actual.slowed)
                    row("Посмотрели", o.expected.looked, o.actual.looked)
                    row("Людей (треков)", o.expectedTracks, o.actualTracks)
                } header: {
                    HStack {
                        Text(o.name)
                        Spacer()
                        Text(o.passed ? "✅ совпадает" : "❌ расхождение")
                    }
                } footer: {
                    Text(String(format: "%.0f мс", o.seconds * 1000))
                }
                .listRowBackground(Theme.surface)
            }
        }
        .themedList()
        .navigationTitle("Проверка движка")
        .themedNavigationBar()
        .task { await run() }
    }

    private func row(_ title: String, _ expected: Int, _ actual: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("Python \(expected)").foregroundStyle(Theme.moonDim)
            Text("Swift \(actual)").bold().foregroundStyle(expected == actual ? Theme.moon : Color.red)
        }
        .monospacedDigit()
    }

    private func run() async {
        guard outcomes.isEmpty else { return }
        running = true
        defer { running = false }
        do {
            let r = try await Task.detached(priority: .userInitiated) { try EngineSelfTest.run() }.value
            outcomes = r.outcomes
            info = "Ролик: \(r.source), кадров: \(r.frames)"
        } catch {
            errorText = error.localizedDescription
        }
    }
}
