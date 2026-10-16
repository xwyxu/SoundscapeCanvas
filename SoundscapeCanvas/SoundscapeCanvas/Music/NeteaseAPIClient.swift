//
//  NeteaseAPIClient.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/10/16.
//

import Foundation

/// 网易云解析接口错误（面向用户的中文描述）。
nonisolated enum NeteaseAPIError: LocalizedError, Equatable {
    /// 请求参数被服务端拒绝（code 400）
    case badRequest
    /// IP 频控（code 429），携带服务端 message
    case rateLimited(String)
    /// 版权限制，无法获取该歌曲
    case copyrightRestricted
    /// 解析失败：可能为 VIP 或已下架
    case unavailable
    /// 网络请求失败（重试后仍失败）
    case transport(String)
    /// 服务返回数据异常（携带服务端 message，可为空）
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .badRequest:
            return "请求参数被服务端拒绝"
        case .rateLimited(let message):
            return "请求过于频繁：\(message)"
        case .copyrightRestricted:
            return "版权限制，无法获取该歌曲"
        case .unavailable:
            return "可能为 VIP 或已下架，无法解析"
        case .transport:
            return "网络请求失败"
        case .invalidResponse(let message):
            return message.isEmpty ? "服务返回数据异常" : "服务返回数据异常（\(message)）"
        }
    }
}

