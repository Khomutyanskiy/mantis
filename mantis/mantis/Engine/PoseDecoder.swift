//
//  PoseDecoder.swift
//  mantis
//
//  Разбор сырого выхода YOLO11-pose ([1, 56, N]: cx, cy, w, h, conf, 17×(x, y, v)) в детекции людей:
//  порог уверенности → NMS → пересчёт из координат входа сети (letterbox) в пиксели кадра.
//  Повторяет ultralytics non_max_suppression + scale_boxes / scale_coords.
//

import Foundation

/// Параметры letterbox: как кадр был вписан во вход сети.
nonisolated struct Letterbox: Sendable {
    var gain: Double     // масштаб кадр → вход
    var padX: Double     // отступ слева, пикселей входа
    var padY: Double     // отступ сверху, пикселей входа
    var imageWidth: Double
    var imageHeight: Double

    /// Как ultralytics LetterBox(center=True) для квадратного входа size×size.
    static func make(imageWidth w: Double, imageHeight h: Double, inputSize s: Double) -> Letterbox {
        let r = min(s / h, s / w)
        let newW = (w * r).rounded(), newH = (h * r).rounded()
        let dw = (s - newW) / 2, dh = (s - newH) / 2
        return Letterbox(gain: r, padX: (dw - 0.1).rounded(), padY: (dh - 0.1).rounded(),
                         imageWidth: w, imageHeight: h)
    }

    /// Размер вписанного кадра внутри входа сети.
    var scaledSize: (width: Double, height: Double) { ((imageWidth * gain).rounded(), (imageHeight * gain).rounded()) }
}

nonisolated enum PoseDecoder {
    static let numKeypoints = 17

    /// values — выход сети подряд (канал-major): values[c * count + i].
    static func decode(values: [Float], channels: Int, count: Int, letterbox lb: Letterbox,
                       confThreshold: Double = 0.35, iouThreshold: Double = 0.7, maxDetections: Int = 300) -> [RawDetection] {
        precondition(channels >= 5 + numKeypoints * 3, "Неожиданный выход модели: \(channels) каналов")
        // 1. Кандидаты выше порога
        var candidates: [(score: Double, i: Int)] = []
        for i in 0..<count {
            let s = Double(values[4 * count + i])
            if s > confThreshold { candidates.append((s, i)) }
        }
        candidates.sort { $0.score > $1.score }
        if candidates.count > 30000 { candidates = Array(candidates.prefix(30000)) }

        // 2. Рамки в координатах входа сети
        func box(_ i: Int) -> Box {
            let cx = Double(values[0 * count + i]), cy = Double(values[1 * count + i])
            let w = Double(values[2 * count + i]), h = Double(values[3 * count + i])
            return Box(x1: cx - w / 2, y1: cy - h / 2, x2: cx + w / 2, y2: cy + h / 2)
        }

        // 3. NMS (жадный, как torchvision.ops.nms)
        var kept: [(score: Double, i: Int, box: Box)] = []
        for c in candidates {
            let b = box(c.i)
            if kept.contains(where: { Geometry.iou($0.box, b) > iouThreshold }) { continue }
            kept.append((c.score, c.i, b))
            if kept.count >= maxDetections { break }
        }

        // 4. Обратно в пиксели кадра, с обрезкой по кадру
        let W = lb.imageWidth, H = lb.imageHeight
        func clampX(_ v: Double) -> Double { min(max(v, 0), W) }
        func clampY(_ v: Double) -> Double { min(max(v, 0), H) }
        return kept.map { k in
            let b = k.box
            let ob = Box(x1: clampX((b.x1 - lb.padX) / lb.gain), y1: clampY((b.y1 - lb.padY) / lb.gain),
                         x2: clampX((b.x2 - lb.padX) / lb.gain), y2: clampY((b.y2 - lb.padY) / lb.gain))
            var kps: [Keypoint] = []
            kps.reserveCapacity(numKeypoints)
            for n in 0..<numKeypoints {
                let base = 5 + n * 3
                let x = clampX((Double(values[base * count + k.i]) - lb.padX) / lb.gain)
                let y = clampY((Double(values[(base + 1) * count + k.i]) - lb.padY) / lb.gain)
                let v = Double(values[(base + 2) * count + k.i])
                kps.append(Keypoint(x: x, y: y, conf: v))
            }
            return RawDetection(box: ob, score: k.score, keypoints: kps)
        }
    }
}
