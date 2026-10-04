//
//  AnalyticsConfig.swift
//  mantis
//
//  Параметры подсчёта. Значения по умолчанию совпадают с python/config.example.yaml.
//  Ключи в JSON — snake_case (как в Python-конфиге), декодировать с .convertFromSnakeCase.
//

import Foundation

nonisolated struct AnalyticsConfig: Codable, Equatable, Sendable {
    nonisolated struct Slowdown: Codable, Equatable, Sendable {
        /// Скорость в «ростах человека в секунду», ниже которой человек «тормозит».
        var speedThreshold: Double = 0.30
        /// Столько секунд суммарно медленно в зоне => «притормозил».
        var minSlowSeconds: Double = 1.0
        /// Или столько секунд в зоне в целом => тоже «притормозил».
        var dwellSeconds: Double = 8.0
        /// Окно сглаживания скорости.
        var smoothingSeconds: Double = 0.5
        /// Фокусное в долях длинной стороны кадра — для учёта движения к камере.
        var focalRatio: Double = 0.8
        /// Окно оценки скорости по глубине (изменение высоты рамки).
        var depthWindowSeconds: Double = 1.0
        /// Правило «долго в зоне» — только если зона нарисована (не весь кадр).
        var dwellOnlyWithZone: Bool = true
    }

    nonisolated struct Look: Codable, Equatable, Sendable {
        var showcaseDirection: ShowcaseDirection = .camera
        var maxYaw: Double = 0.35
        var minSideYaw: Double = 0.35
        var minLookSeconds: Double = 0.6
        var minKeypointConf: Double = 0.5
    }

    nonisolated struct Tracking: Codable, Equatable, Sendable {
        var lostTimeoutSeconds: Double = 2.0
        var minTrackSeconds: Double = 0.5
    }

    /// Считать ли проходы через линию. Выключено — анализируется всё видео без линии.
    var countLineEnabled = true
    /// Линия подсчёта в долях кадра (0..1).
    var countLine: [Pt] = [Pt(0.5, 0.0), Pt(0.5, 1.0)]
    /// Зона перед витриной в долях кадра (0..1).
    var showcaseZone: [Pt] = [Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)]
    var slowdown = Slowdown()
    var look = Look()
    var tracking = Tracking()

    init() {}

    enum CodingKeys: String, CodingKey {
        case countLineEnabled, countLine, showcaseZone, slowdown, look, tracking
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Python хранит точки как [[x, y], ...]
        countLineEnabled = try c.decodeIfPresent(Bool.self, forKey: .countLineEnabled) ?? true
        if let line = try c.decodeIfPresent([[Double]].self, forKey: .countLine) {
            countLine = line.map { Pt($0[0], $0[1]) }
        }
        if let zone = try c.decodeIfPresent([[Double]].self, forKey: .showcaseZone) {
            showcaseZone = zone.map { Pt($0[0], $0[1]) }
        }
        slowdown = try c.decodeIfPresent(Slowdown.self, forKey: .slowdown) ?? Slowdown()
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? Look()
        tracking = try c.decodeIfPresent(Tracking.self, forKey: .tracking) ?? Tracking()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(countLineEnabled, forKey: .countLineEnabled)
        try c.encode(countLine.map { [$0.x, $0.y] }, forKey: .countLine)
        try c.encode(showcaseZone.map { [$0.x, $0.y] }, forKey: .showcaseZone)
        try c.encode(slowdown, forKey: .slowdown)
        try c.encode(look, forKey: .look)
        try c.encode(tracking, forKey: .tracking)
    }
}
