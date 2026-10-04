//
//  Cloud.swift
//  mantis
//
//  Firebase: вход по почте и паролю, профиль магазина, почасовая статистика и история анализов в Firestore.
//
//  Структура Firestore:
//    users/{uid}                       — профиль магазина (BusinessProfile)
//    users/{uid}/hours/{2026-10-03-14} — счётчики за час (HourStat)
//    users/{uid}/reports/{id}          — итоги анализов (ReportSummary)
//
//  Пока пакет firebase-ios-sdk не добавлен в проект, код собирается без него (всё облачное просто выключено).
//

import Foundation
import SwiftUI

#if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
#endif

nonisolated enum CloudError: LocalizedError {
    case notConfigured
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Firebase не подключён"
        case .message(let s): return s
        }
    }
}

nonisolated enum Cloud {
    /// Настроить Firebase при запуске (если в приложении есть GoogleService-Info.plist).
    static func configure() {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard FirebaseApp.app() == nil,
              Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        FirebaseApp.configure()
        #endif
    }

    static var isAvailable: Bool {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        return FirebaseApp.app() != nil
        #else
        return false
        #endif
    }

    // MARK: Вход

    static func observeAuth(_ callback: @escaping @MainActor @Sendable (String?, String?) -> Void) {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { return }
        _ = Auth.auth().addStateDidChangeListener { _, user in
            let uid = user?.uid, email = user?.email
            Task { @MainActor in callback(uid, email) }
        }
        #endif
    }

    static func signIn(email: String, password: String) async throws {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { throw CloudError.notConfigured }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Auth.auth().signIn(withEmail: email, password: password) { _, error in
                if let error { cont.resume(throwing: friendly(error)) } else { cont.resume() }
            }
        }
        #else
        throw CloudError.notConfigured
        #endif
    }

    static func signUp(email: String, password: String) async throws {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { throw CloudError.notConfigured }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Auth.auth().createUser(withEmail: email, password: password) { _, error in
                if let error { cont.resume(throwing: friendly(error)) } else { cont.resume() }
            }
        }
        #else
        throw CloudError.notConfigured
        #endif
    }

    static func resetPassword(email: String) async throws {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { throw CloudError.notConfigured }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Auth.auth().sendPasswordReset(withEmail: email) { error in
                if let error { cont.resume(throwing: friendly(error)) } else { cont.resume() }
            }
        }
        #else
        throw CloudError.notConfigured
        #endif
    }

    static func signOut() {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { return }
        try? Auth.auth().signOut()
        #endif
    }

    /// Удалить аккаунт и данные в облаке (данные на телефоне остаются).
    static func deleteAccount(uid: String) async throws {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable, let user = Auth.auth().currentUser else { throw CloudError.notConfigured }
        let db = Firestore.firestore()
        for sub in ["hours", "reports"] {
            let ids: [String] = try await withCheckedThrowingContinuation { cont in
                db.collection("users").document(uid).collection(sub).getDocuments { snap, error in
                    if let error { cont.resume(throwing: error) } else {
                        cont.resume(returning: snap?.documents.map(\.documentID) ?? [])
                    }
                }
            }
            for id in ids { db.collection("users").document(uid).collection(sub).document(id).delete(completion: nil) }
        }
        db.collection("users").document(uid).delete(completion: nil)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            user.delete { error in
                if let error { cont.resume(throwing: friendly(error)) } else { cont.resume() }
            }
        }
        #else
        throw CloudError.notConfigured
        #endif
    }

    // MARK: Данные

    static func saveProfile(_ p: BusinessProfile, uid: String) {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { return }
        try? Firestore.firestore().collection("users").document(uid).setData(from: p, merge: true)
        #endif
    }

    static func loadProfile(uid: String) async throws -> BusinessProfile? {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { throw CloudError.notConfigured }
        return try await withCheckedThrowingContinuation { cont in
            Firestore.firestore().collection("users").document(uid).getDocument { snap, error in
                if let error { cont.resume(throwing: error); return }
                guard let snap, snap.exists else { cont.resume(returning: nil); return }
                cont.resume(returning: try? snap.data(as: BusinessProfile.self))
            }
        }
        #else
        throw CloudError.notConfigured
        #endif
    }

    static func saveHours(_ hours: [String: HourStat], uid: String) {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable, !hours.isEmpty else { return }
        let col = Firestore.firestore().collection("users").document(uid).collection("hours")
        // пакеты по 400 записей (лимит Firestore — 500)
        let all = Array(hours)
        for start in stride(from: 0, to: all.count, by: 400) {
            let batch = Firestore.firestore().batch()
            for (k, v) in all[start..<min(start + 400, all.count)] {
                _ = try? batch.setData(from: v, forDocument: col.document(k))
            }
            batch.commit(completion: nil)
        }
        #endif
    }

    static func loadHours(uid: String) async throws -> [String: HourStat] {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { throw CloudError.notConfigured }
        return try await withCheckedThrowingContinuation { cont in
            Firestore.firestore().collection("users").document(uid).collection("hours").getDocuments { snap, error in
                if let error { cont.resume(throwing: error); return }
                var out: [String: HourStat] = [:]
                for d in snap?.documents ?? [] {
                    if let h = try? d.data(as: HourStat.self) { out[d.documentID] = h }
                }
                cont.resume(returning: out)
            }
        }
        #else
        throw CloudError.notConfigured
        #endif
    }

    static func saveReport(_ r: ReportSummary, uid: String) {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { return }
        try? Firestore.firestore().collection("users").document(uid).collection("reports").document(r.id).setData(from: r)
        #endif
    }

    static func deleteReport(_ id: String, uid: String) {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { return }
        Firestore.firestore().collection("users").document(uid).collection("reports").document(id).delete(completion: nil)
        #endif
    }

    static func loadReports(uid: String) async throws -> [ReportSummary] {
        #if canImport(FirebaseCore) && canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard isAvailable else { throw CloudError.notConfigured }
        return try await withCheckedThrowingContinuation { cont in
            Firestore.firestore().collection("users").document(uid).collection("reports").getDocuments { snap, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (snap?.documents ?? []).compactMap { try? $0.data(as: ReportSummary.self) })
            }
        }
        #else
        throw CloudError.notConfigured
        #endif
    }

    /// Понятные сообщения для ошибок входа (коды FIRAuthErrorDomain).
    private static func friendly(_ error: Error) -> Error {
        let e = error as NSError
        let text: String?
        switch e.code {
        case 17004, 17009, 17011: text = "Неверная почта или пароль"
        case 17007: text = "Эта почта уже зарегистрирована — войдите"
        case 17008: text = "Неверный адрес почты"
        case 17010: text = "Слишком много попыток, попробуйте позже"
        case 17014: text = "Для удаления аккаунта войдите заново и повторите"
        case 17020: text = "Нет связи с интернетом"
        case 17026: text = "Пароль слишком простой — минимум 6 символов"
        default: text = nil
        }
        return text.map { CloudError.message($0) } ?? error
    }
}

