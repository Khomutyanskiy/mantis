//
//  HeatData.swift
//  mantis
//
//  Данные для тепловых карт: точки траекторий людей (сэмплы), слои, сетки «вид сверху» и «на кадре»,
//  направления потока, подсказки, калибровка расстояний и снимки для сравнения «до/после».
//
//  Расстояния: человек ~1,7 м. По высоте рамки h и фокусному f (в пикселях):
//    расстояние до камеры Z = f · 1,7 / h,  сдвиг вбок X = (x − W/2) · 1,7 / h.
//  Калибровка по известной ширине уточняет масштаб (множитель scale).
//

import Foundation

// MARK: - Сэмплы

/// Точка траектории человека в зоне детекции (одна на проанализированный кадр).
nonisolated struct HeatSample: Sendable {
    var trackId: Int
    var t: Double
    var x: Double          // точка ног, пиксели кадра
    var y: Double
    var h: Double          // высота рамки, пиксели
    var dt: Double         // время, которое «весит» точка (до предыдущей точки этого человека), с
    var looking: Bool
    var speed: Double?     // ростов/с
    var stopped: Bool      // внутри остановки ≥ 2 с
}

nonisolated enum HeatLayer: String, CaseIterable, Identifiable, Sendable {
    case time, pass, slow, stops, looks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .time: return "Время"
        case .pass: return "Проход"
        case .slow: return "Медленно"
        case .stops: return "Стоп"
        case .looks: return "Взгляд"
        }
    }

    var subtitle: String {
        switch self {
        case .time: return "где люди проводили больше всего времени"
        case .pass: return "где шли — основной поток"
        case .slow: return "где сбавляли шаг"
        case .stops: return "где стояли 2 с и дольше"
        case .looks: return "где находились, когда смотрели на витрину"
        }
    }

    func includes(_ s: HeatSample) -> Bool {
        switch self {
        case .time: return true
        case .pass: return (s.speed ?? 0) > MetricsCalculator.movingSpeed && !s.stopped
        case .slow: return s.speed.map { $0 < 0.3 } ?? false
        case .stops: return s.stopped
        case .looks: return s.looking
        }
    }
}

/// Объектив, которым снято видео: от него зависит пересчёт в метры по глубине.
nonisolated enum Lens: String, CaseIterable, Identifiable, Sendable {
    case ultraWide, main, tele2, tele3, tele4, tele5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraWide: return "0,5×"
        case .main: return "1×"
        case .tele2: return "2×"
        case .tele3: return "3×"
        case .tele4: return "4×"
        case .tele5: return "5×"
        }
    }

    /// Фокусное расстояние в долях длинной стороны кадра (эквиваленты 13/24/48/77/100/120 мм).
    var focalRatio: Double {
        switch self {
        case .ultraWide: return 0.36
        case .main: return 0.67
        case .tele2: return 1.33
        case .tele3: return 2.14
        case .tele4: return 2.78
        case .tele5: return 3.33
        }
    }
}

/// Пересчёт пикселей кадра в метры на земле.
nonisolated struct GroundModel: Sendable {
    var width: Double
    var height: Double
    var focalRatio: Double
    var scale: Double = 1

    var focal: Double { focalRatio * max(width, height) }

    func ground(x: Double, h: Double) -> GroundPoint {
        let k = MetricsCalculator.personHeightM / max(h, 1) * scale
        return GroundPoint(x: (x - width / 2) * k, z: focal * k)
    }

    func ground(_ s: HeatSample) -> GroundPoint { ground(x: s.x, h: s.h) }
}

// MARK: - Сетки

nonisolated struct FlowVector: Sendable {
    var dx: Double
    var dz: Double
    var n: Int
}

nonisolated struct HeatCellInfo: Sendable {
    var seconds = 0.0
    var people = 0
    var lookers = 0
    var stoppers = 0
}

