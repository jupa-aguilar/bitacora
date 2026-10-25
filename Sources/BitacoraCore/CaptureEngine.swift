import CoreGraphics
import Foundation

public enum CaptureOutcome: Sendable, Equatable {
    case stored(id: Int64, trigger: TriggerKind, difference: Double, source: TextSource)
    /// A visual check overwrote the last stored frame (same window, same text plus a little more).
    case replaced(id: Int64, difference: Double, source: TextSource)
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
    private var lastStored: LastStoredFrame?
    private var lastCapture: Date?
    private var lastIdleTrigger: Date?
    private var busy = false

    public private(set) var storedCount = 0
    public private(set) var replacedCount = 0
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
        case .replaced(let id, let difference, let source):
            replacedCount += 1
            Log.debug("replaced frame #\(id) (diff \(String(format: "%.3f", difference)), text: \(source.rawValue))")
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
        if let reason = CapturePolicy.textSkipReason(trigger: trigger.kind, text: extracted.text, previousText: lastStored?.text) {
            return .skipped(reason: reason)
        }
        let replacing = CapturePolicy.replacesLast(trigger: trigger.kind, context: context, text: extracted.text,
                                                   last: lastStored, now: now, config: config) ? lastStored : nil

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
            let frame = NewFrame(
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
            )
            let id: Int64
            if let replacing {
                id = replacing.id
                try storage.replace(id: id, with: frame)
                if let oldImage = replacing.imagePath { try? FileManager.default.removeItem(atPath: oldImage) }
            } else {
                id = try storage.insert(frame)
            }
            comparer.setReference(thumbnail)
            gate.markCaptured(at: now)
            lastCapture = now
            lastStored = LastStoredFrame(id: id, bundleID: context.bundleID, windowTitle: context.windowTitle,
                                         text: extracted.text, imagePath: imageURL.path,
                                         burstStart: replacing?.burstStart ?? now)
            if replacing != nil {
                return .replaced(id: id, difference: difference, source: extracted.source)
            }
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

    /// Applied to visual checks that passed the other rules. A reply being written or a video playing
    /// fires one visual change after another in the same window, each with almost the same text: the
    /// newer capture overwrites the last stored frame, so the burst ends up as one frame with its final state.
    public static func replacesLast(trigger: TriggerKind, context: WindowContext, text: String,
                                    last: LastStoredFrame?, now: Date, config: BitacoraConfig) -> Bool {
        guard trigger == .visualChange, let last,
              last.bundleID == context.bundleID, last.windowTitle == context.windowTitle,
              now.timeIntervalSince(last.burstStart) < config.burstWindow else { return false }
        return textOverlap(of: last.text, in: text) >= config.burstMinTextOverlap
    }

    /// Share of the old text's distinct non-blank lines that are still present in the new text.
    /// 1 means replacing the old text with the new one loses nothing.
    public static func textOverlap(of old: String, in new: String) -> Double {
        let oldLines = Set(old.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) })
        guard !oldLines.isEmpty else { return 1 }
        let newLines = Set(new.split(separator: "\n"))
        return Double(oldLines.intersection(newLines).count) / Double(oldLines.count)
    }
}

/// What the engine remembers about the last stored frame.
public struct LastStoredFrame: Sendable, Equatable {
    public var id: Int64
    public var bundleID: String?
    public var windowTitle: String?
    public var text: String
    public var imagePath: String?
    /// When the frame was first stored; replacing it keeps this date.
    public var burstStart: Date

    public init(id: Int64, bundleID: String?, windowTitle: String?, text: String, imagePath: String?, burstStart: Date) {
        self.id = id
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.text = text
        self.imagePath = imagePath
        self.burstStart = burstStart
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
