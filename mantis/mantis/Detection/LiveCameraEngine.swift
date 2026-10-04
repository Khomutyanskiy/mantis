//
//  LiveCameraEngine.swift
//  mantis
//
//  Живой режим: кадры с камеры телефона → YOLO-pose → ByteTrack → подсчёт → снимки для экрана.
//  Всё считается на устройстве, кадры никуда не сохраняются и не отправляются.
//
//  Потоки:
//    • sessionQueue — запуск/остановка AVCaptureSession (startRunning блокирует);
//    • processQueue — обработка кадров; здесь живут детектор, трекер и подсчёт.
//      Если обработка не успевает, лишние кадры камера отбрасывает сама (alwaysDiscardsLateVideoFrames).
//

import AVFoundation
import CoreImage
import Foundation

/// Что показывать на экране после очередного кадра.
nonisolated struct LiveSnapshot: Sendable {
    var boxes: [OverlayBox] = []
    var counters = Counters()
    var seen = 0
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    var line: [Pt] = []
    var zone: [Pt] = []
    var entrance: [Pt] = []
    var fps: Double = 0
    var elapsed: Double = 0
    var extended: ExtendedMetrics?
    var events: [AnalyticsEvent] = []
    /// Точки траекторий для тепловых карт (обновляются раз в 2 с).
    var samples: [HeatSample] = []
    var focalRatio: Double = Lens.main.focalRatio
    /// Порядковые номера людей в зоне (trackId → 1, 2, 3…).
    var numbers: [Int: Int] = [:]
}

