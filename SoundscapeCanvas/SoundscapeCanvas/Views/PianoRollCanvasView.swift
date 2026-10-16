//
//  PianoRollCanvasView.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import SwiftUI

/// 钢琴块旋律画布：纯黑背景，时间 → X 轴（左→右），MIDI 21–108 → Y 轴（低音在下）。
///
/// 薄壳视图：仅负责 TimelineView 逐帧驱动 + Canvas 承载，全部绘制内容委托给同源渲染
/// 函数 `PianoRollRenderer.drawPianoRoll`（背景、音符块、发光、弯音线均由其完成），
/// 与离屏视频渲染共用同一实现，避免双实现漂移；几何/视觉常量以 `PianoRollRenderer`
/// 为单一事实来源。竖线仍由 `PlayheadOverlay` 独立绘制（不在渲染函数内）。
///
/// `currentTime` 由播放引擎采样级时钟驱动（外层 TimelineView 每帧传入最新值），
/// 暂停时该值冻结，画面自然静止，无跳变。
struct PianoRollCanvasView: View {
    let melody: MelodyData?
    let currentTime: TimeInterval
    let isPlaying: Bool
    var pixelsPerSecond: CGFloat = 120

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                PianoRollRenderer.drawPianoRoll(
                    to: context,
                    size: size,
                    melody: melody,
                    currentTime: currentTime,
                    pixelsPerSecond: pixelsPerSecond
                )
            }
        }
    }
}

/// 画布状态覆盖层：叠加在画布与竖线之上（画布背景与竖线常驻，覆盖内容居中）。
///
/// - 分析中（`isAnalyzing`）：声波图标正弦呼吸（TimelineView 驱动，opacity 0.4→1.0）
///   + "旋律分析中 xx%" 文本 + 宽 200pt 细进度条；
/// - 空态（旋律已完成但未检出音符）：居中灰字提示。
///
/// 覆盖层不拦截触摸（`allowsHitTesting(false)`），分析期间播放控制不受影响；
/// 竖线由 `PlayheadOverlay` 独立绘制，不受本层影响。
struct CanvasStateOverlay: View {
    let melody: MelodyData?
    let isAnalyzing: Bool
    let analysisProgress: Double?

    var body: some View {
        ZStack {
            if isAnalyzing {
                AnalyzingPlaceholder(progress: analysisProgress)
            } else if let melody, melody.notes.isEmpty {
                Text("未检测到清晰的旋律线条")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 分析中占位：呼吸声波图标 + 进度文本 + 细进度条。
///
/// 呼吸相位由 TimelineView(.animation) 每帧从当前时间计算（正弦、周期 1.6s），
/// opacity 在 0.4–1.0 间平滑往复；该驱动方式与画布/竖线的帧驱动一致，无状态残留。
private struct AnalyzingPlaceholder: View {
    /// 呼吸周期（秒）
    private static let breathingPeriod: TimeInterval = 1.6
    /// 进度条总宽
    private static let barWidth: CGFloat = 200

    let progress: Double?

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                * 2 * .pi / Self.breathingPeriod
            // 0.7 ± 0.3 → opacity 在 0.4–1.0 间正弦呼吸
            let breathing = 0.7 + 0.3 * sin(phase)

            VStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(breathing))

                Text(progressText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))

                analysisBar
            }
        }
    }

    /// 进度文本：回调未到达（progress 为 nil）时显示不带百分比的提示；
    /// 推理完成（100%）后进入音符解码阶段，切换文案避免被误认为卡死
    private var progressText: String {
        guard let progress else { return "旋律分析中…" }
        let clamped = clampedProgress(progress)
        if clamped >= 1.0 { return "正在生成音符数据…" }
        return "旋律分析中 \(Int(clamped * 100))%"
    }

    /// 宽 200pt 细进度条：暗轨道 + 白色已填充段，进度变化带短动画平滑
    private var analysisBar: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.15))
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: Self.barWidth * CGFloat(clamped), height: 3)
        }
        .frame(width: Self.barWidth, height: 3)
        .animation(.linear(duration: 0.2), value: clamped)
    }

    /// 归一化进度（0–1）：nil 视为 0
    private var clamped: Double {
        progress.map { clampedProgress($0) } ?? 0
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
