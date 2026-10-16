//
//  NoteDecoderTests.swift
//  SoundscapeCanvasTests
//
//  NoteDecoder（outputToNotesPoly / addPitchBends / 帧转秒等）合成数据单元测试。
//  所有期望值均由 JS 参考实现（toMidi.ts）逐行手工推导演算得出。
//

import XCTest
@testable import SoundscapeCanvas

final class NoteDecoderTests: XCTestCase {

    // MARK: - 辅助

    /// nFrames × 88 全零矩阵（88 = 模型频率 bin 数）
    private func zeros(_ rows: Int, cols: Int = 88) -> [[Double]] {
        Array(repeating: Array(repeating: 0, count: cols), count: rows)
    }

    // MARK: - 常量

    func testWindowOffsetValue() {
        // windowOffset = (256/22050) × (172 − 43844/256) + 0.0018
        //             = (256/22050) × 0.734375 + 0.0018
        //             = 188/22050 + 0.0018
        //             = 0.008526077097505669 + 0.0018 = 0.010326077097505669
        XCTAssertEqual(NoteDecoder.windowOffset, 0.010326077097505669, accuracy: 1e-9)
    }

    // MARK: - argMax（JS tie 语义：相等取更靠后的索引）

    func testArgMaxTieBreaking() {
        XCTAssertNil(NoteDecoder.argMax([]))
        // 两个并列最大值 2：JS 的 reduce 在相等时（> 为 false）取后者 → 索引 2
        XCTAssertEqual(NoteDecoder.argMax([1, 2, 2, 1]), 2)
        XCTAssertEqual(NoteDecoder.argMax([3, 1, 2]), 0)
        XCTAssertEqual(NoteDecoder.argMax([5]), 0)
        // 全零行：所有比较相等 → 取最后索引（melodia 循环中依赖此行为）
        XCTAssertEqual(NoteDecoder.argMax([0, 0, 0, 0]), 3)
    }

    // MARK: - modelFrameToTime

    func testModelFrameToTime() {
        // frame 0：0 − windowOffset × floor(0/172) = 0
        XCTAssertEqual(NoteDecoder.modelFrameToTime(0), 0, accuracy: 1e-12)
        // 同一窗内（frame < 172）：floor(frame/172) = 0，无 windowOffset 修正
        XCTAssertEqual(NoteDecoder.modelFrameToTime(86), 86.0 * 256.0 / 22050.0, accuracy: 1e-9)
        // frame = 172（第二个窗起点）：172×256/22050 − windowOffset × floor(172/172)
        //   = 1.9969160997732426 − 0.010326077097505669 = 1.9865900226757370
        XCTAssertEqual(NoteDecoder.modelFrameToTime(172), 1.9865900226757370, accuracy: 1e-9)
    }

    // MARK: - outputToNotesPoly（40 帧 × 88 列合成矩阵）

