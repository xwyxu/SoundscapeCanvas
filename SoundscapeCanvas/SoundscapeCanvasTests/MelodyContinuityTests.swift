//
//  MelodyContinuityTests.swift
//  SoundscapeCanvasTests
//
//  旋律轨迹连贯性回归测试 —— 用用户真实音乐《狮尾之舞 Swirls of Shamshir》
//  (HOYO-MiX, 4:11) 断言"轨迹级追踪"相对"逐拍 argmax 基线"的改善
//  （Task 1 固化基线，Task 3 启用断言；spec: .trae/specs/track-melody-trajectories）。
//
//  基线（逐拍 argmax 版本实测，两次运行逐位一致）：
//  - A 跳变平滑度：melody 相邻音高差 中位数 3.0 / P90 19.0 半音
//    （P90 长尾 = 碎片化断裂证据；中位数主要反映音乐本身级进，不恶化即可）
//  - B 角色抖动率：66.011 次/分钟（<1s 快速互切）
//  - C melody 时间覆盖率：0.51202
//
//  验收目标（spec，不得下调）：
//  - A'：P90 ≤ 11.4（基线 × 0.6）且中位数 ≤ 3.3（基线 × 1.1）
//  - B：≤ 33.0 次/分钟（基线 × 0.5）
//  - C：≥ 0.41（基线 × 0.8，防"少标作弊"）
//
//  指标口径（音符均为秒域；模型帧分辨率 timeResolution = 256/22050 ≈ 11.61ms）：
//  - A 跳变平滑度：melody 音符按 startTime 升序排列后，相邻音符 midiNote 差
//    绝对值序列的中位数与 P90（单位：半音）。中位数偶数样本取中间两值平均；
//    P90 采用线性插值口径（与 numpy.percentile 默认 linear 法一致）。
//  - B 角色抖动率：全部非 background 音符按 startTime 升序构成角色序列
//    （melody/countermelody），统计「相邻异角色且 startTime 间隔 < 1.0s」的
//    交替次数 / 分钟；分母分钟数 = 角色序列时间跨度（末音符 end − 首音符 start）/ 60。
//  - C melody 时间覆盖率：Σ melody 音符时长 / (melody 末音符 end − 首音符 start)。
//
//  运行（真机级完整管线，测试超时保护 300s）：
//  xcodebuild test -project SoundscapeCanvas.xcodeproj -scheme SoundscapeCanvas \
//    -destination 'platform=iOS Simulator,id=265CE503-…' \
//    -only-testing:SoundscapeCanvasTests/MelodyContinuityTests
//

import XCTest
@testable import SoundscapeCanvas

final class MelodyContinuityTests: XCTestCase {

    // MARK: - 常量

    /// 完整管线超时（秒）：4:11 音频在模拟器上解码 + CoreML 推理通常 10–30s，
    /// 留足余量避免首跑模型加载抖动误报
    private static let analysisTimeoutSeconds: Double = 300

    /// B 指标：相邻异角色事件判定为"抖动交替"的最大 startTime 间隔（秒）
    private static let roleSwitchIntervalThreshold: Double = 1.0

    /// fixture 资源名（shamshir.mp3，经文件系统同步组自动入测试 target）
    private static let fixtureName = "shamshir"

    /// 指标 JSON 落盘路径（供宿主读取与迭代对比）
    private static let baselineJSONPath = "/tmp/shamshir-baseline.json"

    // MARK: - 基线常量（Task 1 实测固化，两次运行逐位一致）

    /// 基线 A 中位数（半音，逐拍 argmax 版本）
    private static let baselineJumpMedian: Double = 3.0
    /// 基线 A P90（半音，逐拍 argmax 版本——碎片化长尾证据）
    private static let baselineJumpP90: Double = 19.0
    /// 基线 B 角色抖动率（次/分钟，逐拍 argmax 版本）
    private static let baselineSwitchPerMinute: Double = 66.011
    /// 基线 C melody 时间覆盖率（逐拍 argmax 版本）
    private static let baselineCoverage: Double = 0.512

    // MARK: - E 全曲连贯指标基线（spec: stitch-melody-chain，Task 1 实测固化，
    // 两次运行逐位一致；链构建前的单条最佳轨迹版本）

    /// 基线 E1 主线全曲覆盖率 = Σmelody 时长 / 音频时长（实测 0.4355306093901151）
    private static let baselineFullSongCoverage: Double = 0.43553
    /// 基线 E2 旋律段数（>3s 无旋律间隙切分，实测 6 段）
    private static let baselineMelodySegmentCount = 6

