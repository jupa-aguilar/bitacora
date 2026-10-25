import ApplicationServices
import Foundation
import XCTest
@testable import BitacoraCore

final class CapturePolicyTests: XCTestCase {
    private let config = BitacoraConfig()

    func testDefaultsAfterFirstRealRecording() {
        XCTAssertEqual(config.minCaptureInterval, 5)
        XCTAssertEqual(config.duplicateThreshold, 0.03)
        XCTAssertEqual(config.snapshotMaxWidth, 1440)
        XCTAssertEqual(config.jpegQuality, 0.5)
    }

    func testIdenticalScreenIsDuplicateEvenAfterWindowChange() {
        // Browsers rewrite tab titles by themselves: window_focus fires but nothing visible changed.
        XCTAssertNotNil(CapturePolicy.visualSkipReason(trigger: .windowFocus, difference: 0, config: config))
        XCTAssertNotNil(CapturePolicy.visualSkipReason(trigger: .appSwitch, difference: 0.02, config: config))
        XCTAssertNil(CapturePolicy.visualSkipReason(trigger: .appSwitch, difference: 0.2, config: config))
    }

    func testVisualChecksUseTheirOwnThreshold() {
        XCTAssertNotNil(CapturePolicy.visualSkipReason(trigger: .visualChange, difference: 0.04, config: config))
        XCTAssertNil(CapturePolicy.visualSkipReason(trigger: .visualChange, difference: 0.06, config: config))
    }

    func testManualIsAlwaysKept() {
        XCTAssertNil(CapturePolicy.visualSkipReason(trigger: .manual, difference: 0, config: config))
        XCTAssertNil(textSkip(.manual, "a", "a", difference: 0))
    }

    func testIdleIsKeptUnlessNothingChanged() {
        XCTAssertNil(CapturePolicy.visualSkipReason(trigger: .idle, difference: 0, config: config))
        XCTAssertNotNil(textSkip(.idle, "a", "a", difference: 0.01))
        XCTAssertNotNil(textSkip(.idle, "", "", difference: 0), "a still screen without text adds nothing either")
        XCTAssertNil(textSkip(.idle, "a", "b", difference: 0.01), "the text changed")
        XCTAssertNil(textSkip(.idle, "a", "a", difference: 0.2), "the screen changed")
        XCTAssertNil(textSkip(.idle, "a", nil, difference: 0), "nothing stored yet in this run")
    }

    func testRepeatedTextIsSkipped() {
        XCTAssertNotNil(textSkip(.click, "hola", "hola"))
        XCTAssertNil(textSkip(.click, "hola mundo", "hola"))
        XCTAssertNil(textSkip(.click, "hola", nil))
        // No text at all (e.g. a video) is not "repeated text": the visual check already decided.
        XCTAssertNil(textSkip(.visualChange, "", ""))
    }

    private func textSkip(_ trigger: TriggerKind, _ text: String, _ previous: String?, difference: Double = 0.2) -> String? {
        CapturePolicy.textSkipReason(trigger: trigger, text: text, previousText: previous, difference: difference, config: config)
    }
}

final class BurstPolicyTests: XCTestCase {
    private let config = BitacoraConfig()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let chat = WindowContext(appName: "ChatGPT", bundleID: "com.openai.chat", windowTitle: "Redes")
    private let reply = (1...10).map { "línea \($0)" }.joined(separator: "\n")

    private func last(text: String) -> LastStoredFrame {
        LastStoredFrame(id: 7, bundleID: "com.openai.chat", windowTitle: "Redes", text: text,
                        imagePath: nil, burstStart: start)
    }

    private func replaces(_ trigger: TriggerKind = .visualChange, context: WindowContext? = nil,
                          text: String, previous: String? = nil, after seconds: TimeInterval = 10) -> Bool {
        CapturePolicy.replacesLast(trigger: trigger, context: context ?? chat, text: text,
                                   last: last(text: previous ?? reply), now: start.addingTimeInterval(seconds),
                                   config: config)
    }

    func testDefaults() {
        XCTAssertEqual(config.burstWindow, 120)
        XCTAssertEqual(config.burstMinTextOverlap, 0.9)
    }

    func testReplyBeingWrittenReplacesTheLastFrame() {
        XCTAssertTrue(replaces(text: reply + "\nlínea 11"))
    }

    func testVideoWithAChangingTimestampReplacesTheLastFrame() {
        // One line out of ten changed (the elapsed time): 90 % of the old text is still there.
        XCTAssertTrue(replaces(text: reply.replacingOccurrences(of: "línea 10", with: "1:02 / 12:40")))
    }

    func testScreensWithoutTextReplaceEachOther() {
        XCTAssertTrue(replaces(text: "", previous: ""))
    }

    func testLosingMoreTextAddsANewFrame() {
        let half = (1...5).map { "línea \($0)" }.joined(separator: "\n")
        XCTAssertFalse(replaces(text: half + "\notra cosa"))
    }

    func testOnlyVisualChecksReplace() {
        for trigger in [TriggerKind.click, .typingPause, .scrollStop, .appSwitch, .idle, .manual] {
            XCTAssertFalse(replaces(trigger, text: reply + "\nmás"), "\(trigger)")
        }
    }

    func testOtherWindowAddsANewFrame() {
        let other = WindowContext(appName: "ChatGPT", bundleID: "com.openai.chat", windowTitle: "Recetas")
        XCTAssertFalse(replaces(context: other, text: reply))
    }

