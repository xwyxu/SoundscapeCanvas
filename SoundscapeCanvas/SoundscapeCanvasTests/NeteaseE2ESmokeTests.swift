//
//  NeteaseE2ESmokeTests.swift
//  SoundscapeCanvasTests
//
//  网易云解析功能真实网络冒烟测试。
//  ⚠️ 依赖真实外网服务（https://nextmusic.toubiec.cn）：
//  无网络 / 服务端频控（429）/ 歌曲版权限制（VIP 或已下架）都会导致断言失败，
//  此类失败属环境问题而非代码问题，请结合报错文案判断后重试。
//

import XCTest
@testable import SoundscapeCanvas

final class NeteaseE2ESmokeTests: XCTestCase {

    /// 单条解析失败时允许尝试的歌曲条数上限（避免整组测试被频控拖垮）
    private static let maxResolveAttempts = 5

    // MARK: - 测试 1：搜索 → 解析音频直链

    /// search("晴天") 结果非空；对前若干条依次尝试 songURL(standard)，
    /// 直到拿到可播放直链（最多 5 条，全失败视为测试失败并附各条错误）。
    func testSearchAndResolveSongURL() async throws {
        // 第一步：搜索（失败常见原因：断网、服务端不可用、频控 429）
        let songs: [NeteaseSong]
        do {
            songs = try await NeteaseAPIClient.shared.search(keyword: "晴天")
        } catch {
            XCTFail("搜索「晴天」失败：\(error.localizedDescription)。请检查外网连通性（nextmusic.toubiec.cn）；若提示请求过于频繁（429 频控）请稍后重试。")
            return
        }
        XCTAssertFalse(songs.isEmpty, "搜索「晴天」返回空列表：服务端可能异常或被频控（429）")

        // 第二步：逐条尝试解析标准音质直链（单条失败常见原因：版权限制 / VIP / 已下架）
        var attemptErrors: [String] = []
        var resolved: NeteaseResolvedSong?
        for song in songs.prefix(Self.maxResolveAttempts) {
            do {
                resolved = try await NeteaseAPIClient.shared.songURL(id: song.id, quality: .standard)
                break
            } catch {
                attemptErrors.append("id=\(song.id)《\(song.name)》：\(error.localizedDescription)")
            }
        }
        guard let resolved else {
            XCTFail(
                "前 \(min(Self.maxResolveAttempts, songs.count)) 条歌曲均未解析出音频直链"
                + "（可能为版权限制 / VIP 歌曲 / 频控 429 / 网络异常），各条错误：\n"
                + attemptErrors.joined(separator: "\n")
            )
            return
        }

        // 第三步：直链基本契约校验
        XCTAssertTrue(
            resolved.url.absoluteString.hasPrefix("https"),
            "音频直链应以 https 开头，实际：\(resolved.url.absoluteString)"
        )
        XCTAssertGreaterThan(resolved.sizeBytes, 0, "文件大小应大于 0，实际：\(resolved.sizeBytes)")

        // fileType 契约：取直链扩展名小写，无扩展名兜底 "mp3"（逻辑在 NeteaseAPIClient.songURL，需真实响应覆盖）
        let expectedFileType = resolved.url.pathExtension.isEmpty
            ? "mp3"
            : resolved.url.pathExtension.lowercased()
        XCTAssertEqual(
            resolved.fileType, expectedFileType,
            "fileType 应与直链扩展名一致（无扩展名兜底 mp3），实际：\(resolved.fileType)"
        )
    }

    // MARK: - 测试 2：歌单解析

    /// playlistTracks(3778678) → 曲目非空且 songCount > 0
    /// （songCount 与实际条数不必相等：服务端可能只返回部分曲目）
    func testPlaylistTracksSmoke() async throws {
        let (info, songs): (NeteasePlaylistInfo, [NeteaseSong])
        do {
            (info, songs) = try await NeteaseAPIClient.shared.playlistTracks(id: 3778678)
        } catch {
            XCTFail("解析歌单 3778678 失败：\(error.localizedDescription)。请检查外网连通性；若为 429 频控请稍后重试。")
            return
        }
        XCTAssertFalse(songs.isEmpty, "歌单 3778678 曲目列表为空：服务端可能异常或该歌单已失效")
        XCTAssertGreaterThan(info.songCount, 0, "歌单 3778678 的 songCount 应大于 0，实际：\(info.songCount)")
    }

    // MARK: - 测试 3：专辑解析

    /// albumInfo(18918) → 专辑名为 "Jay"（周杰伦同名专辑）且曲目非空
    func testAlbumInfoSmoke() async throws {
        let (info, songs): (NeteaseAlbumInfo, [NeteaseSong])
        do {
            (info, songs) = try await NeteaseAPIClient.shared.albumInfo(id: 18918)
        } catch {
            XCTFail("解析专辑 18918 失败：\(error.localizedDescription)。请检查外网连通性；若为 429 频控请稍后重试。")
            return
        }
        XCTAssertEqual(info.name, "Jay", "专辑 18918 应为周杰伦《Jay》，实际：\(info.name)")
        XCTAssertFalse(songs.isEmpty, "专辑 18918 曲目列表为空：服务端可能异常或该专辑已下架")
    }
}
