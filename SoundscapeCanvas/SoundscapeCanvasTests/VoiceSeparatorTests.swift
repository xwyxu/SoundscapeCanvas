//
//  VoiceSeparatorTests.swift
//  SoundscapeCanvasTests
//
//  VoiceSeparator.assignRoles 单元测试 —— 手工构造音符（confidence 0.5–0.95），
//  期望值由 spec「声部分离算法设计」三步算法逐条推导演算（见各用例注释）。
//

import XCTest
@testable import SoundscapeCanvas

final class VoiceSeparatorTests: XCTestCase {

    // MARK: - 构造辅助

    /// 快速构造音符（role 默认 background，由被测函数回写）
    private func note(
        _ start: Double,
        _ end: Double,
        _ midi: Int,
        _ confidence: Double = 0.9
    ) -> MelodyNote {
        MelodyNote(
            startTime: start,
            endTime: end,
            midiNote: midi,
            confidence: confidence,
            pitchBends: nil
        )
    }

    /// 主旋律（C5 区，0.5s × 5 连续音符）：salience = (0.9×2.5) × 1.0 × 1.0 = 2.25
    /// （均值 (72+74+76+74+72)/5 = 73.6 ∈ 55–84 → 音区先验 1.0；覆盖率 2.5/2.5 = 1.0）
    private func melodyLine() -> [MelodyNote] {
        [
            note(0.0, 0.5, 72), note(0.5, 1.0, 74), note(1.0, 1.5, 76),
            note(1.5, 2.0, 74), note(2.0, 2.5, 72),
        ]
    }

    /// 副旋律（G4 区，同节奏）：salience = (0.8×2.5) × 1.0 × 1.0 = 2.0
    /// （均值 68.6 ∈ 55–84 → 先验 1.0；与主旋律音高类距离 5.0 > 2 → 非近重复）
    private func counterLine() -> [MelodyNote] {
        [
            note(0.0, 0.5, 67, 0.8), note(0.5, 1.0, 69, 0.8), note(1.0, 1.5, 71, 0.8),
            note(1.5, 2.0, 69, 0.8), note(2.0, 2.5, 67, 0.8),
        ]
    }

    /// 和弦垫碎片（低音区三音柱式和弦，t = 0 / 1.0 / 2.0 各一击，0.25s）：
    /// 每个垫音各自成线且总时长 0.25s < 1.0s → 碎片线出局
    private func padStabs() -> [MelodyNote] {
        let pitches = [50, 53, 55] // 与主/副旋律线尾音高差均 > 12，不会被线追踪误吸
        var notes: [MelodyNote] = []
        for t in [0.0, 1.0, 2.0] {
            for p in pitches {
                notes.append(note(t, t + 0.25, p, 0.6))
            }
        }
        return notes
    }

    // MARK: - 用例 1：标准三声部（主/副归线正确、和弦垫为 background）

    func testThreeVoicesMelodyCounterAndPad() {
        let input = melodyLine() + counterLine() + padStabs()
        let result = VoiceSeparator.assignRoles(to: input)

        // 主旋律 5 音（C5 区 midi 72/74/76，conf 0.9）全部标为 melody
        let melodyNotes = result.filter { [72, 74, 76].contains($0.midiNote) && $0.confidence == 0.9 }
        XCTAssertEqual(melodyNotes.count, 5)
        for n in melodyNotes {
            XCTAssertEqual(n.role, .melody, "midi \(n.midiNote) @ \(n.startTime) 应为主旋律")
        }
        // 副旋律 5 音（G4 区，conf 0.8）全部标为 countermelody
        let counterNotes = result.filter { [67, 69, 71].contains($0.midiNote) && $0.confidence == 0.8 }
        XCTAssertEqual(counterNotes.count, 5)
        for n in counterNotes {
            XCTAssertEqual(n.role, .countermelody, "midi \(n.midiNote) @ \(n.startTime) 应为副旋律")
        }
        // 和弦垫 9 音（低音区三音柱式和弦，conf 0.6）全部保持 background
        let padNotes = result.filter { [50, 53, 55].contains($0.midiNote) && $0.confidence == 0.6 }
        XCTAssertEqual(padNotes.count, 9)
        for n in padNotes {
            XCTAssertEqual(n.role, .background, "垫音 midi \(n.midiNote) 应为背景")
        }
        // 角色计数汇总（主旋律线 salience 2.25 > 副旋律线 2.0 > 出局的碎片/垫线）
        XCTAssertEqual(result.filter { $0.role == .melody }.count, 5)
        XCTAssertEqual(result.filter { $0.role == .countermelody }.count, 5)
        XCTAssertEqual(result.filter { $0.role == .background }.count, 9)
    }