/// Сетка карты: в метрах (вид сверху) или в пикселях (на кадре).
nonisolated struct HeatGrid: Sendable {
    var cols: Int
    var rows: Int
    var cell: Double
    /// Левая граница (м или px).
    var left: Double
    /// Вид сверху: дальняя граница zMax (строка 0 — дальняя). На кадре: 0 (строка 0 — верх).
    var top: Double
    var isGround: Bool
    var values: [Double]
    var info: [HeatCellInfo]
    var flow: [FlowVector]
    var paths: [[GroundPoint]]

    var maxValue: Double { values.max() ?? 0 }
    var width: Double { Double(cols) * cell }
    var height: Double { Double(rows) * cell }

    /// Центр клетки в координатах сетки (м: x, z; px: x, y).
    func center(col: Int, row: Int) -> (Double, Double) {
        let cx = left + (Double(col) + 0.5) * cell
        let cy = isGround ? top - (Double(row) + 0.5) * cell : top + (Double(row) + 0.5) * cell
        return (cx, cy)
    }

    func cellIndex(x: Double, y: Double) -> Int? {
        let c = Int(((x - left) / cell).rounded(.down))
        let r = isGround ? Int(((top - y) / cell).rounded(.down)) : Int(((y - top) / cell).rounded(.down))
        guard c >= 0, c < cols, r >= 0, r < rows else { return nil }
        return r * cols + c
    }

    var hottest: Int? {
        guard let m = values.indices.max(by: { values[$0] < values[$1] }), values[m] > 0 else { return nil }
        return m
    }
}

nonisolated struct HeatHints: Sendable {
    var busiest: GroundPoint?
    var interest: GroundPoint?
    var lookDistance: (lo: Double, hi: Double)?
    var mainFlow: String?
    var lookers = 0
}

