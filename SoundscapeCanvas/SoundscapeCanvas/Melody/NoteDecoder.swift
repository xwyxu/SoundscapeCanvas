//
//  NoteDecoder.swift
//  SoundscapeCanvas
//
//  Basic Pitch 音符解码纯函数集合 —— 逐行翻译自
//  @spotify/basic-pitch 的 src/toMidi.ts（Apache License 2.0, Copyright 2022 Spotify AB），
//  参考文件/mawimbi-master/node_modules/@spotify/basic-pitch/src/toMidi.ts。
//
//  翻译纪律：
//  - 矩阵统一使用 [[Double]]（JS number 为 IEEE754 float64；CoreML 的 Float32 输出由上游转为 Double）
//  - 严格保持 JS 的处理顺序、循环边界（含 off-by-one）、tie-breaking 与 NaN 行为；
//    与 JS 行为存在差异的 Swift 内置 API 处均改用手工实现并加中文注释说明 JS 原始行为
//  - JS 中 constrainFrequency 会原地修改入参矩阵；Swift 值语义下天然隔离为副本，
//    调用方持有的原矩阵不受影响（参考实现 mawimbi 的调用方亦不复用修改后的矩阵）
//  - generateFileData（MIDI 文件导出）按任务要求不翻译
//

import Foundation

/// 帧域音符事件（对齐 JS NoteEvent，toMidi.ts L20-26）
struct NoteEvent {
    var startFrame: Int
    var durationFrames: Int
    var pitchMidi: Int
    var amplitude: Double
    var pitchBends: [Double]?
}

/// 秒域音符事件（对齐 JS NoteEventTime，toMidi.ts L28-34）
struct NoteEventTime {
    var startTimeSeconds: Double
    var durationSeconds: Double
    var pitchMidi: Int
    var amplitude: Double
    var pitchBends: [Double]?
}

/// melodia 循环中的防御性错误（对齐 toMidi.ts L499-507 的两个 throw new Error(...)）
enum NoteDecoderError: Error {
    case iStartNotPositive(Int)
    case iEndPastEndOfTimes(iEnd: Int, nFrames: Int)
}

