//
//  ResamplerTests.swift
//  SoundscapeCanvasTests
//
//  Resampler.resampleLinear 单元测试。
//  期望值由参考实现（MelodyExtractor.ts L79-99）逐行推导演算。
//

import XCTest
@testable import SoundscapeCanvas

final class ResamplerTests: XCTestCase {

    /// 相邻有效样本的符号变化计数（0 值不改变上一有效符号）
    private func zeroCrossings(_ samples: [Double]) -> Int {
        var count = 0
        var lastSign = 0
        for v in samples {
            if v > 0 {
                if lastSign < 0 { count += 1 }
                lastSign = 1
            } else if v < 0 {
                if lastSign > 0 { count += 1 }
                lastSign = -1
            }
        }
        return count
    }

    // ① 源采样率 == 目标采样率：直通返回
    func testPassthroughWhenRatesEqual() {
        let input: [Double] = [0, 0.25, -0.5, 0.75, 1.0, -1.0]
        let output = Resampler.resampleLinear(input, from: 44100, to: 44100)
        XCTAssertEqual(output, input)
    }

    // ② 44100 → 22050：长度 ceil 断言 + 首样本 = input[0] + 整数 ratio 时为精确抽取
    func testDownsampleByTwo() {
        let n = 201
        let input = (0..<n).map { Double($0) * 0.01 - 1.0 } // 单调序列，便于精确断言
        let output = Resampler.resampleLinear(input, from: 44100, to: 22050)

        // outputLength = ceil(201 / 2) = 101
        XCTAssertEqual(output.count, 101)
        // i = 0 → srcIndex = 0 → output[0] == input[0]
        XCTAssertEqual(output[0], input[0])
        // ratio = 2 为精确整数 → frac 恒为 0 → 输出即偶数下标抽取（插值公式退化为直取）
        for i in 0..<101 {
            XCTAssertEqual(output[i], input[2 * i])
        }
    }

    // ②b 44100 → 22050 高频正弦：总过零点数近似减半（宽松断言）
    func testDownsampleHalvesZeroCrossings() {
        let n = 600
        // f = 14700 Hz → 归一化频率恰为 1/3 cycles/sample：
        // 输入 sin(2πk/3) 每 3 样本 2 次过零；抽取偶数下标后 sin(4πi/3) 仍为每 3 样本
        // 2 次过零，但样本总数减半（600 → 300）→ 总过零数近似减半（~400 → ~200）
        let input = (0..<n).map { sin(2.0 * Double.pi * 14700.0 * Double($0) / 44100.0) }
        let output = Resampler.resampleLinear(input, from: 44100, to: 22050)

        XCTAssertEqual(output.count, 300)
        let crossingsIn = zeroCrossings(input)
        let crossingsOut = zeroCrossings(output)
        XCTAssertEqual(Double(crossingsOut), Double(crossingsIn) / 2.0, accuracy: 4.0)
    }

    // ③ 空数组安全（不崩溃、返回空）
    func testEmptyInput() {
        XCTAssertEqual(Resampler.resampleLinear([], from: 44100, to: 22050), [])
        XCTAssertEqual(Resampler.resampleLinear([], from: 44100, to: 44100), [])
    }

    // 附：单样本上采样验证 hi 钳制（hi = min(lo+1, count−1) = 0，两输出样本都落在源样本 0 上）
    func testSingleSampleUpsample() {
        let output = Resampler.resampleLinear([0.7], from: 22050, to: 44100)
        // outputLength = ceil(1 / 0.5) = 2
        XCTAssertEqual(output, [0.7, 0.7])
    }
}
