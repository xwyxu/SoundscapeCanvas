
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
<img width="4800" height="2800" alt="soundscape-canvas" src="https://github.com/user-attachments/assets/0b52d036-4621-41ed-a143-4f659ed228f5" />


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
