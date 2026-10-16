//
//  PlaybackEngine.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import AVFoundation
import Foundation

/// 采样级精确播放引擎：AVAudioEngine + AVAudioPlayerNode。
///
/// 调度模型（核心决策）：
/// 任何位置变更（play / resume / seek）都先 `playerNode.stop()` 清空既有调度，
/// 再从目标帧起一次性 `scheduleBuffer` 剩余片段 —— 全程只存在至多一个在途调度，
/// pause/resume/seek 三条路径走完全一致的“停 → 重设偏移 → 重新调度”流程，
/// 杜绝叠加调度导致的重复声音。
///
/// 播放时钟：
/// `currentTime` 播放中由渲染时钟实时推导 ——
/// `playerNode.lastRenderTime → playerTime(forNodeTime:) → sampleTime + startFrame`，
/// 精度到采样级，不使用任何 Timer 插值；暂停/停止时返回冻结的暂停位置。
///
/// 线程模型：
/// 公开方法按主线程调用模型设计；可变状态由轻量 NSLock 保护，
/// `currentTime` 可被 SwiftUI 每帧高频查询而不会阻塞 —— 锁内仅做校验/快照/登记，
/// 缓冲切片拷贝（大 memcpy）与 `scheduleBuffer` 等耗时操作留在锁外执行
/// （主线程模型下 play/seek/pause 不会与锁外段并发；node 调度 API 本身线程安全）。
/// completion 回调在引擎内部线程触发，统一派发回主线程后再收敛状态。
final class PlaybackEngine: @unchecked Sendable {

    // MARK: - 回调

    /// 自然播放完毕回调（主线程派发）。seek/pause/load 引发的停止不触发。
    var onPlaybackFinished: (() -> Void)?

    // MARK: - 私有状态（由 lock 保护）

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// 已加载音频；nil 表示尚未加载任何音频
    private var audio: LoadedAudio?

    /// 本次调度的起始帧（片段在整个 buffer 中的偏移），用于时钟换算
    private var startFrame: AVAudioFramePosition = 0

    /// 冻结位置（秒）。暂停/停止时为暂停位置；播放中恰好等于本次调度起点，
    /// 作为渲染时钟暂不可用时的回退值
    private var pausedTime: TimeInterval = 0

    /// 逻辑播放状态（由本类维护，而非 node 的引擎状态）
    private var playing = false

    /// 调度代数：每次 scheduleBuffer 递增；携带旧代数的 completion 回调一律作废，
    /// 用于区分“自然播完”与“stop/seek/pause 清空调度”
    private var scheduleGeneration = 0

    /// 保护上述可变状态的轻量锁
    private let lock = NSLock()

    // MARK: - 生命周期

    init() {
        // iOS 播放前置条件：声明 playback 类别并激活会话（后台播放/不受静音开关影响）。
        // 失败不阻塞初始化 —— 某些系统资源暂时不可用的场景下，稍后播放仍有机会成功。
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // 会话配置失败可容忍，engine.start 失败时 play() 会放弃本次播放
        }

