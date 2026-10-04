//
//  Business.swift
//  mantis
//
//  Бизнес-слой: профиль магазина, оценка витрины 0–100, пересчёт в деньги,
//  статистика по часам (режим камеры) и история анализов.
//

import Foundation

// MARK: - Профиль магазина

nonisolated struct BusinessProfile: Codable, Equatable, Sendable {
    var name = ""
    var company = ""
    var point = ""
    var city = ""
    /// Средний чек, ₽.
    var avgCheck: Double = 3000
    /// Сколько процентов посмотревших на витрину покупают (если линии входа нет).
    var lookToBuy: Double = 3
    /// Сколько процентов вошедших покупают.
    var enterToBuy: Double = 20
    /// Часы работы в день и дни в месяц — для пересчёта «в месяц».
    var hoursPerDay: Double = 12
    var daysPerMonth: Double = 30

    static let storageKey = "businessProfile.v1"

    static func loadLocal() -> BusinessProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let p = try? JSONDecoder().decode(BusinessProfile.self, from: data) else { return BusinessProfile() }
        return p
    }

    func saveLocal() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    init() {}

    // мягкое чтение: новые поля в будущих версиях не ломают старые документы
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BusinessProfile()
        name = (try? c.decode(String.self, forKey: .name)) ?? d.name
        company = (try? c.decode(String.self, forKey: .company)) ?? d.company
        point = (try? c.decode(String.self, forKey: .point)) ?? d.point
        city = (try? c.decode(String.self, forKey: .city)) ?? d.city
        avgCheck = (try? c.decode(Double.self, forKey: .avgCheck)) ?? d.avgCheck
        lookToBuy = (try? c.decode(Double.self, forKey: .lookToBuy)) ?? d.lookToBuy
        enterToBuy = (try? c.decode(Double.self, forKey: .enterToBuy)) ?? d.enterToBuy
        hoursPerDay = (try? c.decode(Double.self, forKey: .hoursPerDay)) ?? d.hoursPerDay
        daysPerMonth = (try? c.decode(Double.self, forKey: .daysPerMonth)) ?? d.daysPerMonth
    }
}

// MARK: - Оценка витрины

/// Одна цифра 0–100: насколько витрина цепляет прохожих.
/// Каждая доля (посмотрели, притормозили, остановились, подошли, вошли) сравнивается с «хорошим» уровнем
/// и складывается с весом. Если линии входа нет, её вес делится между остальными.
nonisolated struct ShowcaseScore: Sendable {
    nonisolated struct Part: Sendable, Identifiable {
        let title: String
        let count: Int
        let rate: Double      // доля от людей в зоне
        let target: Double    // «хороший» уровень
        let weight: Double
        var id: String { title }
        var fill: Double { min(1, rate / target) }
    }

    var value: Int
    var people: Int
    var parts: [Part]

    var grade: String {
        switch value {
        case ..<40: return "слабо цепляет"
        case ..<70: return "средне"
        default: return "сильная витрина"
        }
    }

    static let minPeople = 3

    static func compute(people: Int, looked: Int, slowed: Int, stopped: Int, approached: Int, entered: Int?) -> ShowcaseScore? {
        guard people >= minPeople else { return nil }
        let n = Double(people)
        func part(_ t: String, _ c: Int, _ target: Double, _ w: Double) -> Part {
            Part(title: t, count: c, rate: min(1, Double(c) / n), target: target, weight: w)
        }
        var parts = [
            part("Посмотрели", looked, 0.30, 35),
            part("Притормозили", slowed, 0.20, 15),
            part("Остановились", stopped, 0.10, 20),
            part("Подошли ближе", approached, 0.10, 10),
        ]
        if let entered { parts.append(part("Вошли", entered, 0.05, 20)) }
        let total = parts.reduce(0) { $0 + $1.weight }
        let v = parts.reduce(0) { $0 + $1.weight * $1.fill } / total * 100
        return ShowcaseScore(value: Int(v.rounded()), people: people, parts: parts)
    }

    static func from(_ m: ExtendedMetrics, counters: Counters, people: Int) -> ShowcaseScore? {
        compute(people: people, looked: counters.looked, slowed: counters.slowed, stopped: m.stopped,
                approached: m.approached, entered: m.entered)
    }
}

// MARK: - Деньги

nonisolated struct MoneyEstimate: Sendable {
    /// «вошедших» или «посмотревших»
    var basisTitle: String
    var basis: Int
    var conversion: Double     // %
    var buyers: Double
    var revenue: Double
    var perHour: Double?
    var perMonth: Double?
    /// Если витрина привлечёт на 10 п.п. больше взглядов — плюс в месяц.
    var upliftPerMonth: Double?

    static func compute(profile p: BusinessProfile, people: Int, looked: Int, entered: Int?, duration: Double) -> MoneyEstimate {
        let useEntered = entered != nil
        let basis = entered ?? looked
        let conv = useEntered ? p.enterToBuy : p.lookToBuy
        let buyers = Double(basis) * conv / 100
        let revenue = buyers * p.avgCheck
        var e = MoneyEstimate(basisTitle: useEntered ? "вошедших" : "посмотревших", basis: basis, conversion: conv,
                              buyers: buyers, revenue: revenue)
        // экстраполяция имеет смысл, если наблюдали хотя бы минуту
        if duration >= 60 {
            let perHour = revenue / duration * 3600
            e.perHour = perHour
            e.perMonth = perHour * p.hoursPerDay * p.daysPerMonth
            // +10% людей посмотрят → столько же процентов купят (через конверсию взгляда)
            let extraLookers = Double(people) * 0.10 / duration * 3600 * p.hoursPerDay * p.daysPerMonth
            e.upliftPerMonth = extraLookers * p.lookToBuy / 100 * p.avgCheck
        }
        return e
    }
}

