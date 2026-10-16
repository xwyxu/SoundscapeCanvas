
# Soundscape Canvas · 意境

把一段音乐变成一幅会流动的钢琴卷帘，可以看，也可以录成视频分享出去。

## 它是什么

导入一首歌（或者用内置搜索在线找一首），App 会先解码装载，马上就能播放。与此同时，它在后台做旋律分析：用 Spotify 的 Basic Pitch 模型在本地推理，音频不出设备。分析完成后，主旋律和副旋律会以两种颜色铺在钢琴卷帘画布上，跟着播放进度逐帧滚动。整首曲子看下来，哪句是主旋律、副旋律在做什么，一眼就能看清。看上哪一段，可以一键导出和屏幕同分辨率的视频。

平台是 iPhone 和 iPad，在 Apple Silicon 的 Mac 上也能以「为 iPad 设计」方式运行。

## 界面预览


 <img width="1136" height="912" alt="01-home" src="https://github.com/user-attachments/assets/86893ccf-2b3f-461b-a4af-063a7b276f50" />
  <img width="1136" height="912" alt="02-piano-roll" src="https://github.com/user-attachments/assets/e6c5c794-5408-4e65-8163-36c32b99cfb7" />
  <img width="1136" height="912" alt="03-online-search" src="https://github.com/user-attachments/assets/bb1ffe33-7e4f-4405-8dd7-71778c474738" />
 

## 主要功能

音频来源：

- 本地导入常见音频格式，走系统文件选择器，安全作用域访问全程托管
- 内置聚合搜索，按歌名或歌手搜，下载完成后自动进分析管线

分析和可视化：

- 旋律提取完全在本地完成。Basic Pitch CoreML 模型随 App 打包，不依赖任何在线 AI 服务
- 主旋律和副旋律自动分成两个声部，双色渲染。声部分离用的是声学显著度加轨迹级追踪，真实音乐上的表现比逐拍取最大值稳定得多
- 播放和分析完全解耦：导入即可播放，不用等分析，画布在分析完成后自动淡入

视频导出：

- 分辨率等于当前设备屏幕的物理像素，不拉伸、不裁切、没有黑边
- 30fps，H.264 视频加 AAC 音轨，两条轨并行写入
- 渲染进度实时可见，随时可以取消，半成品会自动清掉

一些细节：

- 错误提示走顶部横幅，6 秒自动消失，点一下就关。在文件选择器里点取消不会误报错误
- 纯黑主题，为看谱场景设计
- 关键操作都写了 accessibilityLabel

## 工作原理

