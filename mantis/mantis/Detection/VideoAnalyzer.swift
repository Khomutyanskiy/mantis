//
//  VideoAnalyzer.swift
//  mantis
//
//  Анализ видеофайла: кадры (с учётом поворота видео с телефона) → нейросеть → ByteTrack → подсчёт.
//  Результат хранит снимок по каждому проанализированному кадру — по нему потом рисуются рамки при просмотре.
//

import AVFoundation
import CoreImage
import Foundation

nonisolated enum PersonState: Sendable {
    case tracked, passed, slowed, looked
}

nonisolated struct OverlayBox: Sendable {
    var trackId: Int
    var box: Box
    var state: PersonState
    var lookingNow: Bool
    var speed: Double?
    var inZone: Bool = true
}

nonisolated struct AnalyzedFrame: Sendable {
    var time: Double
    var boxes: [OverlayBox]
    var counters: Counters
}

nonisolated struct AnalysisResult: Sendable {
    var videoURL: URL
    var width: Double
    var height: Double
    var duration: Double
    var analyzedFPS: Double
    var frames: [AnalyzedFrame]
    var events: [AnalyticsEvent]
    var counters: Counters
    var tracks: [TrackSummary]
    var line: [Pt]       // в пикселях кадра
    var zone: [Pt]       // в пикселях кадра
    var processingSeconds: Double
    /// Диагностика нейросети
    var rawDetections: Int = 0
    var maxScore: Double = 0
    var computeDescription: String = ""
    /// Линия входа в магазин, пиксели кадра (пусто — не задана).
    var entrance: [Pt] = []
    /// Дополнительные метрики по всему видео.
    var extended = ExtendedMetrics()
    /// Точки траекторий людей в зоне — для тепловых карт.
    var samples: [HeatSample] = []
    /// Фокусное (в долях длинной стороны кадра), с которым шёл анализ.
    var focalRatio: Double = 0.8
    /// Порядковые номера людей в зоне (trackId → 1, 2, 3…) по времени появления.
    /// Номера трекера идут с пропусками: их получают и люди вне зоны, и короткие ложные треки.
    var numbers: [Int: Int] = [:]

    /// Номер для показа: порядковый, если человек был в зоне, иначе номер трекера.
    func number(_ trackId: Int) -> Int { numbers[trackId] ?? trackId }

    static func numbering(_ tracks: [TrackSummary]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (i, t) in tracks.filter({ $0.everInZone }).sorted(by: { ($0.firstT, $0.trackId) < ($1.firstT, $1.trackId) }).enumerated() {
            out[t.trackId] = i + 1
        }
        return out
    }

    /// Зона детекции — весь кадр (прямоугольник по краям).
    var isFullFrameZone: Bool {
        zone.count == 4 && zone.allSatisfy { ($0.x == 0 || $0.x == width) && ($0.y == 0 || $0.y == height) }
    }

    /// Последний проанализированный кадр не позже time (бинарный поиск).
    func frame(at time: Double) -> AnalyzedFrame? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        if time < frames[0].time { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].time <= time + 1e-3 { lo = mid } else { hi = mid - 1 }
        }
        return frames[lo]
    }
}

