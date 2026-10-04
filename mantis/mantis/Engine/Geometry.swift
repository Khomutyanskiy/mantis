//
//  Geometry.swift
//  mantis
//
//  Геометрические примитивы: линия подсчёта и зона витрины.
//  Порт python/mantis/geometry.py — формулы и порядок операций совпадают, чтобы результаты были идентичны.
//

import Foundation

nonisolated struct Pt: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// Прямоугольник x1, y1, x2, y2 в пикселях кадра (y вниз).
nonisolated struct Box: Codable, Equatable, Sendable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double

    var width: Double { x2 - x1 }
    var height: Double { y2 - y1 }
    var area: Double { max(0, x2 - x1) * max(0, y2 - y1) }
}

nonisolated enum Geometry {
    /// С какой стороны от прямой AB лежит точка P: +1, -1 или 0 (на линии).
    static func sideOfLine(_ p: Pt, _ a: Pt, _ b: Pt) -> Int {
        let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        if cross > 0 { return 1 }
        if cross < 0 { return -1 }
        return 0
    }

    /// Пересекает ли отрезок движения P1→P2 отрезок линии AB (а не её продолжение).
    static func segmentsIntersect(_ p1: Pt, _ p2: Pt, _ a: Pt, _ b: Pt) -> Bool {
        let d1 = sideOfLine(p1, a, b)
        let d2 = sideOfLine(p2, a, b)
        let d3 = sideOfLine(a, p1, p2)
        let d4 = sideOfLine(b, p1, p2)
        return d1 != d2 && d3 != d4 && d1 != 0 && d2 != 0
    }

    /// Ray casting: лежит ли точка внутри многоугольника.
    static func pointInPolygon(_ p: Pt, _ poly: [Pt]) -> Bool {
        var inside = false
        let n = poly.count
        guard n > 0 else { return false }
        var j = n - 1
        for i in 0..<n {
            let xi = poly[i].x, yi = poly[i].y
            let xj = poly[j].x, yj = poly[j].y
            if (yi > p.y) != (yj > p.y) {
                let xCross = (xj - xi) * (p.y - yi) / (yj - yi) + xi
                if p.x < xCross {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// Площадь многоугольника (формула шнурования), как polygon_area в Python.
    static func polygonArea(_ poly: [Pt]) -> Double {
        let n = poly.count
        var s = 0.0
        for i in 0..<n {
            let a = poly[i], b = poly[(i + 1) % n]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// Перевод координат из долей кадра (0..1) в пиксели.
    static func toPixels(_ points: [Pt], width: Double, height: Double) -> [Pt] {
        points.map { Pt($0.x * width, $0.y * height) }
    }

    /// IoU двух прямоугольников (как в ultralytics bbox_ioa(iou=True), eps = 1e-7).
    static func iou(_ a: Box, _ b: Box) -> Double {
        let iw = max(0, min(a.x2, b.x2) - max(a.x1, b.x1))
        let ih = max(0, min(a.y2, b.y2) - max(a.y1, b.y1))
        let inter = iw * ih
        let areaA = (a.x2 - a.x1) * (a.y2 - a.y1)
        let areaB = (b.x2 - b.x1) * (b.y2 - b.y1)
        return inter / (areaA + areaB - inter + 1e-7)
    }
}
