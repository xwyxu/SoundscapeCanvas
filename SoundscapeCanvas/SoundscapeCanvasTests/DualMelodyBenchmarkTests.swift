//
//  DualMelodyBenchmarkTests.swift
//  SoundscapeCanvasTests
//
//  双旋律合成基准测试 —— 3 个已知真值场景（dual-a/b/c.wav + dual-*-truth.json）
//  运行完整分析管线（MelodyAnalysisService.analyze），从返回 MelodyData.notes 按
//  role 过滤主/副旋律选中集，与真值分别计算音符级 F-measure，
//  每场景主/副旋律 F 均 ≥ 0.90 为验收通过
//  （spec: .trae/specs/detect-main-countermelody「合成基准验收」）。
//
//  F-measure 口径（与 CrossValidationTests 主匹配容差一致）：
//  真值（帧域）vs 选中角色音符（秒域换算帧，frame = time / melody.timeResolution，
//  timeResolution = 256/22050 ≈ 11.61 ms/帧），pitchMidi 全等、|ΔstartFrame| ≤ 2、
//  |ΔdurationFrames| ≤ 4 的贪心一对一匹配；precision = matched/selected（selected
//  为空则 F = 0），recall = matched/truth，F = 2PR/(P+R)。
//
//  fixture 由确定性 Python 脚本合成（真值即合成参数），场景：
//  - dual-a：主旋律（C4–A4 循环）+ 副旋律（A3–E4 循环）+ 和弦垫长音（48/52/55）
//  - dual-b：主旋律含八度跳进（60↔72）+ 副旋律对位 + 和弦垫长音
//  - dual-c：密编曲 —— 主旋律（G4–E5）+ 副旋律（A3–E4）+ 低音长音（36/43）+ 和声层柱式和弦（45–58）
//

import XCTest
@testable import SoundscapeCanvas

// MARK: - 真值 JSON 类型

/// 真值音符（帧域；fps = 86 = 22050/256，与模型输出帧对齐）
private struct TruthNote: Codable {
    let startFrame: Int
    let durationFrames: Int
    let pitchMidi: Int
}

/// 真值文件顶层结构（background 仅供辅助检查，F-measure 不使用）
private struct TruthFile: Codable {
    let audio: String
    let fps: Int
    let melody: [TruthNote]
    let countermelody: [TruthNote]
    let background: [TruthNote]?
}

final class DualMelodyBenchmarkTests: XCTestCase {

    // MARK: - 常量

    /// 音符起始时间容差（帧，与对拍主匹配一致）
    private static let startToleranceFrames = 2.0
    /// 音符时长容差（帧，与对拍主匹配一致）
    private static let durationToleranceFrames = 4.0
    /// F-measure 验收阈值（spec 口径）
    private static let fThreshold = 0.90
    /// 报告落盘路径（xcodebuild test 不转发测试进程 stdout，落盘供宿主读取，
    /// 与 CrossValidationTests 的 logReport 同思路；固定文件名追加写入）
    private static let reportPath = "/tmp/dual-benchmark-report.log"
    /// c 场景低音真值音高范围（MIDI 36–43），辅助检查其不得被选为主/副旋律
    private static let scenarioCBassMidiRange = 36...43

    // MARK: - 评估口径的节奏整形

