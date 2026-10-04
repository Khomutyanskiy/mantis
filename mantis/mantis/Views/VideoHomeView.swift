//
//  VideoHomeView.swift
//  mantis
//
//  Вкладка «Анализ»: выбор видео (Фото / Файлы / тестовый ролик) и переход к анализу.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Видео, выбранное для анализа.
struct VideoSelection: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

/// Видео из галереи: копируется во временную папку приложения.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

struct VideoHomeView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var selected: VideoSelection?
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    Text("ВИДЕО ДЛЯ АНАЛИЗА")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.moonDim)
                        .padding(.top, 6)

                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        ActionCard(icon: "photo.on.rectangle", title: "Выбрать из Фото",
                                   subtitle: "Видео из галереи телефона")
                    }
                    .buttonStyle(.plain)

                    Button {
                        showFileImporter = true
                    } label: {
                        ActionCard(icon: "folder", title: "Открыть из Файлов",
                                   subtitle: "iCloud Drive, AirDrop, «На iPhone»")
                    }
                    .buttonStyle(.plain)

                    howItWorks
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .themedScreen()
            .navigationTitle("Mantis")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selected) { sel in
                AnalysisView(url: sel.url)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie]) { result in
                handleFile(result)
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await loadPicked(item) }
            }
            .overlay {
                if loading {
                    ProgressView("Загрузка видео…")
                        .tint(Theme.moon)
                        .padding(24)
                        .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert("Ошибка", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mantis")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Theme.moon)
                    Text("Аналитика витрины")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.moonDim)
                }
            }
            Text("Mantis показывает, как витрина или выкладка работает на продажи: сколько людей прошло мимо, сколько притормозило, посмотрело и зашло в магазин — и сколько это в деньгах. Помогает сравнивать оформление, находить час пик и доказывать эффект от изменений.")
                .font(.subheadline)
                .foregroundStyle(Theme.moonDim)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                modeRow("film.stack", "Видео", "загрузите запись — разбор за минуту")
                modeRow("dot.radiowaves.left.and.right", "Онлайн", "поставьте телефон в витрину — подсчёт в реальном времени на вкладке «Камера»")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("ГДЕ РАБОТАЕТ")
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.moonDim)
                modeRow("storefront", "Витрина снаружи", "прохожие на улице или в галерее ТЦ")
                modeRow("cart", "Внутри торговой точки", "полка, стойка, промо-зона, примерочные, касса — кто подошёл, смотрел и задержался")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func modeRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 24)
                .foregroundStyle(Theme.moon)
            Text("\(Text(title).bold().foregroundStyle(Theme.moon)) — \(text)")
                .font(.subheadline)
                .foregroundStyle(Theme.moonDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Как это работает")
                .font(.headline)
                .foregroundStyle(Theme.moon)

            group("Разметка перед анализом") {
                bullet("viewfinder", "Зона детекции — четыре угла на кадре; люди вне зоны не учитываются")
                bullet("line.diagonal", "Красная линия (по желанию) — считает проходы и их направление")
                bullet("door.left.hand.open", "Зелёная линия «Вход» (по желанию) — на пороге двери, считает вошедших")
            }

            group("Основные счётчики") {
                bullet("person.2", "В кадре / в зоне — сколько разных людей было")
                bullet("figure.walk", "Прошли — пересекли красную линию: → и ←")
                bullet("tortoise", "Притормозили — заметно сбавили шаг в зоне (движение к камере учитывается)")
                bullet("eye", "Посмотрели — повернули голову к витрине хотя бы на 0,6 с")
            }

            group("Поведение") {
                bullet("figure.walk.motion", "Средняя скорость прохожих, м/с и км/ч")
                bullet("hand.raised", "Остановились — стояли на месте 2 с и дольше")
                bullet("timer", "Время взгляда — среднее и медиана у посмотревших")
                bullet("arrow.down.right.and.arrow.up.left", "Подошли ближе — приблизились к витрине")
                bullet("arrow.uturn.backward", "Оглянулись — смотрели на витрину, уже уходя")
                bullet("person.3", "Одновременно в кадре — максимум за видео")
            }

            group("Воронка и поток") {
                bullet("chart.bar.xaxis", "Воронка интереса: в зоне → притормозили → посмотрели → остановились → подошли → вошли")
                bullet("arrow.left.arrow.right", "Направления: к камере, от камеры, слева направо, справа налево")
                bullet("person.2.wave.2", "Группы и одиночки — кто идёт вместе")
            }

            group("Визуализация") {
                bullet("square.dashed", "Рамки на видео: белая — прошёл, зелёная — притормозил, жёлтая — посмотрел")
                bullet("map", "Тепловая карта: вид сверху в метрах или пятна прямо на кадре")
                bullet("square.3.layers.3d", "Слои: время, проход, медленно, остановки, взгляды; стрелки потока")
                bullet("lightbulb", "Подсказки: самое оживлённое место, точка интереса, с какого расстояния смотрят")
                bullet("hand.tap", "Нажмите на место карты — сколько людей, секунд, взглядов и остановок там")
                bullet("slider.horizontal.below.rectangle", "Период: фрагмент видео или последние минуты с камеры")
                bullet("ruler", "Калибровка по предмету известной ширины и выбор объектива")
                bullet("square.split.2x1", "Сравнение «до / после» — например, до и после смены витрины")
                bullet("square.and.arrow.up", "Экспорт карты в PNG и PDF-отчёт со всеми цифрами")
                bullet("flame", "Тепловые пятна поверх видео во время просмотра")
                bullet("chart.xyaxis.line", "График накопления и список событий по времени")
                bullet("arrow.counterclockwise", "Сброс счётчиков или пересчёт с другой разметкой")
            }

            group("Для бизнеса") {
                bullet("gauge.with.needle", "Оценка витрины 0–100 — одна цифра, насколько витрина цепляет")
                bullet("rublesign.circle", "Деньги: потенциальные покупатели и выручка в час и месяц по вашему среднему чеку")
                bullet("chart.bar.xaxis", "Статистика камеры по часам и дням недели: час пик и лучший день")
                bullet("person.crop.circle", "Профиль и облако: история анализов и статистика на всех устройствах")
            }

            group("Приватность") {
                bullet("lock.shield", "Видео обрабатывается на телефоне и никуда не отправляется; лица не сохраняются")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(padding: 16)
        .padding(.top, 6)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.moonDim)
            content()
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .frame(width: 24)
                .foregroundStyle(Theme.moon)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.moonDim)
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        loading = true
        defer {
            loading = false
            pickerItem = nil
        }
        do {
            if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                selected = VideoSelection(url: movie.url)
            } else {
                errorText = "Не удалось загрузить видео"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func handleFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: dst)
                selected = VideoSelection(url: dst)
            } catch {
                errorText = error.localizedDescription
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }
}

/// Крупная кнопка-карточка на тёмно-синем фоне.
struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Theme.moon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.moon)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.moonDim)
        }
        .contentShape(Rectangle())
        .themedCard(padding: 12)
    }
}
