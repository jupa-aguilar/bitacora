import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case noWindow
    case imageEncoding(String)

    public var description: String {
        switch self {
        case .noDisplay: "no display available to capture"
        case .noWindow: "focused window not found"
        case .imageEncoding(let path): "could not write image to \(path)"
        }
    }
}

/// A connected display, in the global coordinates Accessibility and Core Graphics use (points,
/// origin at the top-left corner of the main display).
public struct DisplayInfo: Sendable, Equatable {
    public var id: CGDirectDisplayID
    public var bounds: CGRect
    /// Pixels per point (2 on Retina displays).
    public var scale: CGFloat

    public init(id: CGDirectDisplayID, bounds: CGRect, scale: CGFloat) {
        self.id = id
        self.bounds = bounds
        self.scale = scale
    }

    public static func active() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let pixels = CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(bounds.width)
            return DisplayInfo(id: id, bounds: bounds, scale: bounds.width > 0 ? CGFloat(pixels) / bounds.width : 1)
        }
    }

    /// The display the user is looking at: the one showing most of the focused `window`; without a
    /// window on any display, the one under the `pointer`; otherwise the main display.
    public static func choose(from displays: [DisplayInfo], window: CGRect?, pointer: CGPoint?,
                              main: CGDirectDisplayID) -> DisplayInfo? {
        func visibleArea(_ display: DisplayInfo) -> CGFloat {
            guard let window else { return 0 }
            let visible = window.intersection(display.bounds)
            return visible.isNull ? 0 : visible.width * visible.height
        }
        if let best = displays.max(by: { visibleArea($0) < visibleArea($1) }), visibleArea(best) > 0 { return best }
        if let pointer, let under = displays.first(where: { $0.bounds.contains(pointer) }) { return under }
        return displays.first(where: { $0.id == main }) ?? displays.first
    }
}

/// Takes still screenshots with ScreenCaptureKit (needs Screen Recording permission).
public struct ScreenCapturer: Sendable {
    public init() {}

    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// The preflight check can report "denied" for command-line tools that are in fact allowed,
    /// so a negative answer is confirmed with a real ScreenCaptureKit request. Returns nil when
    /// capturing works, or macOS's error otherwise.
    public static func verifyAccess() async -> String? {
        if hasPermission { return nil }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return nil
        } catch {
            return "\(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]"
        }
    }

    public func captureDisplay(_ info: DisplayInfo) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == info.id }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        configuration.width = mode?.pixelWidth ?? display.width
        configuration.height = mode?.pixelHeight ?? display.height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Only the on-screen window of `pid` closest to `frame` (the focused window, in global points),
    /// without notifications or other windows covering it, at `scale` pixels per point.
    /// Returns the image and the window's frame.
    public func captureWindow(pid: pid_t, frame: CGRect, scale: CGFloat) async throws -> (image: CGImage, frame: CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        func distance(_ window: SCWindow) -> CGFloat {
            abs(window.frame.minX - frame.minX) + abs(window.frame.minY - frame.minY)
                + abs(window.frame.width - frame.width) + abs(window.frame.height - frame.height)
        }
        guard let window = candidates.min(by: { distance($0) < distance($1) }) else { throw CaptureError.noWindow }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, window.frame)
    }
}

public enum ImageWriter {
    /// Returns `image` scaled down to at most `maxWidth` pixels wide (never upscales).
    public static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth, maxWidth > 0 else { return image }
        let width = maxWidth
        let height = Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CaptureError.imageEncoding(url.path) }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.imageEncoding(url.path) }
    }
}