    // MARK: - 验收目标（spec，不得下调）

    /// A'：P90 ≤ 基线 × 0.6 = 11.4 半音
    private static let targetJumpP90: Double = baselineJumpP90 * 0.6
    /// A'：中位数 ≤ 基线 × 1.1 = 3.3 半音（不恶化即可）
    private static let targetJumpMedian: Double = baselineJumpMedian * 1.1
    /// B：≤ 基线 × 0.5 = 33.0 次/分钟
    private static let targetSwitchPerMinute: Double = 33.0
    /// C：≥ 基线 × 0.8 = 0.41（防"少标作弊"）
    private static let targetCoverage: Double = 0.41

    // MARK: - D 全曲跨度守恒目标（Task 4 返工，堵口径漏洞）

    /// D1：melody 首末跨度 ≥ 音频时长 × 0.75（基线 melody 散布全曲，跨度≈1.0）
    private static let targetMelodySpanRatio: Double = 0.75
    /// D2：counter 首末跨度 ≥ 音频时长 × 0.5 且 counter 音符数 ≥ 60（基线 175）
    private static let targetCounterSpanRatio: Double = 0.5
    private static let targetCounterNoteCount = 60

    // MARK: - E 全曲连贯目标（spec: stitch-melody-chain，Task 3 启用）

    /// E1 ≥ 基线 × 1.15 = 0.5009（链构建后全曲覆盖率相对改善 ≥ 15%）
    private static let targetFullSongCoverage: Double = baselineFullSongCoverage * 1.15
    /// E2 ≤ 基线 × 0.6 = 3.6（旋律段数相对削减 ≥ 40%）
    private static let targetMelodySegmentCount: Double =
        Double(baselineMelodySegmentCount) * 0.6

    // MARK: - G 轮廓级指标基线（spec: fill-melody-contour-gaps，Task 1 实测固化，
    // 两次运行逐位一致；轮廓填充前的链构建版本）

    /// 基线 G1 轮廓命中率：轮廓带内候选音符中 role == melody 的比例
    /// （Task 1 实测 0.513715710723192，轮廓填充前的链构建版本；轮廓带内
    /// 约一半音符被判 background——即用户截图的黄白交替）
    private static let baselineContourHitRate: Double = 0.513715710723192
    /// 基线 G2 轮廓断点数：轮廓线上相邻 melody 音符间被非 melody 候选打断的次数
    /// （Task 1 实测 195——旋律轮廓几乎每个音符间都被背景音符插入打断，
    /// 黄线在画面上呈虚线状）
    private static let baselineContourBreakCount = 195
    /// G1 ≥ 基线 × 1.3（轮廓带内命中率先显著提升）
    private static let targetContourHitRate: Double = baselineContourHitRate * 1.3
    /// G2 ≤ 基线 × 0.4（轮廓线上的黄白交替次数削减 ≥ 60%）
    private static let targetContourBreakCount: Double =
        Double(baselineContourBreakCount) * 0.4

    // MARK: - 指标结果类型

    /// 连贯性指标（Codable 便于落盘；复用同一实现计算改善后值）
    struct ContinuityMetrics: Codable, Equatable {
        // A 跳变平滑度（melody 相邻音高差，半音）
        let jumpMedianSemitones: Double
        let jumpP90Semitones: Double
        /// 音高差样本数（诊断用）
        let jumpSampleCount: Int
        // B 角色抖动率（次/分钟）
        let roleSwitchPerMinute: Double
        /// 交替绝对次数（诊断用）
        let roleSwitchCount: Int
        /// 角色序列时间跨度（秒，抖动率分母）
        let roleSpanSeconds: Double
        // C melody 时间覆盖率
        let melodyCoverageRatio: Double
        /// Σ melody 音符时长（秒，"覆盖秒数"）
        let melodyDurationSeconds: Double
        /// melody 首末音符跨度（秒，覆盖率分母）
        let melodySpanSeconds: Double
        // D 全曲跨度守恒（Task 4 返工，堵"少标作弊"口径漏洞）
        /// D1 melody 首末跨度 / 音频时长
        let melodySpanRatio: Double
        /// D2 counter 首末跨度 / 音频时长
        let counterSpanRatio: Double
        /// 音符数
        let melodyNoteCount: Int
        let countermelodyNoteCount: Int
        // E 全曲连贯指标（spec: stitch-melody-chain，Task 1 口径、Task 3 启用断言）
        /// E1 主线全曲覆盖率 = Σ melody 音符时长 / 音频时长。分母 = 音频总时长
        /// （AudioLoader.load(url:).duration），与 C 的「melody 自身首末跨度」
        /// 分母严格区分：C 衡量主线上音符的密实度（跨度内覆盖率），E1 衡量
        /// 旋律角色占全曲的比例——片段式断线的直接度量（断段越少 E1 越高）
        let melodyFullSongCoverage: Double
        /// E2 旋律段数：melody 音符按 start 排序合并重叠区间后，被
        /// > melodyChainSegmentGap(3.0s) 的无旋律间隙切分的段数（理想连贯旋律
        /// = 1 段；片段式黄线段数多）
        let melodySegmentCount: Int
        // G 轮廓级指标（spec: fill-melody-contour-gaps）
        /// G1 轮廓命中率：轮廓带内（|midi − contour(t)| ≤ 2.0 且在 melody 跨度内）
        /// 的候选音符中 role == melody 的比例——直接度量「同一条旋律线上黄白
        /// 交替」的程度（用户截图症状）
        let contourHitRate: Double
        /// G2 轮廓断点数：轮廓线上相邻 melody 音符之间被非 melody 候选音符插入
        /// 打断的次数（越少说明黄线越连续）
        let contourBreakCount: Int
        /// 轮廓带内候选音符数（G1 分母，诊断用）
        let contourBandNoteCount: Int
    }

