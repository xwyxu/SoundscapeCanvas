//
//  BasicPitchInference.swift
//  SoundscapeCanvas
//
//  Basic Pitch CoreML 分窗推理 —— 逐字翻译自
//  参考文件/mawimbi-master/node_modules/@spotify/basic-pitch/src/inference.ts
//  （Apache License 2.0, Copyright 2022 Spotify AB）的
//  prepareData（L113-128）/ evaluateSingleFrame（L92-106）/ unwrapOutput（L135-147）/
//  evaluateModel（L160-232）；分窗部分逐字对齐 tfjs-core 的 tf.signal.frame 实现
//  （node_modules/@tensorflow/tfjs-core/dist/ops/signal/frame.js L39-60）。
//
//  翻译纪律：
//  - 常量与求值顺序严格对齐 basic-pitch constants.py（inference.ts L32-46）；
//  - tf.signal.frame 不用闭式公式，而是逐字翻译其 while 循环（完整窗 + padEnd 残余窗），
//    保证窗口数、每窗内容与 JS 完全一致；
//  - 模型 IO：输入名 input_2（[1, 43844, 1] Float32）；
//    输出名 Identity_1（frames [1,172,88]）/ Identity_2（onsets [1,172,88]）/
//    Identity（contours [1,172,264]）。运行时若键名带 ":0" 等后缀则做前缀容错映射；
//  - CoreML 模型由 Xcode 自动编译（nmp.mlpackage → nmp.mlpackagec）进 app bundle；
//  - Float↔Double 往返无损（Float32 可被 Double 精确表示），数值路径与 JS 的
//    Float32Array → number（float64 算术）一致。
//

import CoreML
import Foundation

/// 分窗推理聚合结果（每行 = 一帧，列 = 频率 bin；对齐 JS onComplete 回调累计的 number[][]）
struct WindowedResult {
    var frames: [[Double]]
    var onsets: [[Double]]
    var contours: [[Double]]
}

/// 推理错误
enum BasicPitchInferenceError: Error, LocalizedError {
    /// bundle 中找不到已编译的 Basic Pitch 模型
    case modelNotFound
    /// 模型输出缺少指定的张量
    case missingOutput(String)
    /// 输出张量形状/类型与预期不符
    case unexpectedOutputShape(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "找不到 Basic Pitch 模型资源（nmp.mlpackagec），请检查 app target 的 Resources 配置。"
        case .missingOutput(let name):
            return "Basic Pitch 模型输出缺少张量：\(name)"
        case .unexpectedOutputShape(let expected, let actual):
            return "Basic Pitch 模型输出不符合预期（期望 \(expected)，实际 \(actual)）"
        }
    }
}