    // MARK: - 用例 2：低音排除（MIDI 33–43 长音线不参与主/副旋律）

    func testBassLineExcluded() {
        // 低音线：36/38/36 各 1.0s 长音，总时长 3.0s ≥ 1.0s 非碎片，
        // 线追踪可成线（步进 2 ≤ 12），但均值 (36+38+36)/3 ≈ 36.7 < 45 → 直接出局；
        // 唯一候选线为主旋律 → melody，无 countermelody，低音全部 background
        let bass: [MelodyNote] = [
            note(0.0, 1.0, 36, 0.95), note(1.0, 2.0, 38, 0.95), note(2.0, 3.0, 36, 0.95),
        ]
        let result = VoiceSeparator.assignRoles(to: melodyLine() + bass)

        for n in result.filter({ $0.midiNote <= 43 }) {
            XCTAssertEqual(n.role, .background, "低音 midi \(n.midiNote) 不得被选为主/副旋律")
        }
        XCTAssertEqual(result.filter { $0.role == .melody }.count, 5)
        XCTAssertEqual(result.filter { $0.role == .countermelody }.count, 0)
    }

    // MARK: - 用例 3：单声部回退（只产主旋律，无副旋律）

    func testSingleVoiceMarksMelodyOnly() {
        // 单音序列：单线总时长 2.0s ≥ 1.0s，均值 63.6 → salience = 0.85×2.0 = 1.7
        // → 唯一候选线即主旋律；仅 1 条候选线 → 副旋律为空
        let input: [MelodyNote] = [
            note(0.0, 0.4, 60, 0.85), note(0.4, 0.8, 62, 0.85), note(0.8, 1.2, 64, 0.85),
            note(1.2, 1.6, 65, 0.85), note(1.6, 2.0, 67, 0.85),
        ]
        let result = VoiceSeparator.assignRoles(to: input)

        XCTAssertEqual(result.count, input.count)
        for n in result {
            XCTAssertEqual(n.role, .melody)
        }
    }

    func testFragmentSequenceFallsBackToBackground() {
        // 短序列碎片回退：两音各 0.3s，线总时长 0.6s < 1.0s → 全部 background
        let input: [MelodyNote] = [note(0.0, 0.3, 60, 0.9), note(0.3, 0.6, 62, 0.9)]
        let result = VoiceSeparator.assignRoles(to: input)
        for n in result {
            XCTAssertEqual(n.role, .background)
        }
    }

    // MARK: - 用例 4：近重复抑制（主旋律 +12 半音平行复制线不作为副旋律）

    func testOctaveDuplicateSuppressedWithoutThirdLine() {
        // 复制线 84/86/88/86/84（conf 0.85）：salience = 0.85×2.5 = 2.125 < 主旋律 2.25；
        // 与主旋律时间共现率 1.0 > 0.7，音高类距离 |84−73.6| = 10.4 → min(10.4, 1.6) = 1.6 ≤ 2
        // → 判为近重复被排除；无第三条候选线 → 副旋律为空
        let duplicate: [MelodyNote] = [
            note(0.0, 0.5, 84, 0.85), note(0.5, 1.0, 86, 0.85), note(1.0, 1.5, 88, 0.85),
            note(1.5, 2.0, 86, 0.85), note(2.0, 2.5, 84, 0.85),
        ]
        let result = VoiceSeparator.assignRoles(to: melodyLine() + duplicate)

        XCTAssertEqual(result.filter { $0.role == .melody }.count, 5)
        XCTAssertEqual(result.filter { $0.role == .countermelody }.count, 0, "近重复线不得成为副旋律")
        for n in result.filter({ $0.midiNote >= 84 }) {
            XCTAssertEqual(n.role, .background, "复制线音符应为背景")
        }
    }

