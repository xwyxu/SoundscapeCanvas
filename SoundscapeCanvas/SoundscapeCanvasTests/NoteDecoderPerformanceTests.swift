//
//  NoteDecoderPerformanceTests.swift
//  SoundscapeCanvasTests
//
//  melodia 循环性能回归测试。
//
//  背景：outputToNotesPoly(melodiaTrick: true) 的 melodia 循环原实现每轮迭代做
//  2 次全矩阵扫描（while 条件的 globalMax + 逐行 argMax 找峰值），长音频
//  （2 万+ 帧）在 Debug 构建下耗时数百秒（用户感知"卡死在 100%"）。
//  修复方案为行缓存 + 脏行重算（语义逐位等价，见 NoteDecoder.swift 内的论证注释）。
//
//  本测试用种子随机数（可复现）构造 8000×88 密集矩阵：约 250 个带 onset 的
//  持续音符段（主路径回收）+ 650 个无 onset 的短促能量脉冲（melodia 循环的
//  压力元素——每条消耗一次 melodia 迭代但被 minNoteLength=5 跳过不产音符，
//  使输出保持约 250 音符量级，同时让 melodia 循环成为瓶颈）。
//  实测锚点（Debug）：修复前 ≈ 86s（必失败），修复后 ≈ 3s。
//

import XCTest
@testable import SoundscapeCanvas

final class NoteDecoderPerformanceTests: XCTestCase {

    // MARK: - 可复现种子随机数

    /// SplitMix64：种子固定则序列固定，保证矩阵构造在每次运行时完全一致
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - 密集矩阵构造

    /// 8000×88 密集矩阵（88 = 模型频率 bin 数）：
    /// - 噪声底 0–0.28（低于 frameThreshold 默认 0.3，构成音符段的天然终止）
    /// - 约 250 个持续音符段：frames 0.4–0.95，onsets 起始 0.5–0.9（主路径回收）
    /// - 650 个短促能量脉冲：frames 0.4–0.6、2–6 帧、无 onset（melodia 压力元素）
    private func buildDenseMatrix() -> (frames: [[Double]], onsets: [[Double]]) {
        let nFrames = 8000
        let nFreqs = 88
        var gen = SeededGenerator(seed: 0x2026_0912)
        var frames = [[Double]](repeating: [Double](repeating: 0, count: nFreqs), count: nFrames)
        var onsets = [[Double]](repeating: [Double](repeating: 0, count: nFreqs), count: nFrames)

        for r in 0..<nFrames {
            for c in 0..<nFreqs {
                frames[r][c] = Double.random(in: 0..<0.28, using: &gen)
            }
        }

        for _ in 0..<250 {
            let col = Int.random(in: 0..<nFreqs, using: &gen)
            let start = Int.random(in: 0..<(nFrames - 450), using: &gen)
            let length = Int.random(in: 30...400, using: &gen)
            for r in start..<(start + length) {
                frames[r][col] = Double.random(in: 0.4...0.95, using: &gen)
            }
            onsets[start][col] = Double.random(in: 0.5...0.9, using: &gen)
        }

        for _ in 0..<650 {
            let col = Int.random(in: 0..<nFreqs, using: &gen)
            let start = Int.random(in: 12..<(nFrames - 12), using: &gen)
            let length = Int.random(in: 2...6, using: &gen)
            for r in start..<(start + length) {
                frames[r][col] = Double.random(in: 0.4...0.6, using: &gen)
            }
        }

        return (frames, onsets)
    }

    // MARK: - 性能回归

    /// melodia 循环性能回归：8000×88 密集矩阵上 outputToNotesPoly(melodiaTrick: true)
    /// 必须在 30s 内完成（修复前 ≈ 86s 必失败，修复后 ≈ 3s）。
    /// 音符数 > 0 防止"跳过循环"式的假优化。
    func testMelodiaLoopPerformanceOnDenseMatrix() throws {
        let (frames, onsets) = buildDenseMatrix()

        let t0 = CFAbsoluteTimeGetCurrent()
        let notes = try NoteDecoder.outputToNotesPoly(
            frames: frames,
            onsets: onsets,
            melodiaTrick: true
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        print(String(
            format: "outputToNotesPoly(melodia=true) on 8000x88: %.3fs, %d notes",
            elapsed, notes.count
        ))

        // 防止假优化（如跳过 melodia 循环）：密集矩阵必须产出音符
        XCTAssertGreaterThan(notes.count, 0)
        // 修复前同规模 Debug ≈ 86s（必失败）；修复后 ≈ 3s。30s 阈值留足机器抖动余量
        XCTAssertLessThan(elapsed, 30, "melodia 解码耗时 \(elapsed)s，超过 30s 阈值（性能回归）")
    }
}
