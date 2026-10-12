import Foundation

@main
struct SpeakerTests {
    static func main() throws {
        var document = TranscriptDocument()
        let tokens = [TranscriptToken(text: "今天开始会议。", start: 0, end: 3),
                      TranscriptToken(text: "我来介绍进度。", start: 3, end: 6),
                      TranscriptToken(text: "好的，谢谢。", start: 6, end: 9)]
        document.update(source: .imported, start: 0, end: 9, text: tokens.map(\.text).joined(), isFinal: true, tokens: tokens)
        let originalID = document.lines[0].id
        document.toggleImportant(originalID)
        let turns = [SpeakerTurn(source: .imported, start: 0, end: 3, speakerID: "a"),
                     SpeakerTurn(source: .imported, start: 3, end: 6, speakerID: "b"),
                     SpeakerTurn(source: .imported, start: 6, end: 9, speakerID: "a")]
        document.applySpeakerTurns(turns)
        precondition(document.lines.map(\.speakerID) == ["a", "b", "a"])
        precondition(document.lines.map(\.text).joined() == tokens.map(\.text).joined())
        precondition(document.lines[0].id == originalID && document.lines.allSatisfy { $0.isImportant == true })
        document.renameSpeaker("a", name: "主持人王明")
        document.renameSpeaker("b", name: "工程师李华")
        precondition(document.bodyText.components(separatedBy: "主持人王明").count == 3)
        precondition(document.subtitles.contains("工程师李华：我来介绍进度。"))
        document.assignSpeaker(document.lines[1].id, speakerID: "a")
        document.edit(document.lines[2].id, text: "校对后谢谢。")
        document.applySpeakerTurns(turns)
        precondition(document.lines[1].speakerID == "a" && document.lines[1].speakerManuallyAssigned == true)
        precondition(document.lines[2].text == "校对后谢谢。" && document.lines[2].originalText == "好的，谢谢。")
        let rerun = turns.map { SpeakerTurn(source: $0.source, start: $0.start, end: $0.end, speakerID: $0.speakerID == "a" ? "new-9" : "new-1") }
        document.applySpeakerTurns(document.reconciledSpeakerTurns(rerun))
        precondition(document.speakerName(document.lines[0].speakerID) == "主持人王明")
        document.assignSpeaker(document.lines[0].id, speakerID: nil)
        document.applySpeakerTurns(turns)
        precondition(document.lines[0].speakerID == nil && document.lines[0].speakerManuallyAssigned == true)
        document.assignSpeaker(document.lines[2].id, speakerID: "invalid")
        precondition(document.lines[2].speakerID == "a")

        var ambiguous = TranscriptDocument()
        ambiguous.update(source: .system, start: 0, end: 3, text: "重叠声音", isFinal: true)
        ambiguous.applySpeakerTurns([SpeakerTurn(source: .system, start: 0, end: 3, speakerID: "a"),
                                     SpeakerTurn(source: .system, start: 0, end: 3, speakerID: "b")])
        precondition(ambiguous.lines[0].speakerID == nil)
        ambiguous.applySpeakerTurns([SpeakerTurn(source: .microphone, start: 0, end: 3, speakerID: "a")])
        precondition(ambiguous.lines[0].speakerID == nil)
        precondition(ambiguous.addSpeaker(name: "  ") == nil)
        var punctuation = TranscriptDocument()
        punctuation.update(source: .imported, start: 0, end: 4, text: "你好。", isFinal: true,
            tokens: [TranscriptToken(text: "你好", start: 0, end: 2), TranscriptToken(text: "。", start: 3, end: 4)])
        punctuation.update(source: .imported, start: 4, end: 4.1, text: "！", isFinal: true)
        punctuation.applySpeakerTurns([SpeakerTurn(source: .imported, start: 0, end: 2, speakerID: "a")])
        precondition(punctuation.lines.count == 1 && punctuation.lines[0].text == "你好。！")
        precondition(punctuation.lines[0].speakerID == "a" && punctuation.lines[0].end == 4.1)

        var adjacent = TranscriptDocument()
        adjacent.update(source: .imported, start: 0, end: 2, text: "今天讨论", isFinal: true,
            tokens: [TranscriptToken(text: "今天讨论", start: 0, end: 2)])
        adjacent.update(source: .imported, start: 2, end: 4, text: "上线方案。", isFinal: true,
            tokens: [TranscriptToken(text: "上线方案。", start: 2, end: 4)])
        adjacent.applySpeakerTurns([SpeakerTurn(source: .imported, start: 0, end: 4, speakerID: "a")])
        precondition(adjacent.lines.count == 1 && adjacent.lines[0].text == "今天讨论上线方案。")
        adjacent.update(source: .imported, start: 4, end: 5, text: "手动保留", isFinal: true,
            tokens: [TranscriptToken(text: "手动保留", start: 4, end: 5)])
        let protected = adjacent.lines.last!.id
        adjacent.assignSpeaker(protected, speakerID: "a")
        adjacent.applySpeakerTurns([SpeakerTurn(source: .imported, start: 0, end: 5, speakerID: "a")])
        precondition(adjacent.lines.count == 2 && adjacent.lines.last?.id == protected)

        var onset = TranscriptDocument()
        onset.update(source: .imported, start: 0, end: 2.5, text: "我补充一下。", isFinal: true,
            tokens: [TranscriptToken(text: "我", start: 0, end: 0.24), TranscriptToken(text: "补充一下。", start: 0.24, end: 2.5)])
        onset.applySpeakerTurns([SpeakerTurn(source: .imported, start: 0.184, end: 2.5, speakerID: "a")])
        precondition(onset.lines.count == 1 && onset.lines[0].speakerID == "a")
        var shortReply = TranscriptDocument()
        shortReply.update(source: .imported, start: 0, end: 0.24, text: "嗯", isFinal: true,
            tokens: [TranscriptToken(text: "嗯", start: 0, end: 0.24)])
        shortReply.applySpeakerTurns([SpeakerTurn(source: .imported, start: 0.184, end: 2.5, speakerID: "a")])
        precondition(shortReply.lines[0].speakerID == nil, "a standalone short reply must not inherit a later voice")
        var conflictingOnset = TranscriptDocument()
        conflictingOnset.update(source: .imported, start: 0, end: 2.5, text: "我补充一下。", isFinal: true,
            tokens: [TranscriptToken(text: "我", start: 0, end: 0.24), TranscriptToken(text: "补充一下。", start: 0.24, end: 2.5)])
        conflictingOnset.applySpeakerTurns([SpeakerTurn(source: .imported, start: 0, end: 0.1, speakerID: "b"),
                                            SpeakerTurn(source: .imported, start: 0.184, end: 2.5, speakerID: "a")])
        precondition(conflictingOnset.lines[0].speakerID == nil, "conflicting onset must stay uncertain")
        var duplicatedCoverage = TranscriptDocument()
        duplicatedCoverage.update(source: .imported, start: 0, end: 1, text: "短句", isFinal: true)
        duplicatedCoverage.applySpeakerTurns([SpeakerTurn(source: .imported, start: 0, end: 0.3, speakerID: "a"),
                                             SpeakerTurn(source: .imported, start: 0, end: 0.3, speakerID: "a")])
        precondition(duplicatedCoverage.lines[0].speakerID == nil, "duplicate intervals must not inflate speaker confidence")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        var record = MeetingRecord(title: "中文说话人测试", textFileName: "test.txt")
        record.document = document
        let segment = MeetingAudioSegment(source: .system, start: 5, fileName: UUID().uuidString + ".wav", duration: 9)
        record.audioSegments = [segment]
        try store.save(record)
        let url = try store.audioURL(for: segment, in: record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio fixture".utf8).write(to: url)
        let loaded = try store.load().first!
        precondition(loaded.document == document && loaded.audioSegments?.first?.start == 5)
        precondition(loaded.plainText.contains("主持人王明") && loaded.markdown.contains("主持人王明"))
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        legacyJSON.removeValue(forKey: "audioSegments")
        var docJSON = legacyJSON["document"] as! [String: Any]
        docJSON.removeValue(forKey: "speakers"); docJSON.removeValue(forKey: "speakerAnalysisAt")
        docJSON["lines"] = (docJSON["lines"] as! [[String: Any]]).map { line in
            var old = line; for key in ["speakerID", "speakerManuallyAssigned", "tokens"] { old.removeValue(forKey: key) }; return old
        }
        legacyJSON["document"] = docJSON
        let oldRecord = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(oldRecord.document.speakers == nil && oldRecord.audioSegments == nil)
        let invalid = MeetingAudioSegment(source: .system, start: 0, fileName: "../../other.wav")
        do { _ = try store.audioURL(for: invalid, in: record); preconditionFailure("invalid path accepted") } catch {}
        let other = directory.appendingPathComponent("other.wav"); try Data("unrelated".utf8).write(to: other)
        record.deletedAt = Date(); try store.save(record)
        precondition(FileManager.default.fileExists(atPath: url.path))
        record.deletedAt = nil; try store.save(record)
        let restored = try store.load().first!
        precondition(restored.document == document)
        record.deletedAt = Date(); try store.save(record); try store.permanentlyDelete(record)
        precondition(!FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: other.path))
        print("PASS: 中文跨人分段、归属不串声道、重叠未确定、改名全场同步、人工纠正与原文保留、再分析姓名稳定、TXT/Markdown/SRT姓名、旧数据兼容、删除恢复及音频隔离")
    }
}