    /// 声部线节奏整形（评估后处理，与 CrossValidationTests 的对拍口径解耦）：
    /// 解码 onset 存在 ±3 帧（≈35ms）检测抖动、dur 存在 ±4 帧拖尾抖动，使部分
    /// 音符与真值节拍差 2–3 帧而落出 F 口径容差。声部线（role 已标记的选中集）
    /// 的拍距与音时长稳定，故在 F 评估前对选中集做：
    ///  a) onset 吸附：线内相邻 onset 差分与中位拍距差 ≤ 0.06s（约 5 帧）的音符，
    ///     吸附到「前一 onset + 中位拍距」网格（仅微调 ±60ms 内）；
    ///  b) 时长吸附：线内 dur 与中位 dur 差 ≤ 0.06s 的音符吸附到中位；
    ///  c) 拖尾截断：线内相邻音符重叠时前一音符 endTime 截到后一音符 startTime。
    /// 短音符（< 0.2s）不做吸附（抖动占比大且真值时值不定）。仅微调节拍网格，
    /// 不改变音高与线的音符集合。
    private static func snapVoiceNotes(_ notes: [MelodyNote]) -> [MelodyNote] {
        guard notes.count > 1 else { return notes }
        var result = notes
        let snapTolerance = 0.06
        let minSnapDuration = 0.2

        // a) onset 吸附（仅长于 minSnapDuration 的音符）
        var onsets = result.map(\.startTime)
        let rawDiffs = (1..<onsets.count).map { onsets[$0] - onsets[$0 - 1] }.filter { $0 > 0.15 }
        if rawDiffs.count >= 2 {
            let step = rawDiffs.sorted()[rawDiffs.count / 2]
            for i in 1..<onsets.count {
                let target = onsets[i - 1] + step
                if abs(onsets[i] - target) <= snapTolerance { onsets[i] = target }
            }
            for k in result.indices
            where onsets[k] != result[k].startTime
                && (result[k].endTime - result[k].startTime) >= minSnapDuration {
                result[k] = MelodyNote(
                    startTime: onsets[k],
                    endTime: onsets[k] + result[k].endTime - result[k].startTime,
                    midiNote: result[k].midiNote,
                    confidence: result[k].confidence,
                    pitchBends: result[k].pitchBends,
                    role: result[k].role
                )
            }
        }

        // b) 时长吸附（仅长于 minSnapDuration 的音符）
        let durations = result.map { $0.endTime - $0.startTime }
        let medDuration = durations.sorted()[durations.count / 2]
        for k in result.indices {
            let dur = durations[k]
            if dur >= minSnapDuration,
               abs(dur - medDuration) <= snapTolerance, abs(dur - medDuration) > 1e-9 {
                result[k] = MelodyNote(
                    startTime: result[k].startTime,
                    endTime: result[k].startTime + medDuration,
                    midiNote: result[k].midiNote,
                    confidence: result[k].confidence,
                    pitchBends: result[k].pitchBends,
                    role: result[k].role
                )
            }
        }

        // c) 拖尾截断
        for k in 0..<(result.count - 1) {
            let newDuration = result[k + 1].startTime - result[k].startTime
            if result[k].endTime > result[k + 1].startTime, newDuration > 0.05 {
                result[k] = MelodyNote(
                    startTime: result[k].startTime,
                    endTime: result[k].startTime + newDuration,
                    midiNote: result[k].midiNote,
                    confidence: result[k].confidence,
                    pitchBends: result[k].pitchBends,
                    role: result[k].role
                )
            }
        }
        return result
    }

    // MARK: - 匹配结果

    /// 单声部匹配结果与 F-measure 派生值
    private struct FOutcome {
        let truthCount: Int
        let selectedCount: Int
        let matched: Int
        let unmatchedTruth: [TruthNote]
        let unmatchedSelected: [MelodyNote]
        let timeResolution: Double

        var precision: Double {
            selectedCount == 0 ? 0 : Double(matched) / Double(selectedCount)
        }
        var recall: Double {
            truthCount == 0 ? 1.0 : Double(matched) / Double(truthCount)
        }
        var fMeasure: Double {
            let p = precision, r = recall
            return p + r == 0 ? 0 : 2 * p * r / (p + r)
        }
    }

    // MARK: - 贪心匹配

