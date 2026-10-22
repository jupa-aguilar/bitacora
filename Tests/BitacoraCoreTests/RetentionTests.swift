import Foundation
import XCTest
@testable import BitacoraCore

final class RetentionTests: XCTestCase {
    private var root: URL!
    private var paths: DataPaths!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bitacora-retention-\(UUID())", isDirectory: true)
        paths = DataPaths(root: root)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Inserts a frame `daysAgo` old with a 1 KB screenshot inside the frames directory.
    @discardableResult
    private func frame(_ storage: Storage, daysAgo: Double, text: String, imageAt url: URL? = nil) throws -> (id: Int64, image: URL) {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        let image = url ?? paths.frames.appendingPathComponent("day-\(Int(daysAgo))/\(UUID()).jpg")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1_024).write(to: image)
        let id = try storage.insert(NewFrame(capturedAt: date, trigger: .click, appName: "Safari",
                                             text: text, textSource: .accessibility, imagePath: image.path))
        return (id, image)
    }

    private func config(images: Int, text: Int) -> BitacoraConfig {
        var config = BitacoraConfig()
        config.imageRetentionDays = images
        config.textRetentionDays = text
        return config
    }

    func testOldImagesAreDeletedButTextStaysSearchable() throws {
        let storage = try Storage.inMemory()
        let old = try frame(storage, daysAgo: 40, text: "factura de marzo")
        let recent = try frame(storage, daysAgo: 2, text: "factura de octubre")

        let report = try Retention(storage: storage, paths: paths, config: config(images: 30, text: 0)).run(now: now)

        XCTAssertEqual(report.imagesDeleted, 1)
        XCTAssertEqual(report.bytesFreed, 1_024)
        XCTAssertEqual(report.framesDeleted, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.image.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.image.path))
        XCTAssertNil(try storage.frame(id: old.id)?.imagePath)
        XCTAssertEqual(try storage.search(SearchQuery(text: "marzo")).count, 1, "text must stay searchable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.image.deletingLastPathComponent().path), "empty day folder removed")
    }

    func testTextRetentionDeletesWholeFrames() throws {
        let storage = try Storage.inMemory()
        let ancient = try frame(storage, daysAgo: 400, text: "muy viejo")
        try frame(storage, daysAgo: 40, text: "viejo")
        try frame(storage, daysAgo: 1, text: "nuevo")

        let report = try Retention(storage: storage, paths: paths, config: config(images: 30, text: 365)).run(now: now)

        XCTAssertEqual(report.framesDeleted, 1)
        XCTAssertEqual(report.imagesDeleted, 2)
        XCTAssertNil(try storage.frame(id: ancient.id))
        XCTAssertEqual(try storage.search(SearchQuery(text: "muy viejo")).count, 0, "search index entry removed too")
        XCTAssertEqual(try storage.count(), 2)
    }

    func testDryRunChangesNothingAndCountsOnce() throws {
        let storage = try Storage.inMemory()
        let old = try frame(storage, daysAgo: 400, text: "muy viejo")

        let report = try Retention(storage: storage, paths: paths, config: config(images: 30, text: 365)).run(now: now, dryRun: true)

        XCTAssertEqual(report, RetentionReport(imagesDeleted: 1, bytesFreed: 1_024, framesDeleted: 1, dryRun: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.image.path))
        XCTAssertNotNil(try storage.frame(id: old.id)?.imagePath)
    }

    func testFilesOutsideTheFramesFolderAreNeverDeleted() throws {
        let storage = try Storage.inMemory()
        let outside = root.appendingPathComponent("no-tocar.jpg")
        let old = try frame(storage, daysAgo: 40, text: "x", imageAt: outside)

        let report = try Retention(storage: storage, paths: paths, config: config(images: 30, text: 0)).run(now: now)

        XCTAssertEqual(report.imagesDeleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try storage.frame(id: old.id)?.imagePath, outside.path)
    }

    func testMissingFilesAreForgotten() throws {
        let storage = try Storage.inMemory()
        let old = try frame(storage, daysAgo: 40, text: "x")
        try FileManager.default.removeItem(at: old.image)

        let report = try Retention(storage: storage, paths: paths, config: config(images: 30, text: 0)).run(now: now)

        XCTAssertEqual(report.imagesDeleted, 1)
        XCTAssertEqual(report.bytesFreed, 0)
        XCTAssertNil(try storage.frame(id: old.id)?.imagePath)
    }

    func testZeroDaysKeepsEverything() throws {
        let storage = try Storage.inMemory()
        try frame(storage, daysAgo: 4_000, text: "x")
        XCTAssertTrue(try Retention(storage: storage, paths: paths, config: config(images: 0, text: 0)).run(now: now).isEmpty)
    }

    func testDefaultsKeepTextForeverAndImagesThirtyDays() {
        XCTAssertEqual(BitacoraConfig().imageRetentionDays, 30)
        XCTAssertEqual(BitacoraConfig().textRetentionDays, 0)
    }

    func testDiskUsageSumsFiles() throws {
        try Data(count: 1_500).write(to: paths.frames.appendingPathComponent("a.jpg"))
        try Data(count: 500).write(to: paths.frames.appendingPathComponent("b.jpg"))
        XCTAssertEqual(Retention.diskUsage(of: paths.frames), 2_000)
    }
}

final class LaunchAgentTests: XCTestCase {
    func testPropertyListRunsRecordAtLoginAndRestartsOnCrash() throws {
        let paths = DataPaths(root: URL(fileURLWithPath: "/Users/ana/.bitacora"))
        let plist = LaunchAgent(executable: URL(fileURLWithPath: "/Users/ana/.local/bin/bitacora"), paths: paths).propertyList()

        XCTAssertEqual(plist["Label"] as? String, "local.bitacora.record")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Users/ana/.local/bin/bitacora", "record", "--serve"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/Users/ana/.bitacora/logs/bitacora.log")
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["BITACORA_LAUNCHD"], "1")
        XCTAssertEqual(environment["BITACORA_HOME"], "/Users/ana/.bitacora")
        // Must serialize as a valid property list.
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    }
}
