//
//  TimelineViews.swift
//  mantis
//
//  График накопления по времени (компактный на экране результата и подробный в отдельном окне)
//  и просмотр видео с разметкой во весь экран.
//

import AVKit
import Charts
import SwiftUI

// MARK: - Серии графика

struct TimelineSeries: Identifiable {
    let name: String
    let color: Color
    /// Моменты, когда счётчик увеличивался на 1 (по возрастанию).
    let times: [Double]
    /// Показывать на компактном графике.
    let compact: Bool

    var id: String { name }

    func value(at t: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

extension AnalysisResult {
    var timelineSeries: [TimelineSeries] {
        func ev(_ k: EventKind) -> [Double] { events.filter { $0.kind == k }.map(\.t).sorted() }
        var s: [TimelineSeries] = []
        s.append(TimelineSeries(name: isFullFrameZone ? "В кадре" : "В зоне", color: Theme.moon,
                                times: tracks.filter(\.everInZone).map(\.firstT).sorted(), compact: true))
        if line.count == 2 {
            s.append(TimelineSeries(name: "Прошли линию", color: .cyan, times: ev(.passed), compact: true))
        }
        if extended.entered != nil {
            s.append(TimelineSeries(name: "Вошли", color: .mint, times: extended.enterTimes.sorted(), compact: true))
        }
        s.append(TimelineSeries(name: "Посмотрели", color: PersonState.looked.color, times: ev(.looked), compact: true))
        s.append(TimelineSeries(name: "Притормозили", color: PersonState.slowed.color, times: ev(.slowed), compact: false))
        s.append(TimelineSeries(name: "Остановились", color: .orange, times: extended.stopTimes.sorted(), compact: false))
        s.append(TimelineSeries(name: "Подошли ближе", color: .pink, times: extended.approachTimes.sorted(), compact: false))
        return s
    }
}

/// Ступенчатые линии накопления.
struct TimelineLines: ChartContent {
    let series: [TimelineSeries]
    let duration: Double

    private struct P {
        let t: Double
        let v: Int
        let name: String
    }

    private var points: [P] {
        var out: [P] = []
        for s in series {
            out.append(P(t: 0, v: 0, name: s.name))
            for (i, t) in s.times.enumerated() { out.append(P(t: t, v: i + 1, name: s.name)) }
            out.append(P(t: max(duration, s.times.last ?? 0), v: s.times.count, name: s.name))
        }
        return out
    }

    var body: some ChartContent {
        ForEach(Array(points.enumerated()), id: \.offset) { _, p in
            LineMark(x: .value("Время, с", p.t), y: .value("Человек", p.v))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(by: .value("Метрика", p.name))
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }
}

extension View {
    /// Оси графика в цветах темы.
    func themedChartAxes() -> some View {
        self
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel().foregroundStyle(Theme.moonDim)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel().foregroundStyle(Theme.moonDim)
                }
            }
    }
}

// MARK: - Компактный график

struct TimelineChart: View {
    let result: AnalysisResult
    @State private var showDetail = false

    var body: some View {
        let series = result.timelineSeries.filter(\.compact)
        Button {
            showDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Накопление по времени").font(.headline).foregroundStyle(Theme.moon)
                    Spacer()
                    Label("подробно", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.moonDim)
                }
                Chart {
                    TimelineLines(series: series, duration: result.duration)
                }
                .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
                .themedChartAxes()
                .chartLegend(position: .bottom)
                .frame(height: 180)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                TimelineDetailView(result: result)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { showDetail = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.large])
        }
    }
}

// MARK: - Подробный график

struct TimelineDetailView: View {
    let result: AnalysisResult

    @State private var hidden: Set<String> = []
    @State private var selectedT: Double?

    private struct Occupancy: Identifiable {
        let id: Int
        let t: Double
        let n: Int
    }

    /// Сколько людей в зоне одновременно (≈ 2 точки в секунду).
    private var occupancy: [Occupancy] {
        let frames = result.frames
        guard !frames.isEmpty else { return [] }
        let step = max(1, Int((result.analyzedFPS / 2).rounded()))
        return stride(from: 0, to: frames.count, by: step).map { i in
            Occupancy(id: i, t: frames[i].time, n: frames[i].boxes.filter(\.inZone).count)
        }
    }

