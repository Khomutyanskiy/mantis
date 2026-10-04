//
//  Theme.swift
//  mantis
//
//  Оформление: тёмно-синий фон и белолунный (холодный бело-голубой) текст и акценты.
//

import SwiftUI

enum Theme {
    /// Основной фон — глубокий тёмно-синий.
    static let background = Color(red: 0.035, green: 0.063, blue: 0.145)      // #09102B
    /// Карточки и строки списков.
    static let surface = Color(red: 0.075, green: 0.118, blue: 0.239)         // #131E3D
    /// Выделенные элементы, нажатые состояния.
    static let surfaceHigh = Color(red: 0.118, green: 0.176, blue: 0.333)     // #1E2D55
    /// Белолунный — основной цвет текста и акцентов.
    static let moon = Color(red: 0.925, green: 0.945, blue: 1.0)              // #ECF1FF
    /// Приглушённый белолунный — подписи и второстепенный текст.
    static let moonDim = Color(red: 0.925, green: 0.945, blue: 1.0).opacity(0.62)
    /// Тонкие разделители и обводки.
    static let stroke = Color(red: 0.925, green: 0.945, blue: 1.0).opacity(0.12)

    /// Фон экрана с лёгким градиентом.
    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.055, green: 0.094, blue: 0.212), background],
                       startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// Тёмно-синий фон для экранов со списками (List / Form).
    func themedList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient.ignoresSafeArea())
    }

    /// Тёмно-синий фон для обычных экранов.
    func themedScreen() -> some View {
        self.background(Theme.backgroundGradient.ignoresSafeArea())
    }

    /// Карточка на тёмно-синем фоне.
    func themedCard(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
    }

    /// Шапка навигации в цветах темы.
    func themedNavigationBar() -> some View {
        self
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

/// Ключи настроек в UserDefaults.
enum SettingsKeys {
    /// Разметка кадра (зона, линия) — JSON Markup, последняя использованная.
    /// v2: линия по умолчанию выключена — старые сохранённые разметки с линией не подхватываем.
    static let markup = "markupJSON.v2"
    static let showcaseDirection = "showcaseDirection"
    /// Разметка для режима камеры — отдельно от разметки видео.
    static let cameraMarkup = "cameraMarkupJSON"
    /// Объектив, которым снято видео (Lens.rawValue).
    static let videoLens = "videoLens"
    /// Калибровка расстояний: множитель масштаба (1 — без калибровки).
    static let heatScale = "heatScale"
}
