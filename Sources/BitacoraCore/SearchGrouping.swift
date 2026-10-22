import Foundation

/// Search results collapsed by moment: frames of the same window, close in time and with
/// mostly the same text (scrolling a chat, clicking around one page) become a single result.
public struct SearchGroup: Codable, Sendable {
    /// The best-ranked frame of the group, with the highlighted excerpt.
    public let frame: FrameRecord
    public let frameCount: Int
    public let firstCapturedAt: Date
    public let lastCapturedAt: Date
    public let frameIds: [Int64]
}

public enum ResultGrouper {
    /// Longest pause between two frames of the same group.
    static let maxGap: TimeInterval = 300
    /// Minimum share of words two consecutive frames must have in common (Jaccard index).
    static let minSimilarity = 0.5

    private struct Candidate {
        let record: FrameRecord
        let words: Set<String>
        let rank: Int
        var window: String { "\(record.appName ?? record.bundleID ?? "")|\(record.windowTitle ?? "")" }
    }

    /// Groups `rows` (already in rank order) and returns at most `limit` groups, ordered by
    /// the rank of their best frame.
    public static func group(_ rows: [(record: FrameRecord, fullText: String)], limit: Int) -> [SearchGroup] {
        let candidates = rows.enumerated().map { index, row in
            Candidate(record: row.record, words: words(in: row.fullText), rank: index)
        }
        let chronological = candidates.sorted { a, b in
            a.window != b.window ? a.window < b.window : a.record.capturedAt < b.record.capturedAt
        }

        var groups: [[Candidate]] = []
        for candidate in chronological {
            if let previous = groups.last?.last,
               previous.window == candidate.window,
               candidate.record.capturedAt.timeIntervalSince(previous.record.capturedAt) <= maxGap,
               similarity(previous.words, candidate.words) >= minSimilarity {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        return groups
            .map { members -> (rank: Int, group: SearchGroup) in
                let best = members.min { $0.rank < $1.rank }!
                return (best.rank, SearchGroup(
                    frame: best.record,
                    frameCount: members.count,
                    firstCapturedAt: members.first!.record.capturedAt,
                    lastCapturedAt: members.last!.record.capturedAt,
                    frameIds: members.map(\.record.id).sorted()
                ))
            }
            .sorted { $0.rank < $1.rank }
            .prefix(limit)
            .map(\.group)
    }

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Jaccard index: shared words over all words. Two frames without text count as identical.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
