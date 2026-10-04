//
//  Analytics.swift
//  mantis
//
//  Логика подсчёта: прошёл / притормозил / посмотрел. Порт python/mantis/analytics.py один в один.
//  Не зависит от нейросети и трекера — на вход идут уже отслеженные люди (track id + рамка + точки).
//

import Foundation

/// Человек в кадре после трекинга.
nonisolated struct TrackedPerson: Sendable {
    var trackId: Int
    var box: Box
    var keypoints: [Keypoint]?

    /// Точка ног — середина нижней стороны рамки.
    var foot: Pt { Pt((box.x1 + box.x2) / 2, box.y2) }
    var height: Double { max(1.0, box.y2 - box.y1) }
}

nonisolated enum EventKind: String, Codable, Sendable {
    case passed, slowed, looked

    var title: String {
        switch self {
        case .passed: return "прошёл"
        case .slowed: return "притормозил"
        case .looked: return "посмотрел"
        }
    }
}

nonisolated struct AnalyticsEvent: Codable, Identifiable, Sendable {
    var id: String { "\(trackId)-\(kind.rawValue)" }
    var t: Double
    var trackId: Int
    var kind: EventKind
    var direction: String
}

nonisolated struct Counters: Codable, Equatable, Sendable {
    var passed = 0
    var passedForward = 0
    var passedBackward = 0
    var slowed = 0
    var looked = 0

    var slowedRate: Double? { passed > 0 ? Double(slowed) / Double(passed) : nil }

    /// Счётчики по событиям в интервале (after; upTo]. after = nil — с начала видео.
    static func from(events: [AnalyticsEvent], after: Double?, upTo: Double) -> Counters {
        var c = Counters()
        for e in events where e.t <= upTo && (after.map { e.t > $0 } ?? true) {
            switch e.kind {
            case .passed:
                c.passed += 1
                if e.direction == "forward" { c.passedForward += 1 } else { c.passedBackward += 1 }
            case .slowed:
                c.slowed += 1
            case .looked:
                c.looked += 1
            }
        }
        return c
    }
    var lookedRate: Double? { passed > 0 ? Double(looked) / Double(passed) : nil }
}

nonisolated struct TrackSummary: Codable, Sendable {
    var trackId: Int
    var firstT: Double
    var lastT: Double
    var passed: Bool
    var direction: String
    var slowed: Bool
    var looked: Bool
    var zoneTime: Double
    var slowTime: Double
    var lookTime: Double
    var minSpeed: Double?
    /// Заходил ли человек в зону детекции хотя бы раз.
    var everInZone: Bool = true

    var duration: Double { lastT - firstT }
}