/// 隔离说明：分窗推理为重计算，标 nonisolated 以豁免工程的默认 MainActor 隔离，
/// 确保从后台任务调用时不会隐式跳回主线程（模型缓存由 modelLock 保护）。
nonisolated enum BasicPitchInference {

    // MARK: - 常量（inference.ts L34-46，逐一对齐）

    static let numChannels = 1
    /// Basic Pitch 模型要求输入 22050 Hz 单声道
    static let audioSampleRate = 22050.0
    static let fftHop = 256
    /// floor(22050 / 256) = 86 帧/秒
    static let annotationsFPS = Int(floor(audioSampleRate / Double(fftHop)))
    /// 22050 × 2 − 256 = 43844
    static let audioNSamples = Int(audioSampleRate) * 2 - fftHop
    /// 相邻窗口重叠的帧数
    static let nOverlappingFrames = 30
    /// floor(30 / 2) = 15
    static let nOverlapOver2 = Int(floor(Double(nOverlappingFrames) / 2))
    /// 30 × 256 = 7680（JS 构造函数校验其能被 2 整除）
    static let overlapLengthFrames = nOverlappingFrames * fftHop
    /// 43844 − 7680 = 36164
    static let hopSize = audioNSamples - overlapLengthFrames

    /// 模型输出张量名（inference.ts L26-30 OUTPUT_TO_TENSOR_NAME）
    private static let outputFramesName = "Identity_1"
    private static let outputOnsetsName = "Identity_2"
    private static let outputContoursName = "Identity"
    /// 模型输入张量名
    private static let inputName = "input_2"

    // MARK: - 模型缓存（对齐 JS BasicPitch 实例对 model Promise 的缓存）

    private static let modelLock = NSLock()
    private static var cachedModel: MLModel?

    /// 懒加载 CoreML 模型（线程安全单例；无需 MLModelCompileAtURL，Xcode 已自动编译）
    private static func acquireModel() throws -> MLModel {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let model = cachedModel { return model }
        guard let url = Bundle.main.url(forResource: "nmp", withExtension: "mlpackagec")
            ?? Bundle.main.url(forResource: "nmp", withExtension: "mlmodelc") else {
            throw BasicPitchInferenceError.modelNotFound
        }
        // cpuOnly：与 JS 参考实现（纯 CPU）数值路径最接近，且规避模拟器 GPU 加速的兼容不确定性
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: config)
        cachedModel = model
        return model
    }

    // MARK: - 主入口（对应 JS evaluateModel）

    /// 将 22050 Hz 单声道 Float32 采样送入 Basic Pitch 模型，返回去重叠拼接后的
    /// frames / onsets / contours 矩阵（[帧][频率bin]）。
    ///
    /// - Parameters:
    ///   - samples: 单声道 22050 Hz 采样
    ///   - progress: 每窗推理前的进度回调（已处理窗数/总窗数；结束后回调 1.0），
    ///     对齐 JS percentCallback(i / shape[0]) 与结尾 percentCallback(1.0)；
    ///     在推理线程上同步调用
    static func evaluate(
        samples: [Float],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> WindowedResult {
        // prepareData（inference.ts L113-128）：
        // JS: tf.concat1d([tf.zeros([Math.floor(OVERLAP_LENGTH_FRAMES / 2)]), tf.tensor(audio)])
        let padCount = overlapLengthFrames / 2 // floor(7680/2) = 3840
        var wavSamples = [Double](repeating: 0, count: padCount)
        wavSamples.append(contentsOf: samples.map { Double($0) })
        let audioOriginalLength = samples.count

        // tf.signal.frame(wavSamples, AUDIO_N_SAMPLES, HOP_SIZE, padEnd=true, padValue=0)
        // —— 逐字翻译 tfjs-core frame_ 的两个 while 循环：
        //    1) 完整窗：start + 43844 <= 总长时切一窗，start += 36164；
        //    2) padEnd 残余窗：起点未越过信号末尾（start < 总长）时，
        //       取剩余样本并在尾部补零凑满 43844，start += 36164。
        var windowSlices: [(offset: Int, padLength: Int)] = []
        var start = 0
        while start + audioNSamples <= wavSamples.count {
            windowSlices.append((offset: start, padLength: 0))
            start += hopSize
        }
        while start < wavSamples.count {
            let padLength = (start + audioNSamples) - wavSamples.count
            windowSlices.append((offset: start, padLength: padLength))
            start += hopSize
        }
        let nWindows = windowSlices.count

        // JS: nOutputFramesOriginal = Math.floor(audioOriginalLength * (ANNOTATIONS_FPS / AUDIO_SAMPLE_RATE))
        let nOutputFramesOriginal = Int(
            (Double(audioOriginalLength) * (Double(annotationsFPS) / audioSampleRate)).rounded(.down)
        )

        let model = try acquireModel()

        var allFrames = [[Double]]()
        var allOnsets = [[Double]]()
        var allContours = [[Double]]()
        var calculatedFrames = 0

        for (i, window) in windowSlices.enumerated() {
            // 支持任务取消
            try Task.checkCancellation()
            // JS: percentCallback(i / reshapedInput.shape[0])
            progress?(Double(i) / Double(nWindows))

            // 取第 i 窗（pad 窗尾部补零凑满 43844）
            var windowScalars = Array(
                wavSamples[window.offset..<min(window.offset + audioNSamples, wavSamples.count)]
            )
            if windowScalars.count < audioNSamples {
                windowScalars.append(
                    contentsOf: [Double](repeating: 0, count: audioNSamples - windowScalars.count)
                )
            }

            let (frames, onsets, contours) = try predict(
                windowScalars: windowScalars.map { Float($0) },
                model: model
            )
            let unwrappedFrames = try unwrapOutput(frames)
            let unwrappedOnsets = try unwrapOutput(onsets)
            let unwrappedContours = try unwrapOutput(contours)

            // JS evaluateModel L203-228：累计帧数与截断逻辑，逐字翻译。
            // 注意：calculatedFrames += 的是截断前的整窗帧数（与 JS 一致），
            // 超出目标帧数后的窗口整窗丢弃（continue）。
            let calculatedFramesTmp = unwrappedFrames.count
            if calculatedFrames >= nOutputFramesOriginal {
                continue
            }
            if calculatedFramesTmp + calculatedFrames >= nOutputFramesOriginal {
                let framesToOutput = nOutputFramesOriginal - calculatedFrames
                allFrames.append(contentsOf: unwrappedFrames.prefix(framesToOutput))
                allOnsets.append(contentsOf: unwrappedOnsets.prefix(framesToOutput))
                allContours.append(contentsOf: unwrappedContours.prefix(framesToOutput))
            } else {
                allFrames.append(contentsOf: unwrappedFrames)
                allOnsets.append(contentsOf: unwrappedOnsets)
                allContours.append(contentsOf: unwrappedContours)
            }
            calculatedFrames += calculatedFramesTmp
        }

        // JS: percentCallback(1.0)
        progress?(1.0)
        return WindowedResult(frames: allFrames, onsets: allOnsets, contours: allContours)
    }

    // MARK: - 单窗推理（对应 JS evaluateSingleFrame）

    /// 对单窗 [43844] 采样执行模型推理，返回 frames/onsets/contours 三个输出张量
    private static func predict(
        windowScalars: [Float],
        model: MLModel
    ) throws -> (frames: MLMultiArray, onsets: MLMultiArray, contours: MLMultiArray) {
        precondition(windowScalars.count == audioNSamples)
        // 输入 [1, 43844, 1] Float32
        let shaped = MLShapedArray<Float>(scalars: windowScalars, shape: [1, audioNSamples, 1])
        let input = MLFeatureValue(multiArray: MLMultiArray(shaped))
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
        let output = try model.prediction(from: provider)
        return (
            frames: try outputMultiArray(output, name: outputFramesName),
            onsets: try outputMultiArray(output, name: outputOnsetsName),
            contours: try outputMultiArray(output, name: outputContoursName)
        )
    }

    /// 读取输出张量：先精确匹配键名，再做带 `:` 后缀（如 "Identity:0"）的容错映射。
    /// 容错收紧：仅接受 `key == name` 或 `key = name + ":xxx"` 变体——拒绝其它
    /// 碰巧以 name 为前缀的键（如 "Identity_1" 对 name "Identity"），避免误映射到
    /// 无关张量。精确匹配优先（第一段直接命中即返回），多候选按 featureNames
    /// 自然顺序取首个，保证确定性。
    private static func outputMultiArray(
        _ provider: MLFeatureProvider,
        name: String
    ) throws -> MLMultiArray {
        if let value = provider.featureValue(for: name), let array = value.multiArrayValue {
            return array
        }
        for key in provider.featureNames
        where key.hasPrefix(name) && key.dropFirst(name.count).hasPrefix(":") {
            if let value = provider.featureValue(for: key), let array = value.multiArrayValue {
                return array
            }
        }
        throw BasicPitchInferenceError.missingOutput(name)
    }

    // MARK: - 去重叠（对应 JS unwrapOutput）

    /// JS: result.slice([0, N_OVERLAP_OVER_2, 0], [-1, shape[1] - 2*N_OVERLAP_OVER_2, -1])
    ///     → reshape([shape[0] * keptRows, shape[2]])
    /// 单窗输出 [1, 172, cols] → 掐头去尾各 15 帧 → [142, cols]
    private static func unwrapOutput(_ multiArray: MLMultiArray) throws -> [[Double]] {
        let shape = multiArray.shape.map { $0.intValue }
        guard shape.count == 3, shape[0] == 1, shape[1] > 2 * nOverlapOver2 else {
            throw BasicPitchInferenceError.unexpectedOutputShape(
                expected: "[1, ≥31, cols]",
                actual: "\(shape)"
            )
        }
        let totalRows = shape[1]
        let cols = shape[2]
        let keptRows = totalRows - 2 * nOverlapOver2

        let scalars = try readFloatScalars(multiArray)
        var rows = [[Double]]()
        rows.reserveCapacity(keptRows)
        for r in nOverlapOver2..<(nOverlapOver2 + keptRows) {
            let base = r * cols
            rows.append(Array(scalars[base..<(base + cols)]))
        }
        return rows
    }

    /// MLMultiArray(Float32) → 逻辑行主序 [Double]。
    ///
    /// 必须按实际 strides 寻址：MLProgram 输出缓冲区会把行 pad 到对齐边界
    /// （实测 [1,172,88] 行 stride=96、[1,172,264] 行 stride=272），
    /// 线性读 dataPointer 会把 padding 脏数据与相邻行错位混入（整矩阵被"剪切"）。
    private static func readFloatScalars(_ multiArray: MLMultiArray) throws -> [Double] {
        guard multiArray.dataType == .float32 else {
            throw BasicPitchInferenceError.unexpectedOutputShape(
                expected: "Float32 张量",
                actual: "dataType \(multiArray.dataType.rawValue)"
            )
        }
        let shape = multiArray.shape.map { $0.intValue }
        let strides = multiArray.strides.map { $0.intValue }
        guard shape.count == 3, strides.count == 3 else {
            throw BasicPitchInferenceError.unexpectedOutputShape(
                expected: "三维张量",
                actual: "shape \(shape)"
            )
        }
        let rows = shape[1]
        let cols = shape[2]
        let rowStride = strides[1]
        let colStride = strides[2]
        let pointer = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
        var result = [Double](repeating: 0, count: rows * cols)
        var idx = 0
        for r in 0..<rows {
            let base = r * rowStride
            for c in 0..<cols {
                result[idx] = Double(pointer[base + c * colStride])
                idx += 1
            }
        }
        return result
    }
}