// MARK: - Аккаунт (состояние для экранов)

@Observable
final class AccountModel {
    static let shared = AccountModel()

    private(set) var uid: String?
    private(set) var email: String?
    var syncing = false
    var lastError: String?

    /// Профиль магазина: сохраняется на телефоне сразу, в облако — через секунду после последней правки.
    var profile: BusinessProfile {
        didSet {
            guard profile != oldValue else { return }
            profile.saveLocal()
            scheduleCloudSave()
        }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var isCloudAvailable: Bool { Cloud.isAvailable }
    var isSignedIn: Bool { uid != nil }

    private init() {
        profile = BusinessProfile.loadLocal()
    }

    /// Вызвать один раз после Cloud.configure().
    func start() {
        Cloud.observeAuth { uid, email in
            AccountModel.shared.authChanged(uid: uid, email: email)
        }
    }

    private func authChanged(uid: String?, email: String?) {
        let changed = uid != self.uid
        self.uid = uid
        self.email = email
        HourlyStore.shared.uid = uid
        if changed, uid != nil { Task { await pull() } }
    }

    /// Подтянуть данные из облака и объединить с телефоном.
    func pull() async {
        guard let uid else { return }
        syncing = true
        defer { syncing = false }
        do {
            if let remote = try await Cloud.loadProfile(uid: uid) {
                if remote != profile { profile = remote }
            } else {
                Cloud.saveProfile(profile, uid: uid)
            }
            HourlyStore.shared.merge(remote: try await Cloud.loadHours(uid: uid))
            ReportStore.shared.merge(remote: try await Cloud.loadReports(uid: uid))
            lastError = nil
        } catch {
            lastError = "Синхронизация: \(error.localizedDescription)"
        }
    }

    private func scheduleCloudSave() {
        guard let uid else { return }
        saveTask?.cancel()
        let p = profile
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            Cloud.saveProfile(p, uid: uid)
        }
    }

    func signIn(email: String, password: String) async throws {
        try await Cloud.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
    }

    func signUp(email: String, password: String) async throws {
        try await Cloud.signUp(email: email.trimmingCharacters(in: .whitespaces), password: password)
    }

    func resetPassword(email: String) async throws {
        try await Cloud.resetPassword(email: email.trimmingCharacters(in: .whitespaces))
    }

    func signOut() {
        HourlyStore.shared.flush()
        Cloud.signOut()
    }

    func deleteAccount() async throws {
        guard let uid else { return }
        try await Cloud.deleteAccount(uid: uid)
    }
}
