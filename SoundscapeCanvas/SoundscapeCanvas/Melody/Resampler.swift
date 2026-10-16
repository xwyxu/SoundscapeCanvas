//
//  Resampler.swift
//  SoundscapeCanvas
//
//  线性插值重采样 —— 逐字翻译自
//  参考文件/mawimbi-master/src/features/transcription/MelodyExtractor.ts 的 resampleLinear（L79-99）。
//
//  说明：JS 原版接收/返回 Float32Array，但内部算术全部在 JS number（IEEE754 float64）上进行；
//  为与其逐位对拍，此处输入输出统一使用 [Double]（上游解码得到的 Float32 样本由调用方转为 Double）。
//

import Foundation

/// 隔离说明：纯计算，标 nonisolated 以豁免工程的默认 MainActor 隔离，
/// 确保从后台任务调用时不会隐式跳回主线程。
nonisolated enum Resampler {

    /// 将单声道采样从 `sourceRate` 线性插值重采样到 `targetRate`。
    /// 对神经网络推理而言质量足够（模型自身的分窗主导频率分辨率）。
    static func resampleLinear(
        _ input: [Double],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Double] {
        // JS: if (sourceSampleRate === targetSampleRate) return input;
        if sourceRate == targetRate { return input }

        // JS: const ratio = sourceSampleRate / targetSampleRate;
        let ratio = sourceRate / targetRate
        // JS: const outputLength = Math.ceil(input.length / ratio);
        let outputLength = Int(ceil(Double(input.count) / ratio))
        var output = [Double](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            // JS: const srcIndex = i * ratio;
            let srcIndex = Double(i) * ratio
            // JS: const lo = Math.floor(srcIndex);
            let lo = Int(floor(srcIndex))
            // JS: const hi = Math.min(lo + 1, input.length - 1);
            let hi = min(lo + 1, input.count - 1)
            // JS: const frac = srcIndex - lo;
            let frac = srcIndex - Double(lo)
            // JS: output[i] = input[lo] * (1 - frac) + input[hi] * frac;
            //
            // NaN 对齐说明：极罕见的浮点边缘下 srcIndex 可能恰好等于 input.length（此时 JS 的
            // input[lo] 为 undefined、参与算术得 NaN）。Swift 数组越界会崩溃而非得 NaN，
            // 此处显式对齐 JS 行为：越界下标按 NaN 参与运算（正常输入不会触达此分支）。
            let loValue = lo < input.count ? input[lo] : .nan
            let hiValue = (hi >= 0 && hi < input.count) ? input[hi] : .nan
            output[i] = loValue * (1 - frac) + hiValue * frac
        }

        return output
    }
}
