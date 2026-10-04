//
//  ByteTracker.swift
//  mantis
//
//  Трекер ByteTrack: присваивает людям устойчивые ID между кадрами.
//  Порт ultralytics BYTETracker с параметрами bytetrack.yaml, чтобы ID и счётчики совпадали с Python.
//

import Foundation

/// Сырая детекция нейросети (после NMS), в пикселях кадра.
nonisolated struct RawDetection: Sendable {
    var box: Box
    var score: Double
    var keypoints: [Keypoint]
}

nonisolated struct ByteTrackConfig: Sendable {
    var trackHighThresh = 0.25
    var trackLowThresh = 0.1
    var newTrackThresh = 0.25
    var trackBuffer = 30
    var matchThresh = 0.8
    var fuseScore = true
    /// ultralytics всегда передаёт frame_rate = 30, поэтому max_time_lost = trackBuffer кадров.
    var frameRate = 30.0
}

nonisolated final class STrack {
    enum State { case new, tracked, lost, removed }

    var trackId = 0
    var isActivated = false
    var state: State = .new
    var mean: [Double]?
    var cov: Matrix?
    var detTLWH: [Double]
    var score: Double
    var detIndex: Int
    var frameId = 0
    var startFrame = 0
    var trackletLen = 0

    var endFrame: Int { frameId }

    init(det: RawDetection, index: Int) {
        detTLWH = [det.box.x1, det.box.y1, det.box.x2 - det.box.x1, det.box.y2 - det.box.y1]
        score = det.score
        detIndex = index
    }

    /// Текущая рамка (top-left, w, h): из состояния фильтра, если оно есть.
    var tlwh: [Double] {
        guard let m = mean else { return detTLWH }
        let w = m[2] * m[3]
        return [m[0] - w / 2, m[1] - m[3] / 2, w, m[3]]
    }

    var xyxy: Box {
        let r = tlwh
        return Box(x1: r[0], y1: r[1], x2: r[0] + r[2], y2: r[1] + r[3])
    }

    static func xyah(_ tlwh: [Double]) -> [Double] {
        [tlwh[0] + tlwh[2] / 2, tlwh[1] + tlwh[3] / 2, tlwh[2] / tlwh[3], tlwh[3]]
    }

    func activate(kf: KalmanFilterXYAH, frameId: Int, newId: Int) {
        trackId = newId
        let (m, c) = kf.initiate(Self.xyah(detTLWH))
        mean = m
        cov = c
        trackletLen = 0
        state = .tracked
        if frameId == 1 { isActivated = true }
        self.frameId = frameId
        startFrame = frameId
    }

    func reActivate(_ det: STrack, kf: KalmanFilterXYAH, frameId: Int) {
        let (m, c) = kf.update(mean: mean!, cov: cov!, measurement: Self.xyah(det.tlwh))
        mean = m
        cov = c
        trackletLen = 0
        state = .tracked
        isActivated = true
        self.frameId = frameId
        score = det.score
        detIndex = det.detIndex
    }

    func update(_ det: STrack, kf: KalmanFilterXYAH, frameId: Int) {
        self.frameId = frameId
        trackletLen += 1
        let (m, c) = kf.update(mean: mean!, cov: cov!, measurement: Self.xyah(det.tlwh))
        mean = m
        cov = c
        state = .tracked
        isActivated = true
        score = det.score
        detIndex = det.detIndex
    }
}

/// Результат трекинга для одного человека в кадре.
nonisolated struct TrackOutput: Sendable {
    var trackId: Int
    var box: Box          // рамка из фильтра Калмана (как отдаёт ultralytics)
    var detIndex: Int     // индекс исходной детекции — оттуда берутся ключевые точки
}