/// 网易云解析（nextmusic.toubiec.cn）API 客户端。
///
/// 隔离说明：本类型为 actor，网络请求均在非主线程执行，
/// 不受工程默认 MainActor 隔离影响；UI 层可从主线程直接 `await` 调用。
///
/// 契约要点（2026-10-16 curl 实测校准）：
/// - 全部端点为 JSON POST，请求体必含 `timestamp`（毫秒）与 `ip`，缺一即 400；
/// - `ip` 经 `/api/ip` 获取后进程内缓存复用，获取失败则降级为不带 ip 发送；
/// - 业务语义以响应信封 `code` 判定：400=非法参数、429=频控、其余非 200=数据异常。
actor NeteaseAPIClient {

    static let shared = NeteaseAPIClient()

    /// 服务基址
    private static let baseURLString = "https://nextmusic.toubiec.cn"

    private static var baseURL: URL? { URL(string: baseURLString) }

    /// 单请求超时（秒）
    private static let timeout: TimeInterval = 20
    /// 传输层故障重试上限（不含首次请求，即最多 1+2 次）
    private static let maxRetries = 2
    /// 重试退避基数（秒）：第 1 次重试等 0.5s，第 2 次等 1s
    private static let retryBaseDelay: TimeInterval = 0.5

    /// 客户端公网 IP 缓存（仅缓存成功结果；失败不缓存，下次请求重新尝试）
    private var cachedIP: String?

    // MARK: - 公开 API

    /// 关键词搜索，返回结果列表。
    func search(keyword: String, limit: Int = 30) async throws -> [NeteaseSong] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await fetch(
            NeteaseSearchData.self,
            path: "/api/search",
            body: ["keyword": trimmed, "type": 1, "limit": limit, "offset": 0]
        )
        return (data.songs ?? []).map { $0.toSong() }
    }

    /// 查询歌曲详情；版权限制（copyright==0）抛 `.copyrightRestricted`。
    func songInfo(id: Int) async throws -> NeteaseSong {
        let raw = try await fetch(
            NeteaseRawSong.self,
            path: "/api/getSongInfo",
            body: ["id": id]
        )
        let song = raw.toSong()
        guard song.copyright != 0 else {
            throw NeteaseAPIError.copyrightRestricted
        }
        return song
    }

    /// 按歌曲 id 与音质档位解析音频直链；url 为 nil/空串抛 `.unavailable`。
    func songURL(id: Int, quality: NeteaseQuality) async throws -> NeteaseResolvedSong {
        let data = try await fetch(
            NeteaseSongURLData.self,
            path: "/api/getSongUrl",
            body: ["id": id, "level": quality.rawValue]
        )
        guard let urlString = data.url, !urlString.isEmpty, let url = URL(string: urlString) else {
            throw NeteaseAPIError.unavailable
        }
        // 服务端返回的 level 原始值映射中文名；未知/缺失回退到请求档位名
        let levelName: String
        if let rawLevel = data.level, let mapped = NeteaseQuality(rawValue: rawLevel) {
            levelName = mapped.displayName
        } else {
            levelName = quality.displayName
        }
        // 服务端不返回文件类型，从直链扩展名推断（无扩展名兜底 mp3）
        let fileExtension = url.pathExtension.lowercased()
        return NeteaseResolvedSong(
            url: url,
            bitrate: data.br ?? 0,
            sizeBytes: data.size ?? 0,
            levelName: levelName,
            fileType: fileExtension.isEmpty ? "mp3" : fileExtension
        )
    }

    /// 解析歌单，返回信息页头与全部曲目。
    func playlistTracks(id: Int) async throws -> (info: NeteasePlaylistInfo, songs: [NeteaseSong]) {
        let data = try await fetch(
            NeteasePlaylistData.self,
            path: "/api/playlist_trackall",
            body: ["id": id]
        )
        return (data.toInfo(), (data.songs ?? []).map { $0.toSong() })
    }

    /// 解析专辑，返回信息页头与全部曲目。
    func albumInfo(id: Int) async throws -> (info: NeteaseAlbumInfo, songs: [NeteaseSong]) {
        let data = try await fetch(
            NeteaseAlbumData.self,
            path: "/api/getAlbum",
            body: ["id": id]
        )
        return (data.toInfo(), (data.songs ?? []).map { $0.toSong() })
    }

    // MARK: - 内部：请求组装与信封解包

    /// 发送业务请求并解包：注入 timestamp/ip → POST → 解码信封 → 判定 code → 返回业务数据。
    private func fetch<T: Decodable>(_ type: T.Type, path: String, body: [String: Any]) async throws -> T {
        var payload = body
        // timestamp 必带（毫秒），缺失即被服务端 400 拒绝
        payload["timestamp"] = Self.timestampMillis()
        // ip 获取失败时降级为不带 ip 发送一次，不影响主流程
        if let ip = await fetchIP() {
            payload["ip"] = ip
        }
        let data = try await sendJSON(path: path, payload: payload)
        let envelope = try Self.decode(NeteaseEnvelope<T>.self, from: data)
        try Self.checkEnvelope(envelope)
        guard let value = envelope.data else {
            // code 200 但缺业务数据，同样视为响应异常
            throw NeteaseAPIError.invalidResponse("")
        }
        return value
    }

    /// 获取并缓存客户端公网 IP；整体容错（失败返回 nil，不抛错、不缓存失败）。
    private func fetchIP() async -> String? {
        if let cachedIP { return cachedIP }
        // /api/ip 请求体仅需 timestamp；失败不影响主流程
        guard let data = try? await sendJSON(path: "/api/ip", payload: ["timestamp": Self.timestampMillis()]),
              let envelope = try? Self.decode(NeteaseEnvelope<NeteaseIPData>.self, from: data),
              let ip = envelope.data?.ip, !ip.isEmpty else {
            return nil
        }
        cachedIP = ip
        return ip
    }

    /// 发送 JSON POST（不注入公共字段，供 /api/ip 复用）。
    private func sendJSON(path: String, payload: [String: Any]) async throws -> Data {
        guard let base = Self.baseURL, let requestURL = URL(string: path, relativeTo: base) else {
            throw NeteaseAPIError.invalidResponse("")
        }
        var request = URLRequest(url: requestURL, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            // payload 恒为 String/Int 字典，此分支实际不可达；防御性归为参数错误
            throw NeteaseAPIError.badRequest
        }
        request.httpBody = body
        return try await send(request)
    }

    /// 统一请求入口：连接重置/超时/断网按 0.5s、1s 退避重试最多 2 次，仍失败抛 `.transport`。
    private func send(_ request: URLRequest) async throws -> Data {
        var lastError: Error?
        for attempt in 0...Self.maxRetries {
            if attempt > 0 {
                // 退避等待 0.5s / 1s；任务被取消时 sleep 抛 CancellationError 直接中断
                try await Task.sleep(nanoseconds: UInt64(Self.retryBaseDelay * Double(attempt) * 1_000_000_000))
            }
            do {
                // 统一走 URLSession.shared；单请求超时由 URLRequest.timeoutInterval 控制
                let (data, _) = try await URLSession.shared.data(for: request)
                return data
            } catch {
                // 用户主动取消不重试、不改写错误类型（UI 层按 CancellationError 收敛）
                if (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                guard Self.isRetryableTransport(error) else {
                    throw NeteaseAPIError.transport(error.localizedDescription)
                }
                lastError = error
            }
        }
        throw NeteaseAPIError.transport(lastError?.localizedDescription ?? "未知网络错误")
    }

    // MARK: - 内部：纯函数

    /// 当前毫秒级时间戳（每个请求体必带）。
    private nonisolated static func timestampMillis() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    /// 信封判定：code==200 通过；400→badRequest；429→rateLimited；其余→invalidResponse。
    private nonisolated static func checkEnvelope<T>(_ envelope: NeteaseEnvelope<T>) throws {
        switch envelope.code {
        case 200:
            return
        case 400:
            throw NeteaseAPIError.badRequest
        case 429:
            throw NeteaseAPIError.rateLimited(envelope.message ?? "请稍后重试")
        default:
            throw NeteaseAPIError.invalidResponse(envelope.message ?? "")
        }
    }

    /// 可重试的传输层错误：连接重置 / 超时 / 网络断开（其余错误直接失败）。
    private nonisolated static func isRetryableTransport(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// JSON 解码（失败归为响应异常）。
    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NeteaseAPIError.invalidResponse("")
        }
    }
}
