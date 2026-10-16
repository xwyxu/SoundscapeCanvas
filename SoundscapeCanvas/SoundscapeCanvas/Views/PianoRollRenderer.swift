//
//  PianoRollRenderer.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/18.
//

import SwiftUI

// MARK: - 双端通用颜色

/// 归一化 sRGB 颜色：同源渲染在 SwiftUI（App 内画布）与 CoreGraphics（离屏视频）
/// 两条绘制路径间共享的颜色值类型
nonisolated struct PianoRollColor {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    /// SwiftUI 色（App 内画布路径）
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue).opacity(alpha)
    }

    /// CoreGraphics 色（离屏视频路径）
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - 绘制目标抽象

/// 同源渲染的绘制目标：核心绘制逻辑只写一份，由两个轻量适配器承载等价原语，
/// 避免双实现漂移——
/// - `GraphicsContextDrawTarget`：App 内画布（Canvas 提供的 GraphicsContext，行为不变）；
/// - `CGContextDrawTarget`：离屏视频（CVPixelBuffer 绑定的 CGContext，后台线程可绘）。
///
/// iOS 26 SDK 的 `GraphicsContext` 无公开初始化器（无法在 Canvas 之外构造），
/// 故以本协议把"绘制原语"抽象出来，核心逻辑与具体绘制后端解耦。
nonisolated protocol PianoRollDrawTarget {
    /// 纯色填充
    func fill(_ path: Path, with color: PianoRollColor)

    /// 两停点线性渐变填充（沿路径裁剪）
    func fill(
        _ path: Path,
        withLinearGradientFrom startColor: PianoRollColor,
        to endColor: PianoRollColor,
        startPoint: CGPoint,
        endPoint: CGPoint
    )

    /// 描边
    func stroke(
        _ path: Path,
        with color: PianoRollColor,
        lineWidth: CGFloat,
        lineCap: CGLineCap,
        lineJoin: CGLineJoin
    )

    /// 发光填充：先在模糊垫层中以指定半径铺色（调用方随后正常覆盖填充）。
    /// App 端 = drawLayer + blur；视频端 = CGContext shadow（即参考 TS 实现的
    /// 原生 shadowColor/shadowBlur 语义）。
    func fillWithGlow(_ path: Path, with color: PianoRollColor, blurRadius: CGFloat)
}

/// SwiftUI 适配器（App 内画布）：直通 `GraphicsContext` 原语，绘制行为与
/// 抽象前完全一致
private nonisolated struct GraphicsContextDrawTarget: PianoRollDrawTarget {
    let context: GraphicsContext

    func fill(_ path: Path, with color: PianoRollColor) {
        context.fill(path, with: .color(color.swiftUIColor))
    }

    func fill(
        _ path: Path,
        withLinearGradientFrom startColor: PianoRollColor,
        to endColor: PianoRollColor,
        startPoint: CGPoint,
        endPoint: CGPoint
    ) {
        let gradient = Gradient(stops: [
            .init(color: startColor.swiftUIColor, location: 0),
            .init(color: endColor.swiftUIColor, location: 1),
        ])
        context.fill(
            path,
            with: .linearGradient(gradient, startPoint: startPoint, endPoint: endPoint)
        )
    }

    func stroke(
        _ path: Path,
        with color: PianoRollColor,
        lineWidth: CGFloat,
        lineCap: CGLineCap,
        lineJoin: CGLineJoin
    ) {
        context.stroke(
            path,
            with: .color(color.swiftUIColor),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap, lineJoin: lineJoin)
        )
    }

    func fillWithGlow(_ path: Path, with color: PianoRollColor, blurRadius: CGFloat) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: blurRadius))
            layer.fill(path, with: .color(color.swiftUIColor))
        }
    }
}

