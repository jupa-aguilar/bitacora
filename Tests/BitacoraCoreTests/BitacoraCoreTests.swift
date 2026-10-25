import CoreGraphics
import CoreText
import Foundation
import SQLite3
import XCTest
@testable import BitacoraCore

final class FrameComparerTests: XCTestCase {
    private func thumbnail(_ width: Int = 64, _ height: Int = 40, _ pixel: (Int, Int) -> UInt8) -> GrayThumbnail {
        var pixels: [UInt8] = []
        for y in 0..<height { for x in 0..<width { pixels.append(pixel(x, y)) } }
        return GrayThumbnail(width: width, height: height, pixels: pixels)
    }

    func testIdenticalFramesScoreZero() {
        let a = thumbnail { x, y in UInt8((x * 3 + y * 5) % 256) }
        XCTAssertEqual(FrameComparer.score(a, a), 0)
    }

    func testCompletelyDifferentFramesScoreHigh() {
        let white = thumbnail { _, _ in 255 }
        let black = thumbnail { _, _ in 0 }
        XCTAssertGreaterThan(FrameComparer.score(white, black), 0.9)
    }

    func testSmallLocalChangeScoresBelowLargeChange() {
        let base = thumbnail { x, _ in x < 32 ? 240 : 30 }
        var tweaked = base.pixels
        for i in 0..<8 { tweaked[i] = 0 } // a few pixels: e.g. a blinking cursor
        let small = FrameComparer.score(base, GrayThumbnail(width: 64, height: 40, pixels: tweaked))
        let large = FrameComparer.score(base, thumbnail { x, _ in x < 32 ? 30 : 240 })
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThan(small, 0.05)
        XCTAssertGreaterThan(large, small * 5)
    }

    func testMismatchedSizesScoreOne() {
        XCTAssertEqual(FrameComparer.score(thumbnail(64, 40) { _, _ in 0 }, thumbnail(32, 20) { _, _ in 0 }), 1)
    }

    func testNoReferenceMeansFullDifference() {
        var comparer = FrameComparer()
        let frame = thumbnail { _, _ in 128 }
        XCTAssertEqual(comparer.difference(to: frame), 1)
        comparer.setReference(frame)
        XCTAssertEqual(comparer.difference(to: frame), 0)
    }

    func testThumbnailFromCGImageKeepsAspectRatio() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let thumb = try XCTUnwrap(GrayThumbnail.make(from: XCTUnwrap(context.makeImage()), width: 96))
        XCTAssertEqual(thumb.width, 96)
        XCTAssertEqual(thumb.height, 48)
        XCTAssertTrue(thumb.pixels.allSatisfy { $0 > 250 })
    }
}

final class TriggerTests: XCTestCase {
    func testHighestPriorityWins() {
        let now = Date()
        let reduced = TriggerReducer.reduce([
            Trigger(.click, date: now),
            Trigger(.appSwitch, date: now.addingTimeInterval(-1)),
            Trigger(.visualChange, date: now.addingTimeInterval(1)),
        ])
        XCTAssertEqual(reduced?.kind, .appSwitch)
    }

    func testTiesKeepMostRecent() {
        let now = Date()
        let later = now.addingTimeInterval(2)
        XCTAssertEqual(TriggerReducer.reduce([Trigger(.click, date: now), Trigger(.click, date: later)])?.date, later)
    }

    func testEmptyReducesToNil() {
        XCTAssertNil(TriggerReducer.reduce([]))
    }

    func testGateDebouncesExceptManual() {
        var gate = CaptureGate(minInterval: 2)
        let t0 = Date()
        XCTAssertTrue(gate.allows(Trigger(.click), now: t0))
        gate.markCaptured(at: t0)
        XCTAssertFalse(gate.allows(Trigger(.click), now: t0.addingTimeInterval(1)))
        XCTAssertTrue(gate.allows(Trigger(.manual), now: t0.addingTimeInterval(1)))
        XCTAssertTrue(gate.allows(Trigger(.click), now: t0.addingTimeInterval(2)))
    }