nonisolated final class ByteTracker {
    let cfg: ByteTrackConfig
    private let kf = KalmanFilterXYAH()
    private var tracked: [STrack] = []
    private var lost: [STrack] = []
    private var removed: [STrack] = []
    private var frameId = 0
    private var nextId = 0
    private let maxTimeLost: Int

    init(config: ByteTrackConfig = ByteTrackConfig()) {
        cfg = config
        maxTimeLost = Int(config.frameRate / 30.0 * Double(config.trackBuffer))
    }

    private func newId() -> Int {
        nextId += 1
        return nextId
    }

    /// width/height — размер кадра: итоговые рамки обрезаются по кадру (как Results.update в ultralytics).
    func update(_ detections: [RawDetection], width: Double, height: Double) -> [TrackOutput] {
        frameId += 1
        var activated: [STrack] = []
        var refind: [STrack] = []
        var lostNow: [STrack] = []
        var removedNow: [STrack] = []

        var high: [STrack] = []
        var second: [STrack] = []
        for (i, d) in detections.enumerated() {
            if d.score >= cfg.trackHighThresh {
                high.append(STrack(det: d, index: i))
            } else if d.score > cfg.trackLowThresh {
                second.append(STrack(det: d, index: i))
            }
        }

        let unconfirmed = tracked.filter { !$0.isActivated }
        let trackedConfirmed = tracked.filter { $0.isActivated }

        // Шаг 2: первое сопоставление — уверенные детекции с активными и потерянными треками
        let pool = Self.joint(trackedConfirmed, lost)
        for t in pool {
            guard var m = t.mean, let c = t.cov else { continue }
            if t.state != .tracked { m[7] = 0 }
            let (pm, pc) = kf.predict(mean: m, cov: c)
            t.mean = pm
            t.cov = pc
        }
        var dists = Self.iouDistance(pool, high)
        if cfg.fuseScore { dists = Self.fuseScore(dists, high) }
        let (matches, uTrack, uDetection) = LinearAssignment.solve(dists, rows: pool.count, cols: high.count,
                                                                   thresh: cfg.matchThresh)
        for (it, id) in matches {
            let track = pool[it], det = high[id]
            if track.state == .tracked {
                track.update(det, kf: kf, frameId: frameId)
                activated.append(track)
            } else {
                track.reActivate(det, kf: kf, frameId: frameId)
                refind.append(track)
            }
        }

        // Шаг 3: второе сопоставление — слабые детекции с оставшимися активными треками
        let rTracked = uTrack.map { pool[$0] }.filter { $0.state == .tracked }
        let dists2 = Self.iouDistance(rTracked, second)
        let (matches2, uTrack2, _) = LinearAssignment.solve(dists2, rows: rTracked.count, cols: second.count,
                                                            thresh: 0.5)
        for (it, id) in matches2 {
            let track = rTracked[it], det = second[id]
            if track.state == .tracked {
                track.update(det, kf: kf, frameId: frameId)
                activated.append(track)
            } else {
                track.reActivate(det, kf: kf, frameId: frameId)
                refind.append(track)
            }
        }
        for it in uTrack2 {
            let track = rTracked[it]
            if track.state != .lost {
                track.state = .lost
                lostNow.append(track)
            }
        }

        // Неподтверждённые треки (появились на прошлом кадре)
        let rest = uDetection.map { high[$0] }
        var dists3 = Self.iouDistance(unconfirmed, rest)
        if cfg.fuseScore { dists3 = Self.fuseScore(dists3, rest) }
        let (matches3, uUnconfirmed, uDetection3) = LinearAssignment.solve(dists3, rows: unconfirmed.count,
                                                                           cols: rest.count, thresh: 0.7)
        for (it, id) in matches3 {
            unconfirmed[it].update(rest[id], kf: kf, frameId: frameId)
            activated.append(unconfirmed[it])
        }
        for it in uUnconfirmed {
            unconfirmed[it].state = .removed
            removedNow.append(unconfirmed[it])
        }

        // Шаг 4: новые треки
        for id in uDetection3 {
            let track = rest[id]
            if track.score < cfg.newTrackThresh { continue }
            track.activate(kf: kf, frameId: frameId, newId: newId())
            activated.append(track)
        }

        // Шаг 5: удаляем давно потерянные
        for track in lost where frameId - track.endFrame > maxTimeLost {
            track.state = .removed
            removedNow.append(track)
        }

        tracked = tracked.filter { $0.state == .tracked }
        tracked = Self.joint(tracked, activated)
        tracked = Self.joint(tracked, refind)
        lost = Self.sub(lost, tracked)
        lost.append(contentsOf: lostNow)
        lost = Self.sub(lost, removedNow)
        (tracked, lost) = Self.removeDuplicates(tracked, lost)
        removed.append(contentsOf: removedNow)
        if removed.count > 1000 { removed.removeFirst(removed.count - 999) }

        return tracked.filter { $0.isActivated }.map { t in
            let b = t.xyxy
            let clipped = Box(x1: min(max(b.x1, 0), width), y1: min(max(b.y1, 0), height),
                              x2: min(max(b.x2, 0), width), y2: min(max(b.y2, 0), height))
            return TrackOutput(trackId: t.trackId, box: clipped, detIndex: t.detIndex)
        }
    }

    // MARK: - Вспомогательные функции (как в ultralytics.trackers.byte_tracker / utils.matching)

    static func joint(_ a: [STrack], _ b: [STrack]) -> [STrack] {
        var exists = Set(a.map { $0.trackId })
        var res = a
        for t in b where !exists.contains(t.trackId) {
            exists.insert(t.trackId)
            res.append(t)
        }
        return res
    }

    static func sub(_ a: [STrack], _ b: [STrack]) -> [STrack] {
        let ids = Set(b.map { $0.trackId })
        return a.filter { !ids.contains($0.trackId) }
    }

    static func removeDuplicates(_ a: [STrack], _ b: [STrack]) -> ([STrack], [STrack]) {
        let d = iouDistance(a, b)
        var dupA = Set<Int>(), dupB = Set<Int>()
        for p in 0..<a.count {
            for q in 0..<b.count where d[p][q] < 0.15 {
                let timeP = a[p].frameId - a[p].startFrame
                let timeQ = b[q].frameId - b[q].startFrame
                if timeP > timeQ { dupB.insert(q) } else { dupA.insert(p) }
            }
        }
        let resA = a.enumerated().filter { !dupA.contains($0.offset) }.map { $0.element }
        let resB = b.enumerated().filter { !dupB.contains($0.offset) }.map { $0.element }
        return (resA, resB)
    }

    static func iouDistance(_ a: [STrack], _ b: [STrack]) -> [[Double]] {
        let boxesB = b.map { $0.xyxy }
        return a.map { ta in
            let ba = ta.xyxy
            return boxesB.map { 1 - Geometry.iou(ba, $0) }
        }
    }

    static func fuseScore(_ cost: [[Double]], _ dets: [STrack]) -> [[Double]] {
        cost.map { row in
            row.enumerated().map { j, c in 1 - (1 - c) * dets[j].score }
        }
    }
}

