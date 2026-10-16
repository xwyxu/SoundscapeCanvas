//
//  AudioLoader.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import Accelerate
import AVFoundation
import Foundation

/// 音频加载/解码错误
enum AudioLoadError: LocalizedError {
    /// 文件在磁盘上不存在（或不可访问）
    case fileNotFound
    /// 无法按音频格式打开（容器/编码不受支持）
    case unsupportedFormat
    /// 打开成功但读取/解码 PCM 数据失败（附具体原因）
    case decodeFailed(String)

    /// 面向用户的中文错误描述
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "找不到所选音频文件，请重新选择。"
        case .unsupportedFormat:
            return "不支持该音频格式，请选择 WAV、MP3、M4A、AAC、FLAC、AIFF 或 CAF 文件。"
        case .decodeFailed(let reason):
            return "音频解码失败：\(reason)"
        }
    }
}

/// 音频文件解码器：AVAudioFile → Float32 原始声道缓冲 + 下混单声道采样。
///
/// 设计说明：
/// - 统一经 `AVAudioFile.processingFormat`（恒为 deinterleaved Float32）解码，
///   播放缓冲与分析采样共用同一次解码结果，避免二次解码开销；
/// - 分段读取（每段 64K 帧）后拼装为整轨缓冲，避免超长文件一次性
///   `read` 触发超大内存分配失败；
/// - 多声道按“各声道平均”下混为 mono（与 JS 参考实现一致）；
/// - 本方法为同步 CPU 密集操作，调用方负责放到后台线程执行。
///
/// 隔离说明：解码为重计算，标 nonisolated 以豁免工程的默认 MainActor 隔离，
/// 确保从后台任务调用时不会隐式跳回主线程。
nonisolated enum AudioLoader {

    /// 分段读取的块大小（帧）：64K ≈ 1.5s @44.1kHz
    private static let chunkFrames: AVAudioFrameCount = 65_536

    /// 加载并解码音频文件。
    ///
    /// - Parameter url: 音频文件 URL（wav/mp3/m4a/aac/flac/aiff/caf 等
    ///   AVAudioFile 可解码的格式）
    /// - Returns: 原始声道播放缓冲 + 下混单声道采样 + 元信息
    /// - Throws: `AudioLoadError`
    static func load(url: URL) throws -> LoadedAudio {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioLoadError.fileNotFound
        }

        // 打开文件并统一解码为处理格式（Float32、deinterleaved）
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            // 文件已确认存在却打不开：几乎都是容器/编码不受支持
            throw AudioLoadError.unsupportedFormat
        }

        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioLoadError.unsupportedFormat
        }
        guard file.length > 0 else {
            throw AudioLoadError.decodeFailed("文件不包含音频数据")
        }
        guard file.length <= AVAudioFramePosition(AVAudioFrameCount.max) else {
            throw AudioLoadError.decodeFailed("音频长度超出可处理范围")
        }

        let totalFrames = AVAudioFrameCount(file.length)
        let channels = Int(format.channelCount)

        // 目标整轨缓冲（容量按文件头声明的帧数分配，最终以实际读取为准）
        guard let fullBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw AudioLoadError.decodeFailed("无法分配音频缓冲区")
        }

        // 分段读取缓冲（复用同一块内存，逐段拷贝拼装）
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(chunkFrames, totalFrames)) else {
            throw AudioLoadError.decodeFailed("无法分配读取缓冲区")
        }

        var framesRead: AVAudioFrameCount = 0
        while framesRead < totalFrames {
            let want = min(chunkFrames, totalFrames - framesRead)
            chunk.frameLength = 0
            do {
                try file.read(into: chunk, frameCount: want)
            } catch {
                throw AudioLoadError.decodeFailed(error.localizedDescription)
            }
            let got = chunk.frameLength
            // 文件头声明的长度虚高（截断/损坏文件）时提前结束
            guard got > 0 else { break }
            for ch in 0..<channels {
                guard let src = chunk.floatChannelData?[ch],
                      let dst = fullBuffer.floatChannelData?[ch] else { continue }
                dst.advanced(by: Int(framesRead)).update(from: src, count: Int(got))
            }
            framesRead += got
        }

        guard framesRead > 0 else {
            throw AudioLoadError.decodeFailed("未能读取到音频数据")
        }
        fullBuffer.frameLength = framesRead

        let sampleRate = format.sampleRate
        return LoadedAudio(
            playbackBuffer: fullBuffer,
            monoSamples: downmixToMono(fullBuffer, frames: Int(framesRead)),
            sampleRate: sampleRate,
            duration: Double(framesRead) / sampleRate,
            fileName: url.lastPathComponent
        )
    }

    /// 多声道平均下混为单声道（vDSP 加速）。
    ///
    /// - 单声道：直接拷贝；
    /// - 多声道：各声道累加后统一乘 1/声道数（双缓冲交替累加，避免 vDSP 原位操作）。
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer, frames: Int) -> [Float] {
        let channels = Int(buffer.format.channelCount)

        if channels == 1 {
            var mono = [Float](repeating: 0, count: frames)
            if let src = buffer.floatChannelData?[0] {
                mono.replaceSubrange(0..<frames, with: UnsafeBufferPointer(start: src, count: frames))
            }
            return mono
        }

        var acc = [Float](repeating: 0, count: frames)
        var tmp = [Float](repeating: 0, count: frames)
        for ch in 0..<channels {
            guard let src = buffer.floatChannelData?[ch] else { continue }
            vDSP_vadd(acc, 1, src, 1, &tmp, 1, vDSP_Length(frames))
            swap(&acc, &tmp)
        }
        var scale = 1.0 / Float(channels)
        var mono = [Float](repeating: 0, count: frames)
        vDSP_vsmul(acc, 1, &scale, &mono, 1, vDSP_Length(frames))
        return mono
    }
}
