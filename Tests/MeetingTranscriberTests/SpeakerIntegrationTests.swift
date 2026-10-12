import Foundation
import AVFoundation
import Speech

@main
struct SpeakerIntegrationTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = MeetingStore(directory: temporary)
        let models = root.appendingPathComponent("Resources/SpeakerModels")
        let engine = LocalSpeakerDiarizer(resources: models)
        let combined = root.appendingPathComponent("verification/中文双人会议示例.wav")
        // Fixed local TTS fixture: Tingting / Meijia, alternating A-B-A-B.
        // Intervals include TTS silence; this is not human-annotated real audio.
        let reference: [(Double, Double, Int)] = [(0, 6.912, 0), (7.8575, 15.14075, 1),
            (15.84075, 24.28875, 0), (25.091, 32.003, 1)]
        var record = MeetingRecord(title: "中文双人会后分离验收", textFileName: "test.txt")
        var asset = MeetingAudioSegment(source: .imported, start: 0, fileName: UUID().uuidString + ".wav")
        asset.duration = try await MeetingAudioArchive.copyFile(combined, to: store.audioURL(for: asset, in: record))
        record.audioSegments = [asset]
        let began = Date()
        let automatic = try await engine.analyze(record, store: store)
        let automaticCount = Set(automatic.map(\.speakerID)).count
        let chosenCount = automaticCount == 2 ? 0 : 2
        let turns = chosenCount == 0 ? automatic : try await engine.analyze(record, store: store, speakerCount: chosenCount)
        let separationSeconds = Date().timeIntervalSince(began)
        let ids = Array(Set(turns.map(\.speakerID)))
        precondition(ids.count == 2, "指定人数后中文双人样本没有分为两人")
        func dominant(_ start: Double, _ end: Double) -> String? {
            var seconds: [String: Double] = [:]
            for turn in turns {
                let overlap = min(end, turn.end) - max(start, turn.start)
                if overlap > 0 { seconds[turn.speakerID, default: 0] += overlap }
            }
            return seconds.max { $0.value < $1.value }?.key
        }
        let expected = reference.map { dominant($0.0, $0.1) }
        precondition(expected[0] != nil && expected[1] != nil && expected[0] != expected[1])
        precondition(expected[0] == expected[2] && expected[1] == expected[3], "重复发言的声纹身份不一致")
        let length = try await SpeechSession.transcribeFile(url: combined) { result in
            let tokens = result.text.runs.map { run -> TranscriptToken in
                let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? result.range
                return TranscriptToken(text: String(result.text[run.range].characters), start: range.start.seconds, end: range.end.seconds)
            }
            record.document.update(source: .imported, start: result.range.start.seconds, end: result.range.end.seconds,
                text: String(result.text.characters), isFinal: result.isFinal, tokens: result.isFinal ? tokens : nil)
        }
        let raw = record.document.lines.map(\.text).joined().filter { !$0.isWhitespace }
        let originalLineCount = record.document.lines.count
        try JSONEncoder().encode(record.document).write(to: root.appendingPathComponent("verification/speaker-raw-document.json"))
        precondition(raw.contains("会议") && raw.contains("本机") && raw.contains("归属"), "中文转写缺少预期关键词")
        record.document.applySpeakerTurns(turns)
        precondition(record.document.lines.map(\.text).joined().filter { !$0.isWhitespace } == raw, "分人改动了转写文字")
        precondition(Set(record.document.lines.compactMap(\.speakerID)).count == 2)
        let assigned = record.document.lines.filter { $0.speakerID != nil }.count
        record.document.renameSpeaker(expected[0]!, name: "测试发言人甲")
        record.document.renameSpeaker(expected[1]!, name: "测试发言人乙")
        let corrected = record.document.lines.first(where: { $0.speakerID == expected[1] })!
        record.document.assignSpeaker(corrected.id, speakerID: expected[0])
        let repeated = try await engine.analyze(record, store: store, speakerCount: chosenCount)
        record.document.applySpeakerTurns(record.document.reconciledSpeakerTurns(repeated))
        precondition(record.document.lines.first { $0.id == corrected.id }?.speakerID == expected[0])
        record.elapsed = length; try store.save(record)
        let loaded = try store.load().first!
        precondition(loaded.document == record.document)
        precondition(loaded.plainText.contains("测试发言人甲") && loaded.plainText.contains("测试发言人乙"))
        precondition(loaded.markdown.contains("测试发言人甲") && loaded.document.subtitles.contains("测试发言人乙："))
        try loaded.plainText.write(to: root.appendingPathComponent("verification/speaker-transcript.txt"), atomically: true, encoding: .utf8)
        try loaded.markdown.write(to: root.appendingPathComponent("verification/speaker-transcript.md"), atomically: true, encoding: .utf8)
        try loaded.document.subtitles.write(to: root.appendingPathComponent("verification/speaker-transcript.srt"), atomically: true, encoding: .utf8)
        let testReport: [String: Any] = ["duration": length, "separationSeconds": separationSeconds, "automaticSpeakers": automaticCount,
            "chosenCount": chosenCount, "finalSpeakers": ids.count,
            "repeatSpeakerIdentity": true, "rawParagraphs": originalLineCount, "finalParagraphs": record.document.lines.count,
            "assignedParagraphs": assigned, "textUnchanged": true, "renameCorrectionReanalysisPersistenceExport": true,
            "reference": reference.map { ["start": $0.0, "end": $0.1, "speaker": $0.2] }]
        try JSONSerialization.data(withJSONObject: testReport, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("verification/speaker-integration.json"))
        let cancelling = Task { try await engine.analyze(record, store: store) }
        try await Task.sleep(for: .milliseconds(300)); cancelling.cancel()
        do { _ = try await cancelling.value; preconditionFailure("cancel ignored") } catch is CancellationError {}
        let savedAudio = try store.audioURL(for: asset, in: record)
        precondition(FileManager.default.fileExists(atPath: savedAudio.path))
        print("PASS: 实际中文双人四轮发言、自动人数及重复发言身份一致、中文ASR词时间合并、文字未丢失、改名纠正再分析保存导出、取消停止本地进程且保留音频")
        print("duration=\(length), separation=\(separationSeconds), paragraphs=\(originalLineCount)->\(record.document.lines.count)")
    }
}