    func testIdleWaitsAFullIntervalAfterAnAttempt() {
        let t0 = Date()
        XCTAssertFalse(IdleSchedule.isDue(lastCapture: nil, lastIdleTrigger: nil, interval: 300, now: t0))
        XCTAssertFalse(IdleSchedule.isDue(lastCapture: t0, lastIdleTrigger: nil, interval: 300, now: t0.addingTimeInterval(299)))
        XCTAssertTrue(IdleSchedule.isDue(lastCapture: t0, lastIdleTrigger: nil, interval: 300, now: t0.addingTimeInterval(300)))
        // Idle attempt at 300 s was skipped (e.g. screen locked): not due again on the next tick.
        let attempt = t0.addingTimeInterval(300)
        XCTAssertFalse(IdleSchedule.isDue(lastCapture: t0, lastIdleTrigger: attempt, interval: 300, now: attempt.addingTimeInterval(0.25)))
        XCTAssertTrue(IdleSchedule.isDue(lastCapture: t0, lastIdleTrigger: attempt, interval: 300, now: attempt.addingTimeInterval(300)))
    }

    func testTriggerNamesAreSnakeCase() {
        XCTAssertEqual(TriggerKind.appSwitch.rawValue, "app_switch")
        XCTAssertEqual(TriggerKind.typingPause.rawValue, "typing_pause")
    }
}

final class TextSelectorTests: XCTestCase {
    func testRichAccessibilityTextSkipsOCR() async {
        let rich = String(repeating: "palabra ", count: 30)
        var ocrCalled = false
        let result = await TextSelector.choose(accessibility: rich, minAccessibilityChars: 100) {
            ocrCalled = true
            return "ocr"
        }
        XCTAssertEqual(result.source, .accessibility)
        XCTAssertFalse(ocrCalled)
    }

    func testThinAccessibilityFallsBackToOCR() async {
        let result = await TextSelector.choose(accessibility: "OK", minAccessibilityChars: 100) {
            "Texto reconocido en un lienzo que no expone accesibilidad"
        }
        XCTAssertEqual(result.source, .ocr)
    }

    func testThinAccessibilityKeptWhenOCRFails() async {
        struct Failure: Error {}
        let result = await TextSelector.choose(accessibility: "Hola", minAccessibilityChars: 100) { throw Failure() }
        XCTAssertEqual(result, ExtractedText(text: "Hola", source: .accessibility))
    }

    func testNothingFound() async {
        let result = await TextSelector.choose(accessibility: "  \n", minAccessibilityChars: 100) { "" }
        XCTAssertEqual(result.source, .none)
    }

    // Shaped like Excalidraw: the toolbar is exposed, the drawing is not.
    private let toolbar = (["Excalidraw", "Shapes", "Rectangle", "Diamond", "Ellipse", "Arrow", "Line", "Draw",
                            "Text", "Eraser", "Zoom in", "Zoom out", "Undo", "Redo", "Library", "Share"]
                           + (1...6).map { "Keep selected tool active \($0)" }).joined(separator: "\n")

    func testNothingNewInTheWindowAddsWhatOCRSees() async {
        let result = await TextSelector.choose(accessibility: toolbar, knownWords: [], minAccessibilityChars: 100) {
            "Shapes  Rectangle\nRouter de casa\nSwitch del laboratorio\nShapes"
        }
        XCTAssertEqual(result.source, .accessibilityAndOCR)
        XCTAssertEqual(result.text, toolbar + "\nRouter de casa\nSwitch del laboratorio")
    }

    func testNewAccessibilityTextSkipsOCR() async {
        var ocrCalled = false
        let result = await TextSelector.choose(accessibility: toolbar, knownWords: nil, minAccessibilityChars: 100) {
            ocrCalled = true
            return "Router de casa y switch del laboratorio"
        }
        XCTAssertEqual(result, ExtractedText(text: toolbar, source: .accessibility))
        XCTAssertFalse(ocrCalled)
    }