/// Состояние одного человека по ходу видео.
nonisolated final class TrackState {
    let trackId: Int
    var firstT: Double
    var lastT: Double
    var history: [(t: Double, x: Double, y: Double, h: Double)] = []
    var passed = false
    var direction: String?
    var zoneTime = 0.0
    var slowTime = 0.0
    var lookTime = 0.0
    var slowed = false
    var looked = false
    var speed: Double?
    var minSpeed: Double?
    var inZone = false {
        didSet { if inZone { everInZone = true } }
    }
    var everInZone = false
    var lookingNow = false
    var box: Box?

    static let historyLimit = 120

    init(trackId: Int, t: Double, box: Box) {
        self.trackId = trackId
        self.firstT = t
        self.lastT = t
        self.box = box
    }

    func appendHistory(_ item: (t: Double, x: Double, y: Double, h: Double)) {
        history.append(item)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    var summary: TrackSummary {
        TrackSummary(trackId: trackId, firstT: firstT, lastT: lastT, passed: passed, direction: direction ?? "",
                     slowed: slowed, looked: looked, zoneTime: zoneTime, slowTime: slowTime,
                     lookTime: lookTime, minSpeed: minSpeed, everInZone: everInZone)
    }
}

nonisolated final class Analytics {
    static let maxDt = 0.5  // секунды; больший разрыв между кадрами не учитываем в накоплении времени

    let cfg: AnalyticsConfig
    /// Линия подсчёта в пикселях; nil — линия выключена, «прошёл» не считается.
    let line: (a: Pt, b: Pt)?
    let zone: [Pt]
    private(set) var tracks: [Int: TrackState] = [:]
    private(set) var finished: [TrackSummary] = []
    private(set) var counters = Counters()
    private(set) var lastT = 0.0

    /// line и zone — уже в пикселях кадра. Пустая line или countLineEnabled = false — без линии.
    /// Фокусное расстояние в пикселях (для скорости по глубине); 0 — не учитывать движение к камере.
    let focal: Double
    /// Зона детекции — весь кадр (тогда правило «долго в зоне» не применяется).
    let zoneIsFull: Bool

    /// frameWidth/frameHeight — размер кадра: нужен для учёта движения к камере/от камеры.
    init(config: AnalyticsConfig, line: [Pt], zone: [Pt], frameWidth: Double? = nil, frameHeight: Double? = nil) {
        self.cfg = config
        self.line = (config.countLineEnabled && line.count == 2) ? (a: line[0], b: line[1]) : nil
        self.zone = zone
        if let w = frameWidth, let h = frameHeight {
            focal = config.slowdown.focalRatio * max(w, h)
            zoneIsFull = Geometry.polygonArea(zone) >= 0.98 * w * h
        } else {
            focal = 0
            zoneIsFull = false
        }
    }

    /// Сглаженная скорость в «ростах в секунду» за окно smoothingSeconds.
    private func speed(_ tr: TrackState) -> Double? {
        let win = cfg.slowdown.smoothingSeconds
        guard let last = tr.history.last else { return nil }
        let tNow = last.t
        let pts = tr.history.filter { tNow - $0.t <= win }
        guard pts.count >= 2, pts[pts.count - 1].t - pts[0].t >= win * 0.5 else { return nil }
        let p0 = pts[0], p1 = pts[pts.count - 1]
        let h = Self.median(pts.map { $0.h })
        let dist = ((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)).squareRoot()
        let lateral = dist / h / (p1.t - p0.t)
        guard focal > 0 else { return lateral }
        // Движение к камере/от камеры: человек почти не сдвигается, но растёт/уменьшается.
        // Скорость по глубине в «ростах в секунду» = (f/h) * |d ln h / dt|, наклон — по МНК за окно.
        let dwin = cfg.slowdown.depthWindowSeconds
        let dp = tr.history.filter { tNow - $0.t <= dwin }
        var depth = 0.0
        if dp.count >= 3 {
            let n = Double(dp.count)
            var sumT = 0.0, sumL = 0.0
            for p in dp { sumT += p.t }
            for p in dp { sumL += log(p.h) }
            let mt = sumT / n, ml = sumL / n
            var den = 0.0
            for p in dp { den += (p.t - mt) * (p.t - mt) }
            if den > 0 {
                var num = 0.0
                for p in dp { num += (p.t - mt) * (log(p.h) - ml) }
                depth = focal / h * abs(num / den)
            }
        }
        return pow(lateral * lateral + depth * depth, 0.5)
    }

    /// Медиана как в Python statistics.median (для чётного числа — среднее двух средних).
    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Обработать один кадр. t — время кадра в секундах. Возвращает новые события.
    @discardableResult
    func update(t: Double, people: [TrackedPerson]) -> [AnalyticsEvent] {
        lastT = t
        var events: [AnalyticsEvent] = []
        let sd = cfg.slowdown, lk = cfg.look

        for det in people {
            let foot = det.foot
            guard let tr = tracks[det.trackId] else {
                let fresh = TrackState(trackId: det.trackId, t: t, box: det.box)
                fresh.appendHistory((t: t, x: foot.x, y: foot.y, h: det.height))
                fresh.inZone = Geometry.pointInPolygon(foot, zone)
                tracks[det.trackId] = fresh
                continue
            }

            let dt = min(max(t - tr.lastT, 0.0), Self.maxDt)
            let prev = tr.history[tr.history.count - 1]
            tr.appendHistory((t: t, x: foot.x, y: foot.y, h: det.height))
            tr.lastT = t
            tr.box = det.box

            // 1. Прошёл: отрезок движения ног пересёк линию подсчёта
            if let ln = line, !tr.passed, Geometry.segmentsIntersect(Pt(prev.x, prev.y), foot, ln.a, ln.b) {
                tr.passed = true
                let side = Geometry.sideOfLine(foot, ln.a, ln.b)
                let dir = side > 0 ? "forward" : "backward"
                tr.direction = dir
                counters.passed += 1
                if dir == "forward" { counters.passedForward += 1 } else { counters.passedBackward += 1 }
                events.append(AnalyticsEvent(t: t, trackId: tr.trackId, kind: .passed, direction: dir))
            }

            // 2. Притормозил: медленно в зоне или долго в зоне
            tr.inZone = Geometry.pointInPolygon(foot, zone)
            tr.speed = speed(tr)
            if tr.inZone {
                tr.zoneTime += dt
                if let s = tr.speed {
                    tr.minSpeed = tr.minSpeed.map { min($0, s) } ?? s
                    if s < sd.speedThreshold {
                        tr.slowTime += dt
                    }
                }
                // «Долго в зоне» имеет смысл только для зоны у витрины, а не для всего кадра
                let dwellOK = !(zoneIsFull && sd.dwellOnlyWithZone)
                if !tr.slowed && (tr.slowTime >= sd.minSlowSeconds || (dwellOK && tr.zoneTime >= sd.dwellSeconds)) {
                    tr.slowed = true
                    counters.slowed += 1
                    events.append(AnalyticsEvent(t: t, trackId: tr.trackId, kind: .slowed, direction: ""))
                }
            }

            // 3. Посмотрел: голова повёрнута к витрине, пока человек в зоне
            let pose = HeadPoseEstimator.estimate(det.keypoints, minConf: lk.minKeypointConf)
            tr.lookingNow = tr.inZone && HeadPoseEstimator.isLooking(pose, direction: lk.showcaseDirection,
                                                                     maxYaw: lk.maxYaw, minSideYaw: lk.minSideYaw)
            if tr.lookingNow {
                tr.lookTime += dt
                if !tr.looked && tr.lookTime >= lk.minLookSeconds {
                    tr.looked = true
                    counters.looked += 1
                    events.append(AnalyticsEvent(t: t, trackId: tr.trackId, kind: .looked, direction: ""))
                }
            }
        }

        closeLost(t)
        return events
    }

    private func closeLost(_ t: Double) {
        let timeout = cfg.tracking.lostTimeoutSeconds
        let lost = tracks.filter { t - $0.value.lastT > timeout }.map { $0.key }.sorted()
        for tid in lost {
            if let tr = tracks.removeValue(forKey: tid) {
                finish(tr)
            }
        }
    }

    private func finish(_ tr: TrackState) {
        if tr.lastT - tr.firstT >= cfg.tracking.minTrackSeconds {
            finished.append(tr.summary)
        }
    }

    func closeAll() {
        for tid in tracks.keys.sorted() {
            if let tr = tracks[tid] { finish(tr) }
        }
        tracks.removeAll()
    }
}