    /// 10s 桶直方图条目
    struct HistogramBucket: Codable, Equatable {
        let startSeconds: Int
        let melodyNotes: Int
        let countermelodyNotes: Int
    }

    /// 基线 JSON 顶层结构
    private struct BaselineDump: Codable {
        let audio: String
        let generatedAt: String
        let audioDurationSeconds: Double
        let totalNoteCount: Int
        let timeResolution: Double
        let metrics: ContinuityMetrics
        let histogram: [HistogramBucket]
    }

    // MARK: - 统计辅助（Task 3 复用，保证口径一致）

    /// 分位数（线性插值口径，同 numpy.percentile 默认 linear 法）；
    /// 空数组返回 0，单元素返回该值
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let pos = p * Double(sorted.count - 1)
        let lower = Int(pos.rounded(.down))
        let upper = Int(pos.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = pos - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// 中位数：偶数个样本取中间两值平均（即 percentile 0.5 的线性插值结果）
    static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    // MARK: - 指标计算（独立 static 函数，Task 3 复用同一实现）

    /// 从完整分析结果的音符集合计算连贯性指标（口径见文件头注释；
    /// audioDuration 为音频总时长，用于 D1/D2 全曲跨度守恒）
    static func computeContinuityMetrics(
        notes: [MelodyNote], audioDuration: TimeInterval
    ) -> ContinuityMetrics {
        // 按 role 拆两组并按 startTime 升序（MelodyData.notes 理论上已升序，显式排序保险）
        let melody = notes.filter { $0.role == .melody }
            .sorted { $0.startTime < $1.startTime }
        let counter = notes.filter { $0.role == .countermelody }
            .sorted { $0.startTime < $1.startTime }

        // A 跳变平滑度：melody 相邻音高差绝对值（半音）
        let jumps: [Double] = zip(melody, melody.dropFirst())
            .map { abs(Double($1.midiNote - $0.midiNote)) }

        // B 角色抖动率：非 background 角色序列中「相邻异角色且 start 间隔 < 阈值」的交替
        let voiced = notes.filter { $0.role != .background }
            .sorted { $0.startTime < $1.startTime }
        var switchCount = 0
        for (prev, curr) in zip(voiced, voiced.dropFirst())
        where prev.role != curr.role {
            if (curr.startTime - prev.startTime) < Self.roleSwitchIntervalThreshold {
                switchCount += 1
            }
        }
        let roleSpan = voiced.isEmpty ? 0 : (voiced.last!.endTime - voiced.first!.startTime)
        let roleMinutes = roleSpan / 60
        let switchPerMinute = roleMinutes > 0 ? Double(switchCount) / roleMinutes : 0

        // C melody 时间覆盖率：Σ melody 时长 / melody 首末跨度
        let melodyDuration = melody.reduce(0) { $0 + ($1.endTime - $1.startTime) }
        let melodySpan = melody.isEmpty ? 0 : (melody.last!.endTime - melody.first!.startTime)
        let coverage = melodySpan > 0 ? melodyDuration / melodySpan : 0

        // D 全曲跨度守恒：角色首末跨度 / 音频时长（防"少标作弊"——
        // 角色坍缩为短区段时 A/B/C 的口径分母同步收缩而失真）
        let counterSpan = counter.isEmpty ? 0 : (counter.last!.endTime - counter.first!.startTime)
        let melodySpanRatio = audioDuration > 0 ? melodySpan / audioDuration : 0
        let counterSpanRatio = audioDuration > 0 ? counterSpan / audioDuration : 0

        // E1 主线全曲覆盖率：Σ melody 时长 / 音频时长（分母 = 音频总时长，全曲
        // 口径——与 C 的 melody 自身跨度口径区分，见 ContinuityMetrics 字段注释；
        // melody 为空时记 0）
        let fullSongCoverage = audioDuration > 0 ? melodyDuration / audioDuration : 0

        // E2 旋律段数：按 start 升序扫描，重叠/贴合区间并入当前段（regionEnd 取
        // max），与当前段尾的间隙 > melodyChainSegmentGap 时开新段——等价于
        // 「合并重叠区间后被大间隙切分」。空 melody = 0 段。
        var segmentCount = 0
        var regionEnd: Double?
        for note in melody {
            if let end = regionEnd {
                if note.startTime - end > VoiceSeparator.melodyChainSegmentGap {
                    segmentCount += 1
                }
                regionEnd = max(end, note.endTime)
            } else {
                segmentCount = 1
                regionEnd = note.endTime
            }
        }

        // G 轮廓级指标（spec: fill-melody-contour-gaps）：轮廓 = melody 音符按
        // (start, midi) 排序后相邻线性插值；轮廓在 melody 首音符之前与末音符之后
        // 无定义（不参与统计）。轮廓口径与产品侧 VoiceSeparator 的 contourY(at:)
        // 同构（线性插值 + 链首尾无定义），保证指标与实现对齐。
        let contour = Self.buildContour(from: melody)
        // G1 分母：轮廓带内候选音符（|midi − contour| ≤ 2.0 且 t 在轮廓定义域内）
        var bandCount = 0
        var bandMelody = 0
        // 轮廓带内按时间排序的候选（供 G2 统计相邻 melody 间被非 melody 打断）
        var bandNotes: [(start: Double, isMelody: Bool)] = []
        for note in notes {
            let t = (note.startTime + note.endTime) / 2
            guard let y = contour.atTime(t) else { continue }
            guard abs(Double(note.midiNote) - y) <= Self.contourBandTolerance else { continue }
            bandCount += 1
            bandNotes.append((note.startTime, note.role == .melody))
            if note.role == .melody { bandMelody += 1 }
        }
        let contourHitRate = bandCount > 0 ? Double(bandMelody) / Double(bandCount) : 0
        // G2：轮廓带内按时间排序后，相邻两个 melody 音符之间若存在非 melody
        // 候选音符则记一次打断（黄白交替的直接计数）
        bandNotes.sort { $0.start < $1.start }
        var contourBreaks = 0
        var seenMelody = false
        var gapHasBackground = false
        for item in bandNotes {
            if item.isMelody {
                if seenMelody && gapHasBackground { contourBreaks += 1 }
                seenMelody = true
                gapHasBackground = false
            } else if seenMelody {
                gapHasBackground = true
            }
        }

        return ContinuityMetrics(
            jumpMedianSemitones: Self.median(jumps),
            jumpP90Semitones: Self.percentile(jumps, 0.9),
            jumpSampleCount: jumps.count,
            roleSwitchPerMinute: switchPerMinute,
            roleSwitchCount: switchCount,
            roleSpanSeconds: roleSpan,
            melodyCoverageRatio: coverage,
            melodyDurationSeconds: melodyDuration,
            melodySpanSeconds: melodySpan,
            melodySpanRatio: melodySpanRatio,
            counterSpanRatio: counterSpanRatio,
            melodyNoteCount: melody.count,
            countermelodyNoteCount: counter.count,
            melodyFullSongCoverage: fullSongCoverage,
            melodySegmentCount: segmentCount,
            contourHitRate: contourHitRate,
            contourBreakCount: contourBreaks,
            contourBandNoteCount: bandCount
        )
    }

    // MARK: - 轮廓构造与统计辅助（G 指标，产品侧同构）

    /// 轮廓带容差（半音）：与产品侧 VoiceSeparator.contourFillTolerance 同值，
    /// 保证指标口径与实现一致
    static let contourBandTolerance: Double = 2.0

    /// 旋律轮廓：相邻 melody 音符间线性插值；首音符之前 / 末音符之后无定义
    struct MelodyContour {
        private let points: [(t: Double, y: Double)]

        init(notes: [MelodyNote]) {
            var sorted = notes.sorted {
                ($0.startTime, $0.midiNote) < ($1.startTime, $1.midiNote)
            }
            // 同一 startTime 保留音高最低者（确定性去重，避免零长度插值段）
            var deduped: [MelodyNote] = []
            for note in sorted {
                if let last = deduped.last, last.startTime == note.startTime {
                    if note.midiNote < last.midiNote { deduped[deduped.count - 1] = note }
                } else {
                    deduped.append(note)
                }
            }
            points = deduped.map { ($0.startTime, Double($0.midiNote)) }
        }

        var isEmpty: Bool { points.count < 2 }

        /// 轮廓定义域（首末音符时间）
        var timeDomain: ClosedRange<Double>? {
            guard let first = points.first, let last = points.last else { return nil }
            return first.t...last.t
        }

        /// 线性插值查询；定义域外返回 nil
        func atTime(_ t: Double) -> Double? {
            guard points.count >= 2 else { return nil }
            guard let first = points.first, let last = points.last else { return nil }
            guard t >= first.t, t <= last.t else { return nil }
            if t == last.t { return last.y }
            var lo = 0
            var hi = points.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if points[mid].t <= t { lo = mid } else { hi = mid }
            }
            let a = points[lo], b = points[hi]
            let span = b.t - a.t
            guard span > 0 else { return a.y }
            return a.y + (b.y - a.y) * ((t - a.t) / span)
        }
    }

