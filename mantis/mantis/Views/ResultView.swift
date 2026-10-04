//
//  ResultView.swift
//  mantis
//
//  Просмотр результата: видео с рамками (синхронно с плеером, перемотка работает), итоговые цифры,
//  график накопления и список событий.
//

import AVKit
import SwiftUI

/// Плеер + текущее время воспроизведения для отрисовки разметки.
@Observable
final class PlaybackClock {
    let player: AVPlayer
    var time: Double = 0
    @ObservationIgnored private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.time = t.seconds
            }
        }
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

struct ResultView: View {
    let result: AnalysisResult
    /// Каждое увеличение — команда «обнулить счётчики» с текущего момента видео.
    var resetToken: Int = 0
    @State private var clock: PlaybackClock
    /// Момент видео, с которого считаем после сброса (nil — с начала).
    @State private var resetTime: Double?
    /// Самый дальний момент, до которого видео уже проигрывалось. Счётчики не откатываются,
    /// когда ролик доиграл до конца и начался заново или его перемотали назад.
    @State private var watchedUpTo: Double = 0
    /// Тепловые пятна поверх видео (накопленные до текущего момента).
    @State private var heatOnVideo = false
    @State private var fullScreen = false
    @State private var reportFile: ShareFile?
    @State private var makingReport = false
    @State private var savedToHistory = false
    @AppStorage(SettingsKeys.heatScale) private var heatScale = 1.0

    init(result: AnalysisResult, resetToken: Int = 0) {
        self.result = result
        self.resetToken = resetToken
        _clock = State(initialValue: PlaybackClock(url: result.videoURL))
    }

    /// Сброс действует, пока видео не перемотали назад раньше точки сброса.
    private var effectiveReset: Double? { resetTime }

    /// До какого момента считаем: текущая позиция или самая дальняя просмотренная.
    private var countUpTo: Double { max(clock.time, watchedUpTo) + 1e-3 }

    /// Сколько разных людей появилось в кадре на текущий момент (с учётом сброса).
    private var liveSeen: Int {
        let upTo = countUpTo
        let after = effectiveReset
        func inWindow(_ t: Double) -> Bool { t <= upTo && (after.map { t > $0 } ?? true) }
        var ids = Set(result.tracks.filter { $0.everInZone && inWindow($0.firstT) }.map { $0.trackId })
        for e in result.events where inWindow(e.t) { ids.insert(e.trackId) }
        return ids.count
    }

    /// Счётчики на текущий момент воспроизведения (с учётом сброса).
    private var liveCounters: Counters {
        Counters.from(events: result.events, after: effectiveReset, upTo: countUpTo)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VideoPlayer(player: clock.player) {
                    OverlayView(result: result, time: clock.time, counters: liveCounters, heat: videoHeat)
                }
                .aspectRatio(result.width / max(result.height, 1), contentMode: .fit)
                .frame(maxHeight: 520)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    Button {
                        fullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .padding(10)
                    .accessibilityLabel("Во весь экран")
                }

                legend

                HStack {
                    Spacer()
                    HeatChip(title: "Тепловые пятна на видео", icon: "flame.fill", on: heatOnVideo) {
                        heatOnVideo.toggle()
                    }
                    Spacer()
                }
                .disabled(result.samples.isEmpty)

                if let r = effectiveReset {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Счётчики обнулены на \(Self.formatTime(r))")
                        Spacer()
                        Button("Отменить") { resetTime = nil }
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.moon)
                    .themedCard(padding: 10)
                }

                SummaryCards(counters: liveCounters, seen: liveSeen, lineEnabled: result.line.count == 2,
                             zoneIsFullFrame: result.isFullFrameZone)

                ScoreCard(score: score)

                MoneyCard(estimate: money, profile: AccountModel.shared.profile)

                BehaviorList(m: result.extended, speedScale: heatScale)

                FunnelView(m: result.extended, slowed: result.counters.slowed)

                FlowList(m: result.extended)

                HeatmapLink(source: HeatSource(result: result))

                if !result.tracks.isEmpty {
                    TimelineChart(result: result)
                }

