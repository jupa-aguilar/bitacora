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
    /// In browsers and web-based apps only the page is read, not tabs, toolbars or extensions.
    public func readText(pid: pid_t) -> String {
        guard let window = focusedWindow(pid: pid) else { return "" }
        let walker = TextTreeWalker(
            maxNodes: maxNodes, maxDepth: maxDepth, maxCharacters: maxCharacters,
            deadline: Date().addingTimeInterval(timeBudget)
        )
        let root = AXNode(element: window)
        return walker.collectText(from: walker.contentRoot(of: root))
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

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        axString(element, attribute)
    }
}

private func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
    return raw as? T
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    if let text: String = axValue(element, attribute) { return text }
    if let url: URL = axValue(element, attribute) { return url.absoluteString }
    return nil
}

/// The parts of an accessibility element the text walker needs; lets tests use a fake tree.
protocol TextTreeNode {
    var role: String? { get }
    var subrole: String? { get }
    /// Title, value and description, in that order, when present.
    var texts: [String] { get }
    var children: [Self] { get }
}

struct AXNode: TextTreeNode {
    let element: AXUIElement

    var role: String? { axString(element, kAXRoleAttribute) }
    var subrole: String? { axString(element, kAXSubroleAttribute) }
    var texts: [String] {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { axString(element, $0) }
    }
    var children: [AXNode] {
        (axValue(element, kAXChildrenAttribute) as [AXUIElement]?)?.map(AXNode.init) ?? []
    }
}

/// Breadth-first text extraction with node, depth, size and time limits.
struct TextTreeWalker {
    static let webAreaRole = "AXWebArea"

    var maxNodes: Int
    var maxDepth: Int
    var maxCharacters: Int
    var deadline: Date

    /// The outermost web area (the page in a browser or Electron app), or the window itself.
    func contentRoot<N: TextTreeNode>(of window: N) -> N {
        var queue: [(node: N, depth: Int)] = [(window, 0)]
        var head = 0
        while head < queue.count, head < maxNodes, Date() < deadline {
            let (node, depth) = queue[head]
            head += 1
            if node.role == Self.webAreaRole { return node }
            if depth < maxDepth { queue.append(contentsOf: node.children.map { ($0, depth + 1) }) }
        }
        return window
    }

    func collectText<N: TextTreeNode>(from root: N) -> String {
        var queue: [(node: N, depth: Int)] = [(root, 0)]
        var head = 0
        var seen = Set<String>()
        var pieces: [String] = []
        var characters = 0

        while head < queue.count, head < maxNodes, characters < maxCharacters, Date() < deadline {
            let (node, depth) = queue[head]
            head += 1

            if node.subrole == kAXSecureTextFieldSubrole { continue }

            for raw in node.texts {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, seen.insert(text).inserted else { continue }
                let clipped = String(text.prefix(5_000))
                pieces.append(clipped)
                characters += clipped.count
            }

            if depth < maxDepth { queue.append(contentsOf: node.children.map { ($0, depth + 1) }) }
        }
        return pieces.joined(separator: "\n")
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
