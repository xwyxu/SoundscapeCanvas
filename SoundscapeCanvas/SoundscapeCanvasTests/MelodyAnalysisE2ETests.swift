//
//  MelodyAnalysisE2ETests.swift
//  SoundscapeCanvasTests
//
//  Basic Pitch 推理管线端到端测试（分窗 + CoreML + 拼接 + 音符解码）。
//
//  说明：
//  - 用例 1 使用 mawimbi e2e fixture（test-tone-10s.wav：10s 440 Hz 正弦，
//    44100 Hz Int16 单声道，已复制进本目录作为测试 bundle 资源）；
//  - 用例 2/3 为冒烟测试（静音/噪声），仅要求不崩溃、不抛异常；
//  - CoreML 模型位于 app bundle（测试 host app = SoundscapeCanvas，Bundle.main 可达）；
//  - 推理在模拟器 CPU（cpuOnly）上耗时较长，整组用例可能需要 1-2 分钟，请耐心等待。
//

import AVFoundation
import XCTest
@testable import SoundscapeCanvas

/// 进度回调收集器（回调经后台线程桥接发布，用锁保证安全）
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    var max: Double? {
        lock.lock()
        defer { lock.unlock() }
        return values.max()
    }
}

final class MelodyAnalysisE2ETests: XCTestCase {

    // MARK: - 用例 1：10s 440 Hz 正弦 fixture（端到端）

    /// 440 Hz = MIDI 69（A4）；断言音符存在、时长 ≥ 8s、弯音 |值| < 0.5 半音、置信度 ∈ (0, 1]
    func testAnalyzeTenSecondSineTone() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: MelodyAnalysisE2ETests.self)
                .url(forResource: "test-tone-10s", withExtension: "wav"),
            "测试 bundle 中找不到 test-tone-10s.wav —— 请确认该文件已复制进 SoundscapeCanvasTests 目录"
        )

        let loaded = try AudioLoader.load(url: fixtureURL)
        XCTAssertEqual(loaded.sampleRate, 44100, accuracy: 0.5)
        XCTAssertEqual(loaded.duration, 10.0, accuracy: 0.1)

        let recorder = ProgressRecorder()
        let data = try await MelodyAnalysisService.shared.analyze(
            samples: loaded.monoSamples,
            sampleRate: loaded.sampleRate,
            progress: { recorder.append($0) }
        )

        // 进度回调确实被发布过，且终值不超过 1.0（时序不严格断言，避免并发脆弱性）
        XCTAssertGreaterThan(recorder.count, 0, "分析过程中应发布过进度回调")
        XCTAssertLessThanOrEqual(recorder.max ?? -1, 1.0)

        // 存在 MIDI 69（A4）音符
        let a4Notes = data.notes.filter { $0.midiNote == 69 }
        XCTAssertFalse(
            a4Notes.isEmpty,
            "10s 440 Hz 正弦应解码出 MIDI 69 音符，实际音符：\(data.notes.map(\.midiNote))"
        )

        // 该音符时长 ≥ 8s（音频 10s 的 80%）
        let a4 = try XCTUnwrap(a4Notes.first)
        let duration = a4.endTime - a4.startTime
        XCTAssertGreaterThanOrEqual(duration, 8.0, "A4 音符时长 \(duration)s 应 ≥ 8s")

        // 弯音全部 |值| < 0.5 半音（纯音无弯音；bin 单位下允许 ±1 bin 的模型偏差 = ±1/3 半音）
        let bends = try XCTUnwrap(a4.pitchBends, "纯音音符应带 pitchBends")
        XCTAssertFalse(bends.isEmpty)
        for (index, bend) in bends.enumerated() {
            XCTAssertLessThan(abs(bend), 0.5, "pitchBends[\(index)] = \(bend) 超出 ±0.5 半音")
        }

        // 置信度 ∈ (0, 1]
        XCTAssertGreaterThan(a4.confidence, 0)
        XCTAssertLessThanOrEqual(a4.confidence, 1)

        // 时间分辨率 = 256 / 22050
        XCTAssertEqual(data.timeResolution, 256.0 / 22050.0, accuracy: 1e-12)

        print("[E2E] 正弦用例：\(data.notes.count) 个音符，A4 时长 \(String(format: "%.3f", duration))s")
    }

    // MARK: - 用例 2：静音冒烟

    /// 2 秒全零信号：分析成功、无音符、不崩溃、耗时合理
    func testAnalyzeSilenceSmoke() async throws {
        let sampleRate = 44100.0
        let samples = [Float](repeating: 0, count: Int(sampleRate * 2))

        let start = Date()
        let data = try await MelodyAnalysisService.shared.analyze(
            samples: samples,
            sampleRate: sampleRate
        )
        let elapsed = Date().timeIntervalSince(start)

        // 静音 → frames 全 0 → 阈值解码必然无音符
        XCTAssertTrue(data.notes.isEmpty, "静音不应解码出音符，实际 \(data.notes.count) 个")
        XCTAssertEqual(data.timeResolution, 256.0 / 22050.0, accuracy: 1e-12)
        XCTAssertLessThan(elapsed, 120, "2s 静音分析耗时 \(elapsed)s 过长")
        print("[E2E] 静音用例耗时 \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - 用例 3：噪声冒烟

    /// 2 秒伪随机噪声：只要求不崩溃、不抛异常（解码结果不作断言）
    func testAnalyzeNoiseSmoke() async throws {
        // 简单 LCG 伪随机（可复现），输出 [0, 1]
        var state: UInt64 = 0x5DEECE66D
        let samples: [Float] = (0..<88_200).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let normalized = Double(state >> 11) / Double(UInt64.max >> 11)
            return Float(normalized * 2.0 - 1.0)
        }

        do {
            let data = try await MelodyAnalysisService.shared.analyze(
                samples: samples,
                sampleRate: 44_100
            )
            print("[E2E] 噪声用例：解码出 \(data.notes.count) 个音符（不作断言）")
        } catch is CancellationError {
            XCTFail("噪声分析被意外取消")
        } catch {
            XCTFail("噪声分析不应抛错：\(error)")
        }
    }
}
