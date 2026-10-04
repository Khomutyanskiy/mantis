//
//  SettingsView.swift
//  mantis
//
//  Вкладка «Настройки»: помощь, что считать взглядом, расстояния, сохранённая разметка,
//  очистка данных, о приложении. Проверка движка — в скрытом режиме разработчика (7 касаний по версии).
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.markup) private var markupJSON = ""
    @AppStorage(SettingsKeys.cameraMarkup) private var cameraMarkupJSON = ""
    @AppStorage(SettingsKeys.showcaseDirection) private var direction = ShowcaseDirection.camera.rawValue
    @AppStorage(SettingsKeys.videoLens) private var lens = Lens.main.rawValue
    @AppStorage(SettingsKeys.heatScale) private var heatScale = 1.0
    @AppStorage("devMode") private var devMode = false

    @State private var versionTaps = 0
    @State private var confirm: ClearTarget?
    @State private var toast: String?

    enum ClearTarget: String, Identifiable {
        case history, hourly, snapshots
        var id: String { rawValue }
        var title: String {
            switch self {
            case .history: return "Очистить историю анализов?"
            case .hourly: return "Очистить статистику по часам?"
            case .snapshots: return "Удалить снимки для сравнения?"
            }
        }
    }

    private var videoMarkup: Markup { Markup.decode(markupJSON) }
    private var cameraMarkup: Markup { Markup.decode(cameraMarkupJSON) }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                // Помощь
                Section {
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("Как установить и пользоваться", systemImage: "questionmark.circle")
                    }
                }
                .listRowBackground(Theme.surface)

                // Где камера
                Section {
                    Picker("Камера стоит", selection: $direction) {
                        ForEach(ShowcaseDirection.allCases, id: \.rawValue) { d in
                            Text(d.title).tag(d.rawValue)
                        }
                    }
                } header: {
                    Text("Что считать взглядом").foregroundStyle(Theme.moonDim)
                } footer: {
                    Text("«Камера в витрине» (или на полке) — «посмотрел» значит повернулся лицом к камере. «Витрина слева / справа» — камера сбоку, засчитывается поворот головы в сторону витрины.")
                        .foregroundStyle(Theme.moonDim)
                }
                .listRowBackground(Theme.surface)

                // Расстояния
                Section {
                    Picker("Объектив видео", selection: $lens) {
                        ForEach(Lens.allCases) { l in
                            Text(l.title).tag(l.rawValue)
                        }
                    }
                    LabeledContent("Калибровка", value: heatScale == 1 ? "нет" : "×\(heatNum(heatScale, 2))")
                    if heatScale != 1 {
                        Button("Сбросить калибровку") { heatScale = 1 }
                    }
                } header: {
                    Text("Расстояния и скорость").foregroundStyle(Theme.moonDim)
                } footer: {
                    Text("Выберите, каким объективом iPhone снято видео (обычно 1×). Действует со следующего анализа. Точнее — калибровка на экране тепловой карты.")
                        .foregroundStyle(Theme.moonDim)
                }
                .listRowBackground(Theme.surface)

                // Разметка
                Section {
                    markupRow("Видео", markupJSON: $markupJSON, markup: videoMarkup, isVideo: true)
                    markupRow("Камера", markupJSON: $cameraMarkupJSON, markup: cameraMarkup, isVideo: false)
                } header: {
                    Text("Сохранённая разметка").foregroundStyle(Theme.moonDim)
                } footer: {
                    Text("Линия подсчёта и вход запоминаются. Зона для каждого нового видео начинается со всего кадра; для камеры — сохраняется.")
                        .foregroundStyle(Theme.moonDim)
                }
                .listRowBackground(Theme.surface)

                // Данные
                Section {
                    Button("Очистить историю анализов") { confirm = .history }
                        .disabled(ReportStore.shared.items.isEmpty)
                    Button("Очистить статистику по часам") { confirm = .hourly }
                        .disabled(HourlyStore.shared.hours.isEmpty)
                    Button("Удалить снимки для сравнения") { confirm = .snapshots }
                } header: {
                    Text("Данные на телефоне").foregroundStyle(Theme.moonDim)
                } footer: {
                    Text("Удаляется только с этого телефона. Если вы вошли в аккаунт, копия в облаке остаётся.")
                        .foregroundStyle(Theme.moonDim)
                }
                .listRowBackground(Theme.surface)

                // О приложении
                Section {
                    LabeledContent("Версия", value: version)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 7 {
                                versionTaps = 0
                                devMode.toggle()
                                flash(devMode ? "Режим разработчика включён" : "Режим разработчика выключен")
                            }
                        }
                    Label("Видео и кадры обрабатываются только на телефоне и никуда не отправляются. Лица не сохраняются.",
                          systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(Theme.moonDim)
                    LabeledContent("Разработчик", value: "РСМ АйТи")
                } header: {
                    Text("О приложении").foregroundStyle(Theme.moonDim)
                }
                .listRowBackground(Theme.surface)

                if devMode {
                    Section {
                        NavigationLink {
                            EngineSelfTestView()
                        } label: {
                            Label("Проверка движка", systemImage: "checkmark.seal")
                        }
                        LabeledContent("Модель", value: "YOLO11n-pose, Core ML")
                        LabeledContent("Трекер", value: "ByteTrack")
                        LabeledContent("Анализ", value: "15 кадров/с")
                        Button("Выключить режим разработчика") { devMode = false }
                    } header: {
                        Text("Для разработчика").foregroundStyle(Theme.moonDim)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .themedList()
            .navigationTitle("Настройки")
            .themedNavigationBar()
            .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible, presenting: confirm) { target in
                Button("Удалить", role: .destructive) { clear(target) }
                Button("Отмена", role: .cancel) {}
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
                }
            }
        }
    }

    private func markupRow(_ title: String, markupJSON: Binding<String>, markup: Markup, isVideo: Bool) -> some View {
        HStack(spacing: 14) {
            MarkupPreview(markup: isVideo ? { var m = markup; m.zone = Markup.fullFrame; return m }() : markup)
                .frame(width: 70, height: 110)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                if !isVideo {
                    Text("Зона: \(markup.isFullFrame ? "весь кадр" : "задана")").font(.caption).foregroundStyle(Theme.moonDim)
                }
                Text("Линия: \(markup.lineEnabled ? "вкл." : "выкл.") · Вход: \(markup.entranceEnabled ? "вкл." : "выкл.")")
                    .font(.caption).foregroundStyle(Theme.moonDim)
                Button("Сбросить") { markupJSON.wrappedValue = Markup().json }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(markup == Markup())
                    .padding(.top, 2)
            }
            Spacer()
        }
    }

    private func clear(_ target: ClearTarget) {
        switch target {
        case .history:
            ReportStore.shared.clearLocal()
            flash("История очищена")
        case .hourly:
            HourlyStore.shared.clearAll()
            flash("Статистика очищена")
        case .snapshots:
            HeatStore.save([])
            flash("Снимки удалены")
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}

/// Схема кадра с сохранённой зоной и линией.
struct MarkupPreview: View {
    let markup: Markup

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = h * 9 / 16
            let x0 = (geo.size.width - w) / 2
            Canvas { ctx, _ in
                let frame = CGRect(x: x0, y: 0, width: w, height: h)
                func map(_ p: Pt) -> CGPoint { CGPoint(x: x0 + p.x * w, y: p.y * h) }
                ctx.fill(Path(roundedRect: frame, cornerRadius: 8), with: .color(Theme.surfaceHigh))
                ctx.stroke(Path(roundedRect: frame, cornerRadius: 8), with: .color(Theme.moon.opacity(0.4)), lineWidth: 1)

                var zone = Path()
                if let first = markup.zone.first {
                    zone.move(to: map(first))
                    for p in markup.zone.dropFirst() { zone.addLine(to: map(p)) }
                    zone.closeSubpath()
                }
                ctx.fill(zone, with: .color(.cyan.opacity(0.18)))
                ctx.stroke(zone, with: .color(.cyan.opacity(0.9)), lineWidth: 1.5)

                if markup.lineEnabled, markup.line.count == 2 {
                    var lp = Path()
                    lp.move(to: map(markup.line[0]))
                    lp.addLine(to: map(markup.line[1]))
                    ctx.stroke(lp, with: .color(.red), lineWidth: 2.5)
                }

                if markup.entranceEnabled, markup.entrance.count == 2 {
                    var ep = Path()
                    ep.move(to: map(markup.entrance[0]))
                    ep.addLine(to: map(markup.entrance[1]))
                    ctx.stroke(ep, with: .color(.green), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                }
            }
        }
        .padding(.vertical, 6)
    }
}