    func testBurstsAreCappedByTheWindow() {
        XCTAssertTrue(replaces(text: reply + "\nmás", after: 119))
        XCTAssertFalse(replaces(text: reply + "\nmás", after: 120))
    }

    func testZeroWindowNeverReplaces() {
        var config = BitacoraConfig()
        config.burstWindow = 0
        XCTAssertFalse(CapturePolicy.replacesLast(trigger: .visualChange, context: chat, text: reply,
                                                  last: last(text: reply), now: start, config: config))
    }

    func testNoPreviousFrameNeverReplaces() {
        XCTAssertFalse(CapturePolicy.replacesLast(trigger: .visualChange, context: chat, text: reply,
                                                  last: nil, now: start, config: config))
    }

    func testTextOverlapIgnoresBlankAndRepeatedLines() {
        XCTAssertEqual(CapturePolicy.textOverlap(of: "a\n\n  \na\nb", in: "b\nc"), 0.5)
        XCTAssertEqual(CapturePolicy.textOverlap(of: "", in: "algo"), 1)
    }
}

/// Minimal in-memory accessibility tree.
private struct FakeNode: TextTreeNode {
    var role: String?
    var subrole: String?
    var texts: [String]
    var children: [FakeNode]

    init(_ role: String?, _ texts: [String] = [], subrole: String? = nil, _ children: [FakeNode] = []) {
        self.role = role
        self.subrole = subrole
        self.texts = texts
        self.children = children
    }
}

final class TextTreeWalkerTests: XCTestCase {
    private let walker = TextTreeWalker(maxNodes: 1_000, maxDepth: 20, maxCharacters: 10_000,
                                        deadline: Date().addingTimeInterval(60))

    /// Shaped like Chrome: toolbar and tab strip next to the page.
    private let chromeWindow = FakeNode("AXWindow", ["Docs - Google Chrome"], [
        FakeNode("AXGroup", [], [
            FakeNode("AXTabGroup", [], [FakeNode("AXRadioButton", ["Gmail - asunto privado"]), FakeNode("AXButton", ["Tab search"])]),
            FakeNode("AXTextField", ["Address and search bar"]),
            FakeNode("AXButton", ["Has access to this site"]),
        ]),
        FakeNode("AXGroup", [], [
            FakeNode("AXWebArea", ["Índices en PostgreSQL"], [
                FakeNode("AXStaticText", ["Un índice compuesto conviene cuando filtrás por varias columnas."]),
                FakeNode("AXTextField", ["contraseña123"], subrole: kAXSecureTextFieldSubrole),
            ]),
        ]),
    ])

    func testBrowserReadsOnlyThePage() {
        let text = walker.readContent(of: chromeWindow)
        XCTAssertTrue(text.contains("Un índice compuesto conviene"))
        XCTAssertFalse(text.contains("Gmail - asunto privado"), "other tabs must not leak into the text")
        XCTAssertFalse(text.contains("Address and search bar"))
        XCTAssertFalse(text.contains("Has access to this site"))
    }

    func testContentRootsAreThePagesInBrowsers() {
        let content = walker.content(of: chromeWindow)
        XCTAssertEqual(content.roots.map(\.role), ["AXWebArea"], "OCR is cropped to these, so tabs stay out")
        let notes = FakeNode("AXWindow", ["Notas"], [FakeNode("AXTextArea", ["Lista de compras"])])
        XCTAssertEqual(walker.content(of: notes).roots.map(\.role), ["AXWindow"])
    }

    func testPasswordFieldsAreNeverRead() {
        XCTAssertFalse(walker.readContent(of: chromeWindow).contains("contraseña123"))
    }

    func testNativeAppsReadTheWholeWindow() {
        let notes = FakeNode("AXWindow", ["Notas"], [
            FakeNode("AXOutline", ["Carpetas"]),
            FakeNode("AXTextArea", ["Lista de compras"]),
        ])
        XCTAssertEqual(walker.readContent(of: notes), "Notas\nCarpetas\nLista de compras")
    }

    /// Shaped like the Claude desktop app: an empty web view found first, the chat in another one.
    func testAppsWithSeveralWebAreasReadAllOfThem() {
        let claude = FakeNode("AXWindow", ["Claude"], [
            FakeNode("AXGroup", [], [FakeNode("AXWebArea", [], [FakeNode("AXGroup")])]),
            FakeNode("AXGroup", [], [
                FakeNode("AXGroup", [], [
                    FakeNode("AXWebArea", [], [FakeNode("AXStaticText", ["¿Cómo funciona Bitácora?"])]),
                ]),
            ]),
        ])
        XCTAssertEqual(walker.readContent(of: claude), "¿Cómo funciona Bitácora?")
    }

    func testEmptyWebAreasFallBackToTheWholeWindow() {
        let loading = FakeNode("AXWindow", ["Cargando…"], [
            FakeNode("AXButton", ["Recargar"]),
            FakeNode("AXWebArea", [], []),
        ])
        XCTAssertEqual(walker.readContent(of: loading), "Cargando…\nRecargar")
    }

    func testRepeatedStringsAppearOnce() {
        let window = FakeNode("AXWindow", [], [FakeNode("AXStaticText", ["Guardar"]), FakeNode("AXButton", ["Guardar"])])
        XCTAssertEqual(walker.collectText(from: [window]), "Guardar")
    }
}
