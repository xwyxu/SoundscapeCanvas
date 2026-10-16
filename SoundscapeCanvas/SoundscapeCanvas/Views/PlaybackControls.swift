//
//  PlaybackControls.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import SwiftUI

/// 底部播放控制栏：分析进度 / 时间与进度滑杆 / 导入与播放暂停按钮 / 文件名。
///
/// 错误提示已迁移为画布区顶部 `ErrorBanner` 横幅（见本文件底部），
/// 本视图不再展示错误文本。
///
/// 滑杆策略：拖动中仅更新本地 `dragValue`（避免每帧 seek 与画面回跳），
/// 编辑结束（松手）才调用 `seekAction` 真正跳转。
struct PlaybackControls: View {
    let fileName: String?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let analysisProgress: Double?
    /// 是否允许发起视频导出（旋律已生成且非渲染中）；渲染中按钮禁用
    let exportEnabled: Bool
    /// 是否允许打开在线搜索页（渲染导出中禁用，渲染互斥）
    let onlineSearchEnabled: Bool
    let playPauseAction: () -> Void
    let seekAction: (TimeInterval) -> Void
    let importAction: () -> Void
    let onlineSearchAction: () -> Void
    let exportAction: () -> Void

    /// 拖动中的临时进度；nil 表示未在拖动（显示实时 currentTime）
    @State private var dragValue: Double?

    var body: some View {
        VStack(spacing: 12) {
            if let analysisProgress {
                let clamped = min(max(analysisProgress, 0), 1)
                VStack(spacing: 4) {
                    ProgressView(value: clamped)
                    Text("旋律分析中 \(Int(clamped * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Text(Self.formatTime(dragValue ?? currentTime))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { dragValue ?? currentTime },
                        set: { dragValue = $0 }
                    ),
                    in: 0...max(duration, 0.001),
                    onEditingChanged: { editing in
                        // 编辑结束才真正 seek；拖动中只更新本地拖动值避免回跳
                        if !editing {
                            if let value = dragValue { seekAction(value) }
                            dragValue = nil
                        }
                    }
                )
                .tint(.white.opacity(0.85))

                Text(Self.formatTime(duration))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            // 间距由 40 收窄到 28：四按钮（44pt 触达区）在窄屏（320pt）也可单行放下
            HStack(spacing: 28) {
                Button(action: importAction) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("导入音频")
                // 在线搜索：与现有按钮同风格（圆形触达区 + 白色图标）；渲染导出中禁用（渲染互斥）
                Button(action: onlineSearchAction) {
                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .disabled(!onlineSearchEnabled)
                .opacity(onlineSearchEnabled ? 1 : 0.3)
                .accessibilityLabel("在线搜索")
                Button(action: playPauseAction) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .imageScale(.large)
                        .frame(width: 44, height: 44)
                }
                // 下载视频：与现有按钮同风格（圆形触达区 + 白色图标）；
                // 旋律未生成或渲染中禁用（渲染互斥由覆盖层与 ViewModel 双重兜底）
                Button(action: exportAction) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .disabled(!exportEnabled)
                .opacity(exportEnabled ? 1 : 0.3)
                .accessibilityLabel("导出视频")
            }
            .foregroundStyle(.white)

            if let fileName {
                Text(fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// 手动格式化 "m:ss"（左侧实时/拖动值，右侧总时长，合成 "m:ss / m:ss" 语义）
    static func formatTime(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 统一错误横幅：画布区顶部悬浮，红调黑底贴合黑色主题（圆角 8、左右边距 16 由调用方控制）。
///
/// 出现/消失带 opacity + 顶部滑入过渡（transition 由调用方挂载）；
/// 6 秒自动消失由 `AppViewModel` 调度，点击横幅任意处或 xmark 按钮立即关闭。
/// 错误期间导入/播放等其他功能不受影响（横幅仅覆盖顶部窄条）。
struct ErrorBanner: View {
    let message: String
    let dismissAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                )
        )
        // 点击横幅任意处关闭（xmark 按钮命中时由按钮响应，行为一致）
        .onTapGesture { dismissAction() }
    }
}
