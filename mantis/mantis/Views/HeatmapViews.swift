//
//  HeatmapViews.swift
//  mantis
//
//  Тепловые карты: «вид сверху» (в метрах) и «на кадре» (пятна поверх снимка),
//  слои (время, проход, медленно, остановки, взгляды), стрелки потока, подсказки,
//  информация по клетке, диапазон времени, калибровка, сравнение «до/после», экспорт PNG и PDF.
//

import AVFoundation
import Charts
import SwiftUI
import UIKit

// MARK: - Источник данных

/// Цифры для PDF-отчёта.
struct HeatReportData {
    var counters: Counters
    var seen: Int
    var extended: ExtendedMetrics?
    var lineEnabled: Bool
    var zoneIsFullFrame: Bool
}

/// Всё, что нужно экрану тепловой карты: сэмплы, размер кадра, фон и цифры для отчёта.
struct HeatSource {
    var title: String
    var samples: [HeatSample]
    var width: Double
    var height: Double
    var duration: Double
    var focalRatio: Double
    var isLive = false
    var videoURL: URL?
    /// Момент видео для фона «на кадре» — где меньше всего людей.
    var backgroundTime: Double = 0
    var still: CGImage?
    var report: HeatReportData

    var people: Int { Set(samples.map(\.trackId)).count }
}

extension HeatSource {
    init(result: AnalysisResult) {
        self.init(title: "Видео", samples: result.samples, width: result.width, height: result.height,
                  duration: result.duration, focalRatio: result.focalRatio, isLive: false,
                  videoURL: result.videoURL,
                  backgroundTime: result.frames.min(by: { $0.boxes.count < $1.boxes.count })?.time ?? 0,
                  still: nil,
                  report: HeatReportData(counters: result.counters, seen: result.extended.people,
                                         extended: result.extended, lineEnabled: result.line.count == 2,
                                         zoneIsFullFrame: result.isFullFrameZone))
    }
}

// MARK: - Палитра и отрисовка

enum HeatPalette {
    private static let stops: [(Double, Double, Double)] = [
        (0.10, 0.25, 0.65), (0.10, 0.70, 0.85), (0.95, 0.85, 0.20), (0.95, 0.45, 0.15), (0.90, 0.15, 0.20),
    ]

    static var colors: [Color] { stops.map { Color(red: $0.0, green: $0.1, blue: $0.2) } }

    /// Цвет по доле 0…1 (корень — чтобы слабые следы тоже были видны).
    static func color(_ v: Double) -> Color {
        let x = min(max(v, 0), 1).squareRoot() * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    /// Расходящаяся шкала для сравнения: −1 синий … 0 прозрачный … +1 красный.
    static func diverging(_ v: Double) -> Color {
        let c = min(max(v, -1), 1)
        let a = 0.15 + 0.8 * abs(c).squareRoot()
        return c >= 0 ? Color(red: 0.95, green: 0.30, blue: 0.20).opacity(a) : Color(red: 0.20, green: 0.55, blue: 1.0).opacity(a)
    }
}

enum HeatPaint {
    /// Размытые пятна по сетке «на кадре». rect — где кадр на экране.
    static func blobs(_ ctx: inout GraphicsContext, grid: HeatGrid, rect: CGRect, opacity: Double = 0.8) {
        let maxV = grid.maxValue
        guard maxV > 0, grid.width > 0 else { return }
        let k = rect.width / grid.width
        let cs = grid.cell * k
        ctx.drawLayer { outer in
            outer.clip(to: Path(rect))
            outer.drawLayer { layer in
                layer.addFilter(.blur(radius: max(2, cs * 0.55)))
                for i in grid.values.indices where grid.values[i] > 0 {
                    let v = grid.values[i] / maxV
                    let c = grid.center(col: i % grid.cols, row: i / grid.cols)
                    let p = CGPoint(x: rect.minX + c.0 * k, y: rect.minY + c.1 * k)
                    let r = cs * (0.55 + 0.35 * v.squareRoot())
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(HeatPalette.color(v).opacity(opacity * (0.35 + 0.65 * v.squareRoot()))))
                }
            }
        }
    }