    func testOCRMisreadingKnownTextAddsNothing() async {
        // A chat scrolled in an app that exposes all of it: OCR wraps lines differently and misreads a few letters.
        let chat = "Un índice compuesto conviene cuando filtrás por varias columnas a la vez y el orden importa."
            + "\n" + String(repeating: "relleno ", count: 10)
        let result = await TextSelector.choose(accessibility: chat, knownWords: [], minAccessibilityChars: 100) {
            "Un índice compuest0 conviene cuando\nfiltrás por varias colunmas\n12:04"
        }
        XCTAssertEqual(result, ExtractedText(text: chat, source: .accessibility))
    }

    func testWordsTheWindowShowedBeforeAreNotAddedAgain() async {
        let known = Set(TextSelector.words(in: "Router de casa\nSwitch del laboratorio"))
        let result = await TextSelector.choose(accessibility: toolbar, knownWords: known, minAccessibilityChars: 100) {
            "Router de casa\nSwitch del laboratorio"
        }
        XCTAssertEqual(result, ExtractedText(text: toolbar, source: .accessibility))
    }

    func testNothingNewSurvivesOCRFailure() async {
        struct Failure: Error {}
        let result = await TextSelector.choose(accessibility: toolbar, knownWords: [], minAccessibilityChars: 100) {
            throw Failure()
        }
        XCTAssertEqual(result, ExtractedText(text: toolbar, source: .accessibility))
    }

    func testNewLinesNeedHalfTheirWordsUnknown() {
        let ocr = "Bastion Host privado\nhola mundo nuevo\nbastion host\n• → =\nok"
        XCTAssertEqual(TextSelector.newLines(in: ocr, known: ["hola", "mundo"]), "Bastion Host privado")
    }

    func testWordsIgnoreCaseAndAccents() {
        XCTAssertEqual(TextSelector.words(in: "Canción, ÍNDICE-2"), ["cancion", "indice", "2"])
    }

    func testMeaningfulLengthIgnoresWhitespace() {
        XCTAssertEqual(TextSelector.meaningfulLength(" a b\n c\t"), 3)
    }

    func testVisionOCRReadsRenderedText() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 900, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let text = NSAttributedString(string: "Bitacora funciona", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let image = try XCTUnwrap(context.makeImage())

        let recognized = try OCRReader(languages: ["es-ES", "en-US"]).recognize(image)
        XCTAssertTrue(recognized.lowercased().contains("funciona"), "OCR returned: \(recognized)")
    }
}

final class OCRRegionTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testRetinaPointsBecomePixels() {
        let rect = OCRRegion.pixelRect(for: CGRect(x: 100, y: 80, width: 600, height: 400), in: display,
                                       imageWidth: 3024, imageHeight: 1964)
        XCTAssertEqual(rect, CGRect(x: 200, y: 160, width: 1200, height: 800))
    }

    func testFramesAreClippedToTheBounds() {
        let rect = OCRRegion.pixelRect(for: CGRect(x: 1400, y: -50, width: 400, height: 200), in: display,
                                       imageWidth: 1512, imageHeight: 982)
        XCTAssertEqual(rect, CGRect(x: 1400, y: 0, width: 112, height: 150))
    }

    func testFramesOutsideTheBoundsAreIgnored() {
        XCTAssertNil(OCRRegion.pixelRect(for: CGRect(x: 2000, y: 0, width: 800, height: 600), in: display,
                                         imageWidth: 1512, imageHeight: 982))
    }

    func testPageInsideAWindowCapture() {
        // A window captured on its own at 2x: the page is relative to the window, not the display.
        let window = CGRect(x: 200, y: 100, width: 1000, height: 700)
        let page = CGRect(x: 200, y: 180, width: 1000, height: 620)
        XCTAssertEqual(OCRRegion.pixelRect(for: page, in: window, imageWidth: 2000, imageHeight: 1400),
                       CGRect(x: 0, y: 160, width: 2000, height: 1240))
    }
}

final class WindowMemoryTests: XCTestCase {
    func testFirstReadOfAWindowIsNew() {
        var memory = WindowMemory()
        XCTAssertNil(memory.knownWords(ifNothingNew: "Shapes\nShare", window: "excalidraw"))
        XCTAssertNotNil(memory.knownWords(ifNothingNew: "Share\nShapes", window: "excalidraw"))
        XCTAssertNil(memory.knownWords(ifNothingNew: "Shapes\nShare", window: "otra"))
    }

