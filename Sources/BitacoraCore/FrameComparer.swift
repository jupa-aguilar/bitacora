import CoreGraphics
import Foundation

/// Small grayscale copy of a screenshot, used only to decide whether the screen changed.
public struct GrayThumbnail: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must match dimensions")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Downscales `image` to `width` pixels wide (keeping the aspect ratio) in 8-bit gray.
    public static func make(from image: CGImage, width: Int = 96) -> GrayThumbnail? {
        guard image.width > 0, image.height > 0 else { return nil }
        let w = max(1, width)
        let h = max(1, Int((Double(image.height) / Double(image.width) * Double(w)).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? GrayThumbnail(width: w, height: h, pixels: pixels) : nil
    }
}

/// Scores how different the current screen is from a reference frame, from 0 (identical) to 1.
///
/// The score averages two complementary signals:
/// - Hellinger distance between brightness histograms (global changes: a new window, dark mode).
/// - 1 − SSIM over 8×8 blocks (local structure: text scrolled, a dialog appeared).
public struct FrameComparer: Sendable {
    public private(set) var reference: GrayThumbnail?

    public init() {}

    public mutating func setReference(_ thumbnail: GrayThumbnail) {
        reference = thumbnail
    }

    /// Difference against the reference, or 1 when there is no comparable reference yet.
    public func difference(to current: GrayThumbnail) -> Double {
        guard let reference else { return 1 }
        return Self.score(reference, current)
    }

    public static func score(_ a: GrayThumbnail, _ b: GrayThumbnail) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        if a.pixels == b.pixels { return 0 }
        let histogramDistance = hellinger(histogram(a), histogram(b))
        let structuralDistance = min(1, max(0, 1 - ssim(a, b)))
        return min(1, max(0, 0.5 * histogramDistance + 0.5 * structuralDistance))
    }

    static let histogramBins = 32

    /// Normalized brightness histogram (sums to 1).
    static func histogram(_ t: GrayThumbnail) -> [Double] {
        var bins = [Double](repeating: 0, count: histogramBins)
        let shift = 8 - Int(log2(Double(histogramBins)))
        for p in t.pixels { bins[Int(p) >> shift] += 1 }
        let total = Double(t.pixels.count)
        return bins.map { $0 / total }
    }

    /// Hellinger distance between two discrete distributions, in 0...1.
    static func hellinger(_ p: [Double], _ q: [Double]) -> Double {
        var coefficient = 0.0
        for i in p.indices { coefficient += (p[i] * q[i]).squareRoot() }
        return max(0, 1 - coefficient).squareRoot()
    }

    /// Mean structural similarity over non-overlapping 8×8 blocks, in −1...1.
    static func ssim(_ a: GrayThumbnail, _ b: GrayThumbnail) -> Double {
        let c1 = (0.01 * 255) * (0.01 * 255)
        let c2 = (0.03 * 255) * (0.03 * 255)
        let block = 8
        var total = 0.0
        var blocks = 0
        for by in stride(from: 0, to: a.height, by: block) {
            for bx in stride(from: 0, to: a.width, by: block) {
                let bw = min(block, a.width - bx)
                let bh = min(block, a.height - by)
                let n = Double(bw * bh)
                var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
                for y in by..<(by + bh) {
                    let row = y * a.width
                    for x in bx..<(bx + bw) {
                        let va = Double(a.pixels[row + x])
                        let vb = Double(b.pixels[row + x])
                        sumA += va
                        sumB += vb
                        sumAA += va * va
                        sumBB += vb * vb
                        sumAB += va * vb
                    }
                }
                let meanA = sumA / n
                let meanB = sumB / n
                let varA = sumAA / n - meanA * meanA
                let varB = sumBB / n - meanB * meanB
                let cov = sumAB / n - meanA * meanB
                let numerator = (2 * meanA * meanB + c1) * (2 * cov + c2)
                let denominator = (meanA * meanA + meanB * meanB + c1) * (varA + varB + c2)
                total += numerator / denominator
                blocks += 1
            }
        }
        return blocks > 0 ? total / Double(blocks) : 1
    }
}
