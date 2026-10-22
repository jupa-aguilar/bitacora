import Foundation
import XCTest
@testable import BitacoraCore

final class SearchGroupingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ id: Int64, _ seconds: Double, app: String = "Chrome", title: String = "Flow Builder",
                     text: String) -> (record: FrameRecord, fullText: String) {
        let record = FrameRecord(
            id: id, capturedAt: t0.addingTimeInterval(seconds), trigger: "click", appName: app, bundleID: nil,
            windowTitle: title, url: nil, textSource: "accessibility", imagePath: nil, visualDifference: nil,
            text: "…«error»…"
        )
        return (record, text)
    }

    private let flow = "Save As New Version Show errors panel Zoom out Fit to canvas Zoom in Flow"

    func testSameWindowCloseInTimeAndSimilarTextCollapses() {
        let groups = ResultGrouper.group([
            row(427, 30, text: flow + " nodo A"),
            row(425, 0, text: flow + " nodo A"),
            row(426, 13, text: flow + " nodo B"),
        ], limit: 10)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].frameCount, 3)
        XCTAssertEqual(groups[0].frame.id, 427, "the best-ranked frame represents the group")
        XCTAssertEqual(groups[0].frameIds, [425, 426, 427])
        XCTAssertEqual(groups[0].firstCapturedAt, t0)
        XCTAssertEqual(groups[0].lastCapturedAt, t0.addingTimeInterval(30))
    }

    func testLongPauseStartsANewGroup() {
        let groups = ResultGrouper.group([row(1, 0, text: flow), row(2, 301, text: flow)], limit: 10)
        XCTAssertEqual(groups.map(\.frameCount), [1, 1])
    }

    func testDifferentTextInTheSameWindowStaysSeparate() {
        // A terminal keeps its title while showing unrelated commands.
        let groups = ResultGrouper.group([
            row(1, 0, app: "iTerm2", title: "zsh", text: "swift build error: cannot find type"),
            row(2, 20, app: "iTerm2", title: "zsh", text: "git push origin main everything up to date"),
        ], limit: 10)
        XCTAssertEqual(groups.count, 2)
    }

    func testDifferentWindowsNeverMerge() {
        let groups = ResultGrouper.group([
            row(1, 0, title: "Home | Salesforce", text: flow),
            row(2, 5, title: "Flow Builder", text: flow),
        ], limit: 10)
        XCTAssertEqual(groups.count, 2)
    }

    func testGroupsKeepRankOrderAndRespectLimit() {
        let groups = ResultGrouper.group([
            row(10, 500, title: "B", text: "segundo momento"),
            row(1, 0, title: "A", text: flow),
            row(2, 10, title: "A", text: flow),
            row(20, 900, title: "C", text: "tercer momento"),
        ], limit: 2)
        XCTAssertEqual(groups.map(\.frame.id), [10, 1])
        XCTAssertEqual(groups[1].frameCount, 2)
    }

    func testSimilarity() {
        XCTAssertEqual(ResultGrouper.similarity(["a", "b"], ["a", "b"]), 1)
        XCTAssertEqual(ResultGrouper.similarity(["a", "b"], ["b", "c"]), 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(ResultGrouper.similarity([], []), 1)
        XCTAssertEqual(ResultGrouper.words(in: "¡Error, ERROR! línea 42"), ["error", "línea", "42"])
    }

    func testStorageSearchGroupedCollapsesScrollingInOneChat() throws {
        let storage = try Storage.inMemory()
        for (i, extra) in ["", " más", " todavía más"].enumerated() {
            try storage.insert(NewFrame(capturedAt: t0.addingTimeInterval(Double(i) * 5), trigger: .scrollStop,
                                        appName: "Claude", windowTitle: "Claude",
                                        text: "conversación sobre factura de marzo y otros temas" + extra,
                                        textSource: .accessibility))
        }
        try storage.insert(NewFrame(capturedAt: t0.addingTimeInterval(3_600), trigger: .appSwitch,
                                    appName: "Google Chrome", windowTitle: "Facturas 2026",
                                    text: "factura de marzo pendiente", textSource: .accessibility))

        XCTAssertEqual(try storage.search(SearchQuery(text: "factura marzo")).count, 4, "raw search is unchanged")
        let groups = try storage.searchGrouped(SearchQuery(text: "factura marzo"))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.frameCount).sorted(), [1, 3])
    }
}
