import AppKit
import ApplicationServices
import Foundation

/// What was in front of the user when a frame was captured.
public struct WindowContext: Sendable, Equatable {
    public var appName: String?
    public var bundleID: String?
    public var pid: pid_t?
    public var windowTitle: String?
    public var url: String?

    public init(appName: String? = nil, bundleID: String? = nil, pid: pid_t? = nil, windowTitle: String? = nil, url: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowTitle = windowTitle
        self.url = url
    }

    /// Identifies "the same window" for duplicate detection.
    public var windowKey: String { "\(bundleID ?? "?")|\(windowTitle ?? "")" }
}

/// Reads window metadata and on-screen text through the macOS Accessibility API
/// (needs the Accessibility permission). Password fields are never read.
public struct AccessibilityReader: Sendable {
    public var maxNodes = 4_000
    public var maxDepth = 64
    public var maxCharacters = 60_000
    public var timeBudget: TimeInterval = 0.5

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func currentContext() -> WindowContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return WindowContext() }
        var context = WindowContext(
            appName: app.localizedName,
            bundleID: app.bundleIdentifier,
            pid: app.processIdentifier
        )
        if let window = focusedWindow(pid: app.processIdentifier) {
            context.windowTitle = string(window, kAXTitleAttribute)
            context.url = string(window, kAXDocumentAttribute)
        }
        return context
    }

    /// Visible text of the frontmost app's focused window, top to bottom, without exact duplicates.
    public func readText(pid: pid_t) -> String {
        guard let window = focusedWindow(pid: pid) else { return "" }
        let deadline = Date().addingTimeInterval(timeBudget)
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var head = 0
        var seen = Set<String>()
        var pieces: [String] = []
        var characters = 0

        while head < queue.count, head < maxNodes, characters < maxCharacters, Date() < deadline {
            let (element, depth) = queue[head]
            head += 1

            if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { continue }

            for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                guard let raw = string(element, attribute) else { continue }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, seen.insert(text).inserted else { continue }
                let clipped = String(text.prefix(5_000))
                pieces.append(clipped)
                characters += clipped.count
            }

            if depth < maxDepth, let children: [AXUIElement] = value(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - AX helpers

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        if let text: String = value(element, attribute) { return text }
        if let url: URL = value(element, attribute) { return url.absoluteString }
        return nil
    }
}

/// Lock-screen detection through the window server session dictionary.
public enum SessionState {
    public static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}

/// Decides which windows must never be recorded.
public struct PrivacyFilter: Sendable {
    public let excludedBundleIDs: Set<String>
    public let excludedTitleKeywords: [String]

    public init(config: BitacoraConfig) {
        excludedBundleIDs = Set(config.excludedBundleIDs)
        excludedTitleKeywords = config.excludedTitleKeywords.map { $0.lowercased() }
    }

    /// A human-readable reason to skip this window, or nil when it may be captured.
    public func skipReason(for context: WindowContext) -> String? {
        if let bundle = context.bundleID, excludedBundleIDs.contains(bundle) {
            return "excluded app \(bundle)"
        }
        if let title = context.windowTitle?.lowercased(),
           let keyword = excludedTitleKeywords.first(where: { title.contains($0) }) {
            return "window title contains '\(keyword)'"
        }
        return nil
    }
}
