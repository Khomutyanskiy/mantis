//
//  Markup.swift
//  mantis
//
//  Разметка кадра, которую пользователь рисует перед анализом:
//  зона детекции (четырёхугольник), линия подсчёта и линия входа в магазин (обе можно выключить).
//  Координаты — доли кадра 0..1.
//

import Foundation

nonisolated struct Markup: Codable, Equatable, Sendable {
    static let fullFrame = [Pt(0, 0), Pt(1, 0), Pt(1, 1), Pt(0, 1)]
    static let verticalLine = [Pt(0.5, 0.05), Pt(0.5, 0.95)]
    static let horizontalLine = [Pt(0.05, 0.6), Pt(0.95, 0.6)]
    static let defaultEntrance = [Pt(0.2, 0.8), Pt(0.8, 0.8)]

    /// Зона детекции: учитываются только люди, которые в неё заходили.
    var zone: [Pt] = Markup.fullFrame
    /// Считать ли проходы через линию.
    var lineEnabled = false
    /// Линия подсчёта (2 точки).
    var line: [Pt] = Markup.verticalLine
    /// Считать ли вход в магазин.
    var entranceEnabled = false
    /// Линия входа (порог двери), 2 точки.
    var entrance: [Pt] = Markup.defaultEntrance

    var isFullFrame: Bool { zone == Markup.fullFrame }

    init() {}

    enum CodingKeys: String, CodingKey {
        case zone, lineEnabled, line, entranceEnabled, entrance
    }

    /// Старые сохранённые разметки без новых полей тоже читаются.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zone = try c.decodeIfPresent([Pt].self, forKey: .zone) ?? Markup.fullFrame
        lineEnabled = try c.decodeIfPresent(Bool.self, forKey: .lineEnabled) ?? false
        line = try c.decodeIfPresent([Pt].self, forKey: .line) ?? Markup.verticalLine
        entranceEnabled = try c.decodeIfPresent(Bool.self, forKey: .entranceEnabled) ?? false
        entrance = try c.decodeIfPresent([Pt].self, forKey: .entrance) ?? Markup.defaultEntrance
    }

    /// Конфиг подсчёта для движка.
    func analyticsConfig(direction: ShowcaseDirection) -> AnalyticsConfig {
        var c = AnalyticsConfig()
        c.showcaseZone = zone.count >= 3 ? zone : Markup.fullFrame
        c.countLineEnabled = lineEnabled && line.count == 2
        c.countLine = line.count == 2 ? line : Markup.verticalLine
        c.look.showcaseDirection = direction
        return c
    }

    /// Линия входа для анализатора (nil — выключена).
    var entranceForAnalysis: [Pt]? { entranceEnabled && entrance.count == 2 ? entrance : nil }

    // MARK: - Хранение в UserDefaults (через @AppStorage как JSON-строка)

    static func decode(_ json: String) -> Markup {
        guard let data = json.data(using: .utf8), !json.isEmpty,
              let m = try? JSONDecoder().decode(Markup.self, from: data) else { return Markup() }
        return m
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