        engine.attach(playerNode)
        // format: nil 先按默认格式搭好图；load() 时会按具体音频格式重连
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.prepare()
    }

    deinit {
        engine.stop()
        engine.detach(playerNode)
    }

    // MARK: - 加载

    /// 替换当前音频：停止旧播放、清空既有调度、重置到 0。
    func load(_ audio: LoadedAudio) {
        lock.lock(); defer { lock.unlock() }
        playerNode.stop()
        scheduleGeneration += 1  // 作废旧调度的 completion 回调

        // 按新音频格式重建连线：不同采样率/声道数的文件需要各自匹配的连线格式，
        // 否则 playerNode 会按旧连线格式错误解释缓冲数据
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audio.playbackBuffer.format)

        self.audio = audio
        startFrame = 0
        pausedTime = 0
        playing = false
    }

    // MARK: - 播放控制

    /// 从暂停位置开始播放；若已停在末尾则从头开始。
    /// 未加载音频或已在播放时为无操作。
    func play() {
        // —— 锁内：校验 + 快照（含"末尾回开头"的冻结位置修正，与原顺序一致）——
        lock.lock()
        guard let audio, !playing else { lock.unlock(); return }
        var frame = AVAudioFramePosition((pausedTime * audio.sampleRate).rounded())
        if pausedTime >= audio.duration - 1.0 / audio.sampleRate {
            pausedTime = 0
            frame = 0
        }
        lock.unlock()

        // —— 锁外：启动引擎与调度（大 memcpy 不进锁临界区；主线程调用模型下
        //      play/seek/pause 不会与本段并发，时钟查询读到的仍是登记前冻结值）——
        guard startEngineIfIdle(), scheduleSegment(from: frame, of: audio) else { return }

        // —— 锁内：登记在途状态（渲染时钟换算基准）——
        lock.lock()
        startFrame = frame
        playing = true
        lock.unlock()
    }

    /// 暂停：先冻结采样级精确位置，再清空调度；恢复时重新调度。
    /// 未在播放时为无操作。
    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard audio != nil, playing else { return }

        // 暂停瞬间读一次精确时钟 —— stop() 之后渲染时钟即失效
        pausedTime = currentPlaybackTimeLocked()
        playing = false
        playerNode.stop()          // 清空在途片段，resume 走全新调度，避免叠加
        scheduleGeneration += 1    // 作废该片段的 completion 回调
    }

    /// 播放/暂停切换
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// 跳转到指定时间（自动 clamp 到 [0, duration]）。
    /// 播放中 seek：清空调度后立即从新位置继续播放；
    /// 暂停中 seek：仅停在新位置，等下次 play() 再出声。
    func seek(to time: TimeInterval) {
        // —— 锁内：clamp + 冻结新位置 + 作废旧调度（与原顺序一致）——
        lock.lock()
        guard let audio else { lock.unlock(); return }
        let clamped = min(max(time, 0), audio.duration)
        let wasPlaying = playing

        playerNode.stop()          // 清空在途调度（可能产生旧回调，由代数机制作废）
        scheduleGeneration += 1
        playing = false
        pausedTime = clamped
        lock.unlock()

        guard wasPlaying else { return }

        // —— 锁外：启动引擎与重新调度（大 memcpy 不进锁临界区）——
        let frame = AVAudioFramePosition((clamped * audio.sampleRate).rounded())
        guard startEngineIfIdle(), scheduleSegment(from: frame, of: audio) else { return }

        // —— 锁内：登记在途状态（渲染时钟换算基准）——
        lock.lock()
        startFrame = frame
        playing = true
        lock.unlock()
    }

    // MARK: - 状态查询

    /// 当前播放位置（秒，采样级精确）。
    /// 播放中由渲染时钟实时推导；暂停/停止时返回冻结的暂停位置；未加载时为 0。
    var currentTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return currentPlaybackTimeLocked()
    }

    /// 是否正在播放
    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    /// 当前音频总时长（秒）；未加载时为 0
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return audio?.duration ?? 0
    }

    // MARK: - 私有：播放时钟

    /// 采样级时钟推导（须持锁调用）。
    private func currentPlaybackTimeLocked() -> TimeInterval {
        guard let audio else { return 0 }
        guard playing else { return pausedTime }

        // 渲染时钟暂不可用（刚调度尚未渲染、engine 异常）时回退到调度起点
        guard let nodeTime = playerNode.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0 else {
            return pausedTime
        }

        // playerTime.sampleTime 相对本次调度片段起点的已播帧数；
        // 加上片段在整轨中的起始帧偏移即得整轨位置
        let seconds = (Double(startFrame) + Double(playerTime.sampleTime)) / audio.sampleRate
        return min(max(seconds, 0), audio.duration)
    }

    // MARK: - 私有：调度

    /// 确保引擎处于运行状态。返回是否成功。（锁外调用；AVAudioEngine 自身线程安全，
    /// 主线程调用模型下不会与其它公开方法并发）
    @discardableResult
    private func startEngineIfIdle() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            // 引擎启动失败（如音频会话被占用）：放弃本次播放，状态保持暂停
            return false
        }
    }

    /// 从指定帧调度播放至音频末尾，并立即启动 node（锁外调用；
    /// 调用前 play/seek 已在锁内完成状态冻结与旧调度作废）。返回是否成功调度。
    ///
    /// 锁优化：锁内只做帧校验与代数快照（轻量），逐声道大 memcpy 与
    /// `scheduleBuffer` 留在锁外执行，避免采样级时钟的高频查询被拷贝阻塞。
    /// 行为与原实现一致：帧越界/分配失败返回 false；completion 回调与代数校验不变
    /// （代数递增提前到分配之前——分配失败时多递增一次无行为影响，因此时
    /// 不存在在途调度，pause/seek/load 均已 stop 清空，无有效回调可被作废）。
    private func scheduleSegment(from frame: AVAudioFramePosition, of audio: LoadedAudio) -> Bool {
        // —— 短暂持锁：帧校验 + 代数快照 ——
        let buffer = audio.playbackBuffer
        lock.lock()
        guard frame >= 0, frame < AVAudioFramePosition(buffer.frameLength) else {
            lock.unlock()
            return false
        }
        scheduleGeneration += 1
        let generation = scheduleGeneration
        lock.unlock()

        // —— 锁外：分配新片段并逐声道拷贝 [frame, end) 区间（大 memcpy 不进锁）——
        let remaining = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - frame)
        guard let segment = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remaining) else {
            return false
        }
        for ch in 0..<Int(buffer.format.channelCount) {
            guard let src = buffer.floatChannelData?[ch],
                  let dst = segment.floatChannelData?[ch] else { continue }
            dst.update(from: src.advanced(by: Int(frame)), count: Int(remaining))
        }
        segment.frameLength = remaining

        // 末尾检测选择 .dataPlayedBack：数据真正渲染到输出完毕才回调
        //（而非默认的 .dataConsumed —— 引擎消费即回调，早于实际发声结束），
        // 回调时刻天然对齐音频末尾，无需 UI 层轮询 currentTime >= duration，
        // 也避免了轮询漏检（一帧间隔内跨过末尾）的问题。
        playerNode.scheduleBuffer(
            segment,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            // completion 在引擎内部线程触发；状态收敛统一在主线程进行，
            // 避免在渲染线程上碰锁造成优先级反转
            DispatchQueue.main.async {
                self?.handleSegmentPlayed(generation: generation)
            }
        }
        playerNode.play()
        return true
    }

    /// 主线程处理“片段播完”：代数匹配即自然播完，否则忽略。
    private func handleSegmentPlayed(generation: Int) {
        var handler: (() -> Void)?
        lock.lock()
        // 代数不匹配 = 回调来自已被 stop/seek/pause/load 作废的旧调度
        if generation == scheduleGeneration, playing {
            playing = false
            pausedTime = audio?.duration ?? 0
            startFrame = 0
            handler = onPlaybackFinished
        }
        lock.unlock()
        handler?()
    }
}
