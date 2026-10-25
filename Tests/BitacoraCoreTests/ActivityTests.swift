import Foundation
import XCTest
@testable import BitacoraCore

final class ActivitySummaryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-22 09:00 in Montevideo

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func sample(_ minutes: Double, _ app: String, _ title: String? = nil, text: String? = nil) -> ActivitySample {
        ActivitySample(capturedAt: at(minutes), app: app, title: title, text: text)
    }

    func testConsecutiveFramesOfAWindowMakeOneBlock() {
        let summary = ActivitySummary(samples: [
            sample(0, "Code", "main.swift"), sample(3, "Code", "main.swift"), sample(7, "Safari", "Docs"), sample(9, "Code", "main.swift"),
        ], from: at(0), to: at(12))
        XCTAssertEqual(summary.blocks.map(\.app), ["Code", "Safari", "Code"])
        XCTAssertEqual(summary.blocks[0].duration, 7 * 60)
        XCTAssertEqual(summary.blocks[2].end, at(12), "the last frame counts until the end of the period")
        XCTAssertEqual(summary.total, 12 * 60)
    }

    func testLongSilencesCountAsAway() {
        let summary = ActivitySummary(samples: [sample(0, "Code", "a"), sample(60, "Code", "a")], from: at(0), to: at(65))
        XCTAssertEqual(summary.blocks.count, 2, "an hour away splits the block")
        XCTAssertEqual(summary.blocks[0].end, at(10))
        XCTAssertEqual(summary.total, 15 * 60)
    }

    func testFramesBeforeThePeriodOnlyCountInsideIt() {
        let summary = ActivitySummary(samples: [sample(-5, "Mail", "Inbox"), sample(3, "Code", "a")], from: at(0), to: at(4))
        XCTAssertEqual(summary.blocks.first?.start, at(0))
        XCTAssertEqual(summary.blocks.first?.duration, 3 * 60)
    }

    func testTimelineHidesShortBlocksAndJoinsTheirNeighbours() {
        let code = [0, 5, 10, 15, 19.5, 25, 30, 35].map { sample($0, "Code", "a") }
        let summary = ActivitySummary(samples: code + [sample(19, "Slack", "general"), sample(40, "Safari", "Docs")],
                                      from: at(0), to: at(45))
        let timeline = summary.timeline(minDuration: 120)
        XCTAssertEqual(timeline.map(\.app), ["Code", "Safari"])
        XCTAssertEqual(timeline[0].start, at(0))
        XCTAssertEqual(timeline[0].end, at(40))
        XCTAssertEqual(timeline[0].duration, 39.5 * 60, "the glance at Slack is not counted for Code")
    }

    func testTotalsPerAppAndWindowLongestFirst() {
        let summary = ActivitySummary(samples: [
            sample(0, "Safari", "Docs"), sample(5, "Code", "a"), sample(10, "Code", "a"), sample(15, "Code", "a"),
            sample(20, "Code", "a"), sample(25, "Safari", "Mail"), sample(27, "Code", "b"),
        ], from: at(0), to: at(30))
        XCTAssertEqual(summary.perApp.map(\.app), ["Code", "Safari"])
        XCTAssertEqual(summary.perApp.map(\.duration), [23 * 60, 7 * 60] as [TimeInterval])
        XCTAssertEqual(summary.perWindow.first, ActivityTotal(app: "Code", title: "a", duration: 20 * 60))
    }

    func testTitlesIgnoreCountersPagesAndTheBrowserName() {
        XCTAssertEqual(ActivitySummary.normalizedTitle("(1716) Terraform desde 0 - YouTube", app: "YouTube"), "Terraform desde 0")
        XCTAssertEqual(ActivitySummary.normalizedTitle("Inbox (39,891) - Gmail - Google Chrome", app: "Google Chrome"), "Inbox - Gmail")
        XCTAssertEqual(ActivitySummary.normalizedTitle("Guia_Redes_AWS.pdf – Page 12 of 44", app: "Preview"), "Guia_Redes_AWS.pdf")
        XCTAssertEqual(ActivitySummary.normalizedTitle(nil, app: "Finder"), "")
    }

    func testMissingTitlesUseTheFirstLineOfText() {
        XCTAssertEqual(sample(0, "YouTube", nil, text: "(1716) Terraform desde 0\nGuide Home").title, "Terraform desde 0")
        XCTAssertEqual(sample(0, "Notas", "Ideas", text: "Otra cosa").title, "Ideas")
        XCTAssertEqual(sample(0, "Notas", nil).app, "Notas")
        XCTAssertEqual(ActivitySample(capturedAt: start, app: nil, title: nil).app, "app desconocida")
    }
}

