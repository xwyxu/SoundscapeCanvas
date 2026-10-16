//
//  OnlineSearchView.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/19.
//

import SwiftUI

/// 在线搜索页（sheet 呈现）：搜索框 + 音质切换 + 结果列表 + 底部版权声明。
///
/// 下载完成后通过 `onImported` 回调主界面（导入该本地文件并关闭本页）；
/// 页面关闭时取消全部在途下载（`cancelAll`）。
struct OnlineSearchView: View {
    @StateObject private var viewModel: OnlineSearchViewModel
    @Environment(\.dismiss) private var dismiss

    init(onImported: @escaping (URL) -> Void) {
        _viewModel = StateObject(wrappedValue: OnlineSearchViewModel(onImported: onImported))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                qualityMenu

                if let error = viewModel.searchError {
                    searchErrorBanner(error)
                }

                resultArea
            }
            .navigationTitle("在线搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // 底部固定版权与用途声明（不随列表滚动）
            .safeAreaInset(edge: .bottom) { declarationFooter }
        }
        .preferredColorScheme(.dark)
        .onDisappear { viewModel.cancelAll() }
    }

    // MARK: - 搜索框与音质

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索歌曲 / 歌手", text: $viewModel.query)
                .submitLabel(.search)
                .onSubmit { viewModel.search() }

            if !viewModel.query.isEmpty {
                Button(action: { viewModel.query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空关键词")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Capsule().fill(.white.opacity(0.1)))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 音质切换（默认"标准音质"）

    private var qualityMenu: some View {
        HStack {
            Menu {
                Picker("音质", selection: $viewModel.selectedQuality) {
                    ForEach(NeteaseQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
            } label: {
                Label("音质：\(viewModel.selectedQuality.displayName)", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - 结果区

    @ViewBuilder
    private var resultArea: some View {
        if viewModel.isSearching {
            // 搜索中：居中加载指示
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty {
            emptyHint
        } else {
            List {
                // 歌单/专辑页头（仅集合解析结果展示）
                if let header = viewModel.collectionHeader {
                    CollectionHeaderView(header: header) {
                        viewModel.clearCollection()
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 4))
                }
                ForEach(viewModel.results) { song in
                    SongRow(song: song, state: viewModel.downloads[song.id]) {
                        viewModel.download(song: song, quality: viewModel.selectedQuality)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// 空态提示：区分"尚未搜索"与"搜索无结果"
    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text(viewModel.hasSearched ? "未找到相关歌曲，换个关键词试试" : "输入关键词开始搜索")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("支持粘贴歌曲/歌单/专辑链接或纯数字 ID")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 错误横幅（页面内简化版，样式对齐 ErrorBanner）

    private func searchErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { viewModel.searchError = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - 底部声明

    private var declarationFooter: some View {
        Text("内容来自网易云音乐解析服务（nextmusic.toubiec.cn），音乐版权归原平台及原作者所有，仅供个人学习研究使用")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
    }
}

// MARK: - 集合页头

/// 歌单/专辑页头：封面小图 + 标题/副标题/曲目数 + 右侧关闭按钮（回到未搜索态）。
private struct CollectionHeaderView: View {
    let header: OnlineSearchViewModel.CollectionHeader
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: header.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(header.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let subtitle = header.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let trackCount = header.trackCountText {
                    Text(trackCount)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭\(header.kind == .playlist ? "歌单" : "专辑")页头")
        }
    }
}

// MARK: - 结果行

/// 单条搜索结果：歌名 / 歌手 / 专辑三行文本 + 右侧下载状态。
/// 状态：空闲（下载按钮）→ 解析中（转圈）→ 下载中（进度条）
/// → 完成（绿色对勾）/ 失败（灰色警告 + 行内错误小字，可点击重试）。
private struct SongRow: View {
    let song: NeteaseSong
    let state: OnlineSearchViewModel.DownloadState?
    let downloadAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.name)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(song.singer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(song.album)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // 失败原因行内小字（VIP/下架等）
                if case .failed(let message) = state {
                    Text(message ?? "下载失败")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusView
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: 右侧下载状态

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .resolving:
            // 解析直链中：小转圈
            ProgressView()
                .frame(width: 32, height: 32)
                .accessibilityLabel("正在解析 \(song.name)")
        case .progress(let value):
            // 下载中：细进度条（0–1）
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 56)
                .accessibilityLabel("正在下载 \(song.name)")
        case .completed:
            // 完成：绿色对勾（不可再点，主界面已自动导入）
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .accessibilityLabel("已下载 \(song.name)")
        case .failed:
            // 失败：灰色警告，点击重试
            Button(action: downloadAction) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.gray)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重试下载 \(song.name)")
        case nil:
            // 空闲：下载按钮
            Button(action: downloadAction) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下载 \(song.name)")
        }
    }
}

#Preview {
    OnlineSearchView { _ in }
}
