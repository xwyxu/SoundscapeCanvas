//
//  VideoExportE2ECheck.swift
//  SoundscapeCanvasTests
//
//  视频导出端到端回归：加载 10s 440Hz 正弦 fixture → 旋律分析 →
//  `VideoExporter.export` → 断言导出 MP4 轨道（视频+音频共 2 轨）、
//  时长（≈10s）、分辨率（=当前设备屏幕物理像素，H.264 偶数对齐后，
//  与产品代码同源计算）、帧率（≈30fps）。
//
//  另用 `AVAssetImageGenerator` 抽取 t=2s / t=8s 两帧 PNG 写入 host app
//  临时目录（`xcrun simctl get_app_container … data` 下 tmp/ 可取回），
//  供人工目检画面方向正确性：时间轴左→右滚动、低音在下、竖线位于
//  屏宽 1/3 处且与音符块交叉处发光。
//
//  运行（单测）：
//  xcodebuild test -only-testing:SoundscapeCanvasTests/VideoExportE2ECheck \
//    -destination 'platform=iOS Simulator,id=<UDID>'
//

import AVFoundation
import UIKit
import XCTest
@testable import SoundscapeCanvas

final class VideoExportE2ECheck: XCTestCase {

    // 实现备注（防止回退）：VideoExporter 的两轨**必须并行推进**。曾验证：串行
    // "先写完视频再写音频"在模拟器上会让视频轨写到 ~82 帧（≈2.7s 媒体）后
    // 耗尽 muxer 交错写入预算，`isReadyForMoreMediaData` 永不恢复（writer 停在
    // writing 态、非 failed），导出永久卡死、产物 0 字节。并行推进时音频编码
    // 速度（≈40x 实时）远快于视频渲染（≈4x 实时），muxer 预算始终被音频数据
    // 填充，全程稳定。本测试即该修复的端到端回归。

    /// 抽帧时刻（秒）：t=2s 音符块尚未滚出左缘；t=8s 块已大部分滚出
    /// （440Hz 音符约 0–10s、120px/s：t=8s 时块左端在屏外，可见段应明显短于 t=2s）
    private static let sampleTimes: [Double] = [2, 8]

    func testVideoExportProducesValidMP4WithTwoTracksAndCorrectFrames() async throws {
        // MARK: 1. 加载 fixture（10s 440Hz 正弦，44100Hz 单声道）
        let fixtureURL = try XCTUnwrap(
            Bundle(for: VideoExportE2ECheck.self)
                .url(forResource: "test-tone-10s", withExtension: "wav"),
            "测试 bundle 中找不到 test-tone-10s.wav"
        )
        let loaded = try AudioLoader.load(url: fixtureURL)
        XCTAssertEqual(loaded.duration, 10.0, accuracy: 0.1)

        // MARK: 2. 旋律分析（440Hz → MIDI 69 / A4 音符，约覆盖 0–10s）
        let melody = try await MelodyAnalysisService.shared.analyze(
            samples: loaded.monoSamples,
            sampleRate: loaded.sampleRate
        )
        XCTAssertTrue(
            melody.notes.contains { $0.midiNote == 69 },
            "440Hz 正弦应解码出 MIDI 69 音符，实际：\(melody.notes.map(\.midiNote))"
        )

        // MARK: 3. 执行导出
        let result = try await VideoExporter.export(audio: loaded, melody: melody)
        // 产物保留在 host app tmp（供测试后取回目检），不做删除清理
        print("[VideoExportE2ECheck] 导出 MP4 → \(result.url.path)")

        // MARK: 4. 产物结构断言
        let asset = AVURLAsset(url: result.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1, "应恰有 1 条视频轨，实际 \(videoTracks.count)")
        XCTAssertEqual(audioTracks.count, 1, "应恰有 1 条音频轨，实际 \(audioTracks.count)")

        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)

        // 分辨率：当前设备屏幕物理像素（nativeBounds，偶数对齐后；
        // 期望值由下方与 VideoExporter 同源实现动态计算，非硬编码）
        let expectedSize = try await Self.expectedExportSize()
        let size = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(size.width, expectedSize.width, accuracy: 0.5,
                       "视频宽 \(size.width)，期望 \(expectedSize.width)")
        XCTAssertEqual(size.height, expectedSize.height, accuracy: 0.5,
                       "视频高 \(size.height)，期望 \(expectedSize.height)")

        // 时长：视频轨 = 300 帧 / 30fps ≈ 10s；音频轨（AAC）与导出器返回值同查
        let videoDuration = try await videoTrack.load(.timeRange).duration.seconds
        XCTAssertEqual(videoDuration, 10.0, accuracy: 0.5, "视频轨时长 \(videoDuration)s")
        let audioDuration = try await audioTrack.load(.timeRange).duration.seconds
        XCTAssertEqual(audioDuration, 10.0, accuracy: 0.5, "音频轨时长 \(audioDuration)s")
        XCTAssertEqual(result.durationSeconds, 10.0, accuracy: 0.5,
                       "导出器返回时长 \(result.durationSeconds)s")

        // 帧率 ≈ 30fps
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        XCTAssertEqual(frameRate, 30.0, accuracy: 5.0, "nominalFrameRate = \(frameRate)")

        // MARK: 5. 抽帧 PNG（目检素材）
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        for time in Self.sampleTimes {
            let (cgImage, actualTime) = try await generator.image(
                at: CMTime(seconds: time, preferredTimescale: 600)
            )
            let pngData = try XCTUnwrap(UIImage(cgImage: cgImage).pngData())
            let outURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(String(format: "export-check-frame-t%ds.png", Int(time)))
            try pngData.write(to: outURL)
            print("[VideoExportE2ECheck] 帧 t=\(time)s（实际 \(actualTime.seconds)s）→ \(outURL.path)")
        }
    }

    // MARK: 期望尺寸（与 VideoExporter.resolveVideoSize 同源实现，勿硬编码）

    /// 期望导出尺寸：当前设备屏幕物理像素（`nativeBounds` 已是物理像素、
    /// 方向固定竖屏 W×H）→ H.264 偶数对齐（奇数就近取偶，四舍五入 0.5 入）。
    /// 与产品代码保持同一套计算逻辑（测试内独立实现，防产品侧悄悄改语义）。
    @MainActor
    private static func expectedExportSize() throws -> CGSize {
        let native = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.nativeBounds
        func alignToEven(_ value: Int) -> Int {
            guard value > 0 else { return 0 }
            return value % 2 == 0 ? value : value + 1
        }
        let width = alignToEven(Int(native?.width ?? 0))
        let height = alignToEven(Int(native?.height ?? 0))
        guard width >= 2, height >= 2 else {
            throw NSError(
                domain: "VideoExportE2ECheck",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "无法解析当前设备屏幕尺寸：\(String(describing: native))"]
            )
        }
        return CGSize(width: width, height: height)
    }
}