    func testOctaveDuplicateSuppressedWithThirdLine() {
        // 有第三条独立线（G4 区，salience 2.0）时：复制线被近重复抑制，
        // 副旋律选中第三条线
        let duplicate: [MelodyNote] = [
            note(0.0, 0.5, 84, 0.85), note(0.5, 1.0, 86, 0.85), note(1.0, 1.5, 88, 0.85),
            note(1.5, 2.0, 86, 0.85), note(2.0, 2.5, 84, 0.85),
        ]
        let result = VoiceSeparator.assignRoles(to: melodyLine() + duplicate + counterLine())

        let counterRoles = result.filter { [67, 69, 71].contains($0.midiNote) && $0.confidence == 0.8 }
        XCTAssertEqual(counterRoles.count, 5)
        for n in counterRoles {
            XCTAssertEqual(n.role, .countermelody, "第三条独立线应被选为副旋律")
        }
        for n in result.filter({ $0.midiNote >= 84 }) {
            XCTAssertEqual(n.role, .background, "复制线音符应为背景")
        }
        XCTAssertEqual(result.filter { $0.role == .melody }.count, 5)
    }

    // MARK: - 用例 5：空数组 / 乱序输入安全且确定性

    func testEmptyInput() {
        XCTAssertEqual(VoiceSeparator.assignRoles(to: []), [])
    }

    func testShuffledInputMatchesSortedInput() {
        // 乱序输入与升序输入必须得到完全一致的结果（确定性）：多键全序排序
        // （startTime → endTime → midiNote → confidence）消除输入顺序影响
        let sorted = melodyLine() + counterLine() + padStabs()
        // 手工确定性乱序（不使用随机数）
        var shuffled: [MelodyNote] = []
        for i in sorted.indices where i % 2 == 1 { shuffled.append(sorted[i]) }
        for i in sorted.indices where i % 2 == 0 { shuffled.append(sorted[i]) }
        shuffled.reverse()

        XCTAssertEqual(VoiceSeparator.assignRoles(to: shuffled), VoiceSeparator.assignRoles(to: sorted))
    }

    // MARK: - 用例 6：主旋律概率泛化（spec: generalize-voice-roles-by-probability）

    /// 概率分布 70/21/8（用户示例）：rawScores [7.0, 2.1, 0.8] →
    /// [0.70, 0.21, 0.08]（份额经同一分母归一，Σ = 100%）
    func testProbabilityDistribution70_21_8() {
        let probabilities = VoiceSeparator.mainMelodyProbabilities(
            rawScores: [7.0, 2.1, 0.8])
        XCTAssertEqual(probabilities.count, 3)
        // 名义份额（用户示例读数，容差 0.008：Σ = 9.9 非整 10，精确值
        // 7/9.9 = 0.70707 与名义 0.70 差 0.71pp）
        XCTAssertEqual(probabilities[0], 0.70, accuracy: 0.008)
        XCTAssertEqual(probabilities[1], 0.21, accuracy: 0.008)
        XCTAssertEqual(probabilities[2], 0.08, accuracy: 0.008)
        // 精确值校验（份额 = raw/Σ：7.0/9.9、2.1/9.9、0.8/9.9）
        XCTAssertEqual(probabilities[0], 7.0 / 9.9, accuracy: 1e-12)
        XCTAssertEqual(probabilities[1], 2.1 / 9.9, accuracy: 1e-12)
        XCTAssertEqual(probabilities[2], 0.8 / 9.9, accuracy: 1e-12)
        // 归一性：Σ = 100%
        XCTAssertEqual(probabilities.reduce(0, +), 1.0, accuracy: 1e-12)
    }

