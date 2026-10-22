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

    func testManualAndIdleAreAlwaysKept() {
        for trigger in [TriggerKind.manual, .idle] {
            XCTAssertNil(CapturePolicy.visualSkipReason(trigger: trigger, difference: 0, config: config))
            XCTAssertNil(CapturePolicy.textSkipReason(trigger: trigger, text: "a", previousText: "a"))
        }
    }

    func testRepeatedTextIsSkipped() {
        XCTAssertNotNil(CapturePolicy.textSkipReason(trigger: .click, text: "hola", previousText: "hola"))
        XCTAssertNil(CapturePolicy.textSkipReason(trigger: .click, text: "hola mundo", previousText: "hola"))
        XCTAssertNil(CapturePolicy.textSkipReason(trigger: .click, text: "hola", previousText: nil))
        // No text at all (e.g. a video) is not "repeated text": the visual check already decided.
        XCTAssertNil(CapturePolicy.textSkipReason(trigger: .visualChange, text: "", previousText: ""))
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
