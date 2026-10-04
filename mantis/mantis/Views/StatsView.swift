//
//  StatsView.swift
//  mantis
//
//  Статистика режима камеры по часам и дням недели: час пик, лучший день, итог за период,
//  оценка витрины и деньги за период.
//

import Charts
import SwiftUI

struct StatsView: View {
    enum Period: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: return "7 дней"
            case .month: return "30 дней"
            case .all: return "Всё время"
            }
        }
        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case people, looked, slowed, entered, passed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .people: return "Люди"
            case .looked: return "Посмотрели"
            case .slowed: return "Притормозили"
            case .entered: return "Вошли"
            case .passed: return "Прошли"
            }
        }
        var color: Color {
            switch self {
            case .people: return Theme.moon
            case .looked: return PersonState.looked.color
            case .slowed: return PersonState.slowed.color
            case .entered: return .mint
            case .passed: return .cyan
            }
        }
        func value(_ h: HourStat) -> Int {
            switch self {
            case .people: return h.people
            case .looked: return h.looked
            case .slowed: return h.slowed
            case .entered: return h.entered
            case .passed: return h.passed
            }
        }
    }

    private struct DayBar: Identifiable {
        let day: Date
        let value: Int
        var id: Date { day }
    }

    private struct Bar: Identifiable {
        let id: Int
        let label: String
        let value: Double
    }

    @State private var period: Period = .week
    @State private var metric: Metric = .people
    @State private var confirmClear = false

    private var store: HourlyStore { .shared }
    private static let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    /// Часы, попавшие в период.
    private var rows: [(date: Date, stat: HourStat)] {
        let from = period.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) } ?? .distantPast
        return store.hours.compactMap { item -> (date: Date, stat: HourStat)? in
            guard let d = HourKey.date(item.key) else { return nil }
            return (date: d, stat: item.value)
        }
            .filter { $0.date >= from }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        let rows = self.rows
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Период", selection: $period) {
                    ForEach(Period.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if rows.isEmpty {
                    ContentUnavailableView("Данных пока нет", systemImage: "chart.bar.xaxis",
                                           description: Text("Запустите подсчёт на вкладке «Камера» — статистика копится по часам автоматически."))
                        .padding(.top, 30)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Metric.allCases) { m in
                                HeatChip(title: m.title, icon: "circle.fill", on: metric == m) { metric = m }
                            }
                        }
                    }

                    totalsCard(rows)
                    hourChart(rows)
                    weekdayChart(rows)
                    dayChart(rows)

                    let total = rows.reduce(HourStat()) { $0 + $1.stat }
                    let seconds = total.seconds
                    ScoreCard(score: ShowcaseScore.compute(people: total.people, looked: total.looked, slowed: total.slowed,
                                                           stopped: 0, approached: 0,
                                                           entered: total.entered > 0 ? total.entered : nil))
                    MoneyCard(estimate: MoneyEstimate.compute(profile: AccountModel.shared.profile, people: total.people,
                                                              looked: total.looked,
                                                              entered: total.entered > 0 ? total.entered : nil,
                                                              duration: seconds),
                              profile: AccountModel.shared.profile)
                    Text("Оценка за период считается без остановок и «подошли ближе» — они не копятся по часам.")
                        .font(.caption).foregroundStyle(Theme.moonDim)

                    Button("Очистить статистику на телефоне", role: .destructive) { confirmClear = true }
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding()
            .padding(.bottom, 20)
        }
        .themedScreen()
        .navigationTitle("По часам и дням")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .confirmationDialog("Очистить статистику?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { store.clearAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Удалится статистика на этом телефоне. Копия в облаке останется и вернётся при следующем входе.")
        }
    }

    // MARK: Итог

    private func totalsCard(_ rows: [(date: Date, stat: HourStat)]) -> some View {
        let total = rows.reduce(HourStat()) { $0 + $1.stat }
        let hours = total.seconds / 3600
        let peak = hourBars(rows).max { $0.value < $1.value }
        let best = weekdayBars(rows).max { $0.value < $1.value }
        return MetricList {
            MetricRow(icon: "clock", tint: Theme.moon, title: "Наблюдали", value: "\(heatNum(hours)) ч",
                      detail: "\(Set(rows.map { Calendar.current.startOfDay(for: $0.date) }).count) дн.")
            MetricRow(icon: "person.2.fill", tint: Theme.moon, title: "Людей", value: "\(total.people)",
                      detail: hours > 0 ? "\(heatNum(Double(total.people) / hours, 0)) в час" : nil)
            MetricRow(icon: "eye.fill", tint: PersonState.looked.color, title: "Посмотрели", value: "\(total.looked)",
                      detail: total.people > 0 ? "\(Int((Double(total.looked) / Double(total.people) * 100).rounded()))%" : nil)
            if total.entered > 0 {
                MetricRow(icon: "door.left.hand.open", tint: .mint, title: "Вошли", value: "\(total.entered)",
                          detail: total.people > 0 ? "\(Int((Double(total.entered) / Double(total.people) * 100).rounded()))%" : nil)
            }
            if let peak, peak.value > 0 {
                MetricRow(icon: "flame.fill", tint: .orange, title: "Час пик", hint: "\(metric.title.lowercased()), в среднем за день",
                          value: peak.label, detail: heatNum(peak.value, 1))
            }
            if let best, best.value > 0 {
                MetricRow(icon: "star.fill", tint: .yellow, title: "Лучший день недели", hint: "\(metric.title.lowercased()), в среднем",
                          value: best.label, detail: heatNum(best.value, 0))
            }
        }
    }

    // MARK: По часам

    /// Среднее за день по каждому часу (делим на число дней, когда этот час наблюдался).
    private func hourBars(_ rows: [(date: Date, stat: HourStat)]) -> [Bar] {
        var sum = [Double](repeating: 0, count: 24), days = [Int](repeating: 0, count: 24)
        for r in rows {
            let h = Calendar.current.component(.hour, from: r.date)
            sum[h] += Double(metric.value(r.stat))
            days[h] += 1
        }
        return (0..<24).map { Bar(id: $0, label: "\($0):00", value: days[$0] > 0 ? sum[$0] / Double(days[$0]) : 0) }
    }

    private func hourChart(_ rows: [(date: Date, stat: HourStat)]) -> some View {
        let bars = hourBars(rows)
        let peak = bars.max { $0.value < $1.value }?.id
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "По часам", subtitle: "\(metric.title.lowercased()) в среднем за день")
            Chart(bars) { b in
                BarMark(x: .value("Час", b.id), y: .value(metric.title, b.value))
                    .foregroundStyle(b.id == peak ? Color.orange : metric.color.opacity(0.8))
                    .cornerRadius(3)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { _ in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel().foregroundStyle(Theme.moonDim)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel().foregroundStyle(Theme.moonDim)
                }
            }
            .frame(height: 190)
        }
        .themedCard(padding: 14)
    }

    // MARK: По дням недели

    private func weekdayBars(_ rows: [(date: Date, stat: HourStat)]) -> [Bar] {
        var sum = [Double](repeating: 0, count: 7)
        var days = [Set<Date>](repeating: [], count: 7)
        for r in rows {
            let wd = (Calendar.current.component(.weekday, from: r.date) + 5) % 7   // Пн = 0
            sum[wd] += Double(metric.value(r.stat))
            days[wd].insert(Calendar.current.startOfDay(for: r.date))
        }
        return (0..<7).map { Bar(id: $0, label: Self.weekdays[$0], value: days[$0].isEmpty ? 0 : sum[$0] / Double(days[$0].count)) }
    }

    private func weekdayChart(_ rows: [(date: Date, stat: HourStat)]) -> some View {
        let bars = weekdayBars(rows)
        let best = bars.max { $0.value < $1.value }?.id
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "По дням недели", subtitle: "\(metric.title.lowercased()) в среднем за день")
            Chart(bars) { b in
                BarMark(x: .value("День", b.label), y: .value(metric.title, b.value))
                    .foregroundStyle(b.id == best ? Color.yellow : metric.color.opacity(0.8))
                    .cornerRadius(3)
            }
            .chartXScale(domain: Self.weekdays)
            .themedChartAxes()
            .frame(height: 170)
        }
        .themedCard(padding: 14)
    }

    // MARK: По датам

    private func dayChart(_ rows: [(date: Date, stat: HourStat)]) -> some View {
        var byDay: [Date: Int] = [:]
        for r in rows { byDay[Calendar.current.startOfDay(for: r.date), default: 0] += metric.value(r.stat) }
        let items = byDay.sorted { $0.key < $1.key }.map { DayBar(day: $0.key, value: $0.value) }
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "По датам", subtitle: "\(metric.title.lowercased()) за день")
            Chart(items) { d in
                BarMark(x: .value("Дата", d.day, unit: .day), y: .value(metric.title, d.value))
                    .foregroundStyle(metric.color.opacity(0.8))
                    .cornerRadius(3)
            }
            .themedChartAxes()
            .frame(height: 170)
        }
        .themedCard(padding: 14)
    }
}
