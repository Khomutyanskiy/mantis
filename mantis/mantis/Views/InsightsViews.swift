//
//  InsightsViews.swift
//  mantis
//
//  Дополнительная аналитика на экране результата (итог по всему видео):
//  список «Поведение», воронка интереса, «Поток» и тепловая карта — в HeatmapViews.swift.
//

import SwiftUI

// MARK: - Общие элементы

/// Заголовок секции.
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(Theme.moon)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(Theme.moonDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Строка списка: иконка в плашке, название с пояснением и значение справа.
struct MetricRow: View {
    let icon: String
    let tint: Color
    let title: String
    var hint: String?
    let value: String
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(Theme.moonDim).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.moon)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.moonDim).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

/// Карточка со списком строк и тонкими разделителями.
struct MetricList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 {
                        Divider().overlay(Theme.stroke).padding(.leading, 60)
                    }
                    subview
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
    }
}

private func pct(_ n: Int, of total: Int) -> String? {
    guard total > 0 else { return nil }
    return "\(Int((Double(n) / Double(total) * 100).rounded()))%"
}

private func seconds(_ s: Double?) -> String {
    guard let s else { return "—" }
    return String(format: "%.1f с", s)
}

// MARK: - Поведение

struct BehaviorList: View {
    let m: ExtendedMetrics
    /// Множитель калибровки расстояний (1 — без калибровки).
    var speedScale: Double = 1

    private var speed: Double? { m.avgSpeed.map { $0 * speedScale } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Поведение", subtitle: "итог по всему видео")
            MetricList {
                MetricRow(icon: "figure.walk.motion", tint: Theme.moon,
                          title: "Средняя скорость прохожих", hint: "пока человек идёт",
                          value: speed.map { String(format: "%.1f м/с", $0) } ?? "—",
                          detail: speed.map { String(format: "%.1f км/ч", $0 * 3.6) })
                MetricRow(icon: "hand.raised.fill", tint: .orange,
                          title: "Остановились", hint: "стояли на месте 2 с и дольше",
                          value: "\(m.stopped)",
                          detail: m.avgStopSeconds.map { "в среднем " + seconds($0) } ?? pct(m.stopped, of: m.people))
                MetricRow(icon: "eye.fill", tint: PersonState.looked.color,
                          title: "Время взгляда", hint: "среднее у посмотревших",
                          value: seconds(m.avgLookSeconds),
                          detail: m.medianLookSeconds.map { "медиана " + seconds($0) })
                MetricRow(icon: "arrow.down.right.and.arrow.up.left", tint: .cyan,
                          title: "Подошли ближе", hint: "приблизились к камере",
                          value: "\(m.approached)", detail: pct(m.approached, of: m.people))
                MetricRow(icon: "arrow.uturn.backward", tint: .pink,
                          title: "Оглянулись после прохода", hint: "смотрели, уже уходя",
                          value: "\(m.lookedBack)", detail: pct(m.lookedBack, of: m.people))
                MetricRow(icon: "person.3.fill", tint: Theme.moon,
                          title: "Одновременно в кадре", hint: "максимум за видео",
                          value: "\(m.maxSimultaneous)")
            }
        }
    }
}

// MARK: - Воронка

struct FunnelView: View {
    let m: ExtendedMetrics
    let slowed: Int

    private struct Step: Identifiable {
        let id = UUID()
        let title: String
        let value: Int
        let color: Color
    }

    private var steps: [Step] {
        var s = [
            Step(title: "В зоне", value: m.people, color: Theme.moon),
            Step(title: "Притормозили", value: slowed, color: PersonState.slowed.color),
            Step(title: "Посмотрели", value: m.lookers, color: PersonState.looked.color),
            Step(title: "Остановились", value: m.stopped, color: .orange),
            Step(title: "Подошли ближе", value: m.approached, color: .cyan),
        ]
        if let entered = m.entered {
            s.append(Step(title: "Вошли в магазин", value: entered, color: .green))
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Воронка интереса",
                          subtitle: m.entered == nil ? "добавьте линию «Вход» в разметке, чтобы видеть вход в магазин" : nil)
            VStack(spacing: 10) {
                ForEach(steps) { step in
                    let share = m.people > 0 ? Double(step.value) / Double(m.people) : 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(step.title).font(.subheadline).foregroundStyle(Theme.moon)
                            Spacer()
                            Text("\(step.value)").font(.subheadline.weight(.bold)).monospacedDigit()
                                .foregroundStyle(Theme.moon)
                            Text(pct(step.value, of: m.people) ?? "—")
                                .font(.caption).monospacedDigit().foregroundStyle(Theme.moonDim)
                                .frame(width: 40, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.surfaceHigh)
                                Capsule().fill(step.color.opacity(0.85))
                                    .frame(width: max(6, geo.size.width * min(share, 1)))
                            }
                        }
                        .frame(height: 8)
                    }
                }
            }
            .themedCard(padding: 14)
        }
    }
}

// MARK: - Поток

struct FlowList: View {
    let m: ExtendedMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Поток")
            MetricList {
                MetricRow(icon: "arrow.down.to.line", tint: Theme.moon, title: "К камере",
                          value: "\(m.towardCamera)", detail: pct(m.towardCamera, of: m.people))
                MetricRow(icon: "arrow.up.to.line", tint: Theme.moon, title: "От камеры",
                          value: "\(m.awayFromCamera)", detail: pct(m.awayFromCamera, of: m.people))
                MetricRow(icon: "arrow.right", tint: Theme.moon, title: "Слева направо",
                          value: "\(m.leftToRight)", detail: pct(m.leftToRight, of: m.people))
                MetricRow(icon: "arrow.left", tint: Theme.moon, title: "Справа налево",
                          value: "\(m.rightToLeft)", detail: pct(m.rightToLeft, of: m.people))
                MetricRow(icon: "person.fill", tint: .cyan, title: "Одиночки",
                          value: "\(m.singles)", detail: pct(m.singles, of: m.people))
                MetricRow(icon: "person.2.fill", tint: .cyan, title: "Группы", hint: "идут рядом",
                          value: "\(m.groups)",
                          detail: m.groups > 0 ? "\(m.peopleInGroups) чел." : nil)
            }
        }
    }
}
