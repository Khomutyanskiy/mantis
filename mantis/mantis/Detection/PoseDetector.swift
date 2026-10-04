//
//  PoseDetector.swift
//  mantis
//
//  Нейросеть YOLO11-pose (Core ML): кадр → люди с рамками и 17 ключевыми точками.
//  Модель yolo11n-pose.mlpackage лежит в папке проекта; Xcode компилирует её в yolo11n-pose.mlmodelc.
//

import CoreImage
import CoreML
import CoreVideo
import Foundation

nonisolated final class PoseDetector {
    enum DetectorError: LocalizedError {
        case modelNotFound
        case badModel(String)
        case pixelBuffer

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "Модель yolo11n-pose не найдена в приложении. Добавьте yolo11n-pose.mlpackage в папку проекта mantis."
            case .badModel(let s):
                return "Неожиданный формат модели: \(s)"
            case .pixelBuffer:
                return "Не удалось подготовить кадр для нейросети"
            }
        }
    }

    let model: MLModel
    let inputName: String
    let outputName: String
    let inputSize: Int
    var confThreshold = 0.35
    var iouThreshold = 0.7
    /// Диагностика: максимальная уверенность «человек» на последнем кадре (до порога).
    private(set) var lastMaxScore: Double = 0
    /// На чём реально считается модель (для экрана результата).
    let computeDescription: String

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var buffer: CVPixelBuffer?

    init(computeUnits: MLComputeUnits = .all) throws {
        guard let url = Bundle.main.url(forResource: "yolo11n-pose", withExtension: "mlmodelc") else {
            throw DetectorError.modelNotFound
        }
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // В симуляторе нет Neural Engine, а GPU-бэкенд Core ML падает (E5RT / MPSGraph) и откатывается
        // на CPU на каждом кадре. Сразу работаем на CPU — так быстрее и без ошибок в консоли.
        config.computeUnits = .cpuOnly
        computeDescription = "CPU (симулятор)"
        #else
        config.computeUnits = computeUnits
        computeDescription = "Neural Engine / GPU"
        #endif
        model = try MLModel(contentsOf: url, configuration: config)

        guard let input = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }) else {
            throw DetectorError.badModel("нет входа-изображения")
        }
        inputName = input.key
        inputSize = input.value.imageConstraint?.pixelsWide ?? 640

        guard let output = model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) else {
            throw DetectorError.badModel("нет выхода-массива")
        }
        outputName = output.key
    }

    private func inputBuffer() throws -> CVPixelBuffer {
        if let b = buffer { return b }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, inputSize, inputSize, kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let b = pb else { throw DetectorError.pixelBuffer }
        buffer = b
        return b
    }

    /// Найти людей на кадре. Координаты результата — в пикселях кадра (y вниз).
    func detect(_ image: CIImage) throws -> [RawDetection] {
        let extent = image.extent
        let w = Double(extent.width), h = Double(extent.height)
        let s = Double(inputSize)
        let lb = Letterbox.make(imageWidth: w, imageHeight: h, inputSize: s)
        let scaled = lb.scaledSize

        // Letterbox как в ultralytics: кадр уменьшается с сохранением пропорций и центрируется на сером (114) поле.
        // У CIImage начало координат внизу слева, поэтому сдвиг по y считается от низа.
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scaled.width / w, y: scaled.height / h))
            .transformed(by: CGAffineTransform(translationX: lb.padX, y: s - lb.padY - scaled.height))
        let gray = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255))
            .cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
        let composed = placed.composited(over: gray)

        let pb = try inputBuffer()
        ciContext.render(composed, to: pb, bounds: CGRect(x: 0, y: 0, width: s, height: s), colorSpace: colorSpace)

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pb)])
        let result = try model.prediction(from: provider)
        guard let array = result.featureValue(for: outputName)?.multiArrayValue else {
            throw DetectorError.badModel("пустой выход")
        }
        let shape = array.shape.map { $0.intValue }
        guard shape.count == 3 else { throw DetectorError.badModel("форма выхода \(shape)") }

        // MLShapedArray даёт логически непрерывные значения (учитывает шаги). Модель отдаёт Float16.
        let values: [Float]
        switch array.dataType {
        case .float32:
            values = MLShapedArray<Float>(array).scalars
        case .float16:
            values = MLShapedArray<Float16>(array).scalars.map { Float($0) }
        default:
            values = MLShapedArray<Float>(converting: array).scalars
        }
        let n = shape[2]
        var best: Float = 0
        if values.count >= 5 * n {
            for i in (4 * n)..<(5 * n) where values[i] > best { best = values[i] }
        }
        lastMaxScore = Double(best)
        return PoseDecoder.decode(values: values, channels: shape[1], count: shape[2], letterbox: lb,
                                  confThreshold: confThreshold, iouThreshold: iouThreshold)
    }
}
