//
//  MelodyNote.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import AVFoundation
import Foundation

/// 音符的声部角色（双旋律识别，三色语义与钢琴块着色一一对应）：
/// - `.background`：其余音符（和弦垫/伴奏/低音等）→ 银白 #C8C8C8
/// - `.melody`：主旋律线 → 黄色 #FFFF00
/// - `.countermelody`：主要副旋律线 → 浅蓝 #87CEEB
nonisolated enum MelodyRole: String, Codable, Sendable {
    case background
    case melody
    case countermelody
}

/// 单个旋律音符（字段对齐 JS 参考实现的 `MelodyNote` 类型）
///
/// 隔离说明：纯数据容器（无 UI 状态），整型 nonisolated 豁免默认 MainActor 隔离，
/// 允许后台分析管线直接构造/读取（新增可变 `role` 字段后，若保持默认 MainActor
/// 隔离，其逐一成员构造器会变为 actor 隔离，导致后台构造无法编译）。
nonisolated struct MelodyNote: Sendable, Equatable {
    /// 音符起始时间（秒）
    let startTime: TimeInterval
    /// 音符结束时间（秒，不含）
    let endTime: TimeInterval
    /// MIDI 音高编号（21–108 对应完整钢琴音域）
    let midiNote: Int
    /// 置信度（0–1，源自模型输出的 amplitude）
    let confidence: Double
    /// 逐帧弯音值（单位：半音）。无弯音时为 nil（对齐 JS 的可选字段）
    let pitchBends: [Double]?
    /// 声部角色（默认 background，既有调用零破坏；由 VoiceSeparator 在分析管线中回写）
    var role: MelodyRole = .background
}

/// 一段音频的完整旋律提取结果
struct MelodyData: Sendable, Equatable {
    /// 全部音符（按起始时间升序排列）
    let notes: [MelodyNote]
    /// 模型时间分辨率（秒/帧；Basic Pitch 为 256/22050 ≈ 11.61ms）
    let timeResolution: TimeInterval
}

/// 已加载的音频：一次解码同时服务两条链路。
///
/// - `playbackBuffer`：保留原始声道，供 `PlaybackEngine` 播放；
/// - `monoSamples`：多声道平均下混的单声道采样，供旋律分析管线。
///
/// 注意：`AVAudioPCMBuffer` 非 Sendable，故本类型不声明 Sendable；
/// 加载完成后仅作只读共享（播放与分析均不修改 buffer 内容）。
/// 隔离说明：纯数据容器（无 UI 状态），整型 nonisolated 豁免默认 MainActor 隔离，
/// 允许后台解码/分析线程与离屏视频渲染直接访问。
nonisolated struct LoadedAudio {
    /// 原始声道 Float32 缓冲（deinterleaved），用于播放
    let playbackBuffer: AVAudioPCMBuffer
    /// 下混单声道采样（多声道取平均），用于旋律分析
    let monoSamples: [Float]
    /// 采样率（Hz），与 playbackBuffer 的格式一致
    let sampleRate: Double
    /// 总时长（秒）= 实际解码帧数 / 采样率
    let duration: TimeInterval
    /// 源文件名（含扩展名），供 UI 显示
    let fileName: String
}
