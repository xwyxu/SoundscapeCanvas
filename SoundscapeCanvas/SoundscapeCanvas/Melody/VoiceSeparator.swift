//
//  VoiceSeparator.swift
//  SoundscapeCanvas
//
//  声部分离纯函数 —— 主/副旋律双声部识别
//  （spec: .trae/specs/detect-main-countermelody/spec.md「声部分离算法设计」章节）
//
//  双路径设计（v7，轨迹级追踪，spec: .trae/specs/track-melody-trajectories）：
//  【DSP 主路径】acousticSalience 非空时（真实分析管线）：beam 轨迹追踪双遍——
//    音符组按 start 升序分簇、簇内显著度降序处理（同拍声部竞争显著度高者先
//    占坑）；每组按转移代价（w1·音高距离 + w2·走势二阶突变 + w3·断线罚，
//    八度条件豁免）延续最优轨迹或新开轨迹；显著度主导保护：归一化显著度差
//    ≥0.1 的槽位竞争显著度必胜，转移代价只裁决显著度接近的归属（逐拍 argmax
//    v6 的教训反证：确定性主信号下转移代价会引入八度跳进歧视——melody 60→72
//    距离 12 输给跨声部级进 60→62 距离 2，故代价必须条件化且不得压过 0.1 量级
//    的显著度差）；主旋律 = Σ显著度×连续覆盖最高轨迹（合并视图成员共享角色，
//    回写原始音符）；掩码（melody + 高八度幽灵：重叠 >50%、音高高于旋律音符、
//    音高类距离 ≤2——谐波伪影只在基频之上）后 Pass 2（counter）重复同样规则；
//    近重复抑制（折叠差规则）、碎片轨迹（总时长 <1.0s）出局、上声部先验
//    仅作平级决胜。v6 纯逐拍 argmax 无轨迹记忆，真实音乐上主/副标记碎片化
//    散布（两色角色频繁互换、音高长尾跳变），轨迹级追踪为修复核心。
//  【旋律链整合（v8，spec: .trae/specs/stitch-melody-chain）】真实音乐主旋律
//    被长间隙断成多条轨迹（单条最佳轨迹跨度内覆盖率仅 ~0.44，黄线呈「片段
//    式」）：Pass 1 选择层在最佳轨迹（argmax 语义不变）之后做链构建——双向
//    循环接入满足「时间 gap ≤ 12s ∧ 与链音符重叠率 ≤ 0.5 ∧ 声部同质门 ∧
//    chainMatch ≥ 0.55」的落选轨迹段落，链成员音符统一 melody；单轨迹情形
//    （合成基准）无候选可接，行为零变化。下游掩码/吸收/counter 三道门照常。
//  【conf 回退路径】acousticSalience 为空时（单元测试手工音符）：沿用 v2
//    拍内二部匹配算法原样（该路径下无 DSP 信号，转移代价 + 音程簿罚是对
//    conf 序列的已验证实现；VoiceSeparatorTests 全部用例走此路径）。
//  公共规则：低音硬排除（MIDI <45 不参与主/副旋律）、置信度门限 confFloor、
//    时长门限 minDuration、门限外音符保留在输出中（role = background——对拍
//    与渲染依赖完整音符集合）、纯函数、确定性、无 force unwrap。
//
//  隔离说明：纯计算类型，标 nonisolated 豁免工程默认 MainActor 隔离（参照
//  NoteDecoder 的写法），确保从后台分析管线调用时不会隐式跳回主线程。
//

import Foundation