    /// 用例 1：单音符。
    /// onsets[5][40] = 0.9，frames[5...20][40] = 0.8。
    /// 能量追踪：第 21 帧起能量为 0，连续累计 k 至 11（energyTolerance）后退出，
    /// i = 32 − 11 = 21 → duration = 21 − 5 = 16；幅度 = 16 帧 × 0.8 的均值 = 0.8。
    func testSingleNote() throws {
        let nFrames = 40
        var frames = zeros(nFrames)
        var onsets = zeros(nFrames)
        onsets[5][40] = 0.9
        for r in 5...20 { frames[r][40] = 0.8 }

        let notes = try NoteDecoder.outputToNotesPoly(frames: frames, onsets: onsets)

        XCTAssertEqual(notes.count, 1)
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.startFrame, 5)
        XCTAssertEqual(note.durationFrames, 16)
        XCTAssertEqual(note.pitchMidi, 61) // 40 + MIDI_OFFSET(21)
        XCTAssertEqual(note.amplitude, 0.8, accuracy: 1e-12)
        XCTAssertNil(note.pitchBends)
    }

    /// 用例 2：minNoteLength 过滤。
    /// frames 仅持续 4 帧（5...8）：主路径 i − start = 4 ≤ 5 被跳过（且不清零能量）；
    /// melodia 路径随后捡起该能量，但其 iEnd − iStart = 8 − 5 = 3 ≤ 5 同样被跳过 → 无音符。
    func testMinNoteLengthFiltersShortNote() throws {
        let nFrames = 40
        var frames = zeros(nFrames)
        var onsets = zeros(nFrames)
        onsets[5][40] = 0.9
        for r in 5...8 { frames[r][40] = 0.8 } // 仅 4 帧

        let notes = try NoteDecoder.outputToNotesPoly(frames: frames, onsets: onsets)
        XCTAssertTrue(notes.isEmpty)
    }

    /// 用例 3：inferOnsets 效果。
    /// 注：任务描述的原始构想（onsets 全 0）在 JS 中 onsetMax = 0 会把 frameDiff 整体缩放为
    /// 0，推断起始失效（音符只能由 melodia 路径产出，见下一个用例）。此处按 JS 真实语义构造：
    /// onsets 带一个真实峰值 + frames 出现更大的二段阶跃 → 推断出第二个起始。
    ///
    /// 构造：onsets[5][40] = 0.9；frames[5..<12][40] = 0.35，frames[12..<22][40] = 0.95。
    /// frameDiff：[5] = 0.35（n=1、n=2 取 min）、[12] = 0.6（二段阶跃为最大差分）；
    /// 缩放系数 = onsetMax/frameDiffMax = 0.9/0.6 = 1.5 → 推断 onsets [12][40] = 0.9 > 0.5。
    /// noteStarts 反转后按 [12, 5] 顺序处理：
    ///   - (12)：能量持续至 21 帧，k 从 22 累至 32 → i = 33 − 11 = 22 → duration = 10；
    ///     并清零行 12..<22 的列 39...41
    ///   - (5)：行 6...11 能量 0.35 在阈值上；行 12 起已被上一音符清零 → k 自 12 累至 22
    ///     → i = 23 − 11 = 12 → duration = 7
    func testInferredOnsetsCreateSecondNoteOnset() throws {
        let nFrames = 40
        var frames = zeros(nFrames)
        var onsets = zeros(nFrames)
        onsets[5][40] = 0.9
        for r in 5..<12 { frames[r][40] = 0.35 }
        for r in 12..<22 { frames[r][40] = 0.95 }

        let notes = try NoteDecoder.outputToNotesPoly(frames: frames, onsets: onsets)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].startFrame, 12)
        XCTAssertEqual(notes[0].durationFrames, 10)
        XCTAssertEqual(notes[0].pitchMidi, 61)
        XCTAssertEqual(notes[0].amplitude, 0.95, accuracy: 1e-12)
        XCTAssertEqual(notes[1].startFrame, 5)
        XCTAssertEqual(notes[1].durationFrames, 7)
        XCTAssertEqual(notes[1].pitchMidi, 61)
        XCTAssertEqual(notes[1].amplitude, 0.35, accuracy: 1e-12)

        // 对照：关闭 inferOnsets 后仅剩 onsets[5] 一个起始 → 单音符，
        // 能量贯穿 5..<22（i = 33 − 11 = 22 → duration = 17），幅度 = (0.35×7 + 0.95×10)/17
        let notesNoInfer = try NoteDecoder.outputToNotesPoly(
            frames: frames, onsets: onsets, inferOnsets: false
        )
        XCTAssertEqual(notesNoInfer.count, 1)
        XCTAssertEqual(notesNoInfer[0].startFrame, 5)
        XCTAssertEqual(notesNoInfer[0].durationFrames, 17)
        XCTAssertEqual(notesNoInfer[0].amplitude, 11.95 / 17.0, accuracy: 1e-12)
    }

    /// 用例 4：melodiaTrick 补充。
    /// onsets 全 0 且 frames 从第 0 帧起恒定持续（无任何阶跃 → frameDiff 全 0）：
    /// 推断 onsets 为 0/0 = NaN 矩阵 → 无峰值，主路径无起始音符；
    /// melodia 路径从全局最大值 (0, 50) 正反向扫描：
    ///   forward：i = 1...29 高能（k=0），i = 30...38 低能（k = 9），i = 39 时退出
    ///     → iEnd = 39 − 1 − 9 = 29
    ///   backward：iMid − 1 = −1 不进循环 → iStart = 0
    ///   → duration = 29，pitchMidi = 50 + 21 = 71
    func testMelodiaTrickRecoversNoteWithoutOnset() throws {
        let nFrames = 40
        var frames = zeros(nFrames)
        let onsets = zeros(nFrames)
        for r in 0..<30 { frames[r][50] = 0.7 }

        let notes = try NoteDecoder.outputToNotesPoly(frames: frames, onsets: onsets)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].startFrame, 0)
        XCTAssertEqual(notes[0].durationFrames, 29)
        XCTAssertEqual(notes[0].pitchMidi, 71)
        XCTAssertEqual(notes[0].amplitude, 0.7, accuracy: 1e-12)
    }

    /// 用例 5：全零矩阵 → 空结果不崩溃（覆盖 frameDiffMax == 0 的 0/0 = NaN 路径）。
    func testAllZeroMatricesProduceNoNotes() throws {
        let frames = zeros(40)
        let onsets = zeros(40)

        // frameDiffMax = 0 且 onsetMax = 0 → 缩放 0×0/0 = NaN（IEEE754，与 JS 完全一致），
        // NaN 经 max3dForAxis0 传播 → 推断 onsets 为全 NaN 矩阵
        let inferred = NoteDecoder.getInferredOnsets(onsets: onsets, frames: frames)
        XCTAssertEqual(inferred.count, 40)
        XCTAssertTrue(inferred[0][0].isNaN)
        XCTAssertTrue(inferred[39][87].isNaN)

        // NaN 与阈值比较恒为 false → 无峰值；melodia 的 globalMax = 0 → 无音符；不崩溃
        let notes = try NoteDecoder.outputToNotesPoly(frames: frames, onsets: onsets)
        XCTAssertTrue(notes.isEmpty)
    }

    // MARK: - addPitchBendsToNoteEvents

    /// 弯音提取：峰值偏移 ±3 bins 及正中三种情况。
    ///
    /// pitchMidi 61 → contour bin = 12×3×log2(midiToHz(61)/27.5) = 120（数学精确值）；
    /// nBinsTolerance = 25 → 高斯窗长 51，中心对齐 bin 120；
    /// 子矩阵列范围 [95, 146)，pbShift = 25。
    /// JS 的 bends 单位是 contour bin 数（每半音 3 bins）：
    ///   - 峰值在 bin 123（+3 bins = +1 半音）→ argmax 子矩阵内索引 28 → bend = 28 − 25 = +3
    ///   - 峰值在 bin 117（−3 bins = −1 半音）→ 索引 22 → bend = −3
    ///   - 峰值恰在 bin 120 → 索引 25 → bend = 0
    /// （任务描述中"+1/−1"为换算成半音后的值；解码器输出保持 JS 原始的 bins 单位，
    ///  上层渲染如需半音需再除以 3。）
    func testAddPitchBendsOffsets() {
        let note = NoteEvent(
            startFrame: 0, durationFrames: 5, pitchMidi: 61, amplitude: 0.8, pitchBends: nil
        )

        for (peakBin, expectedBend) in [(123, 3.0), (117, -3.0), (120, 0.0)] {
            var contours = zeros(5, cols: 264)
            for r in 0..<5 { contours[r][peakBin] = 1.0 }

            let result = NoteDecoder.addPitchBendsToNoteEvents(contours: contours, notes: [note])

            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[0].pitchBends ?? [], Array(repeating: expectedBend, count: 5))
            // 其余字段原样保留
            XCTAssertEqual(result[0].startFrame, 0)
            XCTAssertEqual(result[0].durationFrames, 5)
            XCTAssertEqual(result[0].pitchMidi, 61)
            XCTAssertEqual(result[0].amplitude, 0.8, accuracy: 1e-12)
        }
    }

    // MARK: - noteFramesToTime

    func testNoteFramesToTime() {
        let note = NoteEvent(
            startFrame: 172, durationFrames: 86, pitchMidi: 69, amplitude: 0.5, pitchBends: nil
        )
        let times = NoteDecoder.noteFramesToTime([note])

        XCTAssertEqual(times.count, 1)
        let t = times[0]
        // start = 172×256/22050 − windowOffset = 1.9865900226757370
        XCTAssertEqual(t.startTimeSeconds, 1.9865900226757370, accuracy: 1e-9)
        // duration = modelFrameToTime(258) − modelFrameToTime(172)；
        // floor(258/172) = floor(172/172) = 1 → windowOffset 项相消 → 86×256/22050 = 0.9984580498866213
        XCTAssertEqual(t.durationSeconds, 0.9984580498866213, accuracy: 1e-9)
        XCTAssertEqual(t.pitchMidi, 69)
        XCTAssertEqual(t.amplitude, 0.5, accuracy: 1e-12)

        // startFrame = 0 → startTime = 0；pitchBends 透传
        let zeroNote = NoteEvent(
            startFrame: 0, durationFrames: 86, pitchMidi: 60, amplitude: 0.5, pitchBends: [0, 1]
        )
        let t2 = NoteDecoder.noteFramesToTime([zeroNote])[0]
        XCTAssertEqual(t2.startTimeSeconds, 0, accuracy: 1e-12)
        XCTAssertEqual(t2.pitchBends ?? [], [0, 1])
    }
}
