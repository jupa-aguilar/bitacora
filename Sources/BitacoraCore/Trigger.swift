import Foundation

/// Why a frame was captured.
public enum TriggerKind: String, Codable, CaseIterable, Sendable {
    case manual
    case appSwitch = "app_switch"
    case windowFocus = "window_focus"
    case clipboard
    case typingPause = "typing_pause"
    case scrollStop = "scroll_stop"
    case click
    case visualChange = "visual_change"
    case idle

    /// When several triggers arrive between two captures, the highest priority one names the frame.
    /// Context switches outrank fine-grained input; periodic triggers come last.
    public var priority: Int {
        switch self {
        case .manual: 100
        case .appSwitch: 90
        case .windowFocus: 80
        case .clipboard: 70
        case .typingPause: 60
        case .scrollStop: 50
        case .click: 40
        case .visualChange: 30
        case .idle: 10
        }
    }

    /// Manual captures ignore the debounce interval and the duplicate check.
    public var bypassesGate: Bool { self == .manual }
}

public struct Trigger: Sendable, Equatable {
    public let kind: TriggerKind
    public let date: Date

    public init(_ kind: TriggerKind, date: Date = Date()) {
        self.kind = kind
        self.date = date
    }
}

public enum TriggerReducer {
    /// Collapses a burst of pending triggers into the one that will label the capture:
    /// highest priority wins, and among equals the most recent one.
    public static func reduce(_ triggers: [Trigger]) -> Trigger? {
        triggers.max { a, b in
            if a.kind.priority != b.kind.priority { return a.kind.priority < b.kind.priority }
            return a.date < b.date
        }
    }
}

public enum IdleSchedule {
    /// An idle capture is due when neither a frame was stored nor an idle capture was attempted
    /// during the last `interval` seconds. Nothing is due before the first stored frame.
    public static func isDue(lastCapture: Date?, lastIdleTrigger: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let lastCapture else { return false }
        let reference = max(lastCapture, lastIdleTrigger ?? lastCapture)
        return now.timeIntervalSince(reference) >= interval
    }
}

/// Debounce: at most one stored frame per `minInterval`.
public struct CaptureGate: Sendable {
    public let minInterval: TimeInterval
    public private(set) var lastCapture: Date?

    public init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    public func allows(_ trigger: Trigger, now: Date) -> Bool {
        if trigger.kind.bypassesGate { return true }
        guard let lastCapture else { return true }
        return now.timeIntervalSince(lastCapture) >= minInterval
    }

    public mutating func markCaptured(at date: Date) {
        lastCapture = date
    }
}