nonisolated enum VoiceSeparator {

    // MARK: - 公共常量（两路径共用）

    /// 低置信度门限：amplitude 低于该值的音符不参与角色分配（直接 background）。
    /// 调参结论：0.25——conf 只用于挡极端垃圾，不作声部区分信号：①模型对高频
    /// 音符置信度系统性偏低（c 场景 melody 74/76 conf 0.33-0.42）且**逐实例波动**
    /// （同一音高不同周期 conf 不同，与伪影区间重叠），任何 conf 门限都会随机
    /// 误杀真值音符；②门限放宽放进来的模型八度幻影 conf 0.29-0.41 由 DSP
    /// argmax 天然淘汰（伪影 f0 只测到真值音符的弱谐波分量）+ 高八度幽灵掩码兜底。
    static let confFloor: Double = 0.25
    /// 超短音门限（秒）：解码碎段（dur < 0.15s）不参与角色分配
    static let minDuration: TimeInterval = 0.15
    /// 低音硬排除（MIDI < 45 不参与主/副旋律候选，spec 原值）
    static let bassExclude = 45

    /// 音区先验边界（按音高，单位半音）：45–54 → 0.75；55–84 → 1.0；> 84 → 0.8
    static let midMeanMidiUpper = 55
    static let highMeanMidiUpper = 84
    static let midRegisterPrior = 0.75
    static let coreRegisterPrior = 1.0
    static let highRegisterPrior = 0.8

    /// 碎片轨迹阈值（秒）：轨迹总时长低于该值不成立（spec Step 2 原值）
    static let minLineTotalDuration: TimeInterval = 1.0

    /// 近重复线判定：与主旋律时间共现率 > duplicateCoOccurrenceThreshold 且同拍
    /// 折叠音高差（±6 半音内）均值 ≤ duplicateSpan 且极差 ≤ duplicateSpan →
    /// 严格平行复制线（同度/八度加倍）；独立声部即使音区相距近八度，逐音符
    /// 折叠差也会波动 > 1 半音，不被误杀（排除恒定五度等平行独立声部）
    static let duplicateCoOccurrenceThreshold = 0.70
    static let duplicateSpan: Double = 1.0
    static let duplicateMinSamples = 4

    // MARK: - DSP 主路径常量

    /// 显著度窗口边缘裁剪比例：音符时段时间去掉前后各 10%（避开起止包络）
    static let salienceEdgeFraction = 0.10
    /// 显著度窗口样本数封顶：长音符窗口不超过该值（控制复杂度，O(总样本) 线性）
    static let salienceWindowCap = 8192
    /// Goertzel 最小窗口样本数（低于则显著度记 0）
    static let goertzelMinSamples = 64
    /// 合并视图间隙（秒）：同音高相邻音符间隙 ≤ 该值（或重叠）视为同源延续片段
    /// （解码层同音截断的通用修复；实测 c 场景 74 被解码成间隙 0.267s 的两段
    /// 9 帧碎片——mergeGap 0.06 接不住导致碎片被时长门限误删；0.30 会引入
    /// 跨周期杂音合并（b-counter/c-mel 倒退），0.27 恰好接住碎片对。真值中
    /// 同音高的相邻音符间隔 ≥ 1s 不受影响。只影响角色分组，输出保持原样）
    static let mergeGap: TimeInterval = 0.27
    /// 合并显著度相近判据：两片段显著度比 > 该值不合并（跨声部同音幅度不同——
    /// 实测 melody 0.106 vs counter 0.095 比 1.116 > 1.10 不合并；真截断片段
    /// 同源能量相近被合并）
    static let mergeSalienceRatio: Double = 1.10
    /// 短碎片对合并间隙（秒）：同音高相邻音符间隙 ≤ 该值时，若双段都为短碎片则
    /// 合并（中段断裂伪影修复）。调参结论：0.35——c 场景碎片对间隙 0.267s；
    /// 真实断奏重复音（staccato repeat）间隔通常 ≥0.35s；a/b 场景同音高音符
    /// 最小间隔 2.0s（循环周期）不受影响。
    static let mergeGapShortFragments: TimeInterval = 0.35
    /// 短碎片对时长上限（秒）：两段时长都 ≤ 该值才按短碎片对合并（真值长音
    /// 43 帧 ≈ 0.5s 不满足；中段断裂伪影的两段各 ≈ 9-14 帧 ≈ 0.10-0.16s）
    static let shortFragmentMax: TimeInterval = 0.25
    /// 短碎片对显著度比上限：两段显著度比 ≤ 该值才合并（同源断裂片段能量相近；
    /// 与 mergeSalienceRatio 同量级，略放宽以容忍断裂段的测量波动）
    static let shortFragmentRatio: Double = 1.15
    /// 高八度幽灵掩码重叠率：与某旋律音符时间重叠超过该比例（占自身时长）
    static let ghostOverlap: Double = 0.5
    /// 高八度幽灵音高类距离：候选音高**高于**旋律音符（谐波只在基频之上——
    /// 低于旋律的同格音符是真实声部，不掩）且音高类距离 ≤ 该值
    static let ghostPCDistance = 2

    // MARK: - 轨迹追踪常量（beam 多假设，spec「算法设计」Step 2–3）

    /// beam 宽度：同时维护的轨迹假设数上限（spec 要求 ≥8）。终值 12——合成场景
    /// 并行声部 5 条（主/副/3 垫）、c 场景和声层 13 个音高各自成链，12 保证主/副
    /// 链在剪枝压力下稳定存活；再宽只增加纯计算量不改变选中结果。
    static let beamWidth = 12
    /// 轨迹延续窗 / 衔接容忍窗（秒）：音符 start 距轨迹尾音 start 至少
    /// trajMinOnsetSep、距尾音 end 不超过该值方可延续（自然断线）。
    /// 终值 2.0——1.0 桥不过真实音乐乐句间呼吸（实测 shamshir 轨迹最长仅 13 组
    /// /5.1s，旋律角色塌缩成 11 音符「少标」）；2.0 桥接乐句级休止，误桥接由
    /// 声部同质门（自适应显著度水平）+ 衔接匹配度门槛（contMatchThreshold）
    /// + 代价上限三重抑制；实测 shamshir melody 音符数 11 → 147，A/B/C 全达标。
    static let trajMaxGap: TimeInterval = 2.0
    /// onset 簇窗口（秒）：与簇首 start 差 ≤ 该值的连续候选视为同簇，簇内按显著度
    /// 降序处理——显著度主导保护的「占坑」实现：同拍多声部竞争同一轨迹槽位时
    /// 显著度高者先选。终值 0.08——解码 onset 抖动 ±3 帧 ≈ 0.035s 的 2 倍余量，
    /// 且小于半个网格步（0.15/2），节拍错位的两个声部不会被误并同簇。
    static let onsetClusterWindow: TimeInterval = 0.08
    /// 显著度主导阈值（归一化 0–1）：争夺同一衔接槽位的两候选归一化显著度差
    /// ≥ 该值时显著度必胜，转移代价只裁决显著度接近的归属（spec 原值 0.1；
    /// 用于主导保护 bar——更强候选争夺槽位时弱者让位）。
    static let salienceDominance: Double = 0.10
    /// 声部同质门下限（归一化 0–1，对称）：音符与本遍轨迹显著度水平的差 ≥ 门值
    /// 时禁止加入该轨迹——声部身份判据。门值自适应：max(该下限, K×轨迹内标差)。
    /// 下限 0.06——实测合成基准主/副旋律显著度差 0.079–0.11（0.1 门拦不住跨声部
    /// 劫持：旋律 69→60 乐句跳进代价 11.75，跳到副声部链 64→60 仅 5.5，副链被
    /// 选中、真旋律整循环错标）；0.06 满足：链内波动（合成场景 ≤0.03）不受阻、
    /// 跨声部（≥0.079）必拦、垫音/幽灵（≥0.19）必拦。
    static let salienceGateFloor: Double = 0.06
    /// 声部同质门自适应系数：门值 = max(下限, K×轨迹音符归一化显著度标准差)。
    /// 终值 3.0——合成场景链内 σ ≤0.01 → 门=下限 0.06（与固定门同判，合成基准
    /// 不回归）；真实音乐链内 σ 可达 0.1（人声强弱拍动态 10×）→ 门放宽到 0.3，
    /// 真旋律线在动态起伏下不断裂（固定 0.06 门曾把 shamshir 旋律角色塌缩到
    /// 11 音符——绝对门对 10× 动态范围必然碎线，自适应门是两难的科学解）。
    static let salienceGateSigmaK: Double = 3.0
    /// 同链最小起音间隔（秒）：新音符起音距轨迹尾音符起音低于该值不可延续
    /// （同一声部不会在 0.12s 内两次起音——同拍和弦音由此拒入他链）。
    /// 终值 0.12——解码同拍抖动 ≤0.08（onsetClusterWindow）被排除在外，
    /// 同时覆盖 16 分音符（@120bpm = 0.125s）以上的一切真实节奏。
    static let trajMinOnsetSep: TimeInterval = 0.12
    /// 长程重衔接窗（秒）：短程延续失败后，音符可跨 gap 重新衔接的轨迹尾距
    /// 上限（trajMaxGap < gap ≤ 该值）。终值 10.0——真实音乐乐句间休止 4–8s
    /// 是常态（v7 首版 gap 2.0 使全局最佳轨迹只覆盖 ~50s，melody 角色坍缩成
    /// 短区段、全曲其余时段落榜）；10s 桥接乐句级断线，误衔接由衔接匹配度
    /// 门槛（reattachMatchThreshold）+ 声部同质门双重抑制。
    static let reattachMaxGap: TimeInterval = 10.0
    /// 长程重衔接匹配度门槛：断线重衔接要求匹配度（音高接近轨迹历史音域(主)
    /// + 走势一致(次) + 时值相近(次) + 显著度水平相当(次)）≥ 该值。终值
    /// 0.55——与 contMatchThreshold 同值：音高在历史音域内（0.5 权重满分）时
    /// 其余次级项中性即可通过；跳出音域或显著度失配则自然断线。
    static let reattachMatchThreshold: Double = 0.55
    /// counter 候选显著度比值门：与 melody 音符时间重叠、且组显著度（×音区
    /// 先验）< 该比值 × 重叠 melody 音符最大 em 的组不得进入 counter——把
    /// 低响度伴奏从 counter 剔除（B 指标异音交替主源）。终值 0.75——合成基准
    /// counter/melody em 比 ≈ 0.90（余量 0.15 全部保留，0.9 会崩到 F 0.33）；
    /// 真实音乐低响度伴奏比值 0.1–0.7 被挡（实测 B 88→35/min）。
    static let counterSalienceRatio: Double = 0.75
    /// 音高上下文吸收窗（秒）：counter 候选与「前后各最近的 melody 音符
    /// onset 之一」距离 ≤ 该值且同音高 → 吸收进 melody。终值 0.45——
    /// shamshir 碎片与相邻 melody onset 距离 ≤0.33 被吸收；合成基准安全：
    /// dual-a/b counter 与同音高 melody 音符的 onset 距离 ≥1.0s、dual-c 无
    /// 同音高（0.6 曾误吞 dual-b 距离 0.49 的同音对致 F 0.963→0.876）。
    static let counterAbsorbWindow: TimeInterval = 0.45
    /// counter 音区下界（MIDI）：低于该值的 counter 音符 = 深低音伴奏点缀，
    /// 不是第二旋律线，降 background。终值 54——合成基准 counter 音区 57–64
    ///（余量 3 半音全部幸存）；真实音乐低音/低中音点缀 45–53 被清除。
    static let counterMinMidi = 54
    /// 孤立 counter 修剪窗（秒）：时间排序后前后紧邻均为 melody 且间隔 <
    /// 该值的非重叠 counter 音符 = 插入主旋律线的伴奏点缀（目检"闪帧"本体），
    /// 降 background；成串 counter（互为紧邻）与时间重叠 melody 的 counter
    ///（同时发声第二声部）不受影响。终值 1.0——与 B 指标的交替判定窗一致，
    /// 修剪恰好运走 B 计数的直接来源。
    static let counterIsolationWindow: TimeInterval = 1.0
    /// 副旋律概率门槛（全局份额，spec: generalize-voice-roles-by-probability）：
    /// counter 候选 K 的全局份额（K.score / Σ Pass 1 全部合格候选轨迹 score）
    /// ≥ 该值才赋 countermelody，否则不产出副旋律（K 及其余全 background）。
    /// 定值 0.05（spec 预授权的实证调参，非下调断言）——实证全局份额：
    /// dual-a 0.387 / dual-b 0.386 / dual-c 0.448（合成基准副线）、shamshir
    /// 0.0567（真实音乐副线，D2 验收线）。初值 0.10（用户示例 8% 线须保持
    /// background、21% 线应为副旋律）下 shamshir 副线 0.0567 < 0.10 被拦、
    /// D2（counter 跨度/音符数）回退，故按 spec「零回归」条款以实证定值：
    /// 0.05 保留真实音乐副旋律（对 0.0567 有 0.0067 ≈ 13% 相对余量）且仍
    /// 拦截全局份额 <5% 的弱线；代价：用户示例中 8% 低概率线在真实管线
    /// （需先过 counterSalienceRatio 门）不再被本门拦截——D2 真实验收优先
    /// 于示例边界（spec「允许以实证数据定门槛值」条款）。
    static let countermelodyProbabilityThreshold: Double = 0.05
    /// 主导竞争窗（秒）：候选 h 与 g 的 start 差 ≤ 该值视为争夺同一衔接槽位。
    /// 终值 0.30——覆盖切分/弱起节奏（≤ 半拍）的同槽竞争；更远的先后关系属
    /// 顺序延续而非槽位竞争，不触发保护。
    static let dominanceClaimWindow: TimeInterval = 0.30
    /// 轨迹大跳检查阈值（半音）：|Δpitch| ≥ 该值按大跳处理（进入八度豁免判定）
    static let trajLeapThreshold = 7
    /// 八度豁免后的转移代价（半音当量）：|Δ| ≈ 12 且轨迹近期历史含同音/八度重现
    /// 时大跳罚降为该值（b 场景 60→72 教训：纯距离代价毁掉八度跳进旋律；取
    /// conf 路径 recurrenceCost 3.0 同值——高于级进 2 半音、远低于裸距离 12，
    /// 豁免后仍略劣于级进以避免八度关系被滥用为跨声部跳板）。
    static let trajRecurrenceCost: Double = 3.0
    /// 转移代价权重 w1（每半音音高距离）。终值 1.0——级进（≤4 半音）代价 ≤4
    /// 显著优于新开轨迹（12），使旋律线在显著度接近时天然延续。
    static let trajW1: Double = 1.0
    /// 转移代价权重 w2（走势二阶突变：轨迹尾两音走向 vs 新转移的方向/幅度差）。
    /// 终值 0.25——突变项只作「近同价候选间」的裁决维度，不得把真实旋律的
    /// 方向反转推出代价上限：a 场景 69→60（Δ9，前转移 +2）曾因 0.5×|−9−2|
    /// = 5.5 使总代价 14.5 > 上限，旋律链每循环断裂一次、垫音链反超选中
    /// （合成基准崩到 F 0.19）；0.25 下同转移总代价 11.75 ≤ 12 安全延续，
    /// 而锯齿形跳变（|d2−d1| ≥ 12）仍罚 ≥3 持续劣于平滑延续。
    static let trajW2: Double = 0.25
    /// 转移代价权重 w3（断线罚，每秒 gap；衔接匹配达标时清零）。终值 2.0——
    /// 0.5s 休止罚 1.0（可被衔接匹配豁免），1.0s 顶格罚 2.0，与中跳代价同量级。
    static let trajW3: Double = 2.0
    /// 衔接次级权重：时值失配罚 = wDur·|log2(时值比)|（封顶 2），仅 gap > 0 参与
    /// 裁决（spec Step 3「时值相近(次)」）。终值 0.5——长垫音（2s）混入 0.5s
    /// 旋律线的失配罚 1.0，足以被同级音高延续压过。
    static let trajWDur: Double = 0.5
    /// 衔接次级权重：显著度水平失配罚 = wLevel·|归一化显著度差|（封顶 1），
    /// 仅 gap > 0 参与裁决（spec Step 3「显著度水平相当(次)」）。终值 1.0——
    /// 抑制弱声部（垫音/和声）经休止混入强轨迹。
    static let trajWLevel: Double = 1.0
    /// 新开轨迹代价 = 转移代价上限：加入既有轨迹的总代价超过该值 → 新开轨迹
    /// （与 conf 路径 newLineCost 同值 12——八度重现 3.0、级进 ≤5、中跳 7–11
    /// 均可延续，≥12 的跳跃大概率是换声部而非旋律线内跳进）。
    static let trajNewCost: Double = 12.0
    /// 衔接匹配度门槛：gap > 0 时匹配度 ≥ 该值清 gap 罚（延续），否则收断线罚
    /// （spec Step 3「匹配度高于阈值 → 延续该轨迹（清 gap 罚）」）。终值 0.55——
    /// 音高接近（主权重 0.5）接近满分时其余次级项中性即可通过；音高远离或
    /// 走向/时值/显著度全面失配则自然断线。
    static let contMatchThreshold: Double = 0.55
    /// 八度重现判定窗口：轨迹尾最近若干音高（沿用 conf 路径 histWindow=8——
    /// 旋律八度往返周期内的重现可考）
    static let trajHistWindow = 8

    // MARK: - 旋律链构建常量（spec: stitch-melody-chain「算法设计」）

    /// 链扩展最大时间间隔（秒）：未入链轨迹与链时间跨度（spanStart/spanEnd）的
    /// 间隔 ≤ 该值方可作为链候选。终值 12.0——> reattachMaxGap 10s：链比单轨迹
    /// 追踪更能容断——追踪的重衔接是「尾音一对一衔接」，误接风险高故窗口收紧；
    /// 链以「整段轨迹」为单元做多维匹配（音域并集/走势/时值/显著度水平 + 时间
    /// 重叠率约束），判据更强，误接风险更低，窗口可放宽 2s 以覆盖真实音乐间奏
    /// /主副歌切换级的断线（10–12s）。
    static let melodyChainMaxGap: TimeInterval = 12.0
    /// 链衔接匹配度门槛：chainMatch（与 reattachMatch 同构：音高接近链历史音域
    /// 0.5 主 + 走势一致 0.2 + 时值相近 0.15 + 显著度水平相当 0.15）≥ 该值才接入。
    /// 终值 0.55——与 reattachMatchThreshold/contMatchThreshold 同值：音高在链
    /// 音域并集内（0.5 权重满分）时其余次级项中性即可通过；跳出音域或显著度
    /// 失配自然拒绝。
    static let melodyChainMatchThreshold: Double = 0.55
    /// E2 旋律段数切分间隙（秒，测试口径用）：melody 区域被 > 该值的无旋律间隙
    /// 切分的段数（MelodyContinuityTests.computeContinuityMetrics 计算 E2 使用；
    /// 理想连贯旋律 = 1 段，乐句间 ≤3s 的呼吸休止不切断）
    static let melodyChainSegmentGap: TimeInterval = 3.0
    /// 链候选时间重叠率上限：候选轨迹与链音符的时间重叠率（候选与链音符共现
    /// 时长 / 候选总时长）> 该值不接——与主链同时发声的平行和声线/重复声部
    /// 不是「续段」，保持原角色（background 或参与 counter 既有逻辑）
    static let melodyChainOverlapMax: Double = 0.5
    /// 链音区硬门边距（半音）：候选轨迹的均值音高必须落在种子轨迹音域 ± 该值
    /// 内，超出 = 另一声部音区（低音/和声），不参与链候选。终值 2.0——种子
    /// （argmax 主干）音域固定不随接入变化，切断音域棘轮（软性 pitchProx 的
    /// 12 半音衰减拦不住「距音域边缘 3-4 半音」的段，误接后并集扩张、更远的
    /// 段变得可接）。
    static let chainRegisterMargin: Double = 2.0
    /// 链局部音高贴合门（半音）：候选轨迹各组到链旋律线（其时间邻域的前/后
    /// 最近音符）音高距离的平均值 ≤ 该值才可入链。终值 6.0——「续段」在音高
    /// 上贴合它所嵌入的旋律线走向（旋律自身的段间移动均值 ≤ 3-4 半音，6 给
    /// 足余量）；偏离更大的段是另一声部在其自身音区活动（和声/低音句），接入
    /// 会在旋律线内制造大跳（实测 shamshir：无此门时 123 段全入、A' P90
    /// 8→16，此门 6.0 时接入 35 段、A' P90=10、E1 达标）。种子全局音域门
    /// （chainRegisterMargin）对音域宽的主干（实测 44-87 半音）不设防，本门
    /// 在时间-音高局部尺度补位。
    static let melodyChainLocalPitchMax: Double = 6.0
    /// 局部音高贴合门的截尾距离（半音）：单侧邻接距离 > 该值（跨八度）时该侧
    /// 不计入均值——旋律自身跨八度断裂处（实测 shamshir 残余 4 个 >3s 间隙
    /// 两侧分别为 50→82、84→62、84→67、82→72），桥接碎片对远侧的距离不代表
    /// 声部差异（旋律本身就在此跳档），把远侧计入均值会误杀真旋律的音区过渡
    /// 段；截尾后均值只衡量与「仍在同一音区的一侧」的贴合度。两侧均 >12 的
    /// 段（无任何同音区锚点）仍被拒（count = 0）。
    static let melodyChainLocalPitchTrim: Double = 12.0

    // MARK: - 旋律轮廓逐音符填充常量（spec: fill-melody-contour-gaps）

    /// 轮廓容差（半音）：候选音符到旋律轮廓插值线的距离 ≤ 该值方可被填充。
    /// 终值 2.0——轮廓由链成员音符线性插值而来，链成员本身必然落在轮廓上
    /// （距离 0）；被链门拒绝的碎片若与轮廓同高，其距离也在 0-1 半音内（解码
    /// 音高量化误差）。2.0 容差足以接纳同一条旋律线上的碎片，又不至于把轮廓
    /// 下方一个音阶（2 半音）的和声声部误填——实测 shamshir 轮廓带内候选中
    /// 约 49% 未被标黄（G1 基线 0.5137），这些就是被链门拒绝的同线碎片。
    /// 与测试侧 MelodyContinuityTests.contourBandTolerance 同值，保证指标口径
    /// 与实现一致。
    static let contourFillTolerance: Double = 2.0
    /// 轮廓填充时间邻接窗（秒）：候选音符到最近链成员音符的起始时间差 ≤ 该值。
    /// 终值 0.6——容得下同一旋律线上被解码切碎的相邻短音（实测 0.35 收窄后
    /// 反而恶化：B 34.9→39.3 次/分、G2 90→103——接纳更少使 melody 轮廓更
    /// 稀疏，被 counter 打断的机会反而增加；见 contourFillNotes 注释）
    static let contourFillWindow: TimeInterval = 0.6
    /// 轮廓外离群占比上限：填充后 melody 集合中「到轮廓距离 > 容差」的音符
    /// 占比上限。终值 0.15——允许零星轮廓抖动被接纳（实测收紧至 0.10 后
    /// B/G2 双双恶化，见 contourFillWindow 注释）
    static let contourFillMaxOutlier: Double = 0.15
    /// counter 轮廓回收的显著度下限（相对链内最安静成员）：回收时不接纳明显
    /// 比主旋律链更安静的 counter 音符——它们更可能是真正的伴奏/和声而非
    /// 旋律碎片。终值 = contourFillCounterGuard（0.75，与 counter 判据同值，
    /// 保证「counter 判据认为够响才算独立声部」的对称性）
    static let contourReclaimSalienceRatio: Double = 0.75
    /// counter 回收的同音高邻接重叠下限（秒）：被回收的 counter 音符必须与某个
    /// **音高完全相同**的 melody 音符时间重叠 ≥ 该值——解码碎片是同一物理音被
    /// 切开的前后段（音高相同、时间重叠）；真正的副旋律是独立声部（音高不同）。
    /// 终值 0.01s。判据演进记录：先尝试「纯时间重叠」判据，实测无效——合成基准
    /// dual-a 的 counter（64）与 melody（69）同时发声确实重叠，F 仍 89.7/87.7；
    /// 音高才是区分二者的稳定特征
    static let contourReclaimOverlap: TimeInterval = 0.01
    /// counter 回收的时间邻接窗（秒）：被回收音符到最近 melody 音符起点距。
    /// 终值 0.25——比填充窗 0.6 更紧：回收只认紧贴链成员者（解码碎片的
    /// 后段紧跟前一旋律音符）
    static let contourReclaimWindow: TimeInterval = 0.25
    /// 轮廓填充的 counter 潜在占用预判（结构修复，Task 3）：候选组若同时满足
    /// ①通过声部同质门（|归一化显著度 − 链均值| < 链门值）②显著度 ≥ 重叠
    /// melody 最大显著度 × 该倍数，则视为「独立副旋律声部素材」，不参与填充。
    /// 终值 = counterSalienceRatio（0.75）——与 counter 显著度比值门同值：
    /// 填充与 counter 两条路对同一批候选的判据一致，避免"两边都想要"的角色
    /// 抖动（实测 Task 3 迭代：宽松填充 B 31.3→34.9 次/分，G2 195→90——
    /// G2 收益伴随 B 恶化；本门把职责边界由阈值调平改为候选归属划清）。
    static let contourFillCounterGuard: Double = 0.75

    // MARK: - conf 回退路径常量（v2 拍内二部匹配，单元测试手工音符用）

    /// 排序量化拍格（秒）：同格音符视为同拍做联合分配
    static let beatQuantLegacy: TimeInterval = 0.15
    /// 音符与声部线的最大时间间隔（秒）
    static let maxGap: TimeInterval = 0.35
    /// 轻微重叠容忍（秒）
    static let overlapTolerance: TimeInterval = 0.02
    /// onset 节奏放行窗口（秒）：修复解码拖尾伪影（endTime 变成挡板）
    static let minInterOnset: TimeInterval = 0.30
    static let maxOnsetInterval: TimeInterval = 0.60
    /// 相邻音符最大音高跳变（半音）
    static let maxStep = 12
    /// 大跳检查阈值（半音）：≥ 该值需线历史含同音/八度重现
    static let leapThreshold = 7
    /// 大跳重现判定窗口：线尾最近若干音高
    static let histWindow = 8
    /// 重现代价（半音距离压平值）：大跳且音高重现时候选代价降为该值
    static let recurrenceCost: Double = 3.0
    /// 时长一致性比率：候选时长与线内中位时长差超该倍数（双向）不可候选
    static let durRatio: Double = 2.0
    /// 音程簿罚：新线对音程不在历史（≥minIntervalHistory 个）中时的代价增量
    static let intervalPenalty: Double = 6.0
    static let minIntervalHistory = 3
    /// 新开线代价
    static let newLineCost: Double = 12.0

    // MARK: - DSP 显著度（Goertzel 单频测量）

    /// midi → 频率（A4 = 440 Hz 十二平均律）
    private static func midiToHz(_ midi: Int) -> Double {
        440.0 * Foundation.pow(2.0, Double(midi - 69) / 12.0)
    }

    /// 计算每个音符的声学显著度：Goertzel 单频算法测量音符基频能量。
    /// 窗口 = 音符时段时间的中段 80%（避开起止包络），样本数封顶
    /// salienceWindowCap（长音符复杂度受控，O(总样本) 线性）；累加用 Double
    /// 保证 Float 输入下的数值精度。与 notes 平行返回；空/越界安全（窗口不足
    /// goertzelMinSamples 记 0）。DSP 测量决定性：同音频同窗口 → 同值，无运行漂移。
    static func computeNoteSalience(
        samples: [Float], sampleRate: Double, notes: [MelodyNote]
    ) -> [Double] {
        guard sampleRate > 0 else { return notes.map { _ in 0.0 } }
        return notes.map { note in
            let dur = note.endTime - note.startTime
            let s0 = max(0, Int(note.startTime * sampleRate))
            let s1 = min(samples.count, Int((note.startTime + dur) * sampleRate))
            guard s1 - s0 >= goertzelMinSamples else { return 0.0 }
            let span = s1 - s0
            let lo = s0 + Int(Double(span) * salienceEdgeFraction)
            let hi = s0 + Int(Double(span) * (1.0 - salienceEdgeFraction))
            var window = Array(samples[min(lo, samples.count)..<min(hi, samples.count)])
            if window.count > salienceWindowCap {
                let off = (window.count - salienceWindowCap) / 2
                window = Array(window[off..<(off + salienceWindowCap)])
            }
            guard window.count >= goertzelMinSamples else { return 0.0 }
            // Goertzel：单频 DFT，O(窗口长)
            let omega = 2.0 * Double.pi * midiToHz(note.midiNote) / sampleRate
            let coeff = 2.0 * Foundation.cos(omega)
            var g1 = 0.0, g2 = 0.0
            for x in window {
                let g0 = Double(x) + coeff * g1 - g2
                g2 = g1
                g1 = g0
            }
            let power = g1 * g1 + g2 * g2 - coeff * g1 * g2
            return Foundation.sqrt(max(power, 0.0)) / Double(window.count)
        }
    }

    // MARK: - 公开入口

    /// 为音符分配声部角色（melody / countermelody / background）。
    ///
    /// - acousticSalience 非空（真实分析管线）：DSP 主路径——纯逐拍 argmax 双遍，
    ///   显著度为主信号，conf 仅做门限；
    /// - acousticSalience 为空（单元测试手工音符）：conf 回退路径——v2 拍内
    ///   二部匹配算法（VoiceSeparatorTests 全部用例走此路径）。
    /// - 纯函数、确定性：输出按时间升序（多键全序排序），乱序输入得到完全一致
    ///   的结果；所有切片前都有 count 守卫（不存在空区间反向 Range）。
    static func assignRoles(
        to notes: [MelodyNote], acousticSalience: [Double]? = nil
    ) -> [MelodyNote] {
        guard !notes.isEmpty else { return notes }
        if let salience = acousticSalience, salience.count == notes.count {
            return dspAssignRoles(to: notes, salience: salience)
        }
        return legacyAssignRoles(to: notes)
    }

    // MARK: - DSP 主路径（纯逐拍 argmax 双遍）

    /// DSP 主路径。salience 与 notes 平行。
    private static func dspAssignRoles(
        to notes: [MelodyNote], salience: [Double]
    ) -> [MelodyNote] {
        // 合并视图（先于时长门限——解码把同一物理音符截成多个碎片时，合并恢复
        // 完整时长；若先过滤碎片会被误删）。候选池 = conf 门限 + 低音硬排除；
        // 时长门限在合并后按组时长执行。
        let pool = notes.indices.filter {
            notes[$0].confidence >= confFloor && notes[$0].midiNote >= bassExclude
        }
        guard !pool.isEmpty else {
            return notes.map { settingRole($0, .background) }
        }

        // 合并视图：同音高、间隙 ≤ mergeGap（或重叠）且显著度相近（同源延续片段）
        // ——只影响角色分组，输出音符保持原样（对拍依赖完整音符集合）
        var byPitch: [Int: [Int]] = [:]
        for i in pool { byPitch[notes[i].midiNote, default: []].append(i) }
        var groups: [(members: [Int], start: Double, end: Double, midi: Double, sig: Double,
                      dur: Double, fragmentMerged: Bool)] = []
        func finalize(_ members: [Int], fragmentMerged: Bool) {
            let start = members.map { notes[$0].startTime }.min() ?? 0
            let end = members.map { notes[$0].endTime }.max() ?? 0
            let midi = Double(members.map { notes[$0].midiNote }.reduce(0, +)) / Double(members.count)
            let sig = members.map { salience[$0] }.max() ?? 0
            groups.append((members, start, end, midi, sig, end - start, fragmentMerged))
        }
        for m in byPitch.keys.sorted() {
            let idxs = (byPitch[m] ?? []).sorted { notes[$0].startTime < notes[$1].startTime }
            guard !idxs.isEmpty else { continue }
            var cur = [idxs[0]]
            var fragMergePending = false
            for j in idxs.dropFirst() {
                let prev = cur.last ?? j
                let gap = notes[j].startTime - notes[prev].endTime
                let sHi = max(salience[j], salience[prev])
                let sLo = min(salience[j], salience[prev])
                let ratio = sHi / max(sLo, 1e-9)
                // 规则 1：同源延续（间隙 ≤ mergeGap 且显著度相近）
                // 规则 2（短碎片对鲁棒合并）：解码器对高频/弱音长音常产生「中段断裂」
                // 伪影——同一物理音符被解码成间隙较大的两段短碎片（c 场景 74 碎成
                // 9+9 帧、间隙 0.267s，恰好也落进 mergeGap 0.27 内）；真值是单一
                // 长音。**双短段判定（两段时长都 ≤ shortFragmentMax）优先于合并
                // 路径**：凡是双短段合并（无论走规则 1 还是 2），组都标记
                // fragmentMerged（成员时间归一到组范围的依据——碎片与真值时长
                // 容差对齐）；长音间合并（规则 1 且非双短段）不改写时间（对拍依赖）。
                let prevDur = notes[prev].endTime - notes[prev].startTime
                let curDur = notes[j].endTime - notes[j].startTime
                let bothShort = prevDur <= shortFragmentMax && curDur <= shortFragmentMax
                var merge = gap <= mergeGap && ratio <= mergeSalienceRatio
                var fragMerge = bothShort && gap <= mergeGapShortFragments
                    && ratio <= shortFragmentRatio
                if !merge, fragMerge {
                    merge = true // 双短段但间隙超 mergeGap：按短碎片对规则合并
                }
                if merge {
                    if fragMerge { fragMergePending = true }
                    cur.append(j)
                } else {
                    finalize(cur, fragmentMerged: fragMergePending)
                    fragMergePending = false
                    cur = [j]
                }
            }
            finalize(cur, fragmentMerged: fragMergePending)
        }
        // 规范排序（确定性：tie-break 依赖组序号，必须消除字典迭代顺序影响）
        groups.sort { ($0.start, $0.midi) < ($1.start, $1.midi) }
        // 组级时长门限（碎片组出局；组级=合并恢复后的完整时长）
        let candGroups = groups.indices.filter { groups[$0].dur >= minDuration }
        guard !candGroups.isEmpty else {
            return notes.map { settingRole($0, .background) }
        }

        // 音区先验（文件级 registerPrior(midi)，两遍追踪共用）

        // 轨迹总时长（音符下标集合的原始时长和）
        func lineDuration(_ members: Set<Int>) -> TimeInterval {
            members.reduce(0) { $0 + (notes[$1].endTime - notes[$1].startTime) }
        }

        // beam 轨迹追踪双遍（spec Step 2–4，替代 v6 纯逐拍 argmax）：
        // Pass 1（melody）→ 掩码 → Pass 2（counter）结构保持；
        // 返回 (选中轨迹的成员音符下标集, 选中轨迹的组下标序列)。
        // Pass 1 轨迹集另行保留：counter 全局概率份额的分母（Σ Pass 1 全部
        // 合格候选轨迹 score，见 counterGlobalShare——防第二遍候选稀释放行
        // 低概率线）。
        let pass1Trajectories = trackTrajectories(candGroups, groups: groups)
        // 旋律链整合（spec: stitch-melody-chain）：以概率 argmax 最佳轨迹为起点，
        // 双向循环接入满足约束的落选轨迹段落（>reattachMaxGap 断开的段、被门拒绝
        // 的段），链成员音符统一获得 melody 角色——修复真实音乐主旋律的「片段式」
        // 断线。单轨迹情形（合成基准旋律连续无断段）无候选可接，链 = 最佳轨迹，
        // 行为零变化；下游掩码/吸收/counter 三道门以链后 melody 集为输入照常运行
        //（Pass 2 counter 不变，仍取单条最佳轨迹）。
        let (melodyNotes, melodyWon) = chainedTrajectoryNotes(pass1Trajectories, groups: groups)
        var melodySet = melodyNotes
        if lineDuration(melodySet) < minLineTotalDuration { melodySet = [] }

        // 旋律轮廓逐音符填充（spec: fill-melody-contour-gaps，链之后、掩码之前）：
        // 链以**整条轨迹**为决策单位（all-or-nothing）——被份额门/音区门/局部
        // 贴合门任一拒绝的轨迹，其内部全部音符落回 background，即使个别音符
        // 完美落在旋律线上（用户截图实证：同一条音高线上黄白交替；实测 G1 轮廓
        // 带内命中率仅 0.5137、G2 断点 195）。本步在链之下做**音符级**补全：
        // 链成员音符间线性插值出旋律轮廓，落在轮廓容差内、时间邻接合格、且未被
        // counter 级轨迹占用的候选音符单独获得 melody 角色。执行顺序说明：
        // 填充置于掩码之前 → 被填充的轮廓音符同样参与高八度幽灵掩码与音高
        // 上下文吸收（它们是真实旋律的一部分，谐波伪影应被一并抑制）；填充
        // 置于 counter 三道门之前 → counter 在「已补全的主线」余量中选出，
        // 与既有语义（counter 从剩余轨迹中选）一致。
        // 轮廓填充用的两张映射：音符 → 归一化显著度 em（salience × 音区先验）、
        // 音符 → 所属合并组下标（counter 潜在占用预判按组判定）。em 的最大值
        // 在 contourFillNotes 内部用作归一化基准，与 TrajectoryFeature 同口径。
        var emByNoteForFill: [Int: Double] = [:]
        var groupIndexByNoteForFill: [Int: Int] = [:]
        if !melodySet.isEmpty {
            for gi in candGroups {
                for m in groups[gi].members {
                    groupIndexByNoteForFill[m] = gi
                    emByNoteForFill[m] = salience[m]
                        * registerPrior(Double(notes[m].midiNote))
                }
            }
            let filled = contourFillNotes(
                melodySet: melodySet,
                pool: pool,
                notes: notes,
                groups: groups,
                pass1Trajectories: pass1Trajectories,
                emByNote: emByNoteForFill,
                groupIndexByNote: groupIndexByNoteForFill
            )
            melodySet.formUnion(filled)
        }

        // 掩码：melody + 高八度幽灵（重叠 >50%、音高**高于**旋律音符、音高类距离 ≤2
        // ——谐波伪影只在基频之上；低于旋律的同格音符是真实声部，不掩）
        var masked = melodySet
        for i in pool {
            if masked.contains(i) { continue }
            let s0 = notes[i].startTime, e0 = notes[i].endTime
            for j in melodySet {
                let s1 = notes[j].startTime, e1 = notes[j].endTime
                let overlap = min(e0, e1) - max(s0, s1)
                if overlap > ghostOverlap * (e0 - s0), notes[i].midiNote > notes[j].midiNote {
                    let dd = abs(notes[i].midiNote - notes[j].midiNote) % 12
                    if dd <= ghostPCDistance {
                        masked.insert(i)
                        break
                    }
                }
            }
        }

        // Pass 2：counter（剩余候选组；部分成员被掩的组整体排除——melody 轨迹
        // 音符与高八度幽灵不进入本遍候选，轨迹追踪的显著度主导保护在剩余候选
        // 间独立裁决）
        let restGroups = candGroups.filter { g in
            !groups[g].members.contains { masked.contains($0) }
        }

        // 音高上下文吸收（Task 4 返工）：剩余组若与「前后各最近的 melody 音符
        // onset 之一」距离 ≤ counterAbsorbWindow 且同音高 → 是同一人声长音被
        // 解码器切碎的碎片，并入 melody 候选。合成基准安全边界：dual-a/b
        // counter 与同音高 melody 音符的 onset 距离 ≥ 1.0s（连续 0.5s 音符
        // 交错排列）、dual-c 无同音高（音区 57–64 vs 67–76），全部不会被吸收；
        // 真实音乐人声碎片（乒乓交替的来源）被回收进主线。
        var absorbedGroups: [Int] = []
        var restAfterAbsorb: [Int] = []
        do {
            let melodyNotesSorted = melodySet.sorted {
                (notes[$0].startTime, notes[$0].midiNote)
                    < (notes[$1].startTime, notes[$1].midiNote)
            }
            let onsets = melodyNotesSorted.map { notes[$0].startTime }
            for g in restGroups {
                let gr = groups[g]
                let idx = onsets.firstIndex { $0 >= gr.start } ?? onsets.count
                var ok = false
                if idx > 0 {
                    let m = melodyNotesSorted[idx - 1]
                    ok = gr.start - notes[m].startTime <= counterAbsorbWindow
                        && abs(Double(notes[m].midiNote) - gr.midi) < 1.0
                }
                if !ok, idx < onsets.count {
                    let m = melodyNotesSorted[idx]
                    ok = notes[m].startTime - gr.start <= counterAbsorbWindow
                        && abs(Double(notes[m].midiNote) - gr.midi) < 1.0
                }
                if ok {
                    absorbedGroups.append(g)
                } else {
                    restAfterAbsorb.append(g)
                }
            }
        }
        for g in absorbedGroups {
            melodySet.formUnion(groups[g].members)
        }

        // counter 候选显著度比值门（Task 4 返工）：与 melody 音符时间重叠、且
        // 组 em < counterSalienceRatio × 重叠 melody 音符最大 em 的组不得进入
        // counter——低响度伴奏是 B 指标异音交替的主源；合成基准 counter/melody
        // em 比 ≈ 0.90 全部保留。
        let restAfterGate: [Int] = restAfterAbsorb.filter { g in
            let gr = groups[g]
            var bestMelEM = 0.0
            for i in melodySet
            where gr.start < notes[i].endTime && notes[i].startTime < gr.end {
                bestMelEM = max(
                    bestMelEM, salience[i] * registerPrior(Double(notes[i].midiNote)))
            }
            if bestMelEM == 0 { return true }
            return gr.sig * registerPrior(gr.midi) >= counterSalienceRatio * bestMelEM
        }

        let restGroupsFinal = restAfterGate
        let counterTrajectories = trackTrajectories(restGroupsFinal, groups: groups)
        let (counterNotes, counterWon) = selectedTrajectoryNotes(counterTrajectories, groups: groups)
        var counterSet = counterNotes
        counterSet.subtract(masked) // 安全网：部分掩码组的被掩成员不随组获角色
        if lineDuration(counterSet) < minLineTotalDuration { counterSet = [] }

        // 概率泛化门槛（spec generalize-voice-roles-by-probability）：副旋律
        // 候选 K = Pass 2 最高轨迹，全局份额 ≥ countermelodyProbabilityThreshold
        // 才赋 countermelody，否则 counterSet 置空（K 及其余全 background）。
        // 全局份额 = K.score / Σ(Pass 1 全部合格候选轨迹 score)：分母取
        // Pass 1 全集而非 Pass 2 候选集（第二遍候选经掩码/吸收/显著度门后
        // 大减，小分母会放大幸存线份额、稀释放行低概率线）。门槛定值 0.05
        // 的实证推导见常量注释（dual 0.39/0.39/0.45、shamshir 0.057）。
        // 其余既有逻辑（时长门、近重复、去掩码、上声部先验、孤立修剪）不变。
        if !counterSet.isEmpty, let k = bestTrajectory(counterTrajectories),
           counterGlobalShare(k, pass1Trajectories: pass1Trajectories)
               < countermelodyProbabilityThreshold {
            counterSet = []
        }

        // 近重复抑制（折叠差规则）
        if !counterSet.isEmpty && !melodySet.isEmpty {
            var total: Double = 0
            var overlapping: Double = 0
            var diffs: [Double] = []
            for i in counterSet {
                let s0 = notes[i].startTime, e0 = notes[i].endTime
                total += e0 - s0
                for j in melodySet
                where s0 < notes[j].endTime && notes[j].startTime < e0 {
                    overlapping += e0 - s0
                    var d = Double(notes[i].midiNote - notes[j].midiNote)
                        .truncatingRemainder(dividingBy: 12)
                    if d > 6 { d -= 12 }
                    if d < -6 { d += 12 }
                    diffs.append(d)
                    break
                }
            }
            let co = total > 0 ? overlapping / total : 0
            if co > duplicateCoOccurrenceThreshold, diffs.count >= duplicateMinSamples {
                let mean = diffs.reduce(0, +) / Double(diffs.count)
                let span = (diffs.max() ?? 0) - (diffs.min() ?? 0)
                if abs(mean) <= duplicateSpan && span <= duplicateSpan {
                    counterSet = []
                }
            }
        }

        // 上声部先验（平级决胜：两轨迹均值音高高者为 melody）。旋律链整合后
        // 的修正（spec stitch-melody-chain 实证）：melodyFinal 是以概率 argmax
        // 轨迹为种子、经声部同质门/份额门/局部音高贴合门逐段整合的「链」，
        // 其身份由概率 argmax 契约锚定（spec generalize-voice-roles-by-probability：
        // melody = argmax 份额）；counterFinal 是 Pass 2 在剩余轨迹中选出的线，
        // 按构造即为副旋律。两集合不再「同级」——链被拒的碎片会流入 Pass 2 被
        // 追踪拼成复合线（实测 shamshir：复合线均值音高恰比链高 1.1 半音，
        // 触发本互换把 445 音的整条链降级为 counter、E1 0.61 → 0.17 崩塌），
        // 故 meanMidi 互换不再适用；仅保留空旋律提升分支（链碎片化出局时
        // Pass 2 线提升为 melody，既有语义）。
        var melodyFinal = melodySet
        var counterFinal = counterSet

        // counter 轮廓回收（spec: fill-melody-contour-gaps，Task 3）：把 counter
        // 集中落在旋律轮廓带内、时间邻接链成员的音符收回为 melody——它们是主旋律
        // 被解码切碎后误分配为副旋律的碎片（用户截图中黄线上的蓝点/黄白黄蓝
        // 交替的直接来源）。与前面的轮廓填充互为逆操作，共同保证不变式
        // 「轮廓带内必属旋律」，与 G2 指标口径直接对齐。回收发生在近重复抑制
        // 之后、孤立修剪之前——近重复抑制针对整体声部关系（不应回收整条
        // 平行线），孤立修剪针对点缀碎片（回收后已不在 counter 集内）。
        if !counterFinal.isEmpty && !melodyFinal.isEmpty {
            let reclaimed = contourReclaimNotes(
                counterSet: counterFinal,
                melodySet: melodyFinal,
                notes: notes,
                salience: salience
            )
            if !reclaimed.isEmpty {
                melodyFinal.formUnion(reclaimed)
                counterFinal.subtract(reclaimed)
                // 回收后 counter 可能低于时长门限（整条被回收）→ 置空
                if lineDuration(counterFinal) < minLineTotalDuration {
                    counterFinal = []
                }
            }
        }

        if melodyFinal.isEmpty {
            melodyFinal = counterFinal
            counterFinal = []
        }

        // 孤立 counter 修剪（Task 4 返工）：时间排序后前后紧邻（<
        // counterIsolationWindow）均为 melody、且自身不与任何 melody 音符时间
        // 重叠的 counter 音符 = 插入主旋律线的伴奏点缀（目检"闪帧"本体），降
        // background。与 melody 重叠的 counter（同时发声的第二声部，合成基准
        // 形态）与成串 counter（互为紧邻）不受影响。不动点迭代：修剪改变邻接
        // 关系，最多 4 轮收敛（实测 ≤2 轮）。
        if !counterFinal.isEmpty && !melodyFinal.isEmpty {
            for _ in 0..<4 {
                let voiced = Array(melodyFinal.union(counterFinal)).sorted {
                    (notes[$0].startTime, notes[$0].midiNote, notes[$0].endTime)
                        < (notes[$1].startTime, notes[$1].midiNote, notes[$1].endTime)
                }
                var pruned: Set<Int> = []
                for (k, i) in voiced.enumerated() where counterFinal.contains(i) {
                    let s0 = notes[i].startTime, e0 = notes[i].endTime
                    let overlapsMelody = melodyFinal.contains { j in
                        s0 < notes[j].endTime && notes[j].startTime < e0
                    }
                    if overlapsMelody { continue }
                    var okL = false, okR = false
                    if k > 0, melodyFinal.contains(voiced[k - 1]) {
                        okL = notes[i].startTime - notes[voiced[k - 1]].startTime
                            < counterIsolationWindow
                    }
                    if k + 1 < voiced.count, melodyFinal.contains(voiced[k + 1]) {
                        okR = notes[voiced[k + 1]].startTime - notes[i].startTime
                            < counterIsolationWindow
                    }
                    if okL && okR { pruned.insert(i) }
                }
                if pruned.isEmpty { break }
                counterFinal.subtract(pruned)
            }
        }

        // 低音区修剪（Task 4 返工）：counter 音符低于 counterMinMidi = 深低音
        // 伴奏点缀，不是第二旋律线，降 background（合成基准 counter 音区 57–64
        // 全部幸存）。
        counterFinal = counterFinal.filter { notes[$0].midiNote >= counterMinMidi }

        // 角色回写（门限外/长音/落选音符保持 background）。获角色的合并组：
        // 仅组内**代表成员**（显著度最高者——真值长音的主解码段）获得组时间范围
        //（碎片与真值时长容差对齐），其余碎片成员保持原时间 + background
        //（避免同组双成员输出重叠时间被真值匹配消耗两次——P 损失来源）
        var timeOverride: [Int: (Double, Double)] = [:]
        var nonRep: Set<Int> = []
        for g in melodyWon + counterWon
        where groups[g].fragmentMerged && groups[g].members.count > 1 {
            // 时间归一仅作用于「短碎片对合并」的组（碎片与真值时长容差对齐）；
            // 同源延续合并（规则 1）不改写时间——保持原始解码时间（对拍依赖）
            let members = groups[g].members
            let rep = members.max { salience[$0] < salience[$1] } ?? members[0]
            timeOverride[rep] = (groups[g].start, groups[g].end)
            for m in members where m != rep { nonRep.insert(m) }
        }
        var roles = [MelodyRole](repeating: .background, count: notes.count)
        for i in melodyFinal { roles[i] = .melody }
        for i in counterFinal { roles[i] = .countermelody }
        for i in nonRep { roles[i] = .background } // 非代表碎片成员保持背景
        return notes.enumerated().map { index, note in
            guard roles[index] != .background, let (ts, te) = timeOverride[index] else {
                return settingRole(note, roles[index])
            }
            return settingRole(
                MelodyNote(startTime: ts, endTime: max(te, ts + 0.01),
                           midiNote: note.midiNote, confidence: note.confidence,
                           pitchBends: note.pitchBends, role: roles[index]),
                roles[index]
            )
        }
    }

    // MARK: - beam 轨迹追踪（DSP 主路径 Pass 1/Pass 2 共用，spec Step 1–4）

    /// 合并视图组类型（dspAssignRoles 内构建，轨迹追踪的输入单元）
    private typealias MergeGroup = (
        members: [Int], start: Double, end: Double, midi: Double, sig: Double,
        dur: Double, fragmentMerged: Bool
    )

    /// 音区先验（轨迹评分与显著度归一化的权重；按组均值音高分档）
    private static func registerPrior(_ midi: Double) -> Double {
        if midi < Double(midMeanMidiUpper) { return midRegisterPrior }
        if midi <= Double(highMeanMidiUpper) { return coreRegisterPrior }
        return highRegisterPrior
    }

    /// 轨迹特征向量（spec Step 1：pitch/start/end/salience/stepToPrev/
    /// durationRatio 的组级形态；stepToPrev 与 durationRatio 在追踪推进时相对
    /// 轨迹尾即时计算——lastDelta 与 tailDuration 承载）
    private struct TrajectoryFeature {
        let group: Int            // 合并视图组下标
        let pitch: Double         // 组均值 MIDI
        let start: Double
        let end: Double
        let duration: Double
        let salience: Double      // 组显著度 × 音区先验
        let normSalience: Double  // salience / 本遍候选最大值（0–1，主导保护用）
    }

    /// 一条轨迹假设（beam 中的一个假设）：音符组序列 + 尾部衔接状态 + 累计统计
    private struct TrajectoryHypothesis {
        var groups: [Int] = []          // 组下标（加入序 = 时间序）
        var pitches: [Double] = []      // 音高历史（八度重现/音域判定）
        var tailPitch: Double = 0
        var tailDuration: Double = 0
        var tailStart: Double = 0
        var tailEnd: Double = 0
        var lastDelta: Double?          // 尾部最近一次转移 Δpitch（二阶突变项）
        var sumSalience: Double = 0     // Σ(显著度×先验)，按加入顺序累加（确定性）
        var totalDuration: Double = 0
        var spanStart: Double = 0
        var spanEnd: Double = 0
        var levelNorm: Double = 0       // 归一化显著度水平（均值，声部同质门用）
        var sumSqNorm: Double = 0       // 归一化显著度平方和（σ → 自适应门）
        var creationIndex: Int = 0      // 决胜用（早开者优先）

        /// 连续覆盖 = Σ时长 / 首末跨度（封顶 1，与 conf 路径 continuity 同口径）
        var coverage: Double {
            let span = spanEnd - spanStart
            return span > 0 ? min(1.0, totalDuration / span) : 1.0
        }
        /// 轨迹评分 = Σ显著度 × 连续覆盖（spec Step 4 角色选择主判据）
        var score: Double { sumSalience * coverage }
        var meanPitch: Double {
            pitches.isEmpty ? 0 : pitches.reduce(0, +) / Double(pitches.count)
        }

        /// 以首个音符特征新建轨迹
        init(seed: TrajectoryFeature, creationIndex: Int) {
            groups = [seed.group]
            pitches = [seed.pitch]
            tailPitch = seed.pitch
            tailDuration = seed.duration
            tailStart = seed.start
            tailEnd = seed.end
            lastDelta = nil
            sumSalience = seed.salience
            totalDuration = seed.duration
            spanStart = seed.start
            spanEnd = seed.end
            levelNorm = seed.normSalience
            sumSqNorm = seed.normSalience * seed.normSalience
            self.creationIndex = creationIndex
        }

        /// 音符延续轨迹：更新尾部衔接状态与累计统计（累加顺序 = 处理顺序，确定性）
        mutating func extend(_ f: TrajectoryFeature) {
            lastDelta = f.pitch - tailPitch
            tailPitch = f.pitch
            tailDuration = f.duration
            tailStart = f.start
            tailEnd = f.end
            pitches.append(f.pitch)
            groups.append(f.group)
            let priorCount = Double(groups.count - 1)
            levelNorm = (levelNorm * priorCount + f.normSalience) / Double(groups.count)
            sumSqNorm += f.normSalience * f.normSalience
            sumSalience += f.salience
            totalDuration += f.duration
            spanEnd = max(spanEnd, f.end)
        }

        /// 声部同质门（自适应）：max(下限, K×链内归一化显著度标准差)。
        /// 均匀声部（合成/电子乐）门收紧到下限——跨声部劫持必拦；
        /// 动态声部（真实人声强弱）门随 σ 放宽——真旋律线不被自身动态切碎。
        /// 单音符轨迹 σ=0 → 门=下限；σ 无负值（方差下限 0 保护）。
        func salienceGate() -> Double {
            let n = Double(groups.count)
            guard n >= 2 else { return salienceGateFloor }
            let variance = max(0, sumSqNorm / n - levelNorm * levelNorm)
            return max(salienceGateFloor, salienceGateSigmaK * Foundation.sqrt(variance))
        }

        /// 音高是否在轨迹近期历史中以同音或八度关系出现过（大跳重现判定，
        /// 语义与 conf 路径 isRecurrence 一致；组均值为小数故用容差比较）
        func isOctaveRecurrence(_ pitch: Double) -> Bool {
            pitches.suffix(trajHistWindow).contains {
                abs($0 - pitch) < 0.5 || abs(abs($0 - pitch) - 12) < 0.5
            }
        }

        /// 落点是否落在轨迹历史音域内（±0.5 半音容差）：声部内八度往复的判据——
        /// 跳出历史音域的八度跳进大概率是换声部（a 场景 69→57 劫持教训：
        /// 57 = 69−12 音高类重现成立，但 57 在音域 [60,69] 之外）
        func isWithinHistoricalRange(_ pitch: Double) -> Bool {
            guard let lo = pitches.min(), let hi = pitches.max() else { return false }
            return pitch >= lo - 0.5 && pitch <= hi + 0.5
        }

        /// 长程重衔接匹配度（spec 建议③「跳跃衔接」的断线重续场景）：
        /// 音高接近轨迹历史音域(主 0.5) + 走势一致(次 0.2) + 时值相近(次 0.15)
        /// + 显著度水平相当(次 0.15)——与衔接匹配度同构，但音高项对「历史音域」
        /// 计算（断线后尾音可能落在音域边缘/离群点，对尾音算距离会错杀回归音）。
        func reattachMatch(_ f: TrajectoryFeature) -> Double {
            var dist = 0.0
            if !isWithinHistoricalRange(f.pitch) {
                let lo = pitches.min() ?? f.pitch
                let hi = pitches.max() ?? f.pitch
                dist = min(abs(f.pitch - lo), abs(f.pitch - hi)) - 0.5
            }
            let pitchProx = max(0.0, 1.0 - dist / 12.0)
            var direction = 0.5
            if let d1 = lastDelta {
                let d2 = f.pitch - tailPitch
                direction = d1 == 0 || d2 == 0 ? 1.0 : ((d1 > 0) == (d2 > 0) ? 1.0 : 0.0)
            }
            let durSim = tailDuration > 0 && f.duration > 0
                ? 1.0 - min(abs(Foundation.log2(f.duration / tailDuration)), 2.0) / 2.0
                : 0.5
            let salAgree = 1.0 - min(abs(f.normSalience - levelNorm), 0.5) / 0.5
            return 0.5 * pitchProx + 0.2 * direction + 0.15 * durSim + 0.15 * salAgree
        }
    }

    /// 转移分配代价（spec Step 2）：
    /// cost = w1·|Δpitch|（八度条件豁免）+ w2·走势二阶突变 + w3·gap 罚（衔接
    /// 匹配达标清零）+ 衔接次级项（时值/显著度水平，仅 gap > 0）。
    /// 「− salience 权重」按 spec 公式加入：它对同一音符的所有候选轨迹同值，
    /// 在「延续 vs 新开」比较中双边抵消，等效于固定的代价上限 trajNewCost。
    private static func joinCost(
        _ f: TrajectoryFeature, _ t: TrajectoryHypothesis
    ) -> Double {
        let rawDelta = abs(f.pitch - t.tailPitch)
        // 八度条件豁免（双条件）：|Δ| ≈ 12 且轨迹近期历史含同音/八度重现，
        // 且落点在轨迹历史音域内（声部内八度往复）——三者缺一按裸距离计罚。
        // （b 场景 60→72 教训：纯距离代价毁掉八度跳进旋律；a 场景 69→57 教训：
        // 仅音高类重现会让跨声部八度劫持豁免通道——音域回归条件补上第三道锁）
        let octaveExempt = abs(rawDelta - 12) < 0.5
            && t.isOctaveRecurrence(f.pitch)
            && t.isWithinHistoricalRange(f.pitch)
        var cost = trajW1 * (octaveExempt ? trajRecurrenceCost : rawDelta)
        // 走势二阶突变项：轨迹尾两音的走向 vs 新转移的方向/幅度差（豁免转移跳过
        // ——八度往返的走向突变是旋律语义，不作平滑罚）
        if !octaveExempt, let d1 = t.lastDelta {
            let d2 = f.pitch - t.tailPitch
            cost += trajW2 * min(abs(d2 - d1), 24)
        }
        let gap = f.start - t.tailEnd
        if gap > 0 {
            // 衔接匹配度（spec Step 3）：音高接近(主) + 走向一致(次) +
            // 时值相近(次) + 显著度水平相当(次)；达标 → 清 gap 罚（延续），
            // 否则收断线罚（自然断线倾向）
            let pitchProx = max(0, 1 - rawDelta / 12)
            var direction = 0.5 // 无走向历史（轨迹第二音）取中性
            if let d1 = t.lastDelta {
                let d2 = f.pitch - t.tailPitch
                direction = d1 == 0 || d2 == 0 ? 1.0 : ((d1 > 0) == (d2 > 0) ? 1.0 : 0.0)
            }
            let durSim = t.tailDuration > 0 && f.duration > 0
                ? 1 - min(abs(Foundation.log2(f.duration / t.tailDuration)), 2) / 2
                : 0.5
            let salAgree = 1 - min(abs(f.normSalience - t.levelNorm), 0.5) / 0.5
            let match = 0.5 * pitchProx + 0.2 * direction + 0.15 * durSim + 0.15 * salAgree
            if match < contMatchThreshold {
                cost += trajW3 * min(gap, trajMaxGap)
            }
            // 衔接次级裁决项（两轨迹竞争同一 gap 音符时的次级维度）
            if t.tailDuration > 0 && f.duration > 0 {
                cost += trajWDur * min(abs(Foundation.log2(f.duration / t.tailDuration)), 2)
            }
            cost += trajWLevel * min(abs(f.normSalience - t.levelNorm), 1)
        }
        return cost
    }

    /// 显著度主导保护（spec：归一化显著度差 ≥0.1 时显著度必胜，代价只裁决接近
    /// 情形）：若存在未分配候选 h——与 f 近同时（争夺同一衔接槽位）、对轨迹 t
    /// 具备延续资格且代价可行（真能占用该槽）、显著度高出 f ≥ salienceDominance
    /// ——则 f 让位（不得加入 t，转投其他轨迹或新开）。h 不可行时不构成竞争。
    /// 仅扫描 f.start ± dominanceClaimWindow 的未分配候选（feats 按 start 升序，
    /// 二分定位窗口），保证确定性。
    private static func isDominanceBarred(
        _ f: TrajectoryFeature, t: TrajectoryHypothesis,
        feats: [TrajectoryFeature], assigned: Set<Int>
    ) -> Bool {
        var lo = 0, hi = feats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if feats[mid].start < f.start - dominanceClaimWindow { lo = mid + 1 } else { hi = mid }
        }
        var k = lo
        while k < feats.count, feats[k].start <= f.start + dominanceClaimWindow {
            let h = feats[k]
            if h.group != f.group, !assigned.contains(h.group),
               h.normSalience - f.normSalience >= salienceDominance,
               h.start >= t.tailStart + trajMinOnsetSep,
               h.start <= t.tailEnd + trajMaxGap,
               joinCost(h, t) <= trajNewCost {
                return true
            }
            k += 1
        }
        return false
    }

    /// beam 轨迹追踪一遍（spec Step 2–3）：候选组按 start 升序分 onset 簇，
    /// 簇内显著度降序处理（同拍声部竞争显著度高者先占坑）；每组在「延续最优
    /// 轨迹（代价 ≤ trajNewCost）/ 新开轨迹」间决策；beam 超宽按评分剪枝。
    /// 返回全部轨迹假设（含被剪枝者——已分配音符保留在各自轨迹中，最终统一
    /// 参与评分）。纯函数、确定性：簇划分/簇内排序/代价决胜/剪枝决胜均为全序。
    private static func trackTrajectories(
        _ candGroups: [Int], groups: [MergeGroup]
    ) -> [TrajectoryHypothesis] {
        guard !candGroups.isEmpty else { return [] }
        // Step 1 特征层：归一化显著度以本遍候选最大值为基准（主导保护口径）
        var salienceMax = 0.0
        for g in candGroups {
            let em = groups[g].sig * registerPrior(groups[g].midi)
            if em > salienceMax { salienceMax = em }
        }
        var feats: [TrajectoryFeature] = []
        feats.reserveCapacity(candGroups.count)
        for g in candGroups { // candGroups 已按 (start, midi) 升序 → feats 按 start 升序
            let gr = groups[g]
            let em = gr.sig * registerPrior(gr.midi)
            feats.append(TrajectoryFeature(
                group: g, pitch: gr.midi, start: gr.start, end: gr.end,
                duration: gr.dur, salience: em,
                normSalience: salienceMax > 0 ? em / salienceMax : 0.0))
        }

        var assigned = Set<Int>()
        var beam: [TrajectoryHypothesis] = []
        var finished: [TrajectoryHypothesis] = []
        var creationCounter = 0

        // onset 簇划分：与簇首 start 差 ≤ onsetClusterWindow 的连续候选同簇
        var i = 0
        while i < feats.count {
            var j = i
            while j < feats.count,
                  feats[j].start - feats[i].start <= onsetClusterWindow {
                j += 1
            }
            // 簇内处理序：显著度降序 → pitch 升序 → 序号（确定性总序）
            let cluster = Array(i..<j).sorted {
                let a = feats[$0], b = feats[$1]
                if a.normSalience != b.normSalience { return a.normSalience > b.normSalience }
                if a.pitch != b.pitch { return a.pitch < b.pitch }
                return $0 < $1
            }
            for fi in cluster {
                let f = feats[fi]
                // 候选延续轨迹：资格窗口（起音间隔 + 衔接容忍窗，音内部起音合法
                // ——解码时长抖动会把下一音符起点拉进尾音内部，旧「tailEnd−重叠
                // 容忍」窗口曾因此把自家链拒之门外）、未被声部同质门/主导保护
                // 阻止、代价 ≤ trajNewCost 者中代价最小者胜（同价取 beam 序在先
                // ——扫描顺序固定，严格 < 保证）
                var best: (beamIndex: Int, cost: Double)?
                for ti in beam.indices {
                    let t = beam[ti]
                    guard f.start >= t.tailStart + trajMinOnsetSep,
                          f.start <= t.tailEnd + trajMaxGap else { continue }
                    // 声部同质门（对称、自适应）：音符与轨迹显著度水平差 ≥ 门值
                    // 禁止加入——高显著度音符不得被更安静的轨迹以「距离更近」的
                    // 代价优势吸走（b 场景旋律 72 距 counter 尾仅 8 半音 vs 本轨迹
                    // 八度），低显著度音符也不得混入更响的链（垫音/和声混入旋律
                    // 线）；门值随链内显著度标准差自适应（均匀声部收紧到下限、
                    // 动态声部放宽），双向同断杜绝「跳板轨迹」双向吸收
                    if abs(f.normSalience - t.levelNorm) >= t.salienceGate() { continue }
                    if isDominanceBarred(f, t: t, feats: feats, assigned: assigned) {
                        continue
                    }
                    let cost = joinCost(f, t)
                    if cost <= trajNewCost, best == nil || cost < best!.cost {
                        best = (ti, cost)
                    }
                }
                if let b = best {
                    beam[b.beamIndex].extend(f)
                } else {
                    // 长程重衔接（spec 建议③断线重续）：短程无解时，在
                    // reattachMaxGap 内寻找休眠轨迹——衔接匹配度达门槛（且声部
                    // 同质门通过）者跨 gap 延续。顺序处理天然保证「gap 内没有
                    // 更好的归属竞争」：更早的候选已先行处理（衔接成功则尾前移，
                    // 失败则被门/代价明确拒绝），不会留更好候选给后来者跳过。
                    // 多轨迹可达时取匹配度最高者（同分取早开轨迹，确定性）。
                    var reattach: (beamIndex: Int, match: Double)?
                    for ti in beam.indices {
                        let t = beam[ti]
                        guard f.start > t.tailEnd + trajMaxGap,
                              f.start <= t.tailEnd + reattachMaxGap else { continue }
                        if abs(f.normSalience - t.levelNorm) >= t.salienceGate() { continue }
                        let m = t.reattachMatch(f)
                        if m >= reattachMatchThreshold,
                           reattach == nil || m > reattach!.match
                            || (m == reattach!.match
                                && t.creationIndex < beam[reattach!.beamIndex].creationIndex) {
                            reattach = (ti, m)
                        }
                    }
                    if let r = reattach {
                        beam[r.beamIndex].extend(f)
                    } else {
                        // 无候选 / 代价超限 / 重衔接不可达 → 新开轨迹
                        beam.append(TrajectoryHypothesis(seed: f, creationIndex: creationCounter))
                        creationCounter += 1
                    }
                }
                assigned.insert(f.group)
                // beam 剪枝：评分最低者移入 finished（决胜链：评分 → 累计显著度
                // → 时长 → 晚开先弃，全序确定性）
                if beam.count > beamWidth {
                    var worst = 0
                    for k in 1..<beam.count {
                        let a = beam[k], b = beam[worst]
                        if (a.score, a.sumSalience, a.totalDuration, -a.creationIndex)
                            < (b.score, b.sumSalience, b.totalDuration, -b.creationIndex) {
                            worst = k
                        }
                    }
                    finished.append(beam.remove(at: worst))
                }
            }
            i = j
        }
        finished.append(contentsOf: beam)
        return finished
    }

    // MARK: - 主旋律概率泛化（spec: generalize-voice-roles-by-probability）

    /// 候选旋律线的主旋律概率分布：raw_i / Σraw（Σ = 100%）。角色选择层的
    /// 显式概率模型——每条候选线有可解释的"主旋律概率份额"，role 由概率
    /// 分布泛化决定（melody = argmax 份额；counter 候选取份额最高者且全局
    /// 份额 ≥ countermelodyProbabilityThreshold）。Σ ≤ 0（含负值防护——
    /// 轨迹评分非负但防御）时退化为均分 1/n：零和时无显著度质量信号，均分
    /// 保证概率仍有定义且决策由决胜链产生（确定性）。空输入返回空数组。
    /// 纯函数、确定性：同输入同输出（份额仅依赖输入值，无迭代顺序歧义）。
    static func mainMelodyProbabilities(rawScores: [Double]) -> [Double] {
        guard !rawScores.isEmpty else { return [] }
        let total = rawScores.reduce(0, +)
        guard total > 0 else {
            return [Double](repeating: 1.0 / Double(rawScores.count), count: rawScores.count)
        }
        return rawScores.map { $0 / total }
    }

    /// 角色选择（spec Step 4）：主/副旋律 = 主旋律概率份额 argmax（= 评分
    /// 最高，Σ显著度×连续覆盖）且非碎片（总时长 ≥ minLineTotalDuration）的
    /// 轨迹。决胜链：概率份额 → 评分 → 累计显著度 → 时长 → 均值音高 → 早开
    /// 优先（全序确定性）。份额 = score/Σscore 与 score 经同一正分母单调
    /// 等价（份额序 = 评分序，Σ=0 均分时份额全等），故概率 argmax 与既有
    /// 评分 argmax 逐位一致——主旋律选择行为零变化（spec 设计目标）；平票
    /// 时既有元组决胜链逐位接办（评分项即原主键）。
    private static func bestTrajectory(
        _ trajectories: [TrajectoryHypothesis]
    ) -> TrajectoryHypothesis? {
        let probabilities = mainMelodyProbabilities(rawScores: trajectories.map(\.score))
        var best: TrajectoryHypothesis?
        var bestProbability = 0.0
        for (idx, t) in trajectories.enumerated()
        where t.totalDuration >= minLineTotalDuration {
            guard let b = best else {
                best = t
                bestProbability = probabilities[idx]
                continue
            }
            let tk = (t.score, t.sumSalience, t.totalDuration, t.meanPitch, -t.creationIndex)
            let bk = (b.score, b.sumSalience, b.totalDuration, b.meanPitch, -b.creationIndex)
            if probabilities[idx] > bestProbability
                || (probabilities[idx] == bestProbability && tk > bk) {
                best = t
                bestProbability = probabilities[idx]
            }
        }
        return best
    }

    /// counter 候选的全局主旋律概率份额：K.score / Σ(Pass 1 全部合格候选
    /// 轨迹 score)。分母为 Pass 1 候选轨迹全集（candGroups 的 beam 追踪
    /// 结果，含被剪枝与碎片轨迹——候选显著度质量的全集口径）：Pass 2 候选
    /// 集是 Pass 1 经掩码/音高上下文吸收/显著度比值门裁剪后的子集，以其为
    /// 分母会把幸存线份额整体放大，低概率线（用户示例 8%）可能因候选稀疏
    /// 被放行；Pass 1 全集口径下份额 = 该线占全部候选旋律显著度质量的
    /// 比例，与概率模型语义一致。Σ ≤ 0（全零显著度的极端输入，如纯静音）
    /// 记 0 份额：无旋律质量信号不产出副旋律（同时规避 0/0 的 NaN 比较）。
    private static func counterGlobalShare(
        _ counter: TrajectoryHypothesis, pass1Trajectories: [TrajectoryHypothesis]
    ) -> Double {
        let total = pass1Trajectories.reduce(0.0) { $0 + $1.score }
        guard total > 0 else { return 0 }
        return counter.score / total
    }

    /// 选中轨迹 → (成员原始音符下标集, 组下标序列)。
    /// 合并视图成员共享角色（回写原始音符），组下标序列供 fragmentMerged
    /// 时间归一使用（语义与 v6 argmaxPass 的 wonGroups 完全一致）。
    private static func selectedTrajectoryNotes(
        _ trajectories: [TrajectoryHypothesis], groups: [MergeGroup]
    ) -> (notes: Set<Int>, wonGroups: [Int]) {
        guard let win = bestTrajectory(trajectories) else { return ([], []) }
        var result = Set<Int>()
        for g in win.groups { result.formUnion(groups[g].members) }
        return (result, win.groups)
    }

    // MARK: - 旋律链构建（spec: stitch-melody-chain「算法设计」，Pass 1 选择层）

    /// 旋律链构建：以概率 argmax 最佳轨迹为起点，双向循环接入满足全部约束的
    /// 落选轨迹段落，链成员全部轨迹的音符（组下标集并集）统一获得 melody 角色
    /// ——真实音乐主旋律被 >reattachMaxGap 断开/被门拒绝的段落由此接回主线。
    ///
    /// 候选约束（每轮全部满足方可入链，防吞并副旋律/垫音/和声线）：
    /// 0a. 概率份额 < countermelodyProbabilityThreshold（反吞并保护一，
    ///     与 counterGlobalShare 同口径——counter 级素材的完整声部线留给
    ///     Pass 2，链只整合低于 counter 级的碎片段落）；
    /// 0b. 均值音高在种子轨迹音域 ± chainRegisterMargin 内（反吞并保护二，
    ///     音区硬门——切断「误接一段 → 音域扩张 → 更远段可接」的音域棘轮）；
    /// 0c. 各组到链旋律线时间邻域音符的音高距离均值 ≤
    ///     melodyChainLocalPitchMax（反吞并保护三，局部音高贴合门——「续段」
    ///     贴合所嵌入旋律线的走向，偏离段是另一声部在自身音区活动；桥接
    ///     >3s 旋律断裂的候选用截尾均值，音区过渡豁免仅作用于断裂处）；
    /// 1. 时间间隔 ≤ melodyChainMaxGap：候选与链时间跨度（spanStart/spanEnd）
    ///    的间隔，时间重叠记 0（链尾或链头均可接，双向）；
    /// 2. 时间重叠率 ≤ melodyChainOverlapMax：候选与链音符的共现时长占候选总
    ///    时长的比例——与主链同时发声的平行和声线/重复声部不是「续段」；
    /// 3. 声部同质门：|候选 levelNorm − 链加权 levelNorm| < 链级 salienceGate()
    ///    （沿用 TrajectoryHypothesis 机制：max(下限, K×σ)，链级聚合口径 =
    ///    整条链视为「一条大轨迹」）；
    /// 4. 衔接匹配度 chainMatch ≥ melodyChainMatchThreshold（与 reattachMatch
    ///    同构，链级差异见 chainMatch 注释）。
    ///
    /// 决胜链：match 最高 → gap 小 → 总时长长 → 早开（creationIndex 全程唯一，
    /// 全序确定）。接入后链的跨度/音高并集/加权显著度水平/均值时值随之更新，
    /// 循环至无候选（每轮链至少 +1 条轨迹，必然收敛）。
    /// 纯函数、确定性：候选扫描按轨迹数组序、Set 迭代一律 sorted、聚合累加按
    /// 接入顺序；无 force unwrap。单轨迹情形（合成基准）无候选可接，链 = 最佳
    /// 轨迹，行为零变化。
    private static func chainedTrajectoryNotes(
        _ trajectories: [TrajectoryHypothesis], groups: [MergeGroup]
    ) -> (notes: Set<Int>, wonGroups: [Int]) {
        guard let seed = bestTrajectory(trajectories) else { return ([], []) }

        // 反吞并保护一（概率份额门，与 counterGlobalShare 同口径）：全局份额
        // ≥ countermelodyProbabilityThreshold 的轨迹是「完整声部线」——按概率
        // 模型（spec: generalize-voice-roles-by-probability）它属于 counter 级
        // 素材，不是主旋律的「断开续段」；链吞并它会掏空 Pass 2 的 counter
        // 候选池（份额 < 5% 的弱线触发概率门槛归零，D2 失守）。实测 shamshir：
        // counter 线（份额 0.0567）overlap 仅 0.365（主副旋律交替多于重叠，
        // 时间重叠约束拦不住）、chainMatch 0.976（音高在链域内，匹配项拦不住
        // ——链并集音域覆盖其音区），必须份额门结构排除；链只整合低于
        // counter 级的碎片段落。
        let pass1ScoreTotal = trajectories.reduce(0.0) { $0 + $1.score }

        // 反吞并保护二（音区硬门）：候选均值音高必须落在**种子轨迹音域** ±
        // chainRegisterMargin 半音内——均值音高超出主旋律主干音域的段是另一声部
        // （低音/和声音区），不是主旋律续段。基准取种子（argmax 主干，跨全曲
        // 351 组）而非链并集：并集随接入扩张，「±2 边距 + 并集更新」仍会棘轮式
        // 下探/上探（实测 shamshir 垃圾碎片被逐步放进 42-89 半音全域，A' P90
        // 8 → 20），种子音域固定不随接入变化，棘轮被彻底切断。软性 pitchProx
        // （chainMatch 内，12 半音衰减、对链并集）保持 spec 同构不变。
        func registerBlocked(_ t: TrajectoryHypothesis) -> Bool {
            guard let lo = seed.pitches.min(), let hi = seed.pitches.max() else { return true }
            return !(t.meanPitch >= lo - chainRegisterMargin
                && t.meanPitch <= hi + chainRegisterMargin)
        }

        // 反吞并保护三（局部音高贴合门）：候选各组到链旋律线（时间邻域的前/后
        // 最近音符）的音高距离**截尾均值** ≤ melodyChainLocalPitchMax——单侧
        // 距离 > melodyChainLocalPitchTrim（跨八度）的侧不计入（旋律自身跨八度
        // 断裂处，远侧距离不代表声部差异，计入会误杀真旋律的音区过渡段；两侧
        // 均超限 = 无同音区锚点，仍拒）。截尾豁免仅对「桥接旋律断裂」的候选
        // 生效（跨度与链上 >melodyChainSegmentGap 的无音符间隙相交）——非断裂
        // 区维持严格全均值，防止和声碎片借豁免涌入推高主/副边界角色抖动
        //（实测 shamshir：无限制截尾 B 30.6 → 38.3 次/分）。链音符的邻居查找
        // O(chainGroups) 线性扫描（链规模数百组，成本可忽略）。
        func localPitchAdherent(_ t: TrajectoryHypothesis, trimmed: Bool) -> Bool {
            var sum = 0.0
            var count = 0
            for g in t.groups {
                let gr = groups[g]
                var prevEnd = -Double.greatestFiniteMagnitude
                var prevMidi = 0.0
                var nextStart = Double.greatestFiniteMagnitude
                var nextMidi = 0.0
                for cg in chainGroups.sorted() {
                    let cgr = groups[cg]
                    if cgr.end <= gr.start {
                        if cgr.end > prevEnd { prevEnd = cgr.end; prevMidi = cgr.midi }
                    } else if cgr.start >= gr.end {
                        if cgr.start < nextStart { nextStart = cgr.start; nextMidi = cgr.midi }
                    }
                }
                if prevEnd > -Double.greatestFiniteMagnitude {
                    let d = abs(gr.midi - prevMidi)
                    if !trimmed || d <= melodyChainLocalPitchTrim { sum += d; count += 1 }
                }
                if nextStart < Double.greatestFiniteMagnitude {
                    let d = abs(gr.midi - nextMidi)
                    if !trimmed || d <= melodyChainLocalPitchTrim { sum += d; count += 1 }
                }
            }
            guard count > 0 else { return false }
            return sum / Double(count) <= melodyChainLocalPitchMax
        }

        /// 候选跨度是否与链上 >melodyChainSegmentGap 的无音符间隙相交（桥接
        /// 判定，音区过渡豁免的作用域）。链音符区间按 start 排序线性扫描。
        func bridgesMelodyHole(_ t: TrajectoryHypothesis) -> Bool {
            var prevEnd = -Double.greatestFiniteMagnitude
            for note in chainSortedNotes {
                if note.0 - prevEnd > melodyChainSegmentGap,
                   t.spanStart <= note.0, t.spanEnd >= prevEnd {
                    return true
                }
                prevEnd = max(prevEnd, note.1)
            }
            return false
        }

        // 链级聚合状态（整条链视为「一条大轨迹」，公式与 TrajectoryHypothesis
        // 同名机制一致）：
        // - chainLevelNorm：按音符数加权的归一化显著度均值（各轨迹 levelNorm 是
        //   其音符均值，音符数加权即还原链内全部音符的精确均值）；
        // - chainSumSqNorm：各轨迹平方和累加 → 链级方差 = Σx²/n − mean²；
        // - chainPitches：链内全部轨迹音高拼接（音域取 min/max，拼接保序）；
        // - 均值时值 = 链总时长 / 链音符数（时值相近项的段级基准）。
        var chainIds: Set<Int> = [seed.creationIndex]
        var chainGroups: Set<Int> = []
        var chainPitches = seed.pitches
        var chainSpanStart = seed.spanStart
        var chainSpanEnd = seed.spanEnd
        var chainLevelNorm = seed.levelNorm
        var chainSumSqNorm = seed.sumSqNorm
        var chainNoteCount = seed.groups.count
        var chainTotalDuration = seed.totalDuration
        // 链的尾/头轨迹（走势一致项的边界状态）：尾 = spanEnd 最大、头 =
        // spanStart 最小（严格比较，同值保持原状，确定性）
        var tail = seed
        var head = seed
        chainGroups.formUnion(seed.groups)
        // 链音符区间（按 start 排序，接入时增量重排）——桥接判定用
        var chainSortedNotes: [(Double, Double)] = seed.groups
            .map { (groups[$0].start, groups[$0].end) }
            .sorted { $0.0 < $1.0 }

        var chain: [TrajectoryHypothesis] = [seed]
        while true {
            var bestCand: (traj: TrajectoryHypothesis, match: Double, gap: Double)?
            for t in trajectories
            where !chainIds.contains(t.creationIndex) {
                // 反吞并保护一：概率份额门（counter 级素材不参与链，见函数头注释）
                let share = pass1ScoreTotal > 0 ? t.score / pass1ScoreTotal : 0
                guard share < countermelodyProbabilityThreshold else { continue }
                // 反吞并保护二：音区硬门（种子音域 ± chainRegisterMargin）
                guard !registerBlocked(t) else { continue }
                // 反吞并保护三：局部音高贴合门（严格全均值；桥接旋律断裂的
                // 候选用截尾均值——音区过渡豁免仅作用于断裂处）
                guard localPitchAdherent(t, trimmed: bridgesMelodyHole(t)) else { continue }
                // 约束 1：时间间隔（与链跨度两端取近者，时间重叠记 0）
                let tailGap = t.spanStart - chainSpanEnd   // 接链尾侧的间隔（负 = 重叠）
                let headGap = chainSpanStart - t.spanEnd   // 接链头侧的间隔（负 = 重叠）
                let gap = max(0.0, max(tailGap, headGap))
                guard gap <= melodyChainMaxGap else { continue }
                // 约束 2：时间重叠率 = 候选与链音符共现时长 / 候选总时长。
                // 逐组对链内各组求共现并按组时长封顶（链内组互不重叠时为精确值，
                // 封顶保证链内组相互重叠也不放大比率）
                var overlap = 0.0
                for g in t.groups {
                    let gr = groups[g]
                    var co = 0.0
                    for cg in chainGroups.sorted() {
                        let cgr = groups[cg]
                        co += max(0.0, min(gr.end, cgr.end) - max(gr.start, cgr.start))
                    }
                    overlap += min(co, gr.dur)
                }
                let overlapRatio = t.totalDuration > 0
                    ? min(overlap / t.totalDuration, 1.0) : 1.0
                guard overlapRatio <= melodyChainOverlapMax else { continue }
                // 约束 3：声部同质门（链级聚合门值，公式同 TrajectoryHypothesis.salienceGate）
                let variance = max(
                    0.0,
                    chainSumSqNorm / Double(chainNoteCount) - chainLevelNorm * chainLevelNorm)
                let gate = max(salienceGateFloor, salienceGateSigmaK * Foundation.sqrt(variance))
                guard abs(t.levelNorm - chainLevelNorm) < gate else { continue }
                // 约束 4：衔接匹配度（接入侧按最近边界预判：tailGap > headGap =
                // 候选在链尾一侧或更靠尾——链外候选该判定精确，链内候选取重叠
                // 较小侧，仅影响 0.2 权重的走势项且方向中性兜底）
                let match = chainMatch(
                    t,
                    chainPitches: chainPitches,
                    chainLevelNorm: chainLevelNorm,
                    chainMeanDuration: chainTotalDuration / Double(chainNoteCount),
                    tail: tail,
                    head: head,
                    attachAtTail: tailGap > headGap
                )
                guard match >= melodyChainMatchThreshold else { continue }
                // 决胜：match 高 → gap 小 → 总时长长 → 早开（creationIndex 唯一，全序）
                if let cur = bestCand {
                    let better = match > cur.match
                        || (match == cur.match
                            && (gap < cur.gap
                                || (gap == cur.gap
                                    && (t.totalDuration > cur.traj.totalDuration
                                        || (t.totalDuration == cur.traj.totalDuration
                                            && t.creationIndex < cur.traj.creationIndex)))))
                    if better { bestCand = (t, match, gap) }
                } else {
                    bestCand = (t, match, gap)
                }
            }
            guard let pick = bestCand else { break }
            // 接入：更新链级状态（聚合公式见函数头注释；累加顺序 = 接入顺序，
            // 确定性）
            let p = pick.traj
            chainIds.insert(p.creationIndex)
            chain.append(p)
            chainGroups.formUnion(p.groups)
            chainSortedNotes.append(contentsOf:
                p.groups.map { (groups[$0].start, groups[$0].end) })
            chainSortedNotes.sort { $0.0 < $1.0 }
            chainPitches.append(contentsOf: p.pitches)
            chainSpanStart = min(chainSpanStart, p.spanStart)
            chainSpanEnd = max(chainSpanEnd, p.spanEnd)
            let newCount = chainNoteCount + p.groups.count
            chainLevelNorm = (chainLevelNorm * Double(chainNoteCount)
                + p.levelNorm * Double(p.groups.count)) / Double(newCount)
            chainSumSqNorm += p.sumSqNorm
            chainNoteCount = newCount
            chainTotalDuration += p.totalDuration
            if p.spanEnd > tail.spanEnd { tail = p }
            if p.spanStart < head.spanStart { head = p }
        }

        // 链成员全部轨迹的音符（组下标集并集）→ melody 集；组序列按时间序输出
        // （fragmentMerged 时间归一处理与序无关，保持确定性输出口径）
        var result = Set<Int>()
        var won: [Int] = []
        for t in chain {
            won.append(contentsOf: t.groups)
            for g in t.groups { result.formUnion(groups[g].members) }
        }
        won.sort { (groups[$0].start, groups[$0].midi) < (groups[$1].start, groups[$1].midi) }
        return (result, won)
    }

    /// counter 轮廓回收（Task 3）：把最终 counter 集中「落在旋律轮廓带内且
    /// 时间邻接链成员」的音符回收为 melody——这些是主旋律被解码切碎后误分配
    /// 为副旋律的碎片（用户截图的黄白/黄蓝交替的直接来源）。与 contourFillNotes
    /// 互为逆操作，两者共同保证不变式「轮廓带内必属旋律」，与 G2 指标口径
    /// 直接对齐。返回应从 counter 移出的音符下标集合（确定性全序）。
    private static func contourReclaimNotes(
        counterSet: Set<Int>,
        melodySet: Set<Int>,
        notes: [MelodyNote],
        salience: [Double]
    ) -> Set<Int> {
        guard !counterSet.isEmpty, !melodySet.isEmpty, salience.count == notes.count
        else { return [] }
        let contour = MelodyContour(notes: melodySet.map { notes[$0] })
        guard !contour.isEmpty, contour.timeDomain != nil else { return [] }

        // 链内显著度下界（回收的响度基准，同 contourFillNotes 的口径）
        var melodyFloor = Double.greatestFiniteMagnitude
        for i in melodySet {
            melodyFloor = min(melodyFloor,
                              salience[i] * registerPrior(Double(notes[i].midiNote)))
        }
        guard melodyFloor.isFinite, melodyFloor > 0 else { return [] }

        // 链成员时间轴（升序）
        let melodyTimes = melodySet.map { notes[$0].startTime }.sorted()

        var reclaimed: [Int] = []
        for i in counterSet.sorted() {
            let note = notes[i]
            // 响度门：明显更安静的 counter 音符不回收（伴奏/和声，非旋律碎片）
            let em = salience[i] * registerPrior(Double(note.midiNote))
            guard em >= melodyFloor * contourReclaimSalienceRatio else { continue }
            // 轮廓带内
            let mid = (note.startTime + note.endTime) / 2
            guard let y = contour.pitch(at: mid),
                  abs(Double(note.midiNote) - y) <= contourFillTolerance else { continue }
            // 时间邻接链成员（回收窗比填充窗更紧，见 contourReclaimWindow）
            var minDelta = Double.greatestFiniteMagnitude
            for t in melodyTimes {
                let d = abs(note.startTime - t)
                if d < minDelta { minDelta = d }
            }
            guard minDelta <= contourReclaimWindow else { continue }
            // 同音高判据（决定性）：解码碎片是同一物理音被切开，其音高与所属
            // melody 音符**完全相同**；真正的副旋律是独立声部，音高不同
            // （合成基准 dual-a counter=64 vs melody=69、dual-b 62 vs 64）。
            // 实测重叠判据无效——基准中 counter 与 melody 同时发声确实重叠，
            // F 仍 89.7/87.7；音高才是区分二者的稳定特征。
            var samePitchNeighbour = false
            for j in melodySet where notes[j].midiNote == note.midiNote {
                let o = min(note.endTime, notes[j].endTime)
                    - max(note.startTime, notes[j].startTime)
                if o >= contourReclaimOverlap { samePitchNeighbour = true; break }
            }
            guard samePitchNeighbour else { continue }
            reclaimed.append(i)
        }
        return Set(reclaimed)
    }

    /// 旋律轮廓：链成员音符按 (start, midi) 排序后，相邻音符间线性插值得到的
    /// 音高曲线。首音符之前 / 末音符之后无定义（不填充——链外的同音高伴奏
    /// 与旋律线无时间关联，填充它们会凭空造线）。纯值类型、无副作用。
    struct MelodyContour {
        /// 轮廓控制点（时间升序、音高为 MIDI 半音值；同 startTime 已去重）
        private let points: [(t: Double, y: Double)]

        init(notes: [MelodyNote]) {
            let sorted = notes.sorted {
                ($0.startTime, $0.midiNote) < ($1.startTime, $1.midiNote)
            }
            // 同 startTime 只保留音高最低者（确定性去重，避免零长度插值段）
            var deduped: [(t: Double, y: Double)] = []
            for note in sorted {
                if let last = deduped.last, last.t == note.startTime {
                    if Double(note.midiNote) < last.y {
                        deduped[deduped.count - 1].y = Double(note.midiNote)
                    }
                } else {
                    deduped.append((note.startTime, Double(note.midiNote)))
                }
            }
            points = deduped
        }

        var isEmpty: Bool { points.count < 2 }

        /// 轮廓定义域（首末控制点时间）；控制点不足 2 个时为 nil
        var timeDomain: ClosedRange<Double>? {
            guard points.count >= 2, let first = points.first, let last = points.last
            else { return nil }
            return first.t...last.t
        }

        /// 线性插值查询；定义域外或控制点不足返回 nil
        func pitch(at t: Double) -> Double? {
            guard points.count >= 2 else { return nil }
            guard let first = points.first, let last = points.last else { return nil }
            guard t >= first.t, t <= last.t else { return nil }
            if t == last.t { return last.y }
            // 二分定位插值区间（点集已按时间升序）
            var lo = 0
            var hi = points.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if points[mid].t <= t { lo = mid } else { hi = mid }
            }
            let a = points[lo], b = points[hi]
            let span = b.t - a.t
            guard span > 0 else { return a.y }
            return a.y + (b.y - a.y) * ((t - a.t) / span)
        }
    }

    /// 轮廓逐音符填充（spec: fill-melody-contour-gaps）：返回应补入 melody 角色
    /// 的音符下标集合（不含已在 melodySet 中的音符）。
    ///
    /// 接纳条件（全部满足）：
    /// 1. 到最近链成员音符的起始时间差 ≤ contourFillWindow；
    /// 2. 音符中点时刻的轮廓有定义（落在链首末之间）；
    /// 3. 音高到轮廓值的距离 ≤ contourFillTolerance；
    /// 4. 未被 counter 级轨迹占用（全局概率份额 ≥ 门槛的轨迹所含全部音符
    ///    ——反吞并保护，与链的份额门同口径，见 counterGlobalShare）；
    /// 4b. 不属 counter 潜在声部素材（通过声部同质门且相对重叠 melody 达
    ///     contourFillCounterGuard 倍显著度的组——与 counter 判据一致，把
    ///     melody/counter 的职责边界由阈值调平改为候选归属划清）。
    ///
    /// 离群保护：填充后 melody 集合中「到轮廓距离 > 容差」的音符占比超过
    /// contourFillMaxOutlier 时，按距离降序 → startTime 升序 → 下标升序回滚至
    /// 达标（确定性全序）。链成员天然落在轮廓上，离群只可能来自本步误纳。
    private static func contourFillNotes(
        melodySet: Set<Int>,
        pool: [Int],
        notes: [MelodyNote],
        groups: [MergeGroup],
        pass1Trajectories: [TrajectoryHypothesis],
        emByNote: [Int: Double],
        groupIndexByNote: [Int: Int]
    ) -> Set<Int> {
        // 轮廓控制点用链成员**音符**（链以组为单位选出，此处展开为音符级——
        // 用户症状发生在音符粒度：黄白交替即单个音符未被标黄）
        let contour = MelodyContour(notes: melodySet.map { notes[$0] })
        guard !contour.isEmpty, contour.timeDomain != nil else { return [] }

        // 反吞并：counter 级轨迹（全局份额 ≥ 门槛）所占音符不参与填充
        let pass1Total = pass1Trajectories.reduce(0.0) { $0 + $1.score }
        var counterLevelNotes = Set<Int>()
        if pass1Total > 0 {
            for t in pass1Trajectories
            where t.score / pass1Total >= countermelodyProbabilityThreshold {
                for g in t.groups { counterLevelNotes.formUnion(groups[g].members) }
            }
        }

        // 链成员时间轴（升序）——时间邻接窗查询
        let chainTimed = melodySet.map { (notes[$0].startTime, notes[$0].endTime) }
            .sorted { $0.0 < $1.0 }

        // counter 潜在占用预判（Task 3 结构性修复，详见 contourFillCounterGuard）：
        // 链级显著度均值与方差 → 门值（公式同 TrajectoryHypothesis.salienceGate）
        var chainLevelSum = 0.0
        var chainLevelSq = 0.0
        for i in melodySet {
            let em = emByNote[i] ?? 0
            chainLevelSum += em
            chainLevelSq += em * em
        }
        let chainNoteCount = Double(melodySet.count)
        let chainLevelNorm = chainNoteCount > 0 ? chainLevelSum / chainNoteCount : 0
        let chainVariance = chainNoteCount > 1
            ? max(0.0, chainLevelSq / chainNoteCount - chainLevelNorm * chainLevelNorm) : 0
        let chainGate = max(salienceGateFloor,
                            salienceGateSigmaK * Foundation.sqrt(chainVariance))
        // 候选组 → 其归一化显著度均值（em/链最大值归一，与轨迹特征口径一致）
        let chainEmMax = emByNote.values.max() ?? 0
        // 预判：仅当候选组与主链**时间重叠**（平行和声声部——主副旋律同时发声
        // 的区域）时，才按 counter 判据决定是否让位；与主链几乎不重叠的组
        // （旋律间隙处的碎片，被链门拒绝后待补入）直接放行——实测按组无差别
        // 预判会把这些碎片全部拦死（G2 反弹 90 → 192）。
        func isCounterLevelCandidate(_ groupIndex: Int) -> Bool {
            guard groupIndex >= 0, groupIndex < groups.count else { return false }
            let members = groups[groupIndex].members
            guard !members.isEmpty else { return false }
            let gr = groups[groupIndex]
            // 重叠率 = 共现时长 / 组总时长（与 melodyChainOverlapMax 同口径）
            var overlap = 0.0
            for m in members {
                let n = notes[m]
                var co = 0.0
                for i in melodySet
                where n.startTime < notes[i].endTime && notes[i].startTime < n.endTime {
                    co += max(0.0, min(n.endTime, notes[i].endTime)
                        - max(n.startTime, notes[i].startTime))
                }
                overlap += min(co, n.endTime - n.startTime)
            }
            let totalDur = members.reduce(0.0) { $0 + (notes[$1].endTime - notes[$1].startTime) }
            let overlapRatio = totalDur > 0 ? min(overlap / totalDur, 1.0) : 0
            // 非重叠（间隙处碎片）→ 不属平行和声，放行给填充
            guard overlapRatio > melodyChainOverlapMax else { return false }
            // 重叠组：先判「是否落在旋律轮廓带内」——落在轮廓带内者（距离 ≤
            // 容差）是主旋律被解码切碎的碎片，属旋律线本身，放行填充；
            // 明显偏出轮廓的组才是独立声部，按 counter 判据决定让位。
            // （实测：shamshir 的 counter 与主旋律多为主副交替、重叠率低，
            //  仅按重叠+响度预判会放行它们 → B 34.9、G2 90；本判据把
            //  「轮廓带内 = 属于旋律线」写进预判，与 G2 口径直接对齐）
            var onContour = 0
            var measured = 0
            for m in members {
                let n = notes[m]
                let mid = (n.startTime + n.endTime) / 2
                guard let y = contour.pitch(at: mid) else { continue }
                measured += 1
                if abs(Double(n.midiNote) - y) <= contourFillTolerance { onContour += 1 }
            }
            if measured > 0, onContour == measured { return false }  // 整组在轮廓上
            let ems = members.map { emByNote[$0] ?? 0 }
            let meanEm = ems.reduce(0, +) / Double(ems.count)
            let norm = chainEmMax > 0 ? meanEm / chainEmMax : 0
            guard abs(norm - chainLevelNorm) < chainGate else { return false }
            var bestMelEM = 0.0
            for i in melodySet
            where gr.start < notes[i].endTime && notes[i].startTime < gr.end {
                bestMelEM = max(bestMelEM, emByNote[i] ?? 0)
            }
            guard bestMelEM > 0 else { return false }
            return meanEm >= contourFillCounterGuard * bestMelEM
        }

        /// 候选接纳判定：返回 (是否接纳, 到轮廓距离)
        func evaluate(_ i: Int, groupIndex: Int) -> (accepted: Bool, distance: Double) {
            guard !counterLevelNotes.contains(i) else { return (false, .infinity) }
            // counter 潜在占用预判：属独立副旋律声部素材的组不参与填充
            // （职责边界划清，避免 melody/counter 抢同一批音符）。
            // 注意：groupIndex < 0 表示该音符未入任何候选组（解码时长不足被
            // 时长门限过滤的碎片）——这恰是填充的主要对象，不得拒绝。
            if groupIndex >= 0, isCounterLevelCandidate(groupIndex) {
                return (false, .infinity)
            }
            let note = notes[i]
            // 条件 1：时间邻接（到最近链成员音符起点的距离）
            var minDelta = Double.greatestFiniteMagnitude
            for ct in chainTimed {
                let delta = abs(note.startTime - ct.0)
                if delta < minDelta { minDelta = delta }
            }
            guard minDelta <= contourFillWindow else { return (false, .infinity) }
            // 条件 2 + 3：轮廓有定义且音高贴合
            let t = (note.startTime + note.endTime) / 2
            guard let y = contour.pitch(at: t) else { return (false, .infinity) }
            let d = abs(Double(note.midiNote) - y)
            guard d <= contourFillTolerance else { return (false, d) }
            return (true, d)
        }

        // 收集候选（池内未入链的音符，pool 已按 conf 门限 + 低音硬排除过滤）
        var accepted: [(index: Int, distance: Double)] = []
        for i in pool.sorted() where !melodySet.contains(i) {
            let verdict = evaluate(i, groupIndex: groupIndexByNote[i] ?? -1)
            if verdict.accepted { accepted.append((i, verdict.distance)) }
        }
        guard !accepted.isEmpty else { return [] }

        // 离群保护：填充后 melody 中的轮廓外音符占比不得超过上限。链成员是
        // 轮廓控制点本身（距离 0），离群只可能来自本步误纳——而误纳者已被
        // evaluate 的容差过滤，故此处只需统计链成员中因展开异常落在定义域外
        // 或超容差者（防御性，正常恒为 0）。
        var outlierCount = 0
        for i in melodySet {
            let note = notes[i]
            let t = (note.startTime + note.endTime) / 2
            guard let y = contour.pitch(at: t) else { continue }  // 定义域外不计入
            if abs(Double(note.midiNote) - y) > contourFillTolerance { outlierCount += 1 }
        }
        let totalMelody = melodySet.count + accepted.count
        let allowed = Int((Double(totalMelody) * contourFillMaxOutlier).rounded(.down))
        if outlierCount > allowed {
            let rollback = min(outlierCount - allowed, accepted.count)
            // 按距离降序 → startTime 升序 → 下标升序 回滚（确定性全序）
            accepted.sort {
                $0.distance != $1.distance ? $0.distance > $1.distance
                    : (notes[$0.index].startTime != notes[$1.index].startTime
                        ? notes[$0.index].startTime < notes[$1.index].startTime
                        : $0.index < $1.index)
            }
            accepted.removeLast(rollback)
        }
        return Set(accepted.map { $0.index })
    }


    /// 链衔接匹配度（与 reattachMatch 同构：音高接近链历史音域 0.5 主 + 走势
    /// 一致 0.2 + 时值相近 0.15 + 显著度水平相当 0.15），链级差异点：
    /// - 「历史音域」取整条链全部轨迹 pitches 并集的范围 [min, max]（±0.5 容差
    ///   同 reattachMatch 的 isWithinHistoricalRange 口径）——链是多段合成，
    ///   音域更宽更稳；
    /// - 音高接近对候选轨迹的**均值音高**计算（选实现稳的一侧：段端点可能是
    ///   断段边缘残帧/离群音，均值对段级噪声更鲁棒；均值落在链音域内即满分，
    ///   与「整段归属同一声部」的语义一致）；
    /// - 走势一致比较双方**内部**步进方向（链边界轨迹的最近步进 vs 候选靠边界
    ///   一侧的首/末步进）——段边界的大跳不参与裁决（与 reattachMatch 只用
    ///   轨迹内部 lastDelta 的口径一致）：尾侧取候选首步、头侧取候选末步，
    ///   任一侧无步进历史取中性 0.5，零步进不冲突记 1.0；
    /// - 时值相近以「候选均值时值 vs 链均值时值」计算（段级口径，log2 失配
    ///   封顶 2，同 reattachMatch 的 durSim 尺度）。
    private static func chainMatch(
        _ t: TrajectoryHypothesis,
        chainPitches: [Double],
        chainLevelNorm: Double,
        chainMeanDuration: Double,
        tail: TrajectoryHypothesis,
        head: TrajectoryHypothesis,
        attachAtTail: Bool
    ) -> Double {
        // 音高接近（主）：均值音高在链音域并集内（±0.5 容差）满分，超出按距
        // 最近端点的半音距离衰减（12 半音归零，与 reattachMatch 同尺度）
        var dist = 0.0
        if let lo = chainPitches.min(), let hi = chainPitches.max() {
            let inside = t.meanPitch >= lo - 0.5 && t.meanPitch <= hi + 0.5
            if !inside {
                dist = min(abs(t.meanPitch - lo), abs(t.meanPitch - hi)) - 0.5
            }
        } else {
            dist = 12.0 // 空音高防御（不可达：链至少含种子轨迹），保守拒接
        }
        let pitchProx = max(0.0, 1.0 - dist / 12.0)
        // 走势一致（次）：链边界轨迹的最近内部步进 vs 候选靠边界一侧的步进
        let boundaryDelta: Double? = attachAtTail
            ? tail.lastDelta
            : (head.pitches.count >= 2 ? head.pitches[1] - head.pitches[0] : nil)
        let candDelta: Double?
        if t.pitches.count < 2 {
            candDelta = nil
        } else if attachAtTail {
            candDelta = t.pitches[1] - t.pitches[0]
        } else {
            candDelta = t.pitches[t.pitches.count - 1] - t.pitches[t.pitches.count - 2]
        }
        var direction = 0.5
        if let d1 = boundaryDelta, let d2 = candDelta {
            direction = d1 == 0 || d2 == 0 ? 1.0 : ((d1 > 0) == (d2 > 0) ? 1.0 : 0.0)
        }
        // 时值相近（次）：候选均值时值 vs 链均值时值（任一侧非正取中性 0.5）
        let candMeanDuration = t.groups.isEmpty
            ? 0.0 : t.totalDuration / Double(t.groups.count)
        let durSim = chainMeanDuration > 0 && candMeanDuration > 0
            ? 1.0 - min(abs(Foundation.log2(candMeanDuration / chainMeanDuration)), 2.0) / 2.0
            : 0.5
        // 显著度水平相当（次）
        let salAgree = 1.0 - min(abs(t.levelNorm - chainLevelNorm), 0.5) / 0.5
        return 0.5 * pitchProx + 0.2 * direction + 0.15 * durSim + 0.15 * salAgree
    }

    // MARK: - conf 回退路径（v2 拍内二部匹配，单元测试手工音符用）

    /// 一条声部线：音符（排序后下标序列）+ 线尾衔接状态 + 音高/时长历史
    private struct VoiceLine {
        var noteIndices: [Int]
        var lastStart: TimeInterval
        var lastEnd: TimeInterval
        var lastMidi: Int
        var lastBeat: Int
        var pitchHistory: [Int]
        var midiSum: Int
        var durations: [TimeInterval]
        var meanMidi: Double { Double(midiSum) / Double(noteIndices.count) }
    }

    private struct ScoredLine {
        var noteIndices: [Int]
        var salience: Double
        var meanMidi: Double
    }

    /// conf 回退路径：v2 拍内二部匹配（VoiceSeparatorTests 用例走此路径）。
    private static func legacyAssignRoles(to notes: [MelodyNote]) -> [MelodyNote] {
        // 确定性排序：量化拍格 → 格内置信度降序 → 起始时间 → 结束时间 → 音高
        let sortedAll = notes.indices.sorted { a, b in
            let x = notes[a], y = notes[b]
            let bx = Int(x.startTime / beatQuantLegacy), by = Int(y.startTime / beatQuantLegacy)
            if bx != by { return bx < by }
            if x.confidence != y.confidence { return x.confidence > y.confidence }
            if x.startTime != y.startTime { return x.startTime < y.startTime }
            if x.endTime != y.endTime { return x.endTime < y.endTime }
            return x.midiNote < y.midiNote
        }.map { notes[$0] }

        // 门限过滤（门限外音符保留在输出中，role = background）
        let participating = sortedAll.filter {
            $0.confidence >= confFloor && ($0.endTime - $0.startTime) >= minDuration
        }
        guard !participating.isEmpty else {
            return sortedAll.map { settingRole($0, .background) }
        }
        let sorted = participating

        // 拍内二部匹配
        var lines: [VoiceLine] = []
        var intervalBook: [Int: Set<Int>] = [:]

        var cursor = 0
        while cursor < sorted.count {
            let beat = Int(sorted[cursor].startTime / beatQuantLegacy)
            var group: [Int] = []
            var next = cursor
            while next < sorted.count, Int(sorted[next].startTime / beatQuantLegacy) == beat {
                group.append(next)
                next += 1
            }

            var candidates: [Int: [(line: Int, cost: Double, secondary: Double)]] = [:]
            for gi in group {
                let note = sorted[gi]
                var cl: [(line: Int, cost: Double, secondary: Double)] = []
                for (l, line) in lines.enumerated() {
                    if line.lastBeat == beat { continue }
                    let condA = note.startTime >= line.lastEnd - overlapTolerance
                        && note.startTime <= line.lastEnd + maxGap
                    let condB = note.startTime >= line.lastStart + minInterOnset
                        && note.startTime <= line.lastStart + maxOnsetInterval
                    if !(condA || condB) { continue }
                    let distance = abs(note.midiNote - line.lastMidi)
                    if distance > maxStep { continue }
                    if distance >= leapThreshold && !isRecurrence(line, note.midiNote) { continue }
                    let med = median(line.durations)
                    let dur = note.endTime - note.startTime
                    if dur > med * durRatio || dur < med / durRatio { continue }
                    let cost: Double = (distance >= leapThreshold && isRecurrence(line, note.midiNote))
                        ? recurrenceCost
                        : Double(distance)
                    let secondary = abs(Double(note.midiNote) - line.meanMidi)
                    cl.append((line: l, cost: cost, secondary: secondary))
                }
                candidates[gi] = cl
            }

            var bestAssign: [(gi: Int, line: Int?)]?
            var bestCost = Double.greatestFiniteMagnitude
            var bestNewCount = Int.max
            var bestSecondary = Double.greatestFiniteMagnitude

            func enumerate(_ k: Int, _ used: inout Set<Int>,
                           _ assign: inout [(gi: Int, line: Int?)],
                           _ cost: Double, _ secondary: Double) {
                if k == group.count {
                    let newCount = assign.filter { $0.line == nil }.count
                    if cost < bestCost
                        || (cost == bestCost && (newCount < bestNewCount
                            || (newCount == bestNewCount && secondary < bestSecondary))) {
                        bestCost = cost; bestNewCount = newCount
                        bestSecondary = secondary; bestAssign = assign
                    }
                    return
                }
                let gi = group[k]
                for cand in candidates[gi] ?? [] {
                    if used.contains(cand.line) { continue }
                    var penalty = 0.0
                    for other in assign where other.line != nil {
                        let a = min(cand.line, other.line!), b = max(cand.line, other.line!)
                        let interval = a == cand.line
                            ? sorted[gi].midiNote - sorted[other.gi].midiNote
                            : sorted[other.gi].midiNote - sorted[gi].midiNote
                        if let hist = intervalBook[b * 4096 + a],
                           hist.count >= minIntervalHistory, !hist.contains(interval) {
                            penalty += intervalPenalty
                        }
                    }
                    used.insert(cand.line)
                    assign.append((gi, cand.line))
                    enumerate(k + 1, &used, &assign, cost + cand.cost + penalty,
                              secondary + cand.secondary)
                    assign.removeLast()
                    used.remove(cand.line)
                }
                assign.append((gi, nil))
                enumerate(k + 1, &used, &assign, cost + newLineCost, secondary)
                assign.removeLast()
            }
            var usedLines: Set<Int> = []
            var assignBuf: [(gi: Int, line: Int?)] = []
            enumerate(0, &usedLines, &assignBuf, 0, 0)

            var received: [(line: Int, gi: Int)] = []
            for (gi, lineIndex) in bestAssign ?? [] {
                let note = sorted[gi]
                if let l = lineIndex {
                    lines[l].noteIndices.append(gi)
                    lines[l].lastStart = note.startTime
                    lines[l].lastEnd = note.endTime
                    lines[l].lastMidi = note.midiNote
                    lines[l].lastBeat = beat
                    lines[l].pitchHistory.append(note.midiNote)
                    lines[l].midiSum += note.midiNote
                    lines[l].durations.append(note.endTime - note.startTime)
                    received.append((line: l, gi: gi))
                } else {
                    lines.append(VoiceLine(
                        noteIndices: [gi], lastStart: note.startTime, lastEnd: note.endTime,
                        lastMidi: note.midiNote, lastBeat: beat, pitchHistory: [note.midiNote],
                        midiSum: note.midiNote, durations: [note.endTime - note.startTime]
                    ))
                }
            }
            for pair in combinationsOfTwo(received) {
                let a = min(pair.0.line, pair.1.line), b = max(pair.0.line, pair.1.line)
                let interval = a == pair.0.line
                    ? sorted[pair.0.gi].midiNote - sorted[pair.1.gi].midiNote
                    : sorted[pair.1.gi].midiNote - sorted[pair.0.gi].midiNote
                intervalBook[b * 4096 + a, default: []].insert(interval)
            }
            cursor = next
        }

        // 显著性评分
        var scored: [ScoredLine] = []
        for line in lines {
            var totalDuration: TimeInterval = 0
            var energy = 0.0
            var maxEnd: TimeInterval = 0
            for i in line.noteIndices {
                let n = sorted[i]
                let duration = n.endTime - n.startTime
                totalDuration += duration
                energy += n.confidence * duration
                maxEnd = max(maxEnd, n.endTime)
            }
            guard totalDuration >= minLineTotalDuration else { continue }
            let meanMidi = line.meanMidi
            guard meanMidi >= Double(bassExclude) else { continue }
            let registerPrior: Double
            if meanMidi < Double(midMeanMidiUpper) {
                registerPrior = midRegisterPrior
            } else if meanMidi <= Double(highMeanMidiUpper) {
                registerPrior = coreRegisterPrior
            } else {
                registerPrior = highRegisterPrior
            }
            let firstStart = sorted[line.noteIndices[0]].startTime
            let span = max(maxEnd - firstStart, 0)
            let continuity = span > 0 ? min(1.0, totalDuration / span) : 1.0
            scored.append(
                ScoredLine(noteIndices: line.noteIndices,
                           salience: energy * continuity * registerPrior, meanMidi: meanMidi)
            )
        }

        guard !scored.isEmpty else {
            return sortedAll.map { settingRole($0, .background) }
        }

        var melodyIndex = 0
        for i in scored.indices where scored[i].salience > scored[melodyIndex].salience {
            melodyIndex = i
        }

        var counterIndex: Int?
        for i in scored.indices where i != melodyIndex {
            let candidate = scored[i]
            let coOccurrence = coOccurrenceRatio(
                candidate.noteIndices.map { sorted[$0] },
                against: scored[melodyIndex].noteIndices.map { sorted[$0] })
            if coOccurrence > duplicateCoOccurrenceThreshold,
               isStrictParallel(candidate.noteIndices,
                                melodyIndices: scored[melodyIndex].noteIndices, sorted: sorted) {
                continue
            }
            if let current = counterIndex {
                if candidate.salience > scored[current].salience {
                    counterIndex = i
                }
            } else {
                counterIndex = i
            }
        }

        var roles = [MelodyRole](repeating: .background, count: sorted.count)
        for i in scored[melodyIndex].noteIndices { roles[i] = .melody }
        if let counterIndex {
            for i in scored[counterIndex].noteIndices { roles[i] = .countermelody }
        }

        // 线内拖尾截断（不改动 onset——onset 是对拍验证的原始解码数据）
        var result = sorted
        var lineGroups: [[Int]] = [scored[melodyIndex].noteIndices]
        if let counterIndex { lineGroups.append(scored[counterIndex].noteIndices) }
        for indices in lineGroups where indices.count > 1 {
            for k in 0..<(indices.count - 1) {
                let iA = indices[k], iB = indices[k + 1]
                let newDuration = result[iB].startTime - result[iA].startTime
                if result[iA].endTime > result[iB].startTime, newDuration > 0.05 {
                    result[iA] = MelodyNote(
                        startTime: result[iA].startTime,
                        endTime: result[iA].startTime + newDuration,
                        midiNote: result[iA].midiNote,
                        confidence: result[iA].confidence,
                        pitchBends: result[iA].pitchBends,
                        role: roles[iA]
                    )
                }
            }
        }

        let shaped = result.enumerated().map { index, note in
            settingRole(note, roles[index])
        }
        var shapedIter = shaped.makeIterator()
        return sortedAll.map { note in
            let participates = note.confidence >= confFloor
                && (note.endTime - note.startTime) >= minDuration
            guard participates, let shapedNote = shapedIter.next() else {
                return settingRole(note, .background)
            }
            return shapedNote
        }
    }

    // MARK: - 私有辅助

    /// 返回仅改写 role 的音符副本（其余字段原样保留）
    private static func settingRole(_ note: MelodyNote, _ role: MelodyRole) -> MelodyNote {
        MelodyNote(
            startTime: note.startTime,
            endTime: note.endTime,
            midiNote: note.midiNote,
            confidence: note.confidence,
            pitchBends: note.pitchBends,
            role: role
        )
    }

    /// 音高是否在线近期历史中以同音或八度关系出现过（大跳重现判定）
    private static func isRecurrence(_ line: VoiceLine, _ midi: Int) -> Bool {
        let window = line.pitchHistory.suffix(histWindow)
        return window.contains { $0 == midi || abs($0 - midi) == 12 }
    }

    /// 排序数组中位数
    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let s = values.sorted()
        return s[s.count / 2]
    }

    /// 两两组合
    private static func combinationsOfTwo<T>(_ items: [T]) -> [(T, T)] {
        var result: [(T, T)] = []
        for i in items.indices {
            for j in (i + 1)..<items.count {
                result.append((items[i], items[j]))
            }
        }
        return result
    }

    /// 时间共现率：`notes` 中与 `reference` 任一音符时间重叠的音符时长占比
    private static func coOccurrenceRatio(
        _ notes: [MelodyNote],
        against reference: [MelodyNote]
    ) -> Double {
        var total: TimeInterval = 0
        var overlapping: TimeInterval = 0
        for note in notes {
            let duration = note.endTime - note.startTime
            total += duration
            for other in reference
            where note.startTime < other.endTime && other.startTime < note.endTime {
                overlapping += duration
                break
            }
        }
        return total > 0 ? overlapping / total : 0
    }

    /// 严格平行复制线判定：同拍折叠音高差均值与极差均 ≤ duplicateSpan
    /// （仅同度/八度复制；排除恒定五度等平行独立声部）
    private static func isStrictParallel(
        _ indices: [Int], melodyIndices: [Int], sorted: [MelodyNote]
    ) -> Bool {
        var diffs: [Double] = []
        for i in indices {
            let a0 = sorted[i].startTime, a1 = sorted[i].endTime
            for j in melodyIndices {
                let b0 = sorted[j].startTime, b1 = sorted[j].endTime
                if a0 < b1 && b0 < a1 {
                    var d = Double(sorted[i].midiNote - sorted[j].midiNote)
                        .truncatingRemainder(dividingBy: 12)
                    if d > 6 { d -= 12 }
                    if d < -6 { d += 12 }
                    diffs.append(d)
                    break
                }
            }
        }
        guard diffs.count >= duplicateMinSamples else { return false }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        guard abs(mean) <= duplicateSpan else { return false }
        return (diffs.max() ?? 0) - (diffs.min() ?? 0) <= duplicateSpan
    }
}
