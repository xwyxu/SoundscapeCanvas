//
//  NeteaseModels.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/10/16.
//

import Foundation

// MARK: - 业务模型

/// 网易云解析服务（nextmusic.toubiec.cn）返回的歌曲条目。
nonisolated struct NeteaseSong: Identifiable, Sendable, Equatable {
    /// 歌曲在网易云的数字 id
    let id: Int
    /// 歌名
    let name: String
    /// 歌手
    let singer: String
    /// 专辑名（可能缺失）
    let album: String
    /// 封面图地址（原站为 http，仅作展示用途）
    let coverImgUrl: URL?
    /// 时长文案（如 "4:39"）
    let durationText: String?
    /// 是否免费
    let isFree: Bool
    /// 版权标记（0 = 无版权）
    let copyright: Int
}

/// 歌单解析结果的信息页头（曲目列表复用 `NeteaseSong`）。
nonisolated struct NeteasePlaylistInfo: Sendable {
    /// 歌单名
    let name: String
    /// 歌单封面（http → https 归一化）
    let coverImageURL: URL?
    /// 曲目数
    let songCount: Int
    /// 创建者昵称
    let creatorName: String?
    /// 播放量文案（服务端 Int / String 都可能出现，容错解码后归一为字符串）
    let playCountText: String?
}

/// 专辑解析结果的信息页头。
nonisolated struct NeteaseAlbumInfo: Sendable {
    /// 专辑名
    let name: String
    /// 歌手名
    let artistName: String?
    /// 专辑封面（http → https 归一化）
    let coverImageURL: URL?
    /// 发行时间
    let publishTime: String?
    /// 专辑简介
    let songDescription: String?
}

/// `/api/getSongUrl` 解析成功后的音频直链信息。
nonisolated struct NeteaseResolvedSong: Sendable {
    /// 音频直链
    let url: URL
    /// 比特率（kbps）
    let bitrate: Int
    /// 文件大小（字节）
    let sizeBytes: Int
    /// 音质中文名（如 "标准音质"）
    let levelName: String
    /// 文件类型（从直链扩展名推断，如 "mp3"/"flac"，无扩展名兜底 "mp3"）
    let fileType: String
}

/// 音质档位（对应 `/api/getSongUrl` 的 level 参数，共 9 档）。
nonisolated enum NeteaseQuality: String, CaseIterable, Sendable {
    case standard
    case exhigh
    case lossless
    case hires
    case jyeffect
    case sky
    case dolby
    case vivid
    case jymaster

    /// 档位的中文展示名。
    var displayName: String {
        switch self {
        case .standard: return "标准音质"
        case .exhigh: return "极高音质"
        case .lossless: return "无损音质"
        case .hires: return "Hi-Res"
        case .jyeffect: return "高清环绕声"
        case .sky: return "沉浸环绕声"
        case .dolby: return "杜比全景声"
        case .vivid: return "臻音全景声"
        case .jymaster: return "超清母带"
        }
    }
}

// MARK: - 响应信封与原始负载（含容错解码）

/// 通用响应信封：`data` 为业务负载；`message` 仅在出错时用于提示。
nonisolated struct NeteaseEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

/// `/api/ip` 的 data 负载。
nonisolated struct NeteaseIPData: Decodable {
    let ip: String?
}

/// `/api/search` 的 data 负载。
nonisolated struct NeteaseSearchData: Decodable {
    let songs: [NeteaseRawSong]?
    let songCount: Int?
}

/// 搜索/详情/歌单/专辑共用的歌曲原始条目：字段可缺省，经 `toSong()` 容错转换。
nonisolated struct NeteaseRawSong: Decodable {
    let id: Int
    let name: String?
    let singer: String?
    let album: String?
    /// 时长文案（如 "4:39"）
    let duration: String?
    /// 是否免费（缺省视为免费）
    let free: Bool?
    /// 版权标记（缺省视为有版权）
    let copyright: Int?
    /// 封面图地址
    let picimg: String?

    /// 转为对外模型：文本缺失补空串；free 缺省视为免费；copyright 缺省视为 1；
    /// 封面 http 强转 https（仅展示用）。
    func toSong() -> NeteaseSong {
        NeteaseSong(
            id: id,
            name: name ?? "",
            singer: singer ?? "",
            album: album ?? "",
            coverImgUrl: NeteaseDisplayURL.normalize(picimg),
            durationText: duration,
            isFree: free ?? true,
            copyright: copyright ?? 1
        )
    }
}

/// `/api/getSongUrl` 的 data 负载。
nonisolated struct NeteaseSongURLData: Decodable {
    let id: Int?
    /// 音频直链；null 或空串 = VIP / 已下架 / 账号池不可用
    let url: String?
    /// 比特率（kbps）
    let br: Int?
    /// 音质档位原始值（如 "standard"）
    let level: String?
    /// 文件大小（字节）
    let size: Int?
    // md5 / channelLayout / cookie 等字段本期不使用，忽略
}

/// `/api/playlist_trackall` 的 data 负载。
nonisolated struct NeteasePlaylistData: Decodable {
    let id: Int?
    let name: String?
    let coverImage: String?
    let songCount: Int?
    /// 播放量（Int / String 都可能出现，容错解码）
    let playCount: NeteasePlayCount?
    // description / tags 等字段本期不使用，忽略
    let creator: Creator?
    let songs: [NeteaseRawSong]?

    /// 歌单创建者
    struct Creator: Decodable {
        let name: String?
    }

    /// 转为对外模型：名称缺失补空串；数值缺失补 0；封面 http 强转 https（仅展示用）。
    func toInfo() -> NeteasePlaylistInfo {
        NeteasePlaylistInfo(
            name: name ?? "",
            coverImageURL: NeteaseDisplayURL.normalize(coverImage),
            songCount: songCount ?? 0,
            creatorName: creator?.name,
            playCountText: playCount?.text
        )
    }
}

/// `/api/getAlbum` 的 data 负载。
nonisolated struct NeteaseAlbumData: Decodable {
    let id: Int?
    let name: String?
    let picUrl: String?
    let publishTime: String?
    let artist: Artist?
    let description: String?
    let songs: [NeteaseRawSong]?

    /// 专辑歌手
    struct Artist: Decodable {
        let id: Int?
        let name: String?
    }

    /// 转为对外模型：名称缺失补空串；封面 http 强转 https（仅展示用）。
    func toInfo() -> NeteaseAlbumInfo {
        NeteaseAlbumInfo(
            name: name ?? "",
            artistName: artist?.name,
            coverImageURL: NeteaseDisplayURL.normalize(picUrl),
            publishTime: publishTime,
            songDescription: description
        )
    }
}

/// 播放量容错解码：服务端可能返回 Int 或 String。
nonisolated struct NeteasePlayCount: Decodable, Sendable {
    /// 归一化后的展示文案；两种类型都无法解析时为 nil
    let text: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let count = try? container.decode(Int.self) {
            text = String(count)
        } else if let string = try? container.decode(String.self) {
            text = string.isEmpty ? nil : string
        } else {
            text = nil
        }
    }
}

/// 展示用图片地址归一化：http → https；空串或非法字符串返回 nil。
private nonisolated enum NeteaseDisplayURL {
    static func normalize(_ raw: String?) -> URL? {
        guard var string = raw, !string.isEmpty else { return nil }
        if string.hasPrefix("http://") {
            string = "https://" + string.dropFirst("http://".count)
        }
        return URL(string: string)
    }
}
