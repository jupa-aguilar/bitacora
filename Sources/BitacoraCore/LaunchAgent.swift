import Foundation

/// Starts `bitacora record --serve` at login and restarts it if it crashes, through launchd.
///
/// Under launchd macOS grants Screen Recording and Accessibility to the `bitacora` binary itself,
/// not to Terminal. Builds are signed ad hoc, so a new build may need those permissions again.
public struct LaunchAgent: Sendable {
    public static let label = "local.bitacora.record"
    /// Set in the agent's environment so `record` knows nobody is watching a terminal.
    public static let environmentFlag = "BITACORA_LAUNCHD"

    public let executable: URL
    public let paths: DataPaths

    public init(executable: URL, paths: DataPaths) {
        self.executable = executable
        self.paths = paths
    }

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public var logFile: URL { paths.logs.appendingPathComponent("bitacora.log") }

    static var domain: String { "gui/\(getuid())" }

    public func propertyList() -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executable.path, "record", "--serve"],
            "RunAtLoad": true,
            // Restart after a crash, but not after a clean exit (e.g. missing permissions).
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "ProcessType": "Interactive",
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "EnvironmentVariables": [
                Self.environmentFlag: "1",
                "BITACORA_HOME": paths.root.path,
            ],
        ]
    }

    /// Writes the plist and (re)loads the agent so it starts right away.
    public func install() throws {
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList(), format: .xml, options: 0)
        try data.write(to: Self.plistURL, options: .atomic)
        if Self.isLoaded {
            _ = try Self.launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
            Self.waitUntilUnloaded()
        }
        var result = try Self.launchctl(["bootstrap", Self.domain, Self.plistURL.path])
        if result.status != 0 {
            // launchd may still be tearing down the previous instance ("Input/output error").
            Thread.sleep(forTimeInterval: 1.5)
            result = try Self.launchctl(["bootstrap", Self.domain, Self.plistURL.path])
        }
        guard result.status == 0 else { throw LaunchAgentError.launchctl(result.output) }
    }

    /// `bootout` returns before launchd has fully removed the job; bootstrapping too early fails.
    static func waitUntilUnloaded(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while isLoaded, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public static func uninstall() throws {
        if isLoaded {
            _ = try launchctl(["bootout", "\(domain)/\(label)"])
            waitUntilUnloaded()
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public static var isLoaded: Bool {
        ((try? launchctl(["print", "\(domain)/\(label)"]))?.status ?? 1) == 0
    }

    public static var isRunningUnderLaunchd: Bool {
        ProcessInfo.processInfo.environment[environmentFlag] == "1"
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum LaunchAgentError: Error, CustomStringConvertible {
    case launchctl(String)

    public var description: String {
        switch self {
        case .launchctl(let output): "launchctl falló: \(output)"
        }
    }
}
