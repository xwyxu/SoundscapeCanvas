//
//  MelodyAnalysisService.swift
//  SoundscapeCanvas
//
//  旋律分析管线编排 —— 逐字翻译自
//  参考文件/mawimbi-master/src/features/transcription/MelodyExtractor.ts 的
//  extractMelody（L154-230）与常量（L45-68）。
//
//  管线：单声道采样 → 线性重采样至 22050 Hz → Basic Pitch 分窗推理（CoreML）
//       → outputToNotesPoly 音符解码 → 弯音提取 → 帧转秒 → MelodyData
//
//  并发说明：
//  - 重计算（解码/重采样/推理/音符解码）全部在后台 Task 中执行，不阻塞主线程；
//  - 进度回调标记 @MainActor，由推理线程经 Task { @MainActor } 桥接发布；
//  - 支持 Task 取消：外层任务 cancel → 联动取消后台任务 → 推理循环抛 CancellationError。
//

import Foundation

final class MelodyAnalysisService: @unchecked Sendable {

    static let shared = MelodyAnalysisService()
    private init() {}

    // MARK: - 常量（MelodyExtractor.ts L45-68）

    /// Basic Pitch 模型采样率 —— 音频必须重采样到该值
    private static let modelSampleRate = 22050.0
    /// Basic Pitch FFT hop（来自模型常量）
    private static let fftHop = 256.0
    /// 模型输出的时间分辨率（秒/帧）= 256 / 22050 ≈ 11.61 ms
    private static let timeResolution = fftHop / modelSampleRate
    /// 音符起始检测阈值
    private static let onsetThreshold = 0.5
    /// 音符延续的帧能量阈值
    private static let frameThreshold = 0.3
    /// 最短音符长度（帧）；5 帧 ≈ 58 ms
    private static let minNoteLengthFrames = 5
    /// 旋律提取频率下界（Hz）
    private static let minFrequency = 55.0
    /// 旋律提取频率上界（Hz）
    private static let maxFrequency = 1760.0

    // MARK: - 入口

