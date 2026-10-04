//
//  HeadPose.swift
//  mantis
//
//  Оценка поворота головы по ключевым точкам COCO (нос, глаза, уши, плечи).
//  Порт python/mantis/headpose.py.
//
//  yaw — нормированное смещение носа относительно центра головы:
//    0 — лицо смотрит прямо в камеру; < 0 — нос смещён влево по кадру; > 0 — вправо;
//    nil — лица не видно (человек спиной / точки ненадёжны).
//

import Foundation

/// Ключевая точка: x, y в пикселях кадра и уверенность (видимость) 0..1.
nonisolated struct Keypoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var conf: Double
}

nonisolated enum ShowcaseDirection: String, Codable, CaseIterable, Sendable {
    case camera, left, right

    var title: String {
        switch self {
        case .camera: return "Камера в витрине"
        case .left: return "Витрина слева"
        case .right: return "Витрина справа"
        }
    }
}

nonisolated struct HeadPose: Sendable {
    var faceVisible: Bool
    var bothEyes: Bool
    var yaw: Double?
}

nonisolated enum HeadPoseEstimator {
    static let nose = 0, lEye = 1, rEye = 2, lEar = 3, rEar = 4, lShoulder = 5, rShoulder = 6

    static func estimate(_ kpts: [Keypoint]?, minConf: Double = 0.5) -> HeadPose {
        guard let k = kpts, k.count >= 7 else { return HeadPose(faceVisible: false, bothEyes: false, yaw: nil) }
        func ok(_ i: Int) -> Bool { k[i].conf >= minConf }

        guard ok(nose) else { return HeadPose(faceVisible: false, bothEyes: false, yaw: nil) }
        let noseX = k[nose].x
        let bothEyes = ok(lEye) && ok(rEye)

        // Центр и полуширина головы: уши надёжнее всего, затем глаза, затем плечи.
        var center: Double?
        var halfW: Double?
        if ok(lEar) && ok(rEar) {
            center = (k[lEar].x + k[rEar].x) / 2
            halfW = abs(k[lEar].x - k[rEar].x) / 2
        } else if bothEyes {
            center = (k[lEye].x + k[rEye].x) / 2
            halfW = abs(k[lEye].x - k[rEye].x)  // межглазное ~ половина ширины головы
        } else if ok(lShoulder) && ok(rShoulder) {
            center = (k[lShoulder].x + k[rShoulder].x) / 2
            halfW = abs(k[lShoulder].x - k[rShoulder].x) / 4
        }

        guard let c = center, let hw = halfW, hw >= 1e-3 else {
            // Видно нос и одно ухо => голова в профиль. Направление — по тому, с какой стороны ухо.
            let ear: Int? = ok(lEar) ? lEar : (ok(rEar) ? rEar : nil)
            guard let e = ear else { return HeadPose(faceVisible: true, bothEyes: bothEyes, yaw: nil) }
            return HeadPose(faceVisible: true, bothEyes: bothEyes, yaw: noseX > k[e].x ? 1.0 : -1.0)
        }

        let yaw = max(-1.0, min(1.0, (noseX - c) / hw))
        return HeadPose(faceVisible: true, bothEyes: bothEyes, yaw: yaw)
    }

    /// Смотрит ли человек в сторону витрины.
    static func isLooking(_ pose: HeadPose, direction: ShowcaseDirection, maxYaw: Double, minSideYaw: Double) -> Bool {
        guard pose.faceVisible, let yaw = pose.yaw else { return false }
        switch direction {
        case .camera: return pose.bothEyes && abs(yaw) <= maxYaw
        case .left: return yaw <= -minSideYaw
        case .right: return yaw >= minSideYaw
        }
    }
}