nonisolated enum HeatBuilder {
    /// Сэмплы из траекторий: только точки в зоне, с весом по времени и отметкой остановок.
    static func samples(from trajectories: [Int: [TrackPoint]]) -> [HeatSample] {
        var out: [HeatSample] = []
        for (id, v) in trajectories.sorted(by: { $0.key < $1.key }) {
            guard v.count >= 2 else { continue }
            // отметка остановок: непрерывно медленнее stopSpeed ≥ minStopSeconds
            var stopped = [Bool](repeating: false, count: v.count)
            var i = 0
            while i < v.count {
                guard let s = v[i].speed, s < MetricsCalculator.stopSpeed else { i += 1; continue }
                var j = i
                while j + 1 < v.count, let s2 = v[j + 1].speed, s2 < MetricsCalculator.stopSpeed { j += 1 }
                if v[j].t - v[i].t >= MetricsCalculator.minStopSeconds {
                    for k in i...j { stopped[k] = true }
                }
                i = j + 1
            }
            for k in v.indices where v[k].inZone {
                let dt = k > 0 ? min(max(v[k].t - v[k - 1].t, 0), Analytics.maxDt) : 0
                out.append(HeatSample(trackId: id, t: v[k].t, x: v[k].x, y: v[k].y, h: v[k].h, dt: dt,
                                      looking: v[k].looking, speed: v[k].speed, stopped: stopped[k]))
            }
        }
        return out
    }

    static func inRange(_ samples: [HeatSample], _ range: ClosedRange<Double>?) -> [HeatSample] {
        guard let range else { return samples }
        return samples.filter { range.contains($0.t) }
    }

    /// Фиксированная сетка для сравнения разных видео: 16 × 24 м, клетка 1 м.
    static let fixedGround = (halfWidth: 8.0, zMax: 24.0, cell: 1.0)

    /// Карта «вид сверху». fixed — общая сетка для сравнения.
    static func ground(_ all: [HeatSample], layer: HeatLayer, range: ClosedRange<Double>?, model: GroundModel,
                       fixed: (halfWidth: Double, zMax: Double, cell: Double)? = nil) -> HeatGrid? {
        let samples = inRange(all, range)
        guard !samples.isEmpty else { return nil }
        let pts = samples.map { model.ground($0) }

        var halfWidth: Double, zMax: Double, cell: Double
        if let f = fixed {
            (halfWidth, zMax, cell) = (f.halfWidth, f.zMax, f.cell)
        } else {
            let xs = pts.map { abs($0.x) }.sorted(), zs = pts.map { $0.z }.sorted()
            halfWidth = max(2.0, (xs[Int(Double(xs.count - 1) * 0.98)] * 1.1).rounded(.up))
            zMax = max(4.0, (zs[Int(Double(zs.count - 1) * 0.98)] * 1.1).rounded(.up))
            cell = 0.5
            while (2 * halfWidth / cell) > 40 || (zMax / cell) > 60 { cell *= 1.5 }
        }
        let cols = Int((2 * halfWidth / cell).rounded(.up)), rows = Int((zMax / cell).rounded(.up))
        var grid = HeatGrid(cols: cols, rows: rows, cell: cell, left: -halfWidth, top: zMax, isGround: true,
                            values: [Double](repeating: 0, count: cols * rows),
                            info: [HeatCellInfo](repeating: HeatCellInfo(), count: cols * rows),
                            flow: [FlowVector](repeating: FlowVector(dx: 0, dz: 0, n: 0), count: cols * rows),
                            paths: [])
        fill(&grid, samples: samples, coords: pts.map { ($0.x, $0.z) }, layer: layer)

        // направления и траектории
        var path: [GroundPoint] = []
        for i in samples.indices {
            let newTrack = i == 0 || samples[i].trackId != samples[i - 1].trackId
            if newTrack {
                if path.count >= 2 { grid.paths.append(path) }
                path = []
            } else {
                let dt = samples[i].t - samples[i - 1].t
                if dt > 0, dt <= Analytics.maxDt, let idx = grid.cellIndex(x: pts[i].x, y: pts[i].z) {
                    grid.flow[idx].dx += (pts[i].x - pts[i - 1].x) / dt
                    grid.flow[idx].dz += (pts[i].z - pts[i - 1].z) / dt
                    grid.flow[idx].n += 1
                }
            }
            if i % 2 == 0 { path.append(pts[i]) }
        }
        if path.count >= 2 { grid.paths.append(path) }
        return grid
    }

    /// Карта «на кадре» (в пикселях кадра), клетки ~1/20 ширины.
    static func frame(_ all: [HeatSample], layer: HeatLayer, range: ClosedRange<Double>?,
                      width W: Double, height H: Double, columns: Int = 20) -> HeatGrid? {
        let samples = inRange(all, range)
        guard !samples.isEmpty, W > 0, H > 0 else { return nil }
        let cell = W / Double(columns)
        let rows = Int((H / cell).rounded(.up))
        var grid = HeatGrid(cols: columns, rows: rows, cell: cell, left: 0, top: 0, isGround: false,
                            values: [Double](repeating: 0, count: columns * rows),
                            info: [HeatCellInfo](repeating: HeatCellInfo(), count: columns * rows),
                            flow: [], paths: [])
        fill(&grid, samples: samples, coords: samples.map { ($0.x, $0.y) }, layer: layer)
        return grid
    }

    private static func fill(_ grid: inout HeatGrid, samples: [HeatSample], coords: [(Double, Double)], layer: HeatLayer) {
        var people = [Set<Int>](repeating: [], count: grid.values.count)
        var lookers = [Set<Int>](repeating: [], count: grid.values.count)
        var stoppers = [Set<Int>](repeating: [], count: grid.values.count)
        for (i, s) in samples.enumerated() {
            guard let idx = grid.cellIndex(x: coords[i].0, y: coords[i].1) else { continue }
            grid.info[idx].seconds += s.dt
            people[idx].insert(s.trackId)
            if s.looking { lookers[idx].insert(s.trackId) }
            if s.stopped { stoppers[idx].insert(s.trackId) }
            if layer.includes(s) { grid.values[idx] += s.dt }
        }
        for i in grid.info.indices {
            grid.info[i].people = people[i].count
            grid.info[i].lookers = lookers[i].count
            grid.info[i].stoppers = stoppers[i].count
        }
    }

    /// Подсказки для карты.
    static func hints(_ all: [HeatSample], range: ClosedRange<Double>?, model: GroundModel) -> HeatHints {
        var h = HeatHints()
        let samples = inRange(all, range)
        guard !samples.isEmpty else { return h }

        if let g = ground(samples, layer: .time, range: nil, model: model), let i = g.hottest {
            let c = g.center(col: i % g.cols, row: i / g.cols)
            h.busiest = GroundPoint(x: c.0, z: c.1)
        }
        if let g = ground(samples, layer: .looks, range: nil, model: model), let i = g.hottest {
            let c = g.center(col: i % g.cols, row: i / g.cols)
            h.interest = GroundPoint(x: c.0, z: c.1)
        }
        let lookZ = samples.filter { $0.looking }.map { model.ground($0).z }.sorted()
        if lookZ.count >= 3 {
            h.lookDistance = (lookZ[lookZ.count / 4], lookZ[(lookZ.count * 3) / 4])
        }
        h.lookers = Set(samples.filter { $0.looking }.map { $0.trackId }).count

        // основной поток — по сумме единичных направлений движения
        var sx = 0.0, sz = 0.0
        for i in 1..<samples.count where samples[i].trackId == samples[i - 1].trackId {
            let a = model.ground(samples[i - 1]), b = model.ground(samples[i])
            let dx = b.x - a.x, dz = b.z - a.z
            let len = (dx * dx + dz * dz).squareRoot()
            if len > 0.05 {
                sx += dx / len
                sz += dz / len
            }
        }
        if abs(sx) > 1 || abs(sz) > 1 {
            if abs(sz) >= abs(sx) {
                h.mainFlow = sz < 0 ? "к камере" : "от камеры"
            } else {
                h.mainFlow = sx > 0 ? "слева направо" : "справа налево"
            }
        }
        return h
    }

    /// Калибровка: известная длина отрезка на земле (поперёк, на уровне ног людей) → множитель масштаба.
    /// Высота человека на этой строке кадра берётся из линейной зависимости h(y) по всем сэмплам.
    static func scale(referenceA a: Pt, referenceB b: Pt, meters: Double, samples: [HeatSample]) -> Double? {
        guard meters > 0, samples.count >= 10 else { return nil }
        let n = Double(samples.count)
        let my = samples.reduce(0) { $0 + $1.y } / n, mh = samples.reduce(0) { $0 + $1.h } / n
        var num = 0.0, den = 0.0
        for s in samples {
            num += (s.y - my) * (s.h - mh)
            den += (s.y - my) * (s.y - my)
        }
        let slope = den > 0 ? num / den : 0
        let hAt = mh + slope * ((a.y + b.y) / 2 - my)
        guard hAt > 5 else { return nil }
        let px = ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        let estimated = px * MetricsCalculator.personHeightM / hAt
        guard estimated > 0.01 else { return nil }
        return meters / estimated
    }
}

