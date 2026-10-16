//
//  AppViewModel.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import Combine
import Foundation

/// 主界面状态机：导入 → 解码装载 → 立即可播放 ∥ 后台旋律分析 → 画布显示。
///
/// 状态收敛规则：
/// - 与播放引擎交互、所有 @Published 更新均在主线程（PlaybackEngine 按主线程调用模型设计）；
/// - 解码与分析为后台任务，结果回主线程收敛；播放与分析完全解耦，
///   分析未完成即可播放，旋律完成后画布无缝出现并立即同步；
/// - `currentTime` 的连续驱动不走发布状态：渲染循环每帧直接查询
///   `engineTime`（采样级时钟，锁保护、无阻塞）；发布值只在离散事件
///   （播放/暂停/seek/自然播完）同步，供滑杆等非画布 UI 使用。
@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - 发布状态

    /// 当前文件名（含扩展名）
    @Published var fileName: String?
    /// 音频总时长（秒）；未加载为 0
    @Published var duration: TimeInterval = 0
    /// 发布的播放位置（离散事件同步；渲染循环用 engineTime）
    @Published var currentTime: TimeInterval = 0
    /// 是否播放中
    @Published var isPlaying = false
    /// 旋律分析结果；分析完成前为 nil（画布空白，仅可播放）
    @Published var melody: MelodyData?
    /// 分析进度（0–1）；非分析态为 nil
    @Published var analysisProgress: Double?
    /// 旋律分析进行中
    @Published var isAnalyzing = false
    /// 面向用户的错误提示（画布区顶部横幅展示）；
    /// 设置后 6 秒自动清除，期间再次设置新错误会重置倒计时（见 didSet）
    @Published var errorMessage: String? {
        didSet { scheduleErrorAutoDismiss() }
    }
    /// 已加载音频；非 nil 即"已导入"状态
    @Published private(set) var importedAudio: LoadedAudio?
    /// 视频导出状态机（完成态携带产物地址，驱动分享面板弹出）
    @Published var exportState: ExportState = .idle
    /// 视频导出渲染进度（0–1）；仅渲染中有意义，覆盖层直接展示
    @Published var exportProgress: Double = 0

    // MARK: - 引擎与任务

    /// 播放引擎（主线程交互）
    let engine = PlaybackEngine()

    /// 旋律分析任务；重复导入时取消旧任务
    private var analysisTask: Task<Void, Never>?

    /// 错误横幅 6 秒自动清除任务；新错误重置计时（旧 Task 直接取消）
    private var errorDismissTask: Task<Void, Never>?

    /// 导入代数：每次导入递增，用于丢弃过期（被新导入取代）的异步结果
    private var importGeneration = 0

    /// 导出任务引用（供取消）；渲染互斥入口在 startExport/cancelExport 收敛
    private var exportTask: Task<Void, Never>?

    /// 导出代数：每次发起导出递增，用于丢弃过期（被取消/新一轮导出取代）的导出结果
    private var exportGeneration = 0

    init() {
        // 自然播完回调（引擎保证主线程派发）：收敛 UI 状态到末尾位置
        engine.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handlePlaybackFinished()
            }
        }
    }

    // MARK: - 派生查询

    /// 采样级实时播放位置：渲染循环每帧直接查询（不触发发布、不修改状态）
    var engineTime: TimeInterval { engine.currentTime }

    // MARK: - 导入

    /// 导入音频：后台解码 → 装载播放引擎 → 立即可播放；随后启动后台旋律分析。
    ///
    /// security-scoped 访问覆盖解码 + 分析全程（分析服务需按 URL 重读文件），
    /// 全流程结束（含取消/失败）后统一释放。
    func importAudio(at url: URL) {
        // 渲染互斥：导出渲染中不接受新导入（视图层已禁用，此处兜底）
        guard exportState != .rendering else { return }
        let secured = url.startAccessingSecurityScopedResource()

        // 收敛旧状态、取消旧分析（旧 scope 由其所属任务的收尾逻辑释放）
        importGeneration += 1
        let generation = importGeneration
        analysisTask?.cancel()
        analysisTask = nil
        melody = nil
        analysisProgress = nil
        isAnalyzing = false
        isPlaying = false
        errorMessage = nil

        // 解码为同步 CPU 密集操作，放后台执行
        let loadTask = Task.detached(priority: .userInitiated) {
            try AudioLoader.load(url: url)
        }

        Task {
            do {
                let audio = try await loadTask.value
                guard generation == importGeneration else {
                    if secured { url.stopAccessingSecurityScopedResource() }
                    return
                }
                // 装载引擎：立即可播放（旋律分析尚未开始）
                engine.load(audio)
                importedAudio = audio
                fileName = audio.fileName
                duration = audio.duration
                currentTime = 0
                isPlaying = false

                // 后台旋律分析，进度回调更新 analysisProgress，完成后画布自动出现
                isAnalyzing = true
                analysisTask = Task { [weak self] in
                    await self?.runAnalysis(generation: generation, url: url)
                    if secured { url.stopAccessingSecurityScopedResource() }
                }
            } catch {
                guard generation == importGeneration else {
                    if secured { url.stopAccessingSecurityScopedResource() }
                    return
                }
                errorMessage = "音频导入失败：\(error.localizedDescription)"
                isAnalyzing = false
                if secured { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: - 播放控制

    /// 播放/暂停切换（引擎交互后同步发布状态）；渲染中禁用（互斥）
    func togglePlayPause() {
        guard exportState != .rendering else { return }
        engine.togglePlayPause()
        isPlaying = engine.isPlaying
        currentTime = engine.currentTime
    }

    /// 跳转（自动 clamp），画面与竖线立即跳到新位置；渲染中禁用（互斥）
    func seek(to time: TimeInterval) {
        guard exportState != .rendering else { return }
        engine.seek(to: time)
        isPlaying = engine.isPlaying
        currentTime = engine.currentTime
    }

    /// 同步采样级时钟到发布状态（离散事件使用；
    /// 连续滚动由渲染循环每帧直接查询 engineTime，不经过本方法）
    func refreshTime() {
        currentTime = engine.currentTime
        isPlaying = engine.isPlaying
    }

    // MARK: - 错误横幅

    /// 点击横幅（任意处或 xmark）立即关闭错误提示
    func dismissError() {
        errorMessage = nil
    }

    /// 错误自动清除调度（errorMessage didSet 触发）：
    /// 先取消旧倒计时（新错误即重置计时），再对非 nil 错误启动 6 秒清除；
    /// 置 nil（手动/自动关闭）时仅取消，不再调度。
    private func scheduleErrorAutoDismiss() {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        guard errorMessage != nil else { return }
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.errorMessage = nil
        }
    }

    // MARK: - 视频导出

    /// 视频导出状态机：空闲 → 渲染中 → 完成（弹分享面板）/ 失败。
    /// 失败态由视图按 idle 处理（错误已进 errorMessage 横幅，可直接重试导出）。
    nonisolated enum ExportState: Equatable {
        /// 空闲（可发起导出）
        case idle
        /// 渲染中（进度覆盖层展示，禁用播放/seek/导入/重复导出）
        case rendering
        /// 渲染完成（携带导出 MP4 地址，触发分享面板）
        case completed(URL)
        /// 渲染失败（半成品已由导出器清理；视图按 idle 处理）
        case failed
    }

    /// 发起视频导出：暂停播放（渲染互斥）→ 后台渲染，进度回写 `exportProgress`。
    /// 前置守卫：音频与旋律已就绪、当前非渲染中（不满足时静默忽略）。
    func startExport() {
        guard exportState == .idle || exportState == .failed else { return }
        guard let audio = importedAudio, let melodyData = melody else { return }

        exportGeneration += 1
        let generation = exportGeneration

        // 渲染互斥：渲染期间暂停音频播放并收敛发布状态
        if engine.isPlaying {
            engine.pause()
            isPlaying = false
        }

        exportProgress = 0
        exportState = .rendering

        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await VideoExporter.export(audio: audio, melody: melodyData) { [weak self] value in
                    // 进度回调已由导出器节流并 hop 主线程，直接发布即可
                    guard let self, generation == self.exportGeneration else { return }
                    self.exportProgress = value
                }
                guard generation == exportGeneration else { return }
                exportState = .completed(result.url)
            } catch {
                // 过期任务（已被取消/新一轮导出取代）：静默退出，不触碰当前状态
                guard generation == exportGeneration else { return }
                if Self.isUserCancellation(error) {
                    // 用户取消：cancelExport 已收敛回 idle，此处兜底保持一致，不报错
                    exportState = .idle
                } else {
                    // 失败：复用错误横幅（6 秒自动清除），导出器已清理半成品
                    errorMessage = error is VideoExportError
                        ? error.localizedDescription
                        : "视频导出失败：\(error.localizedDescription)"
                    exportState = .failed
                }
            }
        }
    }

    /// 取消导出：协作式取消渲染任务，状态立即收敛回空闲（半成品文件由导出器删除）
    func cancelExport() {
        guard exportState == .rendering else { return }
        exportTask?.cancel()
        exportTask = nil
        exportProgress = 0
        exportState = .idle
    }

    /// 分享面板关闭后回调：完成态收敛回空闲，允许再次导出
    func exportDismissed() {
        guard case .completed = exportState else { return }
        exportState = .idle
    }

    /// 判定是否用户取消（静默处理，不进错误横幅）：
    /// 结构化取消（CancellationError / 当前 Task 已取消）或导出器的 `.cancelled`
    private static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let exportError = error as? VideoExportError, case .cancelled = exportError { return true }
        return false
    }

    // MARK: - 私有：旋律分析

    /// 执行旋律分析（MelodyAnalysisService 由并行任务提供，按约定签名调用）。
    /// 结果仅在 generation 仍为最新时收敛到发布状态，过期结果直接丢弃。
    private func runAnalysis(generation: Int, url: URL) async {
        do {
            let data = try await MelodyAnalysisService.shared.analyze(url: url, progress: { [weak self] value in
                guard let self else { return }
                Task { @MainActor in
                    self.updateAnalysisProgress(generation: generation, value: value)
                }
            })
            guard generation == importGeneration, !Task.isCancelled else { return }
            melody = data
            analysisProgress = nil
            isAnalyzing = false
        } catch is CancellationError {
            // 被新导入取代：静默退出，状态由新导入收敛
        } catch {
            guard generation == importGeneration else { return }
            errorMessage = "旋律分析失败：\(error.localizedDescription)"
            analysisProgress = nil
            isAnalyzing = false
        }
    }

    @MainActor
    private func updateAnalysisProgress(generation: Int, value: Double) {
        guard generation == importGeneration else { return }
        analysisProgress = value
    }

    @MainActor
    private func handlePlaybackFinished() {
        isPlaying = false
        currentTime = duration
    }

    // MARK: - DEBUG: 自检入口

    #if DEBUG
    /// `--self-test` / `--import-path` 启动参数（仅 DEBUG 生效）：
    /// - `--self-test`：自动导入 bundle 内 fixture 音频并自动开始播放，
    ///   供模拟器 `simctl launch … --self-test` 截图目检（竖线对齐 / 画面滚动 / 音符发光）。
    /// - `--import-path <path>`：从 Bundle.main 之外的给定路径导入音频（如沙盒 tmp 内的 mp3），
    ///   供真实音乐截图目检；对非沙盒路径调用 security scope 为无害 no-op（沿用 importAudio 现有逻辑）。
    /// 两者均复用 importAudio 的"装载即播放"路径：导入完成后延迟约 1.5s 启动播放，
    /// 无需等待旋律分析（播放与分析解耦，画布在分析完成后自动出现）。
    func runSelfTestIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        // --import-path <path>：优先于 --self-test，导入给定路径的音频
        if let flagIndex = args.firstIndex(of: "--import-path"), flagIndex + 1 < args.count {
            // 数分钟长度的 mp3 解码慢于 fixture，装载等待放宽至 30s
            beginSelfTestImport(url: URL(fileURLWithPath: args[flagIndex + 1]), loadTimeout: 30)
            return
        }
        guard args.contains("--self-test") else { return }
        guard let fixture = Bundle.main.url(forResource: "selftest-440hz", withExtension: "wav") else {
            errorMessage = "self-test：bundle 内未找到 selftest-440hz.wav"
            return
        }
        beginSelfTestImport(url: fixture, loadTimeout: 10)
    }

    /// self-test 公共路径：导入后等装载完成（超时仅防呆），再延迟约 1.5s 自动播放
    private func beginSelfTestImport(url: URL, loadTimeout: TimeInterval) {
        importAudio(at: url)

        Task { @MainActor in
            // 等后台解码装载完成（importedAudio 非 nil），超时防呆
            let deadline = Date().addingTimeInterval(loadTimeout)
            while importedAudio == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard importedAudio != nil else { return }
            // 延迟约 1.5s 再播，避开导入状态收敛窗口
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard importedAudio != nil, !isPlaying else { return }
            togglePlayPause()
        }
    }
    #else
    /// Release 构建无 self-test 逻辑（空实现，保持调用点可编译）
    func runSelfTestIfRequested() {}
    #endif
}