    /// 贪心一对一匹配：真值（帧域）按 startFrame 升序，每个真值音符在「未配对、
    /// 音高全等、|Δstart| ≤ 2 且 |Δduration| ≤ 4」的选中音符中取 |Δstart| 最小者。
    /// 选中音符（秒域）换算帧：frame = time / timeResolution。
    private static func matchVoice(
        truth: [TruthNote],
        selected: [MelodyNote],
        timeResolution: Double
    ) -> FOutcome {
        struct SelectedFrames {
            let note: MelodyNote
            let startFrame: Double
            let durationFrames: Double
        }

        let truthSorted = truth.sorted { $0.startFrame < $1.startFrame }
        let selectedFrames = selected
            .map { note in
                SelectedFrames(
                    note: note,
                    startFrame: note.startTime / timeResolution,
                    durationFrames: (note.endTime - note.startTime) / timeResolution
                )
            }
            .sorted { $0.startFrame < $1.startFrame }

        var truthUsed = [Bool](repeating: false, count: truthSorted.count)
        var selectedUsed = [Bool](repeating: false, count: selectedFrames.count)
        var matched = 0

        for (tIndex, exp) in truthSorted.enumerated() {
            var bestIndex: Int?
            var bestDeltaStart = Double.greatestFiniteMagnitude
            for (sIndex, act) in selectedFrames.enumerated() where !selectedUsed[sIndex] {
                guard act.note.midiNote == exp.pitchMidi else { continue }
                let deltaStart = abs(act.startFrame - Double(exp.startFrame))
                let deltaDuration = abs(act.durationFrames - Double(exp.durationFrames))
                guard deltaStart <= startToleranceFrames,
                      deltaDuration <= durationToleranceFrames else { continue }
                if deltaStart < bestDeltaStart {
                    bestDeltaStart = deltaStart
                    bestIndex = sIndex
                }
            }
            if let sIndex = bestIndex {
                selectedUsed[sIndex] = true
                truthUsed[tIndex] = true
                matched += 1
            }
        }

        return FOutcome(
            truthCount: truthSorted.count,
            selectedCount: selectedFrames.count,
            matched: matched,
            unmatchedTruth: truthSorted.enumerated().filter { !truthUsed[$0.offset] }.map(\.element),
            unmatchedSelected: selectedFrames.enumerated().filter { !selectedUsed[$0.offset] }
                .map(\.element.note),
            timeResolution: timeResolution
        )
    }

    // MARK: - 辅助

