//
//  OverlayView.swift
//  mantis
//
//  Разметка поверх видео: зона, линия подсчёта, рамки людей с номерами и панель счётчиков.
//

import SwiftUI

extension PersonState {
    var color: Color {
        switch self {
        case .looked: return .yellow
        case .slowed: return .green
        case .passed: return .white
        case .tracked: return Color(white: 0.65)
        }
    }
}

struct OverlayView: View {
    let result: AnalysisResult
    let time: Double
    /// Счётчики для панели (с учётом сброса); nil — как в снимке кадра.
    var counters: Counters? = nil
    /// Тепловые пятна (сетка «на кадре»), рисуются под рамками.
    var heat: HeatGrid? = nil

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fitRect(videoWidth: result.width, videoHeight: result.height, in: geo.size)
            let k = rect.width / result.width
            let frame = result.frame(at: time)

            ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                func map(_ p: Pt) -> CGPoint { CGPoint(x: rect.minX + p.x * k, y: rect.minY + p.y * k) }

                // Зона витрины
                var zonePath = Path()
                if let first = result.zone.first {
                    zonePath.move(to: map(first))
                    for p in result.zone.dropFirst() { zonePath.addLine(to: map(p)) }
                    zonePath.closeSubpath()
                }
                ctx.fill(zonePath, with: .color(.cyan.opacity(0.10)))
                ctx.stroke(zonePath, with: .color(.cyan.opacity(0.7)), lineWidth: 1.5)

                // Линия подсчёта
                if result.line.count == 2 {
                    var linePath = Path()
                    linePath.move(to: map(result.line[0]))
                    linePath.addLine(to: map(result.line[1]))
                    ctx.stroke(linePath, with: .color(.red), lineWidth: 2.5)
                }

                // Линия входа в магазин
                if result.entrance.count == 2 {
                    var ep = Path()
                    ep.move(to: map(result.entrance[0]))
                    ep.addLine(to: map(result.entrance[1]))
                    ctx.stroke(ep, with: .color(.green), style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                }

                // Тепловые пятна
                if let heat { HeatPaint.blobs(&ctx, grid: heat, rect: rect, opacity: 0.7) }

                // Люди
                for b in frame?.boxes ?? [] {
                    let r = CGRect(x: rect.minX + b.box.x1 * k, y: rect.minY + b.box.y1 * k,
                                   width: b.box.width * k, height: b.box.height * k)
                    if !b.inZone && b.state == .tracked {
                        // вне зоны детекции — тонкий пунктир без подписи
                        ctx.stroke(Path(r), with: .color(.gray.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        continue
                    }
                    ctx.stroke(Path(r), with: .color(b.state.color), lineWidth: 2)
                    var label = "#\(result.number(b.trackId))"
                    if b.lookingNow { label += " 👀" }
                    let text = Text(label).font(.caption2.bold()).foregroundColor(.black)
                    let resolved = ctx.resolve(text)
                    let ts = resolved.measure(in: CGSize(width: 200, height: 40))
                    let bg = CGRect(x: r.minX, y: max(rect.minY, r.minY - ts.height - 4),
                                    width: ts.width + 8, height: ts.height + 4)
                    ctx.fill(Path(roundedRect: bg, cornerRadius: 3), with: .color(b.state.color))
                    ctx.draw(resolved, at: CGPoint(x: bg.minX + 4, y: bg.minY + 2), anchor: .topLeading)
                }
            }

            }
        }
        .allowsHitTesting(false)
    }

    /// Прямоугольник видео внутри области (как AVPlayer с resizeAspect).
    static func fitRect(videoWidth: Double, videoHeight: Double, in size: CGSize) -> CGRect {
        guard videoWidth > 0, videoHeight > 0, size.width > 0, size.height > 0 else { return .zero }
        let k = min(size.width / videoWidth, size.height / videoHeight)
        let w = videoWidth * k, h = videoHeight * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

struct CountersBadge: View {
    let counters: Counters
    var showPassed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showPassed { row("Прошли", counters.passed) }
            row("Притормозили", counters.slowed)
            row("Посмотрели", counters.looked)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .frame(width: 140, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").bold()
        }
    }
}
