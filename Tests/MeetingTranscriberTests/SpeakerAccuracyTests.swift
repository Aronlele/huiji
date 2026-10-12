import Foundation

struct SpeakerReference: Codable { let start: Double; let end: Double; let speaker: Int }
struct PreviousDiarization: Codable {
    struct Segment: Codable { let start: Double; let end: Double; let speaker: Int }
    let segments: [Segment]
}

@main struct SpeakerAccuracyTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = MeetingStore(directory: temp)
        let engine = LocalSpeakerDiarizer(resources: root.appendingPathComponent("Resources/SpeakerModels"))
        let four: [SpeakerReference] = [(0.318,6.865,0),(7.017,10.747,1),(11.455,13.632,1),(13.750,17.041,2),
            (22.137,24.837,0),(27.638,29.478,3),(30.001,31.553,3),(33.680,37.932,3),(48.040,50.470,2),(52.529,54.605,0)]
            .map { SpeakerReference(start: $0.0, end: $0.1, speaker: $0.2) }
        let two: [SpeakerReference] = [(0.0,6.912,0),(7.8575,15.14075,1),(15.84075,24.28875,0),(25.091,32.003,1)]
            .map { SpeakerReference(start: $0.0, end: $0.1, speaker: $0.2) }
        var cases: [[String: Any]] = []
        var bestTurns: [SpeakerTurn] = []
        var mapping: [String: Int] = [:]
        for name in CommandLine.arguments.contains("--two") ? ["two"] : ["two", "four", "heldout", "single", "quick"] {
            let url = name == "two" ? root.appendingPathComponent("verification/中文双人会议示例.wav")
                : root.appendingPathComponent("verification/speaker-cases/\(name).wav")
            let reference = name == "two" ? two : name == "four" ? four : try JSONDecoder().decode([SpeakerReference].self,
                from: Data(contentsOf: root.appendingPathComponent("verification/speaker-cases/\(name)-reference.json")))
            var record = MeetingRecord(title: "合成/公开测试 \(name)", textFileName: UUID().uuidString + ".txt")
            var asset = MeetingAudioSegment(source: .imported, start: 0, fileName: UUID().uuidString + ".wav")
            asset.duration = try await MeetingAudioArchive.copyFile(url, to: store.audioURL(for: asset, in: record))
            record.audioSegments = [asset]
            let started = Date()
            let turns = try await engine.analyze(record, store: store)
            let elapsed = Date().timeIntervalSince(started)
            var scores: [String: [Int: Double]] = [:]
            for turn in turns { for ref in reference {
                let seconds = max(0, min(turn.end, ref.end) - max(turn.start, ref.start))
                scores[turn.speakerID, default: [:]][ref.speaker, default: 0] += seconds
            } }
            let owners = scores.mapValues { $0.max { $0.value < $1.value }!.key }
            precondition(Set(turns.map(\.speakerID)).count == Set(reference.map(\.speaker)).count, "\(name) 人数错误")
            precondition(Set(owners.values).count == Set(reference.map(\.speaker)).count, "\(name) 身份误合并")
            var correct = 0.0, wrong = 0.0, coveredTurns = 0
            for ref in reference {
                var owned: [String: Double] = [:]
                for turn in turns {
                    let seconds = max(0, min(turn.end, ref.end - 0.05) - max(turn.start, ref.start + 0.05))
                    if owners[turn.speakerID] == ref.speaker { correct += seconds } else { wrong += seconds }
                    owned[turn.speakerID, default: 0] += seconds
                }
                if let dominant = owned.max(by: { $0.value < $1.value })?.key, owners[dominant] == ref.speaker { coveredTurns += 1 }
            }
            let purity = correct / (correct + wrong)
            precondition(coveredTurns == reference.count && purity > 0.95, "\(name) 发言归属错误")
            cases.append(["fixture": name, "automaticSpeakers": owners.count, "referenceTurns": reference.count,
                "correctDominantTurns": coveredTurns, "labeledTimePurity": purity, "seconds": elapsed,
                "referenceKind": name == "four" ? "author model example; not independent annotation" : "known TTS voice intervals; includes silence"])
            if name == "two" { bestTurns = turns; mapping = owners }
            print("PASS \(name): auto=\(owners.count), dominant=\(coveredTurns)/\(reference.count), labeled purity=\(purity), seconds=\(elapsed)")
            fflush(stdout)
        }
        let raw = try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: root.appendingPathComponent("verification/speaker-raw-document.json")))
        var after = raw; after.applySpeakerTurns(bestTurns)
        let baseline = try JSONDecoder().decode(PreviousDiarization.self, from: Data(contentsOf: root.appendingPathComponent("verification/diarization-two-known.json")))
        let previousTurns = baseline.segments.map { SpeakerTurn(source: .imported, start: $0.start, end: $0.end, speakerID: "old-\($0.speaker)") }
        var before = raw; before.applySpeakerTurns(previousTurns)
        func wordErrors(_ doc: TranscriptDocument, owners: [String: Int]) -> (Int, Int) {
            var errors = 0, total = 0
            for line in doc.lines { for token in line.tokens ?? [] {
                let count = token.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                if count == 0 { continue }
                let center = (token.start + token.end) / 2
                let ref = two.min { a, b in
                    max(a.start - center, center - a.end, 0) < max(b.start - center, center - b.end, 0)
                }!
                total += count
                if owners[line.speakerID ?? ""] != ref.speaker { errors += count }
            } }
            return (errors, total)
        }
        let oldScore = wordErrors(before, owners: ["old-0": 0, "old-1": 1])
        let newScore = wordErrors(after, owners: mapping)
        let diagnostic: [String: Any] = ["wrongCharacters": newScore.0, "totalCharacters": newScore.1,
            "turns": bestTurns.map { ["start": $0.start, "end": $0.end, "speaker": mapping[$0.speakerID] ?? -1] },
            "lines": after.lines.map { ["start": $0.start, "end": $0.end, "speaker": mapping[$0.speakerID ?? ""] ?? -1, "text": $0.text] }]
        try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(".build/checks/speaker-word-boundaries.json"))
        precondition(newScore.1 == oldScore.1 && newScore.0 < oldScore.0)
        precondition(newScore.0 == 0, "双人词边界仍然串人")
        precondition(after.lines.count == 4)
        let report: [String: Any] = ["cases": cases, "twoChineseCharacters": newScore.1,
            "previousKnownCountWrongCharacters": oldScore.0, "newAutomaticWrongCharacters": newScore.0,
            "model": "ERes2NetV2 zh-cn 200k", "pipeline": "pyannote changes + Silero pauses + whole-fragment average-link",
            "audioUploaded": false, "realZoomValidated": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("verification/speaker-upgrade-results.json"))
        print("PASS 中文词归属: \(oldScore.0)/\(oldScore.1) 错误 -> \(newScore.0)/\(newScore.1) 错误（同一份ASR词时间，合成样本）")
    }
}
