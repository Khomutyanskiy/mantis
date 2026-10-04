//
//  ExtendedMetrics.swift
//  mantis
//
//  Дополнительная аналитика по траекториям людей (итог по всему видео):
//  средняя скорость, остановки, время взгляда, подошли ближе, оглянулись, вход, группы,
//  направления потока, одновременно в кадре и тепловая карта в проекции «вид сверху».
//
//  Расстояния оцениваются по росту человека (~1,7 м) и примерному фокусному камеры —
//  это оценка, а не измерение, но для сравнения витрин и мест её достаточно.
//

import Foundation

/// Точка траектории человека на одном проанализированном кадре.
nonisolated struct TrackPoint: Sendable {
    var t: Double
    var x: Double        // точка ног, пиксели
    var y: Double
    var h: Double        // высота рамки, пиксели
    var inZone: Bool
    var looking: Bool
    var speed: Double?   // «ростов в секунду», как в Analytics
}

/// Точка на земле в метрах: x — вправо от оси камеры, z — расстояние от камеры.
nonisolated struct GroundPoint: Sendable {
    var x: Double
    var z: Double
}

nonisolated struct Heatmap: Sendable {
    var cell: Double          // размер клетки, м
    var cols: Int
    var rows: Int
    var xMin: Double          // левая граница, м
    var zMax: Double          // дальняя граница, м
    var seconds: [Double]     // время в клетке, rows × cols, строка 0 — самая дальняя
    var paths: [[GroundPoint]]
    var maxSeconds: Double { seconds.max() ?? 0 }
}

nonisolated struct ExtendedMetrics: Sendable {
    var people = 0
    /// Средняя скорость идущих, м/с.
    var avgSpeed: Double?
    var stopped = 0
    var avgStopSeconds: Double?
    var lookers = 0
    var avgLookSeconds: Double?
    var medianLookSeconds: Double?
    var totalLookSeconds = 0.0
    var approached = 0
    var lookedBack = 0
    /// nil — линия входа не задана.
    var entered: Int?
    var singles = 0
    var groups = 0
    var peopleInGroups = 0
    var towardCamera = 0
    var awayFromCamera = 0
    var leftToRight = 0
    var rightToLeft = 0
    var maxSimultaneous = 0
    var heatmap: Heatmap?
    /// Моменты событий для графика: вошёл, остановился (на 2-й секунде стояния), подошёл ближе.
    var enterTimes: [Double] = []
    var stopTimes: [Double] = []
    var approachTimes: [Double] = []
}

