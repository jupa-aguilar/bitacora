import Foundation

/// One stored frame, as the activity summary sees it.
public struct ActivitySample: Sendable, Equatable {
    public var capturedAt: Date
    public var app: String
    public var title: String

    /// `text` stands in for a missing window title: its first line is usually the page or document
    /// title (web apps such as YouTube expose no window title).
    public init(capturedAt: Date, app: String?, title: String?, text: String? = nil) {
        self.capturedAt = capturedAt
        self.app = app ?? "app desconocida"
        let firstLine = text?.split(separator: "\n").first.map { String($0.prefix(100)) }
        let named = title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.title = ActivitySummary.normalizedTitle(named ?? firstLine, app: self.app)
    }
}

/// A stretch of time in one app and window.
public struct ActivityBlock: Sendable, Equatable {
    public var app: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Time actually spent; less than `end - start` when the block swallowed short interruptions.
    public var duration: TimeInterval

    public init(app: String, title: String, start: Date, end: Date, duration: TimeInterval) {
        self.app = app
        self.title = title
        self.start = start
        self.end = end
        self.duration = duration
    }
}

public struct ActivityTotal: Sendable, Equatable {
    public var app: String
    /// Empty for per-app totals.
    public var title: String
    public var duration: TimeInterval
}

/// Approximate time spent per app and window during a period, from the stored frames.
///
/// Frames are only stored when something happens, so each one counts until the next one, but at
/// most `maxGap`: a longer silence is taken as the user being away (or the screen locked).
public struct ActivitySummary: Sendable {
    public static let defaultMaxGap: TimeInterval = 600

    public let from: Date
    public let to: Date
    public let maxGap: TimeInterval
    /// Consecutive frames of the same app and window, split where the user was away.
    public let blocks: [ActivityBlock]

    public init(samples: [ActivitySample], from: Date, to: Date, maxGap: TimeInterval = defaultMaxGap) {
        self.from = from
        self.to = to
        self.maxGap = maxGap
        let ordered = samples.sorted { $0.capturedAt < $1.capturedAt }
        var blocks: [ActivityBlock] = []
        var awayBefore = true
        for (index, sample) in ordered.enumerated() {
            let next = index + 1 < ordered.count ? ordered[index + 1].capturedAt : to
            let start = max(sample.capturedAt, from)
            let end = min(next, sample.capturedAt.addingTimeInterval(maxGap), to)
            let away = next.timeIntervalSince(sample.capturedAt) > maxGap
            defer { awayBefore = away }
            guard end > start else { continue }
            if !awayBefore, var last = blocks.last, last.app == sample.app, last.title == sample.title {
                last.end = end
                last.duration += end.timeIntervalSince(start)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(ActivityBlock(app: sample.app, title: sample.title, start: start, end: end,
                                            duration: end.timeIntervalSince(start)))
            }
        }
        self.blocks = blocks
    }

    public var total: TimeInterval { blocks.reduce(0) { $0 + $1.duration } }

    public var perApp: [ActivityTotal] {
        totals(blocks) { ActivityTotal(app: $0.app, title: "", duration: 0) }
    }

    public var perWindow: [ActivityTotal] {
        totals(blocks) { ActivityTotal(app: $0.app, title: $0.title, duration: 0) }
    }

    /// Blocks of at least `minDuration`, with neighbours of the same window joined when what
    /// separated them was shorter (a quick look at another app) and the user was not away.
    public func timeline(minDuration: TimeInterval) -> [ActivityBlock] {
        var result: [ActivityBlock] = []
        for block in blocks where block.duration >= minDuration {
            if var last = result.last, last.app == block.app, last.title == block.title,
               block.start.timeIntervalSince(last.end) <= maxGap {
                last.end = block.end
                last.duration += block.duration
                result[result.count - 1] = last
            } else {
                result.append(block)
            }
        }
        return result
    }

    private func totals(_ blocks: [ActivityBlock], key: (ActivityBlock) -> ActivityTotal) -> [ActivityTotal] {
        var order: [String] = []
        var byKey: [String: ActivityTotal] = [:]
        for block in blocks {
            var total = key(block)
            let id = "\(total.app)\u{1F}\(total.title)"
            if byKey[id] == nil { order.append(id) }
            total.duration = (byKey[id]?.duration ?? 0) + block.duration
            byKey[id] = total
        }
        return order.compactMap { byKey[$0] }.sorted { $0.duration > $1.duration }
    }