    /// Значок в кружке (метки на карте).
    static func marker(_ ctx: inout GraphicsContext, at p: CGPoint, symbol: String, color: Color) {
        let r: CGFloat = 11
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(.white), lineWidth: 1.5)
        let icon = ctx.resolve(Text(Image(systemName: symbol)).font(.system(size: 11, weight: .bold)).foregroundColor(.white))
        ctx.draw(icon, at: p)
    }

    /// Стрелка от a к b с наконечником.
    static func arrow(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, width: CGFloat = 1.5) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let head = max(3, len * 0.38)
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        let ang: CGFloat = 0.45
        for s: CGFloat in [ang, -ang] {
            let cx = ux * cos(s) - uy * sin(s), cy = ux * sin(s) + uy * cos(s)
            p.move(to: b)
            p.addLine(to: CGPoint(x: b.x - cx * head, y: b.y - cy * head))
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// Число с запятой: 1,5
func heatNum(_ v: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
}

/// «≈ 4,5 м от камеры, 1,0 м левее»
func heatPlace(_ g: GroundPoint) -> String {
    var s = "≈ \(heatNum(g.z)) м от камеры"
    if abs(g.x) < 0.5 {
        s += ", по центру"
    } else {
        s += ", \(heatNum(abs(g.x))) м \(g.x < 0 ? "левее" : "правее")"
    }
    return s
}

func heatDirection(dx: Double, dz: Double) -> String {
    if abs(dz) >= abs(dx) { return dz < 0 ? "к камере" : "от камеры" }
    return dx > 0 ? "слева направо" : "справа налево"
}

// MARK: - Карта «вид сверху»

struct GroundHeatCanvas: View {
    let grid: HeatGrid
    let model: GroundModel
    var showPaths = false
    var showArrows = true
    var hints: HeatHints?
    var selected: Int?
    var onTap: ((Int?) -> Void)?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    guard let onTap else { return }
                    let x = grid.left + v.location.x / geo.size.width * grid.width
                    let z = grid.top - v.location.y / geo.size.height * grid.height
                    onTap(grid.cellIndex(x: x, y: z))
                })
        }
        .aspectRatio(CGFloat(grid.cols) / CGFloat(grid.rows), contentMode: .fit)
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let sx = size.width / grid.width, sy = size.height / grid.height
        let cw = size.width / CGFloat(grid.cols), ch = size.height / CGFloat(grid.rows)
        func pt(_ x: Double, _ z: Double) -> CGPoint { CGPoint(x: (x - grid.left) * sx, y: (grid.top - z) * sy) }

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.background.opacity(0.6)))

        // сетка расстояний
        let step = grid.height > 16 ? 5.0 : 2.0
        var z = step
        while z < grid.top {
            let y = (grid.top - z) * sy
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(Theme.stroke), lineWidth: 1)
            ctx.draw(Text("\(Int(z)) м").font(.caption2).foregroundColor(Theme.moonDim),
                     at: CGPoint(x: 4, y: y - 2), anchor: .bottomLeading)
            z += step
        }
        var axis = Path()
        axis.move(to: CGPoint(x: size.width / 2, y: 0))
        axis.addLine(to: CGPoint(x: size.width / 2, y: size.height))
        ctx.stroke(axis, with: .color(Theme.stroke), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // клетки
        let maxV = max(grid.maxValue, 1e-6)
        for i in grid.values.indices where grid.values[i] > 0 {
            let c = i % grid.cols, r = i / grid.cols
            let rect = CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch, width: cw + 0.5, height: ch + 0.5)
            ctx.fill(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2),
                     with: .color(HeatPalette.color(grid.values[i] / maxV).opacity(0.85)))
        }

        // траектории
        if showPaths {
            for path in grid.paths {
                guard let first = path.first else { continue }
                var p = Path()
                p.move(to: pt(first.x, first.z))
                for g in path.dropFirst() { p.addLine(to: pt(g.x, g.z)) }
                ctx.stroke(p, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
        }

        // стрелки потока: клетки объединяются в блоки, чтобы стрелки не были мельче ~20 pt
        if showArrows, !grid.flow.isEmpty {
            let block = max(1, Int((20 / max(min(cw, ch), 1)).rounded(.up)))
            var br = 0
            while br < grid.rows {
                var bc = 0
                while bc < grid.cols {
                    var dx = 0.0, dz = 0.0, n = 0
                    for r in br..<min(br + block, grid.rows) {
                        for c in bc..<min(bc + block, grid.cols) {
                            let f = grid.flow[r * grid.cols + c]
                            dx += f.dx
                            dz += f.dz
                            n += f.n
                        }
                    }
                    if n >= 3 {
                        let vx = dx / Double(n), vz = dz / Double(n)
                        let sp = (vx * vx + vz * vz).squareRoot()
                        if sp > 0.2 {
                            let w = CGFloat(min(block, grid.cols - bc)) * cw, h = CGFloat(min(block, grid.rows - br)) * ch
                            let center = CGPoint(x: CGFloat(bc) * cw + w / 2, y: CGFloat(br) * ch + h / 2)
                            let len = min(w, h) * 0.7
                            let ux = vx / sp, uy = -vz / sp
                            let a = CGPoint(x: center.x - ux * len / 2, y: center.y - uy * len / 2)
                            let b = CGPoint(x: center.x + ux * len / 2, y: center.y + uy * len / 2)
                            HeatPaint.arrow(&ctx, from: a, to: b, color: .white.opacity(0.85))
                        }
                    }
                    bc += block
                }
                br += block
            }
        }

        // выбранная клетка
        if let s = selected, s < grid.values.count {
            let rect = CGRect(x: CGFloat(s % grid.cols) * cw, y: CGFloat(s / grid.cols) * ch, width: cw, height: ch)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3), with: .color(.white), lineWidth: 2)
        }

        // метки
        if let b = hints?.busiest { HeatPaint.marker(&ctx, at: pt(b.x, b.z), symbol: "flame.fill", color: .orange) }
        if let i = hints?.interest { HeatPaint.marker(&ctx, at: pt(i.x, i.z), symbol: "eye.fill", color: Color(red: 0.85, green: 0.7, blue: 0.0)) }

        // камера и её поле зрения
        let cam = pt(0, 0)
        let tanHalf = model.width / 2 / max(model.focal, 1)
        var fov = Path()
        fov.move(to: cam)
        fov.addLine(to: pt(-grid.top * tanHalf, grid.top))
        fov.move(to: cam)
        fov.addLine(to: pt(grid.top * tanHalf, grid.top))
        ctx.stroke(fov, with: .color(Theme.moon.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        let icon = ctx.resolve(Text(Image(systemName: "video.fill")).font(.system(size: 14)).foregroundColor(Theme.moon))
        ctx.draw(icon, at: CGPoint(x: cam.x, y: cam.y - 10))
    }
}

// MARK: - Карта «на кадре»