    /// 泛化决策验证据（经 assignRoles/DSP 路径构造）：三条候选线轨迹份额
    /// ≈ 70/22/8 → 线 a（argmax 70%）= melody、线 b（22%，过概率门槛）=
    /// countermelody、线 c（8%，非 Pass 2 argmax 且被显著度比值门摘除）=
    /// background——用户示例泛化结果。
    /// 选 assignRoles 端到端构造而非直测决策函数：概率层接入点（argmax 选
    /// 主 + 全局份额门选副）就在 dspAssignRoles 内，端到端同时覆盖"份额
    /// 计算 → argmax → 门槛"全链；纯函数的精确 70/21/8 份额由
    /// testProbabilityDistribution70_21_8 直测。份额为 70/22/8 而非严格
    /// 70/21/8 的原因：counterSalienceRatio 门要求副线组 em ≥ 0.75×旋律组
    /// em，逐音 salience 严格 7:2.1:0.8 时副线（2.1/7 = 0.30 < 0.75）在
    /// Pass 2 候选门即被摘除（副旋律无从产出），故副线逐音 salience 取
    /// 5.5（= 0.786×7，过显著度比值门且与旋律归一化显著度差 0.214 ≥ 0.06
    /// 不被并线）→ 份额 22%，过概率门槛（≥0.05），泛化语义与用户示例一致。
    func testGeneralizeMelodyIsArgmax() {
        // 线 a（份额 70% = argmax）：C5 区 5 音（0.5s×5，t=0–2.5），
        // salience 7.0 → 轨迹评分 5×7×1.0(覆盖) = 35
        let lineA: [MelodyNote] = [
            note(0.0, 0.5, 72, 0.9), note(0.5, 1.0, 74, 0.9), note(1.0, 1.5, 76, 0.9),
            note(1.5, 2.0, 74, 0.9), note(2.0, 2.5, 72, 0.9),
        ]
        // 线 b（份额 22% ≥ 10%）：G4 区 2 音（t=0–1.0），salience 5.5 →
        // 轨迹评分 2×5.5 = 11（过显著度比值门 5.5 ≥ 0.75×7 = 5.25）
        let lineB: [MelodyNote] = [
            note(0.0, 0.5, 67, 0.8), note(0.5, 1.0, 69, 0.8),
        ]
        // 线 c（份额 8% < 10%）：C4 区 2 音（t=0–1.0），salience 2.0 →
        // 轨迹评分 2×2.0 = 4
        let lineC: [MelodyNote] = [
            note(0.0, 0.5, 60, 0.7), note(0.5, 1.0, 62, 0.7),
        ]
        let input = lineA + lineB + lineC
        // 平行 salience 数组：全局份额分母 = 35+11+4 = 50 → 70%/22%/8%
        let salience: [Double] = [7.0, 7.0, 7.0, 7.0, 7.0, 5.5, 5.5, 2.0, 2.0]
        let result = VoiceSeparator.assignRoles(to: input, acousticSalience: salience)

        // 线 a：份额 70% = argmax → melody（5 音全标）
        let aNotes = result.filter {
            [72, 74, 76].contains($0.midiNote) && $0.confidence == 0.9
        }
        XCTAssertEqual(aNotes.count, 5)
        for n in aNotes {
            XCTAssertEqual(n.role, .melody, "份额 70%（argmax）的线 a 应泛化为主旋律")
        }
        // 线 b：份额 22% 过概率门槛（≥0.05）→ countermelody
        let bNotes = result.filter {
            [67, 69].contains($0.midiNote) && $0.confidence == 0.8
        }
        XCTAssertEqual(bNotes.count, 2)
        for n in bNotes {
            XCTAssertEqual(n.role, .countermelody, "份额 22%（过概率门槛）的线 b 应为副旋律")
        }
        // 线 c：非 Pass 2 argmax（份额 8% 低于线 b 且被显著度比值门摘除）
        // → background（2 音全背景）
        let cNotes = result.filter {
            [60, 62].contains($0.midiNote) && $0.confidence == 0.7
        }
        XCTAssertEqual(cNotes.count, 2)
        for n in cNotes {
            XCTAssertEqual(n.role, .background, "非 argmax 的线 c 应为背景")
        }
        // 角色计数汇总（70/22/8 → 5 melody / 2 countermelody / 2 background）
        XCTAssertEqual(result.filter { $0.role == .melody }.count, 5)
        XCTAssertEqual(result.filter { $0.role == .countermelody }.count, 2)
        XCTAssertEqual(result.filter { $0.role == .background }.count, 2)
    }

