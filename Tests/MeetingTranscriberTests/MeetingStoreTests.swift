import Foundation

@main
struct MeetingStoreTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(directory: directory)
        let empty = try store.load()
        precondition(empty.isEmpty)
        var meeting = MeetingRecord(title: "项目周会", textFileName: "项目周会.txt")
        meeting.document.update(source: .system, start: 0, end: 4, text: "中文和 Zoom API 都会保留。", isFinal: true)
        meeting.elapsed = 5
        meeting.notes = "会前议程"
        meeting.tasks = [MeetingTask(text: "接口验收", owner: "王明", due: "周五")]
        meeting.summary = "测试纪要"
        meeting.suggestedTasks = [SuggestedTask(text: "校对中文", owner: "", due: "", evidence: "中文和 Zoom API 都会保留。")]

        try store.save(meeting)
        let loaded = try store.load()
        precondition(loaded.count == 1 && loaded[0].title == "项目周会" && loaded[0].elapsed == 5)
        precondition(loaded[0].notes == "会前议程" && loaded[0].tasks?.first?.owner == "王明")
        precondition(loaded[0].suggestedTasks?.first?.text == "校对中文")
        precondition(loaded[0].summary == "测试纪要")
        precondition(loaded[0].document.lines[0].id == meeting.document.lines[0].id)
        precondition(loaded[0].document.lines[0].text == "中文和 Zoom API 都会保留。")
        let original = "会记 · 中文会议记录\n原始日期\n\n[00:02:30] 电脑声音\n历史中文会议原文。\n"
        let oldURL = directory.appendingPathComponent("会议_2026-10-12_16-13-43_ABCD.txt")
        try original.write(to: oldURL, atomically: true, encoding: .utf8)
        let migrated = try store.load()
        precondition(migrated.count == 2)
        let legacy = migrated.first { $0.textFileName == oldURL.lastPathComponent }!
        precondition(legacy.legacyText == original && legacy.elapsed == 151)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        precondition(formatter.string(from: legacy.document.startedAt) == "2026-10-12_16-13-43")
        let preserved = try String(contentsOf: oldURL, encoding: .utf8)
        precondition(preserved == original)
        let loadedAgain = try store.load()
        precondition(loadedAgain.count == 2)
        var continued = legacy
        continued.document.update(source: .microphone, start: 152, end: 156, text: "继续追加的记录。", isFinal: true)
        try store.save(continued)
        let appended = try String(contentsOf: oldURL, encoding: .utf8)
        precondition(appended.hasPrefix(original) && appended.contains("继续追加的记录。"))
        let afterAppend = try store.load()
        precondition(afterAppend.count == 2)
        let corrupted = directory.appendingPathComponent("bad.json")
        let broken = Data("不是 JSON".utf8)
        try broken.write(to: corrupted)
        let isolated = try store.loadReportingProblems()
        precondition(isolated.records.count == 2 && isolated.warnings.count == 1)
        let preservedBroken = try Data(contentsOf: corrupted)
        let preservedAppend = try String(contentsOf: oldURL, encoding: .utf8)
        precondition(preservedBroken == broken)
        precondition(preservedAppend == appended)
        do { try store.permanentlyDelete(meeting); preconditionFailure("未移入最近删除不能永久删除") } catch {}
        meeting.deletedAt = Date(); try store.save(meeting)
        let trashed = try store.loadReportingProblems()
        precondition(trashed.records.first { $0.id == meeting.id }?.deletedAt != nil)
        try store.permanentlyDelete(meeting)
        precondition(!FileManager.default.fileExists(atPath: store.textURL(for: meeting).path))
        let deleted = try store.loadReportingProblems()
        precondition(!deleted.records.contains { $0.id == meeting.id })
        print("PASS: 删除防误操作、永久删除移除两份文件、重启不复活")
        print("PASS: 会议结构持久化、中文与条目身份保留、旧文本无损导入且不重复、追加历史记录、损坏文件保留")
    }
}