struct FrameHeatCanvas: View {
    let grid: HeatGrid?
    let image: CGImage?
    let width: Double
    let height: Double
    var selected: Int?
    var onTap: ((Int?) -> Void)?

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    guard let onTap, let grid else { return }
                    let rect = OverlayView.fitRect(videoWidth: width, videoHeight: height, in: geo.size)
                    guard rect.width > 0 else { return }
                    let x = (v.location.x - rect.minX) / rect.width * width
                    let y = (v.location.y - rect.minY) / rect.height * height
                    onTap(grid.cellIndex(x: x, y: y))
                })
        }
        .aspectRatio(width / max(height, 1), contentMode: .fit)
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let rect = OverlayView.fitRect(videoWidth: width, videoHeight: height, in: size)
        if let image {
            ctx.draw(ctx.resolve(Image(decorative: image, scale: 1)), in: rect)
            ctx.fill(Path(rect), with: .color(.black.opacity(0.25)))
        } else {
            ctx.fill(Path(rect), with: .color(Theme.surfaceHigh))
        }
        guard let grid else { return }
        HeatPaint.blobs(&ctx, grid: grid, rect: rect)
        let k = rect.width / max(grid.width, 1)
        if let s = selected, s < grid.values.count {
            let c = grid.center(col: s % grid.cols, row: s / grid.cols)
            let half = grid.cell * k / 2
            let r = CGRect(x: rect.minX + c.0 * k - half, y: rect.minY + c.1 * k - half, width: 2 * half, height: 2 * half)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 2)
        }
        if let h = grid.hottest {
            let c = grid.center(col: h % grid.cols, row: h / grid.cols)
            HeatPaint.marker(&ctx, at: CGPoint(x: rect.minX + c.0 * k, y: rect.minY + c.1 * k), symbol: "flame.fill", color: .orange)
        }
    }
}

// MARK: - Построение карт в фоне

nonisolated struct HeatBuilt: Sendable {
    var grid: HeatGrid?
    var hints: HeatHints
}

nonisolated enum HeatScreenBuilder {
    static func build(samples: [HeatSample], frameMode: Bool, layer: HeatLayer, range: ClosedRange<Double>?,
                      model: GroundModel) -> HeatBuilt {
        let grid = frameMode
            ? HeatBuilder.frame(samples, layer: layer, range: range, width: model.width, height: model.height)
            : HeatBuilder.ground(samples, layer: layer, range: range, model: model)
        return HeatBuilt(grid: grid, hints: HeatBuilder.hints(samples, range: range, model: model))
    }
}

// MARK: - Экран тепловой карты

struct HeatmapScreen: View {
    let source: HeatSource

    enum Mode: String, CaseIterable, Identifiable {
        case ground, frame
        var id: String { rawValue }
        var title: String { self == .ground ? "Вид сверху" : "На кадре" }
    }