    /// 低概率无副旋律（对应用户示例 94%/6% 的低份额场景）：副线全局份额
    /// 0.041 < countermelodyProbabilityThreshold(0.05) → 概率门槛置空
    /// counterSet —— 仅产主旋律，无副旋律。副线构造为过全部既有门的独立
    /// 候选（单音 1.2s ≥ 1.0s 非碎片；em 6.0 ≥ 0.75×7 过显著度比值门；
    /// 低于旋律音区不被高八度幽灵掩码），确保本用例由**新增概率门槛**决胜
    /// （无该门时副线会被提为 countermelody）。份额推导：门槛 0.05 要求
    /// em_b < 0.368×n_a（单音副线 score=em_b、主线 score=7·n_a），n_a=20
    /// 时上界 7.37；显著度比值门要求 em_b ≥ 5.25——取 6.0 兼顾两侧 →
    /// 份额 6/(140+6) = 0.0411。
    func testCountermelodyBelowThreshold() {
        // 主旋律线：C5 区 20 音（0.5s×20，t=0–10.0），salience 7.0 →
        // 轨迹评分 20×7 = 140（全局份额 95.9%）
        let mainLine: [MelodyNote] = [
            note(0.0, 0.5, 72, 0.9), note(0.5, 1.0, 74, 0.9), note(1.0, 1.5, 76, 0.9),
            note(1.5, 2.0, 74, 0.9), note(2.0, 2.5, 72, 0.9), note(2.5, 3.0, 71, 0.9),
            note(3.0, 3.5, 72, 0.9), note(3.5, 4.0, 74, 0.9), note(4.0, 4.5, 76, 0.9),
            note(4.5, 5.0, 78, 0.9), note(5.0, 5.5, 76, 0.9), note(5.5, 6.0, 74, 0.9),
            note(6.0, 6.5, 72, 0.9), note(6.5, 7.0, 74, 0.9), note(7.0, 7.5, 76, 0.9),
            note(7.5, 8.0, 74, 0.9), note(8.0, 8.5, 72, 0.9), note(8.5, 9.0, 71, 0.9),
            note(9.0, 9.5, 72, 0.9), note(9.5, 10.0, 74, 0.9),
        ]
        // 副线候选：G4 区单音 1.2s（t=0–1.2，与主旋律同时段），salience 6.0 →
        // 轨迹评分 6.0（全局份额 6/(140+6) = 0.0411 < 0.05）
        let weakLine: [MelodyNote] = [note(0.0, 1.2, 67, 0.8)]
        let input = mainLine + weakLine
        let salience: [Double] = Array(repeating: 7.0, count: 20) + [6.0]
        let result = VoiceSeparator.assignRoles(to: input, acousticSalience: salience)

        // 主旋律 20 音全标 melody
        let melodyNotes = result.filter {
            [71, 72, 74, 76, 78].contains($0.midiNote) && $0.confidence == 0.9
        }
        XCTAssertEqual(melodyNotes.count, 20)
        for n in melodyNotes {
            XCTAssertEqual(n.role, .melody, "主旋律线音应标记为 melody")
        }
        // 副线全局份额 0.041 < 0.05 → 不产出副旋律
        XCTAssertEqual(
            result.filter { $0.role == .countermelody }.count, 0,
            "份额 4.1% < 5% 的副线不得被提为 countermelody")
        for n in result.filter({ $0.midiNote == 67 && $0.confidence == 0.8 }) {
            XCTAssertEqual(n.role, .background, "低份额副线应为背景")
        }
    }

    /// 零和防护：rawScores [0,0,0] → 均分 [1/3,1/3,1/3]，且重复调用结果
    /// 一致（确定性——同输入同输出）
    func testZeroScoreUniformGuard() {
        let probabilities = VoiceSeparator.mainMelodyProbabilities(rawScores: [0, 0, 0])
        XCTAssertEqual(probabilities.count, 3)
        XCTAssertEqual(probabilities[0], 1.0 / 3.0, accuracy: 0.005)
        XCTAssertEqual(probabilities[1], 1.0 / 3.0, accuracy: 0.005)
        XCTAssertEqual(probabilities[2], 1.0 / 3.0, accuracy: 0.005)
        // 确定性：重复调用逐位一致
        let again = VoiceSeparator.mainMelodyProbabilities(rawScores: [0, 0, 0])
        XCTAssertEqual(probabilities, again)
    }

    /// 单声部：rawScores [5.0] → [1.0]（唯一候选线概率 100%）
    func testSingleLineFullProbability() {
        let probabilities = VoiceSeparator.mainMelodyProbabilities(rawScores: [5.0])
        XCTAssertEqual(probabilities.count, 1)
        XCTAssertEqual(probabilities[0], 1.0, accuracy: 0.005)
    }
}
