//
//  NeteaseLinkParserTests.swift
//  SoundscapeCanvasTests
//
//  NeteaseLinkParser 输入解析单元测试：网易云链接（song/playlist/album）、
//  纯数字歌曲 ID、搜索关键词三类分类，以及伪装 host 安全负例。
//

import XCTest
@testable import SoundscapeCanvas

final class NeteaseLinkParserTests: XCTestCase {

    // MARK: - 基础链接分类

    /// 标准歌曲链接 → .song(id)
    func testSongLink() {
        XCTAssertEqual(NeteaseLinkParser.parse("https://music.163.com/song?id=186016"), .song(186016))
    }

    /// 标准歌单链接 → .playlist(id)
    func testPlaylistLink() {
        XCTAssertEqual(NeteaseLinkParser.parse("https://music.163.com/playlist?id=3778678"), .playlist(3778678))
    }

    /// 标准专辑链接 → .album(id)
    func testAlbumLink() {
        XCTAssertEqual(NeteaseLinkParser.parse("https://music.163.com/album?id=18918"), .album(18918))
    }

    /// 带多余查询参数（&from=friend）不影响 id 提取
    func testLinkWithExtraQuery() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("https://music.163.com/song?id=186016&from=friend"),
            .song(186016)
        )
    }

    /// http 协议（非 https）同样识别
    func testHTTPLink() {
        XCTAssertEqual(NeteaseLinkParser.parse("http://music.163.com/song?id=186016"), .song(186016))
    }

    /// host 大写不敏感
    func testUppercaseHost() {
        XCTAssertEqual(NeteaseLinkParser.parse("https://MUSIC.163.COM/song?id=186016"), .song(186016))
    }

    /// 子域（y.music.163.com）识别，如移动端分享链接
    func testSubdomainHost() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("https://y.music.163.com/m/song?id=186016"),
            .song(186016)
        )
    }

    /// 无 scheme 的裸链接同样识别
    func testNoSchemeLink() {
        XCTAssertEqual(NeteaseLinkParser.parse("music.163.com/playlist?id=3778678"), .playlist(3778678))
    }

    /// 老版 SPA 路由：类型与 id 藏在 `#` 片段中
    func testSPAFragmentRoute() {
        XCTAssertEqual(NeteaseLinkParser.parse("http://Music.163.com/#/album?id=18918"), .album(18918))
    }

    /// 分享文案夹带链接（中文 + 空格导致 URL 解码失败，走字符串兜底）
    func testShareTextWithTrailingContent() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("分享《晴天》 https://music.163.com/song?id=186016 (来自@网易云音乐)"),
            .song(186016)
        )
    }

    // MARK: - 伪装 host 安全负例（必须回落关键词）

    /// 伪装 host：163 域名后缀拼接（phishing 常见手法）→ 必须拒绝
    func testFakeHostWithSuffixRejected() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("https://music.163.com.evil.com/song?id=1"),
            .keyword("https://music.163.com.evil.com/song?id=1")
        )
    }

    /// 伪装 host：前缀拼接（xmusic.163.com 并非网易云子域）→ 必须拒绝
    func testFakeHostWithPrefixRejected() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("https://xmusic.163.com/song?id=1"),
            .keyword("https://xmusic.163.com/song?id=1")
        )
    }

    // MARK: - 纯数字歌曲 ID

    /// 纯数字输入 → .song(id)
    func testPureNumericInput() {
        XCTAssertEqual(NeteaseLinkParser.parse("186016"), .song(186016))
    }

    /// 前导零数字：按数值解析（"007" → 7）
    func testLeadingZeroNumericInput() {
        XCTAssertEqual(NeteaseLinkParser.parse("007"), .song(7))
    }

    /// 15 位为上限（可解析为歌曲 ID），16 位以上回落关键词
    func testNumericLengthBoundary() {
        XCTAssertEqual(NeteaseLinkParser.parse("123456789012345"), .song(123456789012345))
        XCTAssertEqual(NeteaseLinkParser.parse("1234567890123456"), .keyword("1234567890123456"))
    }

    // MARK: - 关键词

    /// 普通搜索关键词原样保留（trim 后）
    func testKeywordInput() {
        XCTAssertEqual(NeteaseLinkParser.parse("周杰伦 晴天"), .keyword("周杰伦 晴天"))
    }

    /// 空串与纯空格 → .keyword("")
    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(NeteaseLinkParser.parse(""), .keyword(""))
        XCTAssertEqual(NeteaseLinkParser.parse("   "), .keyword(""))
    }

    // MARK: - 不应误判的链接形态

    /// /songlist?id= 不是 playlist，不得误判 → 关键词
    func testSonglistLinkNotMismatched() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("https://music.163.com/songlist?id=1"),
            .keyword("https://music.163.com/songlist?id=1")
        )
    }

    /// id 参数非数字（?id=abc）→ 回落关键词
    func testNonNumericIDParamFallsBackToKeyword() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("https://music.163.com/song?id=abc"),
            .keyword("https://music.163.com/song?id=abc")
        )
    }

    /// id 参数为空（?id=）→ 回落关键词
    func testEmptyIDParamFallsBackToKeyword() {
        XCTAssertEqual(
            NeteaseLinkParser.parse("https://music.163.com/song?id="),
            .keyword("https://music.163.com/song?id=")
        )
    }
}
