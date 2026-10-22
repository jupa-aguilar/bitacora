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

    /// Accessibility text is exact and cheap, so it wins when it has enough content.
    /// Otherwise OCR runs (canvas apps, games, remote desktops, many Electron apps), and the
    /// longer of the two results is kept.
    public static func choose(
        accessibility: String,
        minAccessibilityChars: Int,
        ocr: () throws -> String
    ) -> ExtractedText {
        let accessibilityLength = meaningfulLength(accessibility)
        if accessibilityLength >= minAccessibilityChars {
            return ExtractedText(text: accessibility, source: .accessibility)
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
}