    enum LiveWindow: String, CaseIterable, Identifiable {
        case last5, last15, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .last5: return "5 мин"
            case .last15: return "15 мин"
            case .all: return "Вся сессия"
            }
        }
        var seconds: Double? {
            switch self {
            case .last5: return 300
            case .last15: return 900
            case .all: return nil
            }
        }
    }

    private struct BuildKey: Equatable {
        var frame: Bool
        var layer: HeatLayer
        var lo: Double
        var hi: Double
        var scale: Double
        var count: Int
        var lastT: Double
    }

    @AppStorage(SettingsKeys.heatScale) private var heatScale = 1.0

    @State private var mode: Mode = .ground
    @State private var layer: HeatLayer = .time
    @State private var showPaths = false
    @State private var showArrows = true
    @State private var selected: Int?
    @State private var lo: Double = 0
    @State private var hi: Double
    @State private var window: LiveWindow = .all
    @State private var built: HeatBuilt?
    @State private var builtKey: BuildKey?
    @State private var background: CGImage?
    @State private var shareFile: ShareFile?
    @State private var showSave = false
    @State private var saveName = ""
    @State private var toast: String?

    init(source: HeatSource) {
        self.source = source
        _hi = State(initialValue: source.duration)
    }

    private var model: GroundModel {
        GroundModel(width: source.width, height: source.height, focalRatio: source.focalRatio, scale: heatScale)
    }

    private var range: ClosedRange<Double>? {
        if source.isLive {
            guard let w = window.seconds, source.duration > w else { return nil }
            return (source.duration - w)...source.duration
        }
        if lo <= 0.05 && hi >= source.duration - 0.05 { return nil }
        return lo...max(hi, lo)
    }

    private var key: BuildKey {
        BuildKey(frame: mode == .frame, layer: layer, lo: range?.lowerBound ?? -1, hi: range?.upperBound ?? -1,
                 scale: heatScale, count: source.samples.count, lastT: source.samples.last?.t ?? 0)
    }

    private var bgImage: CGImage? { source.still ?? background }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Вид", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                layerChips

                mapCard

                legend

                if let s = selected, let grid = built?.grid, s < grid.info.count {
                    cellInfo(grid: grid, index: s)
                }

                if mode == .ground {
                    HStack(spacing: 8) {
                        HeatChip(title: "Стрелки потока", icon: "arrow.up.right", on: showArrows) { showArrows.toggle() }
                        HeatChip(title: "Траектории", icon: "point.topleft.down.to.point.bottomright.curvepath", on: showPaths) { showPaths.toggle() }
                    }
                }

                timeRange

                if let h = built?.hints { hintsCard(h) }

                actions

                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .padding(.bottom, 20)
        }
        .themedScreen()
        .navigationTitle("Тепловая карта")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .task(id: key) { await rebuild() }
        .task { await loadBackground() }
        .sheet(item: $shareFile) { f in
            ActivityView(items: [f.url]).ignoresSafeArea()
        }
        .alert("Сохранить для сравнения", isPresented: $showSave) {
            TextField("Название", text: $saveName)
            Button("Сохранить") { saveSnapshot() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Например: «до смены витрины». Потом его можно сравнить с другим видео.")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.moon, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Части экрана

    private var layerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HeatLayer.allCases) { l in
                    HeatChip(title: l.title, icon: icon(l), on: layer == l) { layer = l }
                }
            }
        }
    }

    private func icon(_ l: HeatLayer) -> String {
        switch l {
        case .time: return "clock.fill"
        case .pass: return "figure.walk"
        case .slow: return "tortoise.fill"
        case .stops: return "hand.raised.fill"
        case .looks: return "eye.fill"
        }
    }

    @ViewBuilder
    private var mapCard: some View {
        Group {
            if mode == .frame {
                FrameHeatCanvas(grid: built?.grid, image: bgImage, width: source.width, height: source.height,
                                selected: selected) { selected = $0 }
                    .frame(maxHeight: 520)
            } else if let grid = built?.grid {
                GroundHeatCanvas(grid: grid, model: model, showPaths: showPaths, showArrows: showArrows,
                                 hints: built?.hints, selected: selected) { selected = $0 }
                    .frame(maxHeight: 520)
            } else if built != nil {
                ContentUnavailableView("Нет данных", systemImage: "map",
                                       description: Text("В зоне детекции не было людей за этот период"))
            } else {
                ProgressView().tint(Theme.moon).frame(height: 240)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("меньше").font(.caption).foregroundStyle(Theme.moonDim)
                LinearGradient(colors: HeatPalette.colors, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8)
                    .clipShape(Capsule())
                Text("больше").font(.caption).foregroundStyle(Theme.moonDim)
            }
            Text("\(layer.title): \(layer.subtitle). Нажмите на место карты — покажу, что там было.")
                .font(.caption)
                .foregroundStyle(Theme.moonDim)
        }
    }

    private func cellInfo(grid: HeatGrid, index s: Int) -> some View {
        let info = grid.info[s]
        let c = grid.center(col: s % grid.cols, row: s / grid.cols)
        var flowText: String?
        if grid.isGround, s < grid.flow.count, grid.flow[s].n >= 2 {
            let f = grid.flow[s]
            let vx = f.dx / Double(f.n), vz = f.dz / Double(f.n)
            let sp = (vx * vx + vz * vz).squareRoot()
            flowText = sp > 0.2 ? "\(heatDirection(dx: vx, dz: vz)), \(heatNum(sp)) м/с" : "почти стоят"
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(grid.isGround ? heatPlace(GroundPoint(x: c.0, z: c.1)) : "Выбранное место на кадре",
                      systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.moon)
                Spacer()
                Button { selected = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.moonDim)
                }
            }
            HStack(spacing: 0) {
                infoCell("\(info.people)", "человек")
                infoCell("\(heatNum(info.seconds))", "секунд")
                infoCell("\(info.lookers)", "смотрели")
                infoCell("\(info.stoppers)", "стояли")
            }
            if let flowText {
                Text("Движение: \(flowText)").font(.caption).foregroundStyle(Theme.moonDim)
            }
        }
        .themedCard(padding: 12)
    }

    private func infoCell(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(Theme.moon)
            Text(title).font(.caption2).foregroundStyle(Theme.moonDim)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var timeRange: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Период")
            if source.isLive {
                Picker("Период", selection: $window) {
                    ForEach(LiveWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } else if source.duration > 2 {
                VStack(spacing: 6) {
                    HStack {
                        Text("\(ResultView.formatTime(lo)) – \(ResultView.formatTime(hi))")
                            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.moon)
                        Spacer()
                        if range != nil {
                            Button("Всё видео") {
                                lo = 0
                                hi = source.duration
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                    HStack {
                        Text("с").font(.caption).foregroundStyle(Theme.moonDim).frame(width: 22, alignment: .leading)
                        Slider(value: $lo, in: 0...source.duration, step: 1)
                    }
                    HStack {
                        Text("до").font(.caption).foregroundStyle(Theme.moonDim).frame(width: 22, alignment: .leading)
                        Slider(value: $hi, in: 0...source.duration, step: 1)
                    }
                }
                .tint(Theme.moon)
                .themedCard(padding: 12)
                .onChange(of: lo) { _, v in if hi < v + 1 { hi = min(source.duration, v + 1) } }
                .onChange(of: hi) { _, v in if lo > v - 1 { lo = max(0, v - 1) } }
            }
        }
    }

    private func hintsCard(_ h: HeatHints) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Подсказки")
            MetricList {
                if let b = h.busiest {
                    MetricRow(icon: "flame.fill", tint: .orange, title: "Самое оживлённое место",
                              hint: heatPlace(b), value: "")
                }
                if let i = h.interest {
                    MetricRow(icon: "eye.fill", tint: PersonState.looked.color, title: "Точка интереса",
                              hint: "отсюда чаще всего смотрят на витрину: \(heatPlace(i))", value: "")
                }
                if let d = h.lookDistance {
                    MetricRow(icon: "ruler", tint: .cyan, title: "Смотрят с расстояния",
                              hint: "половина взглядов в этом диапазоне", value: "\(heatNum(d.lo)) – \(heatNum(d.hi)) м")
                }
                if let f = h.mainFlow {
                    MetricRow(icon: "arrow.left.arrow.right", tint: Theme.moon, title: "Основной поток",
                              hint: "куда идёт большинство", value: f)
                }
                if h.busiest == nil && h.mainFlow == nil {
                    MetricRow(icon: "info.circle", tint: Theme.moonDim, title: "Мало данных", value: "")
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Действия")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                NavigationLink {
                    HeatCalibrationView(image: bgImage, width: source.width, height: source.height,
                                        samples: source.samples, focalRatio: source.focalRatio)
                } label: {
                    actionLabel("Калибровка", "ruler")
                }
                NavigationLink {
                    HeatCompareView(currentMaker: { makeComparison(name: "Сейчас") })
                } label: {
                    actionLabel("Сравнить", "square.split.2x1")
                }
                Button {
                    saveName = defaultName
                    showSave = true
                } label: {
                    actionLabel("Сохранить", "square.and.arrow.down")
                }
                Button { exportPNG() } label: {
                    actionLabel("Картинка PNG", "photo")
                }
            }
            Button { exportPDF() } label: {
                actionLabel("PDF-отчёт", "doc.richtext")
            }
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(Theme.moon)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12))
    }

    private var footnote: String {
        var s = "Учтены только люди в зоне детекции. Расстояния оценены по росту человека (~1,7 м) и объективу"
        s += source.isLive ? " (камера приложения, 1×)" : ""
        s += heatScale != 1 ? ", с калибровкой ×\(heatNum(heatScale, 2))." : " — для точности сделайте калибровку."
        return s
    }

    private var defaultName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM HH:mm"
        return "\(source.title) \(f.string(from: Date()))"
    }

    // MARK: Логика

    private func rebuild() async {
        let k = key
        let samples = source.samples, frame = mode == .frame, layer = self.layer, range = self.range, model = self.model
        let result = await Task.detached(priority: .userInitiated) {
            HeatScreenBuilder.build(samples: samples, frameMode: frame, layer: layer, range: range, model: model)
        }.value
        guard !Task.isCancelled else { return }
        if builtKey.map({ $0.frame != k.frame || $0.lo != k.lo || $0.hi != k.hi || $0.scale != k.scale }) ?? false {
            selected = nil   // сетка поменялась — старая клетка уже не та
        }
        built = result
        builtKey = k
    }

    private func loadBackground() async {
        guard source.still == nil, background == nil, let url = source.videoURL else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let r = try? await generator.image(at: CMTime(seconds: source.backgroundTime, preferredTimescale: 600)) {
            background = r.image
        }
    }

    private func makeComparison(name: String) -> HeatComparison? {
        let duration = source.duration
        return HeatComparison.make(name: name, samples: source.samples, duration: duration, people: source.people, model: model)
    }

    private func saveSnapshot() {
        let name = saveName.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : saveName
        if let item = makeComparison(name: name) {
            HeatStore.add(item)
            flash("Сохранено: \(name)")
        } else {
            flash("Нет данных для сохранения")
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }

    private func exportPNG() {
        guard let built else { return }
        let card = HeatExportCard(title: "Тепловая карта · \(layer.title)", subtitle: periodText,
                                  mode: mode, grid: built.grid, hints: built.hints, model: model, image: bgImage,
                                  showArrows: showArrows, showPaths: showPaths)
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Mantis — тепловая карта.png")
        do {
            try data.write(to: url, options: .atomic)
            shareFile = ShareFile(url: url)
        } catch {
            flash("Не удалось сохранить картинку")
        }
    }

    private func exportPDF() {
        var src = source
        src.still = bgImage
        if let url = HeatReport.make(source: src, range: range, period: periodText, scale: heatScale) {
            shareFile = ShareFile(url: url)
        } else {
            flash("Не удалось создать PDF")
        }
    }

    private var periodText: String {
        if source.isLive {
            return window == .all ? "вся сессия, \(ResultView.formatTime(source.duration))" : "последние \(window.title)"
        }
        guard let r = range else { return "всё видео, \(ResultView.formatTime(source.duration))" }
        return "фрагмент \(ResultView.formatTime(r.lowerBound)) – \(ResultView.formatTime(r.upperBound))"
    }
}