/// CoreGraphics 适配器（离屏视频）：`CGContext` 等价原语。
/// 坐标系约定：调用方负责先把 CGContext 翻转为左上原点（与 SwiftUI 语义一致）。
private nonisolated struct CGContextDrawTarget: PianoRollDrawTarget {
    let cgContext: CGContext

    func fill(_ path: Path, with color: PianoRollColor) {
        cgContext.saveGState()
        cgContext.addPath(path.cgPath)
        cgContext.setFillColor(color.cgColor)
        cgContext.fillPath()
        cgContext.restoreGState()
    }

    func fill(
        _ path: Path,
        withLinearGradientFrom startColor: PianoRollColor,
        to endColor: PianoRollColor,
        startPoint: CGPoint,
        endPoint: CGPoint
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [startColor.cgColor, endColor.cgColor] as CFArray,
            locations: [0, 1]
        ) else { return }
        cgContext.saveGState()
        cgContext.addPath(path.cgPath)
        cgContext.clip()
        cgContext.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
        cgContext.restoreGState()
    }

    func stroke(
        _ path: Path,
        with color: PianoRollColor,
        lineWidth: CGFloat,
        lineCap: CGLineCap,
        lineJoin: CGLineJoin
    ) {
        cgContext.saveGState()
        cgContext.addPath(path.cgPath)
        cgContext.setStrokeColor(color.cgColor)
        cgContext.setLineWidth(lineWidth)
        cgContext.setLineCap(lineCap)
        cgContext.setLineJoin(lineJoin)
        cgContext.strokePath()
        cgContext.restoreGState()
    }

    func fillWithGlow(_ path: Path, with color: PianoRollColor, blurRadius: CGFloat) {
        // shadow = 路径形状的高斯模糊拷贝垫底，等价 Canvas 的 drawLayer + blur
        cgContext.saveGState()
        cgContext.setShadow(offset: .zero, blur: blurRadius, color: color.cgColor)
        cgContext.addPath(path.cgPath)
        cgContext.setFillColor(color.cgColor)
        cgContext.fillPath()
        cgContext.restoreGState()
    }
}

// MARK: - 同源渲染器

