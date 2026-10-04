//
//  ProfileView.swift
//  mantis
//
//  Вкладка «Профиль»: вход в аккаунт (Firebase), данные магазина, настройки для пересчёта в деньги,
//  статистика по часам и история анализов.
//

import SwiftUI

struct ProfileView: View {
    @Bindable private var account = AccountModel.shared
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            List {
                accountSection

                Section {
                    LabeledContent("Магазин", value: account.profile.point.isEmpty ? "—" : account.profile.point)
                    LabeledContent("Средний чек", value: rubles(account.profile.avgCheck))
                    NavigationLink {
                        BusinessSettingsView()
                    } label: {
                        Label("Магазин и деньги", systemImage: "storefront")
                    }
                } header: {
                    Text("Магазин").foregroundStyle(Theme.moonDim)
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink {
                        StatsView()
                    } label: {
                        Label("По часам и дням недели", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink {
                        ReportsHistoryView()
                    } label: {
                        LabeledContent {
                            Text("\(ReportStore.shared.items.count)")
                        } label: {
                            Label("История анализов", systemImage: "clock.arrow.circlepath")
                        }
                    }
                } header: {
                    Text("Аналитика").foregroundStyle(Theme.moonDim)
                } footer: {
                    Text("Статистика по часам копится, пока идёт подсчёт на вкладке «Камера».")
                        .foregroundStyle(Theme.moonDim)
                }
                .listRowBackground(Theme.surface)
            }
            .themedList()
            .navigationTitle("Профиль")
            .themedNavigationBar()
            .refreshable { await account.pull() }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { account.signOut() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Данные на телефоне останутся.")
            }
            .confirmationDialog("Удалить аккаунт?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить навсегда", role: .destructive) {
                    Task {
                        do { try await account.deleteAccount() } catch { deleteError = error.localizedDescription }
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Аккаунт и данные в облаке будут удалены. Данные на телефоне останутся.")
            }
            .alert("Не удалось удалить", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if !account.isCloudAvailable {
                Label("Облако не подключено", systemImage: "icloud.slash")
                    .foregroundStyle(Theme.moonDim)
            } else if account.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.moon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.profile.name.isEmpty ? "Без имени" : account.profile.name)
                            .font(.headline).foregroundStyle(Theme.moon)
                        Text(account.email ?? "").font(.caption).foregroundStyle(Theme.moonDim)
                        if !account.profile.company.isEmpty {
                            Text(account.profile.company).font(.caption).foregroundStyle(Theme.moonDim)
                        }
                    }
                    Spacer()
                    if account.syncing { ProgressView().tint(Theme.moon) }
                }
                .padding(.vertical, 4)
                if let e = account.lastError {
                    Text(e).font(.caption).foregroundStyle(.orange)
                }
                Button("Выйти") { confirmSignOut = true }
                Button("Удалить аккаунт", role: .destructive) { confirmDelete = true }
            } else {
                NavigationLink {
                    AuthView()
                } label: {
                    Label("Войти или зарегистрироваться", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } header: {
            Text("Аккаунт").foregroundStyle(Theme.moonDim)
        } footer: {
            Text(account.isCloudAvailable
                 ? "С аккаунтом профиль, статистика и история анализов хранятся в облаке и доступны на других устройствах. Видео никуда не отправляется — только цифры."
                 : "Добавьте в Xcode пакет firebase-ios-sdk (FirebaseAuth, FirebaseFirestore) и файл GoogleService-Info.plist.")
                .foregroundStyle(Theme.moonDim)
        }
        .listRowBackground(Theme.surface)
    }
}

// MARK: - Вход и регистрация

struct AuthView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
        var title: String { self == .signIn ? "Вход" : "Регистрация" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 0) {
                    if mode == .signUp {
                        field("Имя", text: $name, icon: "person")
                        Divider().overlay(Theme.stroke)
                    }
                    field("Почта", text: $email, icon: "envelope", keyboard: .emailAddress)
                    Divider().overlay(Theme.stroke)
                    HStack(spacing: 12) {
                        Image(systemName: "lock").foregroundStyle(Theme.moonDim).frame(width: 22)
                        SecureField("Пароль", text: $password)
                            .textContentType(mode == .signUp ? .newPassword : .password)
                            .foregroundStyle(Theme.moon)
                    }
                    .padding(14)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if let info {
                    Label(info, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.green)
                }

                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(Theme.background) }
                        Text(mode == .signIn ? "Войти" : "Создать аккаунт")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Theme.background)
                    .background(Theme.moon, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(busy || email.isEmpty || password.isEmpty)
                .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

                if mode == .signIn {
                    Button("Забыли пароль?") { Task { await reset() } }
                        .font(.subheadline)
                        .foregroundStyle(Theme.moon)
                        .frame(maxWidth: .infinity)
                        .disabled(busy)
                }

                Text("Пароль — не меньше 6 символов. В облаке хранятся только цифры анализа и профиль магазина.")
                    .font(.footnote)
                    .foregroundStyle(Theme.moonDim)
            }
            .padding()
        }
        .themedScreen()
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
        .onChange(of: mode) { _, _ in
            error = nil
            info = nil
        }
    }

    private func field(_ title: String, text: Binding<String>, icon: String, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.moonDim).frame(width: 22)
            TextField(title, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                .autocorrectionDisabled()
                .textContentType(keyboard == .emailAddress ? .emailAddress : .name)
                .foregroundStyle(Theme.moon)
        }
        .padding(14)
    }

    private func submit() async {
        busy = true
        error = nil
        info = nil
        defer { busy = false }
        do {
            if mode == .signIn {
                try await AccountModel.shared.signIn(email: email, password: password)
            } else {
                try await AccountModel.shared.signUp(email: email, password: password)
                let n = name.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { AccountModel.shared.profile.name = n }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() async {
        guard !email.isEmpty else {
            error = "Введите почту — пришлём ссылку для смены пароля"
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await AccountModel.shared.resetPassword(email: email)
            error = nil
            info = "Письмо для смены пароля отправлено на \(email)"
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Магазин и деньги

struct BusinessSettingsView: View {
    @Bindable private var account = AccountModel.shared

    var body: some View {
        Form {
            Section {
                TextField("Имя", text: $account.profile.name)
                TextField("Компания", text: $account.profile.company)
                TextField("Магазин / точка", text: $account.profile.point)
                TextField("Город", text: $account.profile.city)
            } header: {
                Text("Магазин").foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)

            Section {
                numberRow("Средний чек, ₽", value: $account.profile.avgCheck)
                numberRow("Покупают из посмотревших, %", value: $account.profile.lookToBuy)
                numberRow("Покупают из вошедших, %", value: $account.profile.enterToBuy)
            } header: {
                Text("Деньги").foregroundStyle(Theme.moonDim)
            } footer: {
                Text("Если в разметке есть линия «Вход», выручка считается от вошедших, иначе — от посмотревших на витрину. Возьмите цифры из кассы: средний чек и сколько посетителей покупают.")
                    .foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)

            Section {
                numberRow("Часов работы в день", value: $account.profile.hoursPerDay)
                numberRow("Дней работы в месяц", value: $account.profile.daysPerMonth)
            } header: {
                Text("Режим работы").foregroundStyle(Theme.moonDim)
            } footer: {
                Text("Нужно для пересчёта «в месяц» по короткому видео или сессии камеры.")
                    .foregroundStyle(Theme.moonDim)
            }
            .listRowBackground(Theme.surface)
        }
        .themedList()
        .navigationTitle("Магазин и деньги")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
    }

    private func numberRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.moon)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .foregroundStyle(Theme.moon)
        }
    }
}

// MARK: - История анализов

struct ReportsHistoryView: View {
    private var store: ReportStore { .shared }

    var body: some View {
        List {
            if store.items.isEmpty {
                ContentUnavailableView("Пока пусто", systemImage: "clock.arrow.circlepath",
                                       description: Text("Здесь появятся итоги анализов видео и сессий камеры."))
                    .listRowBackground(Color.clear)
            }
            ForEach(store.items) { r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: r.source == "camera" ? "camera.viewfinder" : "film")
                            .foregroundStyle(Theme.moonDim)
                        Text(r.title.isEmpty ? (r.source == "camera" ? "Камера" : "Видео") : r.title)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.moon)
                        Spacer()
                        if let s = r.score {
                            Text("\(s)")
                                .font(.subheadline.weight(.bold)).monospacedDigit()
                                .foregroundStyle(Theme.background)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(ShowcaseScore(value: s, people: 0, parts: []).color, in: Capsule())
                        }
                    }
                    Text("\(r.date.formatted(date: .abbreviated, time: .shortened)) · \(ResultView.formatTime(r.duration))")
                        .font(.caption).foregroundStyle(Theme.moonDim)
                    Text(summary(r)).font(.caption).foregroundStyle(Theme.moon)
                    if let m = r.perMonth {
                        Text("≈ \(rubles(m)) в месяц").font(.caption).foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.surface)
                .swipeActions {
                    Button(role: .destructive) { ReportStore.shared.delete(r.id) } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("История")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
    }

    private func summary(_ r: ReportSummary) -> String {
        var parts = ["людей \(r.people)", "посмотрели \(r.looked)", "притормозили \(r.slowed)"]
        if r.passed > 0 { parts.append("прошли \(r.passed)") }
        if let e = r.entered { parts.append("вошли \(e)") }
        return parts.joined(separator: " · ")
    }
}
