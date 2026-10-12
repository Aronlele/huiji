import Foundation
import Accelerate

struct SpeakerEmbeddingSegment: Codable {
    let start: Double
    let end: Double
    let vector: [Float]
    let overlap: Bool?
    var nativeSpeaker: Int? = nil
    var nativeSpeakers: [Int]? = nil
}

// Average-link clustering uses complete speech fragments instead of masked
// embeddings from adjacent voices. Short fragments do not create new identities.
enum SpeakerClustering {
    static func assign(_ segments: [SpeakerEmbeddingSegment], speakerCount: Int) throws -> [Int?] {
        guard (0...12).contains(speakerCount) else { throw MeetingError.message("发言人数无效，请重新选择。") }
        let dimension = segments.first(where: { !$0.vector.isEmpty })?.vector.count ?? 0
        let vectors: [[Float]?] = segments.map { segment in
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start,
                  segment.overlap != true, dimension > 0, segment.vector.count == dimension,
                  segment.vector.allSatisfy(\.isFinite) else { return nil }
            let norm = sqrt(segment.vector.reduce(0.0) { $0 + Double($1) * Double($1) })
            return norm > 0 ? segment.vector.map { Float(Double($0) / norm) } : nil
        }
        var seeds = segments.indices.filter { vectors[$0] != nil && segments[$0].nativeSpeaker != -1 && segments[$0].end - segments[$0].start >= 1.3 }
        if seeds.isEmpty { seeds = segments.indices.filter { vectors[$0] != nil && segments[$0].nativeSpeaker != -1 && segments[$0].end - segments[$0].start >= 0.8 } }
        let n = seeds.count
        guard n <= 8192 else { throw MeetingError.message("录音中的发言片段过多，请分段导入后分析。原音频与转写已保留。") }
        guard n > 0 else { return Array(repeating: nil, count: segments.count) }
        func cosine(_ a: Int, _ b: Int) -> Float {
            var score: Float = 0
            vDSP_dotpr(vectors[a]!, 1, vectors[b]!, 1, &score, vDSP_Length(dimension))
            return score
        }
        var similarities = [Float](repeating: -2, count: n * n)
        for i in 0..<n {
            if i % 32 == 0 { try Task.checkCancellation() }
            for j in 0..<i {
            let score = cosine(seeds[i], seeds[j])
            similarities[i * n + j] = score; similarities[j * n + i] = score
            }
        }
        var groups = seeds.map { [$0] }
        var nearest = [Int](repeating: -1, count: n)
        func bestNeighbor(_ i: Int) -> Int {
            var best = -1
            for j in 0..<n where j != i && !groups[j].isEmpty {
                if best < 0 || similarities[i * n + j] > similarities[i * n + best] { best = j }
            }
            return best
        }
        for i in 0..<n { nearest[i] = bestNeighbor(i) }
        var remaining = n
        while remaining > 1 {
            try Task.checkCancellation()
            var a = -1, b = -1, best: Float = -2
            for i in 0..<n where !groups[i].isEmpty && nearest[i] >= 0 {
                let j = nearest[i], score = similarities[i * n + j]
                if score > best { a = i; b = j; best = score }
            }
            guard a >= 0, b >= 0 else { break }
            if speakerCount > 0 ? remaining <= speakerCount : best < 0.65 { break }
            let countA = Float(groups[a].count), countB = Float(groups[b].count)
            for k in 0..<n where k != a && k != b && !groups[k].isEmpty {
                let score = (similarities[a * n + k] * countA + similarities[b * n + k] * countB) / (countA + countB)
                similarities[a * n + k] = score; similarities[k * n + a] = score
            }
            groups[a] += groups[b]; groups[b] = []; nearest[b] = -1; remaining -= 1
            nearest[a] = bestNeighbor(a)
            for k in 0..<n where k != a && !groups[k].isEmpty {
                if nearest[k] == a || nearest[k] == b { nearest[k] = bestNeighbor(k) }
                else if similarities[k * n + a] > similarities[k * n + nearest[k]] { nearest[k] = a }
            }
        }
        var clusters = groups.filter { !$0.isEmpty }.sorted { $0.min()! < $1.min()! }
        if speakerCount == 0, seeds.contains(where: { (segments[$0].nativeSpeaker ?? -1) >= 0 }) {
            // A lone, brief enrollment is often an intonation/noise outlier.
            // Keep repeated or sustained voices; match the remaining fragments
            // using the same confidence checks, rather than counting each one
            // as a new participant. If none has support, keep the original set.
            let supported = clusters.filter { group in
                group.count >= 2 || group.reduce(0.0) { $0 + segments[$1].end - segments[$1].start } >= 5
            }
            if !supported.isEmpty { clusters = supported }
        }
        var result = [Int?](repeating: nil, count: segments.count)
        for (id, group) in clusters.enumerated() { for i in group { result[i] = id } }
        let centers = clusters.map { group -> [Float] in
            var center = [Float](repeating: 0, count: dimension)
            for i in group { for d in 0..<dimension { center[d] += vectors[i]![d] } }
            let norm = sqrt(center.reduce(0.0) { $0 + Double($1) * Double($1) })
            return norm > 0 ? center.map { Float(Double($0) / norm) } : center
        }
        // Native labels are context hints, not final identities. Learn their
        // mapping only from independently clustered, sufficiently long speech.
        var votes: [Int: [Int: Double]] = [:]
        for i in seeds {
            if let native = segments[i].nativeSpeaker, native >= 0, let id = result[i] {
                votes[native, default: [:]][id, default: 0] += min(3, segments[i].end - segments[i].start)
            }
        }
        let hints = votes.compactMapValues { weights -> Int? in
            let total = weights.values.reduce(0, +)
            guard let best = weights.max(by: { $0.value < $1.value }), total >= 1.3,
                  best.value / total >= 0.85 else { return nil }
            return best.key
        }
        for i in segments.indices where result[i] == nil {
            let duration = segments[i].end - segments[i].start
            guard duration.isFinite, duration >= 0.1 else { continue }
            if segments[i].overlap == true {
                // Several native labels can be fragments of one physical voice.
                // Resolve only unanimous, independently enrolled mappings; true
                // multi-person overlap and missing evidence stay unknown.
                if speakerCount != 1, let labels = segments[i].nativeSpeakers, labels.count >= 2 {
                    let owners = labels.compactMap { hints[$0] }
                    if owners.count == labels.count && Set(owners).count == 1 { result[i] = owners[0] }
                }
                continue
            }
            let hint = segments[i].nativeSpeaker.flatMap { hints[$0] }
            if vectors[i] == nil {
                if segments[i].vector.isEmpty, duration < 1.3 { result[i] = hint }
                continue
            }
            let scores = centers.enumerated().map { id, center -> (Int, Float) in
                var score: Float = 0
                vDSP_dotpr(vectors[i]!, 1, center, 1, &score, vDSP_Length(dimension))
                return (id, score)
            }.sorted { $0.1 > $1.1 }
            guard let best = scores.first else { continue }
            let margin = scores.count == 1 ? Float(2) : best.1 - scores[1].1
            if best.1 >= 0.45 && margin >= 0.08 {
                result[i] = best.0
            } else if duration < 1.3, best.0 == hint, best.1 >= 0.35, margin >= 0.04 {
                result[i] = best.0
            }
        }
        return result
    }
}