    var body: some View {
        let all = result.timelineSeries
        let visible = all.filter { !hidden.contains($0.name) }
        let occ = occupancy
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // переключатели серий
                FlowChips(items: all.map { ($0.name, $0.color) }, hidden: $hidden)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Накопление", subtitle: "проведите пальцем по графику — значения на момент")
                    Chart {
                        TimelineLines(series: visible, duration: result.duration)
                        if let t = selectedT {
                            RuleMark(x: .value("Момент", t))
                                .foregroundStyle(Theme.moon.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    .chartForegroundStyleScale(domain: visible.map(\.name), range: visible.map(\.color))
                    .chartXSelection(value: $selectedT)
                    .chartXScale(domain: 0...max(result.duration, 1))
                    .themedChartAxes()
                    .chartLegend(.hidden)
                    .frame(height: 300)
                }
                .themedCard(padding: 14)

                valuesCard(all)

                if !occ.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Одновременно в зоне",
                                      subtitle: "максимум \(result.extended.maxSimultaneous) чел.")
                        Chart {
                            ForEach(occ) { p in
                                AreaMark(x: .value("Время, с", p.t), y: .value("Человек", p.n))
                                    .interpolationMethod(.stepEnd)
                                    .foregroundStyle(Theme.moon.opacity(0.18))
                                LineMark(x: .value("Время, с", p.t), y: .value("Человек", p.n))
                                    .interpolationMethod(.stepEnd)
                                    .foregroundStyle(Theme.moon)
                            }
                            if let t = selectedT {
                                RuleMark(x: .value("Момент", t))
                                    .foregroundStyle(Theme.moon.opacity(0.5))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                        }
                        .chartXSelection(value: $selectedT)
                        .chartXScale(domain: 0...max(result.duration, 1))
                        .themedChartAxes()
                        .frame(height: 160)
                    }
                    .themedCard(padding: 14)
                }

                totals
            }
            .padding()
            .padding(.bottom, 20)
        }
        .themedScreen()
        .navigationTitle("График")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
    }

    private func valuesCard(_ all: [TimelineSeries]) -> some View {
        let t = selectedT.map { min(max($0, 0), result.duration) }
        let now = t.flatMap { tt in occupancy.last(where: { $0.t <= tt })?.n }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t.map { "На \(ResultView.formatTime($0))" } ?? "Итог за видео")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                Spacer()
                if let now {
                    Text("сейчас в зоне: \(now)").font(.caption).foregroundStyle(Theme.moonDim)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      alignment: .leading, spacing: 8) {
                ForEach(all) { s in
                    HStack(spacing: 8) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text(s.name).font(.caption).foregroundStyle(Theme.moonDim).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        Text("\(t.map { s.value(at: $0) } ?? s.times.count)")
                            .font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(Theme.moon)
                    }
                }
            }
        }
        .themedCard(padding: 14)
    }

    private var totals: some View {
        let m = result.extended
        let c = result.counters
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Все показатели", subtitle: "итог по всему видео")
            MetricList {
                MetricRow(icon: "clock", tint: Theme.moon, title: "Длительность", value: ResultView.formatTime(result.duration))
                MetricRow(icon: "person.2", tint: Theme.moon, title: result.isFullFrameZone ? "Людей в кадре" : "Людей в зоне",
                          value: "\(result.tracks.filter(\.everInZone).count)")
                if result.line.count == 2 {
                    MetricRow(icon: "figure.walk", tint: .cyan, title: "Прошли линию",
                              value: "\(c.passed)", detail: "→ \(c.passedForward)  ← \(c.passedBackward)")
                }
                if let e = m.entered {
                    MetricRow(icon: "door.left.hand.open", tint: .mint, title: "Вошли в магазин", value: "\(e)")
                }
                MetricRow(icon: "tortoise.fill", tint: PersonState.slowed.color, title: "Притормозили", value: "\(c.slowed)")
                MetricRow(icon: "eye.fill", tint: PersonState.looked.color, title: "Посмотрели", value: "\(c.looked)",
                          detail: m.avgLookSeconds.map { "в среднем \(heatNum($0)) с" })
                MetricRow(icon: "hand.raised.fill", tint: .orange, title: "Остановились", value: "\(m.stopped)",
                          detail: m.avgStopSeconds.map { "в среднем \(heatNum($0)) с" })
                MetricRow(icon: "arrow.down.right.and.arrow.up.left", tint: .pink, title: "Подошли ближе", value: "\(m.approached)")
                MetricRow(icon: "arrow.uturn.backward", tint: .pink, title: "Оглянулись", value: "\(m.lookedBack)")
                MetricRow(icon: "person.3.fill", tint: Theme.moon, title: "Одновременно, максимум", value: "\(m.maxSimultaneous)")
                MetricRow(icon: "figure.walk.motion", tint: Theme.moon, title: "Средняя скорость",
                          value: m.avgSpeed.map { "\(heatNum($0)) м/с" } ?? "—")
            }
        }
    }
}

/// Переключатели серий графика («таблетки» с цветной точкой), переносятся на новую строку.
struct FlowChips: View {
    let items: [(String, Color)]
    @Binding var hidden: Set<String>

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        let name = item.0, color = item.1
                        let on = !hidden.contains(name)
                        Button {
                            if on { hidden.insert(name) } else { hidden.remove(name) }
                        } label: {
                            HStack(spacing: 6) {
                                Circle().fill(on ? color : Theme.moonDim.opacity(0.4)).frame(width: 8, height: 8)
                                Text(name).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(on ? Theme.moon : Theme.moonDim)
                            .background(on ? Theme.surfaceHigh : Theme.surface, in: Capsule())
                            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Видео во весь экран

struct FullscreenVideoView: View {
    let result: AnalysisResult
    let clock: PlaybackClock
    let counters: Counters
    let seen: Int
    let heat: HeatGrid?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: clock.player) {
                OverlayView(result: result, time: clock.time, counters: counters, heat: heat)
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Закрыть")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 14) {
                    stat(result.isFullFrameZone ? "в кадре" : "в зоне", seen, .white)
                    if result.line.count == 2 { stat("прошли", counters.passed, .white) }
                    stat("притормозили", counters.slowed, PersonState.slowed.color)
                    stat("посмотрели", counters.looked, PersonState.looked.color)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.bottom, 70)   // над шкалой плеера
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.system(.headline, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
    }
}
