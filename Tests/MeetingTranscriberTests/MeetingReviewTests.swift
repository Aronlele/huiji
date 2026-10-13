import Foundation
import AVFoundation

@main
struct MeetingReviewTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        var record = MeetingRecord(title: "测试周会", textFileName: "test.txt")
        record.document.update(source: .system, start: 1, end: 2, text: "王明负责接口开发，周五完成。", isFinal: true)
        record.document.update(source: .microphone, start: 8, end: 9, text: "预算仍未决定。", isFinal: true)
        let first = record.document.lines[0]
        let evidence = record.evidence
        let parsed = LocalMeetingAI.AnswerResponse(answer: "王明周五完成。", citations: [
            .init(id: first.id.uuidString, quote: "王明负责接口开发，周五完成。"),
            .init(id: first.id.uuidString, quote: "周一完成"),
            .init(id: UUID().uuidString, quote: "预算仍未决定。"),
            .init(id: first.id.uuidString, quote: " ")])
        let citations = LocalMeetingAI.validatedCitations(parsed, evidence: evidence)
        precondition(citations.count == 1 && citations[0].lineID == first.id && citations[0].start == 1)
        let groups = LocalMeetingAI.evidenceGroups([MeetingEvidence(id: "long", lineID: nil,
            text: String(repeating: "测试资料。", count: 1600) + "最后由李华验收。", start: nil, source: nil, speaker: "笔记")])
        precondition(groups.count > 1 && groups.last!.last!.text.contains("最后由李华验收。"))
        record.summaryTemplate = .review
        record.summaryGeneratedTemplate = .work
        record.answers = [MeetingAnswer(question: "谁完成接口？", answer: "王明，周五。", citations: citations, sourceFingerprint: record.evidenceFingerprint)]
        try store.save(record)
        var loaded = try store.load()[0]
        precondition(loaded.summaryTemplate == .review && loaded.summaryGeneratedTemplate == .work)
        precondition(loaded.answers?.first?.citations.first?.lineID == first.id)
        precondition(loaded.plainText.contains("王明，周五。") && loaded.markdown.contains("00:01"))
        let speaker = loaded.document.addSpeaker(name: "王明")!
        loaded.document.assignSpeaker(first.id, speakerID: speaker)
        precondition(loaded.questionExport.contains("王明"))
        loaded.document.renameSpeaker(speaker, name: "王总")
        precondition(loaded.questionExport.contains("王总") && loaded.markdown.contains("王总"))
        let oldFingerprint = loaded.evidenceFingerprint
        loaded.document.edit(first.id, text: "接口延期。")
        precondition(loaded.evidenceFingerprint != oldFingerprint && loaded.questionExport.contains("已变更"))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "summaryTemplate"); json.removeValue(forKey: "summaryGeneratedTemplate"); json.removeValue(forKey: "answers")
        let old = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(old.answers == nil && old.summaryTemplate == nil && old.document.lines.count == 2)
        let invalidAI = LocalMeetingAI(responseGenerator: { _, _ in
            "{\"answer\":\"王明周一完成。\",\"citations\":[{\"id\":\"E1\",\"quote\":\"周一完成\"}]}"
        })
        let rejected = try await invalidAI.answer("什么时候完成？", record: record) { _ in }
        precondition(rejected.citations.isEmpty && rejected.answer.contains("未获得可核验"))
        let canceledAI = LocalMeetingAI(responseGenerator: { _, _ in
            try await Task.sleep(for: .seconds(30)); return "{}"
        })
        let operation = Task { try await canceledAI.answer("什么时候完成？", record: record) { _ in } }
        try await Task.sleep(for: .milliseconds(20)); operation.cancel()
        do { _ = try await operation.value; preconditionFailure("取消不能保存回答") } catch is CancellationError {}
        let brokenAI = LocalMeetingAI(responseGenerator: { _, _ in "坏 JSON" })
        do { _ = try await brokenAI.answer("什么时候完成？", record: record) { _ in }; preconditionFailure("异常响应必须报错") } catch {}
        print("PASS: 引用逐字校验、伪造和空引用拒绝、长尾覆盖、旧数据兼容、模板及问答重启保留、导出、原文变更提示")

        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16000)
        for (source, start) in [(AudioSource.system, 0.0), (.system, 3.0), (.microphone, 0.0)] {
            let segment = MeetingAudioSegment(source: source, start: start, fileName: UUID().uuidString + ".wav", duration: 1)
            try FileManager.default.createDirectory(at: store.audioDirectory(for: record), withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: store.audioURL(for: segment, in: record), settings: format.settings)
            try file.write(from: buffer)
            if record.audioSegments == nil { record.audioSegments = [] }; record.audioSegments!.append(segment)
        }
        let playback = MeetingPlayback(); playback.volume = 0
        playback.configure(record, store: store)
        precondition(playback.sources == [.system, .microphone] && playback.source == .system && playback.duration == 4)
        precondition(playback.seek(0.5) && playback.position == 0.5)
        precondition(!playback.seek(2) && !playback.isPlaying && playback.message.contains("没有"))
        precondition(playback.seek(3.2) && playback.position == 3.2)
        playback.selectSource(.microphone)
        precondition(playback.duration == 1 && playback.position == 0)
        playback.rate = 1.5; playback.play()
        precondition(playback.isPlaying)
        try await Task.sleep(for: .milliseconds(150))
        playback.pause(); precondition(!playback.isPlaying && playback.position > 0)
        playback.selectSource(.system); playback.seek(0.8); playback.play()
        try await Task.sleep(for: .milliseconds(500))
        precondition(playback.position >= 3 && playback.message.contains("跳过"))
        playback.reset(); precondition(!playback.isPlaying && playback.sources.isEmpty)
        var missing = record; missing.audioSegments = [MeetingAudioSegment(source: .system, start: 0, fileName: UUID().uuidString + ".wav", duration: 1)]
        playback.configure(missing, store: store)
        precondition(playback.sources.isEmpty && playback.message.contains("缺失"))
        print("PASS: 本地 WAV 实际播放、来源切换、时间定位、间隔不误播、自动衔接跳空档、倍速、停止复位、缺失音频提示")
    }
}
