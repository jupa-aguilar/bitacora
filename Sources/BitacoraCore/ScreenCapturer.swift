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

/// Takes still screenshots of the main display with ScreenCaptureKit (needs Screen Recording permission).
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

    public func captureMainDisplay() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
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
    /// without notifications or other windows covering it. Returns the image and the window's frame.
    public func captureWindow(pid: pid_t, frame: CGRect) async throws -> (image: CGImage, frame: CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        func distance(_ window: SCWindow) -> CGFloat {
            abs(window.frame.minX - frame.minX) + abs(window.frame.minY - frame.minY)
                + abs(window.frame.width - frame.width) + abs(window.frame.height - frame.height)
        }
        guard let window = candidates.min(by: { distance($0) < distance($1) }) else { throw CaptureError.noWindow }
        let display = CGMainDisplayID()
        let scale = CGFloat(CGDisplayCopyDisplayMode(display)?.pixelWidth ?? Int(CGDisplayBounds(display).width))
            / CGDisplayBounds(display).width
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