/// Basic Pitch 模型输出（frames/onsets/contour）→ 音符事件的纯函数解码器
///
/// 隔离说明：全部为纯计算函数，标 nonisolated 以豁免工程的默认 MainActor 隔离，
/// 确保从后台任务调用时不会隐式跳回主线程。
nonisolated enum NoteDecoder {

    // MARK: - 常量（toMidi.ts L36-51，逐一对齐）

    static let midiOffset = 21
    static let audioSampleRate = 22050.0
    static let audioWindowLength = 2
    static let fftHop = 256.0
    /// floor(22050 / 256) = 86
    static let annotationsFPS = Int(floor(audioSampleRate / fftHop))
    /// 86 * 2 = 172
    static let annotNFrames = annotationsFPS * audioWindowLength
    /// 22050 * 2 - 256 = 43844
    static let audioNSamples = Int(audioSampleRate) * audioWindowLength - Int(fftHop)
    /// (fftHop / audioSampleRate) × (annotNFrames − audioNSamples / fftHop) + 0.0018
    /// 保持公式形式与 JS 完全一致的求值顺序（JS 注释：magic number，needed to align properly）
    static let windowOffset =
        (fftHop / audioSampleRate)
        * (Double(annotNFrames) - Double(audioNSamples) / fftHop) + 0.0018
    static let maxFreqIdx = 87
    static let contoursBinsPerSemitone = 3
    /// 最低钢琴键频率
    static let annotationsBaseFrequency = 27.5
    /// 钢琴键数
    static let annotationsNSemitones = 88
    /// 88 * 3 = 264
    static let nFreqBinsContours = annotationsNSemitones * contoursBinsPerSemitone

    // MARK: - PORTED LIBROSA FUNCTIONS

    /// Hz → MIDI 音高（toMidi.ts L60-61）
    static func hzToMidi(_ hz: Double) -> Double {
        12 * (log2(hz) - log2(440.0)) + 69
    }

    /// MIDI 音高 → Hz（toMidi.ts L68-69）
    static func midiToHz(_ midi: Double) -> Double {
        // JS: 440.0 * 2.0 ** ((midi - 69.0) / 12.0)
        440.0 * pow(2.0, (midi - 69.0) / 12.0)
    }

    /// 模型帧号 → 秒（toMidi.ts L76-78）
    /// time = frame×fftHop/sampleRate − windowOffset×floor(frame/annotNFrames)
    /// frame 为整数；JS 的 frame/ANNOT_N_FRAMES 是浮点除法后再 floor
    static func modelFrameToTime(_ frame: Int) -> Double {
        return (Double(frame) * fftHop) / audioSampleRate
            - windowOffset * floor(Double(frame) / Double(annotNFrames))
    }

    // MARK: - JS Math 语义辅助

    /// JS Math.max(a, b)：任一参数为 NaN 则返回 NaN。
    /// Swift 内置 max(a, .nan) 会返回 a（非 NaN 一方），与 JS 不同，故必须手动实现。
    static func jsMax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        return a > b ? a : b
    }

    /// JS Math.min(a, b)：任一参数为 NaN 则返回 NaN（Swift 内置 min 行为不同，见 jsMax）。
    static func jsMin(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        return a < b ? a : b
    }

    /// JS Math.round(x) = floor(x + 0.5)（0.5 恒远离零取整到更大/更接近零…即正数 0.5 向上）。
    /// Swift 内置 round() 是"四舍六入五成双"（.toNearestOrEven），语义不同，故手动实现。
    static func jsRound(_ x: Double) -> Double {
        floor(x + 0.5)
    }

    // MARK: - PORTED NUMPY FUNCTIONS

    /// 一维数组最大值下标（toMidi.ts L87-95）。
    ///
    /// JS tie 语义：`arr.reduce((maxIndex, v, i) => arr[maxIndex] > v ? maxIndex : i, -1)`
    /// - 初始 maxIndex = -1，首次迭代 arr[-1] 为 undefined，`undefined > v` 恒为 false → 取 i = 0；
    ///   此处以 NaN 作哨兵复刻该比较失败行为
    /// - 之后**严格大于**才保留旧索引：相等（或 NaN 比较）时取更靠后的索引（"相等取后"）
    /// - 空数组返回 nil（JS 返回 null）
    static func argMax(_ arr: [Double]) -> Int? {
        guard !arr.isEmpty else { return nil }
        var maxIndex = -1
        for (i, v) in arr.enumerated() {
            // maxIndex == -1 时用 NaN 模拟 JS 的 arr[undefined]：任何比较均为 false
            let current = maxIndex >= 0 ? arr[maxIndex] : Double.nan
            if !(current > v) {
                maxIndex = i
            }
        }
        return maxIndex
    }

    /// 每行最大值下标（toMidi.ts L102-103）。
    /// JS 对空行返回 null，且后续若参与算术（addPitchBends 的 bends），JS 会把 null 当 0
    /// （ToNumber(null) = 0）——此处对齐（正常输入矩阵行非空，此分支仅病态输入触达）。
    static func argMaxAxis1(_ arr: [[Double]]) -> [Int] {
        arr.map { row in argMax(row) ?? 0 }
    }

    /// 找出 2D 矩阵中大于阈值的元素坐标（toMidi.ts L113-130）。
    /// 返回 (行下标数组, 列下标数组)；NaN 与阈值比较恒为 false，与 JS 一致。
    static func whereGreaterThanAxis1(_ arr2d: [[Double]], threshold: Double) -> ([Int], [Int]) {
        var outputX = [Int]()
        var outputY = [Int]()
        for i in 0..<arr2d.count {
            for j in 0..<arr2d[i].count {
                if arr2d[i][j] > threshold {
                    outputX.append(i)
                    outputY.append(j)
                }
            }
        }
        return (outputX, outputY)
    }

    /// 2D 数组的均值与样本标准差（toMidi.ts L137-154）。
    /// std = sqrt((1/(N-1)) × (Σx² − (Σx)²/N))，即样本标准差（除以 N-1）；
    /// 累加顺序（行序、列序）与 JS 的两层 reduce 一致，保证浮点结果逐位一致。
    static func meanStdDev(_ array: [[Double]]) -> (mean: Double, std: Double) {
        var sum = 0.0
        var sumSquared = 0.0
        var count = 0.0
        for row in array {
            for value in row {
                sum += value
                sumSquared += value * value
                count += 1
            }
        }
        // E[x]
        let mean = sum / count
        // sqrt( (1 / (N - 1)) * (E[x^2] - E[x]^2 / N))
        let std = sqrt((1 / (count - 1)) * (sumSquared - (sum * sum) / count))
        return (mean, std)
    }

    /// 2D 数组全局最大值（toMidi.ts L161-163）。
    /// JS: array.reduce((prev, row) => Math.max(prev, ...row), 0) —— 初始值为 0，
    /// 故结果恒 ≥ 0（除非矩阵含 NaN，此时 NaN 传播）。
    static func globalMax(_ array: [[Double]]) -> Double {
        var result = 0.0
        for row in array {
            for v in row {
                result = jsMax(result, v)
            }
        }
        return result
    }

    /// 3D 数组沿 axis 0 取最小（toMidi.ts L170-182）。
    /// 使用 jsMin 保持 NaN 传播语义（JS Math.min(a, NaN) = NaN）。
    static func min3dForAxis0(_ array: [[[Double]]]) -> [[Double]] {
        var minArray = array[0].map { $0 }
        // np.min axis=0
        for x in 1..<array.count {
            for y in 0..<array[0].count {
                for z in 0..<array[0][0].count {
                    minArray[y][z] = jsMin(minArray[y][z], array[x][y][z])
                }
            }
        }
        return minArray
    }

    /// 3D 数组沿 axis 0 取最大（toMidi.ts L227-237）。NaN 传播语义见 jsMax。
    static func max3dForAxis0(_ array: [[[Double]]]) -> [[Double]] {
        var maxArray = array[0].map { $0 }
        for x in 1..<array.count {
            for y in 0..<array[0].count {
                for z in 0..<array[0][0].count {
                    maxArray[y][z] = jsMax(maxArray[y][z], array[x][y][z])
                }
            }
        }
        return maxArray
    }

    /// scipy.signal.argrelmax 的 TS 实现（toMidi.ts L198-220）。
    /// 严格大于两侧 order 邻域（不含自身）；邻域截断到数组边界。
    /// 收集顺序：col 外层、row 内层（顺序影响结果集顺序，与 JS 保持一致）。
    /// NaN 比较（NaN > x）恒为 false，与 JS 一致。
    static func argRelMax(_ array: [[Double]], order: Int = 1) -> [(row: Int, col: Int)] {
        var result: [(row: Int, col: Int)] = []
        for col in 0..<array[0].count {
            for row in 0..<array.count {
                var isRelMax = true
                var comparisonRow = max(0, row - order)
                while isRelMax && comparisonRow <= min(array.count - 1, row + order) {
                    if comparisonRow != row {
                        isRelMax = isRelMax && array[row][col] > array[comparisonRow][col]
                    }
                    comparisonRow += 1
                }
                if isRelMax {
                    result.append((row, col))
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    /// 将 onsets/frames 超出频率边界的部分置 0（toMidi.ts L257-282，原地修改）。
    static func constrainFrequency(
        onsets: inout [[Double]],
        frames: inout [[Double]],
        maxFreq: Double?,
        minFreq: Double?
    ) {
        // JS: if (maxFreq) —— truthiness 检查：0/undefined 为假跳过，NaN 为真执行。此处对齐。
        if let maxFreq = maxFreq, maxFreq != 0 {
            // JS: const maxFreqIdx = hzToMidi(maxFreq) - MIDI_OFFSET; row.fill(0, maxFreqIdx)
            // hzToMidi 返回浮点；fill 的 start 参数经 ToIntegerOrInfinity 向零截断
            //（对正常输入为正值，trunc 与 floor 等价；负值下 trunc 与 floor 不同，以 trunc 对齐 JS）
            let maxFreqIdx = hzToMidi(maxFreq) - Double(midiOffset)
            for i in onsets.indices {
                jsFill(&onsets[i], value: 0, start: maxFreqIdx, end: nil)
            }
            for i in frames.indices {
                jsFill(&frames[i], value: 0, start: maxFreqIdx, end: nil)
            }
        }
        if let minFreq = minFreq, minFreq != 0 {
            // JS: row.fill(0, 0, minFreqIdx) —— end 参数同样向零截断
            let minFreqIdx = hzToMidi(minFreq) - Double(midiOffset)
            for i in onsets.indices {
                jsFill(&onsets[i], value: 0, start: 0, end: minFreqIdx)
            }
            for i in frames.indices {
                jsFill(&frames[i], value: 0, start: 0, end: minFreqIdx)
            }
        }
    }

    /// 由帧能量的剧烈变化推断 onsets（toMidi.ts L289-325）。
    static func getInferredOnsets(
        onsets: [[Double]],
        frames: [[Double]],
        nDiff: Int = 2
    ) -> [[Double]] {
        // 对 n = 1...nDiff：frames 前补 n 行全零后做 n 阶差分（diff[i] = frames[i] − frames[i−n]）
        var diffs = [[[Double]]]()
        for n in 1...nDiff {
            // JS: Array(n).fill(Array(frames[0].length).fill(0)).concat(frames)
            let rowLength = frames[0].count
            var framesAppended = [[Double]](repeating: [Double](repeating: 0, count: rowLength), count: n)
            framesAppended.append(contentsOf: frames)
            // JS: const nPlus = framesAppended.slice(n);
            //     const minusN = framesAppended.slice(0, -n);
            let nPlus = Array(framesAppended[n...])
            let minusN = Array(framesAppended[0..<(framesAppended.count - n)])
            precondition(
                nPlus.count == minusN.count,
                "nPlus length != minusN length: \(nPlus.count) != \(minusN.count)"
            )
            // JS: nPlus.map((row, r) => row.map((v, c) => v - minusN[r][c]))
            diffs.append(zip(nPlus, minusN).map { plusRow, minusRow in
                zip(plusRow, minusRow).map { $0 - $1 }
            })
        }

        var frameDiff = min3dForAxis0(diffs)

        // JS: frame_diff[frame_diff < 0] = 0（用 Math.max(v, 0)，NaN 传播）
        frameDiff = frameDiff.map { row in row.map { v in jsMax(v, 0) } }
        // JS: frame_diff[:n_diff, :] = 0
        for r in 0..<min(nDiff, frameDiff.count) {
            for c in frameDiff[r].indices {
                frameDiff[r][c] = 0
            }
        }

        // JS: rescale to have the same max as onsets
        let onsetMax = globalMax(onsets)
        let frameDiffMax = globalMax(frameDiff)
        // 注意：frameDiffMax == 0（frames 全零或无任何变化）时，onsetMax*v/0 即 0/0 = NaN
        //（IEEE754），与 JS number 行为完全一致：NaN 经下方 max3dForAxis0 传播使推断 onsets
        // 全 NaN，argRelMax 与阈值比较（NaN 比较恒 false）均无峰值 —— 净效果为"无推断起始"，
        // 故此处不做任何特判，直接按公式计算。
        frameDiff = frameDiff.map { row in row.map { v in (onsetMax * v) / frameDiffMax } }

        // JS: np.max([onsets, frame_diff], axis=0) —— 用预测 onsets 与差分的逐元素最大值
        return max3dForAxis0([onsets, frameDiff])
    }

    // MARK: - 主解码

    /// 将模型原始输出解码为复音音符事件（toMidi.ts L342-530）。
    ///
    /// - Parameters:
    ///   - frames: 帧激活矩阵 (n_times, n_freqs)
    ///   - onsets: 起始激活矩阵 (n_times, n_freqs)
    ///   - onsetThreshold: 起始被视为音符开头的最小激活幅度
    ///   - frameThreshold: 帧能量阈值，低于它则视为音符能量下降（nil 时用 frames 的 mean+std）
    ///   - minNoteLength: 最短音符长度（帧）
    ///   - inferOnsets: 帧能量剧烈变化时推断额外起始
    ///   - maxFrequency / minFrequency: 输出频率上下界（Hz）
    ///   - melodiaTrick: 移除峰值附近的半音（补充无起始峰值的音符）
    ///   - energyTolerance: 允许连续低于阈值的帧数
    /// - Returns: 音符事件列表（帧域）
    static func outputToNotesPoly(
        frames: [[Double]],
        onsets: [[Double]],
        onsetThreshold: Double = 0.5,
        frameThreshold: Double? = 0.3,
        minNoteLength: Int = 5,
        inferOnsets: Bool = true,
        maxFrequency: Double? = nil,
        minFrequency: Double? = nil,
        melodiaTrick: Bool = true,
        energyTolerance: Int = 11
    ) throws -> [NoteEvent] {
        // JS: let inferredFrameThresh = frameThresh;
        //     if (inferredFrameThresh === null) { mean + std }
        let frameThresh: Double
        if let threshold = frameThreshold {
            frameThresh = threshold
        } else {
            let (mean, std) = meanStdDev(frames)
            frameThresh = mean + std
        }

        let nFrames = frames.count

        // JS 的 constrainFrequency 原地修改 onsets/frames；Swift 值语义下取可变副本
        var onsets = onsets
        var frames = frames
        constrainFrequency(onsets: &onsets, frames: &frames, maxFreq: maxFrequency, minFreq: minFrequency)

        var inferredOnsets = onsets
        if inferOnsets {
            inferredOnsets = getInferredOnsets(onsets: onsets, frames: frames) // avoid no-param-reassign
        }

        // a hacky form of zeros-like
        var peakThresholdMatrix = inferredOnsets.map { row in row.map { _ in 0.0 } }
        for peak in argRelMax(inferredOnsets) {
            peakThresholdMatrix[peak.row][peak.col] = inferredOnsets[peak.row][peak.col]
        }

        var (noteStarts, freqIdxs) = whereGreaterThanAxis1(peakThresholdMatrix, threshold: onsetThreshold)

        // JS: noteStarts.reverse(); freqIdxs.reverse();（从后往前处理）
        noteStarts.reverse()
        freqIdxs.reverse()

        // Deep copy to remaining energy
        var remainingEnergy = frames.map { $0.map { $0 } }

        var noteEvents = [NoteEvent]()
        for idx in noteStarts.indices {
            let noteStartIdx = noteStarts[idx]
            let freqIdx = freqIdxs[idx]
            // if we're too close to the end of the audio, continue
            if noteStartIdx >= nFrames - 1 {
                continue
            }

            // find time index at this frequency band where the frames drop below an energy threshold
            var i = noteStartIdx + 1
            var k = 0 // number of frames since energy dropped below threshold
            while i < nFrames - 1 && k < energyTolerance {
                if remainingEnergy[i][freqIdx] < frameThresh {
                    k += 1
                } else {
                    k = 0
                }
                i += 1
            }

            i -= k // go back to frame above threshold

            // if the note is too short, skip it
            //（顺序很重要：跳过的音符不清零 remainingEnergy）
            if i - noteStartIdx <= minNoteLength {
                continue
            }

            for j in noteStartIdx..<i {
                remainingEnergy[j][freqIdx] = 0
                if freqIdx < maxFreqIdx {
                    remainingEnergy[j][freqIdx + 1] = 0
                }
                if freqIdx > 0 {
                    remainingEnergy[j][freqIdx - 1] = 0
                }
            }

            // add the note
            // JS: frames.slice(noteStartIdx, i).reduce((prev, row) => prev + row[freqIdx], 0) / (i - noteStartIdx)
            let noteRows = frames[jsSliceRange(start: noteStartIdx, end: i, length: frames.count)]
            var sum = 0.0
            for row in noteRows {
                sum += row[freqIdx]
            }
            let amplitude = sum / Double(i - noteStartIdx)

            noteEvents.append(
                NoteEvent(
                    startFrame: noteStartIdx,
                    durationFrames: i - noteStartIdx,
                    pitchMidi: freqIdx + midiOffset,
                    amplitude: amplitude,
                    pitchBends: nil
                )
            )
        }

        if melodiaTrick {
            // —— melodia 循环性能优化（语义逐位等价的重写）——
            //
            // 原实现每轮迭代做 2 次全矩阵扫描：
            //   ① while 条件的 globalMax(remainingEnergy)：逐格 jsMax 折叠，O(nFrames×88)
            //   ② 循环体内逐行 argMax 找全局峰值坐标：又是 O(nFrames×88)
            // 长音频（2 万+ 帧）× 数百轮迭代在 Debug(-Onone) 下累计耗时数百秒。
            //
            // 优化：行缓存 + 脏行重算 ——
            //   - rowMaxFold[r]：第 r 行的 jsMax 折叠值（NaN 传播），供 while 条件做行间折叠
            //   - argMaxCol[r]：argMax(remainingEnergy[r]) 的缓存（"相等取后" tie 语义由
            //     argMax 本身保证；空行存 -1，对应原实现 guard let 的 continue）
            //   - 每轮所有清零触碰的行标记为脏，并在任何 continue / 下一轮条件检查之前，
            //     用与初建完全相同的计算重算缓存
            //
            // 语义一致性论证（输出逐位不变）：
            //   1. jsMax 可任意结合：非 NaN 侧是精确的 IEEE754 max（无舍入），任一侧为 NaN
            //      则结果为 NaN —— 故 globalMax 的"逐格全折叠"与"先折行、再行间折叠"的
            //      最终值逐位相同；
            //   2. 未变动行的缓存恒等于实时重算（矩阵未变，纯函数结果不变）；脏行在轮末用
            //      完全相同的 rowFoldMax/argMax 重算 → 每轮读到的缓存与"每轮全矩阵重扫"逐位一致；
            //   3. 峰值扫描期间 (iMid, freqIdx) 单元格不会被写入，用局部 bestVal 跟踪与原实现
            //      每次重读 remainingEnergy[iMid][freqIdx] 等价；
            //   4. 音符记录、amplitude、清零操作、异常抛出完全不动；globalMax/argMax 函数本体
            //      与其他调用处（melodia=false 主路径等）均未改动。
            var rowMaxFold = [Double](repeating: 0, count: nFrames)
            var argMaxCol = [Int](repeating: -1, count: nFrames)
            var rowDirty = [Bool](repeating: false, count: nFrames)
            var dirtyRows = [Int]()

            // 单行 jsMax 折叠（从 0 起、NaN 传播）—— 与 globalMax 对单行矩阵的逐格折叠逐位一致
            func rowFoldMax(_ row: [Double]) -> Double {
                var result = 0.0
                for v in row {
                    result = jsMax(result, v)
                }
                return result
            }

            // 标记清零触碰的行（rowDirty 去重，保证每条脏行只入列一次）
            func markDirty(_ r: Int) {
                if !rowDirty[r] {
                    rowDirty[r] = true
                    dirtyRows.append(r)
                }
            }

            // 脏行重算：用与初建完全相同的计算刷新缓存。
            // 必须在任何 continue / 下一轮条件检查之前调用，保证缓存与矩阵同步。
            func recomputeDirtyRows() {
                for r in dirtyRows {
                    rowMaxFold[r] = rowFoldMax(remainingEnergy[r])
                    argMaxCol[r] = argMax(remainingEnergy[r]) ?? -1
                    rowDirty[r] = false
                }
                dirtyRows.removeAll(keepingCapacity: true)
            }

            for r in remainingEnergy.indices {
                rowMaxFold[r] = rowFoldMax(remainingEnergy[r])
                argMaxCol[r] = argMax(remainingEnergy[r]) ?? -1
            }

            // 原实现：while globalMax(remainingEnergy) > frameThresh { ... }
            // 等价改写为 while true + 顶部条件检查（continue 依旧回到顶部，语义不变）：
            // globalMax(矩阵) ≡ 从 0 起对各行的 rowMaxFold 依次 jsMax 折叠（O(nRows)，
            // 依据见上方第 1 点），替代每轮 O(nRows×88) 的逐格扫描。
            while true {
                var globalMaxValue = 0.0
                for rowIdx in remainingEnergy.indices {
                    globalMaxValue = jsMax(globalMaxValue, rowMaxFold[rowIdx])
                }
                if !(globalMaxValue > frameThresh) {
                    break
                }

                // 找 remainingEnergy 的全局最大值坐标（JS L445-454 的 reduce，初始 [0, 0]）。
                // 注意与 argMax 的"相等取后"不同：此处行间比较用严格 >，相等时保留先出现的坐标。
                // 初始 best 取 (0,0) 的单元格值（不是第 0 行的最大值！）；随后逐行用缓存下标
                // 从矩阵读实际值参与严格 > 比较（NaN 比较恒 false 自然跳过，与 JS 一致）。
                var iMid = 0
                var freqIdx = 0
                var bestVal = remainingEnergy[0][0]
                for rowIdx in remainingEnergy.indices {
                    let colMaxIdx = argMaxCol[rowIdx]
                    if colMaxIdx < 0 {
                        continue // 空行：对应 argMax 返回 nil 的 guard continue
                    }
                    let v = remainingEnergy[rowIdx][colMaxIdx]
                    if v > bestVal {
                        bestVal = v
                        iMid = rowIdx
                        freqIdx = colMaxIdx
                    }
                }
                remainingEnergy[iMid][freqIdx] = 0
                markDirty(iMid)

                // forward pass（JS L457-476）：
                // 与主循环不同——能量判断之后、i 递增之前，循环体内就地清零三列能量
                var i = iMid + 1
                var k = 0
                while i < nFrames - 1 && k < energyTolerance {
                    if remainingEnergy[i][freqIdx] < frameThresh {
                        k += 1
                    } else {
                        k = 0
                    }

                    remainingEnergy[i][freqIdx] = 0
                    if freqIdx < maxFreqIdx {
                        remainingEnergy[i][freqIdx + 1] = 0
                    }
                    if freqIdx > 0 {
                        remainingEnergy[i][freqIdx - 1] = 0
                    }
                    markDirty(i)

                    i += 1
                }
                let iEnd = i - 1 - k

                // backwards pass（JS L478-498）：
                // 循环条件是 i > 0（不是 i >= 0），同样在循环体内清零
                i = iMid - 1
                k = 0
                while i > 0 && k < energyTolerance {
                    if remainingEnergy[i][freqIdx] < frameThresh {
                        k += 1
                    } else {
                        k = 0
                    }

                    remainingEnergy[i][freqIdx] = 0
                    if freqIdx < maxFreqIdx {
                        remainingEnergy[i][freqIdx + 1] = 0
                    }
                    if freqIdx > 0 {
                        remainingEnergy[i][freqIdx - 1] = 0
                    }
                    markDirty(i)

                    i -= 1
                }
                let iStart = i + 1 + k

                // 清零触碰的行已全部标记为脏；在任何 continue / 下一轮条件检查之前重算缓存，
                // 保证下一轮 while 条件与峰值扫描读到与矩阵同步的缓存（语义等价的关键）
                recomputeDirtyRows()

                if iStart < 0 {
                    throw NoteDecoderError.iStartNotPositive(iStart)
                }
                if iEnd >= nFrames {
                    throw NoteDecoderError.iEndPastEndOfTimes(iEnd: iEnd, nFrames: nFrames)
                }

                // JS: amplitude = np.mean(frames[i_start:i_end, freq_idx])
                //（slice 的 JS 语义：iEnd < iStart 时为空数组，reduce 初值 0，
                //  除以 (iEnd - iStart) 得 ±0/NaN —— 但下方长度检查会 continue 掉该音符）
                let ampRows = frames[jsSliceRange(start: iStart, end: iEnd, length: frames.count)]
                var ampSum = 0.0
                for row in ampRows {
                    ampSum += row[freqIdx]
                }
                let amplitude = ampSum / Double(iEnd - iStart)

                if iEnd - iStart <= minNoteLength {
                    // note is too short or too quiet, skip it and remove the energy
                    //（注意：continue 在 amplitude 计算之后，与 JS 顺序一致）
                    continue
                }

                // add the note
                noteEvents.append(
                    NoteEvent(
                        startFrame: iStart,
                        durationFrames: iEnd - iStart,
                        pitchMidi: freqIdx + midiOffset,
                        amplitude: amplitude,
                        pitchBends: nil
                    )
                )
            }
        }

        return noteEvents
    }

    // MARK: - 弯音

    /// 对称高斯窗（toMidi.ts L539-542，基于 scipy.signal.gaussian）：
    /// w(n) = exp(−1/2 × ((n − (M−1)/2) / std)²)
    /// M ≤ 0 时返回空数组（与 JS Array(M).keys() 行为一致）。
    static func gaussian(M: Int, std: Double) -> [Double] {
        // JS: Math.exp((-1 * (n - (M - 1) / 2) ** 2) / (2 * std ** 2))
        (0..<max(M, 0)).map { n in
            let center = Double(n) - Double(M - 1) / 2.0
            return exp(-1.0 * center * center / (2.0 * std * std))
        }
    }

    /// MIDI 音高 → contour bin 索引（浮点，toMidi.ts L544-547）
    static func midiPitchToContourBin(pitchMidi: Int) -> Double {
        12.0
            * Double(contoursBinsPerSemitone)
            * log2(midiToHz(Double(pitchMidi)) / annotationsBaseFrequency)
    }

    /// 为音符事件附加弯音（toMidi.ts L549-586）。
    /// bends 的单位是 contour bin 数（每半音 3 bins），与 JS 输出一致；
    /// 上层如需半音单位需自行除以 contoursBinsPerSemitone。
    static func addPitchBendsToNoteEvents(
        contours: [[Double]],
        notes: [NoteEvent],
        nBinsTolerance: Int = 25
    ) -> [NoteEvent] {
        let windowLength = nBinsTolerance * 2 + 1 // 51
        let freqGaussian = gaussian(M: windowLength, std: 5)
        return notes.map { note in
            // JS: Math.floor(Math.round(...)) —— 双重取整保持 JS 顺序；
            // Math.round = floor(x + 0.5)（jsRound），与 Swift 内置 round 的五成双语义不同
            let freqIdx = Int(floor(jsRound(midiPitchToContourBin(pitchMidi: note.pitchMidi))))
            let freqStartIdx = max(freqIdx - nBinsTolerance, 0)
            let freqEndIdx = min(nFreqBinsContours, freqIdx + nBinsTolerance + 1)

            // JS: freqGaussian.slice(max(0, nBinsTolerance - freqIdx),
            //        windowLength - max(0, freqIdx - (N_FREQ_BINS_CONTOURS - nBinsTolerance - 1)))
            let freqGaussianSubMatrix = Array(
                freqGaussian[
                    jsSliceRange(
                        start: max(0, nBinsTolerance - freqIdx),
                        end: windowLength - max(0, freqIdx - (nFreqBinsContours - nBinsTolerance - 1)),
                        length: freqGaussian.count
                    )
                ]
            )

            // JS: contours.slice(startFrame, startFrame + durationFrames)
            //       .map(d => d.slice(freqStartIdx, freqEndIdx).map((v, col) => v * freqGuassianSubMatrix[col]))
            let rowRange = jsSliceRange(
                start: note.startFrame,
                end: note.startFrame + note.durationFrames,
                length: contours.count
            )
            let pitchBendSubmatrix = contours[rowRange].map { d -> [Double] in
                let colRange = jsSliceRange(start: freqStartIdx, end: freqEndIdx, length: d.count)
                return Array(d[colRange]).enumerated().map { (col, v) in
                    // 正常输入下子矩阵与高斯子矩阵等长；越界时 JS 得 undefined（NaN），此处对齐
                    col < freqGaussianSubMatrix.count ? v * freqGaussianSubMatrix[col] : v * .nan
                }
            }

            // JS: const pbShift = nBinsTolerance - Math.max(0, nBinsTolerance - freqIdx);
            let pbShift = nBinsTolerance - max(0, nBinsTolerance - freqIdx)
            // JS 的 bends 是 number[]（值为整数 bin 偏移）；此处 argMaxAxis1 返回 [Int]，
            // 统一转 [Double] 对齐 NoteEvent.pitchBends 的 [Double]? 字段（数值不变）
            let bends = argMaxAxis1(pitchBendSubmatrix).map { Double($0 - pbShift) }
            var result = note
            result.pitchBends = bends
            return result
        }
    }

    /// 音符事件帧域 → 秒域（toMidi.ts L588-599）
    static func noteFramesToTime(_ notes: [NoteEvent]) -> [NoteEventTime] {
        notes.map { note in
            NoteEventTime(
                startTimeSeconds: modelFrameToTime(note.startFrame),
                durationSeconds: modelFrameToTime(note.startFrame + note.durationFrames)
                    - modelFrameToTime(note.startFrame),
                pitchMidi: note.pitchMidi,
                amplitude: note.amplitude,
                pitchBends: note.pitchBends
            )
        }
    }

    // MARK: - JS 数组方法语义辅助

    /// 模拟 JS Array.prototype.fill(value, start, end)（toMidi.ts constrainFrequency 使用）：
    /// start/end 经 ToIntegerOrInfinity 向零截断；负数从数组末尾数起；
    /// 越界收敛到 [0, length]；start ≥ end 时无操作。
    private static func jsFill(_ row: inout [Double], value: Double, start: Double, end: Double?) {
        let length = row.count
        func normalize(_ v: Double) -> Int {
            var i = Int(v.rounded(.towardZero)) // ToIntegerOrInfinity：向零截断
            if i < 0 { i += length }
            return min(max(i, 0), length)
        }
        let s = normalize(start)
        let e = normalize(end ?? Double(length))
        if s < e {
            for j in s..<e {
                row[j] = value
            }
        }
    }

    /// 模拟 JS Array.prototype.slice(start, end) 的索引语义：
    /// 负数从末尾数起；越界收敛到 [0, length]；end ≤ start 时为空区间。
    /// （本文件所有切片输入均为非负 Int，负数分支仅为完整对齐 JS 语义。）
    private static func jsSliceRange(start: Int, end: Int, length: Int) -> Range<Int> {
        func normalize(_ v: Int) -> Int {
            var i = v
            if i < 0 { i += length }
            return min(max(i, 0), length)
        }
        let s = normalize(start)
        let e = normalize(end)
        return s < e ? s..<e : 0..<0
    }
}