    /// 分析一个音频文件：先解码（后台），再走采样分析管线。
    func analyze(
        url: URL,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> MelodyData {
        // AudioLoader.load 为同步 CPU 密集操作（其文档要求调用方放到后台线程执行）
        let (monoSamples, sampleRate): ([Float], Double) = try await runOnBackground {
            let audio = try AudioLoader.load(url: url)
            return (audio.monoSamples, audio.sampleRate)
        }
        return try await analyze(samples: monoSamples, sampleRate: sampleRate, progress: progress)
    }

    /// 分析单声道采样，返回旋律数据。
    ///
    /// - Parameters:
    ///   - samples: 单声道采样（任意采样率，内部线性重采样至 22050 Hz）
    ///   - sampleRate: 采样率（Hz）
    ///   - progress: 进度回调（0...1，主线程发布）
    func analyze(
        samples: [Float],
        sampleRate: Double,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> MelodyData {
        // 桥接：推理线程的进度回调 → 主线程（fire-and-forget，进度显示无需严格时序）
        let bridge: (@Sendable (Double) -> Void)?
        if let progress {
            bridge = { value in Task { @MainActor in progress(value) } }
        } else {
            bridge = nil
        }

        return try await runOnBackground {
            // 边缘加固（spec 5.1）：样本数不足以产生任何输出帧时直接返回空结果。
            // 1 输出帧至少需要 modelSampleRate / annotationsFPS ≈ 256.4 个采样
            // （nOutputFramesOriginal = floor(n × 86 / 22050)，0 帧 ⇒ 无法分窗出有效数据），
            // 此时对空/极短输入做整窗推理与解码毫无意义，返回空 MelodyData 而非空跑管线。
            // 测试辅助：用 count < 257 的 samples（如空数组、单点采样）即可触发本分支。
            guard Double(samples.count) * Double(BasicPitchInference.annotationsFPS) >= Self.modelSampleRate else {
                return MelodyData(notes: [], timeResolution: Self.timeResolution)
            }

            // 1) 重采样（MelodyExtractor.ts L164）：
            //    Float→Double 无损；Resampler 在 Double 域对齐 JS number 算术
            let monoDoubles = samples.map { Double($0) }
            let resampled = Resampler.resampleLinear(
                monoDoubles,
                from: sampleRate,
                to: Self.modelSampleRate
            )

            // 2) 分窗推理（分窗/拼接与 inference.ts 逐字一致）
            let windowed = try await BasicPitchInference.evaluate(
                samples: resampled.map { Float($0) },
                progress: bridge
            )

            // 3) 解码（MelodyExtractor.ts L194-206）：
            //    阈值/频率上下界与 JS 调用点逐一对应
            let noteEvents = try NoteDecoder.outputToNotesPoly(
                frames: windowed.frames,
                onsets: windowed.onsets,
                onsetThreshold: Self.onsetThreshold,
                frameThreshold: Self.frameThreshold,
                minNoteLength: Self.minNoteLengthFrames,
                inferOnsets: true,
                maxFrequency: Self.maxFrequency,
                minFrequency: Self.minFrequency
            )
            let withBends = NoteDecoder.addPitchBendsToNoteEvents(
                contours: windowed.contours,
                notes: noteEvents
            )
            let noteTimes = NoteDecoder.noteFramesToTime(withBends)

            // 4) 映射（MelodyExtractor.ts L212-229）
            //
            //    pitchBends 单位说明：NoteDecoder 输出为 contour bin 数（每半音 3 bins）；
            //    JS 参考实现的 MelodyNote 类型注释声称 "semitones" 但实现直接透传 bins
            //    （其自身疏漏）。本工程 MelodyNote 类型契约为"半音"，故此处除以
            //    contoursBinsPerSemitone 对齐契约。空数组 → nil（对齐 JS
            //    if (n.pitchBends && n.pitchBends.length > 0)）。
            let notes = noteTimes.map { note -> MelodyNote in
                let bendsInSemitones = note.pitchBends.map { bins in
                    bins.map { $0 / Double(NoteDecoder.contoursBinsPerSemitone) }
                }
                let bends = (bendsInSemitones?.isEmpty == false) ? bendsInSemitones : nil
                return MelodyNote(
                    startTime: note.startTimeSeconds,
                    endTime: note.startTimeSeconds + note.durationSeconds,
                    midiNote: note.pitchMidi,
                    confidence: note.amplitude,
                    pitchBends: bends
                )
            }

            // 5) 声部分离（detect-main-countermelody spec）：DSP 显著度（Goertzel
            //    基频能量，决定性无运行漂移）作胜者主信号 + 纯逐拍 argmax 双遍 →
            //    主/副旋律角色回写。纯函数，仍在后台执行链路内执行。
            //    显著度计算用重采样后的 22050 Hz mono（melody f0 ≤ 1760 Hz ≪ Nyquist）。
            let salienceSamples = resampled.map { Float($0) }
            let acousticSalience = VoiceSeparator.computeNoteSalience(
                samples: salienceSamples, sampleRate: Self.modelSampleRate, notes: notes
            )
            let withRoles = VoiceSeparator.assignRoles(
                to: notes, acousticSalience: acousticSalience
            )
            return MelodyData(notes: withRoles, timeResolution: Self.timeResolution)
        }
    }

    // MARK: - 后台执行与取消联动

    /// 在后台执行操作：detached 不继承调用方 actor（避免主线程阻塞），
    /// 外层任务取消时联动取消后台任务，使内部循环能抛出 CancellationError。
    private func runOnBackground<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Swift 6.2 默认 MainActor 隔离下，把 @Sendable 闭包值直接传给
        // Task.detached(operation:) 会因 nonisolated(nonsending) → @isolated(any)
        // 转换失败而无法推断 Success；改为尾随闭包字面量并显式标注 Task 类型。
        // detached 字面量本身为 nonisolated（实测不继承上下文 actor），
        // operation 为 nonisolated(nonsending) async，仍在后台执行器运行。
        let task = Task<T, Error>.detached(priority: .userInitiated) {
            try await operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
