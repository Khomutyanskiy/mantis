//
//  HelpView.swift
//  mantis
//
//  Помощь для пользователя: как поставить телефон, как разметить, что значат цифры, точность, приватность.
//

import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                block("Где работает", icon: "mappin.and.ellipse", items: [
                    "Витрина снаружи — камера смотрит на тротуар или галерею ТЦ.",
                    "Внутри торговой точки — полка, стойка, промо-зона, примерочные, касса.",
                ])
                block("Как поставить телефон", icon: "iphone.gen3", items: [
                    "Камерой на людей, на уровне 1,2–2 м, немного сверху.",
                    "Чтобы люди были видны в полный рост — так точнее скорость и расстояние.",
                    "Без яркого солнца в объектив и без бликов стекла: прижмите телефон к стеклу.",
                    "Для работы дольше часа — зарядка и подставка без перегрева.",
                ])
                block("Разметка кадра", icon: "viewfinder", items: [
                    "Зона — четыре угла: считаются только люди внутри. Уберите дорогу и соседние витрины.",
                    "Красная линия (по желанию) — поперёк потока, считает проходы и направление.",
                    "Зелёная линия «Вход» (по желанию) — на пороге двери, считает вошедших.",
                ])
                block("Что значат цифры", icon: "number", items: [
                    "Притормозили — заметно сбавили шаг в зоне.",
                    "Посмотрели — повернули голову к витрине (или к камере) хотя бы на 0,6 с.",
                    "Остановились — стояли на месте 2 с и дольше.",
                    "Оценка витрины 0–100 — сводная цифра: 70+ сильная, 40–69 средняя, ниже 40 слабая.",
                    "Деньги — оценка по среднему чеку и доле покупающих из профиля.",
                ])
                block("Точность", icon: "scope", items: [
                    "Люди в толпе и за стеклом с бликами могут теряться — тогда номер человека меняется.",
                    "Расстояния и скорость примерные (по росту ~1,7 м). Уточните калибровкой на тепловой карте.",
                    "«Посмотрел» определяется по повороту головы, а не по глазам.",
                ])
                block("Приватность", icon: "lock.shield", items: [
                    "Видео и кадры обрабатываются только на телефоне и никуда не отправляются.",
                    "Лица не распознаются и не сохраняются — только рамки и счётчики.",
                    "В облако (если вошли в аккаунт) уходят только цифры: профиль, статистика, итоги анализов.",
                ])
            }
            .padding()
            .padding(.bottom, 20)
        }
        .themedScreen()
        .navigationTitle("Помощь")
        .navigationBarTitleDisplayMode(.inline)
        .themedNavigationBar()
    }

    private func block(_ title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(Theme.moon)
            ForEach(items, id: \.self) { t in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.moonDim).frame(width: 5, height: 5).offset(y: -3)
                    Text(t)
                        .font(.subheadline)
                        .foregroundStyle(Theme.moonDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard(padding: 14)
    }
}
