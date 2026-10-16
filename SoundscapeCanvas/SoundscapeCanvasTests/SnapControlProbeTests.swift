//
//  SnapControlProbeTests.swift
//  SoundscapeCanvasTests
//
//  审查临时探针（复审用，跑完即删）：与 DualMelodyBenchmarkTests 相同管线与
//  F 口径，但**不做 snapVoiceNotes 节奏整形**，输出无吸附对照 F 值，
//  用于量化评估整形对验收口径的贡献。只打印不断言阈值。
//

import XCTest
@testable import SoundscapeCanvas

private struct ProbeTruthNote: Codable {
    let startFrame: Int
    let durationFrames: Int
    let pitchMidi: Int
}

private struct ProbeTruthFile: Codable {
    let melody: [ProbeTruthNote]
    let countermelody: [ProbeTruthNote]
}

final class SnapControlProbeTests: XCTestCase {

    private func matchNoSnap(
        truth: [ProbeTruthNote], selected: [MelodyNote], timeResolution: Double
    ) -> Double {
        let truthSorted = truth.sorted { $0.startFrame < $1.startFrame }
        let sel = selected.map {
            (midi: $0.midiNote,
             startFrame: $0.startTime / timeResolution,
             durFrames: ($0.endTime - $0.startTime) / timeResolution)
        }.sorted { $0.startFrame < $1.startFrame }
        var used = [Bool](repeating: false, count: sel.count)
        var matched = 0
        for t in truthSorted {
            var best: Int?
            var bestD = Double.greatestFiniteMagnitude
            for (i, a) in sel.enumerated() where !used[i] {
                guard a.midi == t.pitchMidi else { continue }
                let dS = abs(a.startFrame - Double(t.startFrame))
                let dD = abs(a.durFrames - Double(t.durationFrames))
                guard dS <= 2, dD <= 4 else { continue }
                if dS < bestD { bestD = dS; best = i }
            }
            if let i = best { used[i] = true; matched += 1 }
        }
        let p = sel.isEmpty ? 0 : Double(matched) / Double(sel.count)
        let r = truthSorted.isEmpty ? 1.0 : Double(matched) / Double(truthSorted.count)
        return p + r == 0 ? 0 : 2 * p * r / (p + r)
    }

    private func probe(_ name: String) async throws {
        let truthURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "\(name)-truth", withExtension: "json"))
        let raw = try JSONDecoder().decode(ProbeTruthFile.self, from: Data(contentsOf: truthURL))
        let wavURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "wav"))
        let loaded = try AudioLoader.load(url: wavURL)
        let data = try await MelodyAnalysisService.shared.analyze(
            samples: loaded.monoSamples, sampleRate: loaded.sampleRate
        )
        let mF = matchNoSnap(
            truth: raw.melody,
            selected: data.notes.filter { $0.role == .melody },
            timeResolution: data.timeResolution)
        let cF = matchNoSnap(
            truth: raw.countermelody,
            selected: data.notes.filter { $0.role == .countermelody },
            timeResolution: data.timeResolution)
        let mSel = data.notes.filter { $0.role == .melody }.count
        let cSel = data.notes.filter { $0.role == .countermelody }.count
        let line = "[PROBE-NOSNAP][\(name)] melody F=\(String(format: "%.4f", mF)) (选中\(mSel)/真值\(raw.melody.count)) counter F=\(String(format: "%.4f", cF)) (选中\(cSel)/真值\(raw.countermelody.count))\n"
        let path = "/tmp/probe-nosnap.log"
        if let h = FileHandle(forWritingAtPath: path) { defer { try? h.close() }; h.seekToEndOfFile(); h.write(line.data(using: .utf8)!) } else { FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8)) }
    }

    func testProbeA() async throws { try await probe("dual-a") }
    func testProbeB() async throws { try await probe("dual-b") }
    func testProbeC() async throws { try await probe("dual-c") }
}
