//
//  ScoreViews.swift
//  mantis
//
//  Карточки «Оценка витрины» (0–100) и «Деньги» (потенциальная выручка по настройкам профиля).
//

import SwiftUI

extension ShowcaseScore {
    var color: Color {
        switch value {
        case ..<40: return Color(red: 0.95, green: 0.40, blue: 0.30)
        case ..<70: return Color(red: 0.98, green: 0.78, blue: 0.25)
        default: return Color(red: 0.35, green: 0.85, blue: 0.50)
        }
    }
}

/// Кольцо с оценкой.
struct ScoreRing: View {
    let value: Int
    let color: Color
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle().stroke(Theme.surfaceHigh, lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.moon)
                Text("из 100").font(.caption2).foregroundStyle(Theme.moonDim)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ScoreCard: View {
    let score: ShowcaseScore?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Оценка витрины", subtitle: "насколько витрина цепляет прохожих")
            if let score {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        ScoreRing(value: score.value, color: score.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(score.grade.capitalized(with: Locale(identifier: "ru_RU")))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(score.color)
                            Text("по \(score.people) \(peopleWord(score.people)) в зоне")
                                .font(.caption).foregroundStyle(Theme.moonDim)
                            Text("70+ — сильная, 40–69 — средняя, ниже 40 — слабая")
                                .font(.caption2).foregroundStyle(Theme.moonDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 8) {
                        ForEach(score.parts) { p in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(p.title).font(.caption).foregroundStyle(Theme.moon)
                                    Spacer()
                                    Text("\(Int((p.rate * 100).rounded()))% · цель \(Int(p.target * 100))%")
                                        .font(.caption2).monospacedDigit().foregroundStyle(Theme.moonDim)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.surfaceHigh)
                                        Capsule().fill(score.color.opacity(0.85))
                                            .frame(width: max(4, geo.size.width * p.fill))
                                    }
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                }
                .themedCard(padding: 14)
            } else {
                Text("Мало данных — нужно хотя бы \(ShowcaseScore.minPeople) человека в зоне.")
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .themedCard(padding: 14)
            }
        }
    }
}

func peopleWord(_ n: Int) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return "человеку" }
    return "людям"
}

struct MoneyCard: View {
    let estimate: MoneyEstimate
    let profile: BusinessProfile
    /// Показывать ссылку на настройки (на экране; в PDF — нет).
    var editable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Деньги", subtitle: "оценка по настройкам профиля")
                if editable {
                    NavigationLink {
                        BusinessSettingsView()
                    } label: {
                        Label("Настроить", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.moon)
                    }
                    .fixedSize()
                }
            }
            MetricList {
                MetricRow(icon: "cart.fill", tint: .green, title: "Потенциальные покупатели",
                          hint: "\(heatNum(estimate.conversion, estimate.conversion < 10 ? 1 : 0))% от \(estimate.basis) \(estimate.basisTitle)",
                          value: "≈ \(heatNum(estimate.buyers, estimate.buyers < 10 ? 1 : 0))")
                MetricRow(icon: "rublesign.circle.fill", tint: .green, title: "Выручка за период",
                          hint: "средний чек \(rubles(profile.avgCheck))", value: rubles(estimate.revenue))
                if let h = estimate.perHour {
                    MetricRow(icon: "clock.fill", tint: .green, title: "В час", value: rubles(h))
                }
                if let mo = estimate.perMonth {
                    MetricRow(icon: "calendar", tint: .green, title: "В месяц",
                              hint: "\(heatNum(profile.hoursPerDay, 0)) ч × \(heatNum(profile.daysPerMonth, 0)) дн.",
                              value: rubles(mo))
                }
                if let up = estimate.upliftPerMonth, up > 0 {
                    MetricRow(icon: "arrow.up.right.circle.fill", tint: .yellow, title: "Если смотреть будут на 10% чаще",
                              hint: "дополнительно в месяц", value: "+" + rubles(up))
                }
            }
            if estimate.perHour == nil {
                Text("Для пересчёта в час и месяц нужна хотя бы минута наблюдения.")
                    .font(.caption).foregroundStyle(Theme.moonDim)
            }
        }
    }
}
