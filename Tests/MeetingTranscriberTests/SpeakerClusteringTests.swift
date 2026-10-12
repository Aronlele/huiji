import Foundation

@main struct SpeakerClusteringTests {
    static func main() throws {
        func segment(_ start: Double, _ duration: Double, _ vector: [Float], overlap: Bool = false) -> SpeakerEmbeddingSegment {
            SpeakerEmbeddingSegment(start: start, end: start + duration, vector: vector, overlap: overlap)
        }
        let fragments = [segment(0, 3, [1, 0]), segment(4, 3, [0.6, 0.8]),
                         segment(8, 3, [1, 0.1]), segment(12, 3, [0.59, 0.81]),
                         segment(16, 0.5, [1, 0]), segment(17, 0.4, [0.6, 0.8]),
                         segment(18, 0.5, [0.9, 0.45]), segment(20, 3, [1, 0], overlap: true)]
        let ids = try SpeakerClustering.assign(fragments, speakerCount: 0)
        precondition(ids[0] == ids[2] && ids[1] == ids[3] && ids[0] != ids[1])
        precondition(ids[4] == ids[0] && ids[5] == ids[1] && ids[6] == nil && ids[7] == nil)
        let single = try SpeakerClustering.assign(fragments, speakerCount: 1)
        precondition(Set(single.compactMap { $0 }).count == 1 && single[7] == nil)
        let silence = try SpeakerClustering.assign([segment(0, 2, [0, 0]), segment(3, 2, [.nan, 1])], speakerCount: 0)
        precondition(silence.allSatisfy { $0 == nil })
        let short = try SpeakerClustering.assign([segment(0, 0.3, [1, 0])], speakerCount: 0)
        precondition(short == [nil])
        func native(_ start: Double, _ duration: Double, _ vector: [Float], _ label: Int, overlap: Bool = false) -> SpeakerEmbeddingSegment {
            var value = segment(start, duration, vector, overlap: overlap)
            value.nativeSpeaker = label
            return value
        }
        let context = [native(0, 2, [1, 0], 0), native(3, 2, [0, 1], 1),
                       native(6, 0.12, [], 0), native(7, 0.036, [], 0),
                       native(8, 0.4, [0.7, 0.7], 0), native(9, 0.4, [], 0, overlap: true),
                       native(10, 0.3, [.nan, 1], 0)]
        let contextual = try SpeakerClustering.assign(context, speakerCount: 0)
        precondition(contextual[2] == contextual[0])
        precondition(contextual[3...6].allSatisfy { $0 == nil })
        let inconsistent = try SpeakerClustering.assign([native(0, 2, [1, 0], 0),
            native(3, 2, [0, 1], 0), native(6, 0.12, [], 0)], speakerCount: 0)
        precondition(inconsistent[2] == nil, "conflicting native labels cannot guess a short speaker")
        var duplicate = native(10, 0.4, [], -1, overlap: true)
        duplicate.nativeSpeakers = [0, 2]
        var realOverlap = duplicate; realOverlap.nativeSpeakers = [0, 1]
        var incomplete = duplicate; incomplete.nativeSpeakers = [0, 3]
        let duplicateLabels = [native(0, 2, [1, 0], 0), native(3, 2, [0, 1], 1),
                               native(6, 2, [1, 0.1], 2), duplicate, realOverlap, incomplete]
        let resolved = try SpeakerClustering.assign(duplicateLabels, speakerCount: 0)
        precondition(resolved[3] == resolved[0] && resolved[4] == nil && resolved[5] == nil)
        let forcedSingle = try SpeakerClustering.assign(duplicateLabels, speakerCount: 1)
        precondition(forcedSingle[3] == nil)
        let supportedVoices = [native(0, 2, [1, 0], 0), native(3, 2, [1, 0.05], 0),
                               native(6, 2, [0.6, 0.8], 1), native(9, 2, [0.59, 0.81], 1),
                               native(12, 1.4, [0.65, -0.76], 2), native(15, 1.4, [-1, 0], 3)]
        let enrolled = try SpeakerClustering.assign(supportedVoices, speakerCount: 0)
        precondition(enrolled[0] != enrolled[2], "supported similar voices must remain distinct")
        precondition(enrolled[4] == enrolled[0] && enrolled[5] == nil,
                     "isolated outliers must match confidently or stay unknown, not multiply identities")
        do { _ = try SpeakerClustering.assign([], speakerCount: -1); preconditionFailure("invalid count accepted") } catch {}

        // Compare the cached nearest-neighbor implementation with independent
        // exhaustive average-link clustering on deterministic random inputs.
        var state: UInt64 = 71
        func random() -> Float {
            state = state &* 6364136223846793005 &+ 1
            return Float((state >> 33) % 10000) / 10000 - 0.5
        }
        for count in [0, 1, 2, 4, 12] {
            for _ in 0..<8 {
                let sample = (0..<24).map { segment(Double($0 * 4), 3, (0..<8).map { _ in random() }) }
                let actual = try SpeakerClustering.assign(sample, speakerCount: count)
                let normalized = sample.map { s -> [Float] in
                    let norm = sqrt(s.vector.reduce(0.0) { $0 + Double($1) * Double($1) })
                    return s.vector.map { Float(Double($0) / norm) }
                }
                var groups = sample.indices.map { [$0] }
                func score(_ a: [Int], _ b: [Int]) -> Float {
                    var sum: Float = 0
                    for i in a { for j in b { sum += zip(normalized[i], normalized[j]).reduce(0) { $0 + $1.0 * $1.1 } } }
                    return sum / Float(a.count * b.count)
                }
                while groups.count > 1 {
                    var best: Float = -2, a = 0, b = 1
                    for i in groups.indices { for j in groups.indices where j < i {
                        let s = score(groups[i], groups[j]); if s > best { best = s; a = i; b = j }
                    } }
                    if count > 0 ? groups.count <= count : best < 0.65 { break }
                    groups[b] += groups.remove(at: a)
                }
                for group in groups {
                    precondition(Set(group.map { actual[$0] }).count == 1)
                }
                precondition(Set(actual.compactMap { $0 }).count == groups.count)
            }
        }
        print("PASS: 相近声音分组、短句匹配、模糊短句及重叠未确定、静音异常向量、人数校验；40组与独立穷举算法一致")
    }
}
