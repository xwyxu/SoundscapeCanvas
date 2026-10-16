//
//  OnlineSearchViewModel.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/19.
//

import Combine
import Foundation

/// 在线搜索状态机：搜索 → 解析直链 → 下载 → 回调主界面导入。
///
/// 全部状态更新均在主线程（@MainActor）；
/// 每首歌曲的下载任务按 id 登记，sheet 关闭时 `cancelAll()` 统一取消；
/// 任务内以弱引用持有自身，VM 销毁后回调自动失效。
@MainActor
final class OnlineSearchViewModel: ObservableObject {

    // MARK: - 集合页头

    /// 歌单/专辑解析结果的页头信息（列表顶部展示；歌曲/关键词搜索时为 nil）。
    struct CollectionHeader: Equatable {
        /// 集合类型
        enum Kind: Equatable {
            /// 歌单
            case playlist
            /// 专辑
            case album
        }

        /// 集合类型
        let kind: Kind
        /// 标题（歌单名/专辑名）
        let title: String
        /// 副标题（歌单=创建者昵称；专辑=歌手名 + 发行时间拼接）
        let subtitle: String?
        /// 封面图地址
        let coverURL: URL?
        /// 曲目数文案（如"共 30 首"）
        let trackCountText: String?
    }

    // MARK: - 下载状态

    /// 单首歌曲的下载状态（按歌曲 id 索引到 `downloads`）
    enum DownloadState: Equatable {
        /// 解析音频直链中
        case resolving
        /// 下载中（进度 0–1）
        case progress(Double)
        /// 下载完成（本地文件名）
        case completed(String)
        /// 失败（原因文案；nil 时界面用通用文案兜底）
        case failed(String?)
    }

    // MARK: - 发布状态

    /// 搜索关键词（搜索框双向绑定）
    @Published var query = ""
    /// 搜索结果列表
    @Published private(set) var results: [NeteaseSong] = []
    /// 歌单/专辑页头（nil 表示当前结果非集合解析，如关键词搜索或单曲）
    @Published private(set) var collectionHeader: CollectionHeader?
    /// 搜索进行中（兼作防抖守卫：进行中忽略重复提交）
    @Published private(set) var isSearching = false
    /// 搜索错误（页面内横幅展示；nil 为无错误）
    @Published var searchError: String?
    /// 各歌曲的下载状态（无条目即空闲态）
    @Published private(set) var downloads: [Int: DownloadState] = [:]
    /// 所选音质（默认"标准"，MP3 文件小下载快）
    @Published var selectedQuality: NeteaseQuality = .standard
    /// 是否已发起过搜索（区分"尚未搜索"与"搜索无结果"两种空态）
    @Published private(set) var hasSearched = false

    // MARK: - 依赖与任务

    /// 下载完成回调（主界面接线：导入该本地文件并关闭搜索页）
    private let onImported: (URL) -> Void

    /// 网易云解析 API 客户端（网络层由 Music/NeteaseAPIClient 提供）
    private let apiClient = NeteaseAPIClient.shared

    /// 音频下载服务（落盘到 Documents/Imports/，带进度回调与取消）
    private let downloadService = AudioDownloadService()

    /// 在途下载任务（按歌曲 id 登记，供 cancelAll 统一取消）
    private var activeTasks: [Int: Task<Void, Never>] = [:]

    init(onImported: @escaping (URL) -> Void) {
        self.onImported = onImported
    }

    // MARK: - 搜索与解析分发

    /// 发起搜索/解析：提交时先解析输入类型——
    /// 网易云歌曲/歌单/专辑链接或纯数字 ID 走对应解析，其余按关键词搜索。
    /// 空输入或进行中直接忽略（简单防抖）；失败时清空结果与页头并给出提示，可重试。
    func search() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !isSearching else { return }

