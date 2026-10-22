import Foundation
import XCTest
@testable import BitacoraCore

final class MCPServerTests: XCTestCase {
    private let montevideo = TimeZone(identifier: "America/Montevideo")!

    private func makeServer() throws -> MCPServer {
        let storage = try Storage.inMemory()
        // 2026-10-22 15:42 and 18:05 in Montevideo (UTC-3).
        try storage.insert(NewFrame(
            capturedAt: Date(timeIntervalSince1970: 1_792_694_520), trigger: .appSwitch, appName: "Safari",
            windowTitle: "PostgreSQL B-tree indexes", url: "https://example.com/indices",
            text: "Cuándo conviene un índice compuesto en PostgreSQL", textSource: .accessibility
        ))
        try storage.insert(NewFrame(
            capturedAt: Date(timeIntervalSince1970: 1_792_702_500), trigger: .typingPause, appName: "Notas",
            windowTitle: "Ideas", text: "Lista de compras", textSource: .ocr
        ))
        return MCPServer(storage: storage, timeZone: montevideo)
    }

    private func call(_ server: MCPServer, _ message: [String: Any]) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let response = try XCTUnwrap(server.handle(line))
        XCTAssertFalse(response.contains("\n"), "each response must be a single line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

    private func tool(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool, content: [[String: Any]]) {
        let response = try call(server, ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                         "params": ["name": name, "arguments": arguments]])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return (text, result["isError"] as? Bool ?? false, content)
    }

    func testInitializeNegotiatesVersionAndAdvertisesTools() throws {
        let server = try makeServer()
        let response = try call(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-03-26", "capabilities": [:] as [String: Any],
                                                    "clientInfo": ["name": "test", "version": "1"]]])
        XCTAssertEqual(response["id"] as? Int, 1)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "bitacora")
    }

    func testUnknownProtocolVersionFallsBackToLatest() throws {
        let response = try call(try makeServer(), ["jsonrpc": "2.0", "id": "a", "method": "initialize",
                                                   "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual(response["id"] as? String, "a", "string ids must be echoed back")
        XCTAssertEqual((response["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedVersions[0])
    }

    func testNotificationsGetNoResponse() throws {
        XCTAssertNil(try makeServer().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    func testToolsListHasThreeReadOnlyTools() throws {
        let response = try call(try makeServer(), ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["buscar", "ver_cuadro", "estadisticas"])
        for tool in tools {
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
    }

    func testSearchFindsTextWithoutAccentsAndShowsLocalTime() throws {
        let result = try tool(try makeServer(), "buscar", ["texto": "indice"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("[#1] 2026-10-22 15:42:00 · Safari · PostgreSQL B-tree indexes"), result.text)
        XCTAssertTrue(result.text.contains("url: https://example.com/indices"))
        XCTAssertTrue(result.text.contains("«índice»"), result.text)
    }

    func testSearchByPeriodWithEmptyTextListsRecentFrames() throws {
        let server = try makeServer()
        let wholeDay = try tool(server, "buscar", ["desde": "2026-10-22", "hasta": "2026-10-22"])
        XCTAssertTrue(wholeDay.text.hasPrefix("2 resultado(s)"), wholeDay.text)
        let afternoon = try tool(server, "buscar", ["desde": "2026-10-22T17:00:00"])
        XCTAssertTrue(afternoon.text.hasPrefix("1 resultado(s)"), afternoon.text)
        XCTAssertTrue(afternoon.text.contains("Notas"))
    }

    func testSearchReportsBadDatesAsToolErrors() throws {
        let result = try tool(try makeServer(), "buscar", ["desde": "ayer"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("ISO 8601"))
    }

    func testFrameReturnsFullTextAndMissingImageNotice() throws {
        let server = try makeServer()
        let result = try tool(server, "ver_cuadro", ["id": 2, "incluir_imagen": true])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("Lista de compras"))
        XCTAssertTrue(result.text.contains("ya no está en disco"))
        XCTAssertTrue(try tool(server, "ver_cuadro", ["id": 99]).isError)
        XCTAssertTrue(try tool(server, "ver_cuadro").isError)
    }

    func testFrameAttachesImageWhenPresent() throws {
        let storage = try Storage.inMemory()
        let image = FileManager.default.temporaryDirectory.appendingPathComponent("bitacora-mcp-\(UUID()).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        try storage.insert(NewFrame(capturedAt: Date(), trigger: .manual, text: "x", textSource: .ocr, imagePath: image.path))
        let result = try tool(MCPServer(storage: storage), "ver_cuadro", ["id": 1, "incluir_imagen": true])
        let picture = try XCTUnwrap(result.content.first { $0["type"] as? String == "image" })
        XCTAssertEqual(picture["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(picture["data"] as? String, "/9j/2Q==")
    }

    func testStatsAndUnknownTool() throws {
        let server = try makeServer()
        let stats = try tool(server, "estadisticas")
        XCTAssertTrue(stats.text.contains("Cuadros guardados: 2"))
        XCTAssertTrue(stats.text.contains("- Safari: 1"))
        XCTAssertTrue(try tool(server, "borrar_todo").isError)
    }

    func testProtocolErrors() throws {
        let server = try makeServer()
        let unknown = try call(server, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let garbage = try XCTUnwrap(server.handle("{no es json"))
        XCTAssertTrue(garbage.contains("-32700"))
    }

    func testDateParsing() {
        XCTAssertEqual(MCPServer.parseDate("2026-10-22", timeZone: montevideo)?.dateOnly, true)
        XCTAssertEqual(MCPServer.parseDate("2026-10-22T15:42:00", timeZone: montevideo)?.date,
                       Date(timeIntervalSince1970: 1_792_694_520))
        XCTAssertEqual(MCPServer.parseDate("2026-10-22T18:42:00Z", timeZone: montevideo)?.date,
                       Date(timeIntervalSince1970: 1_792_694_520))
        XCTAssertNil(MCPServer.parseDate("mañana", timeZone: montevideo))
    }
}
