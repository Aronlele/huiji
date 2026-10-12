import Foundation

enum AudioSource: String, CaseIterable, Identifiable, Codable, Equatable {
    case system = "电脑声音"
    case microphone = "我的麦克风"
    case imported = "录音文件"
    var id: String { rawValue }
}

struct TranscriptLine: Identifiable, Codable, Equatable {
    var id = UUID()
    let source: AudioSource
    let start: TimeInterval
    let end: TimeInterval
    var text: String
    let isFinal: Bool
    var isImportant: Bool?
    var originalText: String?
    var speakerID: String?
    var speakerManuallyAssigned: Bool?
    var tokens: [TranscriptToken]?
}

struct TranscriptToken: Codable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct MeetingSpeaker: Identifiable, Codable, Equatable {
    let id: String
    var name: String
}

struct SpeakerTurn: Codable, Equatable {
    let source: AudioSource
    let start: TimeInterval
    let end: TimeInterval
    let speakerID: String
}

struct TranscriptDocument: Codable, Equatable {
    var startedAt = Date()
    private(set) var lines: [TranscriptLine] = []
    private(set) var speakers: [MeetingSpeaker]?
    var speakerAnalysisAt: Date?

    mutating func update(source: AudioSource, start: TimeInterval, end: TimeInterval, text: String, isFinal: Bool, tokens: [TranscriptToken]? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let existing = lines.first { $0.source == source && abs($0.start - start) < 0.001 }
        lines.removeAll { line in
            guard line.source == source else { return false }
            let sameStart = abs(line.start - start) < 0.001
            return sameStart || (!line.isFinal && start < line.end && end > line.start)
        }
        lines.append(TranscriptLine(id: existing?.id ?? UUID(), source: source, start: start, end: end,
            text: existing?.originalText != nil ? existing!.text : text, isFinal: isFinal,
            isImportant: existing?.isImportant, originalText: existing?.originalText,
            speakerID: existing?.speakerID, speakerManuallyAssigned: existing?.speakerManuallyAssigned, tokens: tokens))
        lines.sort { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
    }

    mutating func edit(_ id: UUID, text: String) {
        guard let index = lines.firstIndex(where: { $0.id == id }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if lines[index].originalText == nil { lines[index].originalText = lines[index].text }
        lines[index].text = text
    }

    mutating func toggleImportant(_ id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].isImportant = !(lines[index].isImportant ?? false)
    }

    func speakerName(_ id: String?) -> String {
        guard let id else { return "未确定" }
        return speakers?.first(where: { $0.id == id })?.name ?? "未确定"
    }

    mutating func renameSpeaker(_ id: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = speakers?.firstIndex(where: { $0.id == id }) else { return }
        speakers![index].name = name
    }

    @discardableResult
    mutating func addSpeaker(name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let id = UUID().uuidString
        if speakers == nil { speakers = [] }
        speakers!.append(MeetingSpeaker(id: id, name: name))
        return id
    }

    mutating func assignSpeaker(_ id: UUID, speakerID: String?) {
        guard let index = lines.firstIndex(where: { $0.id == id }), lines[index].isFinal,
              speakerID == nil || speakers?.contains(where: { $0.id == speakerID }) == true else { return }
        lines[index].speakerID = speakerID
        lines[index].speakerManuallyAssigned = true
    }

    // Never change edited text or manual assignments when the automatic analysis is repeated.
    func reconciledSpeakerTurns(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var scores: [String: [String: Double]] = [:]
        for turn in turns {
            for line in lines where line.source == turn.source {
                guard let previous = line.speakerID else { continue }
                let overlap = min(turn.end, line.end) - max(turn.start, line.start)
                if overlap > 0 { scores[turn.speakerID, default: [:]][previous, default: 0] += overlap }
            }
        }
        let candidates = scores.flatMap { new, old in old.map { (new, $0.key, $0.value) } }.sorted { $0.2 > $1.2 }
        var mapping: [String: String] = [:]
        var used: Set<String> = []
        for (new, previous, _) in candidates where mapping[new] == nil && !used.contains(previous) {
            mapping[new] = previous; used.insert(previous)
        }
        return turns.map { SpeakerTurn(source: $0.source, start: $0.start, end: $0.end, speakerID: mapping[$0.speakerID] ?? $0.speakerID) }
    }

    mutating func applySpeakerTurns(_ turns: [SpeakerTurn]) {
        func punctuationOnly(_ text: String) -> Bool {
            !text.isEmpty && text.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }
        }
        let orderedIDs = turns.sorted { $0.start < $1.start }.map(\.speakerID).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        if speakers == nil { speakers = [] }
        for id in orderedIDs where !speakers!.contains(where: { $0.id == id }) {
            speakers!.append(MeetingSpeaker(id: id, name: "说话人 \(speakers!.count + 1)"))
        }
        func owner(source: AudioSource, start: Double, end: Double, minimumCoverage: Double = 0.45) -> String? {
            guard end > start else { return nil }
            var intervals: [String: [(Double, Double)]] = [:]
            for turn in turns where turn.source == source {
                let overlap = min(end, turn.end) - max(start, turn.start)
                if overlap > 0 { intervals[turn.speakerID, default: []].append((max(start, turn.start), min(end, turn.end))) }
            }
            // Padding can overlap two fragments of the same voice. Count the
            // union once so duplicated time cannot inflate confidence.
            let coverage = intervals.mapValues { ranges -> Double in
                var total = 0.0, previousEnd = -Double.infinity
                for (start, end) in ranges.sorted(by: { $0.0 < $1.0 }) {
                    total += max(0, end - max(start, previousEnd))
                    previousEnd = max(previousEnd, end)
                }
                return total
            }
            let ranked = coverage.sorted { $0.value > $1.value }
            guard let best = ranked.first, best.value >= (end - start) * minimumCoverage,
                  ranked.count < 2 || ranked[1].value < best.value * 0.6 else { return nil }
            return best.key
        }
        lines = lines.flatMap { line -> [TranscriptLine] in
            guard line.isFinal, line.speakerManuallyAssigned != true else { return [line] }
            guard line.originalText == nil, let tokens = line.tokens, !tokens.isEmpty,
                  tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == line.text else {
                var assigned = line
                assigned.speakerID = owner(source: line.source, start: line.start, end: line.end)
                return [assigned]
            }
            var groups: [TranscriptLine] = []
            var current: [TranscriptToken] = []
            var currentID: String?
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    groups.append(TranscriptLine(id: groups.isEmpty ? line.id : UUID(), source: line.source,
                        start: first.start, end: last.end, text: text, isFinal: true,
                        isImportant: line.isImportant, speakerID: currentID, tokens: current))
                }
                current = []
            }
            for token in tokens {
                var id = punctuationOnly(token.text) && !current.isEmpty ? currentID
                    : owner(source: line.source, start: token.start, end: token.end)
                // Compensate an early first syllable after silence only when
                // the following long phrase has clear ownership. Standalone
                // replies, nearby prior voices and conflicting coverage stay unknown.
                let futureEnd = min(line.end, token.end + 1.5)
                if id == nil, token.end - token.start <= 0.5, futureEnd - token.end >= 1.0,
                   let context = owner(source: line.source, start: token.end, end: futureEnd, minimumCoverage: 0.75),
                   context == owner(source: line.source, start: token.start, end: min(line.end, token.end + 0.4)),
                   !turns.contains(where: { $0.source == line.source && $0.start < token.start && $0.end > token.start - 0.5 }),
                   !turns.contains(where: { $0.source == line.source && $0.speakerID != context
                       && $0.start < token.end && $0.end > token.start }) { id = context }
                if !current.isEmpty && id != currentID { flush() }
                currentID = id
                current.append(token)
            }
            flush()
            return groups.isEmpty ? [line] : groups
        }
        var merged: [TranscriptLine] = []
        for line in lines {
            let previous = merged.last
            let sameVoice = previous?.speakerID != nil && previous?.speakerID == line.speakerID
                && previous?.speakerManuallyAssigned != true && line.speakerManuallyAssigned != true
                && previous?.tokens != nil && line.tokens != nil
                && line.start - (previous?.end ?? 0) <= 0.25
            if line.isFinal, (punctuationOnly(line.text) || sameVoice), line.speakerManuallyAssigned != true, line.originalText == nil,
               let previous, previous.source == line.source, previous.isFinal,
               previous.originalText == nil, line.start >= previous.start, line.start - previous.end < 1.5 {
                merged[merged.count - 1] = TranscriptLine(id: previous.id, source: previous.source,
                    start: previous.start, end: max(previous.end, line.end),
                    text: sameVoice ? ((previous.tokens ?? []) + (line.tokens ?? [])).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                        : previous.text + line.text, isFinal: true,
                    isImportant: previous.isImportant == true || line.isImportant == true,
                    speakerID: previous.speakerID, speakerManuallyAssigned: previous.speakerManuallyAssigned,
                    tokens: (previous.tokens ?? []) + (line.tokens ?? []))
            } else { merged.append(line) }
        }
        lines = merged
        speakerAnalysisAt = Date()
    }

    var subtitles: String {
        lines.filter(\.isFinal).enumerated().map { index, line in
            func stamp(_ seconds: Double) -> String {
                let ms = max(0, Int(seconds * 1000))
                return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
            }
            let name = line.speakerID != nil || speakerAnalysisAt != nil ? "\(speakerName(line.speakerID))：" : ""
            return "\(index + 1)\n\(stamp(line.start)) --> \(stamp(max(line.end, line.start + 0.1)))\n\(name)\(line.text)\n"
        }.joined(separator: "\n")
    }

    var plainText: String {
        let title = "会记 · 中文会议记录\n" + startedAt.formatted(date: .numeric, time: .standard) + "\n\n"
        return title + bodyText
    }

    var bodyText: String {
        lines.map { line in
            let seconds = max(0, Int(line.start))
            let timestamp = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            let speaker = line.speakerID != nil || speakerAnalysisAt != nil ? " · " + speakerName(line.speakerID) : ""
            return "[\(timestamp)] \(line.source.rawValue)\(speaker)\n\(line.text)\n"
        }.joined(separator: "\n")
    }

    func save(to url: URL) throws {
        try plainText.write(to: url, atomically: true, encoding: .utf8)
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    let seconds = max(0, Int(seconds))
    return seconds >= 3600 ? String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        : String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

enum MeetingError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}
