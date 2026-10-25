import CoreGraphics
import Foundation
import Vision

public struct ExtractedText: Sendable, Equatable {
    public let text: String
    public let source: TextSource
}

/// On-device OCR with Apple's Vision framework.
public struct OCRReader: Sendable {
    public var languages: [String]

    public init(languages: [String]) {
        self.languages = languages
    }

    public func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        // Vision's coordinates start bottom-left: sort top-to-bottom, then left-to-right.
        let ordered = observations.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return ordered.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

public enum TextSelector {
    /// Number of non-whitespace characters, the measure used to decide if text is "thin".
    public static func meaningfulLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.whitespacesAndNewlines.contains($1) ? 0 : 1) }
    }

    /// OCR lines with new words must add at least this many characters to be kept.
    public static let minNewOCRChars = 30

    /// Accessibility text is exact and cheap, so it wins when it has enough content.
    /// Otherwise OCR runs (canvas apps, games, remote desktops, many Electron apps), and the
    /// longer of the two results is kept.
    ///
    /// `knownWords` is set when every accessibility line was already read in this window before
    /// (see `WindowMemory`): the screen only gets here after it changed, so what changed is not in
    /// the accessibility text (a drawing in Excalidraw, a video). OCR runs too, and the lines that
    /// bring words neither the accessibility text nor the window had shown are appended.
    public static func choose(
        accessibility: String,
        knownWords: Set<String>? = nil,
        minAccessibilityChars: Int,
        ocr: () async throws -> String
    ) async -> ExtractedText {
        let accessibilityLength = meaningfulLength(accessibility)
        if accessibilityLength >= minAccessibilityChars {
            guard let knownWords else { return ExtractedText(text: accessibility, source: .accessibility) }
            let recognized = (try? await ocr()) ?? ""
            let extra = newLines(in: recognized, known: knownWords.union(words(in: accessibility)))
            guard meaningfulLength(extra) >= minNewOCRChars else {
                return ExtractedText(text: accessibility, source: .accessibility)
            }
            return ExtractedText(text: accessibility + "\n" + extra, source: .accessibilityAndOCR)
        }
        let recognized = (try? await ocr()) ?? ""
        if meaningfulLength(recognized) > accessibilityLength {
            return ExtractedText(text: recognized, source: .ocr)
        }
        if accessibilityLength > 0 {
            return ExtractedText(text: accessibility, source: .accessibility)
        }
        return ExtractedText(text: "", source: .none)
    }

    /// Lines of `ocr` where at least half of the words (3+ letters) are not in `known`. Search works
    /// by words, so a line made of known words adds nothing, and OCR misreading text that is already
    /// there (a wrong letter here and there) mostly produces known words too.
    static func newLines(in ocr: String, known: Set<String>) -> String {
        var known = known
        var kept: [String] = []
        for raw in ocr.split(separator: "\n") {
            let lineWords = words(in: String(raw)).filter { $0.count >= 3 }
            guard !lineWords.isEmpty else { continue }
            let unknown = lineWords.filter { !known.contains($0) }.count
            guard unknown * 2 >= lineWords.count else { continue }
            kept.append(raw.trimmingCharacters(in: .whitespaces))
            known.formUnion(lineWords)
        }
        return kept.joined(separator: "\n")
    }

    /// Words as search sees them: lowercase, without accents, split on anything not a letter or digit.
    public static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

/// What each window showed before: the accessibility lines read there and every word stored from it.
/// Tells the engine when a window changed on screen without its accessibility text bringing anything new.
public struct WindowMemory: Sendable {
    private struct Entry: Sendable {
        var lines: Set<String> = []
        var words: Set<String> = []
    }

    public var maxWindows = 50
    public var maxLinesPerWindow = 5_000
    private var entries: [String: Entry] = [:]

    public init() {}

    /// The words already seen in `window` when every line of `accessibility` was read there before,
    /// nil otherwise. Remembers the lines either way.
    public mutating func knownWords(ifNothingNew accessibility: String, window: String) -> Set<String>? {
        let lines = Set(accessibility.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        var entry = entries[window] ?? Entry()
        let nothingNew = !lines.isEmpty && !entry.lines.isEmpty && lines.isSubset(of: entry.lines)
        if entry.lines.count + lines.count > maxLinesPerWindow { entry.lines.removeAll() }
        entry.lines.formUnion(lines)
        store(entry, for: window)
        return nothingNew ? entry.words : nil
    }

    /// Adds the words of `text` (what was extracted, OCR included) to what `window` has shown.
    public mutating func remember(_ text: String, window: String) {
        var entry = entries[window] ?? Entry()
        entry.words.formUnion(TextSelector.words(in: text))
        store(entry, for: window)
    }

    private mutating func store(_ entry: Entry, for window: String) {
        // Only recently used windows matter; starting over now and then keeps the memory small.
        if entries.count >= maxWindows, entries[window] == nil { entries.removeAll() }
        entries[window] = entry
    }
}

/// Limits OCR to the part of the screen the text came from (the page in a browser, the focused
/// window otherwise), so tabs, bookmarks and other windows are not read.
public enum OCRRegion {
    /// Pixel rectangle of `frame` inside an image that shows `bounds` (both in global points,
    /// top-left origin), or nil when `frame` falls outside it.
    public static func pixelRect(for frame: CGRect, in bounds: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let visible = frame.intersection(bounds)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        let scaleX = CGFloat(imageWidth) / bounds.width
        let scaleY = CGFloat(imageHeight) / bounds.height
        return CGRect(x: (visible.minX - bounds.minX) * scaleX, y: (visible.minY - bounds.minY) * scaleY,
                      width: visible.width * scaleX, height: visible.height * scaleY).integral
    }

    /// `image`, which shows `bounds`, cropped to `frame`; the whole image when that fails.
    public static func crop(_ image: CGImage, to frame: CGRect?, in bounds: CGRect) -> CGImage {
        guard let frame, let rect = pixelRect(for: frame, in: bounds, imageWidth: image.width, imageHeight: image.height)
        else { return image }
        return image.cropping(to: rect) ?? image
    }
}