    func testPanelsThatComeAndGoAreNotNew() {
        // Excalidraw shows "Stroke width" only while something is selected.
        var memory = WindowMemory()
        _ = memory.knownWords(ifNothingNew: "Shapes\nShare", window: "w")
        XCTAssertNil(memory.knownWords(ifNothingNew: "Shapes\nShare\nStroke width", window: "w"), "a line never seen")
        XCTAssertNotNil(memory.knownWords(ifNothingNew: "Shapes", window: "w"))
        XCTAssertNotNil(memory.knownWords(ifNothingNew: "Shapes\nStroke width", window: "w"))
    }

    func testRemembersStoredWords() {
        var memory = WindowMemory()
        _ = memory.knownWords(ifNothingNew: "Shapes", window: "w")
        memory.remember("Shapes\nRouter de casa", window: "w")
        XCTAssertEqual(memory.knownWords(ifNothingNew: "Shapes", window: "w"), ["shapes", "router", "de", "casa"])
    }

    func testEmptyTextIsNeverNothingNew() {
        var memory = WindowMemory()
        _ = memory.knownWords(ifNothingNew: "", window: "w")
        XCTAssertNil(memory.knownWords(ifNothingNew: "", window: "w"))
    }

    func testOldWindowsAreForgotten() {
        var memory = WindowMemory()
        memory.maxWindows = 2
        _ = memory.knownWords(ifNothingNew: "a", window: "1")
        _ = memory.knownWords(ifNothingNew: "b", window: "2")
        _ = memory.knownWords(ifNothingNew: "c", window: "3")
        XCTAssertNil(memory.knownWords(ifNothingNew: "a", window: "1"))
    }
}

final class StorageTests: XCTestCase {
    private func makeStorage() throws -> Storage {
        let storage = try Storage.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try storage.insert(NewFrame(capturedAt: base, trigger: .appSwitch, appName: "Notas",
                                    windowTitle: "Reunión de presupuesto", text: "Revisar la canción del lanzamiento",
                                    textSource: .accessibility))
        try storage.insert(NewFrame(capturedAt: base.addingTimeInterval(60), trigger: .click, appName: "Safari",
                                    windowTitle: "Documentación", text: "SQLite FTS5 full text search",
                                    textSource: .ocr))
        return storage
    }

    func testSearchIgnoresAccents() throws {
        let hits = try makeStorage().search(SearchQuery(text: "cancion"))
        XCTAssertEqual(hits.map(\.appName), ["Notas"])
        XCTAssertTrue(hits[0].text.contains("«"), "snippet should highlight the match")
    }

    func testSearchMatchesPrefixesAndWindowTitles() throws {
        XCTAssertEqual(try makeStorage().search(SearchQuery(text: "presu")).count, 1)
    }

    func testSearchFiltersByApp() throws {
        let storage = try makeStorage()
        XCTAssertEqual(try storage.search(SearchQuery(text: "sqlite", app: "safari")).count, 1)
        XCTAssertEqual(try storage.search(SearchQuery(text: "sqlite", app: "Notas")).count, 0)
    }

    func testEmptyQueryListsRecentFirst() throws {
        XCTAssertEqual(try makeStorage().search(SearchQuery(text: "")).map(\.appName), ["Safari", "Notas"])
    }

    func testQuotesInQueryCannotBreakFTS() throws {
        XCTAssertNoThrow(try makeStorage().search(SearchQuery(text: "\"OR NEAR( * -")))
        XCTAssertEqual(SearchQuery.ftsExpression(from: "a \"b"), "\"a\"* \"\"\"b\"*")
    }

    func testFrameLookupAndStats() throws {
        let storage = try makeStorage()
        XCTAssertEqual(try storage.count(), 2)
        XCTAssertEqual(try storage.frame(id: 1)?.windowTitle, "Reunión de presupuesto")
        XCTAssertNil(try storage.frame(id: 99))
        XCTAssertEqual(try storage.lastCaptureDate(), Date(timeIntervalSince1970: 1_800_000_060))
    }

