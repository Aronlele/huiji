import Foundation
import CryptoKit

enum SummaryTemplate: String, Codable, CaseIterable, Identifiable {
    case work, review, interview, classroom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .work: return "工作会议"
        case .review: return "项目评审"
        case .interview: return "访谈沟通"
        case .classroom: return "课堂笔记"
        }
    }
    var guidance: String {
        switch self {
        case .work: return "按‘议题与进展、已确认结论、未决问题’分节，突出进展、阻碍与后续行动。"
        case .review: return "按‘评审目标、方案与取舍、风险与未决问题’分节，明确区分提议和已经通过的方案。"
        case .interview: return "按‘访谈主题、受访者观点、待澄清问题’分节，保留观点的发言人归属，区分提问与回答。"
        case .classroom: return "按‘主题、核心概念、示例与疑问’分节，整理材料中讲到的知识，不添加课外知识或虚构作业。"
        }
    }
}

struct MeetingEvidence: Identifiable {
    let id: String
    let lineID: UUID?
    let text: String
    let start: TimeInterval?
    let source: AudioSource?
    let speaker: String
}

struct MeetingCitation: Codable, Identifiable {
    var id: String { (lineID?.uuidString ?? "material") + quote }
    let lineID: UUID?
    let quote: String
    let start: TimeInterval?
    let source: AudioSource?
    let speaker: String
}

struct MeetingAnswer: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let question: String
    let answer: String
    let citations: [MeetingCitation]
    let sourceFingerprint: String
}

extension MeetingRecord {
    var evidence: [MeetingEvidence] {
        var result = document.lines.filter { $0.isFinal && !$0.text.isEmpty }.map {
            MeetingEvidence(id: $0.id.uuidString, lineID: $0.id, text: $0.text, start: $0.start,
                            source: $0.source, speaker: document.speakerName($0.speakerID))
        }
        if let legacyText, !legacyText.isEmpty {
            result.insert(MeetingEvidence(id: "legacy", lineID: nil, text: legacyText, start: nil, source: nil, speaker: "历史原文"), at: 0)
        }
        if let notes, !notes.isEmpty {
            result.append(MeetingEvidence(id: "notes", lineID: nil, text: notes, start: nil, source: nil, speaker: "会议笔记"))
        }
        return result
    }
    var evidenceFingerprint: String {
        let text = evidence.map { [$0.id, $0.text, String($0.start ?? -1), $0.source?.rawValue ?? "", $0.speaker].joined(separator: "\u{1f}") }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func citationSpeaker(_ citation: MeetingCitation) -> String {
        if let id = citation.lineID, let line = document.lines.first(where: { $0.id == id && $0.text.contains(citation.quote) })
            ?? document.lines.first(where: { $0.source == citation.source && $0.text.contains(citation.quote) }) { return document.speakerName(line.speakerID) }
        return citation.speaker
    }
    var questionExport: String {
        (answers ?? []).map { answer in
            var text = "问：" + answer.question + "\n答：" + answer.answer
            if answer.sourceFingerprint != evidenceFingerprint { text += "\n提示：生成后原文或笔记已变更，请重新核对。" }
            for citation in answer.citations {
                let time = citation.start.map { durationText($0) + " · " } ?? ""
                text += "\n依据：" + time + citationSpeaker(citation) + " · " + citation.quote
            }
            return text
        }.joined(separator: "\n\n")
    }
}