final class ActivityPeriodTests: XCTestCase {
    private let montevideo = TimeZone(identifier: "America/Montevideo")!
    private let now = Date(timeIntervalSince1970: 1_792_699_200) // 2026-10-22 17:00 in Montevideo

    private func resolve(_ from: String?, _ to: String? = nil) -> (from: Date, to: Date)? {
        ActivityPeriod.resolve(from: from, to: to, timeZone: montevideo, now: now)
    }

    func testTodayRunsUntilNow() {
        let today = resolve(nil)
        XCTAssertEqual(today?.from, Date(timeIntervalSince1970: 1_792_638_000)) // 00:00
        XCTAssertEqual(today?.to, now)
        XCTAssertEqual(resolve("hoy")?.from, today?.from)
    }

    func testYesterdayAndDatesMeanWholeDays() {
        XCTAssertEqual(resolve("ayer")?.from, Date(timeIntervalSince1970: 1_792_551_600))
        XCTAssertEqual(resolve("ayer")?.to, Date(timeIntervalSince1970: 1_792_638_000))
        XCTAssertEqual(resolve("2026-10-19", "2026-10-21")?.to, Date(timeIntervalSince1970: 1_792_638_000), "the last day is included")
    }

    func testDateTimesAreUsedAsGiven() {
        let morning = resolve("2026-10-22T08:00", "2026-10-22T12:30")
        XCTAssertEqual(morning?.from, Date(timeIntervalSince1970: 1_792_666_800))
        XCTAssertEqual(morning?.to, Date(timeIntervalSince1970: 1_792_683_000))
    }

    func testInvalidPeriods() {
        XCTAssertNil(resolve("la semana pasada"))
        XCTAssertNil(resolve("2026-10-22T12:00", "2026-10-22T10:00"))
        XCTAssertNil(resolve("2026-10-23"), "the future has no activity yet")
    }
}

final class ActivityReportTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(ActivityReport.duration(20), "menos de 1 min")
        XCTAssertEqual(ActivityReport.duration(12 * 60), "12 min")
        XCTAssertEqual(ActivityReport.duration(65 * 60), "1 h 05 min")
    }

    func testLongPeriodsListDaysAndLongerBlocks() {
        let montevideo = TimeZone(identifier: "America/Montevideo")!
        let thursday = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-22 09:00
        let friday = thursday.addingTimeInterval(86_400)
        let summary = ActivitySummary(samples: [
            ActivitySample(capturedAt: thursday, app: "Code", title: "a"),
            ActivitySample(capturedAt: friday, app: "Safari", title: "Docs"),
        ], from: thursday.addingTimeInterval(-9 * 3600), to: friday.addingTimeInterval(3600))
        XCTAssertEqual(ActivityReport.defaultMinDuration(from: summary.from, to: summary.to), 600)
        let text = ActivityReport.render(summary, minDuration: 600, timeZone: montevideo)
        XCTAssertTrue(text.contains("Por día:"), text)
        XCTAssertTrue(text.contains("- jue 22/10: 10 min · Code 10 min"), text)
        XCTAssertTrue(text.contains("vie 23/10 09:00–09:10  10 min  Safari — Docs"), text)
    }

    func testEmptyPeriod() {
        let now = Date()
        let text = ActivityReport.render(ActivitySummary(samples: [], from: now.addingTimeInterval(-60), to: now),
                                         minDuration: 120, timeZone: .current)
        XCTAssertTrue(text.hasSuffix("No hay cuadros en ese período."))
    }
}
