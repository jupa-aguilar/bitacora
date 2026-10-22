import Foundation

public struct RetentionReport: Sendable, Equatable {
    public var imagesDeleted = 0
    public var bytesFreed: Int64 = 0
    public var framesDeleted = 0
    public var dryRun = false

    public var isEmpty: Bool { imagesDeleted == 0 && framesDeleted == 0 }

    public var summary: String {
        let verb = dryRun ? "se borrarían" : "borradas"
        let size = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        var parts = ["\(imagesDeleted) capturas \(verb) (\(size))"]
        if framesDeleted > 0 { parts.append("\(framesDeleted) cuadros \(dryRun ? "se borrarían" : "borrados") con su texto") }
        return parts.joined(separator: ", ")
    }
}

/// Keeps disk usage bounded: old screenshots go first (text stays searchable), and optionally
/// whole frames after a longer period. Only files inside the frames directory are ever deleted.
public struct Retention: Sendable {
    let storage: Storage
    let paths: DataPaths
    let config: BitacoraConfig

    public init(storage: Storage, paths: DataPaths, config: BitacoraConfig) {
        self.storage = storage
        self.paths = paths
        self.config = config
    }

    public func run(now: Date = Date(), dryRun: Bool = false) throws -> RetentionReport {
        var report = RetentionReport(dryRun: dryRun)
        var handled = Set<Int64>()

        if config.textRetentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(config.textRetentionDays) * 86_400)
            let frames = try storage.framesWithImages(before: cutoff)
            handled.formUnion(frames.map(\.id))
            let (deleted, bytes) = deleteFiles(frames, dryRun: dryRun)
            report.imagesDeleted += deleted.count
            report.bytesFreed += bytes
            report.framesDeleted = dryRun ? try storage.countFrames(before: cutoff) : try storage.deleteFrames(before: cutoff)
        }

        if config.imageRetentionDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(config.imageRetentionDays) * 86_400)
            let frames = try storage.framesWithImages(before: cutoff).filter { !handled.contains($0.id) }
            let (deleted, bytes) = deleteFiles(frames, dryRun: dryRun)
            report.imagesDeleted += deleted.count
            report.bytesFreed += bytes
            if !dryRun { try storage.clearImagePaths(ids: deleted) }
        }

        if !dryRun { removeEmptyDayFolders() }
        return report
    }

    /// Deletes the screenshots that live inside the frames directory. Returns the ids whose image is
    /// gone (deleted now or already missing) and the bytes freed.
    private func deleteFiles(_ frames: [(id: Int64, path: String)], dryRun: Bool) -> (ids: [Int64], bytes: Int64) {
        let root = paths.frames.standardizedFileURL.path + "/"
        let fileManager = FileManager.default
        var ids: [Int64] = []
        var bytes: Int64 = 0
        for frame in frames {
            let url = URL(fileURLWithPath: frame.path).standardizedFileURL
            guard url.path.hasPrefix(root) else { continue }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if !dryRun, size != nil {
                guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            }
            ids.append(frame.id)
            bytes += size ?? 0
        }
        return (ids, bytes)
    }

    private func removeEmptyDayFolders() {
        let fileManager = FileManager.default
        guard let days = try? fileManager.contentsOfDirectory(at: paths.frames, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for day in days where (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if (try? fileManager.contentsOfDirectory(atPath: day.path))?.isEmpty == true {
                try? fileManager.removeItem(at: day)
            }
        }
    }

    /// Total size of the stored screenshots, in bytes.
    public static func diskUsage(of directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
