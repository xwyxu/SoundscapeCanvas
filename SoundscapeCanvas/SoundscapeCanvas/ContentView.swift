//
//  ContentView.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import SwiftUI
import UniformTypeIdentifiers

/// 主界面：黑色主题。
/// 未导入 → 居中导入入口（标题 + 导入按钮）；
/// 已导入 → 上方钢琴块画布（含固定竖线，占满剩余空间）+ 底部播放控制栏。
struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var showImporter = false
    @State private var showOnlineSearch = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.importedAudio != nil {
                importedView
            } else {
                emptyStateView
            }
        }
        // 统一错误横幅：悬浮于界面顶部（画布区上方；导入失败时未进入画布态也可显示），
        // 6 秒自动消失（AppViewModel 调度），点击横幅任意处或 xmark 立即关闭
        .overlay(alignment: .top) {
            if let errorMessage = viewModel.errorMessage {
                ErrorBanner(
                    message: errorMessage,
                    dismissAction: { viewModel.dismissError() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.errorMessage)
        // 视频渲染中覆盖层：半透明黑遮罩拦截触摸（渲染互斥），带进度与取消
        .overlay {
            if viewModel.exportState == .rendering {
                ExportRenderingOverlay(
                    progress: viewModel.exportProgress,
                    cancelAction: { viewModel.cancelExport() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.exportState)
        // 渲染完成弹出系统分享面板；面板关闭（含下滑）后收敛导出状态
        .sheet(item: shareItem) { file in
            ActivityView(url: file.url)
        }
        // 在线搜索页：下载完成 → 关闭本页 → 该本地文件走现有导入管线
        // （Documents 下文件无 security scope，importAudio 内 startAccessing 返回 false 无副作用）
        .sheet(isPresented: $showOnlineSearch) {
            OnlineSearchView { url in
                showOnlineSearch = false
                viewModel.importAudio(at: url)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { viewModel.runSelfTestIfRequested() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // security-scoped 访问由 AppViewModel.importAudio 全流程管理
                viewModel.importAudio(at: url)
            case .failure(let failure):
                // 边缘加固：用户在选单中点"取消"（NSCocoaErrorDomain userCancelled）
                // 是正常操作路径，不设 errorMessage，避免误报"导入失败"
                let nsError = failure as NSError
                guard !(nsError.domain == NSCocoaErrorDomain
                    && nsError.code == NSUserCancelledError) else { return }
                viewModel.errorMessage = failure.localizedDescription
            }
        }
    }

    // MARK: - 已导入：画布 + 竖线 + 控制栏

    /// TimelineView 每帧重估内容：直接读取 engineTime（采样级时钟）传入画布与控制栏，
    /// 播放中逐帧刷新，暂停时值冻结画面自然静止（不修改任何发布状态，无发布警告）
    private var importedView: some View {
        TimelineView(.animation) { _ in
            VStack(spacing: 0) {
                ZStack {
                    PianoRollCanvasView(
                        melody: viewModel.melody,
                        currentTime: viewModel.engineTime,
                        isPlaying: viewModel.isPlaying,
                        pixelsPerSecond: 120
                    )
                    // 旋律淡入：分析完成（melody nil → 非 nil）时画布 0→1，easeIn 0.25s
                    .opacity(viewModel.melody != nil ? 1 : 0)
                    .animation(.easeIn(duration: 0.25), value: viewModel.melody != nil)
                    PlayheadOverlay()
                    // 分析中占位 / 空结果提示（不拦截触摸，竖线常驻）
                    CanvasStateOverlay(
                        melody: viewModel.melody,
                        isAnalyzing: viewModel.isAnalyzing,
                        analysisProgress: viewModel.analysisProgress
                    )
                }
                .frame(maxHeight: .infinity)

                PlaybackControls(
                    fileName: viewModel.fileName,
                    currentTime: viewModel.engineTime,
                    duration: viewModel.duration,
                    isPlaying: viewModel.isPlaying,
                    analysisProgress: viewModel.analysisProgress,
                    exportEnabled: viewModel.melody != nil && viewModel.exportState != .rendering,
                    onlineSearchEnabled: viewModel.exportState != .rendering,
                    playPauseAction: { viewModel.togglePlayPause() },
                    seekAction: { viewModel.seek(to: $0) },
                    importAction: { showImporter = true },
                    onlineSearchAction: { showOnlineSearch = true },
                    exportAction: { viewModel.startExport() }
                )
            }
        }
    }

    // MARK: - 视频导出：分享面板挂载

    /// 分享面板 item 绑定：渲染完成 → 产物文件（文件名已由 VideoExporter 生成，含歌曲名）；
    /// 面板关闭（含下滑）时置 nil 回调 exportDismissed，收敛导出状态允许再次导出
    private var shareItem: Binding<ExportedFile?> {
        Binding(
            get: {
                if case .completed(let url) = viewModel.exportState {
                    return ExportedFile(url: url)
                }
                return nil
            },
            set: { newValue in
                if newValue == nil { viewModel.exportDismissed() }
            }
        )
    }

    // MARK: - 空态：导入入口

    private var emptyStateView: some View {
        VStack(spacing: 28) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.85))

            VStack(spacing: 6) {
                Text("Soundscape Canvas")
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .foregroundStyle(.white)
                Text("意境")
                    .font(.title3)
                    .tracking(8)
                    .padding(.leading, 8)   // 补偿 tracking 末尾间距，保持视觉居中
                    .foregroundStyle(.white.opacity(0.5))
            }

            // 两个来源入口并排：本地导入（主）+ 在线搜索（次，描边胶囊）；
            // 水平内边距 20 保证窄屏（320pt）单行放下
            HStack(spacing: 16) {
                Button(action: { showImporter = true }) {
                    Label("导入音频", systemImage: "folder.badge.plus")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.white.opacity(0.9)))
                }
                .accessibilityLabel("导入本地音频文件")

                Button(action: { showOnlineSearch = true }) {
                    Label("在线搜索", systemImage: "music.note.list")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                }
                .accessibilityLabel("在线搜索音乐")
            }
        }
        .padding()
    }
}