func rubles(_ v: Double) -> String {
    let r: Double
    if v >= 10_000 { r = (v / 1000).rounded() * 1000 } else if v >= 1000 { r = (v / 100).rounded() * 100 } else { r = v.rounded() }
    return Int(r).formatted(.number.locale(Locale(identifier: "ru_RU"))) + " ₽"
}

// MARK: - Статистика по часам

/// Счётчики за один час работы камеры.
nonisolated struct HourStat: Codable, Equatable, Sendable {
    var people = 0
    var looked = 0
    var slowed = 0
    var passed = 0
    var entered = 0
    /// Сколько секунд в этом часе шёл подсчёт.
    var seconds = 0.0

    static func + (a: HourStat, b: HourStat) -> HourStat {
        HourStat(people: a.people + b.people, looked: a.looked + b.looked, slowed: a.slowed + b.slowed,
                 passed: a.passed + b.passed, entered: a.entered + b.entered, seconds: a.seconds + b.seconds)
    }

    /// Слияние двух копий одного часа (телефон и облако): по каждому полю — максимум.
    func merged(_ o: HourStat) -> HourStat {
        HourStat(people: max(people, o.people), looked: max(looked, o.looked), slowed: max(slowed, o.slowed),
                 passed: max(passed, o.passed), entered: max(entered, o.entered), seconds: max(seconds, o.seconds))
    }

    init(people: Int = 0, looked: Int = 0, slowed: Int = 0, passed: Int = 0, entered: Int = 0, seconds: Double = 0) {
        self.people = people
        self.looked = looked
        self.slowed = slowed
        self.passed = passed
        self.entered = entered
        self.seconds = seconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = (try? c.decode(Int.self, forKey: .people)) ?? 0
        looked = (try? c.decode(Int.self, forKey: .looked)) ?? 0
        slowed = (try? c.decode(Int.self, forKey: .slowed)) ?? 0
        passed = (try? c.decode(Int.self, forKey: .passed)) ?? 0
        entered = (try? c.decode(Int.self, forKey: .entered)) ?? 0
        seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 0
    }
}

/// Ключ часа «2026-10-03-14» (местное время).
nonisolated enum HourKey {
    static func make(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
    }

    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 4 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3]))
    }
}

/// Хранилище почасовой статистики (файл на телефоне + облако, если вошли).
@Observable
final class HourlyStore {
    static let shared = HourlyStore()

    private(set) var hours: [String: HourStat] = [:]
    @ObservationIgnored var uid: String?
    @ObservationIgnored private var dirty = Set<String>()
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var lastUpload = Date.distantPast

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hourly_stats.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let h = try? JSONDecoder().decode([String: HourStat].self, from: data) { hours = h }
    }

    /// Прибавить к текущему часу.
    func add(_ d: HourStat, at date: Date = Date()) {
        guard d != HourStat() else { return }
        let key = HourKey.make(date)
        hours[key] = (hours[key] ?? HourStat()) + d
        dirty.insert(key)
        if Date().timeIntervalSince(lastSave) > 30 { flush() }
    }

    /// Сохранить на телефон и отправить изменённые часы в облако.
    func flush() {
        lastSave = Date()
        if let data = try? JSONEncoder().encode(hours) { try? data.write(to: Self.url, options: .atomic) }
        guard let uid, !dirty.isEmpty, Date().timeIntervalSince(lastUpload) > 30 || dirty.count > 20 else { return }
        let changed = hours.filter { dirty.contains($0.key) }
        dirty.removeAll()
        lastUpload = Date()
        Cloud.saveHours(changed, uid: uid)
    }

    /// После входа: объединить с облаком и отправить объединённое.
    func merge(remote: [String: HourStat]) {
        for (k, v) in remote { hours[k] = hours[k].map { $0.merged(v) } ?? v }
        dirty = Set(hours.keys)
        lastUpload = .distantPast
        flush()
    }

    func clearAll() {
        hours = [:]
        dirty = []
        flush()
    }
}

// MARK: - История анализов

nonisolated struct ReportSummary: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var date = Date()
    var source = "video"          // video | camera
    var title = ""
    var duration = 0.0
    var people = 0
    var passed = 0
    var slowed = 0
    var looked = 0
    var stopped = 0
    var approached = 0
    var entered: Int?
    var score: Int?
    var revenue: Double?
    var perMonth: Double?
}

@Observable
final class ReportStore {
    static let shared = ReportStore()

    private(set) var items: [ReportSummary] = []

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reports.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let r = try? JSONDecoder().decode([ReportSummary].self, from: data) { items = r }
    }

    func add(_ r: ReportSummary) {
        items.insert(r, at: 0)
        items = Array(items.prefix(200))
        save()
        if let uid = AccountModel.shared.uid { Cloud.saveReport(r, uid: uid) }
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        save()
        if let uid = AccountModel.shared.uid { Cloud.deleteReport(id, uid: uid) }
    }

    /// Очистить историю на телефоне (облако не трогаем).
    func clearLocal() {
        items = []
        save()
    }

    func merge(remote: [ReportSummary]) {
        let have = Set(items.map(\.id))
        let missingRemote = items.filter { r in !remote.contains { $0.id == r.id } }
        items = (items + remote.filter { !have.contains($0.id) }).sorted { $0.date > $1.date }
        save()
        if let uid = AccountModel.shared.uid {
            for r in missingRemote { Cloud.saveReport(r, uid: uid) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.url, options: .atomic) }
    }
}
