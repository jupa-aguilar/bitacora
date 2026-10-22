import Foundation

/// Runtime settings. Every field is optional in `config.json`; missing fields keep their defaults.
public struct BitacoraConfig: Codable, Sendable {
    /// Minimum time between two stored frames (debounce), in seconds.
    public var minCaptureInterval: TimeInterval = 5.0
    /// Store a frame after this many seconds without any capture, even if nothing happened.
    public var idleCaptureInterval: TimeInterval = 300
    /// How often the screen is sampled to detect visual changes, in seconds.
    public var visualCheckInterval: TimeInterval = 3.0
    /// Difference score (0...1) above which a visual check becomes a capture.
    public var visualChangeThreshold: Double = 0.05
    /// Below this score an event-triggered frame is considered a duplicate, even if the window changed.
    public var duplicateThreshold: Double = 0.03
    /// Seconds without keystrokes before a `typing_pause` trigger fires.
    public var typingPauseDelay: TimeInterval = 1.5
    /// Seconds without scrolling before a `scroll_stop` trigger fires.
    public var scrollStopDelay: TimeInterval = 0.8
    /// Accessibility text shorter than this (non-whitespace characters) falls back to OCR.
    public var minAccessibilityChars: Int = 100
    /// OCR languages, in priority order (BCP-47).
    public var ocrLanguages: [String] = ["es-ES", "en-US"]
    /// Stored screenshots are downscaled to this width (pixels).
    public var snapshotMaxWidth: Int = 1440
    public var jpegQuality: Double = 0.5
    /// Apps that are never captured (bundle identifiers).
    public var excludedBundleIDs: [String] = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]
    /// Windows whose title contains any of these (case-insensitive) are never captured.
    public var excludedTitleKeywords: [String] = [
        "incognito", "incógnito", "private browsing", "navegación privada", "inprivate",
    ]
    /// Local API port (bound to 127.0.0.1 only).
    public var port: UInt16 = 3939
    /// Screenshots older than this many days are deleted; their text stays searchable. 0 = keep forever.
    public var imageRetentionDays: Int = 30
    /// Frames (text included) older than this many days are deleted. 0 = keep forever.
    public var textRetentionDays: Int = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BitacoraConfig()
        minCaptureInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .minCaptureInterval) ?? d.minCaptureInterval
        idleCaptureInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .idleCaptureInterval) ?? d.idleCaptureInterval
        visualCheckInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .visualCheckInterval) ?? d.visualCheckInterval
        visualChangeThreshold = try c.decodeIfPresent(Double.self, forKey: .visualChangeThreshold) ?? d.visualChangeThreshold
        duplicateThreshold = try c.decodeIfPresent(Double.self, forKey: .duplicateThreshold) ?? d.duplicateThreshold
        typingPauseDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .typingPauseDelay) ?? d.typingPauseDelay
        scrollStopDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .scrollStopDelay) ?? d.scrollStopDelay
        minAccessibilityChars = try c.decodeIfPresent(Int.self, forKey: .minAccessibilityChars) ?? d.minAccessibilityChars
        ocrLanguages = try c.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? d.ocrLanguages
        snapshotMaxWidth = try c.decodeIfPresent(Int.self, forKey: .snapshotMaxWidth) ?? d.snapshotMaxWidth
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? d.jpegQuality
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? d.excludedBundleIDs
        excludedTitleKeywords = try c.decodeIfPresent([String].self, forKey: .excludedTitleKeywords) ?? d.excludedTitleKeywords
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        imageRetentionDays = try c.decodeIfPresent(Int.self, forKey: .imageRetentionDays) ?? d.imageRetentionDays
        textRetentionDays = try c.decodeIfPresent(Int.self, forKey: .textRetentionDays) ?? d.textRetentionDays
    }

    /// Loads `config.json` from the data directory, or returns the defaults when it does not exist.
    public static func load(from paths: DataPaths) throws -> BitacoraConfig {
        guard FileManager.default.fileExists(atPath: paths.config.path) else { return BitacoraConfig() }
        let data = try Data(contentsOf: paths.config)
        return try JSONDecoder().decode(BitacoraConfig.self, from: data)
    }
}

/// Locations inside the data directory (`~/.bitacora` by default, overridable with `BITACORA_HOME`).
public struct DataPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let env = ProcessInfo.processInfo.environment["BITACORA_HOME"], !env.isEmpty {
            self.root = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bitacora", isDirectory: true)
        }
    }

    public var database: URL { root.appendingPathComponent("bitacora.sqlite") }
    public var frames: URL { root.appendingPathComponent("frames", isDirectory: true) }
    public var config: URL { root.appendingPathComponent("config.json") }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    }
}