/// Кнопка-переключатель в виде «таблетки».
struct HeatChip: View {
    let title: String
    let icon: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(on ? Theme.background : Theme.moon)
                .background(on ? Theme.moon : Theme.surfaceHigh, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Ссылка на экран тепловой карты (в результате анализа видео).
struct HeatmapLink: View {
    let source: HeatSource

    var body: some View {
        NavigationLink {
            HeatmapScreen(source: source)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "map.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Тепловая карта").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                    Text("вид сверху и на кадре, слои, сравнение, PDF").font(.caption).foregroundStyle(Theme.moonDim)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.moonDim)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(source.samples.isEmpty)
        .opacity(source.samples.isEmpty ? 0.5 : 1)
    }
}

// MARK: - Калибровка

struct HeatCalibrationView: View {
    let image: CGImage?
    let width: Double
    let height: Double
    let samples: [HeatSample]
    let focalRatio: Double

    @AppStorage(SettingsKeys.heatScale) private var heatScale = 1.0
    @Environment(\.dismiss) private var dismiss

    /// Концы отрезка в долях кадра.
    @State private var a = Pt(0.3, 0.8)
    @State private var b = Pt(0.7, 0.8)
    @State private var meters = "2"
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Отметьте на кадре два края предмета известной ширины на уровне тротуара — дверь, плитку, разметку, бордюр — и введите его длину.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.moonDim)
                    .fixedSize(horizontal: false, vertical: true)

                GeometryReader { geo in
                    let rect = OverlayView.fitRect(videoWidth: width, videoHeight: height, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in
                            if let image {
                                ctx.draw(ctx.resolve(Image(decorative: image, scale: 1)), in: rect)
                            } else {
                                ctx.fill(Path(rect), with: .color(Theme.surfaceHigh))
                            }
                            let pa = CGPoint(x: rect.minX + a.x * rect.width, y: rect.minY + a.y * rect.height)
                            let pb = CGPoint(x: rect.minX + b.x * rect.width, y: rect.minY + b.y * rect.height)
                            var p = Path()
                            p.move(to: pa)
                            p.addLine(to: pb)
                            ctx.stroke(p, with: .color(.black.opacity(0.6)), lineWidth: 5)
                            ctx.stroke(p, with: .color(.yellow), lineWidth: 2.5)
                            let label = ctx.resolve(Text("\(meters) м").font(.caption.bold()).foregroundColor(.yellow))
                            ctx.draw(label, at: CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2 - 14))
                        }
                        handle($a, rect: rect)
                        handle($b, rect: rect)
                    }
                }
                .aspectRatio(width / max(height, 1), contentMode: .fit)
                .frame(maxHeight: 480)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("Длина, м").foregroundStyle(Theme.moon)
                    Spacer()
                    TextField("2", text: $meters)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .foregroundStyle(Theme.moon)
                }
                .themedCard(padding: 12)

                Button { apply() } label: {
                    Label("Применить", systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(Theme.background)
                        .background(Theme.moon, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                if let message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }

                HStack {
                    Text("Сейчас: \(heatScale == 1 ? "без калибровки" : "масштаб ×\(heatNum(heatScale, 2))")")
                        .font(.footnote).foregroundStyle(Theme.moonDim)
                    Spacer()
                    if heatScale != 1 {
                        Button("Сбросить") { heatScale = 1 }
                            .font(.footnote.weight(.semibold))
                    }
                }

                Text("Объектив видео задаётся в Настройках до анализа (сейчас фокусное \(heatNum(focalRatio, 2)) от длинной стороны кадра). Калибровка уточняет расстояния и скорость на картах и в «Поведении».")
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .themedScreen()
        .navigationTitle("Калибровка")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
    }

    private func handle(_ p: Binding<Pt>, rect: CGRect) -> some View {
        Circle()
            .fill(.yellow)
            .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 2))
            .frame(width: 26, height: 26)
            .position(x: rect.minX + p.wrappedValue.x * rect.width, y: rect.minY + p.wrappedValue.y * rect.height)
            .gesture(DragGesture().onChanged { v in
                guard rect.width > 0 else { return }
                p.wrappedValue = Pt(min(max((v.location.x - rect.minX) / rect.width, 0), 1),
                                    min(max((v.location.y - rect.minY) / rect.height, 0), 1))
            })
    }

    private func apply() {
        guard let m = Double(meters.replacingOccurrences(of: ",", with: ".")), m > 0 else {
            message = "Введите длину в метрах"
            return
        }
        let pa = Pt(a.x * width, a.y * height), pb = Pt(b.x * width, b.y * height)
        guard let s = HeatBuilder.scale(referenceA: pa, referenceB: pb, meters: m, samples: samples) else {
            message = "Недостаточно данных: нужны люди в кадре на разном расстоянии"
            return
        }
        guard s > 0.2, s < 5 else {
            message = "Получился странный масштаб ×\(heatNum(s, 2)) — проверьте точки и длину"
            return
        }
        heatScale = s
        message = nil
        dismiss()
    }
}

