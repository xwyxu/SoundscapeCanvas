//
//  NeteaseModelsTests.swift
//  SoundscapeCanvasTests
//
//  NeteaseModels 响应信封与容错解码单元测试：
//  用 JSON 字符串构造原始响应（含 2026-10-16 实测 golden 样例）验证解码容错行为。
//

import XCTest
@testable import SoundscapeCanvas

final class NeteaseModelsTests: XCTestCase {

    // MARK: - 辅助

    /// 从 JSON 字符串解码（默认 JSONDecoder，与线上解码路径一致）
    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - 响应信封

    /// data 为 null 时信封可解码，data 为 nil，code/message 正常读取
    func testEnvelopeWithNullData() throws {
        let envelope = try decode(
            NeteaseEnvelope<NeteaseSearchData>.self,
            from: #"{"code":200,"message":"ok","data":null}"#
        )
        XCTAssertEqual(envelope.code, 200)
        XCTAssertEqual(envelope.message, "ok")
        XCTAssertNil(envelope.data)
    }

    /// data 字段整体缺省时同样解码为 nil（不抛错）
    func testEnvelopeWithoutDataKey() throws {
        let envelope = try decode(
            NeteaseEnvelope<NeteaseSearchData>.self,
            from: #"{"code":200}"#
        )
        XCTAssertEqual(envelope.code, 200)
        XCTAssertNil(envelope.data)
    }

    // MARK: - /api/search golden 样例（2026-10-16 实测响应）

    /// 实测搜索响应：全字段齐备，验证逐字段映射与封面 http→https 归一化
    func testSearchGoldenSampleDecoding() throws {
        let envelope = try decode(
            NeteaseEnvelope<NeteaseSearchData>.self,
            from: """
            {"code":200,"message":"ok","data":{"songs":[{"id":2652820720,"name":"晴天(深情版)","free":true,"album":"晴天(深情版)","singer":"Lucky小爱","picimg":"http://p2.music.126.net/F0fTkmBTVykCa2o7Vgu1rQ==/109951173569626660.jpg","duration":"4:39","copyright":1}],"songCount":337}}
            """
        )
        let songs = try XCTUnwrap(envelope.data?.songs, "golden 样例应含 1 条歌曲")
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(envelope.data?.songCount, 337)

        let song = songs[0].toSong()
        XCTAssertEqual(song.id, 2652820720)
        XCTAssertEqual(song.name, "晴天(深情版)")
        XCTAssertEqual(song.singer, "Lucky小爱")
        XCTAssertEqual(song.album, "晴天(深情版)")
        XCTAssertEqual(song.durationText, "4:39")
        XCTAssertEqual(song.isFree, true)
        XCTAssertEqual(song.copyright, 1)
        XCTAssertEqual(
            song.coverImgUrl?.absoluteString,
            "https://p2.music.126.net/F0fTkmBTVykCa2o7Vgu1rQ==/109951173569626660.jpg"
        )
    }

    // MARK: - 歌曲条目字段缺省容错