nonisolated enum MetricsCalculator {
    static let personHeightM = 1.7
    /// Порог «идёт» для средней скорости и «стоит» для остановки, в ростах/с.
    static let movingSpeed = 0.15
    static let stopSpeed = 0.12
    static let minStopSeconds = 2.0
    /// «Подошёл ближе»: рамка выросла в 1,3 раза и заняла ≥ 35% высоты кадра.
    static let nearFraction = 0.35
    static let approachGrowth = 1.3
    static let minLookBackSeconds = 0.4

    static func compute(trajectories: [Int: [TrackPoint]], summaries: [TrackSummary],
                        width W: Double, height H: Double, focal: Double,
                        line: (a: Pt, b: Pt)?, entrance: (a: Pt, b: Pt)?,
                        maxSimultaneous: Int, fps: Double) -> ExtendedMetrics {
        var m = ExtendedMetrics()
        m.maxSimultaneous = maxSimultaneous

        // Учитываем людей, которые были в зоне и продержались в кадре ≥ 0,5 с
        let tracks = trajectories.filter { _, v in
            v.count >= 3 && v[v.count - 1].t - v[0].t >= 0.5 && v.contains { $0.inZone }
        }
        m.people = tracks.count
        if entrance != nil { m.entered = 0 }

        var speeds: [Double] = []
        var stopDurations: [Double] = []

        for (_, v) in tracks.sorted(by: { $0.key < $1.key }) {
            // Средняя скорость: медиана скорости, пока человек идёт
            let moving = v.compactMap { $0.speed }.filter { $0 > movingSpeed }
            if moving.count >= 3 { speeds.append(Analytics.median(moving) * personHeightM) }

            // Остановка: непрерывно почти без движения ≥ 2 с
            var runStart: Double?
            var bestRun = 0.0
            var stopAt: Double?
            for p in v {
                if let s = p.speed, s < stopSpeed {
                    if runStart == nil { runStart = p.t }
                    bestRun = max(bestRun, p.t - (runStart ?? p.t))
                    if stopAt == nil, bestRun >= minStopSeconds { stopAt = p.t }
                } else {
                    runStart = nil
                }
            }
            if bestRun >= minStopSeconds {
                m.stopped += 1
                stopDurations.append(bestRun)
                if let stopAt { m.stopTimes.append(stopAt) }
            }

            // Подошёл ближе: самая крупная рамка
            var peak = 0
            for i in v.indices where v[i].h > v[peak].h { peak = i }
            let peakH = v[peak].h
            if peakH / H >= nearFraction && peakH >= approachGrowth * v[0].h {
                m.approached += 1
                m.approachTimes.append(v[peak].t)
            }

            // Пересечения линий
            var passT: Double?
            var didEnter = false
            var enterT: Double?
            for i in 1..<v.count {
                let p0 = Pt(v[i - 1].x, v[i - 1].y), p1 = Pt(v[i].x, v[i].y)
                if passT == nil, let ln = line, Geometry.segmentsIntersect(p0, p1, ln.a, ln.b) { passT = v[i].t }
                if !didEnter, let en = entrance, Geometry.segmentsIntersect(p0, p1, en.a, en.b) {
                    didEnter = true
                    enterT = v[i].t
                }
            }
            if didEnter { m.entered = (m.entered ?? 0) + 1 }
            if let enterT { m.enterTimes.append(enterT) }

            // Оглянулся: смотрел в сторону витрины уже после прохода —
            // после пересечения линии или когда уже удаляется (рамка меньше пика на 10%)
            var back = 0.0
            for i in 1..<v.count where v[i].looking {
                let afterLine = passT.map { v[i].t > $0 } ?? false
                let movingAway = i > peak && v[i].h <= 0.9 * peakH
                if afterLine || movingAway { back += min(v[i].t - v[i - 1].t, Analytics.maxDt) }
            }
            if back >= minLookBackSeconds { m.lookedBack += 1 }

            // Направления
            let mh = Analytics.median(v.map { $0.h })
            let dx = (v[v.count - 1].x - v[0].x) / mh
            if dx > 0.8 { m.leftToRight += 1 } else if dx < -0.8 { m.rightToLeft += 1 }
            let ratio = v[v.count - 1].h / v[0].h
            if ratio > 1.25 { m.towardCamera += 1 } else if ratio < 0.8 { m.awayFromCamera += 1 }
        }

        if !speeds.isEmpty { m.avgSpeed = speeds.reduce(0, +) / Double(speeds.count) }
        if !stopDurations.isEmpty { m.avgStopSeconds = stopDurations.reduce(0, +) / Double(stopDurations.count) }

        // Время взгляда — из итогов подсчёта (то же, что даёт «Посмотрели»)
        let ids = Set(tracks.keys)
        let looks = summaries.filter { $0.looked && ids.contains($0.trackId) }.map { $0.lookTime }
        m.lookers = looks.count
        m.totalLookSeconds = looks.reduce(0, +)
        if !looks.isEmpty {
            m.avgLookSeconds = m.totalLookSeconds / Double(looks.count)
            m.medianLookSeconds = Analytics.median(looks)
        }

        // Группы: идут рядом (≤ 1,2 роста, на одной глубине) ≥ 70% общего времени, общее время ≥ 2 с
        let keys = tracks.keys.sorted()
        var parent = Dictionary(uniqueKeysWithValues: keys.map { ($0, $0) })
        func find(_ k: Int) -> Int {
            var k = k
            while let p = parent[k], p != k { k = p }
            return k
        }
        let byTime = tracks.mapValues { v in Dictionary(v.map { (Int(($0.t * 1000).rounded()), $0) }, uniquingKeysWith: { a, _ in a }) }
        for i in 0..<keys.count {
            for j in (i + 1)..<max(i + 1, keys.count) {
                guard let A = byTime[keys[i]], let B = byTime[keys[j]] else { continue }
                let common = Set(A.keys).intersection(B.keys)
                guard Double(common.count) >= 2 * fps else { continue }
                var close = 0
                for t in common {
                    guard let pa = A[t], let pb = B[t] else { continue }
                    let mh = (pa.h + pb.h) / 2
                    let d = ((pa.x - pb.x) * (pa.x - pb.x) + (pa.y - pb.y) * (pa.y - pb.y)).squareRoot() / mh
                    let r = pa.h / pb.h
                    if d < 1.2 && r > 0.75 && r < 1.33 { close += 1 }
                }
                if Double(close) / Double(common.count) >= 0.7 {
                    let ra = find(keys[i]), rb = find(keys[j])
                    if ra != rb { parent[ra] = rb }
                }
            }
        }
        var components: [Int: Int] = [:]
        for k in keys { components[find(k), default: 0] += 1 }
        for (_, size) in components {
            if size >= 2 {
                m.groups += 1
                m.peopleInGroups += size
            } else {
                m.singles += 1
            }
        }

        m.heatmap = heatmap(tracks: tracks, width: W, focal: focal)
        return m
    }

    /// Проекция точки ног на землю: расстояние по росту человека, сдвиг — по положению в кадре.
    static func ground(_ p: TrackPoint, width W: Double, focal f: Double) -> GroundPoint {
        let z = f * personHeightM / max(p.h, 1)
        let x = (p.x - W / 2) * z / f
        return GroundPoint(x: x, z: z)
    }

    static func heatmap(tracks: [Int: [TrackPoint]], width W: Double, focal f: Double) -> Heatmap? {
        guard f > 0 else { return nil }
        var pts: [(GroundPoint, Double)] = []   // точка и время, которое она «весит»
        var paths: [[GroundPoint]] = []
        for (_, v) in tracks.sorted(by: { $0.key < $1.key }) {
            var path: [GroundPoint] = []
            for i in v.indices where v[i].inZone {
                let g = ground(v[i], width: W, focal: f)
                let dt = i > 0 ? min(v[i].t - v[i - 1].t, Analytics.maxDt) : 0
                pts.append((g, dt))
                if i % 2 == 0 { path.append(g) }
            }
            if path.count >= 2 { paths.append(path) }
        }
        guard !pts.isEmpty else { return nil }

        // Границы по 98-му перцентилю, чтобы редкие выбросы не растягивали карту
        let xs = pts.map { abs($0.0.x) }.sorted(), zs = pts.map { $0.0.z }.sorted()
        let xr = max(2.0, (xs[Int(Double(xs.count - 1) * 0.98)] * 1.1).rounded(.up))
        let zMax = max(4.0, (zs[Int(Double(zs.count - 1) * 0.98)] * 1.1).rounded(.up))
        var cell = 0.5
        while (2 * xr / cell) > 40 || (zMax / cell) > 60 { cell *= 1.5 }
        let cols = Int((2 * xr / cell).rounded(.up)), rows = Int((zMax / cell).rounded(.up))
        var seconds = [Double](repeating: 0, count: cols * rows)
        for (g, dt) in pts {
            let c = Int(((g.x + xr) / cell).rounded(.down))
            let r = Int(((zMax - g.z) / cell).rounded(.down))
            guard c >= 0, c < cols, r >= 0, r < rows else { continue }
            seconds[r * cols + c] += dt
        }
        return Heatmap(cell: cell, cols: cols, rows: rows, xMin: -xr, zMax: zMax, seconds: seconds, paths: paths)
    }
}