// MARK: - Снимки для сравнения «до / после»

nonisolated struct HeatComparison: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var date: Date
    var duration: Double
    var people: Int
    /// Секунды в клетке на минуту видео, фиксированная сетка HeatBuilder.fixedGround.
    var time: [Double]
    var looks: [Double]

    static func make(name: String, samples: [HeatSample], duration: Double, people: Int, model: GroundModel) -> HeatComparison? {
        let f = HeatBuilder.fixedGround
        guard duration > 0,
              let t = HeatBuilder.ground(samples, layer: .time, range: nil, model: model, fixed: f),
              let l = HeatBuilder.ground(samples, layer: .looks, range: nil, model: model, fixed: f) else { return nil }
        let perMin = 60 / duration
        return HeatComparison(name: name, date: Date(), duration: duration, people: people,
                              time: t.values.map { $0 * perMin }, looks: l.values.map { $0 * perMin })
    }

    func values(_ layer: HeatLayer) -> [Double] { layer == .looks ? looks : time }
}

/// Хранилище снимков сравнения (файл в Application Support).
nonisolated enum HeatStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("heat_comparisons.json")
    }

    static func load() -> [HeatComparison] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([HeatComparison].self, from: data) else { return [] }
        return items.sorted { $0.date > $1.date }
    }

    static func save(_ items: [HeatComparison]) {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }

    static func add(_ item: HeatComparison) {
        var all = load()
        all.insert(item, at: 0)
        save(Array(all.prefix(30)))
    }

    static func delete(_ id: UUID) {
        save(load().filter { $0.id != id })
    }
}