nonisolated final class LiveCameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum EngineError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "Камера недоступна (в симуляторе камеры нет — запустите на iPhone)"
            case .cannotAddInput: return "Не удалось подключить камеру"
            case .cannotAddOutput: return "Не удалось получить кадры с камеры"
            }
        }
    }

    let session = AVCaptureSession()
    /// Сколько кадров в секунду обрабатывать (остальные пропускаются).
    var targetFPS: Double = 15
    /// Колбэк с новым снимком — вызывается на processQueue.
    var onSnapshot: (@Sendable (LiveSnapshot) -> Void)?
    /// Колбэк с кадром для разметки — вызывается на processQueue.
    var onStill: (@Sendable (CGImage) -> Void)?
    /// Колбэк с ошибкой обработки — вызывается на processQueue.
    var onError: (@Sendable (String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "mantis.camera.session")
    private let processQueue = DispatchQueue(label: "mantis.camera.process", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var configured = false

    // Состояние обработки — только на processQueue
    private var detector: PoseDetector?
    private var tracker = ByteTracker()
    private var analytics: Analytics?
    private var config = AnalyticsConfig()
    private var entranceNorm: [Pt]?
    private var frameSize: (w: Double, h: Double) = (0, 0)
    private var startTime: Double?
    private var lastProcessed = -1.0
    private var fps = 0.0
    private var lastTick: Double?
    private var trajectories: [Int: [TrackPoint]] = [:]
    private var seenIDs = Set<Int>()
    private var numbers: [Int: Int] = [:]
    private var maxSimultaneous = 0
    private var events: [AnalyticsEvent] = []
    private var extended: ExtendedMetrics?
    private var heatSamples: [HeatSample] = []
    private var lastMetricsAt = -10.0
    private var stillRequested = false
    private var running = false

    // MARK: - Управление (с главного потока)

    /// Настроить камеру. Бросает ошибку, если камеры нет.
    func configure() throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw EngineError.noCamera
        }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw EngineError.cannotAddInput
        }
        session.addInput(input)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: processQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw EngineError.cannotAddOutput
        }
        session.addOutput(output)
        // Кадры сразу в портретной ориентации — как держат телефон в витрине
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
        session.commitConfiguration()
        configured = true
    }

    /// Показывать картинку с камеры (без подсчёта).
    func startPreview() {
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stopPreview() {
        processQueue.async { self.running = false }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Начать подсчёт с нуля с заданной разметкой.
    func startCounting(config: AnalyticsConfig, entrance: [Pt]?, usePhoneCamera: Bool = true) {
        processQueue.async {
            self.config = config
            self.entranceNorm = entrance
            self.resetState()
            self.running = true
        }
        if usePhoneCamera { startPreview() }
    }

    /// Остановить обработку (без камеры телефона) — при переключении источника.
    func stopProcessing() {
        processQueue.async { self.running = false }
    }

    /// Остановить подсчёт (картинка с камеры остаётся). Итоговые метрики пересчитываются.
    func stopCounting() {
        processQueue.async {
            self.running = false
            self.extended = self.computeExtended()
            self.heatSamples = HeatBuilder.samples(from: self.trajectories)
            self.publish(boxes: [])
        }
    }

    /// Обнулить счётчики, не останавливая подсчёт.
    func reset() {
        processQueue.async {
            self.resetState()
            self.publish(boxes: [])
        }
    }

    /// Получить текущий кадр (для рисования разметки).
    func requestStill() {
        processQueue.async { self.stillRequested = true }
    }

    // MARK: - Обработка кадров (processQueue)

    private func resetState() {
        tracker = ByteTracker()
        analytics = nil           // пересоздаётся на ближайшем кадре под его размер
        trajectories = [:]
        seenIDs = []
        numbers = [:]
        maxSimultaneous = 0
        events = []
        extended = nil
        heatSamples = []
        startTime = nil
        lastProcessed = -1
        lastMetricsAt = -10
        fps = 0
        lastTick = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handle(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }

    // MARK: - Внешний источник (IP-камера)

    private let feedLock = NSLock()
    private var feedBusy = false

    /// Кадр с IP-камеры. Если предыдущий ещё обрабатывается — кадр пропускается (как alwaysDiscardsLateVideoFrames).
    func feed(_ frame: FrameBox, time: Double) {
        feedLock.lock()
        if feedBusy {
            feedLock.unlock()
            return
        }
        feedBusy = true
        feedLock.unlock()
        processQueue.async {
            self.handle(frame.buffer, pts: time)
            self.feedLock.lock()
            self.feedBusy = false
            self.feedLock.unlock()
        }
    }

    /// Обработка кадра (processQueue): кадр для разметки, детекция, трекинг, подсчёт.
    private func handle(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        if stillRequested {
            stillRequested = false
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) { onStill?(cg) }
        }
        guard running else { return }

        if startTime == nil { startTime = pts }
        let t = pts - (startTime ?? pts)
        guard t - lastProcessed >= 1.0 / targetFPS - 0.002 else { return }
        lastProcessed = t

        let W = Double(CVPixelBufferGetWidth(pixelBuffer)), H = Double(CVPixelBufferGetHeight(pixelBuffer))
        if analytics == nil || frameSize.w != W || frameSize.h != H {
            frameSize = (W, H)
            let line = config.countLineEnabled ? Geometry.toPixels(config.countLine, width: W, height: H) : []
            let zone = Geometry.toPixels(config.showcaseZone, width: W, height: H)
            analytics = Analytics(config: config, line: line, zone: zone, frameWidth: W, frameHeight: H)
            tracker = ByteTracker()
        }
        guard let analytics else { return }

        do {
            if detector == nil { detector = try PoseDetector() }
            guard let detector else { return }
            let raw = try autoreleasepool { try detector.detect(CIImage(cvPixelBuffer: pixelBuffer)) }
            let tracked = tracker.update(raw, width: W, height: H)
            let people = tracked.map {
                TrackedPerson(trackId: $0.trackId, box: $0.box, keypoints: raw[$0.detIndex].keypoints)
            }
            events += analytics.update(t: t, people: people)

            var inZoneNow = 0
            for p in people {
                guard let tr = analytics.tracks[p.trackId] else { continue }
                trajectories[p.trackId, default: []].append(
                    TrackPoint(t: t, x: p.foot.x, y: p.foot.y, h: p.height, inZone: tr.inZone,
                               looking: tr.lookingNow, speed: tr.speed))
                if tr.inZone {
                    inZoneNow += 1
                    if seenIDs.insert(p.trackId).inserted { numbers[p.trackId] = seenIDs.count }
                }
            }
            maxSimultaneous = max(maxSimultaneous, inZoneNow)
            pruneOldTrajectories(now: t)

            let now = Date().timeIntervalSince1970
            if let last = lastTick, now > last {
                let inst = 1 / (now - last)
                fps = fps == 0 ? inst : 0.9 * fps + 0.1 * inst
            }
            lastTick = now

            // Поведенческие метрики пересчитываем раз в 2 секунды — это дороже подсчёта
            if t - lastMetricsAt >= 2 {
                lastMetricsAt = t
                extended = computeExtended()
                heatSamples = HeatBuilder.samples(from: trajectories)
            }
            publish(boxes: VideoAnalyzer.snapshot(analytics, t: t).boxes)
        } catch {
            // Без детектора подсчёт невозможен — останавливаемся и сообщаем экрану
            running = false
            publish(boxes: [])
            onError?(error.localizedDescription)
        }
    }

    /// Долгие сессии: траектории старше 20 минут больше не нужны для метрик «по сути момента».
    private func pruneOldTrajectories(now: Double) {
        guard trajectories.count > 400 else { return }
        trajectories = trajectories.filter { _, v in (v.last?.t ?? 0) > now - 20 * 60 }
    }

    private func computeExtended() -> ExtendedMetrics? {
        guard let analytics else { return nil }
        let summaries = analytics.finished + analytics.tracks.values.map { $0.summary }
        let entrancePx = entranceNorm.map { Geometry.toPixels($0, width: frameSize.w, height: frameSize.h) } ?? []
        return MetricsCalculator.compute(
            trajectories: trajectories, summaries: summaries, width: frameSize.w, height: frameSize.h,
            focal: analytics.focal, line: analytics.line,
            entrance: entrancePx.count == 2 ? (a: entrancePx[0], b: entrancePx[1]) : nil,
            maxSimultaneous: maxSimultaneous, fps: targetFPS)
    }

    private func publish(boxes: [OverlayBox]) {
        let W = frameSize.w, H = frameSize.h
        var s = LiveSnapshot()
        s.boxes = boxes
        s.counters = analytics?.counters ?? Counters()
        s.seen = seenIDs.count
        s.frameWidth = W
        s.frameHeight = H
        s.line = config.countLineEnabled ? Geometry.toPixels(config.countLine, width: W, height: H) : []
        s.zone = Geometry.toPixels(config.showcaseZone, width: W, height: H)
        s.entrance = entranceNorm.map { Geometry.toPixels($0, width: W, height: H) } ?? []
        s.fps = fps
        s.elapsed = lastProcessed > 0 ? lastProcessed : 0
        s.extended = extended
        s.events = events
        s.samples = heatSamples
        s.numbers = numbers
        s.focalRatio = config.slowdown.focalRatio
        onSnapshot?(s)
    }
}