    func testReplaceKeepsIdAndTriggerAndReindexesText() throws {
        let storage = try makeStorage()
        try storage.replace(id: 2, with: NewFrame(capturedAt: Date(timeIntervalSince1970: 1_800_000_090),
                                                  trigger: .visualChange, appName: "Safari", windowTitle: "Documentación",
                                                  text: "SQLite WAL y checkpoints", textSource: .accessibility,
                                                  imagePath: "/tmp/nuevo.jpg", visualDifference: 0.2))
        let frame = try XCTUnwrap(try storage.frame(id: 2))
        XCTAssertEqual(frame.trigger, "click")
        XCTAssertEqual(frame.text, "SQLite WAL y checkpoints")
        XCTAssertEqual(frame.imagePath, "/tmp/nuevo.jpg")
        XCTAssertEqual(frame.capturedAt, Date(timeIntervalSince1970: 1_800_000_090))
        XCTAssertEqual(try storage.count(), 2)
        XCTAssertEqual(try storage.search(SearchQuery(text: "checkpoints")).map(\.id), [2])
        XCTAssertTrue(try storage.search(SearchQuery(text: "fts5")).isEmpty, "old text must leave the index")
    }

    func testVersionOneDatabaseGetsTheUpdateTrigger() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bitacora-v1-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let storage = try Storage(path: path)
            try storage.insert(NewFrame(capturedAt: Date(), trigger: .click, text: "texto viejo", textSource: .ocr))
        }
        // Simulate a database created before replacements existed.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER frames_au; PRAGMA user_version = 1;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let storage = try Storage(path: path)
        try storage.replace(id: 1, with: NewFrame(capturedAt: Date(), trigger: .visualChange, text: "texto nuevo", textSource: .ocr))
        XCTAssertEqual(try storage.search(SearchQuery(text: "nuevo")).count, 1)
        XCTAssertTrue(try storage.search(SearchQuery(text: "viejo")).isEmpty)
    }
}

final class PrivacyAndConfigTests: XCTestCase {
    func testExcludedAppsAndPrivateWindowsAreSkipped() {
        let filter = PrivacyFilter(config: BitacoraConfig())
        XCTAssertNotNil(filter.skipReason(for: WindowContext(bundleID: "com.1password.1password")))
        XCTAssertNotNil(filter.skipReason(for: WindowContext(bundleID: "com.google.Chrome", windowTitle: "Nueva pestaña - Incógnito")))
        XCTAssertNil(filter.skipReason(for: WindowContext(bundleID: "com.apple.Notes", windowTitle: "Ideas")))
    }

    func testPartialConfigKeepsDefaults() throws {
        let config = try JSONDecoder().decode(BitacoraConfig.self, from: Data(#"{"minCaptureInterval": 5}"#.utf8))
        XCTAssertEqual(config.minCaptureInterval, 5)
        XCTAssertEqual(config.port, BitacoraConfig().port)
        XCTAssertEqual(config.excludedBundleIDs, BitacoraConfig().excludedBundleIDs)
    }
}

final class APIServerTests: XCTestCase {
    private func server() throws -> APIServer {
        let storage = try Storage.inMemory()
        try storage.insert(NewFrame(capturedAt: Date(), trigger: .manual, appName: "Terminal",
                                    text: "hola bitácora", textSource: .ocr))
        return APIServer(storage: storage, port: 0)
    }

    private func request(_ path: String, host: String = "127.0.0.1:3939") throws -> HTTPResponse {
        try server().respond(toHead: "GET \(path) HTTP/1.1\r\nHost: \(host)")
    }

    func testSearchReturnsJSON() throws {
        let response = try request("/search?q=bitacora")
        XCTAssertEqual(response.status, 200)
        let body = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(body.contains("\"app_name\" : \"Terminal\""), body)
    }

    func testHealthAndMissingFrame() throws {
        XCTAssertEqual(try request("/health").status, 200)
        XCTAssertEqual(try request("/frames/42").status, 404)
        XCTAssertEqual(try request("/nope").status, 404)
    }

    func testForeignHostIsRejected() throws {
        XCTAssertEqual(try request("/health", host: "evil.example:3939").status, 403)
    }
}
