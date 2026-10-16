//
//  NeteaseLinkParser.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/10/16.
//

import Foundation

/// 用户输入的分类结果：网易云歌曲/歌单/专辑、纯数字歌曲 ID 或搜索关键词。
nonisolated enum NeteaseInput: Equatable, Sendable {
    /// 歌曲（来自 `/song?id=` 链接或纯数字 ID）
    case song(Int)
    /// 歌单（来自 `/playlist?id=` 链接）
    case playlist(Int)
    /// 专辑（来自 `/album?id=` 链接）
    case album(Int)
    /// 搜索关键词（含链接解析失败后的回落原文，可能为空串）
    case keyword(String)
}

/// 用户输入解析器（无实例状态的纯函数命名空间）：
/// 识别网易云歌曲/歌单/专辑链接、纯数字歌曲 ID，其余一律视为搜索关键词。
///
/// 规则按优先级依次尝试：
/// 1. **网易云链接**：trim 后包含 `music.163.com`（大小写不敏感）时尝试解析；
///    - host 必须恰好是 `music.163.com` 或以 `.music.163.com` 结尾（如 `y.music.163.com`），
///      拒绝 `fakemusic.163.com.evil.com` 这类伪装 host；
///    - 路由（path 或老版 SPA 的 `#` 片段）含 `song` / `playlist` / `album` 片段时，
///      取查询参数 `id`（容忍 http/https、端口、多余参数、`?id=` / `&id=`、参数名大小写）；
///    - host 不符、类型未识别或 `id` 缺失/非数字 → 回落为关键词。
/// 2. **纯数字歌曲 ID**：trim 后为 1-15 位 ASCII 数字 → `.song(id)`。
/// 3. **关键词**：其余一律 `.keyword(trim 后原文)`，空输入 → `.keyword("")`。
///
/// - 示例：
///   - `"https://music.163.com/song?id=186016"` → `.song(186016)`
///   - `"https://y.music.163.com/m/playlist?id=3778678&userid=1"` → `.playlist(3778678)`
///   - `"http://Music.163.com/#/album?id=18918"` → `.album(18918)`
///   - `"186016"` → `.song(186016)`
///   - `"周杰伦 晴天"` → `.keyword("周杰伦 晴天")`
nonisolated enum NeteaseLinkParser {

    // MARK: - 入口

    /// 解析用户输入（规则与示例见类型文档）。
    static func parse(_ rawInput: String) -> NeteaseInput {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .keyword("") }

        // 规则 1：包含网易云域名时先按链接解析；解析失败则继续走后续规则（结果同为关键词）
        if input.range(of: "music.163.com", options: .caseInsensitive) != nil,
           let link = parseNeteaseLink(from: input) {
            return link
        }
        // 规则 2：纯数字 → 歌曲 ID
        if let id = numericSongID(from: input) {
            return .song(id)
        }
        // 规则 3：其余一律按搜索关键词
        return .keyword(input)
    }

    // MARK: - 链接解析

    /// 链接解析：先尝试 `URLComponents`（输入为合法 URL 时的精确路径）；
    /// 失败或未识别出类型时，用字符串匹配容错兜底
    /// （分享文案常带中文/空格导致 URL(string:) 失败，
    /// 如 `"分享《晴天》 https://music.163.com/song?id=1 (来自@网易云音乐)"`）。
    private static func parseNeteaseLink(from input: String) -> NeteaseInput? {
        // 第一层：URLComponents 精确解析（host 大小写不敏感；容忍 http/https、端口、多余参数）
        if let components = URLComponents(string: input),
           let host = components.host?.lowercased(),
           isNeteaseHost(host) {
            // 老版 SPA 路由把类型与 id 藏在 `#` 片段里（如 /#/song?id=1），需与 path 一并拼接
            var route = components.path
            if let fragment = components.fragment, !fragment.isEmpty { route += "/" + fragment }
            if let query = components.query, !query.isEmpty { route += "?" + query }
            if let result = classify(route: route) {
                return result
            }
        }
        // 第二层：字符串匹配兜底（URL 因中文/空格等字符解析失败，或上面未识别出类型）
        return parseByStringMatching(from: input)
    }

    /// 字符串匹配兜底：定位 `music.163.com` 出现处，按 host 边界字符扫描出完整 host，
    /// 校验通过后把剩余部分作为路由交给 `classify`。
    private static func parseByStringMatching(from input: String) -> NeteaseInput? {
        guard let domainRange = input.range(of: "music.163.com", options: .caseInsensitive) else { return nil }

        // 向左扩展子域名标签（ASCII 字母/数字/连字符/点），如 `y.music.163.com`；
        // 中文等非 host 字符自然截断
        var hostStart = domainRange.lowerBound
        while hostStart > input.startIndex {
            let previous = input.index(before: hostStart)
            let character = input[previous]
            guard character.isASCII,
                  character.isLetter || character.isNumber || character == "." || character == "-" else { break }
            hostStart = previous
        }

        // 向右扩展：域名后若紧跟 `.标签`（如 `music.163.com.evil.com`）则纳入 host 一并校验，防伪装
        var hostEnd = domainRange.upperBound
        while hostEnd < input.endIndex, input[hostEnd] == "." {
            var labelEnd = input.index(after: hostEnd)
            guard labelEnd < input.endIndex,
                  input[labelEnd].isASCII,
                  input[labelEnd].isLetter || input[labelEnd].isNumber else { break }
            while labelEnd < input.endIndex, isHostLabelCharacter(input[labelEnd]) {
                labelEnd = input.index(after: labelEnd)
            }
            hostEnd = labelEnd
        }

        let host = String(input[hostStart..<hostEnd]).lowercased()
        guard isNeteaseHost(host) else { return nil }
        return classify(route: String(input[hostEnd...]))
    }

    // MARK: - 路由与参数

    /// 从路由串（path/片段/查询的拼接，可能混有分享文案尾巴）中识别类型并提取 `id`。
    /// 路由按 `/`、`?`、`#` 切段，段名恰为 `song` / `playlist` / `album` 之一才算命中；
    /// `id` 缺失或非数字返回 nil（上层回落为关键词）。
    private static func classify(route: String) -> NeteaseInput? {
        let segments = route
            .split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" })
            .map { $0.lowercased() }
        guard let type = segments.first(where: { $0 == "song" || $0 == "playlist" || $0 == "album" }),
              let id = extractID(from: route) else { return nil }
        switch type {
        case "song":
            return .song(id)
        case "playlist":
            return .playlist(id)
        case "album":
            return .album(id)
        default:
            return nil
        }
    }

    /// 提取查询参数 `id`（容忍 `?id=` / `&id=`、参数名大小写；仅接受纯数字）。
    private static func extractID(from route: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"[?&]id=([0-9]+)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: route, range: NSRange(route.startIndex..., in: route)),
              let captureRange = Range(match.range(at: 1), in: route) else { return nil }
        return Int(route[captureRange])
    }

    // MARK: - host 与数字校验

    /// host 校验：必须恰好是 `music.163.com` 或以 `.music.163.com` 结尾（如 `y.music.163.com`），
    /// 拒绝 `fakemusic.163.com.evil.com`、`xmusic.163.com` 这类伪装 host。
    private static func isNeteaseHost(_ host: String) -> Bool {
        host == "music.163.com" || host.hasSuffix(".music.163.com")
    }

    /// host 标签字符：ASCII 字母/数字/连字符（用于 host 边界扫描，不含点）。
    private static func isHostLabelCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    /// 规则 2 的数字校验：1-15 位 ASCII 数字 → 歌曲 ID
    /// （超出位数或含全角/非 ASCII 数字不算，避免误把长串数字当歌曲 ID）。
    private static func numericSongID(from string: String) -> Int? {
        guard !string.isEmpty, string.count <= 15 else { return nil }
        guard string.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(string)
    }
}
