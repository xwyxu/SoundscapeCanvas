//
//  PlayheadOverlay.swift
//  SoundscapeCanvas
//
//  Created by 徐俊 on 2026/9/12.
//

import SwiftUI

/// 固定播放竖线：白色 1.5pt，位于容器宽度 1/3 处，带轻微发光，全高。
///
/// 竖线位置固定不动，旋律画布内容随播放向左滚动，竖线处对准当前发声音符。
struct PlayheadOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5)   // 仅约束宽度，高度自动撑满容器
                .shadow(color: Color.white.opacity(0.6), radius: 4)
                .position(x: geo.size.width / 3, y: geo.size.height / 2)
        }
    }
}