    /// 仅含 id 的极简条目：文本缺失补空串、free 缺省 true、copyright 缺省 1、封面为 nil
    func testRawSongMissingOptionalFieldsDefaults() throws {
        let raw = try decode(NeteaseRawSong.self, from: #"{"id":42}"#)
        let song = raw.toSong()
        XCTAssertEqual(song.id, 42)
        XCTAssertEqual(song.name, "")
        XCTAssertEqual(song.singer, "")
        XCTAssertEqual(song.album, "")
        XCTAssertEqual(song.durationText, nil)
        XCTAssertEqual(song.isFree, true, "free 缺省应视为免费")
        XCTAssertEqual(song.copyright, 1, "copyright 缺省应视为有版权")
        XCTAssertNil(song.coverImgUrl, "picimg 缺失时封面应为 nil")
    }

    /// picimg 为 http 时归一化为 https
    func testPicimgHTTPNormalizedToHTTPS() throws {
        let raw = try decode(
            NeteaseRawSong.self,
            from: #"{"id":1,"picimg":"http://p1.music.126.net/abc.jpg"}"#
        )
        XCTAssertEqual(raw.toSong().coverImgUrl?.absoluteString, "https://p1.music.126.net/abc.jpg")
    }

    /// picimg 为非法字符串 / 空串时封面为 nil（不抛错、不强解包）。
    /// 注：新版 Foundation URL 解析器会容忍路径中的空格并自动百分号编码
    /// （如 "not a url" → "not%20a%20url"，不再返回 nil），
    /// 因此非法用例改用必然被拒绝的控制字符（JSON 转义 \n）。
    func testPicimgInvalidStringReturnsNil() throws {
        let illegal = try decode(NeteaseRawSong.self, from: #"{"id":1,"picimg":"ht\ntp://x"}"#)
        XCTAssertNil(illegal.toSong().coverImgUrl, "含换行控制符的地址应判定非法")

        let empty = try decode(NeteaseRawSong.self, from: #"{"id":2,"picimg":""}"#)
        XCTAssertNil(empty.toSong().coverImgUrl)
    }

    // MARK: - 歌单信息：playCount 双类型解码

    /// playCount 为 Int 时归一为字符串
    func testPlayCountAsInt() throws {
        let data = try decode(
            NeteasePlaylistData.self,
            from: #"{"id":1,"name":"歌单","playCount":123456}"#
        )
        XCTAssertEqual(data.toInfo().playCountText, "123456")
    }

    /// playCount 为 String（如 "98.7万"）时原样保留
    func testPlayCountAsString() throws {
        let data = try decode(
            NeteasePlaylistData.self,
            from: #"{"id":1,"name":"歌单","playCount":"98.7万"}"#
        )
        XCTAssertEqual(data.toInfo().playCountText, "98.7万")
    }

    /// playCount 缺省 / 为 null 时 playCountText 为 nil
    func testPlayCountMissingOrNullReturnsNil() throws {
        let missing = try decode(NeteasePlaylistData.self, from: #"{"id":1,"name":"歌单"}"#)
        XCTAssertNil(missing.toInfo().playCountText)

        let null = try decode(NeteasePlaylistData.self, from: #"{"id":1,"name":"歌单","playCount":null}"#)
        XCTAssertNil(null.toInfo().playCountText)
    }

    /// 歌单信息其余缺省字段：名称补空串、songCount 补 0、封面 http→https、创建者可缺省
    func testPlaylistInfoDefaultsAndCoverNormalization() throws {
        let data = try decode(
            NeteasePlaylistData.self,
            from: #"{"id":9,"name":"经典老歌","coverImage":"http://p1.music.126.net/cover.jpg","songCount":10,"creator":{"name":"小明"}}"#
        )
        let info = data.toInfo()
        XCTAssertEqual(info.name, "经典老歌")
        XCTAssertEqual(info.songCount, 10)
        XCTAssertEqual(info.creatorName, "小明")
        XCTAssertEqual(info.coverImageURL?.absoluteString, "https://p1.music.126.net/cover.jpg")

        let minimal = try decode(NeteasePlaylistData.self, from: #"{}"#)
        let minimalInfo = minimal.toInfo()
        XCTAssertEqual(minimalInfo.name, "")
        XCTAssertEqual(minimalInfo.songCount, 0)
        XCTAssertNil(minimalInfo.coverImageURL)
        XCTAssertNil(minimalInfo.creatorName)
    }

    // MARK: - 音质档位

    /// NeteaseQuality 共 9 档，rawValue 与服务端 level 参数一致
    func testQualityAllCasesCount() {
        XCTAssertEqual(NeteaseQuality.allCases.count, 9)
        XCTAssertEqual(
            NeteaseQuality.allCases.map(\.rawValue),
            ["standard", "exhigh", "lossless", "hires", "jyeffect", "sky", "dolby", "vivid", "jymaster"]
        )
    }

    /// 中文档位名抽查
    func testQualityDisplayNames() {
        XCTAssertEqual(NeteaseQuality.standard.displayName, "标准音质")
        XCTAssertEqual(NeteaseQuality.lossless.displayName, "无损音质")
        XCTAssertEqual(NeteaseQuality.dolby.displayName, "杜比全景声")
        XCTAssertEqual(NeteaseQuality.vivid.displayName, "臻音全景声")
        XCTAssertEqual(NeteaseQuality.jymaster.displayName, "超清母带")
    }
}