/// 钢琴块旋律渲染器：App 内画布（`PianoRollCanvasView`）与离屏视频渲染共用的**同源绘制函数**。
///
/// 坐标换算（核心公式）：
/// - 竖线固定在屏宽 1/3 处（由 `PlayheadOverlay` 独立绘制，X = w/3）；
/// - 播放偏移 `offset = currentTime × pps − playheadX`；
/// - 时间 t 的水平位置 `x(t) = t × pps − offset = playheadX + (t − currentTime) × pps`。
///   播放中 currentTime 增大 → 音符整体左移（内容随播放向左滚动，时间轴从左至右推进）。
/// - 音高：`y(midi) = topPadding + (108 − midi) × semitoneHeight`，
///   `semitoneHeight = 可用高度 / 88`（88 键音域共 88 个半音槽位，每半音一格，
///   低音贴底；除以 88 使 A0–C8 完整贴合可用高度，边缘不留空槽）。
///
/// `currentTime` 由调用方每帧传入（App 内由播放引擎采样级时钟驱动，外层 TimelineView
/// 每帧取最新值；视频端由离线时钟逐帧推进），暂停时该值冻结，画面自然静止，无跳变。
///
/// 隔离说明：整型 nonisolated（豁免工程默认 MainActor 隔离）——全部成员为无状态
/// 纯绘制/纯数学函数，MainActor 上下文（App 内画布）与后台线程（离屏视频渲染）
/// 均可直接调用；绘制目标仅在单帧绘制内局部使用，不跨隔离边界传递。
nonisolated enum PianoRollRenderer {
    // MARK: - 音符块视觉参数（翻译自参考 PianoRollRenderer.ts，基色随声部角色三色化）

    /// 银白基色分量（.background 角色）：(r,g,b) = (200,200,200) → 归一化灰；
    /// 主旋律/副旋律角色的基色见 `baseColor(for:)`（三色随 role 取值）
    private static let baseGray: CGFloat = 200.0 / 255.0
    /// 圆角半径 2px
    private static let cornerRadius: CGFloat = 2
    /// 边框宽 1.5px
    private static let borderWidth: CGFloat = 1.5
    /// 边框不透明度 0.85（边框色 = 基色 × 0.6）
    private static let borderOpacity: Double = 0.85
    /// 填充不透明度 0.6
    private static let fillOpacity: Double = 0.6
    /// 活跃音符（正被播放）填充不透明度 0.9
    private static let activeFillOpacity: Double = 0.9
    /// 活跃音符发光模糊半径 8px
    private static let activeGlowBlur: CGFloat = 8
    /// 活跃音符发光不透明度 0.5
    private static let activeGlowOpacity: Double = 0.5
    /// 弯音折线不透明度 0.8（活跃时 0.9）
    private static let pitchBendOpacity: Double = 0.8
    /// 弯音折线宽 1.5px
    private static let pitchBendLineWidth: CGFloat = 1.5
    /// 弯音折线颜色提亮量 +60（银白基色下 min(255, 200+60) = 255 纯白；随基色参数化）
    private static let pitchBendBoost: CGFloat = 60.0 / 255.0
    /// 3D 渐变左端提亮量 +40（银白基色下 min(255, 200+40) = 240）
    private static let highlightBoost: CGFloat = 40.0 / 255.0
    /// 3D 渐变右端变暗系数 ×0.55（银白基色下 200×0.55 = 110）
    private static let shadowFactor: CGFloat = 0.55
    /// 左棱高光线宽 0.5px（基色 +80 提亮，不透明度 = 填充 × 0.5）
    private static let edgeHighlightWidth: CGFloat = 0.5
    /// 左棱高光提亮量 +80（银白基色下 min(255, 200+80) = 255 纯白；随基色参数化）
    private static let edgeHighlightBoost: CGFloat = 80.0 / 255.0
    /// Y 轴顶部少量留白
    private static let topPadding: CGFloat = 8
    /// 完整钢琴音域：A0(21) … C8(108)，共 88 键
    private static let midiLow = 21
    private static let midiHigh = 108

    // MARK: - 声部角色基色（双旋律三色，与 MelodyRole 语义一一对应）

    /// 声部角色 → 归一化基色 (r,g,b)：仅基色来源随角色变化，全部派生色
    /// （渐变两端/边框/左棱高光/弯音线/活跃发光）沿用既有公式对该基色参数化。
    /// - `.background` → (200,200,200) 银白 #C8C8C8（和弦垫/伴奏等其余音符，既有色不变）
    /// - `.melody` → (255,255,0) 黄 #FFFF00（主旋律线）
    /// - `.countermelody` → (135,206,235) 浅蓝 #87CEEB（副旋律线）
    private static func baseColor(for role: MelodyRole) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch role {
        case .melody:
            return (1, 1, 0)
        case .countermelody:
            return (135.0 / 255.0, 206.0 / 255.0, 235.0 / 255.0)
        case .background:
            return (Self.baseGray, Self.baseGray, Self.baseGray)
        }
    }

    // MARK: - 同源渲染入口

    /// 渲染一帧完整钢琴块画面（App 内画布路径，GraphicsContext 后端）：
    /// 纯黑背景 + 全部音符（视口裁剪、3D 渐变填充、边框、左棱高光、活跃发光
    /// drawLayer、弯音折线）。
    ///
    /// 刻意**不绘制竖线**：竖线属于 `PlayheadOverlay` 覆盖层，视频端由其自身覆盖层绘制，
    /// 此处不包含以保证画面内容与覆盖层解耦（与 App 内 `PianoRollCanvasView` 行为一致）。
    static func drawPianoRoll(
        to context: GraphicsContext,
        size: CGSize,
        melody: MelodyData?,
        currentTime: TimeInterval,
        pixelsPerSecond: CGFloat
    ) {
        drawPianoRoll(
            to: GraphicsContextDrawTarget(context: context) as any PianoRollDrawTarget,
            size: size,
            melody: melody,
            currentTime: currentTime,
            pixelsPerSecond: pixelsPerSecond
        )
    }

    /// 渲染一帧完整钢琴块画面（离屏视频路径，CGContext 后端）。
    ///
    /// 坐标系：CG 默认左下原点，此处显式翻转为左上原点（与 SwiftUI 语义一致），
    /// 保证"低音在下、时间轴从左至右"与 App 内画面方向完全一致。
    static func drawPianoRoll(
        to cgContext: CGContext,
        size: CGSize,
        melody: MelodyData?,
        currentTime: TimeInterval,
        pixelsPerSecond: CGFloat
    ) {
        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: size.height)
        cgContext.scaleBy(x: 1, y: -1)
        defer { cgContext.restoreGState() }
        drawPianoRoll(
            to: CGContextDrawTarget(cgContext: cgContext) as any PianoRollDrawTarget,
            size: size,
            melody: melody,
            currentTime: currentTime,
            pixelsPerSecond: pixelsPerSecond
        )
    }

    /// 视口时间裁剪判定（纯函数，供单元测试验证裁剪数学）：
    /// x(t) = t × pps − offset；音符可见 ⇔ x2 > 0（未完全滚出左缘）且 x1 < 视口宽（未完全滚出右缘）。
    nonisolated static func isNoteVisible(
        _ note: MelodyNote,
        in size: CGSize,
        offset: CGFloat,
        pixelsPerSecond: CGFloat
    ) -> Bool {
        let x1 = CGFloat(note.startTime) * pixelsPerSecond - offset
        let x2 = CGFloat(note.endTime) * pixelsPerSecond - offset
        return x2 > 0 && x1 < size.width
    }

    // MARK: - 绘制核心（绘制目标无关，单实现）

    /// 渲染核心：面向绘制目标协议（双后端共享，避免双实现漂移）
    private static func drawPianoRoll(
        to target: any PianoRollDrawTarget,
        size: CGSize,
        melody: MelodyData?,
        currentTime: TimeInterval,
        pixelsPerSecond: CGFloat
    ) {
        // 纯黑背景
        target.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: PianoRollColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        drawMelody(
            in: target,
            size: size,
            melody: melody,
            currentTime: currentTime,
            pixelsPerSecond: pixelsPerSecond
        )
    }

    private static func drawMelody(
        in target: any PianoRollDrawTarget,
        size: CGSize,
        melody: MelodyData?,
        currentTime: TimeInterval,
        pixelsPerSecond: CGFloat
    ) {
        guard let melody else { return }

        let pps = pixelsPerSecond
        let playheadX = size.width / 3
        // 播放偏移：画面内容随 currentTime 增大向左平移
        let offset = CGFloat(currentTime) * pps - playheadX

        let usableHeight = size.height - Self.topPadding
        guard usableHeight > 0 else { return }
        // 88 键音域共 88 个半音槽位，每半音占一格（除以 88 使音域完整贴合可用高度）
        let semitoneHeight = usableHeight / CGFloat(Self.midiHigh - Self.midiLow + 1)

        for note in melody.notes {
            // 视口时间裁剪：完全滚出屏幕的音符不绘制（判定数学提为 isNoteVisible 纯函数，供单元测试验证）
            guard Self.isNoteVisible(note, in: size, offset: offset, pixelsPerSecond: pps) else { continue }
            let x1 = CGFloat(note.startTime) * pps - offset
            let x2 = CGFloat(note.endTime) * pps - offset

            let y = Self.topPadding + CGFloat(Self.midiHigh - note.midiNote) * semitoneHeight
            let rect = CGRect(x: x1, y: y, width: x2 - x1, height: semitoneHeight)
            // 活跃判定（参考 isNoteActiveAt）：播放头落在 [start, end) 内即正在发声；
            // 负时钟（未开始播放）一律不活跃
            let isActive = currentTime >= 0
                && currentTime >= note.startTime
                && currentTime < note.endTime
            drawNote(in: target, rect: rect, isActive: isActive, base: Self.baseColor(for: note.role))

            // 弯音折线：仅有 ≥2 个采样点的弯音数据才值得连线（对齐参考 drawPianoRoll）
            if let bends = note.pitchBends, bends.count > 1 {
                drawPitchBendLine(
                    in: target,
                    rect: rect,
                    bends: bends,
                    semitoneHeight: semitoneHeight,
                    isActive: isActive,
                    base: Self.baseColor(for: note.role)
                )
            }
        }
    }

    /// 单个音符块：3D 渐变填充 + 边框 + 左棱高光；活跃（正在发声）时先垫发光层并提亮填充
    /// （视觉参数翻译自 PianoRollRenderer.ts 的 drawNote active 分支；
    /// 全部颜色对入参基色 `base`（按 note.role 取自 `baseColor(for:)`）参数化，
    /// 派生公式与单色时期完全一致，仅基色来源随角色变化）
    private static func drawNote(
        in target: any PianoRollDrawTarget,
        rect: CGRect,
        isActive: Bool,
        base: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) {
        let path = Path(roundedRect: rect, cornerRadius: Self.cornerRadius)
        let fillOpacity = isActive ? Self.activeFillOpacity : Self.fillOpacity

        // 活跃音符：块后先垫发光层 —— 在独立 layer 中对基色 0.5 填充做 blur(8)，
        // 等价参考实现的 shadowColor = rgba(基色, 0.5)、shadowBlur = 8
        if isActive {
            let glowColor = PianoRollColor(
                red: base.r,
                green: base.g,
                blue: base.b,
                alpha: Self.activeGlowOpacity
            )
            target.fillWithGlow(path, with: glowColor, blurRadius: Self.activeGlowBlur)
        }

        // 3D 渐变填充：左端 +40 提亮、右端 ×0.55 变暗（银白基色下为 240/110，随基色参数化）；
        // 活跃时填充不透明度 0.6 → 0.9
        target.fill(
            path,
            withLinearGradientFrom: PianoRollColor(
                red: min(1, base.r + Self.highlightBoost),
                green: min(1, base.g + Self.highlightBoost),
                blue: min(1, base.b + Self.highlightBoost),
                alpha: fillOpacity
            ),
            to: PianoRollColor(
                red: base.r * Self.shadowFactor,
                green: base.g * Self.shadowFactor,
                blue: base.b * Self.shadowFactor,
                alpha: fillOpacity
            ),
            startPoint: CGPoint(x: rect.minX, y: rect.minY),
            endPoint: CGPoint(x: rect.maxX, y: rect.minY)
        )

        // 边框：基色 × 0.6（银白基色下为 120,120,120），不透明度 0.85
        target.stroke(
            path,
            with: PianoRollColor(
                red: base.r * 0.6,
                green: base.g * 0.6,
                blue: base.b * 0.6,
                alpha: Self.borderOpacity
            ),
            lineWidth: Self.borderWidth,
            lineCap: .butt,
            lineJoin: .miter
        )

        // 左棱 0.5px 高光线：基色 +80 提亮（银白基色下 min(255, 280) = 255 纯白，随基色参数化），
        // 不透明度 = 当前填充不透明度 × 0.5（活跃时随填充一并提亮）；
        // X = 块左缘 + 0.5px（对齐参考 drawLeftHighlight 的 0.5px 内缩，边缘加固项）
        var highlight = Path()
        let highlightX = rect.minX + 0.5
        highlight.move(to: CGPoint(x: highlightX, y: rect.minY))
        highlight.addLine(to: CGPoint(x: highlightX, y: rect.maxY))
        target.stroke(
            highlight,
            with: PianoRollColor(
                red: min(1, base.r + Self.edgeHighlightBoost),
                green: min(1, base.g + Self.edgeHighlightBoost),
                blue: min(1, base.b + Self.edgeHighlightBoost),
                alpha: fillOpacity * 0.5
            ),
            lineWidth: Self.edgeHighlightWidth,
            lineCap: .butt,
            lineJoin: .miter
        )
    }

    /// 弯音折线（翻译自 PianoRollRenderer.ts 的 drawPitchBendLine，坐标系转置）：
    ///
    /// 参考实现为"时间→Y、音高→X"，本工程转置为"时间→X、音高→Y"，语义保持一致：
    /// - count 个弯音采样点沿**时间轴（X）**在块范围内均分：
    ///   `px(i) = rect.minX + rect.width × i / count`（对应参考 py = noteY + i × pxPerBend）；
    /// - 每点沿**音高轴（Y）**自块中线偏移：`py(i) = rect.midY − bends[i] × semitoneHeight`。
    ///   弯音单位为半音，1 半音 = semitoneHeight 像素（对应参考 bendBins × pixelsPerBin）；
    ///   本工程 Y 轴向下为低音，故取负号使正向（升调）弯音朝高音方向偏移，
    ///   与参考"正向弯音朝高频"的视觉语义一致。
    private static func drawPitchBendLine(
        in target: any PianoRollDrawTarget,
        rect: CGRect,
        bends: [Double],
        semitoneHeight: CGFloat,
        isActive: Bool,
        base: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) {
        let bendCount = bends.count
        // 颜色 = 基色 +60 提亮（银白基色下为纯白，随基色参数化）；活跃时 0.9，常态 0.8
        let color = PianoRollColor(
            red: min(1, base.r + Self.pitchBendBoost),
            green: min(1, base.g + Self.pitchBendBoost),
            blue: min(1, base.b + Self.pitchBendBoost),
            alpha: isActive ? Self.activeFillOpacity : Self.pitchBendOpacity
        )

        var line = Path()
        for (i, bend) in bends.enumerated() {
            // 采样点沿时间轴（X）均分：第 i 点 = 块左缘 + 块宽 × i / count
            let px = rect.minX + rect.width * CGFloat(i) / CGFloat(bendCount)
            // 弯音沿音高轴（Y）偏移：块中线 − 半音数 × 半音像素高度（向下为低音，取负朝高音）
            let py = rect.midY - CGFloat(bend) * semitoneHeight
            if i == 0 {
                line.move(to: CGPoint(x: px, y: py))
            } else {
                line.addLine(to: CGPoint(x: px, y: py))
            }
        }
        // 圆头连接与端帽（对齐参考 lineJoin/lineCap = round）
        target.stroke(
            line,
            with: color,
            lineWidth: Self.pitchBendLineWidth,
            lineCap: .round,
            lineJoin: .round
        )
    }
}
