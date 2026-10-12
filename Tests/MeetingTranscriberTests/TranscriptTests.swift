import Foundation

@main
struct TranscriptTests {
    static func main() throws {
        try testChineseAndTechnicalWordsSurviveUTF8Export()
        testPartialResultsAreReplacedAndFinalNotDuplicated()
        testChannelsStaySeparateAndOrderedByAudioTime()
        var edited = TranscriptDocument()
        edited.update(source: .system, start: 65.123, end: 67.5, text: "原来的文字", isFinal: true)
        let id = edited.lines[0].id
        edited.toggleImportant(id); edited.edit(id, text: "校对后的文字")
        edited.update(source: .system, start: 65.123, end: 67.5, text: "重复识别回调", isFinal: true)
        precondition(edited.lines[0].id == id && edited.lines[0].isImportant == true)
        precondition(edited.lines[0].text == "校对后的文字" && edited.lines[0].originalText == "原来的文字")
        let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(edited))
        precondition(decoded == edited)
        precondition(edited.subtitles.contains("00:01:05,123 --> 00:01:07,500"))
        print("PASS: 校对保留原文、星标和身份不被重复回调覆盖、结构化字幕时间戳")
        print("PASS: 中文 UTF-8 保存、临时结果替换、重复结果去重、双路时间排序")
    }

    static func testChineseAndTechnicalWordsSurviveUTF8Export() throws {
        var document = TranscriptDocument()
        document.update(source: .system, start: 0, end: 4, text: "我们讨论 Zoom 和 API 接口。中文不会被删除。", isFinal: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.save(to: url)
        let saved = try String(contentsOf: url, encoding: .utf8)
        precondition(saved.contains("我们讨论 Zoom 和 API 接口。中文不会被删除。"))
    }

    static func testPartialResultsAreReplacedAndFinalNotDuplicated() {
        var document = TranscriptDocument()
        document.update(source: .system, start: 0, end: 2, text: "我们开始", isFinal: false)
        document.update(source: .system, start: 0, end: 4, text: "我们开始会议。", isFinal: true)
        document.update(source: .system, start: 0, end: 4, text: "我们开始会议。", isFinal: true)
        precondition(document.lines.count == 1)
        precondition(document.lines[0].isFinal)
    }

    static func testChannelsStaySeparateAndOrderedByAudioTime() {
        var document = TranscriptDocument()
        document.update(source: .system, start: 2, end: 3, text: "对方的声音", isFinal: true)
        document.update(source: .microphone, start: 0, end: 3, text: "我的声音", isFinal: true)
        document.update(source: .system, start: 4, end: 5, text: "下一句话", isFinal: true)
        precondition(document.lines.map(\.text) == ["我的声音", "对方的声音", "下一句话"])
        precondition(document.plainText.contains("我的麦克风"))
        precondition(document.plainText.contains("电脑声音"))
    }
}
