//
//  MarkupEditorView.swift
//  mantis
//
//  Разметка на кадре видео перед анализом:
//    • зона детекции — четырёхугольник: углы перетаскиваются, кнопка возвращает их в углы кадра;
//    • линия подсчёта — две перетаскиваемые точки, можно выключить совсем.
//

import AVFoundation
import SwiftUI

struct MarkupEditorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case zone = "Зона"
        case line = "Линия"
        case entrance = "Вход"
        var id: String { rawValue }
    }

    private enum Handle: Equatable {
        case zone(Int)
        case line(Int)
        case entrance(Int)
    }

    /// Видео, из которого берётся кадр для разметки (nil — кадр передан готовым в image).
    let url: URL?
    @Binding var markup: Markup
    /// Готовый кадр (например, с камеры).
    var image: CGImage? = nil
    var startTitle: String = "Анализировать"
    var startIcon: String = "play.fill"
    var onStart: () -> Void

    @State private var frame: CGImage?
    @State private var frameError: String?
    @State private var mode: Mode = .zone
    @State private var dragging: Handle?
    @State private var gestureStarted = false
    @State private var selectedVertex: Int?

    private let handleRadius: CGFloat = 11
    private let hitRadius: CGFloat = 30

    var body: some View {
        VStack(spacing: 18) {
            Picker("Режим", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
                .frame(maxWidth: .infinity, alignment: .leading)
                .themedCard(padding: 16)

            Button(action: onStart) {
                Label(startTitle, systemImage: startIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(Theme.background)
                    .background(Theme.moon, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .opacity(markup.zone.count < 3 ? 0.4 : 1)
            .disabled(markup.zone.count < 3)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 40)
        .task { await loadFrame() }
    }

    // MARK: - Кадр с разметкой

    private var canvas: some View {
        GeometryReader { geo in
            let imgW = Double(frame?.width ?? 9), imgH = Double(frame?.height ?? 16)
            // Отступ по краям, чтобы ручки в углах кадра были видны целиком
            let inset = handleRadius + 4
            let rect = OverlayView.fitRect(videoWidth: imgW, videoHeight: imgH,
                                           in: CGSize(width: max(geo.size.width - inset * 2, 1),
                                                      height: max(geo.size.height - inset * 2, 1)))
                .offsetBy(dx: inset, dy: inset)

            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface)
                        .frame(width: rect.width, height: rect.height)
                        .overlay {
                            if let frameError {
                                Text(frameError).font(.footnote).foregroundStyle(Theme.moonDim).padding()
                            } else {
                                ProgressView().tint(Theme.moon)
                            }
                        }
                        .offset(x: rect.minX, y: rect.minY)
                }

                Canvas { ctx, _ in
                    func map(_ p: Pt) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }

                    // затемнение вне зоны
                    var outside = Path(rect)
                    var zonePath = Path()
                    if let first = markup.zone.first {
                        zonePath.move(to: map(first))
                        for p in markup.zone.dropFirst() { zonePath.addLine(to: map(p)) }
                        zonePath.closeSubpath()
                    }
                    outside.addPath(zonePath)
                    ctx.fill(outside, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
                    ctx.fill(zonePath, with: .color(.cyan.opacity(0.12)))
                    ctx.stroke(zonePath, with: .color(.cyan.opacity(mode == .zone ? 0.95 : 0.5)), lineWidth: 2)

                    // линия
                    if markup.lineEnabled, markup.line.count == 2 {
                        var lp = Path()
                        lp.move(to: map(markup.line[0]))
                        lp.addLine(to: map(markup.line[1]))
                        ctx.stroke(lp, with: .color(.red.opacity(mode == .line ? 1 : 0.55)), lineWidth: 3)
                    }

                    // вход в магазин
                    if markup.entranceEnabled, markup.entrance.count == 2 {
                        var ep = Path()
                        ep.move(to: map(markup.entrance[0]))
                        ep.addLine(to: map(markup.entrance[1]))
                        ctx.stroke(ep, with: .color(.green.opacity(mode == .entrance ? 1 : 0.55)),
                                   style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    }

                    // ручки активного режима
                    if mode == .zone {
                        for (i, p) in markup.zone.enumerated() {
                            let c = map(p)
                            let r = CGRect(x: c.x - handleRadius, y: c.y - handleRadius,
                                           width: handleRadius * 2, height: handleRadius * 2)
                            ctx.fill(Path(ellipseIn: r), with: .color(selectedVertex == i ? .yellow : .cyan))
                            ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
                        }
                    } else if mode == .line, markup.lineEnabled {
                        for p in markup.line {
                            let c = map(p)
                            let r = CGRect(x: c.x - handleRadius, y: c.y - handleRadius,
                                           width: handleRadius * 2, height: handleRadius * 2)
                            ctx.fill(Path(ellipseIn: r), with: .color(.red))
                            ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
                        }
                    } else if mode == .entrance, markup.entranceEnabled {
                        for p in markup.entrance {
                            let c = map(p)
                            let r = CGRect(x: c.x - handleRadius, y: c.y - handleRadius,
                                           width: handleRadius * 2, height: handleRadius * 2)
                            ctx.fill(Path(ellipseIn: r), with: .color(.green))
                            ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onDrag(v, rect: rect) }
                    .onEnded { v in onDragEnd(v, rect: rect) }
            )
        }
    }

    // MARK: - Управление

    @ViewBuilder
    private var controls: some View {
        switch mode {
        case .zone:
            VStack(alignment: .leading, spacing: 14) {
                Text("Перетаскивайте углы зоны. Люди вне зоны не учитываются.")
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    markup.zone = Markup.fullFrame
                    selectedVertex = nil
                } label: {
                    Label("Вернуть точки в углы", systemImage: "arrow.up.left.and.arrow.down.right")
                        .chip()
                }
                .buttonStyle(.plain)
                .opacity(markup.isFullFrame ? 0.4 : 1)
                .disabled(markup.isFullFrame)
            }
        case .line:
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Считать проходы через линию", isOn: $markup.lineEnabled)
                    .tint(.red)
                    .foregroundStyle(Theme.moon)
                    .font(.subheadline.weight(.semibold))
                if markup.lineEnabled {
                    HStack(spacing: 10) {
                        Button { markup.line = Markup.verticalLine } label: {
                            Label("Вертикально", systemImage: "arrow.up.and.down").chip(fill: true)
                        }
                        Button { markup.line = Markup.horizontalLine } label: {
                            Label("Горизонтально", systemImage: "arrow.left.and.right").chip(fill: true)
                        }
                    }
                    .buttonStyle(.plain)
                    Text("Перетащите концы линии. «Прошёл» — пересёк линию.")
                        .font(.footnote)
                        .foregroundStyle(Theme.moonDim)
                } else {
                    Text("Линия выключена: анализируется всё видео, считаются люди в зоне, притормозившие и посмотревшие.")
                        .font(.footnote)
                        .foregroundStyle(Theme.moonDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .entrance:
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Считать вход в магазин", isOn: $markup.entranceEnabled)
                    .tint(.green)
                    .foregroundStyle(Theme.moon)
                    .font(.subheadline.weight(.semibold))
                Text(markup.entranceEnabled
                     ? "Поставьте зелёную линию на порог двери. Кто её пересёк — «вошёл»; появится воронка до входа."
                     : "Если в кадре видна дверь магазина, включите — получится воронка «посмотрели → вошли».")
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Жесты

    private func normalized(_ p: CGPoint, in rect: CGRect) -> Pt {
        Pt(min(max((p.x - rect.minX) / max(rect.width, 1), 0), 1),
           min(max((p.y - rect.minY) / max(rect.height, 1), 0), 1))
    }

    private func screen(_ p: Pt, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    private func nearestHandle(to loc: CGPoint, rect: CGRect) -> Handle? {
        var best: (Handle, CGFloat)?
        func consider(_ h: Handle, _ p: Pt) {
            let s = screen(p, in: rect)
            let d = hypot(s.x - loc.x, s.y - loc.y)
            if d <= hitRadius, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (h, d) }
        }
        switch mode {
        case .zone:
            for (i, p) in markup.zone.enumerated() { consider(.zone(i), p) }
        case .line:
            if markup.lineEnabled { for (i, p) in markup.line.enumerated() { consider(.line(i), p) } }
        case .entrance:
            if markup.entranceEnabled { for (i, p) in markup.entrance.enumerated() { consider(.entrance(i), p) } }
        }
        return best?.0
    }

    private func onDrag(_ v: DragGesture.Value, rect: CGRect) {
        if !gestureStarted {
            gestureStarted = true
            dragging = nearestHandle(to: v.startLocation, rect: rect)
            if case .zone(let i) = dragging { selectedVertex = i }
        }
        guard let h = dragging else { return }
        let p = normalized(v.location, in: rect)
        switch h {
        case .zone(let i) where i < markup.zone.count: markup.zone[i] = p
        case .line(let i) where i < markup.line.count: markup.line[i] = p
        case .entrance(let i) where i < markup.entrance.count: markup.entrance[i] = p
        default: break
        }
    }

    private func onDragEnd(_ v: DragGesture.Value, rect: CGRect) {
        defer {
            dragging = nil
            gestureStarted = false
        }
        let moved = hypot(v.translation.width, v.translation.height)
        if dragging == nil, moved < 8 {
            selectedVertex = nil
        }
    }

    // MARK: - Кадр видео

    private func loadFrame() async {
        guard frame == nil else { return }
        if let image {
            frame = image
            return
        }
        guard let url else { return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // видео с телефона — в правильной ориентации
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        do {
            let (image, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            frame = image
        } catch {
            do {
                let (image, _) = try await generator.image(at: .zero)
                frame = image
            } catch {
                frameError = "Не удалось показать кадр: \(error.localizedDescription)"
            }
        }
    }
}

private extension View {
    /// Вторичная кнопка-«таблетка» в цветах темы.
    func chip(fill: Bool = false) -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(Theme.moon)
            .padding(.horizontal, fill ? 10 : 14)
            .padding(.vertical, 10)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(Theme.surfaceHigh, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }
}
