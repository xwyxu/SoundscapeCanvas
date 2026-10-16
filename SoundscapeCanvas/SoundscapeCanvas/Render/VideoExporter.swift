//
//  VideoExporter.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/18.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import SwiftUI
import UIKit

// MARK: - 结果与错误

/// 一次成功视频导出的产物
nonisolated struct VideoExportResult: Sendable {
    /// 导出的 MP4 文件地址（位于临时目录，供分享面板使用）
    let url: URL
    /// 视频时长（秒）＝ 总帧数 / 帧率
    let durationSeconds: TimeInterval
}

/// 导出错误（模型无关，面向用户的中文描述）
nonisolated enum VideoExportError: LocalizedError {
    /// 视频轨写入失败（附具体原因，可能为空）
    case videoWriteFailed(String)
    /// 音频轨写入失败（附具体原因，可能为空）
    case audioWriteFailed(String)
    /// 用户取消导出
    case cancelled

    var errorDescription: String? {
        switch self {
        case .videoWriteFailed(let reason):
            return reason.isEmpty ? "视频写入失败" : "视频写入失败：\(reason)"
        case .audioWriteFailed(let reason):
            return reason.isEmpty ? "音频轨写入失败" : "音频轨写入失败：\(reason)"
        case .cancelled:
            return "导出已取消"
        }
    }
}

// MARK: - 离屏视频渲染引擎