// MARK: - Сравнение «до / после»

struct HeatCompareView: View {
    let currentMaker: () -> HeatComparison?

    @State private var current: HeatComparison?
    @State private var saved: [HeatComparison] = []
    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var layer: HeatLayer = .time
    @State private var loaded = false

    private var options: [HeatComparison] { (current.map { [$0] } ?? []) + saved }
    private func item(_ id: UUID?) -> HeatComparison? { options.first { $0.id == id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if options.count < 2 {
                    ContentUnavailableView("Нужно два снимка", systemImage: "square.split.2x1",
                                           description: Text("Нажмите «Сохранить» на тепловой карте одного видео (например, до смены витрины), затем откройте сравнение на другом."))
                } else {
                    pickers
                    Picker("Слой", selection: $layer) {
                        Text("Время").tag(HeatLayer.time)
                        Text("Взгляды").tag(HeatLayer.looks)
                    }
                    .pickerStyle(.segmented)

                    if let a = item(beforeID), let b = item(afterID) {
                        DiffCanvas(before: a.values(layer), after: b.values(layer))
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 460)
                            .padding(10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                        HStack(spacing: 8) {
                            Circle().fill(PeopleColors.less).frame(width: 10, height: 10)
                            Text("стало меньше").font(.caption).foregroundStyle(Theme.moonDim)
                            Spacer()
                            Circle().fill(PeopleColors.more).frame(width: 10, height: 10)
                            Text("стало больше").font(.caption).foregroundStyle(Theme.moonDim)
                        }
                        summary(a, b)
                    }
                }

                if !saved.isEmpty { savedList }
            }
            .padding()
        }
        .themedScreen()
        .navigationTitle("Сравнение")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            current = currentMaker()
            saved = HeatStore.load()
            afterID = options.first?.id
            beforeID = options.dropFirst().first?.id
        }
    }

    private var pickers: some View {
        VStack(spacing: 0) {
            pickerRow("До", selection: $beforeID)
            Divider().overlay(Theme.stroke)
            pickerRow("После", selection: $afterID)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
    }

    private func pickerRow(_ title: String, selection: Binding<UUID?>) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options) { o in Text(o.name).tag(Optional(o.id)) }
            }
            .tint(Theme.moon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func summary(_ a: HeatComparison, _ b: HeatComparison) -> some View {
        let pa = a.duration > 0 ? Double(a.people) / a.duration * 60 : 0
        let pb = b.duration > 0 ? Double(b.people) / b.duration * 60 : 0
        let ta = a.time.reduce(0, +), tb = b.time.reduce(0, +)
        let la = a.looks.reduce(0, +), lb = b.looks.reduce(0, +)
        return MetricList {
            MetricRow(icon: "person.2.fill", tint: Theme.moon, title: "Людей в минуту",
                      hint: "\(heatNum(pa)) → \(heatNum(pb))", value: change(pa, pb))
            MetricRow(icon: "clock.fill", tint: .orange, title: "Время в зоне",
                      hint: "чел·с в минуту: \(heatNum(ta, 0)) → \(heatNum(tb, 0))", value: change(ta, tb))
            MetricRow(icon: "eye.fill", tint: PersonState.looked.color, title: "Взгляды на витрину",
                      hint: "чел·с в минуту: \(heatNum(la, 0)) → \(heatNum(lb, 0))", value: change(la, lb))
        }
    }

    private func change(_ a: Double, _ b: Double) -> String {
        guard a > 0 else { return b > 0 ? "новое" : "—" }
        let p = (b - a) / a * 100
        return (p >= 0 ? "+" : "−") + "\(Int(abs(p).rounded()))%"
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Сохранённые снимки")
            MetricList {
                ForEach(saved) { s in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                            Text("\(s.people) чел. · \(ResultView.formatTime(s.duration)) · \(s.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(Theme.moonDim)
                        }
                        Spacer()
                        Button {
                            HeatStore.delete(s.id)
                            saved = HeatStore.load()
                            if item(beforeID) == nil { beforeID = options.first { $0.id != afterID }?.id }
                            if item(afterID) == nil { afterID = options.first { $0.id != beforeID }?.id }
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                }
            }
        }
    }
}

enum PeopleColors {
    static let more = Color(red: 0.95, green: 0.30, blue: 0.20)
    static let less = Color(red: 0.20, green: 0.55, blue: 1.0)
}

