//
//  CameraView.swift
//  mantis
//
//  Вкладка «Камера»: живой подсчёт с камеры телефона или IP-камеры (RTSP).
//  Превью с рамками людей, старт/стоп, разметка на текущем кадре, сброс, живые метрики и тепловая карта.
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - Модель экрана

@Observable
final class LiveCameraModel {
    enum Status: Equatable {
        case idle, ready, denied, unavailable
    }

    enum Source: String {
        case phone, ip
    }

    var status: Status = .idle
    var source: Source = .phone
    var isCounting = false
    /// IP-камера: текст состояния, идёт ли видео, размер кадра.
    var ipState = ""
    var ipConnected = false
    var ipSize: CGSize?
    var snapshot = LiveSnapshot()
    var still: CGImage?
    var stillVersion = 0
    var errorText: String?
    var thermalWarning = false

    @ObservationIgnored let engine = LiveCameraEngine()
    /// Последние итоги — для прироста по часам в HourlyStore.
    @ObservationIgnored private var lastTotals: HourStat?
    @ObservationIgnored let ipView = RTSPDisplayView()
    @ObservationIgnored private var rtsp: RTSPSource?

    init() {
        let model = self
        engine.onSnapshot = { s in
            Task { @MainActor in
                model.snapshot = s
                model.accountHour(s)
                let state = ProcessInfo.processInfo.thermalState
                model.thermalWarning = state == .serious || state == .critical
            }
        }
        engine.onStill = { image in
            Task { @MainActor in
                model.still = image
                model.stillVersion += 1
            }
        }
        engine.onError = { message in
            Task { @MainActor in
                model.errorText = message
                model.isCounting = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    func activate() async {
        if source == .ip {
            connectIP()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUp()
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { setUp() } else { status = .denied }
        default:
            status = .denied
        }
    }

    private func setUp() {
        do {
            try engine.configure()
            engine.startPreview()
            status = .ready
        } catch {
            errorText = error.localizedDescription
            status = .unavailable
        }
    }

    func deactivate() {
        if isCounting { stop() }
        engine.stopPreview()
        disconnectIP()
        if status == .ready { status = .idle }
    }

    /// Переключить источник: телефон ↔ IP-камера.
    func switchSource(_ new: Source) async {
        guard new != source else { return }
        deactivate()
        source = new
        snapshot = LiveSnapshot()
        await activate()
    }

    // MARK: IP-камера

    func connectIP() {
        disconnectIP()
        let cfg = IPCameraConfig.load()
        guard !cfg.isEmpty else {
            ipState = "Камера не настроена"
            return
        }
        ipState = "Подключение…"
        let source = RTSPSource(url: cfg.url, user: cfg.user, password: Keychain.get(IPCameraConfig.keychainAccount))
        let model = self
        let engine = self.engine
        source.onFrame = { frame, t in
            engine.feed(frame, time: t)
            Task { @MainActor in model.ipView.show(frame) }
        }
        source.onState = { state in
            Task { @MainActor in model.ipStateChanged(state) }
        }
        rtsp = source
        source.start()
    }

    func disconnectIP() {
        rtsp?.stop()
        rtsp = nil
        ipConnected = false
        ipView.clear()
    }

    private func ipStateChanged(_ s: RTSPSource.State) {
        switch s {
        case .connecting:
            ipState = "Подключение…"
            ipConnected = false
        case .playing(let codec, let w, let h):
            ipState = "IP-камера · \(codec) \(w)×\(h)"
            ipConnected = true
            ipSize = CGSize(width: w, height: h)
        case .failed(let msg):
            ipState = msg
            ipConnected = false
        case .stopped:
            ipConnected = false
        }
    }

    func start(markup: Markup, direction: ShowcaseDirection) {
        errorText = nil
        var config = markup.analyticsConfig(direction: direction)
        // камера приложения — основной объектив 1×; IP-камеры обычно 2,8–4 мм — тоже близко к 1×
        config.slowdown.focalRatio = Lens.main.focalRatio
        lastTotals = HourStat()
        engine.startCounting(config: config, entrance: markup.entranceForAnalysis, usePhoneCamera: source == .phone)
        isCounting = true
        UIApplication.shared.isIdleTimerDisabled = true   // экран не гаснет, пока идёт подсчёт
    }

    /// Прибавить прирост счётчиков к текущему часу. После сброса счётчики падают — тогда просто новая база.
    func accountHour(_ s: LiveSnapshot) {
        guard isCounting else { return }
        let prev = lastTotals ?? HourStat()
        let cur = HourStat(people: s.seen, looked: s.counters.looked, slowed: s.counters.slowed,
                           passed: s.counters.passed, entered: max(prev.entered, s.extended?.entered ?? 0),
                           seconds: s.elapsed)
        if cur.people >= prev.people, cur.looked >= prev.looked, cur.slowed >= prev.slowed,
           cur.passed >= prev.passed, cur.seconds >= prev.seconds {
            HourlyStore.shared.add(HourStat(people: cur.people - prev.people, looked: cur.looked - prev.looked,
                                            slowed: cur.slowed - prev.slowed, passed: cur.passed - prev.passed,
                                            entered: cur.entered - prev.entered, seconds: cur.seconds - prev.seconds))
            lastTotals = cur
        } else {
            lastTotals = HourStat(people: cur.people, looked: cur.looked, slowed: cur.slowed, passed: cur.passed,
                                  entered: s.extended?.entered ?? 0, seconds: cur.seconds)
        }
    }

    /// Итог сессии — в историю.
    private func saveSession() {
        let s = snapshot
        guard s.seen > 0 else { return }
        let profile = AccountModel.shared.profile
        let score = s.extended.flatMap { ShowcaseScore.from($0, counters: s.counters, people: s.seen) }
        let money = MoneyEstimate.compute(profile: profile, people: s.seen, looked: s.counters.looked,
                                          entered: s.extended?.entered, duration: s.elapsed)
        ReportStore.shared.add(ReportSummary(source: "camera", title: "Камера", duration: s.elapsed, people: s.seen,
                                             passed: s.counters.passed, slowed: s.counters.slowed, looked: s.counters.looked,
                                             stopped: s.extended?.stopped ?? 0, approached: s.extended?.approached ?? 0,
                                             entered: s.extended?.entered, score: score?.value,
                                             revenue: money.revenue, perMonth: money.perMonth))
    }

    func stop() {
        if isCounting { saveSession() }
        HourlyStore.shared.flush()
        engine.stopCounting()
        isCounting = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func reset() {
        engine.reset()
    }

    func requestStill() {
        engine.requestStill()
    }
}

// MARK: - Экран

struct CameraView: View {
    @AppStorage(SettingsKeys.cameraMarkup) private var markupJSON = ""
    @AppStorage(SettingsKeys.showcaseDirection) private var direction = ShowcaseDirection.camera.rawValue
    @AppStorage(SettingsKeys.heatScale) private var heatScale = 1.0
    @AppStorage("liveSource") private var sourceRaw = LiveCameraModel.Source.phone.rawValue
    @AppStorage("ipCameraMarkupJSON") private var ipMarkupJSON = ""

    @State private var model = LiveCameraModel()
    @State private var markup = Markup()
    @State private var waitingForStill = false
    @State private var showEditor = false
    @State private var showHeatmap = false
    @State private var showResetConfirm = false
    @State private var reportFile: ShareFile?
    @State private var showIPSettings = false
    @State private var showDiscovery = false

    private var source: LiveCameraModel.Source { LiveCameraModel.Source(rawValue: sourceRaw) ?? .phone }
    private var isIP: Bool { source == .ip }

    private var showcase: ShowcaseDirection { ShowcaseDirection(rawValue: direction) ?? .camera }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("Источник", selection: $sourceRaw) {
                        Text("Камера телефона").tag(LiveCameraModel.Source.phone.rawValue)
                        Text("IP-камера").tag(LiveCameraModel.Source.ip.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isCounting)

                    if isIP && IPCameraConfig.load().isEmpty {
                        ipEmptyView
                    } else if isIP {
                        liveBlock
                    } else {
                        switch model.status {
                        case .denied:
                            permissionView
                        case .unavailable:
                            ContentUnavailableView("Камера недоступна", systemImage: "video.slash",
                                                   description: Text(model.errorText ?? ""))
                        default:
                            liveBlock
                        }
                    }
                }
                .padding()
                .padding(.bottom, 24)
            }
            .themedScreen()
            .navigationTitle("Камера")
            .navigationBarTitleDisplayMode(.inline)
            .themedNavigationBar()
            .toolbar {
                if isIP {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showDiscovery = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Найти камеры в сети")
                        .disabled(model.isCounting)
                        Button {
                            showIPSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Настройки IP-камеры")
                        .disabled(model.isCounting)
                    }
                }
            }
            .task {
                model.source = source
                markup = Markup.decode(isIP ? ipMarkupJSON : markupJSON)
                await model.activate()
            }
            .onChange(of: sourceRaw) { _, _ in
                markup = Markup.decode(isIP ? ipMarkupJSON : markupJSON)
                Task { await model.switchSource(source) }
            }
            .sheet(isPresented: $showDiscovery) {
                NavigationStack {
                    CameraDiscoveryView { url, user, pass in
                        var cfg = IPCameraConfig.load()
                        cfg.url = url
                        if !user.isEmpty { cfg.user = user }
                        cfg.save()
                        if !pass.isEmpty { Keychain.set(pass, account: IPCameraConfig.keychainAccount) }
                        showDiscovery = false
                        model.connectIP()
                        // ONVIF без пароля не бывает; для «только RTSP» логин и пароль — в настройках
                        if pass.isEmpty {
                            Task {
                                try? await Task.sleep(for: .milliseconds(700))   // дождаться закрытия листа поиска
                                showIPSettings = true
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { showDiscovery = false }
                        }
                    }
                }
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showIPSettings) {
                NavigationStack {
                    IPCameraSettingsView { model.connectIP() }
                }
                .preferredColorScheme(.dark)
            }
            .onDisappear { model.deactivate() }
            .onChange(of: model.stillVersion) { _, _ in
                if waitingForStill {
                    waitingForStill = false
                    showEditor = true
                }
            }
            .sheet(isPresented: $showEditor) { editorSheet }
            .sheet(isPresented: $showHeatmap) { heatmapSheet }
            .sheet(item: $reportFile) { f in
                ActivityView(items: [f.url]).ignoresSafeArea()
            }
            .confirmationDialog("Обнулить счётчики?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Обнулить", role: .destructive) { model.reset() }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    /// Превью, статус, кнопки, предупреждения и живые метрики.
    @ViewBuilder
    private var liveBlock: some View {
        preview
        statusBar
        controls
        if model.thermalWarning {
            Label("Телефон перегревается — уберите от солнца или подключите охлаждение",
                  systemImage: "thermometer.sun.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .themedCard(padding: 12)
        }
        if let error = model.errorText {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .themedCard(padding: 12)
        }
        liveStats
    }

    private var ipEmptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "web.camera")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.moon)
            Text("Подключите IP-камеру")
                .font(.title3.bold())
                .foregroundStyle(Theme.moon)
            Text("Телефон и камера должны быть в одной сети (Wi-Fi магазина). Видео обрабатывается на телефоне.")
                .font(.subheadline)
                .foregroundStyle(Theme.moonDim)
                .multilineTextAlignment(.center)
            Button {
                showDiscovery = true
            } label: {
                Label("Найти камеры в сети", systemImage: "magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Theme.background)
                    .background(Theme.moon, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            Button {
                showIPSettings = true
            } label: {
                Label("Ввести адрес вручную", systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(Theme.moon)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .themedCard(padding: 20)
        .padding(.top, 20)
    }

    // MARK: Превью с разметкой

    private var previewAspect: CGFloat {
        guard isIP else { return 9.0 / 16.0 }
        if let s = model.ipSize, s.height > 0 { return s.width / s.height }
        return 16.0 / 9.0
    }

    private var preview: some View {
        ZStack {
            if isIP {
                RTSPPreview(view: model.ipView)
                if !model.ipConnected {
                    VStack(spacing: 10) {
                        if model.ipState.hasPrefix("Подключение") { ProgressView().tint(.white) }
                        Text(model.ipState)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
            } else {
                CameraPreview(session: model.engine.session)
            }
            LiveOverlay(snapshot: model.snapshot, markup: markup, showMarkupOnly: !model.isCounting,
                        fallbackSize: isIP ? (model.ipSize ?? CGSize(width: 1280, height: 720)) : CGSize(width: 720, height: 1280))
        }
        .aspectRatio(previewAspect, contentMode: .fit)
        .frame(maxHeight: 520)
        .frame(maxWidth: .infinity)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isCounting ? Color.red : Theme.moonDim)
                .frame(width: 8, height: 8)
            Text(model.isCounting ? "Идёт подсчёт · \(ResultView.formatTime(model.snapshot.elapsed))"
                 : (isIP ? (model.ipConnected ? model.ipState : "Нет видео") : "Камера готова"))
                .lineLimit(1)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.moon)
                .monospacedDigit()
            Spacer()
            if model.isCounting {
                Text(String(format: "%.0f кадр/с", model.snapshot.fps))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.moonDim)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                waitingForStill = true
                model.requestStill()
            } label: {
                Label("Разметка", systemImage: "viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Theme.moon)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isIP && !model.ipConnected)
            .opacity(isIP && !model.ipConnected ? 0.4 : 1)

            Button {
                if model.isCounting { model.stop() } else { model.start(markup: markup, direction: showcase) }
            } label: {
                Label(model.isCounting ? "Стоп" : "Старт", systemImage: model.isCounting ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(model.isCounting ? Color.white : Theme.background)
                    .background(model.isCounting ? Color.red.opacity(0.85) : Theme.moon,
                                in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isIP && !model.ipConnected && !model.isCounting)
            .opacity(isIP && !model.ipConnected && !model.isCounting ? 0.4 : 1)

            Button {
                showResetConfirm = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(width: 50, height: 50)
                    .foregroundStyle(Theme.moon)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!model.isCounting)
            .opacity(model.isCounting ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }

    // MARK: Живые метрики

    @ViewBuilder
    private var liveStats: some View {
        if model.isCounting || model.snapshot.seen > 0 {
            SummaryCards(counters: model.snapshot.counters, seen: model.snapshot.seen,
                         lineEnabled: model.snapshot.line.count == 2, zoneIsFullFrame: markup.isFullFrame)

            if let m = model.snapshot.extended {
                ScoreCard(score: ShowcaseScore.from(m, counters: model.snapshot.counters, people: model.snapshot.seen))
                MoneyCard(estimate: MoneyEstimate.compute(profile: AccountModel.shared.profile, people: model.snapshot.seen,
                                                          looked: model.snapshot.counters.looked, entered: m.entered,
                                                          duration: model.snapshot.elapsed),
                          profile: AccountModel.shared.profile)
                BehaviorList(m: m, speedScale: heatScale)
                FunnelView(m: m, slowed: model.snapshot.counters.slowed)
                FlowList(m: m)
                Button {
                    showHeatmap = true
                } label: {
                    Label("Тепловая карта", systemImage: "map.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Theme.moon)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.snapshot.samples.isEmpty)

                Button {
                    let elapsed = ResultView.formatTime(model.snapshot.elapsed)
                    if let url = HeatReport.make(source: liveHeatSource, range: nil, period: "сессия камеры, \(elapsed)",
                                                 scale: heatScale) {
                        reportFile = ShareFile(url: url)
                    }
                } label: {
                    Label("Скачать PDF-отчёт", systemImage: "doc.richtext")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Theme.moon)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)

                statsLink
            } else if model.isCounting {
                Text("Метрики поведения появятся через пару секунд…")
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Как пользоваться").font(.headline).foregroundStyle(Theme.moon)
                Text("1. Поставьте телефон на подставку в витрине, камерой на улицу.\n2. «Разметка» — отметьте зону, при желании линию подсчёта и вход.\n3. «Старт» — рамки и счётчики появятся сразу. Экран не гаснет, пока идёт подсчёт.\n4. Для долгой работы подключите зарядку.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.moonDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(padding: 16)

            statsLink
        }
    }

    private var statsLink: some View {
        NavigationLink {
            StatsView()
        } label: {
            Label("Статистика по часам и дням", systemImage: "chart.bar.xaxis")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(Theme.moon)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Листы

    private var editorSheet: some View {
        NavigationStack {
            MarkupEditorView(url: nil, markup: $markup, image: model.still,
                             startTitle: model.isCounting ? "Применить и начать заново" : "Применить",
                             startIcon: "checkmark") {
                if isIP { ipMarkupJSON = markup.json } else { markupJSON = markup.json }
                if model.isCounting { model.start(markup: markup, direction: showcase) }
                showEditor = false
            }
            .themedScreen()
            .navigationTitle("Разметка")
            .navigationBarTitleDisplayMode(.inline)
            .themedNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showEditor = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var heatmapSheet: some View {
        NavigationStack {
            HeatmapScreen(source: liveHeatSource)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { showHeatmap = false }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.requestStill() }   // свежий кадр — фон для режима «На кадре»
    }

    private var liveHeatSource: HeatSource {
        let s = model.snapshot
        return HeatSource(title: "Камера", samples: s.samples, width: s.frameWidth, height: s.frameHeight,
                          duration: s.elapsed, focalRatio: s.focalRatio, isLive: true, videoURL: nil,
                          backgroundTime: 0, still: model.still,
                          report: HeatReportData(counters: s.counters, seen: s.seen, extended: s.extended,
                                                 lineEnabled: s.line.count == 2, zoneIsFullFrame: markup.isFullFrame))
    }

    private var permissionView: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.moon)
            Text("Нужен доступ к камере")
                .font(.title3.bold())
                .foregroundStyle(Theme.moon)
            Text("Видео обрабатывается только на телефоне и никуда не отправляется.")
                .font(.subheadline)
                .foregroundStyle(Theme.moonDim)
                .multilineTextAlignment(.center)
            Button("Открыть настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.moon)
            .foregroundStyle(Theme.background)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Превью камеры

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
            c.videoRotationAngle = 90
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.setNeedsLayout()
    }
}

// MARK: - Разметка и рамки поверх превью

struct LiveOverlay: View {
    let snapshot: LiveSnapshot
    let markup: Markup
    /// До старта показываем только разметку (в долях кадра), рамок ещё нет.
    var showMarkupOnly = false
    /// Размер кадра, пока подсчёт не начат (снимка ещё нет).
    var fallbackSize = CGSize(width: 720, height: 1280)

    var body: some View {
        GeometryReader { geo in
            let w = snapshot.frameWidth > 0 ? snapshot.frameWidth : fallbackSize.width
            let h = snapshot.frameHeight > 0 ? snapshot.frameHeight : fallbackSize.height
            let rect = OverlayView.fitRect(videoWidth: w, videoHeight: h, in: geo.size)
            Canvas { ctx, _ in
                func map(_ p: Pt) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
                func path(_ pts: [Pt]) -> Path {
                    var p = Path()
                    if let f = pts.first {
                        p.move(to: map(f))
                        for q in pts.dropFirst() { p.addLine(to: map(q)) }
                    }
                    return p
                }

                // разметка в долях кадра (из текущих настроек)
                if !markup.isFullFrame {
                    var zone = path(markup.zone)
                    zone.closeSubpath()
                    ctx.fill(zone, with: .color(.cyan.opacity(0.10)))
                    ctx.stroke(zone, with: .color(.cyan.opacity(0.8)), lineWidth: 1.5)
                }
                if markup.lineEnabled, markup.line.count == 2 {
                    ctx.stroke(path(markup.line), with: .color(.red), lineWidth: 2.5)
                }
                if markup.entranceEnabled, markup.entrance.count == 2 {
                    ctx.stroke(path(markup.entrance), with: .color(.green), style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                }

                guard !showMarkupOnly else { return }
                let k = rect.width / w
                for b in snapshot.boxes {
                    let r = CGRect(x: rect.minX + b.box.x1 * k, y: rect.minY + b.box.y1 * k,
                                   width: b.box.width * k, height: b.box.height * k)
                    if !b.inZone && b.state == .tracked {
                        ctx.stroke(Path(r), with: .color(.gray.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        continue
                    }
                    ctx.stroke(Path(r), with: .color(b.state.color), lineWidth: 2)
                    var label = "#\(snapshot.numbers[b.trackId] ?? b.trackId)"
                    if b.lookingNow { label += " 👀" }
                    let text = ctx.resolve(Text(label).font(.caption2.bold()).foregroundColor(.black))
                    let ts = text.measure(in: CGSize(width: 200, height: 40))
                    let bg = CGRect(x: r.minX, y: max(rect.minY, r.minY - ts.height - 4), width: ts.width + 8, height: ts.height + 4)
                    ctx.fill(Path(roundedRect: bg, cornerRadius: 3), with: .color(b.state.color))
                    ctx.draw(text, at: CGPoint(x: bg.minX + 4, y: bg.minY + 2), anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
