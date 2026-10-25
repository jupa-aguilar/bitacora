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

    /// OCR lines missing from the accessibility text must add at least this many characters to be kept.
    public static let minNewOCRChars = 30

    /// Accessibility text is exact and cheap, so it wins when it has enough content.
    /// Otherwise OCR runs (canvas apps, games, remote desktops, many Electron apps), and the
    /// longer of the two results is kept.
    ///
    /// `previousAccessibility` is what the same window exposed the last time it was read. The screen
    /// only gets here after it changed, so when the accessibility text did not change at all, what
    /// changed is not in it (a drawing in Excalidraw, a video): OCR runs too, and the lines it reads
    /// that accessibility lacks are appended.
    public static func choose(
        accessibility: String,
        previousAccessibility: String? = nil,
        minAccessibilityChars: Int,
        ocr: () throws -> String
    ) -> ExtractedText {
        let accessibilityLength = meaningfulLength(accessibility)
        if accessibilityLength >= minAccessibilityChars {
            guard accessibility == previousAccessibility else {
                return ExtractedText(text: accessibility, source: .accessibility)
            }
            let extra = lines(of: (try? ocr()) ?? "", missingFrom: accessibility)
            guard meaningfulLength(extra) >= minNewOCRChars else {
                return ExtractedText(text: accessibility, source: .accessibility)
            }
            return ExtractedText(text: accessibility + "\n" + extra, source: .accessibilityAndOCR)
        }
        let recognized = (try? ocr()) ?? ""
        if meaningfulLength(recognized) > accessibilityLength {
            return ExtractedText(text: recognized, source: .ocr)
        }
        if accessibilityLength > 0 {
            return ExtractedText(text: accessibility, source: .accessibility)
        }
        return ExtractedText(text: "", source: .none)
    }

    /// Lines of `ocr` that do not appear anywhere in `text`, ignoring case and spacing, once each.
    /// OCR wraps lines differently than accessibility, so a line counts as known when it is
    /// contained in the text, not only when it equals one of its lines.
    static func lines(of ocr: String, missingFrom text: String) -> String {
        let known = normalized(text)
        var seen = Set<String>()
        return ocr.split(separator: "\n")
            .filter { line in
                let key = normalized(String(line))
                return !key.isEmpty && !known.contains(key) && seen.insert(key).inserted
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Limits OCR to the part of the screen the text came from (the page in a browser, the focused
/// window otherwise), so tabs, bookmarks and other windows are not read.
public enum OCRRegion {
    /// Pixel rectangle of `frame` (global coordinates in points, top-left origin) inside a screenshot
    /// of the display with `displayBounds`, or nil when it falls outside the display.
    public static func pixelRect(for frame: CGRect, displayBounds: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect? {
        let visible = frame.intersection(displayBounds)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        let scaleX = CGFloat(imageWidth) / displayBounds.width
        let scaleY = CGFloat(imageHeight) / displayBounds.height
        return CGRect(x: (visible.minX - displayBounds.minX) * scaleX, y: (visible.minY - displayBounds.minY) * scaleY,
                      width: visible.width * scaleX, height: visible.height * scaleY).integral
    }

    /// `image` (a main display screenshot) cropped to `frame`, or the whole image when that fails.
    public static func crop(_ image: CGImage, to frame: CGRect?) -> CGImage {
        guard let frame, let rect = pixelRect(for: frame, displayBounds: CGDisplayBounds(CGMainDisplayID()),
                                              imageWidth: image.width, imageHeight: image.height)
        else { return image }
        return image.cropping(to: rect) ?? image
    }
}