/// Карта разницы на общей сетке HeatBuilder.fixedGround.
struct DiffCanvas: View {
    let before: [Double]
    let after: [Double]

    private var cols: Int { Int(2 * HeatBuilder.fixedGround.halfWidth / HeatBuilder.fixedGround.cell) }
    private var rows: Int { Int(HeatBuilder.fixedGround.zMax / HeatBuilder.fixedGround.cell) }

    var body: some View {
        Canvas { ctx, size in
            let n = min(before.count, after.count, cols * rows)
            let cw = size.width / CGFloat(cols), ch = size.height / CGFloat(rows)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.background.opacity(0.6)))
            var maxAbs = 0.0
            for i in 0..<n { maxAbs = max(maxAbs, abs(after[i] - before[i])) }
            if maxAbs > 0 {
                for i in 0..<n {
                    let d = (after[i] - before[i]) / maxAbs
                    guard abs(d) > 0.03 else { continue }
                    let rect = CGRect(x: CGFloat(i % cols) * cw, y: CGFloat(i / cols) * ch, width: cw, height: ch)
                    ctx.fill(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(HeatPalette.diverging(d)))
                }
            }
            let zMax = HeatBuilder.fixedGround.zMax
            for z in stride(from: 5.0, to: zMax, by: 5.0) {
                let y = (zMax - z) / zMax * size.height
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(Theme.stroke), lineWidth: 1)
                ctx.draw(Text("\(Int(z)) м").font(.caption2).foregroundColor(Theme.moonDim),
                         at: CGPoint(x: 4, y: y - 2), anchor: .bottomLeading)
            }
            let icon = ctx.resolve(Text(Image(systemName: "video.fill")).font(.system(size: 14)).foregroundColor(Theme.moon))
            ctx.draw(icon, at: CGPoint(x: size.width / 2, y: size.height - 10))
        }
        .aspectRatio(CGFloat(cols) / CGFloat(rows), contentMode: .fit)
    }
}

// MARK: - Экспорт

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Карточка для PNG: заголовок, карта, шкала и подсказки. Фиксированная ширина.
struct HeatExportCard: View {
    let title: String
    let subtitle: String
    let mode: HeatmapScreen.Mode
    let grid: HeatGrid?
    let hints: HeatHints
    let model: GroundModel
    let image: CGImage?
    var showArrows = true
    var showPaths = false

    private let width: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image("Logo").resizable().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Theme.moon)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.moonDim)
                }
            }
            map
            HStack(spacing: 8) {
                Text("меньше").font(.caption).foregroundStyle(Theme.moonDim)
                LinearGradient(colors: HeatPalette.colors, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8).clipShape(Capsule())
                Text("больше").font(.caption).foregroundStyle(Theme.moonDim)
            }
            HeatHintsText(hints: hints)
        }
        .padding(20)
        .frame(width: width)
        .background(Theme.background)
    }

    @ViewBuilder
    private var map: some View {
        let inner = width - 40
        if mode == .frame {
            let h = min(inner * model.height / max(model.width, 1), 700)
            let w = h * model.width / max(model.height, 1)
            FrameHeatCanvasStatic(grid: grid, image: image, width: model.width, height: model.height)
                .frame(width: w, height: h)
                .frame(maxWidth: .infinity)
        } else if let grid {
            let h = min(inner * CGFloat(grid.rows) / CGFloat(grid.cols), 700)
            let w = h * CGFloat(grid.cols) / CGFloat(grid.rows)
            GroundHeatCanvasStatic(grid: grid, model: model, showPaths: showPaths, showArrows: showArrows, hints: hints)
                .frame(width: w, height: h)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Те же карты без жестов и GeometryReader — для ImageRenderer.
struct GroundHeatCanvasStatic: View {
    let grid: HeatGrid
    let model: GroundModel
    var showPaths = false
    var showArrows = true
    var hints: HeatHints?

    var body: some View {
        let painter = GroundHeatCanvas(grid: grid, model: model, showPaths: showPaths, showArrows: showArrows, hints: hints)
        Canvas { ctx, size in painter.draw(&ctx, size: size) }
    }
}

struct FrameHeatCanvasStatic: View {
    let grid: HeatGrid?
    let image: CGImage?
    let width: Double
    let height: Double

    var body: some View {
        let painter = FrameHeatCanvas(grid: grid, image: image, width: width, height: height)
        Canvas { ctx, size in painter.draw(&ctx, size: size) }
    }
}

/// Подсказки текстом (для экспорта).
struct HeatHintsText: View {
    let hints: HeatHints

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let b = hints.busiest { line("flame.fill", .orange, "Самое оживлённое место: \(heatPlace(b))") }
            if let i = hints.interest { line("eye.fill", PersonState.looked.color, "Точка интереса: \(heatPlace(i))") }
            if let d = hints.lookDistance { line("ruler", .cyan, "Смотрят с \(heatNum(d.lo)) – \(heatNum(d.hi)) м") }
            if let f = hints.mainFlow { line("arrow.left.arrow.right", Theme.moon, "Основной поток: \(f)") }
        }
    }

    private func line(_ icon: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            Text(text).font(.footnote).foregroundStyle(Theme.moon)
        }
    }
}

/// Страницы PDF-отчёта.
struct HeatReportPages {
    let source: HeatSource
    let period: String
    let ground: HeatGrid?
    let looks: HeatGrid?
    let frame: HeatGrid?
    let hints: HeatHints
    let model: GroundModel
    let image: CGImage?
    let speedScale: Double
    /// Результат анализа видео — для страницы с графиком и событиями.
    var timeline: AnalysisResult?

    static let pageWidth: CGFloat = 595

    var pages: [AnyView] {
        var out: [AnyView] = [AnyView(page1)]
        if let ext = source.report.extended {
            out.append(AnyView(page(FlowList(m: ext))))
        }
        if let timeline {
            out.append(AnyView(page(timelinePage(timeline))))
        }
        if !source.samples.isEmpty {
            out.append(AnyView(page(heatPage)))
        }
        return out
    }