/// Оптимальное сопоставление с порогом стоимости — как lap.lapjv(extend_cost=True, cost_limit=thresh).
nonisolated enum LinearAssignment {
    /// Возвращает (пары (строка, столбец), несопоставленные строки, несопоставленные столбцы).
    static func solve(_ cost: [[Double]], rows n: Int, cols m: Int,
                      thresh: Double) -> ([(Int, Int)], [Int], [Int]) {
        if n == 0 || m == 0 {
            return ([], Array(0..<n), Array(0..<m))
        }
        // Расширенная матрица (n+m)×(n+m): реальные стоимости, «отказ» стоит thresh/2 с каждой стороны.
        let size = n + m
        var ext = [[Double]](repeating: [Double](repeating: thresh / 2, count: size), count: size)
        for i in n..<size { for j in m..<size { ext[i][j] = 0 } }
        for i in 0..<n { for j in 0..<m { ext[i][j] = cost[i][j] } }

        let assign = hungarian(ext)  // assign[row] = col
        var matches: [(Int, Int)] = []
        var matchedCols = Set<Int>()
        var unmatchedRows: [Int] = []
        for i in 0..<n {
            let j = assign[i]
            if j < m {
                matches.append((i, j))
                matchedCols.insert(j)
            } else {
                unmatchedRows.append(i)
            }
        }
        let unmatchedCols = (0..<m).filter { !matchedCols.contains($0) }
        return (matches, unmatchedRows, unmatchedCols)
    }

    /// Венгерский алгоритм (O(n³), с потенциалами) для квадратной матрицы. Возвращает столбец для каждой строки.
    static func hungarian(_ a: [[Double]]) -> [Int] {
        let n = a.count
        let inf = Double.greatestFiniteMagnitude
        var u = [Double](repeating: 0, count: n + 1)
        var v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1)   // p[j] — строка, назначенная столбцу j (1-based)
        var way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: inf, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = inf
                var j1 = 0
                for j in 1...n where !used[j] {
                    let cur = a[i0 - 1][j - 1] - u[i0] - v[j]
                    if cur < minv[j] {
                        minv[j] = cur
                        way[j] = j0
                    }
                    if minv[j] < delta {
                        delta = minv[j]
                        j1 = j
                    }
                }
                for j in 0...n {
                    if used[j] {
                        u[p[j]] += delta
                        v[j] -= delta
                    } else {
                        minv[j] -= delta
                    }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var result = [Int](repeating: -1, count: n)
        for j in 1...n where p[j] > 0 {
            result[p[j] - 1] = j - 1
        }
        return result
    }
}
