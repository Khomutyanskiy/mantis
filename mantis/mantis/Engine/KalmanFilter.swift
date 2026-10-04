//
//  KalmanFilter.swift
//  mantis
//
//  Фильтр Калмана для трекинга рамок в пространстве (x, y, a, h, vx, vy, va, vh):
//  центр рамки, соотношение сторон w/h, высота и их скорости. Порт ultralytics KalmanFilterXYAH.
//

import Foundation

nonisolated struct Matrix: Equatable {
    var rows: Int
    var cols: Int
    var a: [Double]

    init(_ rows: Int, _ cols: Int, _ value: Double = 0) {
        self.rows = rows
        self.cols = cols
        self.a = Array(repeating: value, count: rows * cols)
    }

    static func identity(_ n: Int) -> Matrix {
        var m = Matrix(n, n)
        for i in 0..<n { m[i, i] = 1 }
        return m
    }

    static func diag(_ v: [Double]) -> Matrix {
        var m = Matrix(v.count, v.count)
        for i in 0..<v.count { m[i, i] = v[i] }
        return m
    }

    subscript(_ r: Int, _ c: Int) -> Double {
        get { a[r * cols + c] }
        set { a[r * cols + c] = newValue }
    }

    var transposed: Matrix {
        var m = Matrix(cols, rows)
        for r in 0..<rows { for c in 0..<cols { m[c, r] = self[r, c] } }
        return m
    }

    static func * (l: Matrix, r: Matrix) -> Matrix {
        precondition(l.cols == r.rows)
        var m = Matrix(l.rows, r.cols)
        for i in 0..<l.rows {
            for k in 0..<l.cols {
                let lik = l[i, k]
                if lik == 0 { continue }
                for j in 0..<r.cols { m[i, j] += lik * r[k, j] }
            }
        }
        return m
    }

    static func + (l: Matrix, r: Matrix) -> Matrix {
        var m = l
        for i in 0..<m.a.count { m.a[i] += r.a[i] }
        return m
    }

    static func - (l: Matrix, r: Matrix) -> Matrix {
        var m = l
        for i in 0..<m.a.count { m.a[i] -= r.a[i] }
        return m
    }

    /// Обратная матрица методом Гаусса — Жордана (для 4×4 ковариации проекции).
    var inverse: Matrix {
        precondition(rows == cols)
        let n = rows
        var m = self
        var inv = Matrix.identity(n)
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(m[r, col]) > abs(m[pivot, col]) { pivot = r }
            if pivot != col {
                for c in 0..<n {
                    m.a.swapAt(col * n + c, pivot * n + c)
                    inv.a.swapAt(col * n + c, pivot * n + c)
                }
            }
            let p = m[col, col]
            guard abs(p) > 1e-12 else { continue }
            for c in 0..<n {
                m[col, c] /= p
                inv[col, c] /= p
            }
            for r in 0..<n where r != col {
                let f = m[r, col]
                if f == 0 { continue }
                for c in 0..<n {
                    m[r, c] -= f * m[col, c]
                    inv[r, c] -= f * inv[col, c]
                }
            }
        }
        return inv
    }
}

nonisolated struct KalmanFilterXYAH {
    private let stdWeightPosition = 1.0 / 20
    private let stdWeightVelocity = 1.0 / 160
    private let motion: Matrix   // 8×8
    private let observation: Matrix   // 4×8 (H)

    init() {
        var f = Matrix.identity(8)
        for i in 0..<4 { f[i, 4 + i] = 1 }  // dt = 1 кадр
        motion = f
        var h = Matrix(4, 8)
        for i in 0..<4 { h[i, i] = 1 }
        observation = h
    }

    /// Новый трек из измерения (x, y, a, h).
    func initiate(_ m: [Double]) -> (mean: [Double], cov: Matrix) {
        let mean = m + [0, 0, 0, 0]
        let wp = stdWeightPosition, wv = stdWeightVelocity
        let std = [2 * wp * m[3], 2 * wp * m[3], 1e-2, 2 * wp * m[3],
                   10 * wv * m[3], 10 * wv * m[3], 1e-5, 10 * wv * m[3]]
        return (mean, Matrix.diag(std.map { $0 * $0 }))
    }

    func predict(mean: [Double], cov: Matrix) -> (mean: [Double], cov: Matrix) {
        let wp = stdWeightPosition, wv = stdWeightVelocity
        let std = [wp * mean[3], wp * mean[3], 1e-2, wp * mean[3],
                   wv * mean[3], wv * mean[3], 1e-5, wv * mean[3]]
        let q = Matrix.diag(std.map { $0 * $0 })
        var newMean = [Double](repeating: 0, count: 8)
        for i in 0..<8 {
            var s = 0.0
            for j in 0..<8 { s += motion[i, j] * mean[j] }
            newMean[i] = s
        }
        let newCov = motion * cov * motion.transposed + q
        return (newMean, newCov)
    }

    private func project(mean: [Double], cov: Matrix) -> (mean: [Double], cov: Matrix) {
        let wp = stdWeightPosition
        let std = [wp * mean[3], wp * mean[3], 1e-1, wp * mean[3]]
        let r = Matrix.diag(std.map { $0 * $0 })
        let pMean = Array(mean[0..<4])
        let pCov = observation * cov * observation.transposed + r
        return (pMean, pCov)
    }

    func update(mean: [Double], cov: Matrix, measurement: [Double]) -> (mean: [Double], cov: Matrix) {
        let (pMean, pCov) = project(mean: mean, cov: cov)
        // K = P Hᵀ S⁻¹
        let gain = cov * observation.transposed * pCov.inverse   // 8×4
        var newMean = mean
        for i in 0..<8 {
            var s = 0.0
            for j in 0..<4 { s += gain[i, j] * (measurement[j] - pMean[j]) }
            newMean[i] += s
        }
        let newCov = cov - gain * pCov * gain.transposed
        return (newMean, newCov)
    }
}