    @ViewBuilder
    private func timelinePage(_ r: AnalysisResult) -> some View {
        let series = r.timelineSeries
        SectionHeader(title: "Накопление по времени")
        Chart {
            TimelineLines(series: series, duration: r.duration)
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .themedChartAxes()
        .chartLegend(position: .bottom)
        .frame(height: 260)
        if !r.events.isEmpty {
            SectionHeader(title: "События", subtitle: r.events.count > 40 ? "первые 40 из \(r.events.count)" : nil)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(r.events.prefix(40).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 10) {
                        Text(ResultView.formatTime(e.t)).monospacedDigit().foregroundStyle(Theme.moonDim)
                            .frame(width: 44, alignment: .leading)
                        Text("#\(r.number(e.trackId))").bold().foregroundStyle(Theme.moon)
                        Text(e.kind.title + (e.kind == .passed ? (e.direction == "forward" ? " →" : " ←") : ""))
                            .foregroundStyle(Theme.moon)
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private func page<Content: View>(_ content: Content) -> some View {
        VStack(alignment: .leading, spacing: 18) { content }
            .padding(28)
            .frame(width: Self.pageWidth, alignment: .topLeading)
            .background(Theme.background)
            .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo").resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mantis · аналитика витрины").font(.title3.bold()).foregroundStyle(Theme.moon)
                Text("\(source.title) · \(period) · \(Date().formatted(date: .long, time: .shortened))")
                    .font(.caption).foregroundStyle(Theme.moonDim)
            }
        }
    }

    private var page1: some View {
        page(Group {
            header
            stats
            if let ext = source.report.extended {
                ScoreCard(score: ShowcaseScore.from(ext, counters: source.report.counters, people: source.report.seen))
            }
            MoneyCard(estimate: MoneyEstimate.compute(profile: AccountModel.shared.profile, people: source.report.seen,
                                                      looked: source.report.counters.looked,
                                                      entered: source.report.extended?.entered, duration: source.duration),
                      profile: AccountModel.shared.profile, editable: false)
            if let ext = source.report.extended {
                BehaviorList(m: ext, speedScale: speedScale)
                FunnelView(m: ext, slowed: source.report.counters.slowed)
            }
        })
    }

    private var stats: some View {
        let r = source.report
        return HStack(spacing: 10) {
            stat(r.zoneIsFullFrame ? "В кадре" : "В зоне", "\(r.seen)", Theme.moon)
            if r.lineEnabled { stat("Прошли", "\(r.counters.passed)", Theme.moon) }
            stat("Притормозили", "\(r.counters.slowed)", PersonState.slowed.color)
            stat("Посмотрели", "\(r.counters.looked)", PersonState.looked.color)
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.moonDim)
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(padding: 10)
    }

    @ViewBuilder
    private var heatPage: some View {
        SectionHeader(title: "Тепловые карты", subtitle: "вид сверху: камера внизу по центру, расстояния примерные")
        HStack(alignment: .top, spacing: 14) {
            mapBox("Время", ground)
            mapBox("Взгляды", looks)
        }
        if let frame {
            VStack(alignment: .leading, spacing: 6) {
                Text("На кадре").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                let h: CGFloat = 300
                let w = h * model.width / max(model.height, 1)
                FrameHeatCanvasStatic(grid: frame, image: image, width: model.width, height: model.height)
                    .frame(width: min(w, Self.pageWidth - 56), height: h)
            }
        }
        SectionHeader(title: "Подсказки")
        HeatHintsText(hints: hints)
    }

    @ViewBuilder
    private func mapBox(_ title: String, _ grid: HeatGrid?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
            if let grid {
                let w: CGFloat = (Self.pageWidth - 56 - 14) / 2
                let h = min(w * CGFloat(grid.rows) / CGFloat(grid.cols), 340)
                GroundHeatCanvasStatic(grid: grid, model: model, showArrows: title == "Время",
                                       hints: title == "Время" ? hints : nil)
                    .frame(width: h * CGFloat(grid.cols) / CGFloat(grid.rows), height: h)
            } else {
                Text("нет данных").font(.caption).foregroundStyle(Theme.moonDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum HeatReport {
    /// Полный PDF-отчёт: счётчики, поведение, воронка, поток, график, события, тепловые карты.
    static func make(source: HeatSource, range: ClosedRange<Double>?, period: String, scale: Double,
                     timeline: AnalysisResult? = nil) -> URL? {
        let m = GroundModel(width: source.width, height: source.height, focalRatio: source.focalRatio, scale: scale)
        let pages = HeatReportPages(
            source: source, period: period,
            ground: HeatBuilder.ground(source.samples, layer: .time, range: range, model: m),
            looks: HeatBuilder.ground(source.samples, layer: .looks, range: range, model: m),
            frame: HeatBuilder.frame(source.samples, layer: .time, range: range, width: source.width, height: source.height),
            hints: HeatBuilder.hints(source.samples, range: range, model: m),
            model: m, image: source.still, speedScale: scale, timeline: timeline)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return pdf(pages: pages.pages, fileName: "Mantis отчёт \(f.string(from: Date())).pdf")
    }

    /// Кадр видео для фона карты «на кадре».
    static func frame(url: URL, at t: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    /// Рисует страницы в PDF (каждая страница — своей высоты) и возвращает файл.
    static func pdf(pages: [AnyView], fileName: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        var box = CGRect(x: 0, y: 0, width: HeatReportPages.pageWidth, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for page in pages {
            let renderer = ImageRenderer(content: page)
            renderer.render { size, draw in
                var media = CGRect(origin: .zero, size: size)
                pdf.beginPage(mediaBox: &media)
                draw(pdf)
                pdf.endPage()
            }
        }
        pdf.closePDF()
        return url
    }
}