        isSearching = true
        searchError = nil
        let input = NeteaseLinkParser.parse(keyword)
        Task { [weak self] in
            guard let self else { return }
            await self.resolve(input: input)
            self.hasSearched = true
            self.isSearching = false
        }
    }

    /// 按输入类型分发解析（共用搜索状态与错误横幅；失败统一清空结果与页头）。
    private func resolve(input: NeteaseInput) async {
        do {
            switch input {
            case .keyword(let keyword):
                results = try await apiClient.search(keyword: keyword)
                collectionHeader = nil
            case .song(let id):
                // 单曲解析：结果仅一条，无页头
                let song = try await apiClient.songInfo(id: id)
                results = [song]
                collectionHeader = nil
            case .playlist(let id):
                let (info, songs) = try await apiClient.playlistTracks(id: id)
                results = songs
                collectionHeader = CollectionHeader(
                    kind: .playlist,
                    title: info.name,
                    subtitle: info.creatorName,
                    coverURL: info.coverImageURL,
                    trackCountText: "共 \(info.songCount) 首"
                )
            case .album(let id):
                let (info, songs) = try await apiClient.albumInfo(id: id)
                results = songs
                collectionHeader = CollectionHeader(
                    kind: .album,
                    title: info.name,
                    subtitle: Self.albumSubtitle(
                        artistName: info.artistName,
                        publishTime: info.publishTime
                    ),
                    coverURL: info.coverImageURL,
                    trackCountText: "共 \(songs.count) 首"
                )
            }
        } catch {
            // 解析失败：清空结果与页头，给出可重试的提示
            results = []
            collectionHeader = nil
            searchError = "第三方服务暂不可用，请稍后重试（\(error.localizedDescription)）"
        }
    }

    /// 清除页头与结果列表，回到未搜索态（页头"×"按钮调用）。
    func clearCollection() {
        results = []
        collectionHeader = nil
        hasSearched = false
        searchError = nil
    }

    // MARK: - 下载与导入

    /// 下载指定歌曲：按所选音质解析直链 → 下载到 Documents/Imports → 回调主界面导入。
    ///
    /// 防重复：解析中/下载中的条目忽略再次点击；失败或完成后可重试。
    /// VIP/已下架/版权限制歌曲解析失败时显示固定文案，不影响其他条目。
    func download(song: NeteaseSong, quality: NeteaseQuality) {
        if case .resolving = downloads[song.id] { return }
        if case .progress = downloads[song.id] { return }

        downloads[song.id] = .resolving
        activeTasks[song.id] = Task { [weak self] in
            guard let self else { return }
            do {
                // 歌曲基础信息已在结果条目中，此处仅需解析音频直链
                let resolved = try await apiClient.songURL(id: song.id, quality: quality)
                guard !Task.isCancelled else {
                    self.downloads[song.id] = nil
                    return
                }
                let fileName = Self.sanitizedFileName(
                    name: song.name,
                    artist: song.singer,
                    fileType: resolved.fileType
                )
                let localURL = try await self.downloadService.download(
                    from: resolved.url,
                    fileName: fileName
                ) { [weak self] value in
                    self?.downloads[song.id] = .progress(value)
                }
                self.activeTasks[song.id] = nil
                self.downloads[song.id] = .completed(fileName)
                self.onImported(localURL)
            } catch is CancellationError {
                // sheet 关闭触发的取消：该条目收敛回空闲态
                self.activeTasks[song.id] = nil
                self.downloads[song.id] = nil
            } catch {
                self.activeTasks[song.id] = nil
                self.downloads[song.id] = .failed(Self.failureMessage(for: error))
            }
        }
    }

    /// 取消全部在途下载任务与网络请求（sheet 关闭时由视图调用）
    func cancelAll() {
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
        downloadService.cancelAll()
    }

    // MARK: - 私有辅助

    /// 生成下载文件名"<歌名>-<歌手>.<扩展名>"，清洗文件系统非法字符
    private static func sanitizedFileName(name: String, artist: String, fileType: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = "\(name)-\(artist)"
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "在线音乐" : cleaned
        let ext = fileType.isEmpty ? "mp3" : fileType.lowercased()
        return "\(base).\(ext)"
    }

    /// 专辑副标题：歌手名 + 发行时间拼接（忽略缺失项，两者皆缺时为 nil）
    private static func albumSubtitle(artistName: String?, publishTime: String?) -> String? {
        let parts = [artistName, publishTime].compactMap { part -> String? in
            let trimmed = part?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 失败原因文案：版权限制 / VIP 或已下架用固定提示，频控与其余透出本地化错误描述
    private static func failureMessage(for error: Error) -> String? {
        if let apiError = error as? NeteaseAPIError {
            switch apiError {
            case .copyrightRestricted:
                return "版权限制，无法获取该歌曲"
            case .unavailable:
                return "可能为 VIP 或已下架"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