// MARK: - 视频导出辅助视图

/// 分享面板挂载包装：Identifiable 供 `.sheet(item:)` 使用
private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// UIKit 分享面板包装（UIActivityViewController，iPhone 上面板以 sheet 形式呈现）：
/// 分享产物为临时目录 MP4（保存到相册/文件或其他 App），presentedURL 直接使用
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 视频渲染中覆盖层：半透明黑遮罩（拦截触摸实现渲染互斥）+ 呼吸图标 + 百分比
/// + 细进度条 + 取消按钮。呼吸风格为 AnalyzingPlaceholder 的简化版
/// （TimelineView 正弦 opacity，不引入额外动画状态）。
private struct ExportRenderingOverlay: View {
    /// 呼吸周期（秒），对齐 AnalyzingPlaceholder
    private static let breathingPeriod: TimeInterval = 1.6
    /// 进度条总宽（对齐分析占位样式）
    private static let barWidth: CGFloat = 200

    let progress: Double
    let cancelAction: () -> Void

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                * 2 * .pi / Self.breathingPeriod
            // 0.7 ± 0.3 → opacity 在 0.4–1.0 间正弦呼吸
            let breathing = 0.7 + 0.3 * sin(phase)
            let clamped = min(max(progress, 0), 1)

            ZStack {
                Color.black.opacity(0.75).ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.white.opacity(breathing))

                    Text("视频渲染中 \(Int(clamped * 100))%")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))

                    // 细进度条：暗轨道 + 白色已填充段（对齐分析占位样式）
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: Self.barWidth * clamped)
                    }
                    .frame(width: Self.barWidth, height: 4)
                }

                // 取消按钮：右上角 xmark（对齐 ErrorBanner 的关闭交互）
                VStack {
                    HStack {
                        Spacer()
                        Button(action: cancelAction) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(.white.opacity(0.12)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("取消导出")
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
