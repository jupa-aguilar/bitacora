import CoreGraphics
import Foundation

public enum CaptureOutcome: Sendable, Equatable {
    case stored(id: Int64, trigger: TriggerKind, difference: Double, source: TextSource)
    case skipped(reason: String)
    case debounced
    case nothingPending
}

/// Turns triggers into stored frames.
///
/// Pipeline for every tick: drain pending triggers → keep the highest priority one → debounce →
/// privacy checks → screenshot → visual difference against the last stored frame →
/// text (accessibility first, OCR fallback) → JPEG on disk + row in SQLite.
public actor CaptureEngine {
    private let config: BitacoraConfig
    private let paths: DataPaths
    private let storage: Storage
    private let capturer = ScreenCapturer()
    private let accessibility = AccessibilityReader()
    private let ocr: OCRReader
    private let privacy: PrivacyFilter

    private var pending: [Trigger] = []
    private var gate: CaptureGate
    private var comparer = FrameComparer()
    private var lastStoredText: String?
    private var lastCapture: Date?
    private var lastIdleTrigger: Date?
    private var busy = false

    public private(set) var storedCount = 0
    public private(set) var skippedCount = 0

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public init(config: BitacoraConfig, paths: DataPaths, storage: Storage) {
        self.config = config
        self.paths = paths
        self.storage = storage
        self.ocr = OCRReader(languages: config.ocrLanguages)
        self.privacy = PrivacyFilter(config: config)
        self.gate = CaptureGate(minInterval: config.minCaptureInterval)
    }

    public func submit(_ trigger: Trigger) {
        pending.append(trigger)
    }

    /// Called periodically by the run loop. Adds an idle trigger when nothing was stored for a
    /// while, then processes at most one capture.
    @discardableResult
    public func tick(now: Date = Date()) async -> CaptureOutcome {
        if IdleSchedule.isDue(lastCapture: lastCapture, lastIdleTrigger: lastIdleTrigger,
                              interval: config.idleCaptureInterval, now: now) {
            // Remember the attempt too, so a skipped idle capture (locked screen, excluded app)
            // waits a full interval instead of retrying on every tick.
            lastIdleTrigger = now
            pending.append(Trigger(.idle, date: now))
        }
        guard !busy, let trigger = TriggerReducer.reduce(pending) else { return .nothingPending }
        guard gate.allows(trigger, now: now) else {
            // Coalesce: keep only the winner so it fires once the debounce window opens.
            pending = [trigger]
            return .debounced
        }
        pending.removeAll()
        busy = true
        defer { busy = false }
        let outcome = await capture(trigger: trigger, now: now)
        switch outcome {
        case .stored(_, let kind, let difference, let source):
            storedCount += 1
            Log.info("stored frame (\(kind.rawValue), diff \(String(format: "%.3f", difference)), text: \(source.rawValue))")
        case .skipped(let reason):
            skippedCount += 1
            Log.debug("skipped \(trigger.kind.rawValue): \(reason)")
        default:
            break
        }
        return outcome
    }

    private func capture(trigger: Trigger, now: Date) async -> CaptureOutcome {
        if SessionState.isScreenLocked { return .skipped(reason: "screen locked") }

        let context = accessibility.currentContext()
        if let reason = privacy.skipReason(for: context) { return .skipped(reason: reason) }

        let image: CGImage
        do {
            image = try await capturer.captureMainDisplay()
        } catch {
            return .skipped(reason: "screenshot failed: \(error)")
        }
        guard let thumbnail = GrayThumbnail.make(from: image) else {
            return .skipped(reason: "could not build thumbnail")
        }

        let difference = comparer.difference(to: thumbnail)
        if let reason = CapturePolicy.visualSkipReason(trigger: trigger.kind, difference: difference, config: config) {
            return .skipped(reason: reason)
        }

        let accessibilityText = context.pid.map { accessibility.readText(pid: $0) } ?? ""
        let ocr = self.ocr
        let extracted = TextSelector.choose(
            accessibility: accessibilityText,
            minAccessibilityChars: config.minAccessibilityChars,
            ocr: { try ocr.recognize(image) }
        )
        if let reason = CapturePolicy.textSkipReason(trigger: trigger.kind, text: extracted.text, previousText: lastStoredText) {
            return .skipped(reason: reason)
        }

        let day = Self.dayFormatter.string(from: now)
        let imageURL = paths.frames
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(Int(now.timeIntervalSince1970 * 1000)).jpg")
        do {
            try ImageWriter.writeJPEG(
                ImageWriter.downscaled(image, maxWidth: config.snapshotMaxWidth),
                to: imageURL,
                quality: config.jpegQuality
            )
            let id = try storage.insert(NewFrame(
                capturedAt: now,
                trigger: trigger.kind,
                appName: context.appName,
                bundleID: context.bundleID,
                windowTitle: context.windowTitle,
                url: context.url,
                text: extracted.text,
                textSource: extracted.source,
                imagePath: imageURL.path,
                visualDifference: difference
            ))
            comparer.setReference(thumbnail)
            gate.markCaptured(at: now)
            lastCapture = now
            lastStoredText = extracted.text
            return .stored(id: id, trigger: trigger.kind, difference: difference, source: extracted.source)
        } catch {
            return .skipped(reason: "could not save frame: \(error)")
        }
    }
}

/// Rules that discard a frame after it was captured. Manual and idle captures are always kept.
public enum CapturePolicy {
    /// Applied right after the screenshot, before the (more expensive) text extraction.
    public static func visualSkipReason(trigger: TriggerKind, difference: Double, config: BitacoraConfig) -> String? {
        let diff = String(format: "%.3f", difference)
        switch trigger {
        case .manual, .idle:
            return nil
        case .visualChange:
            return difference < config.visualChangeThreshold ? "no visual change (\(diff))" : nil
        default:
            // Even if the app or window title changed (browsers rewrite titles on their own),
            // an identical-looking screen adds nothing.
            return difference < config.duplicateThreshold ? "duplicate of previous frame (\(diff))" : nil
        }
    }

    /// Applied after text extraction: the same text as the last stored frame adds nothing to search.
    public static func textSkipReason(trigger: TriggerKind, text: String, previousText: String?) -> String? {
        switch trigger {
        case .manual, .idle:
            return nil
        default:
            guard !text.isEmpty, text == previousText else { return nil }
            return "same text as previous frame"
        }
    }
}

public enum Log {
    public nonisolated(unsafe) static var verbose = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public static func info(_ message: String) {
        FileHandle.standardError.write(Data("[\(formatter.string(from: Date()))] \(message)\n".utf8))
    }

    public static func debug(_ message: String) {
        if verbose { info(message) }
    }
}
