import Foundation

struct SuggestedTask: Codable, Identifiable {
    var id: String { [text, owner, due].joined(separator: "\u{1f}") }
    let text: String
    let owner: String
    let due: String
    let evidence: String
}


struct MeetingTask: Identifiable, Codable {
    var id = UUID()
    var text: String
    var owner = ""
    var due = ""
    var done = false
}

struct MeetingAudioSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    let source: AudioSource
    let start: TimeInterval
    let fileName: String
    var duration: TimeInterval = 0
}

struct MeetingRecord: Identifiable, Codable {
    var id = UUID()
    var title: String
    var document = TranscriptDocument()
    var elapsed: TimeInterval = 0
    var updatedAt = Date()
    var textFileName: String
    var legacyText: String?
    var folder: String?
    var isFavorite: Bool?
    var deletedAt: Date?
    var notes: String?
    var tasks: [MeetingTask]?
    var summary: String?
    var summaryGeneratedAt: Date?
    var suggestedTasks: [SuggestedTask]?
    var audioSegments: [MeetingAudioSegment]?
    var speakerCountHint: Int?
    var summaryTemplate: SummaryTemplate?
    var summaryGeneratedTemplate: SummaryTemplate?
    var answers: [MeetingAnswer]?

    var transcriptText: String {
        if let legacyText { return document.lines.isEmpty ? legacyText : legacyText + "\n\n" + document.bodyText }
        return document.plainText
    }

    var searchableText: String { [title, folder ?? "", transcriptText, notes ?? "", summary ?? "", (tasks ?? []).map { [$0.text, $0.owner, $0.due].joined(separator: " ") }.joined(separator: " ")].joined(separator: "\n") }
    var hasContent: Bool { !document.lines.isEmpty || !(legacyText ?? "").isEmpty }

    var plainText: String {
        let base = legacyText != nil ? transcriptText : "会议：\(title)\n" + transcriptText
        var sections = [base]
        if let summary, !summary.isEmpty { sections.append("纪要（AI 生成，请校对）\n" + summary) }
        if let notes, !notes.isEmpty { sections.append("会议笔记\n" + notes) }
        if let tasks, !tasks.isEmpty {
            sections.append("待办事项\n" + tasks.map { "[\($0.done ? "x" : " ")] \($0.text)\($0.owner.isEmpty ? "" : " · 负责人：" + $0.owner)\($0.due.isEmpty ? "" : " · 截止：" + $0.due)" }.joined(separator: "\n"))
        }
        if !(answers ?? []).isEmpty { sections.append("会议问答（AI 生成，请校对）\n" + questionExport) }
        return sections.joined(separator: "\n\n")
    }

    var markdown: String {
        var sections = ["# " + title, document.startedAt.formatted(date: .long, time: .shortened)]
        if let summary, !summary.isEmpty { sections.append("## 会议纪要\n\n> AI 生成，请与原文校对。\n\n" + summary) }
        if let notes, !notes.isEmpty { sections.append("## 笔记\n\n" + notes) }
        if let tasks, !tasks.isEmpty { sections.append("## 待办\n\n" + tasks.map { "- [\($0.done ? "x" : " ")] \($0.text)\($0.owner.isEmpty ? "" : " · " + $0.owner)\($0.due.isEmpty ? "" : " · " + $0.due)" }.joined(separator: "\n")) }
        if !(answers ?? []).isEmpty { sections.append("## 会议问答\n\n> AI 生成，请校对引用依据。\n\n" + questionExport) }
        sections.append("## 原始转写\n\n" + transcriptText)
        return sections.joined(separator: "\n\n")
    }
}

struct MeetingStore {
    let directory: URL

    func load() throws -> [MeetingRecord] {
        try loadReportingProblems().records
    }