nonisolated final class VideoAnalyzer {
    enum AnalyzerError: LocalizedError {
        case noVideoTrack
        case readerFailed(String)
        case noFrames

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "В файле нет видеодорожки"
            case .readerFailed(let s): return "Не удалось прочитать видео: \(s)"
            case .noFrames:
                return "Не удалось декодировать ни одного кадра. Возможно, формат видео не поддерживается iOS (например, H.264 10 бит). Перекодируйте в H.264 8 бит или HEVC."
            }
        }
    }

    let config: AnalyticsConfig
    /// Линия входа в доли кадра (nil — не считать вход).
    let entrance: [Pt]?
    /// Сколько кадров в секунду анализировать. Для подсчёта людей хватает 10–15.
    let targetFPS: Int

    init(config: AnalyticsConfig, entrance: [Pt]? = nil, targetFPS: Int = 15) {
        self.config = config
        self.entrance = entrance
        self.targetFPS = targetFPS
    }

    func analyze(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> AnalysisResult {
        let started = Date()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzerError.noVideoTrack
        }
        let loaded = try await asset.load(.duration).seconds
        let duration = loaded.isFinite ? loaded : 0

        // Видеокомпозиция сама применяет поворот (preferredTransform) и отдаёт кадры с нужной частотой
        let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        let size = composition.renderSize
        let W = Double(size.width), H = Double(size.height)

        let detector = try PoseDetector()
        let tracker = ByteTracker()
        let line = config.countLineEnabled ? Geometry.toPixels(config.countLine, width: W, height: H) : []
        let zone = Geometry.toPixels(config.showcaseZone, width: W, height: H)
        let analytics = Analytics(config: config, line: line, zone: zone, frameWidth: W, frameHeight: H)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalyzerError.readerFailed("canAdd = false") }
        reader.add(output)
        guard reader.startReading() else {
            throw AnalyzerError.readerFailed(reader.error?.localizedDescription ?? "startReading")
        }

        var frames: [AnalyzedFrame] = []
        var rawTotal = 0
        var maxScore = 0.0
        var events: [AnalyticsEvent] = []
        var trajectories: [Int: [TrackPoint]] = [:]
        var maxSimultaneous = 0
        frames.reserveCapacity(Int(duration * Double(targetFPS)) + 8)

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds

            let raw = try autoreleasepool {
                try detector.detect(CIImage(cvPixelBuffer: pixelBuffer))
            }
            rawTotal += raw.count
            maxScore = max(maxScore, detector.lastMaxScore)
            let tracked = tracker.update(raw, width: W, height: H)
            let people = tracked.map {
                TrackedPerson(trackId: $0.trackId, box: $0.box, keypoints: raw[$0.detIndex].keypoints)
            }
            events += analytics.update(t: t, people: people)
            frames.append(Self.snapshot(analytics, t: t))
            // траектории для дополнительных метрик
            var inZoneNow = 0
            for p in people {
                guard let tr = analytics.tracks[p.trackId] else { continue }
                trajectories[p.trackId, default: []].append(
                    TrackPoint(t: t, x: p.foot.x, y: p.foot.y, h: p.height, inZone: tr.inZone,
                               looking: tr.lookingNow, speed: tr.speed))
                if tr.inZone { inZoneNow += 1 }
            }
            maxSimultaneous = max(maxSimultaneous, inZoneNow)
            if duration > 0 { progress(min(1, t / duration)) }
        }
        if reader.status == .failed {
            throw AnalyzerError.readerFailed(reader.error?.localizedDescription ?? "status failed")
        }

        // Декодер iOS не смог прочитать видео (например, H.264 10 бит): кадров почти нет, хотя ролик длинный
        let expected = duration * Double(targetFPS)
        if frames.isEmpty || (expected >= 10 && Double(frames.count) < expected * 0.1) {
            throw AnalyzerError.noFrames
        }

        analytics.closeAll()
        let entrancePx = entrance.map { Geometry.toPixels($0, width: W, height: H) } ?? []
        let extended = MetricsCalculator.compute(
            trajectories: trajectories, summaries: analytics.finished, width: W, height: H, focal: analytics.focal,
            line: analytics.line, entrance: entrancePx.count == 2 ? (a: entrancePx[0], b: entrancePx[1]) : nil,
            maxSimultaneous: maxSimultaneous, fps: Double(targetFPS))
        progress(1)
        return AnalysisResult(videoURL: url, width: W, height: H, duration: duration, analyzedFPS: Double(targetFPS),
                              frames: frames, events: events, counters: analytics.counters,
                              tracks: analytics.finished, line: line, zone: zone,
                              processingSeconds: Date().timeIntervalSince(started),
                              rawDetections: rawTotal, maxScore: maxScore,
                              computeDescription: detector.computeDescription,
                              entrance: entrancePx, extended: extended,
                              samples: HeatBuilder.samples(from: trajectories),
                              focalRatio: config.slowdown.focalRatio,
                              numbers: AnalysisResult.numbering(analytics.finished))
    }

    /// Снимок того, что видно на кадре: рамки людей (только тех, кто есть в этом кадре) и счётчики.
    static func snapshot(_ a: Analytics, t: Double) -> AnalyzedFrame {
        var boxes: [OverlayBox] = []
        for tr in a.tracks.values where tr.lastT >= a.lastT {
            guard let box = tr.box else { continue }
            let state: PersonState = tr.looked ? .looked : (tr.slowed ? .slowed : (tr.passed ? .passed : .tracked))
            boxes.append(OverlayBox(trackId: tr.trackId, box: box, state: state, lookingNow: tr.lookingNow,
                                    speed: tr.speed, inZone: tr.inZone))
        }
        boxes.sort { $0.trackId < $1.trackId }
        return AnalyzedFrame(time: t, boxes: boxes, counters: a.counters)
    }
}