    /// Window titles without what changes on its own: notification counters such as "(1716)" or
    /// "Inbox (39,891)", page numbers ("– Page 12 of 44"), and the app name browsers append
    /// ("… - Google Chrome").
    public static func normalizedTitle(_ title: String?, app: String) -> String {
        var text = (title ?? "")
            .replacingOccurrences(of: #"\s*\(\d[\d.,]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s[-–—]\s(Page|Página) \d+ (of|de) \d+$"#, with: "", options: .regularExpression)
        for separator in [" - ", " — ", " – "] where text.hasSuffix(separator + app) {
            text.removeLast(separator.count + app.count)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Text version of an `ActivitySummary`, shared by the MCP tool and the command line.
public enum ActivityReport {
    public static let maxBlocks = 150

    /// Short blocks hide in long periods: 2 minutes for a day or less, 10 for longer.
    public static func defaultMinDuration(from: Date, to: Date) -> TimeInterval {
        to.timeIntervalSince(from) <= 86_400 ? 120 : 600
    }

    public static func render(_ summary: ActivitySummary, minDuration: TimeInterval, timeZone: TimeZone) -> String {
        let multiDay = !calendar(timeZone).isDate(summary.from, inSameDayAs: summary.to.addingTimeInterval(-1))
        var lines = [
            "Actividad entre \(format(summary.from, "yyyy-MM-dd HH:mm", timeZone)) y \(format(summary.to, "yyyy-MM-dd HH:mm", timeZone)) (\(timeZone.identifier)).",
        ]
        if summary.blocks.isEmpty {
            lines.append("No hay cuadros en ese período.")
            return lines.joined(separator: "\n")
        }
        lines.append("Tiempo activo aproximado: \(duration(summary.total)). Cada cuadro cuenta hasta el siguiente, con un máximo de \(duration(summary.maxGap)); los silencios más largos se toman como ausencia.")

        if multiDay {
            lines.append("")
            lines.append("Por día:")
            let days = Dictionary(grouping: summary.blocks) { calendar(timeZone).startOfDay(for: $0.start) }
            for day in days.keys.sorted() {
                let daySummary = ActivitySummary(blocks: days[day] ?? [], from: summary.from, to: summary.to, maxGap: summary.maxGap)
                let top = daySummary.perApp.prefix(3).map { "\($0.app) \(duration($0.duration))" }.joined(separator: ", ")
                lines.append("- \(format(day, "EEE d/M", timeZone)): \(duration(daySummary.total)) · \(top)")
            }
        }

        let timeline = summary.timeline(minDuration: minDuration)
        lines.append("")
        lines.append("Bloques de \(duration(minDuration)) o más (\(timeline.count)):")
        for block in timeline.prefix(maxBlocks) {
            let day = multiDay ? format(block.start, "EEE d/M ", timeZone) : ""
            let range = "\(day)\(format(block.start, "HH:mm", timeZone))–\(format(block.end, "HH:mm", timeZone))"
            lines.append("\(range)  \(duration(block.duration))  \(label(block.app, block.title))")
        }
        if timeline.count > maxBlocks {
            lines.append("… y \(timeline.count - maxBlocks) bloques más: pedí un período más corto o bloques más largos.")
        }

        lines.append("")
        lines.append("Por app:")
        lines += summary.perApp.prefix(15).map { "- \($0.app): \(duration($0.duration))" }

        lines.append("")
        lines.append("Ventanas con más tiempo:")
        lines += summary.perWindow.prefix(15).map { "- \(label($0.app, $0.title)): \(duration($0.duration))" }
        return lines.joined(separator: "\n")
    }

    /// "1 h 05 min", "12 min", "menos de 1 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "menos de 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    private static func label(_ app: String, _ title: String) -> String {
        title.isEmpty ? app : "\(app) — \(title)"
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

extension ActivitySummary {
    /// A summary over already built blocks (used to total each day of a longer period).
    init(blocks: [ActivityBlock], from: Date, to: Date, maxGap: TimeInterval) {
        self.from = from
        self.to = to
        self.maxGap = maxGap
        self.blocks = blocks
    }
}

public enum ActivityPeriod {
    /// `from` and `to` as people write them: ISO 8601 dates or date-times (local time without a
    /// zone), "hoy" or "ayer". A date alone means that whole day. Without `from`, today; without
    /// `to`, the end of `from`'s day when it is a date, or now. Never later than now.
    public static func resolve(from rawFrom: String?, to rawTo: String?, timeZone: TimeZone,
                               now: Date = Date()) -> (from: Date, to: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func parse(_ raw: String?) -> (date: Date, dateOnly: Bool)? {
            switch raw?.lowercased() {
            case nil, "", "hoy", "today": return (calendar.startOfDay(for: now), true)
            case "ayer", "yesterday":
                return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)).map { ($0, true) }
            default: return MCPServer.parseDate(raw!, timeZone: timeZone)
            }
        }
        guard let start = parse(rawFrom) else { return nil }
        var end: Date
        if let rawTo, !rawTo.isEmpty {
            guard let parsed = parse(rawTo) else { return nil }
            end = parsed.dateOnly ? calendar.date(byAdding: .day, value: 1, to: parsed.date) ?? parsed.date : parsed.date
        } else {
            end = start.dateOnly ? calendar.date(byAdding: .day, value: 1, to: start.date) ?? now : now
        }
        end = min(end, now)
        guard end > start.date else { return nil }
        return (start.date, end)
    }
}