    static func buildContour(from melodyNotes: [MelodyNote]) -> MelodyContour {
        MelodyContour(notes: melodyNotes)
    }

    /// 角色时间直方图（10s 桶）：确认 melody/counter 跨全曲分布（目检自证材料）
    static func roleHistogramBuckets(
        notes: [MelodyNote], audioDuration: TimeInterval
    ) -> [HistogramBucket] {
        let bucketSeconds = 10.0
        let bucketCount = max(1, Int((audioDuration / bucketSeconds).rounded(.up)))
        var melodyBuckets = [Int](repeating: 0, count: bucketCount)
        var counterBuckets = [Int](repeating: 0, count: bucketCount)
        for note in notes {
            let b = min(bucketCount - 1, max(0, Int(note.startTime / bucketSeconds)))
            if note.role == .melody { melodyBuckets[b] += 1 }
            if note.role == .countermelody { counterBuckets[b] += 1 }
        }
        return (0..<bucketCount).map {
            HistogramBucket(startSeconds: $0 * Int(bucketSeconds),
                            melodyNotes: melodyBuckets[$0],
                            countermelodyNotes: counterBuckets[$0])
        }
    }

    /// 直方图 ASCII 打印
    static func printRoleHistogram(_ buckets: [HistogramBucket]) {
        let header = "[旋律连贯性][角色直方图]"
        print("\(header) 10s 桶角色音符数分布（M=melody C=countermelody）：")
        for b in buckets {
            let barM = String(repeating: "█", count: min(40, b.melodyNotes))
            let barC = String(repeating: "░", count: min(40, b.countermelodyNotes))
            print("\(header) \(String(format: "%3d", b.startSeconds))s " +
                "M\(String(format: "%3d", b.melodyNotes)) " +
                "C\(String(format: "%3d", b.countermelodyNotes)) |\(barM)\(barC)")
        }
        let activeMel = buckets.filter { $0.melodyNotes > 0 }.count
        let activeCnt = buckets.filter { $0.countermelodyNotes > 0 }.count
        print("\(header) melody 活跃桶 \(activeMel)/\(buckets.count)，" +
            "counter 活跃桶 \(activeCnt)/\(buckets.count)")
    }