/// 离屏视频渲染引擎：`AVAssetWriter` 逐帧渲染钢琴块画布
/// （尺寸＝当前设备屏幕物理像素、竖屏、30fps、H.264 MP4）+ 同步音频轨（AAC），
/// 输出到临时目录。
///
/// 渲染调度：离线时钟推进（t = 帧号/30，非实时，可快于/慢于实时播放）；
/// 画面与 App 内画布共用 `PianoRollRenderer.drawPianoRoll`（同源无漂移）；
/// 固定竖线由本引擎每帧补绘（Renderer 刻意不画竖线，与 App 内
/// `PlayheadOverlay` 覆盖层解耦的行为一致）。
///
/// 线程与隔离：整型 nonisolated（豁免工程默认 MainActor 隔离），导出全程在
/// 后台协作线程执行（帧渲染、编码等待均不占主线程）；进度回调 hop @MainActor。
/// 取消：协作式，逐帧/逐音频块检查 `Task.isCancelled`，取消后清理半成品。
nonisolated enum VideoExporter {

    // MARK: 规格常量
    // 视频宽高不再固定：导出入口在 MainActor 上经 `resolveVideoSize()` 运行时
    // 解析当前设备屏幕物理像素（H.264 偶数对齐），全程动态传递。

    /// 帧率（fps）
    private static let fps: CMTimeScale = 30
    /// 每秒像素（与 App 内 `PianoRollCanvasView.pixelsPerSecond` 一致，画面同源）
    private static let pixelsPerSecond: CGFloat = 120
    /// 视频阶段进度区间 0…0.85（剩余 0.15 留给音频轨阶段）
    private static let videoProgressSpan = 0.85
    /// 视频阶段每多少帧发布一次进度（15 帧 = 0.5s 视频时间）
    private static let videoProgressStride = 15
    /// 音频阶段每多少个样本缓冲发布一次进度
    private static let audioProgressStride = 50
    /// 复用的设备 RGB 色彩空间（位图上下文逐帧绑定）
    private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: - 公开入口

    /// 导出完整旋律视频：视频轨（钢琴块逐帧渲染）+ 音频轨（原音频 AAC）。
    ///
    /// - Parameters:
    ///   - audio: 已解码音频（playbackBuffer 提供音轨数据，时长决定视频长度）
    ///   - melody: 旋律分析结果（提供画面音符）
    ///   - progress: 进度回调（0…1，主线程发布；视频阶段 0–0.85，音频阶段 0.85–1.0）
    /// - Returns: 导出文件地址与时长
    /// - Throws: `VideoExportError`（含取消）；失败/取消时半成品文件已清理，
    ///   成功路径不删除产物。
    static func export(
        audio: LoadedAudio,
        melody: MelodyData,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> VideoExportResult {
        let duration = audio.duration
        guard duration > 0, audio.playbackBuffer.frameLength > 0 else {
            throw VideoExportError.videoWriteFailed("音频内容为空")
        }

        // 导出入口先在 MainActor 上一次性解析视频帧尺寸（当前设备屏幕物理像素、
        // 偶数对齐）；此后后台渲染循环全程使用该值，不再触碰主线程
        let videoSize = try await MainActor.run { try Self.resolveVideoSize() }

        let outputURL = Self.makeOutputURL(songName: audio.fileName)
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            do {
                // 两条轨道的输入必须在 startWriting 之前全部挂载
                let videoInputs = try makeVideoTrackInputs(writer: writer, videoSize: videoSize)
                let audioInput = try makeAudioTrackInput(
                    writer: writer,
                    sourceFormat: audio.playbackBuffer.format
                )

                guard writer.startWriting() else {
                    throw VideoExportError.videoWriteFailed(
                        writer.error?.localizedDescription ?? "无法启动视频写入器"
                    )
                }
                // 时间轴从 0 开始：视频 PTS 自 0 逐帧推进，音频 PTS 同轴对齐
                writer.startSession(atSourceTime: .zero)

                // 两轨并行推进（各自背压独立，muxer 按预算交错落盘）：
                // 串行"先写完视频再写音频"在模拟器（iOS 26）上会让视频轨写到
                // ~82 帧（≈2.7s 媒体）后耗尽 muxer 写入预算 —— 音频轨零数据期间
                // `isReadyForMoreMediaData` 永不恢复且 writer 停在 writing 态（非
                // failed），导出永久卡死（探针 H 复现，E2E 两次卡死均源于此）。
                let totalFrames: Int
                do {
                    async let videoFrames = renderVideoTrack(
                        writer: writer,
                        videoInput: videoInputs.input,
                        adaptor: videoInputs.adaptor,
                        videoSize: videoSize,
                        duration: duration,
                        melody: melody,
                        progress: progress
                    )
                    try await writeAudioTrack(
                        writer: writer,
                        audioInput: audioInput,
                        audio: audio,
                        totalDuration: duration,
                        progress: progress
                    )
                    totalFrames = try await videoFrames
                }
                try await finishWriting(writer)
                return VideoExportResult(
                    url: outputURL,
                    durationSeconds: Double(totalFrames) / Double(fps)
                )
            } catch {
                // 失败/取消：停掉编码器并删除半成品（成功路径不走此处，产物保留）
                cleanup(writer: writer, outputURL: outputURL)
                throw error
            }
        } catch let exportError as VideoExportError {
            throw exportError
        } catch {
            // 写入器创建等底层错误 → 包装为面向用户的导出错误
            throw VideoExportError.videoWriteFailed(error.localizedDescription)
        }
    }

    // MARK: - 导出尺寸解析

    /// 解析导出视频帧尺寸：当前设备屏幕物理像素（`nativeBounds` 已是物理像素、
    /// 方向固定竖屏 W×H，与界面显示区域逐像素一致），再做 H.264 偶数对齐。
    /// 须在 MainActor 上调用（读取 `UIWindowScene.screen`）。
    @MainActor
    private static func resolveVideoSize() throws -> CGSize {
        let native = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.nativeBounds
        let width = alignToEven(Int(native?.width ?? 0))
        let height = alignToEven(Int(native?.height ?? 0))
        guard width >= 2, height >= 2 else {
            throw VideoExportError.videoWriteFailed("无法获取当前设备屏幕尺寸")
        }
        return CGSize(width: width, height: height)
    }

    /// H.264 编码要求宽高为偶数：奇数就近取偶（四舍五入语义：x.5 向上入，
    /// 故正值奇数恒 +1）。偏差声明：奇数边至多偏差 1px（≤0.1% 边长，
    /// spec 明确许可的唯一偏差）；对 0/负值返回 0，由调用方判无效兜底。
    private static func alignToEven(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        return value % 2 == 0 ? value : value + 1
    }

    // MARK: - 轨道输入（须在 startWriting 之前挂载）

    /// 构建并挂载视频轨输入 + 像素缓冲适配器（缓冲池按传入动态尺寸创建）
    private static func makeVideoTrackInputs(
        writer: AVAssetWriter,
        videoSize: CGSize
    ) throws -> (input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)
        // 码率随分辨率自适应：≈0.1 bit/像素/帧（宽×高×帧率×0.1），
        // 如 1206×2622@30fps ≈ 9.5 Mbps；下限 8 Mbps 兜底小尺寸画质
        let bitrate = max(8_000_000, Int(Double(width * height) * Double(fps) * 0.1))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw VideoExportError.videoWriteFailed("无法挂载视频输入")
        }
        writer.add(videoInput)
        return (videoInput, adaptor)
    }

    /// 构建并挂载音频轨输入：AAC，采样率/声道与源缓冲格式一致
    private static func makeAudioTrackInput(
        writer: AVAssetWriter,
        sourceFormat: AVAudioFormat
    ) throws -> AVAssetWriterInput {
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sourceFormat.sampleRate,
            AVNumberOfChannelsKey: Int(sourceFormat.channelCount),
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw VideoExportError.audioWriteFailed("无法挂载音频输入")
        }
        writer.add(audioInput)
        return audioInput
    }

    // MARK: - 视频轨

    /// 逐帧渲染钢琴块画面写入视频轨。返回总帧数。
    private static func renderVideoTrack(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoSize: CGSize,
        duration: TimeInterval,
        melody: MelodyData,
        progress: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> Int {
        let totalFrames = Int(ceil(duration * Double(fps)))
        for frameIndex in 0..<totalFrames {
            try checkCancelled()
            // 背压：编码器未就绪时让出协作线程（写入器失败则立即报错，避免空转）
            while !videoInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw VideoExportError.videoWriteFailed(
                        writer.error?.localizedDescription ?? "视频写入器已失败"
                    )
                }
                try checkCancelled()
                await Task.yield()
            }

            // 离线时钟：t = 帧号 / 帧率
            let currentTime = Double(frameIndex) / Double(fps)
            guard let pixelBuffer = makePixelBuffer(adaptor: adaptor, videoSize: videoSize) else {
                throw VideoExportError.videoWriteFailed("无法分配像素缓冲")
            }
            try renderFrame(pixelBuffer: pixelBuffer, melody: melody, currentTime: currentTime)
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw VideoExportError.videoWriteFailed(
                    writer.error?.localizedDescription ?? "视频帧写入被拒绝"
                )
            }

            if frameIndex % videoProgressStride == 0 {
                await report(progress, Double(frameIndex) / Double(totalFrames) * videoProgressSpan)
            }
        }
        videoInput.markAsFinished()
        return totalFrames
    }

    /// 取一帧像素缓冲：优先复用适配器缓冲池（池按 adaptor 的
    /// sourcePixelBufferAttributes 创建，即当前动态尺寸），池不可用时按同规格新建
    private static func makePixelBuffer(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoSize: CGSize
    ) -> CVPixelBuffer? {
        if let pool = adaptor.pixelBufferPool {
            var pooled: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooled)
            if status == kCVReturnSuccess, let pooled {
                return pooled
            }
        }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(videoSize.width),
            Int(videoSize.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    /// 渲染单帧到像素缓冲：黑底钢琴块（同源绘制函数）+ 固定竖线（1/3 处白色发光线）
    private static func renderFrame(
        pixelBuffer: CVPixelBuffer,
        melody: MelodyData,
        currentTime: TimeInterval
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoExportError.videoWriteFailed("无法锁定像素缓冲内存")
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)

        // BGRA（小端、预乘 Alpha）位图上下文，直接绑定缓冲内存（零拷贝）
        guard let cgContext = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw VideoExportError.videoWriteFailed("无法创建位图绘制上下文")
        }

        // 关键坐标说明（方向正确性由 VideoExportE2ECheck 帧目检把关）：
        // - CVPixelBuffer 内存为自上而下（第 0 行 = 视频图像顶部）；
        // - CG 位图上下文为自下而上（逻辑 y=0 = 内存最后一行）；
        // - `drawPianoRoll(to: CGContext)` 内部会做一次"左下原点 → 左上原点"翻转，
        //   该翻转使绘制逻辑 y 直接等于内存行号：Renderer 的左上原点 y（块顶）
        //   落到视频同名行，画面为高音在上、低音在下、时间轴从左至右
        //   （与 App 内画布一致）。此处**不可**再叠加翻转——双重翻转相互抵消
        //   会回到左下原点语义，音符块被垂直镜像（MIDI 69 画到下半区）。
        // 同源绘制（左上原点语义，与 SwiftUI 一致）
        PianoRollRenderer.drawPianoRoll(
            to: cgContext,
            size: size,
            melody: melody,
            currentTime: currentTime,
            pixelsPerSecond: pixelsPerSecond
        )

        // 固定竖线（对齐 PlayheadOverlay）：宽 1/3 处、白色 1.5pt、白 0.6 模糊 4 发光，
        // 画在与 Renderer 相同的左上原点坐标系内（全高线段，垂直方向天然对称）
        let playheadX = size.width / 3
        cgContext.setShadow(offset: .zero, blur: 4, color: CGColor(gray: 1, alpha: 0.6))
        cgContext.setStrokeColor(CGColor(gray: 1, alpha: 1))
        cgContext.setLineWidth(1.5)
        cgContext.move(to: CGPoint(x: playheadX, y: 0))
        cgContext.addLine(to: CGPoint(x: playheadX, y: size.height))
        cgContext.strokePath()
        cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    }

    // MARK: - 音频轨

    /// 写入同步音频轨：playbackBuffer → 临时 CAF（PCM）→ AVAssetReader 逐块读
    /// interleaved Float32 PCM → 交给写入器编码 AAC。
    ///
    /// 路径说明：`AVAudioPCMBuffer` 无法直接 append 给 `AVAssetWriter`，而手工构造
    /// CMBlockBuffer/CMSampleBuffer（ASBD/格式描述/时间戳）繁琐易错；经临时文件 +
    /// AVAssetReader 的成熟管线由系统保证格式描述与 PTS 正确（自 0 连续推进，
    /// 与视频时间轴对齐）。临时 CAF 用后即删。
    private static func writeAudioTrack(
        writer: AVAssetWriter,
        audioInput: AVAssetWriterInput,
        audio: LoadedAudio,
        totalDuration: TimeInterval,
        progress: (@MainActor @Sendable (Double) -> Void)?
    ) async throws {
        let sourceFormat = audio.playbackBuffer.format

        // 1. playbackBuffer → 临时 CAF（Float32 PCM；作用域结束即落盘 flush）
        let cafURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-export-audio-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: cafURL) }

        do {
            let file = try AVAudioFile(
                forWriting: cafURL,
                settings: sourceFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: audio.playbackBuffer)
        }

        // 2. 读临时音频：interleaved Float32 PCM（AAC 编码器可直收，系统负责转码）
        let asset = AVURLAsset(url: cafURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw VideoExportError.audioWriteFailed("临时音频缺少音轨")
        }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(readerOutput) else {
            throw VideoExportError.audioWriteFailed("无法挂载音频读取输出")
        }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw VideoExportError.audioWriteFailed(
                reader.error?.localizedDescription ?? "无法启动音频读取"
            )
        }

        // 3. 逐块 append（背压 + 取消检查；进度按样本 PTS / 总时长推进）
        var appended = 0
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try checkCancelled()
            while !audioInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw VideoExportError.audioWriteFailed(
                        writer.error?.localizedDescription ?? "音频写入器已失败"
                    )
                }
                try checkCancelled()
                await Task.yield()
            }
            guard audioInput.append(sampleBuffer) else {
                throw VideoExportError.audioWriteFailed(
                    writer.error?.localizedDescription ?? "音频样本写入被拒绝"
                )
            }
            appended += 1
            if appended % audioProgressStride == 0 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let fraction = totalDuration > 0 ? min(0.999, max(0, pts / totalDuration)) : 0.999
                await report(progress, videoProgressSpan + fraction * (1 - videoProgressSpan))
            }
        }
        if reader.status == .failed {
            throw VideoExportError.audioWriteFailed(
                reader.error?.localizedDescription ?? "音频读取失败"
            )
        }
        audioInput.markAsFinished()
    }

    // MARK: - 收尾与辅助

    /// 等待写入器完成编码落盘，并按最终状态映射错误
    private static func finishWriting(_ writer: AVAssetWriter) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        switch writer.status {
        case .completed:
            return
        case .cancelled:
            throw VideoExportError.cancelled
        default:
            throw VideoExportError.videoWriteFailed(
                writer.error?.localizedDescription ?? "视频写入未能完成"
            )
        }
    }

    /// 失败/取消清理：取消写入器（停止编码）并静默删除半成品文件；成功路径不调用
    private static func cleanup(writer: AVAssetWriter, outputURL: URL) {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// 取消检查：协作式取消统一抛导出取消错误
    private static func checkCancelled() throws {
        if Task.isCancelled {
            throw VideoExportError.cancelled
        }
    }

    /// 进度回调 hop 主线程发布（clamp 到 0…1）
    private static func report(
        _ progress: (@MainActor @Sendable (Double) -> Void)?,
        _ value: Double
    ) async {
        guard let progress else { return }
        await MainActor.run { progress(min(1, max(0, value))) }
    }

    /// 输出文件：`<歌曲名(去非法字符)>-旋律视频-<时间戳>.mp4`（文件名含歌曲名，spec 要求）
    private static func makeOutputURL(songName fileName: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        let name = "\(sanitizedSongName(fileName))-旋律视频-\(stamp).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// 歌曲名清洗：去扩展名，非法路径字符与空白折叠为连字符，空结果回退"旋律"
    private static func sanitizedSongName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"'<>:")
            .union(.whitespacesAndNewlines)
        let cleaned = base.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "旋律" : trimmed
    }
}