```text
音频来源（本地导入 / 在线搜索下载）
        │
        ▼
  AudioLoader 解码 ──► PlaybackEngine 采样级播放（立即可听）
        │
        ▼  单声道采样（后台 Task）
  MelodyAnalysisService 管线编排
        │  线性重采样 → 22050 Hz
        ▼
  Basic Pitch CoreML 分窗推理（nmp.mlpackage，本地离线）
        │  frames / onsets / contours
        ▼
  NoteDecoder 音符解码 → VoiceSeparator 主/副声部分离
        │
        ▼  MelodyData（主线程收敛）
  PianoRollRenderer 钢琴卷帘渲染（App 画布与视频帧同源）
        │
        ▼
  VideoExporter（AVAssetWriter：H.264 视频 + AAC 音轨并行写入）
        │
        ▼
  系统分享面板（保存 / 分享 MP4）
```
![Uploading sound<svg viewBox="0 0 1200 700" role="img" lang="zh-CN" aria-labelledby="archify-diagram-title archify-diagram-description" data-preset="classic" data-quality-profile="showcase" style="" width="1200" height="700" xmlns="http://www.w3.org/2000/svg"><style>@font-face { font-family: 'JetBrains Mono'; font-weight: 400; src: local('JetBrains Mono'), local('JetBrainsMono-Regular'); }
@font-face { font-family: 'JetBrains Mono'; font-weight: 500; src: local('JetBrains Mono'), local('JetBrainsMono-Regular'); }
@font-face { font-family: 'JetBrains Mono'; font-weight: 600; src: local('JetBrains Mono'), local('JetBrainsMono-Regular'); }
@font-face { font-family: 'JetBrains Mono'; font-weight: 700; src: local('JetBrains Mono'), local('JetBrainsMono-Regular'); }
svg { font-family: 'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, 'DejaVu Sans Mono', 'Liberation Mono', 'Noto Sans Mono CJK SC', 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', monospace; }
:root, [data-theme="dark"] { --bg: #020617; --grid: #1e293b; --text: #ffffff; --text-muted: #94a3b8; --text-dim: #475569; --text-faint: #7d8da1; --panel: rgba(15, 23, 42, 0.5); --panel-border: #1e293b; --lane-fill: rgba(15, 23, 42, 0.22); --lane-stroke: #334155; --arrow: #64748b; --arrow-emphasis: #34d399; --mask: #0f172a; --frontend-fill: rgba(8, 51, 68, 0.4); --frontend-stroke: #22d3ee; --backend-fill: rgba(6, 78, 59, 0.4); --backend-stroke: #34d399; --database-fill: rgba(76, 29, 149, 0.4); --database-stroke: #a78bfa; --cloud-fill: rgba(120, 53, 15, 0.3); --cloud-stroke: #fbbf24; --security-fill: rgba(136, 19, 55, 0.4); --security-stroke: #fb7185; --messagebus-fill: rgba(251, 146, 60, 0.3); --messagebus-stroke: #fb923c; --external-fill: rgba(30, 41, 59, 0.5); --external-stroke: #94a3b8; --toolbar-bg: rgba(15, 23, 42, 0.8); --toolbar-border: #334155; --toolbar-text: #e2e8f0; --toolbar-hover: rgba(15, 23, 42, 0.95); --toolbar-menu-bg: #0f172a; }
[data-theme="light"] { --bg: #f8fafc; --grid: #e2e8f0; --text: #0f172a; --text-muted: #64748b; --text-dim: #94a3b8; --text-faint: #64748b; --panel: #ffffff; --panel-border: #e2e8f0; --lane-fill: rgba(248, 250, 252, 0.65); --lane-stroke: #cbd5e1; --arrow: #94a3b8; --arrow-emphasis: #059669; --mask: #ffffff; --frontend-fill: rgba(34, 211, 238, 0.15); --frontend-stroke: #0891b2; --backend-fill: rgba(52, 211, 153, 0.18); --backend-stroke: #059669; --database-fill: rgba(167, 139, 250, 0.2); --database-stroke: #7c3aed; --cloud-fill: rgba(251, 191, 36, 0.18); --cloud-stroke: #d97706; --security-fill: rgba(251, 113, 133, 0.15); --security-stroke: #e11d48; --messagebus-fill: rgba(251, 146, 60, 0.15); --messagebus-stroke: #ea580c; --external-fill: rgba(148, 163, 184, 0.18); --external-stroke: #64748b; --toolbar-bg: rgba(255, 255, 255, 0.92); --toolbar-border: #cbd5e1; --toolbar-text: #334155; --toolbar-hover: #ffffff; --toolbar-menu-bg: #ffffff; }
[data-preset="signal-flow"][data-theme="dark"] { --bg: #030711; --grid: #15233a; --panel: rgba(6, 14, 28, 0.78); --panel-border: #1d3350; --lane-fill: rgba(9, 22, 40, 0.5); --lane-stroke: #2c4564; --text: #f5fbff; --text-muted: #9eb0c7; --text-dim: #52667f; --text-faint: #7890ad; --mask: #07101e; --frontend-fill: rgba(6, 182, 212, 0.14); --frontend-stroke: #67e8f9; --backend-fill: rgba(16, 185, 129, 0.14); --backend-stroke: #5eead4; --database-fill: rgba(139, 92, 246, 0.16); --database-stroke: #c4b5fd; --cloud-fill: rgba(245, 158, 11, 0.13); --cloud-stroke: #fcd34d; --security-fill: rgba(244, 63, 94, 0.13); --security-stroke: #fda4af; --messagebus-fill: rgba(249, 115, 22, 0.13); --messagebus-stroke: #fdba74; --external-fill: rgba(71, 85, 105, 0.24); --external-stroke: #a5b4c7; --arrow: #7890ad; --arrow-emphasis: #2dd4bf; --toolbar-bg: rgba(7, 16, 30, 0.86); --toolbar-border: #29415f; --toolbar-menu-bg: #07101e; }
[data-preset="signal-flow"][data-theme="light"] { --bg: #f4f9fc; --grid: #d4e5ee; --panel: rgba(255, 255, 255, 0.82); --panel-border: #bfd5e2; --lane-fill: rgba(232, 243, 248, 0.62); --lane-stroke: #a9c5d5; --text: #102638; --text-muted: #587287; --text-dim: #8aa2b4; --text-faint: #668397; --mask: #ffffff; --frontend-fill: rgba(6, 182, 212, 0.09); --frontend-stroke: #0789a1; --backend-fill: rgba(5, 150, 105, 0.09); --backend-stroke: #087f69; --database-fill: rgba(124, 58, 237, 0.09); --database-stroke: #7254c7; --cloud-fill: rgba(217, 119, 6, 0.08); --cloud-stroke: #b9670b; --security-fill: rgba(225, 29, 72, 0.08); --security-stroke: #c53a59; --messagebus-fill: rgba(234, 88, 12, 0.08); --messagebus-stroke: #c65f27; --external-fill: rgba(100, 116, 139, 0.1); --external-stroke: #607a8c; --arrow: #7b97aa; --arrow-emphasis: #0d9488; }
[data-preset="blueprint"][data-theme="dark"] { --bg: #06131f; --grid: #17425a; --panel: rgba(7, 27, 43, 0.9); --panel-border: #27627f; --lane-fill: rgba(10, 43, 66, 0.36); --lane-stroke: #34799a; --text: #e3f6ff; --text-muted: #91b8ca; --text-dim: #557e92; --text-faint: #739caf; --mask: #0a2031; --frontend-fill: rgba(26, 157, 193, 0.14); --frontend-stroke: #66d9ef; --backend-fill: rgba(31, 155, 124, 0.13); --backend-stroke: #69dfbd; --database-fill: rgba(120, 105, 196, 0.14); --database-stroke: #b4a8ff; --cloud-fill: rgba(197, 145, 43, 0.13); --cloud-stroke: #ffd166; --security-fill: rgba(199, 76, 104, 0.13); --security-stroke: #ff8da1; --messagebus-fill: rgba(207, 112, 49, 0.13); --messagebus-stroke: #ffad66; --external-fill: rgba(84, 119, 139, 0.18); --external-stroke: #a7cad9; --arrow: #78a3b7; --arrow-emphasis: #64dfc1; --toolbar-bg: rgba(7, 28, 45, 0.92); --toolbar-border: #34799a; --toolbar-text: #d8f3ff; --toolbar-hover: rgba(18, 58, 83, 0.95); --toolbar-menu-bg: #0a2031; }
[data-preset="blueprint"][data-theme="light"] { --bg: #edf7fa; --grid: #b5d5e1; --panel: rgba(249, 253, 255, 0.94); --panel-border: #78aabd; --lane-fill: rgba(210, 232, 240, 0.42); --lane-stroke: #83b2c4; --text: #123344; --text-muted: #4e7486; --text-dim: #86a6b4; --text-faint: #668c9d; --mask: #f9fdff; --frontend-fill: rgba(8, 145, 178, 0.08); --frontend-stroke: #087f9c; --backend-fill: rgba(5, 128, 101, 0.08); --backend-stroke: #08755f; --database-fill: rgba(100, 75, 180, 0.08); --database-stroke: #6757a8; --cloud-fill: rgba(181, 120, 15, 0.08); --cloud-stroke: #a86609; --security-fill: rgba(190, 48, 80, 0.07); --security-stroke: #b32f50; --messagebus-fill: rgba(196, 81, 22, 0.07); --messagebus-stroke: #b65120; --external-fill: rgba(79, 112, 128, 0.08); --external-stroke: #506f7e; --arrow: #6d93a5; --arrow-emphasis: #087f69; --toolbar-bg: rgba(247, 252, 254, 0.94); --toolbar-border: #8ab5c5; --toolbar-text: #294f61; --toolbar-hover: #ffffff; --toolbar-menu-bg: #f9fdff; }
[data-preset="editorial"][data-theme="dark"] { --bg: #181611; --grid: #39342a; --panel: rgba(35, 31, 24, 0.96); --panel-border: #625a4a; --lane-fill: rgba(52, 46, 35, 0.46); --lane-stroke: #726957; --text: #f4eddf; --text-muted: #b9ae9b; --text-dim: #776e60; --text-faint: #9d917e; --mask: #231f18; --frontend-fill: rgba(43, 133, 142, 0.16); --frontend-stroke: #7fc6c7; --backend-fill: rgba(63, 132, 92, 0.16); --backend-stroke: #8fc29e; --database-fill: rgba(117, 91, 141, 0.17); --database-stroke: #c0a4d0; --cloud-fill: rgba(170, 119, 49, 0.16); --cloud-stroke: #d8ad68; --security-fill: rgba(157, 69, 65, 0.17); --security-stroke: #df9085; --messagebus-fill: rgba(174, 79, 42, 0.16); --messagebus-stroke: #df946f; --external-fill: rgba(126, 115, 96, 0.18); --external-stroke: #b8ad99; --arrow: #948978; --arrow-emphasis: #dd6b3d; --toolbar-bg: rgba(35, 31, 24, 0.92); --toolbar-border: #625a4a; --toolbar-text: #eee5d5; --toolbar-hover: #302a20; --toolbar-menu-bg: #231f18; }
[data-preset="editorial"][data-theme="light"] { --bg: #f2eee5; --grid: #d8d0c2; --panel: rgba(251, 248, 241, 0.97); --panel-border: #c4b9a6; --lane-fill: rgba(229, 221, 207, 0.42); --lane-stroke: #b8aa94; --text: #242018; --text-muted: #6f6658; --text-dim: #a09788; --text-faint: #817767; --mask: #fbf8f1; --frontend-fill: rgba(31, 117, 126, 0.09); --frontend-stroke: #287e84; --backend-fill: rgba(42, 119, 75, 0.09); --backend-stroke: #397b53; --database-fill: rgba(105, 75, 130, 0.09); --database-stroke: #765d86; --cloud-fill: rgba(157, 103, 31, 0.1); --cloud-stroke: #9a671f; --security-fill: rgba(153, 58, 52, 0.09); --security-stroke: #9e463f; --messagebus-fill: rgba(182, 70, 27, 0.09); --messagebus-stroke: #ad4b25; --external-fill: rgba(101, 91, 75, 0.09); --external-stroke: #746b5e; --arrow: #8a806f; --arrow-emphasis: #bb4c23; --toolbar-bg: rgba(251, 248, 241, 0.94); --toolbar-border: #c4b9a6; --toolbar-text: #40392f; --toolbar-hover: #fffdf8; --toolbar-menu-bg: #fbf8f1; }
svg { width: 100%; min-width: min(900px, 100%); display: block; transform-origin: 0px 0px; transition: transform 0.18s; }
@keyframes archify-lens-in { 
  0% { opacity: 0; transform: translateY(5px) scale(0.985); }
  100% { opacity: 1; transform: translateY(0px) scale(1); }
}
@keyframes archify-guide-in { 
  0% { opacity: 0; transform: translateY(-5px) scale(0.985); }
  100% { opacity: 1; transform: translateY(0px) scale(1); }
}
svg[data-chapter-handoff] [data-node-id][data-chapter-role="stay"] { opacity: 1; }
svg[data-chapter-handoff] [data-node-id][data-chapter-role="enter"] { opacity: 0.78; }
svg[data-chapter-handoff] [data-node-id][data-chapter-role="leave"] { opacity: 0.26; }
@keyframes archify-chapter-anchor { 
  0% { opacity: 0.35; stroke-dashoffset: 8; }
  45% { opacity: 1; }
  100% { opacity: 0.72; stroke-dashoffset: 0; }
}
@keyframes archify-story-caption-in { 
  0% { opacity: 0; transform: translateY(3px); }
  100% { opacity: 1; transform: translateY(0px); }
}
[data-theme="light"] #theme-icon { mask-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20'%3E%3Cg fill='none' stroke='black' stroke-width='1.7' stroke-linecap='round'%3E%3Ccircle cx='10' cy='10' r='3.1'/%3E%3Cpath d='M10 2.2v1.4M10 16.4v1.4M2.2 10h1.4M16.4 10h1.4M4.5 4.5l1 1M14.5 14.5l1 1M15.5 4.5l-1 1M5.5 14.5l-1 1'/%3E%3C/g%3E%3C/svg%3E"); }
[data-theme="dark"] #theme-icon { mask-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 20'%3E%3Cpath d='M15.2 12.7A6.3 6.3 0 017.3 4.8a6.3 6.3 0 107.9 7.9Z' fill='none' stroke='black' stroke-width='1.7' stroke-linejoin='round'/%3E%3C/svg%3E"); }
.c-grid { stroke: var(--grid); fill: none; }
.c-mask { fill: var(--mask); stroke: none; }
.c-frontend { fill: var(--frontend-fill); stroke: var(--frontend-stroke); }
.c-backend { fill: var(--backend-fill); stroke: var(--backend-stroke); }
.c-database { fill: var(--database-fill); stroke: var(--database-stroke); }
.c-cloud { fill: var(--cloud-fill); stroke: var(--cloud-stroke); }
.c-security { fill: var(--security-fill); stroke: var(--security-stroke); }
.c-messagebus { fill: var(--messagebus-fill); stroke: var(--messagebus-stroke); }
.c-external { fill: var(--external-fill); stroke: var(--external-stroke); }
.t-primary { fill: var(--text); }
.t-muted { fill: var(--text-muted); }
.t-dim { fill: var(--text-dim); }
.t-frontend { fill: var(--frontend-stroke); }
.t-backend { fill: var(--backend-stroke); }
.t-database { fill: var(--database-stroke); }
.t-cloud { fill: var(--cloud-stroke); }
.t-security { fill: var(--security-stroke); }
.t-messagebus { fill: var(--messagebus-stroke); }
.t-external { fill: var(--external-stroke); }
svg .semantic-sigil { fill: none; stroke: currentcolor; stroke-width: 1.35; stroke-linecap: round; stroke-linejoin: round; opacity: 0.76; pointer-events: none; }
svg .semantic-sigil &gt; * { vector-effect: non-scaling-stroke; }
svg .semantic-sigil .sigil-fill { fill: currentcolor; stroke: none; }
svg .s-frontend { color: var(--frontend-stroke); }
svg .s-backend { color: var(--backend-stroke); }
svg .s-database { color: var(--database-stroke); }
svg .s-cloud { color: var(--cloud-stroke); }
svg .s-security { color: var(--security-stroke); }
svg .s-messagebus { color: var(--messagebus-stroke); }
svg .s-external { color: var(--external-stroke); }
svg .brand-mark { pointer-events: none; }
svg .brand-mark-badge { fill: rgb(255, 255, 255); stroke: none; }
svg .brand-mark-frame { fill: none; stroke: rgb(203, 213, 225); stroke-width: 0.8; vector-effect: non-scaling-stroke; }
svg .brand-mark-fallback { fill: none; stroke: rgb(71, 85, 105); stroke-width: 1.15; stroke-linecap: round; stroke-linejoin: round; }
svg[data-preset="blueprint"] .brand-mark-badge, svg[data-preset="blueprint"] .brand-mark-frame { rx: 1px; }
svg [data-detail] { transition: opacity 160ms; }
svg [data-detail-anchor] { transform-box: fill-box; transform-origin: center center; transition: transform 160ms; }
svg[data-focus-active] [data-focus-match][data-detail], svg[data-focus-active] [data-focus-match] [data-detail], svg[data-reach-active] [data-reach-match][data-detail], svg[data-reach-active] [data-reach-match] [data-detail], svg[data-lens-active] [data-lens-match][data-detail], svg[data-lens-active] [data-lens-match] [data-detail], svg[data-legend-preview-active] [data-legend-preview-match][data-detail], svg[data-legend-preview-active] [data-legend-preview-match] [data-detail], svg[data-intent-trace-active] [data-intent-trace-match][data-detail], svg[data-intent-trace-active] [data-intent-trace-match] [data-detail], svg[data-route-active] [data-route-match][data-detail], svg[data-route-active] [data-route-match] [data-detail], svg[data-story-active] [data-story-step][data-detail], svg[data-story-active] [data-story-step] [data-detail], svg[data-relationship-preview-active] [data-relationship-preview][data-detail], svg[data-relationship-preview-active] [data-relationship-preview] [data-detail], svg [data-node-id]:hover [data-detail], svg [data-node-id]:focus-visible [data-detail] { opacity: 1; pointer-events: auto; }
svg[data-focus-active] [data-focus-match] [data-detail-anchor], svg[data-reach-active] [data-reach-match] [data-detail-anchor], svg[data-lens-active] [data-lens-match] [data-detail-anchor], svg[data-legend-preview-active] [data-legend-preview-match] [data-detail-anchor], svg[data-intent-trace-active] [data-intent-trace-match] [data-detail-anchor], svg[data-route-active] [data-route-match] [data-detail-anchor], svg[data-story-active] [data-story-step] [data-detail-anchor], svg [data-node-id]:hover [data-detail-anchor], svg [data-node-id]:focus-visible [data-detail-anchor] { transform: none; }
.a-default { stroke: var(--arrow); fill: none; }
.a-emphasis { stroke: var(--arrow-emphasis); fill: none; }
.a-security { stroke: var(--security-stroke); fill: none; stroke-dasharray: 5, 5; }
.a-dashed { stroke: var(--database-stroke); fill: none; stroke-dasharray: 4, 4; }
.m-default { fill: var(--arrow); }
.m-emphasis { fill: var(--arrow-emphasis); }
.m-security { fill: var(--security-stroke); }
.m-dashed { fill: var(--database-stroke); }
svg [data-node-id] { cursor: pointer; transition: opacity 0.18s, filter 0.18s; }
svg [data-edge-from] { transition: opacity 0.18s, filter 0.18s; }
svg [data-node-id]:hover, svg [data-node-id]:focus-visible { filter: drop-shadow(0 0 7px var(--frontend-stroke)); outline: none; }
svg [data-node-id]:hover .source-evidence-beacon, svg [data-node-id]:focus-visible .source-evidence-beacon, svg [data-node-id][data-focus-selected] .source-evidence-beacon { opacity: 1; filter: drop-shadow(0 0 4px color-mix(in srgb, var(--backend-stroke) 72%, transparent)); }
svg[data-preset="signal-flow"] .source-evidence-beacon { opacity: 0.9; }
svg[data-preset="blueprint"] .source-evidence-beacon rect { rx: 0.8px; filter: none; }
svg [data-legend-kind][role="button"] { cursor: pointer; }
svg [data-legend-kind]:focus { outline: none; }
svg [data-legend-hit] { fill: transparent; stroke: transparent; stroke-width: 1.4; pointer-events: all; vector-effect: non-scaling-stroke; transition: stroke 150ms, stroke-width 150ms, filter 150ms; }
svg [data-legend-count-badge] { pointer-events: none; }
svg [data-legend-count-badge] rect { fill: var(--mask); stroke: var(--panel-border); stroke-width: 1; vector-effect: non-scaling-stroke; }
svg [data-legend-count-badge] text { fill: var(--text-muted); font-size: 8px; font-weight: 700; text-anchor: middle; }
svg [data-legend-kind][role="button"]:hover [data-legend-hit] { stroke: color-mix(in srgb, var(--database-stroke) 58%, transparent); }
svg [data-legend-kind][role="button"]:focus-visible [data-legend-hit] { stroke: var(--frontend-stroke); stroke-width: 1.8; filter: drop-shadow(0 0 3px var(--frontend-stroke)); }
svg [data-legend-kind][data-legend-selected] [data-legend-hit] { stroke: var(--database-stroke); stroke-width: 2.2; stroke-dasharray: 3, 2; }
svg [data-legend-kind][data-legend-selected] [data-legend-count-badge] rect { stroke: var(--database-stroke); stroke-width: 1.8; }
svg [data-legend-kind][data-legend-zero] { opacity: 0.44; }
svg[data-preset="signal-flow"] [data-legend-kind][data-legend-selected] [data-legend-hit] { filter: drop-shadow(0 0 4px var(--database-stroke)); }
svg[data-preset="blueprint"] [data-legend-hit], svg[data-preset="blueprint"] [data-legend-count-badge] rect { rx: 0; filter: none; }
svg[data-legend-preview-active] [data-node-id], svg[data-legend-preview-active] [data-edge-from] { opacity: 0.11; }
svg[data-legend-preview-active] [data-legend-preview-match] { opacity: 1; }
svg[data-legend-preview-active] [data-legend-preview-peer] { opacity: 0.62; }
svg[data-legend-preview-active] [data-legend-preview-selected] { filter: drop-shadow(0 0 8px var(--database-stroke)); }
svg[data-lens-active] [data-node-id], svg[data-lens-active] [data-edge-from] { opacity: 0.11; }
svg[data-lens-active] [data-lens-match] { opacity: 1; }
svg[data-lens-active] [data-lens-peer] { opacity: 0.62; }
svg[data-lens-active] [data-lens-selected] { filter: drop-shadow(0 0 10px var(--database-stroke)); }
svg[data-preset="signal-flow"] .semantic-lens-flow { stroke-width: 3.7; opacity: 1; }
svg[data-preset="signal-flow"] .semantic-lens-flow[data-direction="out"], svg[data-preset="signal-flow"] .semantic-lens-flow[data-direction="forward"] { filter: drop-shadow(0 0 6px var(--frontend-stroke)); }
svg[data-preset="signal-flow"] .semantic-lens-flow[data-direction="in"], svg[data-preset="signal-flow"] .semantic-lens-flow[data-direction="reverse"] { filter: drop-shadow(0 0 6px var(--database-stroke)); }
svg[data-preset="signal-flow"] .semantic-lens-flow[data-direction="within"] { filter: drop-shadow(0 0 6px var(--messagebus-stroke)); }
svg[data-preset="blueprint"] .semantic-lens-flow { stroke-width: 2.45; stroke-linecap: square; filter: none; opacity: 0.78; }
svg[data-focus-active] [data-node-id], svg[data-focus-active] [data-edge-from] { opacity: 0.13; }
svg[data-focus-active] [data-focus-match] { opacity: 1; }
svg[data-focus-active] [data-focus-selected] { filter: drop-shadow(0 0 10px var(--frontend-stroke)); }
svg[data-reach-active] [data-node-id], svg[data-reach-active] [data-edge-from] { opacity: 0.09; }
svg[data-reach-active] [data-reach-match] { opacity: 1; }
svg[data-reach-active="upstream"] [data-reach-origin] { filter: drop-shadow(0 0 11px var(--database-stroke)); }
svg[data-reach-active="downstream"] [data-reach-origin] { filter: drop-shadow(0 0 11px var(--backend-stroke)); }
svg[data-reach-active="upstream"] [data-edge-from][data-reach-match] { filter: drop-shadow(0 0 4px color-mix(in srgb, var(--database-stroke) 72%, transparent)); }
svg[data-reach-active="downstream"] [data-edge-from][data-reach-match] { filter: drop-shadow(0 0 4px color-mix(in srgb, var(--backend-stroke) 72%, transparent)); }
svg[data-preset="blueprint"][data-reach-active] [data-reach-origin], svg[data-preset="blueprint"][data-reach-active] [data-edge-from][data-reach-match] { filter: none; }
svg[data-preset="blueprint"] .relationship-hit-target:focus-visible .relationship-focus-rail { stroke-linecap: square; filter: none; }
svg[data-relationship-direct-active] [data-node-id], svg[data-relationship-direct-active] [data-edge-from] { opacity: 0.16; }
svg[data-relationship-direct-active] [data-relationship-preview], svg[data-relationship-direct-active] [data-relationship-preview-node] { opacity: 1; }
svg[data-focus-active]:not([data-relationship-pin-active]) .relationship-hit-rail, svg[data-story-active] .relationship-hit-rail, svg[data-route-picking] .relationship-hit-rail, svg[data-route-active] .relationship-hit-rail, svg[data-lens-active] .relationship-hit-rail, svg[data-chapter-preview] .relationship-hit-rail { pointer-events: none; }
svg[data-relationship-preview-active] [data-focus-match] { opacity: 0.18; }
svg[data-relationship-preview-active] [data-relationship-preview], svg[data-relationship-preview-active] [data-relationship-preview-node] { opacity: 1; }
svg[data-relationship-preview-active] [data-relationship-preview] { filter: drop-shadow(0 0 5px var(--arrow-emphasis)); }
svg[data-relationship-preview-active] [data-relationship-preview] path, svg[data-relationship-preview-active] path[data-relationship-preview], svg[data-relationship-preview-active] [data-relationship-preview] line, svg[data-relationship-preview-active] line[data-relationship-preview], svg[data-relationship-preview-active] [data-relationship-preview] polyline, svg[data-relationship-preview-active] polyline[data-relationship-preview] { stroke-width: 2.75; }
svg[data-relationship-preview-active] [data-relationship-preview-source] { filter: drop-shadow(0 0 7px var(--frontend-stroke)); }
svg[data-relationship-preview-active] [data-relationship-preview-target] { filter: drop-shadow(0 0 7px var(--database-stroke)); }
svg[data-preset="signal-flow"] .relationship-flow-pulse { stroke: var(--frontend-stroke); stroke-width: 3.85; filter: drop-shadow(0 0 7px var(--frontend-stroke)); }
svg[data-preset="blueprint"] .relationship-flow-pulse { stroke-width: 2.5; stroke-linecap: square; filter: none; }
svg[data-preset="editorial"] .relationship-flow-pulse { stroke: var(--arrow-emphasis); stroke-width: 2.75; filter: none; }
svg[data-preset="signal-flow"] .semantic-flow-token { filter: drop-shadow(currentcolor 0px 0px 5px); }
svg[data-preset="blueprint"] .semantic-flow-token { filter: none; }
svg[data-preset="editorial"] .semantic-flow-token { filter: none; }
svg[data-intent-trace-active] [data-node-id], svg[data-intent-trace-active] [data-edge-from] { opacity: 0.2; }
svg[data-intent-trace-active] [data-intent-trace-match] { opacity: 1; }
svg[data-intent-trace-active] [data-intent-trace-selected] { filter: drop-shadow(0 0 10px var(--frontend-stroke)); }
svg[data-preset="blueprint"] [data-intent-trace-selected], svg[data-preset="blueprint"] .intent-trace-flow { filter: none; stroke-linecap: square; }
svg[data-preset="editorial"] [data-intent-trace-selected], svg[data-preset="editorial"] .intent-trace-flow { filter: none; }
svg[data-route-picking="target"] [data-node-id] { opacity: 0.24; }
svg[data-route-picking="target"] [data-route-candidate], svg[data-route-picking="target"] [data-route-start] { opacity: 1; }
svg[data-route-picking] [data-node-id] { cursor: crosshair; }
svg[data-route-picking] [data-route-start] { filter: drop-shadow(0 0 10px var(--frontend-stroke)); }
svg[data-route-active] [data-node-id], svg[data-route-active] [data-edge-from] { opacity: 0.11; }
svg[data-route-active] [data-route-match] { opacity: 1; }
svg[data-route-active] [data-route-start] { filter: drop-shadow(0 0 11px var(--frontend-stroke)); }
svg[data-route-active] [data-route-end] { filter: drop-shadow(0 0 11px var(--security-stroke)); }
svg[data-route-active] [data-route-step]:not([data-route-start]):not([data-route-end]) { filter: drop-shadow(0 0 7px var(--backend-stroke)); }
svg[data-route-journey] [data-route-match][data-route-journey-state="past"] { opacity: 0.62; }
svg[data-route-journey] [data-route-match][data-route-journey-state="future"] { opacity: 0.34; }
svg[data-route-journey] [data-route-match][data-route-journey-state="current"] { opacity: 1; }
svg[data-route-journey] [data-node-id][data-route-journey-current] { filter: drop-shadow(0 0 10px var(--backend-stroke)); }
svg[data-route-journey] [data-edge-from][data-route-journey-current] { opacity: 1; filter: drop-shadow(0 0 6px var(--backend-stroke)); }
svg[data-preset="blueprint"] [data-route-start], svg[data-preset="blueprint"] [data-route-end], svg[data-preset="blueprint"] [data-route-step], svg[data-preset="blueprint"] .route-probe-flow { filter: none; stroke-linecap: square; }
svg[data-preset="blueprint"] .route-journey-flow { filter: none; stroke-linecap: square; }
svg[data-preset="editorial"] [data-route-start], svg[data-preset="editorial"] [data-route-end], svg[data-preset="editorial"] [data-route-step], svg[data-preset="editorial"] .route-probe-flow, svg[data-preset="editorial"] .route-journey-flow { filter: none; }
svg[data-preset="editorial"] .c-grid { stroke-dasharray: 1, 4; opacity: 0.48; }
svg[data-preset="editorial"] .c-region { fill: color-mix(in srgb, var(--cloud-fill) 48%, transparent); stroke-dasharray: 9, 4; }
svg[data-preset="editorial"] [data-node-id]:hover, svg[data-preset="editorial"] [data-node-id]:focus-visible, svg[data-preset="editorial"][data-focus-active] [data-focus-selected] { filter: drop-shadow(0 2px 2px color-mix(in srgb, var(--text) 18%, transparent)); }
svg[data-preset="blueprint"] .c-grid { stroke-dasharray: 1, 3; opacity: 0.78; }
svg[data-preset="blueprint"] .c-region { fill: color-mix(in srgb, var(--cloud-fill) 58%, transparent); stroke-dasharray: 12, 4, 2, 4; }
svg[data-preset="blueprint"] .c-security-group, svg[data-preset="blueprint"] .c-lane { stroke-dasharray: 7, 3; }
svg[data-preset="blueprint"] [data-node-id]:hover, svg[data-preset="blueprint"] [data-node-id]:focus-visible { filter: drop-shadow(0 0 3px var(--frontend-stroke)); }
svg[data-preset="blueprint"][data-focus-active] [data-focus-selected] { filter: drop-shadow(0 0 3px var(--frontend-stroke)); }
svg[data-preset="blueprint"][data-focus-active][data-reach-active] [data-focus-selected][data-reach-origin] { filter: none; }
svg[data-preset="blueprint"][data-relationship-preview-active] [data-relationship-preview], svg[data-preset="blueprint"][data-relationship-preview-active] [data-relationship-preview-source], svg[data-preset="blueprint"][data-relationship-preview-active] [data-relationship-preview-target] { filter: drop-shadow(0 0 3px var(--frontend-stroke)); }
svg[data-story-beat] [data-story-step] { opacity: 0.22; filter: saturate(0.42); transition: opacity 180ms, filter 180ms; }
svg[data-story-beat] [data-story-step][data-story-beat-state="past"] { opacity: 0.72; filter: saturate(0.82); }
svg[data-story-beat] [data-story-step][data-story-beat-state="next"] { opacity: 0.5; filter: saturate(0.66); }
svg[data-story-beat] [data-story-step][data-story-beat-state="active"] { opacity: 1; filter: drop-shadow(0 0 7px var(--frontend-stroke)); animation: 360ms cubic-bezier(0.22, 1, 0.36, 1) 0s 1 normal both running archify-story-beat-node; }
svg[data-story-beat] [data-edge-from][data-story-beat-step] { opacity: 0.16; transition: opacity 160ms; }
svg[data-story-beat] [data-edge-from][data-story-beat-step][data-story-beat-state="past"] { opacity: 0.58; }
svg[data-story-beat] [data-edge-from][data-story-beat-step][data-story-beat-state="next"] { opacity: 0.34; }
svg[data-story-beat] [data-edge-from][data-story-beat-step][data-story-beat-state="active"] { opacity: 1; }
svg[data-story-beat] .story-trail-flow { opacity: 0; transition: opacity 160ms; }
svg[data-story-beat] .story-trail-flow[data-story-beat-state="past"] { opacity: 0.34; }
svg[data-story-beat] .story-trail-flow[data-story-beat-state="next"] { opacity: 0.2; }
svg[data-story-beat] .story-trail-flow[data-story-beat-state="active"] { opacity: 0.92; }
svg[data-story-beat] .story-trail-flow[data-story-pulse="true"] { stroke-dasharray: 2, 13; stroke-dashoffset: 30; opacity: 0.92; animation: 0.78s linear 0s 1 normal both running archify-story-flow; }
svg[data-preset="blueprint"] .story-trail-flow { stroke-linecap: square; filter: none; opacity: 0.5; }
svg[data-preset="blueprint"][data-story-beat] [data-story-step][data-story-beat-state="active"] { filter: none; animation: auto ease 0s 1 normal none running none; }
svg[data-preset="editorial"] .story-trail-flow { filter: none; }
svg[data-preset="editorial"][data-story-beat] [data-story-step][data-story-beat-state="active"] { filter: drop-shadow(0 2px 2px color-mix(in srgb, var(--text) 16%, transparent)); }
svg[data-chapter-preview] [data-node-id], svg[data-chapter-preview] [data-edge-from] { opacity: 0.1 !important; filter: none !important; transition: none !important; }
svg[data-chapter-preview] .story-trail-overlay { opacity: 0.08 !important; }
svg[data-chapter-preview] [data-node-id][data-chapter-preview-role="stay"] { opacity: 0.76 !important; filter: saturate(0.7) !important; }
svg[data-chapter-preview] [data-node-id][data-chapter-preview-role="enter"] { opacity: 1 !important; filter: saturate(1.2) !important; }
svg[data-chapter-preview] [data-node-id][data-chapter-preview-role="leave"] { opacity: 0.28 !important; filter: grayscale(0.72) !important; }
svg[data-preset="blueprint"][data-chapter-preview] [data-node-id] { filter: none !important; }
.c-security-group { fill: transparent; stroke: var(--security-stroke); stroke-dasharray: 4, 4; }
.c-region { fill: rgba(251, 191, 36, 0.05); stroke: var(--cloud-stroke); stroke-dasharray: 8, 4; }
.c-lane { fill: var(--lane-fill); stroke: var(--lane-stroke); stroke-dasharray: 6, 6; }
svg[data-preset="signal-flow"][data-animation="trace"] [data-animate="edge"] { stroke-linecap: round; filter: drop-shadow(0 0 3px var(--arrow-emphasis)); animation-duration: 1.75s; }
svg[data-preset="signal-flow"][data-animation="trace"] [data-animate="node"] { animation-duration: 3.1s; }
svg[data-preset="blueprint"][data-animation="trace"] [data-animate="edge"] { stroke-linecap: square; filter: none; animation-duration: 2.15s; }
svg[data-preset="blueprint"][data-animation="trace"] [data-animate="node"] { animation-name: archify-blueprint-node-pulse; animation-duration: 3.8s; }
svg[data-preset="editorial"][data-animation="trace"] [data-animate="edge"] { filter: none; animation-duration: 2.2s; }
svg[data-preset="editorial"][data-animation="trace"] [data-animate="node"] { animation-name: archify-editorial-node-pulse; animation-duration: 3.5s; }
@keyframes archify-edge-flow { 
  0% { stroke-dasharray: 10, 8; stroke-dashoffset: 54; opacity: 0.42; }
  88% { stroke-dasharray: 10, 8; stroke-dashoffset: 0; opacity: 1; }
  99.9% { stroke-dasharray: 10, 8; stroke-dashoffset: 0; opacity: 1; }
  100% { stroke-dashoffset: 0; opacity: 1; }
}
@keyframes archify-node-pulse { 
  0%, 72%, 100% { filter: none; stroke-width: 1.5; }
  18%, 36% { filter: drop-shadow(0 0 8px var(--arrow-emphasis)); stroke-width: 2.4; }
}
@keyframes archify-blueprint-node-pulse { 
  0%, 72%, 100% { opacity: 1; filter: none; }
  18%, 36% { opacity: 0.72; filter: drop-shadow(0 0 2px var(--frontend-stroke)); }
}
@keyframes archify-editorial-node-pulse { 
  0%, 72%, 100% { opacity: 1; filter: none; }
  18%, 36% { opacity: 0.78; filter: drop-shadow(0 2px 2px color-mix(in srgb, var(--text) 18%, transparent)); }
}
@keyframes archify-signal-scan { 
  0%, 18% { opacity: 1; transform: translateX(-70%); }
  70% { opacity: 1; transform: translateX(70%); }
  100% { opacity: 0; transform: translateX(70%); }
}
@keyframes archify-radar-live { 
  0% { box-shadow: 0 0 0 0 color-mix(in srgb, var(--backend-stroke) 52%, transparent); }
  55%, 100% { box-shadow: transparent 0px 0px 0px 0.32rem; }
}
@keyframes archify-guided-progress { 
  0% { transform: scaleX(var(--guided-progress-start, 0)); }
  100% { transform: scaleX(1); }
}
@keyframes archify-story-flow { 
  100% { stroke-dashoffset: 0; }
}
@keyframes archify-intent-trace-flow { 
  0% { opacity: 0.28; stroke-dashoffset: 0; }
  12%, 78% { opacity: 0.94; }
  100% { opacity: 0; stroke-dashoffset: -1; }
}
@keyframes archify-route-probe-flow { 
  0% { stroke-dashoffset: 0; opacity: 0.96; }
  78% { stroke-dashoffset: -1; opacity: 0.96; }
  100% { stroke-dasharray: none; stroke-dashoffset: 0; opacity: 0.58; }
}
@keyframes archify-route-journey-flow { 
  0% { opacity: 0.16; stroke-dashoffset: 0; }
  14%, 76% { opacity: 1; }
  100% { opacity: 0; stroke-dashoffset: -1; }
}
@keyframes archify-semantic-lens-flow { 
  0% { opacity: 0.2; stroke-dashoffset: 0; }
  12%, 78% { opacity: 0.9; }
  100% { opacity: 0; stroke-dashoffset: -1; }
}
@keyframes archify-relationship-pulse { 
  0% { opacity: 0.18; stroke-dashoffset: 0; }
  10%, 76% { opacity: 0.98; }
  100% { opacity: 0; stroke-dashoffset: -1; }
}
@keyframes archify-relationship-token-life { 
  0%, 7% { opacity: 0; }
  13%, 82% { opacity: 1; }
  100% { opacity: 0; }
}
@keyframes archify-story-beat-node { 
  0% { opacity: 0.48; filter: saturate(0.6); }
  58% { opacity: 1; filter: drop-shadow(0 0 10px var(--frontend-stroke)); }
  100% { opacity: 1; filter: drop-shadow(0 0 7px var(--frontend-stroke)); }
}
@keyframes archify-share-cue-enter { 
  0% { opacity: 0; transform: translate(-50%, -0.45rem); }
  100% { opacity: 1; transform: translate(-50%, 0px); }
}
@keyframes archify-share-cue-pulse { 
  0%, 100% { opacity: 1; transform: scale(1); }
  50% { opacity: 0.48; transform: scale(0.78); }
}
:root, svg { --bg: #020617; --grid: #1e293b; --text: #ffffff; --text-muted: #94a3b8; --text-dim: #475569; --text-faint: #7d8da1; --panel: rgba(15, 23, 42, 0.5); --panel-border: #1e293b; --lane-fill: rgba(15, 23, 42, 0.22); --lane-stroke: #334155; --arrow: #64748b; --arrow-emphasis: #34d399; --mask: #0f172a; --frontend-fill: rgba(8, 51, 68, 0.4); --frontend-stroke: #22d3ee; --backend-fill: rgba(6, 78, 59, 0.4); --backend-stroke: #34d399; --database-fill: rgba(76, 29, 149, 0.4); --database-stroke: #a78bfa; --cloud-fill: rgba(120, 53, 15, 0.3); --cloud-stroke: #fbbf24; --security-fill: rgba(136, 19, 55, 0.4); --security-stroke: #fb7185; --messagebus-fill: rgba(251, 146, 60, 0.3); --messagebus-stroke: #fb923c; --external-fill: rgba(30, 41, 59, 0.5); --external-stroke: #94a3b8; --toolbar-bg: rgba(15, 23, 42, 0.8); --toolbar-border: #334155; --toolbar-text: #e2e8f0; --toolbar-hover: rgba(15, 23, 42, 0.95); --toolbar-menu-bg: #0f172a; }
@media (prefers-color-scheme: light) { :root, svg { --bg: #f8fafc; --grid: #e2e8f0; --text: #0f172a; --text-muted: #64748b; --text-dim: #94a3b8; --text-faint: #64748b; --panel: #ffffff; --panel-border: #e2e8f0; --lane-fill: rgba(248, 250, 252, 0.65); --lane-stroke: #cbd5e1; --arrow: #94a3b8; --arrow-emphasis: #059669; --mask: #ffffff; --frontend-fill: rgba(34, 211, 238, 0.15); --frontend-stroke: #0891b2; --backend-fill: rgba(52, 211, 153, 0.18); --backend-stroke: #059669; --database-fill: rgba(167, 139, 250, 0.2); --database-stroke: #7c3aed; --cloud-fill: rgba(251, 191, 36, 0.18); --cloud-stroke: #d97706; --security-fill: rgba(251, 113, 133, 0.15); --security-stroke: #e11d48; --messagebus-fill: rgba(251, 146, 60, 0.15); --messagebus-stroke: #ea580c; --external-fill: rgba(148, 163, 184, 0.18); --external-stroke: #64748b; --toolbar-bg: rgba(255, 255, 255, 0.92); --toolbar-border: #cbd5e1; --toolbar-text: #334155; --toolbar-hover: #ffffff; --toolbar-menu-bg: #ffffff; } }
svg[data-theme="light"] { --bg: #f8fafc; --grid: #e2e8f0; --text: #0f172a; --text-muted: #64748b; --text-dim: #94a3b8; --text-faint: #64748b; --panel: #ffffff; --panel-border: #e2e8f0; --lane-fill: rgba(248, 250, 252, 0.65); --lane-stroke: #cbd5e1; --arrow: #94a3b8; --arrow-emphasis: #059669; --mask: #ffffff; --frontend-fill: rgba(34, 211, 238, 0.15); --frontend-stroke: #0891b2; --backend-fill: rgba(52, 211, 153, 0.18); --backend-stroke: #059669; --database-fill: rgba(167, 139, 250, 0.2); --database-stroke: #7c3aed; --cloud-fill: rgba(251, 191, 36, 0.18); --cloud-stroke: #d97706; --security-fill: rgba(251, 113, 133, 0.15); --security-stroke: #e11d48; --messagebus-fill: rgba(251, 146, 60, 0.15); --messagebus-stroke: #ea580c; --external-fill: rgba(148, 163, 184, 0.18); --external-stroke: #64748b; --toolbar-bg: rgba(255, 255, 255, 0.92); --toolbar-border: #cbd5e1; --toolbar-text: #334155; --toolbar-hover: #ffffff; --toolbar-menu-bg: #ffffff; }
svg[data-theme="dark"] { --bg: #020617; --grid: #1e293b; --text: #ffffff; --text-muted: #94a3b8; --text-dim: #475569; --text-faint: #7d8da1; --panel: rgba(15, 23, 42, 0.5); --panel-border: #1e293b; --lane-fill: rgba(15, 23, 42, 0.22); --lane-stroke: #334155; --arrow: #64748b; --arrow-emphasis: #34d399; --mask: #0f172a; --frontend-fill: rgba(8, 51, 68, 0.4); --frontend-stroke: #22d3ee; --backend-fill: rgba(6, 78, 59, 0.4); --backend-stroke: #34d399; --database-fill: rgba(76, 29, 149, 0.4); --database-stroke: #a78bfa; --cloud-fill: rgba(120, 53, 15, 0.3); --cloud-stroke: #fbbf24; --security-fill: rgba(136, 19, 55, 0.4); --security-stroke: #fb7185; --messagebus-fill: rgba(251, 146, 60, 0.3); --messagebus-stroke: #fb923c; --external-fill: rgba(30, 41, 59, 0.5); --external-stroke: #94a3b8; --toolbar-bg: rgba(15, 23, 42, 0.8); --toolbar-border: #334155; --toolbar-text: #e2e8f0; --toolbar-hover: rgba(15, 23, 42, 0.95); --toolbar-menu-bg: #0f172a; }
rect.c-bg-rect { fill: var(--bg); }
</style><rect width="100%" height="100%" class="c-bg-rect"/>
        <title id="archify-diagram-title">Soundscape Canvas 系统架构</title>
        <desc id="archify-diagram-description">由 Archify 生成的架构图。</desc>
        <!-- Definitions -->
        <defs>
          <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
            <polygon points="0 0, 10 3.5, 0 7" class="m-default"/>
          </marker>
          <marker id="arrowhead-emphasis" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
            <polygon points="0 0, 10 3.5, 0 7" class="m-emphasis"/>
          </marker>
          <marker id="arrowhead-security" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
            <polygon points="0 0, 10 3.5, 0 7" class="m-security"/>
          </marker>
          <marker id="arrowhead-dashed" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
            <polygon points="0 0, 10 3.5, 0 7" class="m-dashed"/>
          </marker>
          <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">
            <path d="M 40 0 L 0 0 0 40" class="c-grid" stroke-width="0.5"/>
          </pattern>
        </defs>

        <!-- Background Grid -->
        <rect width="100%" height="100%" fill="url(#grid)"/>

        <!-- Boundaries (behind everything) -->
        <rect data-graph-role="structural-frame" data-composition-frame-kind="region" data-composition-frame-id="0" data-composition-frame-label="旋律分析管线 · 后台 Task" x="244" y="316" width="692" height="120" rx="12" class="c-region" stroke-width="1"/>

        <!-- Connection paths (before components for correct z-order) -->
        <path data-edge-from="znnu-api" data-edge-to="audio-input" data-edge-label="歌曲下载" data-edge-key="0" data-composition-points="120,340;120,196" d="M 120 340 L 120 196" class="a-dashed" stroke-width="1.5" marker-end="url(#arrowhead-dashed)"/>
        <path data-edge-from="audio-input" data-edge-to="audio-loader" data-edge-label="音频文件" data-edge-key="1" data-composition-points="200,158;270,158" d="M 200 158 L 270 158" class="a-emphasis" stroke-width="1.8" marker-end="url(#arrowhead-emphasis)"/>
        <path data-edge-from="audio-loader" data-edge-to="playback-engine" data-edge-label="PCM 缓冲" data-edge-key="2" data-composition-points="420,158;490,158" d="M 420 158 L 490 158" class="a-default" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        <path data-edge-from="audio-loader" data-edge-to="analysis-service" data-edge-label="单声道采样" data-edge-key="3" data-composition-points="345,196;345,340" d="M 345 196 L 345 340" class="a-dashed" stroke-width="1.5" marker-end="url(#arrowhead-dashed)"/>
        <path data-edge-from="analysis-service" data-edge-to="basicpitch" data-edge-label="22050 Hz 分窗" data-edge-key="4" data-composition-points="430,378;510,378" d="M 430 378 L 510 378" class="a-default" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        <path data-edge-from="basicpitch" data-edge-to="voice-separator" data-edge-label="帧谱输出" data-edge-key="5" data-composition-points="670,378;740,378" d="M 670 378 L 740 378" class="a-default" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        <path data-edge-from="voice-separator" data-edge-to="app-viewmodel" data-edge-label="MelodyData" data-edge-key="6" data-composition-points="920,378;970,378" d="M 920 378 L 970 378" class="a-dashed" stroke-width="1.5" marker-end="url(#arrowhead-dashed)"/>
        <path data-edge-from="playback-engine" data-edge-to="app-viewmodel" data-edge-label="engineTime 时钟" data-edge-key="7" data-composition-points="575,196;575,268;1055,268;1055,340" d="M 575 196 L 575 260 Q 575 268 583 268 L 1047 268 Q 1055 268 1055 276 L 1055 340" class="a-default" stroke-width="1.5" marker-end="url(#arrowhead)"/>
        <path data-edge-from="app-viewmodel" data-edge-to="piano-roll" data-edge-label="melody · 播放状态" data-edge-key="8" data-composition-points="1055,416;1055,440;1071,440;1071,536;1050,536;1050,560" d="M 1055 416 L 1055 432 Q 1055 440 1063 440 L 1063 440 Q 1071 440 1071 448 L 1071 528 Q 1071 536 1063 536 L 1058 536 Q 1050 536 1050 544 L 1050 560" class="a-emphasis" stroke-width="1.8" marker-end="url(#arrowhead-emphasis)"/>
        <path data-edge-from="piano-roll" data-edge-to="video-exporter" data-edge-label="drawPianoRoll 同源" data-edge-key="9" data-composition-points="970,598;910,598" d="M 970 598 L 910 598" class="a-emphasis" stroke-width="1.8" marker-end="url(#arrowhead-emphasis)"/>
        <path data-edge-from="video-exporter" data-edge-to="share" data-edge-label="MP4 产物" data-edge-key="10" data-composition-points="730,598;640,598" d="M 730 598 L 640 598" class="a-emphasis" stroke-width="1.8" marker-end="url(#arrowhead-emphasis)"/>

        <!-- Components -->
        <g id="node-audio-input" data-node-id="audio-input" data-node-label="音频来源" tabindex="0" role="button" aria-label="聚焦音频来源，本地导入 / 在线搜索, 架构组件" aria-pressed="false" data-node-kind="external" data-node-sublabel="本地导入 / 在线搜索" data-node-context="架构组件">
          <title>音频来源 · 本地导入 / 在线搜索 · 架构组件</title>
          <rect x="40" y="120" width="160" height="76" rx="6" class="c-mask"/>
          <rect x="40" y="120" width="160" height="76" rx="6" class="c-external" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="external" class="semantic-sigil s-external" transform="translate(46 126) scale(0.6875)">
            <rect x="2.5" y="5" width="8.5" height="8" rx="1.5"/>
            <path d="M8 2.5h5.5V8M13.5 2.5 7.5 8.5"/>
          </g>
          <text data-node-label="" x="120" y="156" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">音频来源</text>
        <text x="120" y="172" class="t-muted" font-size="9" text-anchor="middle">本地导入 / 在线搜索</text>
        </g>

        <g id="node-audio-loader" data-node-id="audio-loader" data-node-label="AudioLoader" tabindex="0" role="button" aria-label="聚焦AudioLoader，AVAudioFile 解码, 架构组件" aria-pressed="false" data-node-kind="backend" data-node-sublabel="AVAudioFile 解码" data-node-context="架构组件">
          <title>AudioLoader · AVAudioFile 解码 · 架构组件</title>
          <rect x="270" y="120" width="150" height="76" rx="6" class="c-mask"/>
          <rect x="270" y="120" width="150" height="76" rx="6" class="c-backend" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="backend" class="semantic-sigil s-backend" transform="translate(276 126) scale(0.6875)">
            <path d="M6 3 3 8l3 5M10 3l3 5-3 5"/>
          </g>
          <text data-node-label="" x="345" y="156" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">AudioLoader</text>
        <text x="345" y="172" class="t-muted" font-size="9" text-anchor="middle">AVAudioFile 解码</text>
        </g>

        <g id="node-playback-engine" data-node-id="playback-engine" data-node-label="PlaybackEngine" tabindex="0" role="button" aria-label="聚焦PlaybackEngine，采样级精确播放, 架构组件" aria-pressed="false" data-node-kind="backend" data-node-sublabel="采样级精确播放" data-node-context="架构组件">
          <title>PlaybackEngine · 采样级精确播放 · 架构组件</title>
          <rect x="490" y="120" width="170" height="76" rx="6" class="c-mask"/>
          <rect x="490" y="120" width="170" height="76" rx="6" class="c-backend" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="backend" class="semantic-sigil s-backend" transform="translate(496 126) scale(0.6875)">
            <path d="M6 3 3 8l3 5M10 3l3 5-3 5"/>
          </g>
          <text data-node-label="" x="575" y="156" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">PlaybackEngine</text>
        <text x="575" y="172" class="t-muted" font-size="9" text-anchor="middle">采样级精确播放</text>
        </g>

        <g id="node-znnu-api" data-node-id="znnu-api" data-node-label="聚合搜索服务" tabindex="0" role="button" aria-label="聚焦聚合搜索服务，music.znnu.com, 架构组件" aria-pressed="false" data-node-kind="external" data-node-sublabel="music.znnu.com" data-node-context="架构组件">
          <title>聚合搜索服务 · music.znnu.com · 架构组件</title>
          <rect x="40" y="340" width="160" height="76" rx="6" class="c-mask"/>
          <rect x="40" y="340" width="160" height="76" rx="6" class="c-external" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="external" class="semantic-sigil s-external" transform="translate(46 346) scale(0.6875)">
            <rect x="2.5" y="5" width="8.5" height="8" rx="1.5"/>
            <path d="M8 2.5h5.5V8M13.5 2.5 7.5 8.5"/>
          </g>
          <text data-node-label="" x="120" y="376" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">聚合搜索服务</text>
        <text x="120" y="392" class="t-muted" font-size="9" text-anchor="middle">music.znnu.com</text>
        </g>

        <g id="node-analysis-service" data-node-id="analysis-service" data-node-label="MelodyAnalysisService" tabindex="0" role="button" aria-label="聚焦MelodyAnalysisService，重采样 · 管线编排, 旋律分析管线 · 后台 Task" aria-pressed="false" data-node-kind="backend" data-node-sublabel="重采样 · 管线编排" data-node-context="旋律分析管线 · 后台 Task">
          <title>MelodyAnalysisService · 重采样 · 管线编排 · 旋律分析管线 · 后台 Task</title>
          <rect x="260" y="340" width="170" height="76" rx="6" class="c-mask"/>
          <rect x="260" y="340" width="170" height="76" rx="6" class="c-backend" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="backend" class="semantic-sigil s-backend" transform="translate(266 346) scale(0.6875)">
            <path d="M6 3 3 8l3 5M10 3l3 5-3 5"/>
          </g>
          <text data-node-label="" x="345" y="376" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">MelodyAnalysisService</text>
        <text x="345" y="392" class="t-muted" font-size="9" text-anchor="middle">重采样 · 管线编排</text>
        </g>

        <g id="node-basicpitch" data-node-id="basicpitch" data-node-label="Basic Pitch CoreML" tabindex="0" role="button" aria-label="聚焦Basic Pitch CoreML，nmp.mlpackage 推理, 旋律分析管线 · 后台 Task" aria-pressed="false" data-node-kind="database" data-node-sublabel="nmp.mlpackage 推理" data-node-context="旋律分析管线 · 后台 Task">
          <title>Basic Pitch CoreML · nmp.mlpackage 推理 · 旋律分析管线 · 后台 Task</title>
          <rect x="510" y="340" width="160" height="76" rx="6" class="c-mask"/>
          <rect x="510" y="340" width="160" height="76" rx="6" class="c-database" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="database" class="semantic-sigil s-database" transform="translate(516 346) scale(0.6875)">
            <ellipse cx="8" cy="4" rx="5" ry="2"/>
            <path d="M3 4v8c0 1.1 2.2 2 5 2s5-.9 5-2V4M3 8c0 1.1 2.2 2 5 2s5-.9 5-2"/>
          </g>
          <text data-node-label="" x="590" y="376" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">Basic Pitch CoreML</text>
        <text x="590" y="392" class="t-muted" font-size="9" text-anchor="middle">nmp.mlpackage 推理</text>
        </g>

        <g id="node-voice-separator" data-node-id="voice-separator" data-node-label="VoiceSeparator" tabindex="0" role="button" aria-label="聚焦VoiceSeparator，音符解码 · 声部分离, 旋律分析管线 · 后台 Task" aria-pressed="false" data-node-kind="backend" data-node-sublabel="音符解码 · 声部分离" data-node-context="旋律分析管线 · 后台 Task">
          <title>VoiceSeparator · 音符解码 · 声部分离 · 旋律分析管线 · 后台 Task</title>
          <rect x="740" y="340" width="180" height="76" rx="6" class="c-mask"/>
          <rect x="740" y="340" width="180" height="76" rx="6" class="c-backend" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="backend" class="semantic-sigil s-backend" transform="translate(746 346) scale(0.6875)">
            <path d="M6 3 3 8l3 5M10 3l3 5-3 5"/>
          </g>
          <text data-node-label="" x="830" y="376" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">VoiceSeparator</text>
        <text x="830" y="392" class="t-muted" font-size="9" text-anchor="middle">音符解码 · 声部分离</text>
        </g>

        <g id="node-app-viewmodel" data-node-id="app-viewmodel" data-node-label="AppViewModel" tabindex="0" role="button" aria-label="聚焦AppViewModel，@MainActor 状态机, 架构组件" aria-pressed="false" data-node-kind="frontend" data-node-sublabel="@MainActor 状态机" data-node-context="架构组件">
          <title>AppViewModel · @MainActor 状态机 · 架构组件</title>
          <rect x="970" y="340" width="170" height="76" rx="6" class="c-mask"/>
          <rect x="970" y="340" width="170" height="76" rx="6" class="c-frontend" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="frontend" class="semantic-sigil s-frontend" transform="translate(976 346) scale(0.6875)">
            <rect x="2" y="3" width="12" height="10" rx="2"/>
            <path d="M2 6.5h12"/>
            <circle cx="4.1" cy="4.8" r=".7" class="sigil-fill"/>
            <circle cx="6.3" cy="4.8" r=".7" class="sigil-fill"/>
          </g>
          <text data-node-label="" x="1055" y="376" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">AppViewModel</text>
        <text x="1055" y="392" class="t-muted" font-size="9" text-anchor="middle">@MainActor 状态机</text>
        </g>

        <g id="node-piano-roll" data-node-id="piano-roll" data-node-label="PianoRollRenderer" tabindex="0" role="button" aria-label="聚焦PianoRollRenderer，纯函数钢琴卷帘, 架构组件" aria-pressed="false" data-node-kind="frontend" data-node-sublabel="纯函数钢琴卷帘" data-node-context="架构组件">
          <title>PianoRollRenderer · 纯函数钢琴卷帘 · 架构组件</title>
          <rect x="970" y="560" width="160" height="76" rx="6" class="c-mask"/>
          <rect x="970" y="560" width="160" height="76" rx="6" class="c-frontend" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="frontend" class="semantic-sigil s-frontend" transform="translate(976 566) scale(0.6875)">
            <rect x="2" y="3" width="12" height="10" rx="2"/>
            <path d="M2 6.5h12"/>
            <circle cx="4.1" cy="4.8" r=".7" class="sigil-fill"/>
            <circle cx="6.3" cy="4.8" r=".7" class="sigil-fill"/>
          </g>
          <text data-node-label="" x="1050" y="596" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">PianoRollRenderer</text>
        <text x="1050" y="612" class="t-muted" font-size="9" text-anchor="middle">纯函数钢琴卷帘</text>
        </g>

        <g id="node-video-exporter" data-node-id="video-exporter" data-node-label="VideoExporter" tabindex="0" role="button" aria-label="聚焦VideoExporter，AVAssetWriter 渲染, 架构组件" aria-pressed="false" data-node-kind="backend" data-node-sublabel="AVAssetWriter 渲染" data-node-context="架构组件">
          <title>VideoExporter · AVAssetWriter 渲染 · 架构组件</title>
          <rect x="730" y="560" width="180" height="76" rx="6" class="c-mask"/>
          <rect x="730" y="560" width="180" height="76" rx="6" class="c-backend" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="backend" class="semantic-sigil s-backend" transform="translate(736 566) scale(0.6875)">
            <path d="M6 3 3 8l3 5M10 3l3 5-3 5"/>
          </g>
          <text data-node-label="" x="820" y="596" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">VideoExporter</text>
        <text x="820" y="612" class="t-muted" font-size="9" text-anchor="middle">AVAssetWriter 渲染</text>
        </g>

        <g id="node-share" data-node-id="share" data-node-label="系统分享面板" tabindex="0" role="button" aria-label="聚焦系统分享面板，相册 / 文件, 架构组件" aria-pressed="false" data-node-kind="external" data-node-sublabel="相册 / 文件" data-node-context="架构组件">
          <title>系统分享面板 · 相册 / 文件 · 架构组件</title>
          <rect x="480" y="560" width="160" height="76" rx="6" class="c-mask"/>
          <rect x="480" y="560" width="160" height="76" rx="6" class="c-external" stroke-width="1.5"/>
          <g aria-hidden="true" data-semantic-sigil="external" class="semantic-sigil s-external" transform="translate(486 566) scale(0.6875)">
            <rect x="2.5" y="5" width="8.5" height="8" rx="1.5"/>
            <path d="M8 2.5h5.5V8M13.5 2.5 7.5 8.5"/>
          </g>
          <text data-node-label="" x="560" y="596" class="t-primary" font-size="11" font-weight="600" text-anchor="middle">系统分享面板</text>
        <text x="560" y="612" class="t-muted" font-size="9" text-anchor="middle">相册 / 文件</text>
        </g>

        <!-- Connection labels -->
        <g data-edge-from="znnu-api" data-edge-to="audio-input" data-edge-label="歌曲下载" data-edge-key="0">
          <rect x="95.8" y="320" width="48.4" height="14" rx="3" class="c-mask"/>
          <text x="120" y="330" class="t-messagebus" font-size="8" text-anchor="middle">歌曲下载</text>
        </g>
        <g data-edge-from="audio-input" data-edge-to="audio-loader" data-edge-label="音频文件" data-edge-key="1">
          <rect x="210.8" y="138" width="48.4" height="14" rx="3" class="c-mask"/>
          <text x="235" y="148" class="t-backend" font-size="8" text-anchor="middle">音频文件</text>
        </g>
        <g data-edge-from="audio-loader" data-edge-to="playback-engine" data-edge-label="PCM 缓冲" data-edge-key="2">
          <rect x="430.8" y="138" width="48.4" height="14" rx="3" class="c-mask"/>
          <text x="455" y="148" class="t-muted" font-size="8" text-anchor="middle">PCM 缓冲</text>
        </g>
        <g data-edge-from="audio-loader" data-edge-to="analysis-service" data-edge-label="单声道采样" data-edge-key="3">
          <rect x="316" y="230" width="58" height="14" rx="3" class="c-mask"/>
          <text x="345" y="240" class="t-messagebus" font-size="8" text-anchor="middle">单声道采样</text>
        </g>
        <g data-edge-from="analysis-service" data-edge-to="basicpitch" data-edge-label="22050 Hz 分窗" data-edge-key="4">
          <rect x="433.8" y="358" width="72.4" height="14" rx="3" class="c-mask"/>
          <text x="470" y="368" class="t-muted" font-size="8" text-anchor="middle">22050 Hz 分窗</text>
        </g>
        <g data-edge-from="basicpitch" data-edge-to="voice-separator" data-edge-label="帧谱输出" data-edge-key="5">
          <rect x="680.8" y="358" width="48.4" height="14" rx="3" class="c-mask"/>
          <text x="705" y="368" class="t-muted" font-size="8" text-anchor="middle">帧谱输出</text>
        </g>
        <g data-edge-from="voice-separator" data-edge-to="app-viewmodel" data-edge-label="MelodyData" data-edge-key="6">
          <rect x="916" y="470" width="58" height="14" rx="3" class="c-mask"/>
          <text x="945" y="480" class="t-messagebus" font-size="8" text-anchor="middle">MelodyData</text>
        </g>
        <g data-edge-from="playback-engine" data-edge-to="app-viewmodel" data-edge-label="engineTime 时钟" data-edge-key="7">
          <rect x="774" y="248" width="82" height="14" rx="3" class="c-mask"/>
          <text x="815" y="258" class="t-muted" font-size="8" text-anchor="middle">engineTime 时钟</text>
        </g>
        <g data-edge-from="app-viewmodel" data-edge-to="piano-roll" data-edge-label="melody · 播放状态" data-edge-key="8">
          <rect x="1017.2" y="420" width="91.6" height="14" rx="3" class="c-mask"/>
          <text x="1063" y="430" class="t-backend" font-size="8" text-anchor="middle">melody · 播放状态</text>
        </g>
        <g data-edge-from="piano-roll" data-edge-to="video-exporter" data-edge-label="drawPianoRoll 同源" data-edge-key="9">
          <rect x="891.8" y="640" width="96.39999999999999" height="14" rx="3" class="c-mask"/>
          <text x="940" y="650" class="t-backend" font-size="8" text-anchor="middle">drawPianoRoll 同源</text>
        </g>
        <g data-edge-from="video-exporter" data-edge-to="share" data-edge-label="MP4 产物" data-edge-key="10">
          <rect x="660.8" y="578" width="48.4" height="14" rx="3" class="c-mask"/>
          <text x="685" y="588" class="t-backend" font-size="8" text-anchor="middle">MP4 产物</text>
        </g>

        <!-- Boundary labels (foreground masks keep routes out of titles) -->
        <g data-graph-role="structural-frame-label" data-composition-frame-id="0" data-composition-frame-kind="region" data-composition-frame-label="旋律分析管线 · 后台 Task">
          <rect data-graph-role="structural-frame-label-mask" x="248" y="320" width="139.6" height="16" rx="3" class="c-mask"/>
          <text data-boundary-label="" x="252" y="333" class="t-cloud" font-size="9" font-weight="600">旋律分析管线 · 后台 Task</text>
        </g>

        <!-- Legend -->
        <g data-legend="">
          <text x="40" y="664" class="t-primary" font-size="12" font-weight="650">图例</text>
          <g data-legend-semantic-kind="frontend" data-legend-x="40" data-legend-baseline="684" data-legend-width="63">
            <rect x="40" y="675" width="16" height="10" rx="2.5" class="c-frontend" stroke-width="1"/>
            <text x="62" y="684" class="t-muted" font-size="10" font-weight="500">前端</text>
          </g>
          <g data-legend-semantic-kind="backend" data-legend-x="125" data-legend-baseline="684" data-legend-width="63">
            <rect x="125" y="675" width="16" height="10" rx="2.5" class="c-backend" stroke-width="1"/>
            <text x="147" y="684" class="t-muted" font-size="10" font-weight="500">后端</text>
          </g>
          <g data-legend-semantic-kind="database" data-legend-x="210" data-legend-baseline="684" data-legend-width="73">
            <rect x="210" y="675" width="16" height="10" rx="2.5" class="c-database" stroke-width="1"/>
            <text x="232" y="684" class="t-muted" font-size="10" font-weight="500">数据库</text>
          </g>
          <g data-legend-semantic-kind="external" data-legend-x="305" data-legend-baseline="684" data-legend-width="83">
            <rect x="305" y="675" width="16" height="10" rx="2.5" class="c-external" stroke-width="1"/>
            <text x="327" y="684" class="t-muted" font-size="10" font-weight="500">外部系统</text>
          </g>
        </g>
      </svg>scape-canvas.svg…]()



两个实现上比较得意的地方：一是画布和视频导出共用同一个纯函数渲染器 PianoRollRenderer，所见即所得，导出画面不会和 App 里看到的有出入；二是播放时钟直接从 AVAudioEngine 的渲染时钟推导，精度到采样级，不用 Timer 插值，画面和音乐不会漂。

## 快速开始

环境要求：

| 依赖 | 版本 |
|---|---|
| macOS（开发机） | 15.0 以上 |
| Xcode | 26.0 以上 |
| 目标系统 | iOS / iPadOS 26.5 以上 |

没有任何第三方依赖，SPM、CocoaPods 都不用碰。Basic Pitch 模型已经放在仓库里（nmp.mlpackage），Xcode 会自动编译进 App，拿到代码直接构建就能跑：

```bash
open "Soundscape Canvas/SoundscapeCanvas/SoundscapeCanvas.xcodeproj"
```

在 Xcode 里选个模拟器或真机，⌘R 运行。

## 怎么用

1. 首页点「导入音频」从文件 App 里选一首，或者点「在线搜索」按歌名 / 歌手找一首下载
2. 导入完成马上就能播，拖底部进度条可以跳转，不用等分析
3. 等旋律分析跑完（有进度），双色钢琴卷帘会自动出现在画布上
4. 点分享按钮开始渲染视频，完成后弹系统分享面板；渲染期间随时可以取消

## 项目结构

```text
.
├── README.md
├── CHANGELOG.md
├── LICENSE
├── docs/                            # 架构图与截图
└── Soundscape Canvas/
    └── SoundscapeCanvas/
        ├── SoundscapeCanvas.xcodeproj
        ├── SoundscapeCanvas/        # App 源码
        │   ├── Audio/               # 解码装载与播放引擎
        │   ├── Melody/              # 旋律分析管线（重采样 / 推理 / 解码 / 声部分离）
        │   ├── Model/               # 主状态机与数据模型
        │   ├── Music/               # 在线搜索、下载与 API 客户端
        │   ├── Render/              # 离屏视频导出引擎
        │   ├── Views/               # SwiftUI 界面、画布与播放控制
        │   └── Resources/BasicPitch/# Basic Pitch CoreML 模型
        ├── SoundscapeCanvasTests/   # 单元 / 端到端 / 性能基准测试
        └── SoundscapeCanvasUITests/ # UI 测试
```

## 核心模块

| 模块 | 位置 | 干什么的 |
|---|---|---|
| AudioLoader | Audio/ | 用 AVAudioFile 把文件解成 PCM 缓冲和单声道采样，CPU 密集，放后台跑 |
| PlaybackEngine | Audio/ | AVAudioEngine 加 AVAudioPlayerNode。播放、暂停、跳转都走「停 → 重设偏移 → 重新调度」这一条路，不会叠出重复声音；时钟可被每帧高频查询 |
| MelodyAnalysisService | Melody/ | 分析管线编排：线性重采样到 22050 Hz，分窗推理，音符解码，弯音提取。全程支持取消 |
| BasicPitchInference | Melody/ | Basic Pitch 的 CoreML 分窗推理，常量和求值顺序逐字对齐 Spotify 官方实现 |
| NoteDecoder | Melody/ | outputToNotesPoly 音符解码：onset 0.5、frame 0.3 双阈值，最短音符 5 帧，频率界 55 到 1760 Hz |
| VoiceSeparator | Melody/ | 主副旋律分离：声学显著度加 beam 轨迹追踪，再加旋律链拼接。低音硬排除，近重复抑制 |
| PianoRollRenderer | Views/ | 纯函数渲染器，App 画布和视频逐帧渲染共用同一份代码 |
| VideoExporter | Render/ | AVAssetWriter 离屏逐帧渲染。分辨率取屏幕物理像素，30fps H.264；音轨用 async let 并行写，避免 muxer 死锁；支持协作式取消 |
| ZnnuAPIClient | Music/ | 聚合搜索客户端，actor 隔离，签名和解密是纯函数，有单测复算 |
| AppViewModel | Model/ | 主状态机：导入、装载、播放、分析、导出全在这收敛。用 generation 计数丢弃过期的异步结果 |

## 测试

Xcode 里 ⌘U 跑全部测试，或者命令行：

```bash
xcodebuild test -project "Soundscape Canvas/SoundscapeCanvas/SoundscapeCanvas.xcodeproj" \
  -scheme SoundscapeCanvas -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

覆盖了音符解码、线性重采样、声部分离算法、API 签名解密复算这些单元测试，也有一条真实音频的端到端链路（分析、双声部基准、导出产物检查）和性能基准。

## 贡献

欢迎提 Issue 和 PR。几个约定：

- 一个 PR 聚焦一件事，从 main 拉功能分支
- 代码遵循 Swift API 设计指南；不写强制解包（IBOutlet 和明确的静态常量除外）
- 并发用 async/await、Task 和 TaskGroup；数据模型用 struct 加 Codable，不用字典传数据
- 注释写中文，说清楚为什么，不只是做了什么
- 新功能请带测试，提交前确保全部测试通过

## 许可证

本项目以 GNU General Public License v3.0（GPLv3）开源，完整文本见随源码附带的 LICENSE 文件。

可以自由使用、学习、修改和再分发，但基于本项目的二次分发（包括修改版）必须同样以 GPLv3 开源，并保留版权声明。

## 致谢

- Spotify Basic Pitch：轻量级音频转 MIDI 模型。本项目打包的 CoreML 模型和分窗推理逻辑逐字对齐它的官方实现
- Apple：SwiftUI、AVFoundation、CoreML、CryptoKit，好用的系统框架省了大量轮子

## 免责声明

- 在线搜索基于第三方公开聚合接口（music.znnu.com）。本项目不存储、不缓存、不再分发任何音乐文件
- 所有音乐的版权归原作者及相关权利人所有。搜索与下载功能仅供个人学习、研究和技术交流，严禁商用
- 请支持正版，欣赏完整作品请去正版流媒体平台
- 使用本项目产生的任何法律风险由使用者自行承担
