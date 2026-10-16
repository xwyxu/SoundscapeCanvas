//
//  AudioDownloadService.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/19.
//

import Foundation

/// 音频直链下载服务：URLSession downloadTask + delegate 桥接 async，
/// 带进度回调，落盘到 `Documents/Imports/`。
///
/// 隔离说明：标 `nonisolated` 豁免工程默认 MainActor 隔离——下载 IO 与文件
/// 移动均在后台执行；进度回调以 `@MainActor @Sendable` 闭包切回主线程。
/// 支持多任务并发；调用方可通过 `cancelAll()` 取消全部进行中的下载。
nonisolated final class AudioDownloadService: @unchecked Sendable {

    /// 单个下载任务的上下文（fileprivate：delegate 转发入口需按 taskIdentifier 读取）
    fileprivate struct DownloadContext {
        let destinationURL: URL
        let progressHandler: (@MainActor @Sendable (Double) -> Void)?
        var continuation: CheckedContinuation<URL, Error>?
    }

    /// delegate 只作为 session 的转发器，实际状态由 service 统一管理
    nonisolated private final class DelegateBox: NSObject, URLSessionDownloadDelegate {
        let service: AudioDownloadService?

        init(service: AudioDownloadService) {
            self.service = service
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let service, totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let handler = service.context(for: downloadTask)?.progressHandler
            guard let handler else { return }
            Task { @MainActor in handler(min(max(fraction, 0), 1)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            service?.finish(downloadTask: downloadTask, location: location)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let service, let downloadTask = task as? URLSessionDownloadTask else { return }
            service.complete(downloadTask: downloadTask, error: error)
        }
    }

    private let lock = NSLock()
    private var contexts: [Int: DownloadContext] = [:]

    /// 下载目标目录：Documents/Imports/
    private static func importsDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let imports = documents.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        return imports
    }

    /// 下载音频文件。
    ///
    /// - Parameters:
    ///   - url: 音频直链
    ///   - fileName: 目标文件名（含扩展名，如 "晴天-周杰伦.mp3"）；非法字符会被清洗
    ///   - progress: 主线程进度回调（0...1），可为 nil
    /// - Returns: 落盘后的文件 URL（同名冲突自动追加 " (2)" 等序号）
    func download(from url: URL, fileName: String,
                  progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> URL {
        let destination = try Self.resolveDestination(fileName: fileName, sourceURL: url)

        let delegate = DelegateBox(service: self)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                contexts[task.taskIdentifier] = DownloadContext(
                    destinationURL: destination,
                    progressHandler: progress,
                    continuation: continuation
                )
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// 取消全部进行中的下载（半成品由系统临时目录自动清理，不落盘）。
    func cancelAll() {
        lock.lock()
        let pending = contexts.values.compactMap { $0.continuation }
        contexts.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - delegate 回调入口（内部）

    fileprivate func context(for task: URLSessionDownloadTask) -> DownloadContext? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[task.taskIdentifier]
    }

    /// 下载完成：把系统临时文件移动到目标位置并成功续接。
    fileprivate func finish(downloadTask: URLSessionDownloadTask, location: URL) {
        let destination: URL
        do {
            destination = try moveToDestination(location: location, taskIdentifier: downloadTask.taskIdentifier)
        } catch {
            resumeIfPending(taskIdentifier: downloadTask.taskIdentifier, result: .failure(error))
            return
        }
        resumeIfPending(taskIdentifier: downloadTask.taskIdentifier, result: .success(destination))
    }

    /// 任务结束（含失败/取消）：清理上下文，失败时抛出错误。
    fileprivate func complete(downloadTask: URLSessionDownloadTask, error: Error?) {
        guard let error else { return } // 成功路径已由 finish 处理
        let thrown: Error = (error as? URLError)?.code == .cancelled ? CancellationError() : error
        resumeIfPending(taskIdentifier: downloadTask.taskIdentifier, result: .failure(thrown))
    }

    // MARK: - 内部工具

    /// 移动临时文件到目标位置（目标目录已预先建好、文件名已唯一化）。
    private func moveToDestination(location: URL, taskIdentifier: Int) throws -> URL {
        lock.lock()
        let destination = contexts[taskIdentifier]?.destinationURL
        lock.unlock()
        guard let destination else {
            throw CancellationError()
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: location, to: destination)
        return destination
    }

    /// 续接 continuation（仅一次），并清理上下文。
    private func resumeIfPending(taskIdentifier: Int, result: Result<URL, Error>) {
        lock.lock()
        let continuation = contexts[taskIdentifier]?.continuation
        contexts[taskIdentifier] = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// 清洗文件名并解析出唯一的落盘地址（Documents/Imports/<name>）。
    private static func resolveDestination(fileName: String, sourceURL: URL) throws -> URL {
        let cleaned = sanitize(fileName: fileName, sourceURL: sourceURL)
        let directory = try importsDirectory()
        var candidate = directory.appendingPathComponent(cleaned)
        var index = 2
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: candidate.path) {
            let name = cleaned as NSString
            let stem = name.deletingPathExtension
            let ext = name.pathExtension
            let numbered = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            index += 1
        }
        return candidate
    }

    /// 非法字符清洗：`/ \ : ? % * | " < >` 等替换为 "-"；缺失扩展名时从直链补齐。
    private static func sanitize(fileName: String, sourceURL: URL) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var name = fileName
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "audio" }
        let asName = name as NSString
        if asName.pathExtension.isEmpty {
            let ext = sourceURL.pathExtension
            if !ext.isEmpty { name = "\(name).\(ext)" }
        }
        return name
    }
}