                Button {
                    Task { await makeReport() }
                } label: {
                    HStack(spacing: 10) {
                        if makingReport {
                            ProgressView().tint(Theme.background)
                        } else {
                            Image(systemName: "doc.richtext")
                        }
                        Text(makingReport ? "Готовлю отчёт…" : "Скачать PDF-отчёт")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Theme.background)
                    .background(Theme.moon, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(makingReport)

                infoBlock

                if !result.events.isEmpty {
                    EventsList(events: result.events, numbers: result.numbers)
                }
            }
            .padding()
        }
        .themedScreen()
        .sheet(item: $reportFile) { f in
            ActivityView(items: [f.url]).ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $fullScreen) {
            FullscreenVideoView(result: result, clock: clock, counters: liveCounters, seen: liveSeen,
                                heat: videoHeat) { fullScreen = false }
        }
        .onAppear {
            clock.player.play()
            saveToHistory()
        }
        .onDisappear { clock.stop() }
        .onChange(of: resetToken) { _, _ in
            if clock.time >= result.duration - 0.3 {
                // видео доиграло — обнуляем и смотрим заново с начала
                resetTime = nil
                watchedUpTo = 0
                let clock = self.clock
                clock.player.seek(to: .zero) { _ in
                    Task { @MainActor in
                        clock.time = 0
                        watchedUpTo = 0
                        clock.player.play()
                    }
                }
            } else {
                // обнуляем с текущего момента, дальше счёт идёт по мере воспроизведения
                resetTime = clock.time
                watchedUpTo = clock.time
            }
        }
        .onChange(of: clock.time) { _, t in
            if t > watchedUpTo { watchedUpTo = t }
        }
    }

    private var peopleInZone: Int { result.tracks.filter(\.everInZone).count }

    private var score: ShowcaseScore? {
        ShowcaseScore.from(result.extended, counters: result.counters, people: peopleInZone)
    }

    private var money: MoneyEstimate {
        MoneyEstimate.compute(profile: AccountModel.shared.profile, people: peopleInZone, looked: result.counters.looked,
                              entered: result.extended.entered, duration: result.duration)
    }

    /// Итог анализа — в историю (и в облако, если вошли). Один раз на результат.
    private func saveToHistory() {
        guard !savedToHistory else { return }
        savedToHistory = true
        let c = result.counters, m = result.extended, mo = money
        ReportStore.shared.add(ReportSummary(source: "video", title: "Видео", duration: result.duration,
                                             people: peopleInZone, passed: c.passed, slowed: c.slowed, looked: c.looked,
                                             stopped: m.stopped, approached: m.approached, entered: m.entered,
                                             score: score?.value, revenue: mo.revenue, perMonth: mo.perMonth))
    }

    /// PDF со всеми цифрами, графиком, событиями и тепловыми картами → «Поделиться» / «Сохранить в Файлы».
    private func makeReport() async {
        makingReport = true
        defer { makingReport = false }
        var source = HeatSource(result: result)
        source.still = await HeatReport.frame(url: result.videoURL, at: source.backgroundTime)
        let period = "всё видео, \(Self.formatTime(result.duration))"
        if let url = HeatReport.make(source: source, range: nil, period: period, scale: heatScale, timeline: result) {
            reportFile = ShareFile(url: url)
        }
    }

    /// Где люди провели время с начала видео до текущего момента.
    private var videoHeat: HeatGrid? {
        guard heatOnVideo else { return nil }
        return HeatBuilder.frame(result.samples, layer: .time, range: 0...max(clock.time, 0.01),
                                 width: result.width, height: result.height, columns: 24)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(.tracked, "в кадре")
            if result.line.count == 2 {
                legendItem(.passed, "прошёл")
            }
            legendItem(.slowed, "притормозил")
            legendItem(.looked, "посмотрел")
        }
        .font(.caption2)
        .foregroundStyle(Theme.moonDim)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func legendItem(_ s: PersonState, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).stroke(s.color, lineWidth: 2)
                .frame(width: 12, height: 12)
            Text(title)
        }
    }

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Видео: \(Int(result.width))×\(Int(result.height)), \(Self.formatTime(result.duration))")
            Text("Проанализировано кадров: \(result.frames.count) (\(Int(result.analyzedFPS)) в секунду)")
            Text("Время анализа: \(String(format: "%.1f", result.processingSeconds)) с")
            Text("Итог по всему видео: прошли \(result.counters.passed), притормозили \(result.counters.slowed), посмотрели \(result.counters.looked)")
            Text("Людей в кадре было: \(result.tracks.count)")
            Text("Нейросеть: \(result.computeDescription), детекций \(result.rawDetections), макс. уверенность \(String(format: "%.2f", result.maxScore))")
        }
        .font(.footnote)
        .foregroundStyle(Theme.moonDim)
    }

    static func formatTime(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SummaryCards: View {
    let counters: Counters
    /// Сколько разных людей было в кадре (в зоне) — база для процентов.
    let seen: Int
    var lineEnabled = true
    var zoneIsFullFrame = true

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        if lineEnabled {
            // четыре карточки — сеткой 2×2
            LazyVGrid(columns: columns, spacing: 10) { cards }
        } else {
            HStack(spacing: 10) { cards }
        }
    }

    @ViewBuilder
    private var cards: some View {
        card(zoneIsFullFrame ? "В кадре" : "В зоне", "\(seen)", "человек", Theme.moon)
        if lineEnabled {
            card("Прошли", "\(counters.passed)",
                 "→ \(counters.passedForward)  ← \(counters.passedBackward)", Theme.moon)
        }
        card("Притормозили", "\(counters.slowed)", rate(counters.slowed), PersonState.slowed.color)
        card("Посмотрели", "\(counters.looked)", rate(counters.looked), PersonState.looked.color)
    }

    /// Доля от всех людей в кадре (не от прошедших линию: притормозить и посмотреть
    /// может и тот, кто линию не пересёк).
    private func rate(_ n: Int) -> String {
        guard seen > 0 else { return "—" }
        let p = min(100, Int((Double(n) / Double(seen) * 100).rounded()))
        return "\(p)% от \(zoneIsFullFrame ? "людей в кадре" : "людей в зоне")"
    }

    private func card(_ title: String, _ value: String, _ sub: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.moonDim)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(sub).font(.caption2).foregroundStyle(Theme.moonDim).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(padding: 10)
    }
}

struct EventsList: View {
    let events: [AnalyticsEvent]
    var numbers: [Int: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("События").font(.headline).foregroundStyle(Theme.moon)
            ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                HStack {
                    Text(ResultView.formatTime(e.t)).monospacedDigit().foregroundStyle(Theme.moonDim)
                    Text("#\(numbers[e.trackId] ?? e.trackId)").bold()
                    Text(e.kind.title)
                    if e.kind == .passed {
                        Text(e.direction == "forward" ? "→" : "←").foregroundStyle(Theme.moonDim)
                    }
                    Spacer()
                }
                .font(.subheadline)
            }
        }
    }
}