    func loadReportingProblems() throws -> (records: [MeetingRecord], warnings: [String]) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var warnings: [String] = []
        var records: [MeetingRecord] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            do {
                var record = try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: url))
                if record.legacyText != nil, let date = originalDate(from: record.textFileName) {
                    record.document.startedAt = date
                    if record.title.hasPrefix("历史会议 · ") {
                        record.title = "历史会议 · " + date.formatted(date: .abbreviated, time: .shortened)
                    }
                }
                return record
            }
            catch {
                warnings.append("无法读取会议 \(url.lastPathComponent)。原文件已保留，其他会议可继续使用。")
                return nil
            }
        }
        let imported = Set(records.map(\.textFileName))
        for file in files where file.pathExtension == "txt" && !imported.contains(file.lastPathComponent) {
            // A damaged JSON must not be silently replaced by a new import of its companion TXT.
            if !warnings.isEmpty { continue }
            let text: String
            do { text = try String(contentsOf: file, encoding: .utf8) }
            catch { warnings.append("无法导入 \(file.lastPathComponent)，原文件已保留。"); continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let date = originalDate(from: file.lastPathComponent) ?? attributes[.creationDate] as? Date ?? Date()
            var record = MeetingRecord(title: "历史会议 · " + date.formatted(date: .abbreviated, time: .shortened),
                                       textFileName: file.lastPathComponent, legacyText: text)
            record.document.startedAt = date
            record.updatedAt = attributes[.modificationDate] as? Date ?? date
            // Continue imported meetings after the last timestamp; retain their original text verbatim.
            let pattern = #"(?m)^\[(\d+):(\d{2}):(\d{2})\] "#
            let matches = try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                let values = (1...3).map { Int((text as NSString).substring(with: match.range(at: $0))) ?? 0 }
                record.elapsed = max(record.elapsed, Double(values[0] * 3600 + values[1] * 60 + values[2]) + 1)
            }
            try save(record)
            records.append(record)
        }
        return (records.sorted { $0.updatedAt > $1.updatedAt }, warnings)
    }

    func save(_ record: MeetingRecord) throws {
        try validateFileName(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonURL = directory.appendingPathComponent(record.id.uuidString + ".json")
        try JSONEncoder().encode(record).write(to: jsonURL, options: .atomic)
        try record.plainText.write(to: textURL(for: record), atomically: true, encoding: .utf8)
    }

    func textURL(for record: MeetingRecord) -> URL {
        directory.appendingPathComponent(record.textFileName)
    }

    func permanentlyDelete(_ record: MeetingRecord) throws {
        try validateFileName(record)
        guard record.deletedAt != nil else { throw MeetingError.message("请先将会议移入最近删除。") }
        let audio = audioDirectory(for: record)
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        let text = textURL(for: record)
        if FileManager.default.fileExists(atPath: text.path) { try FileManager.default.removeItem(at: text) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(record.id.uuidString + ".json"))
    }

    func audioDirectory(for record: MeetingRecord) -> URL {
        directory.appendingPathComponent("Audio", isDirectory: true).appendingPathComponent(record.id.uuidString, isDirectory: true)
    }

    func audioURL(for segment: MeetingAudioSegment, in record: MeetingRecord) throws -> URL {
        guard UUID(uuidString: URL(fileURLWithPath: segment.fileName).deletingPathExtension().lastPathComponent) != nil,
              segment.fileName.hasSuffix(".wav"), !segment.fileName.contains("/"), !segment.fileName.contains("\\") else {
            throw MeetingError.message("会议音频文件名无效。")
        }
        return audioDirectory(for: record).appendingPathComponent(segment.fileName)
    }

    private func validateFileName(_ record: MeetingRecord) throws {
        guard !record.textFileName.isEmpty, !record.textFileName.contains("/"),
            record.textFileName != ".", record.textFileName != "..", record.textFileName.hasSuffix(".txt") else {
            throw MeetingError.message("记录文件名无效，原文件已保留。")
        }
    }

    private func originalDate(from fileName: String) -> Date? {
        let parts = fileName.components(separatedBy: "_")
        guard parts.count >= 3, parts[0] == "会议" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: parts[1] + "_" + parts[2])
    }
}