    // MARK: - 超时保护

    /// 管线超时错误
    private struct AnalysisTimeoutError: LocalizedError {
        let seconds: Double
        var errorDescription: String? { "分析管线超过 \(Int(seconds))s 超时" }
    }

    /// 竞速超时包装：operation 与 sleep 竞速，先完成者胜出；
    /// analyze 内部支持 Task 取消，超时后 cancelAll 会联动取消推理
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AnalysisTimeoutError(seconds: seconds)
            }
            guard let first = try await group.next() else {
                throw AnalysisTimeoutError(seconds: seconds)
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - 失败诊断（角色标记 vs 音高轨迹对照明细）

    /// 断言失败时打印乐句级明细，用于定位碎片化残留：
    /// 1) melody 相邻音高差 ≥ 8 半音的断点（时间/前音→后音，长尾跳变定位）；
    /// 2) <1s 快速角色交替片段前 20 条（角色抖动定位）；
    /// 3) 两角色音符的音高轮廓压缩视图（前 80 音，目检轨迹形态）。
    private static func printFailureDetails(notes: [MelodyNote]) {
        let header = "[旋律连贯性][失败诊断]"
        let melody = notes.filter { $0.role == .melody }.sorted { $0.startTime < $1.startTime }
        let counter = notes.filter { $0.role == .countermelody }
            .sorted { $0.startTime < $1.startTime }

        print("\(header) ===== A 断点明细（melody 相邻音高差 ≥ 8 半音）=====")
        for (prev, curr) in zip(melody, melody.dropFirst()) {
            let jump = abs(curr.midiNote - prev.midiNote)
            if jump >= 8 {
                print("\(header) 跳变 \(jump) 半音 @ \(String(format: "%.2f", curr.startTime))s: " +
                    "midi \(prev.midiNote)(\(String(format: "%.2f", prev.startTime))s) → " +
                    "\(curr.midiNote)(\(String(format: "%.2f", curr.startTime))s)")
            }
        }

        print("\(header) ===== B 快速角色交替明细（间隔 < 1.0s，前 20 条）=====")
        let voiced = notes.filter { $0.role != .background }
            .sorted { $0.startTime < $1.startTime }
        var shown = 0
        for (prev, curr) in zip(voiced, voiced.dropFirst()) where prev.role != curr.role {
            guard shown < 20 else { break }
            if (curr.startTime - prev.startTime) < roleSwitchIntervalThreshold {
                let arrow = prev.role == .melody ? "主→副" : "副→主"
                print("\(header) \(arrow) " +
                    "@ \(String(format: "%.2f", curr.startTime))s " +
                    "midi \(prev.midiNote)→\(curr.midiNote) " +
                    "(间隔 \(String(format: "%.2f", curr.startTime - prev.startTime))s)")
                shown += 1
            }
        }

        func contour(_ name: String, _ seq: [MelodyNote]) {
            let body = seq.prefix(80).map { "\($0.midiNote)@\(Int($0.startTime))" }
                .joined(separator: " ")
            print("\(header) \(name) 轮廓(前80): \(body)")
        }
        print("\(header) ===== 角色轮廓对照 =====")
        contour("melody", melody)
        contour("counter", counter)
    }

    // MARK: - 连贯性回归用例（A'/B/C 断言 + 指标落盘）

    /// 用真实音乐《狮尾之舞》跑完整管线并断言轨迹级追踪的连贯性改善：
    /// A'（P90 ≤ 11.4 且中位数 ≤ 3.3）、B（≤ 33.0 次/分钟）、C（≥ 0.41）、
    /// D1（melody 跨度 ≥ 0.75×时长）、D2（counter 跨度 ≥ 0.5×时长且 ≥60 音符）；
    /// 基线值与改善值均打印输出，角色直方图自证跨全曲分布，指标 JSON 落盘。
    func testShamshirContinuityRegression() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: Self.fixtureName, withExtension: "mp3"),
            "测试 bundle 中找不到 shamshir.mp3 —— 请确认已复制进 SoundscapeCanvasTests 目录"
        )
        // 音频总时长（D1/D2 分母）：解码只取 duration，采样缓冲即取即弃
        let audioDuration = try AudioLoader.load(url: fixtureURL).duration

        // 完整管线：mp3 解码 → 重采样 → CoreML 推理 → 音符解码 → 声部分离
        let data: MelodyData = try await withTimeout(seconds: Self.analysisTimeoutSeconds) {
            try await MelodyAnalysisService.shared.analyze(url: fixtureURL)
        }

        // —— 健全性检查 ——
        XCTAssertNotNil(data)
        XCTAssertFalse(data.notes.isEmpty, "4:11 真实音乐不应解出 0 个音符")
        XCTAssertEqual(
            data.timeResolution, 256.0 / 22050.0, accuracy: 1e-12,
            "时间分辨率应为 256/22050"
        )

        let metrics = Self.computeContinuityMetrics(
            notes: data.notes, audioDuration: audioDuration)

        // —— 指标输出（基线 vs 改善后对照）——
        let header = "[旋律连贯性][shamshir]"
        print("\(header) ===== 连贯性指标（基线 → 改善后）=====")
        print("\(header) A 跳变平滑度: 中位数 \(Self.baselineJumpMedian) → " +
            "\(String(format: "%.3f", metrics.jumpMedianSemitones)) 半音 " +
            "(目标 ≤ \(Self.targetJumpMedian)), " +
            "P90 \(Self.baselineJumpP90) → \(String(format: "%.3f", metrics.jumpP90Semitones)) 半音 " +
            "(目标 ≤ \(Self.targetJumpP90)) (样本 \(metrics.jumpSampleCount))")
        print("\(header) B 角色抖动率: \(Self.baselineSwitchPerMinute) → " +
            "\(String(format: "%.3f", metrics.roleSwitchPerMinute)) 次/分钟 " +
            "(目标 ≤ \(Self.targetSwitchPerMinute)) " +
            "(交替 \(metrics.roleSwitchCount) 次 / 跨度 \(String(format: "%.1f", metrics.roleSpanSeconds))s)")
        print("\(header) C melody 覆盖率: \(Self.baselineCoverage) → " +
            "\(String(format: "%.4f", metrics.melodyCoverageRatio)) " +
            "(目标 ≥ \(Self.targetCoverage)) " +
            "(Σ时长 \(String(format: "%.1f", metrics.melodyDurationSeconds))s / " +
            "跨度 \(String(format: "%.1f", metrics.melodySpanSeconds))s)")
        print("\(header) D1 melody 跨度: \(String(format: "%.1f", metrics.melodySpanSeconds))s " +
            "= 音频 \(String(format: "%.1f", audioDuration))s 的 " +
            "\(String(format: "%.3f", metrics.melodySpanRatio)) (目标 ≥ \(Self.targetMelodySpanRatio))")
        print("\(header) D2 counter 跨度: \(String(format: "%.1f", metrics.roleSpanSeconds))s 中 " +
            "counter 跨度比 \(String(format: "%.3f", metrics.counterSpanRatio)) " +
            "(目标 ≥ \(Self.targetCounterSpanRatio)) 且音符数 \(metrics.countermelodyNoteCount) " +
            "(目标 ≥ \(Self.targetCounterNoteCount))")
        print("\(header) melody 音符数=\(metrics.melodyNoteCount), " +
            "countermelody 音符数=\(metrics.countermelodyNoteCount), " +
            "总音符数=\(data.notes.count)")
        // E 全曲连贯指标（spec: stitch-melody-chain；基线 = 链构建前的单条
        // 最佳轨迹版本，Task 1 实测固化）
        print("\(header) E1 主线全曲覆盖率: " +
            "\(Self.baselineFullSongCoverage) → " +
            "\(String(format: "%.4f", metrics.melodyFullSongCoverage)) " +
            "(目标 ≥ \(String(format: "%.4f", Self.targetFullSongCoverage))) " +
            "(Σ时长 \(String(format: "%.1f", metrics.melodyDurationSeconds))s / " +
            "音频 \(String(format: "%.1f", audioDuration))s)")
        print("\(header) E2 旋律段数: \(Self.baselineMelodySegmentCount) → " +
            "\(metrics.melodySegmentCount) " +
            "(目标 ≤ \(String(format: "%.1f", Self.targetMelodySegmentCount)), " +
            "切分间隙 > \(VoiceSeparator.melodyChainSegmentGap)s)")
        Self.printRoleHistogram(
            Self.roleHistogramBuckets(notes: data.notes, audioDuration: audioDuration))

        // —— JSON 落盘（覆盖写，始终为最新一次运行结果）——
        let dump = BaselineDump(
            audio: "shamshir.mp3",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            audioDurationSeconds: audioDuration,
            totalNoteCount: data.notes.count,
            timeResolution: data.timeResolution,
            metrics: metrics,
            histogram: Self.roleHistogramBuckets(
                notes: data.notes, audioDuration: audioDuration)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(dump)
        try jsonData.write(to: URL(fileURLWithPath: Self.baselineJSONPath))
        print("\(header) JSON 已写入 \(Self.baselineJSONPath)")

        // —— A' 跳变平滑度断言（P90 为碎片化证据主判据；中位数不恶化即可）——
        if metrics.jumpP90Semitones > Self.targetJumpP90
            || metrics.jumpMedianSemitones > Self.targetJumpMedian {
            Self.printFailureDetails(notes: data.notes)
        }
        XCTAssertLessThanOrEqual(
            metrics.jumpP90Semitones, Self.targetJumpP90,
            String(format: "A' P90 跳变 %.3f 半音 > 目标 %.1f（碎片化长尾未消除）",
                   metrics.jumpP90Semitones, Self.targetJumpP90)
        )
        XCTAssertLessThanOrEqual(
            metrics.jumpMedianSemitones, Self.targetJumpMedian,
            String(format: "A' 中位数跳变 %.3f 半音 > 目标 %.1f（较基线 %.1f 恶化）",
                   metrics.jumpMedianSemitones, Self.targetJumpMedian, Self.baselineJumpMedian)
        )

        // —— B 角色抖动率断言 ——
        if metrics.roleSwitchPerMinute > Self.targetSwitchPerMinute {
            Self.printFailureDetails(notes: data.notes)
        }
        XCTAssertLessThanOrEqual(
            metrics.roleSwitchPerMinute, Self.targetSwitchPerMinute,
            String(format: "B 角色抖动率 %.3f 次/分钟 > 目标 %.1f（两色角色仍频繁互换）",
                   metrics.roleSwitchPerMinute, Self.targetSwitchPerMinute)
        )

        // —— C 主线覆盖守恒断言（防"少标作弊"）——
        XCTAssertGreaterThanOrEqual(
            metrics.melodyCoverageRatio, Self.targetCoverage,
            String(format: "C melody 覆盖率 %.4f < 目标 %.2f（主线覆盖塌陷）",
                   metrics.melodyCoverageRatio, Self.targetCoverage)
        )

        // —— D1 melody 全曲跨度断言（防角色坍缩为短区段）——
        XCTAssertGreaterThanOrEqual(
            metrics.melodySpanRatio, Self.targetMelodySpanRatio,
            String(format: "D1 melody 跨度比 %.3f < 目标 %.2f（主旋律未跨全曲，" +
                "角色坍缩为 %.1fs 短区段）",
                   metrics.melodySpanRatio, Self.targetMelodySpanRatio, metrics.melodySpanSeconds)
        )

        // —— D2 counter 全曲跨度与音符数断言（防 counter 归零）——
        XCTAssertGreaterThanOrEqual(
            metrics.counterSpanRatio, Self.targetCounterSpanRatio,
            String(format: "D2 counter 跨度比 %.3f < 目标 %.2f（副旋律消失）",
                   metrics.counterSpanRatio, Self.targetCounterSpanRatio)
        )
        XCTAssertGreaterThanOrEqual(
            metrics.countermelodyNoteCount, Self.targetCounterNoteCount,
            String(format: "D2 counter 音符数 %d < 目标 %d（副旋律归零）",
                   metrics.countermelodyNoteCount, Self.targetCounterNoteCount)
        )

        // —— E1 主线全曲覆盖率断言（链构建后相对基线改善 ≥ 15%）——
        XCTAssertGreaterThanOrEqual(
            metrics.melodyFullSongCoverage, Self.targetFullSongCoverage,
            String(format: "E1 主线全曲覆盖率 %.4f < 目标 %.4f（基线 %.5f × 1.15，" +
                "旋律链未把断开段落接回主线）",
                   metrics.melodyFullSongCoverage, Self.targetFullSongCoverage,
                   Self.baselineFullSongCoverage)
        )

        // —— E2 旋律段数断言（链构建后段数 ≤ 基线 × 0.6）——
        XCTAssertLessThanOrEqual(
            Double(metrics.melodySegmentCount), Self.targetMelodySegmentCount,
            String(format: "E2 旋律段数 %d > 目标 %.1f（基线 %d × 0.6，" +
                "黄线仍呈片段式分离）",
                   metrics.melodySegmentCount, Self.targetMelodySegmentCount,
                   Self.baselineMelodySegmentCount)
        )

        // —— G1 轮廓命中率断言（轮廓带内候选音符被标黄的比例）——
        XCTAssertGreaterThanOrEqual(
            metrics.contourHitRate, Self.targetContourHitRate,
            String(format: "G1 轮廓命中率 %.4f < 目标 %.4f（基线 %.2f × 1.3，" +
                "轮廓带内仍有大量音符被判 background——同一条旋律线上黄白交替）",
                   metrics.contourHitRate, Self.targetContourHitRate,
                   Self.baselineContourHitRate)
        )

        // —— G2 轮廓断点数断言（轮廓线上黄白交替次数）——
        XCTAssertLessThanOrEqual(
            Double(metrics.contourBreakCount), Self.targetContourBreakCount,
            String(format: "G2 轮廓断点 %d > 目标 %.1f（基线 %d × 0.4，" +
                "旋律轮廓仍被非旋律音符反复打断）",
                   metrics.contourBreakCount, Self.targetContourBreakCount,
                   Self.baselineContourBreakCount)
        )
    }
}