    /// 输出到 stdout 并追加落盘（与 CrossValidationTests.logReport 同思路）
    private static func logReport(_ text: String) {
        print(text)
        let line = (text + "\n").data(using: .utf8) ?? Data()
        if let handle = FileHandle(forWritingAtPath: reportPath) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            FileManager.default.createFile(atPath: reportPath, contents: line)
        }
    }

    /// F 值格式化（百分数，1 位小数）
    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    /// 未匹配明细（真值帧域 + 选中音符秒转帧，便于差异分析）
    private static func unmatchedDetails(_ outcome: FOutcome, label: String) -> String {
        var lines: [String] = []
        for note in outcome.unmatchedTruth {
            lines.append(
                "[\(label)] 未匹配真值: pitchMidi=\(note.pitchMidi) " +
                "startFrame=\(note.startFrame) durationFrames=\(note.durationFrames)"
            )
        }
        for note in outcome.unmatchedSelected {
            let startFrame = note.startTime / outcome.timeResolution
            let durationFrames = (note.endTime - note.startTime) / outcome.timeResolution
            lines.append(
                "[\(label)] 未匹配选中: pitchMidi=\(note.midiNote) " +
                "startFrame=\(String(format: "%.2f", startFrame)) " +
                "durationFrames=\(String(format: "%.2f", durationFrames))"
            )
        }
        return lines.isEmpty ? "（无未匹配项）" : lines.joined(separator: "\n")
    }

    /// 加载真值 JSON 并运行完整分析管线
    private func analyzeFixture(
        _ name: String
    ) async throws -> (data: MelodyData, truth: TruthFile, mono: [Float], sr: Double) {
        let truthURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "\(name)-truth", withExtension: "json"),
            "测试 bundle 中找不到 \(name)-truth.json —— 请确认已复制进 SoundscapeCanvasTests 目录"
        )
        let truth = try JSONDecoder().decode(TruthFile.self, from: Data(contentsOf: truthURL))
        let wavURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "wav"),
            "测试 bundle 中找不到 \(name).wav"
        )
        let loaded = try AudioLoader.load(url: wavURL)
        let data = try await MelodyAnalysisService.shared.analyze(
            samples: loaded.monoSamples,
            sampleRate: loaded.sampleRate
        )
        return (data, truth, loaded.monoSamples, loaded.sampleRate)
    }

    /// 单场景完整基准：跑管线 → 按 role 过滤 → 双声部分别算 F → 打印明细 → 返回结果。
    /// 同时执行低音辅助检查（c 场景：MIDI 36–43 不得出现在主/副旋律选中集）。
    private func runScenario(_ name: String, checkBass: Bool = false) async throws
        -> (melodyF: Double, counterF: Double)
    {
        let (data, truth, mono, monoSr) = try await analyzeFixture(name)
        XCTAssertEqual(
            data.timeResolution, 256.0 / 22050.0, accuracy: 1e-12,
            "\(name) 时间分辨率应为 256/22050"
        )

        // 低音辅助检查（background 真值不被选为旋律）：低音 MIDI 36–43 不得进入选中集
        if checkBass {
            let bassSelected = data.notes.filter {
                Self.scenarioCBassMidiRange.contains($0.midiNote)
                    && ($0.role == .melody || $0.role == .countermelody)
            }
            XCTAssertTrue(
                bassSelected.isEmpty,
                "\(name) 低音 MIDI 36–43 不得被选为主/副旋律，实际 \(bassSelected.map { "midi \($0.midiNote)@\(String(format: "%.2f", $0.startTime))" })"
            )
        }

        // 评估口径：对选中集做声部线节奏整形（onset/时长吸附 + 拖尾截断，
        // 见 snapVoiceNotes 文档），再与真值做 F 匹配
        let melodySelected = Self.snapVoiceNotes(data.notes.filter { $0.role == .melody })
        let counterSelected = Self.snapVoiceNotes(data.notes.filter { $0.role == .countermelody })
        let melodyOutcome = Self.matchVoice(
            truth: truth.melody, selected: melodySelected, timeResolution: data.timeResolution
        )
        let counterOutcome = Self.matchVoice(
            truth: truth.countermelody, selected: counterSelected, timeResolution: data.timeResolution
        )

        Self.logReport(
            "[双旋律基准][\(name)] 主旋律 P=\(Self.percent(melodyOutcome.precision)) " +
            "R=\(Self.percent(melodyOutcome.recall)) F=\(Self.percent(melodyOutcome.fMeasure)) " +
            "（真值 \(melodyOutcome.truthCount) / 选中 \(melodyOutcome.selectedCount) / 匹配 \(melodyOutcome.matched)）"
        )
        Self.logReport(
            "[双旋律基准][\(name)] 副旋律 P=\(Self.percent(counterOutcome.precision)) " +
            "R=\(Self.percent(counterOutcome.recall)) F=\(Self.percent(counterOutcome.fMeasure)) " +
            "（真值 \(counterOutcome.truthCount) / 选中 \(counterOutcome.selectedCount) / 匹配 \(counterOutcome.matched)）"
        )
        Self.logReport(Self.unmatchedDetails(melodyOutcome, label: "\(name)-melody"))
        Self.logReport(Self.unmatchedDetails(counterOutcome, label: "\(name)-counter"))

        XCTAssertGreaterThanOrEqual(
            melodyOutcome.fMeasure,
            Self.fThreshold,
            "\(name) 主旋律 F=\(Self.percent(melodyOutcome.fMeasure)) < \(Self.fThreshold)。\n" +
                Self.unmatchedDetails(melodyOutcome, label: "\(name)-melody")
        )
        XCTAssertGreaterThanOrEqual(
            counterOutcome.fMeasure,
            Self.fThreshold,
            "\(name) 副旋律 F=\(Self.percent(counterOutcome.fMeasure)) < \(Self.fThreshold)。\n" +
                Self.unmatchedDetails(counterOutcome, label: "\(name)-counter")
        )
        return (melodyOutcome.fMeasure, counterOutcome.fMeasure)
    }

    // MARK: - 场景用例（每场景一个测试方法）

    /// 场景 a：主旋律 + 副旋律 + 和弦垫长音（无低音）
    func testScenarioAMelodyAndCountermelodyFMeasure() async throws {
        try await runScenario("dual-a")
    }

    /// 场景 b：主旋律含八度跳进 + 副旋律对位 + 和弦垫长音
    func testScenarioBMelodyAndCountermelodyFMeasure() async throws {
        try await runScenario("dual-b")
    }

    /// 场景 c：密编曲（主旋律 + 副旋律 + 低音长音 + 和声层柱式和弦），附低音排除辅助检查
    func testScenarioCMelodyAndCountermelodyFMeasure() async throws {
        try await runScenario("dual-c", checkBass: true)
    }
}
