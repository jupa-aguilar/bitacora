import Foundation

/// Model Context Protocol server over stdio (JSON-RPC 2.0, one message per line).
///
/// Lets AI assistants such as Claude search the history. Read-only: it never captures, edits or
/// deletes anything. Anything printed to stdout must be a protocol message, so logs go to stderr.
public final class MCPServer {
    private let storage: Storage
    private let timeZone: TimeZone

    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let maxFrameCharacters = 20_000

    public init(storage: Storage, timeZone: TimeZone = .current) {
        self.storage = storage
        self.timeZone = timeZone
    }

    /// Handles one incoming message and returns the response line, or nil for notifications.
    public func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return encode(errorResponse(id: NSNull(), code: -32700, message: "parse error")) }

        // Messages without an id are notifications (e.g. notifications/initialized): never answered.
        guard let id = message["id"] else { return nil }
        guard let method = message["method"] as? String else {
            return encode(errorResponse(id: id, code: -32600, message: "invalid request"))
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(resultResponse(id: id, result: initialize(params)))
        case "ping":
            return encode(resultResponse(id: id, result: [:]))
        case "tools/list":
            return encode(resultResponse(id: id, result: ["tools": Self.tools]))
        case "tools/call":
            return encode(resultResponse(id: id, result: callTool(params)))
        default:
            return encode(errorResponse(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: - Lifecycle

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "bitacora", "version": "0.3.0"],
            "instructions": """
                Bitácora guarda capturas de la pantalla del usuario (macOS) con el texto visible, la app, \
                el título de la ventana y la hora. Usá `buscar` para encontrar lo que el usuario vio o \
                hizo, `ver_cuadro` para leer un cuadro completo y `estadisticas` para un panorama general. \
                Las fechas van en ISO 8601; sin zona horaria se interpretan en la hora local del usuario \
                (\(timeZone.identifier)).
                """,
        ]
    }

    // MARK: - Tools

    static let tools: [[String: Any]] = [
        [
            "name": "buscar",
            "title": "Buscar en el historial de pantalla",
            "description": """
                Busca texto que apareció en la pantalla del usuario. Devuelve los cuadros que coinciden \
                con fecha, app, título de ventana y un fragmento resaltado. Con `texto` vacío lista los \
                cuadros más recientes del período, útil para resumir qué hizo el usuario.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "texto": ["type": "string", "description": "Palabras a buscar; cada una se busca como prefijo y sin acentos. Vacío = cuadros recientes."],
                    "app": ["type": "string", "description": "Nombre exacto de la app, por ejemplo Safari o Notas."],
                    "desde": ["type": "string", "description": "Inicio del período en ISO 8601, por ejemplo 2026-10-22 o 2026-10-22T09:00:00."],
                    "hasta": ["type": "string", "description": "Fin del período en ISO 8601."],
                    "limite": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Cantidad máxima de resultados (10 por defecto)."],
                ],
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "ver_cuadro",
            "title": "Ver un cuadro",
            "description": "Devuelve el texto completo y los metadatos de un cuadro por su id, y opcionalmente la captura de pantalla.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer", "description": "Id del cuadro, tal como lo devuelve `buscar`."],
                    "incluir_imagen": ["type": "boolean", "description": "Adjuntar la captura en JPEG (false por defecto)."],
                ],
                "required": ["id"],
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "estadisticas",
            "title": "Estadísticas del historial",
            "description": "Cantidad de cuadros guardados, fecha de la última captura y las apps más registradas.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]] as [String: Any],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ]

    private struct ToolError: Error {
        let message: String
    }

    private func callTool(_ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            switch name {
            case "buscar": return textResult(try search(arguments))
            case "ver_cuadro": return try frame(arguments)
            case "estadisticas": return textResult(try stats())
            default: return errorResult("herramienta desconocida: \(name)")
            }
        } catch let error as ToolError {
            return errorResult(error.message)
        } catch {
            return errorResult("error interno: \(error)")
        }
    }

    private func search(_ arguments: [String: Any]) throws -> String {
        let text = arguments["texto"] as? String ?? ""
        let app = (arguments["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let from = try date(arguments, "desde")
        let to = try date(arguments, "hasta", endOfDayIfDateOnly: true)
        let limit = min(50, max(1, (arguments["limite"] as? NSNumber)?.intValue ?? 10))

        let groups = try storage.searchGrouped(SearchQuery(text: text, app: app, from: from, to: to, limit: limit))
        if groups.isEmpty {
            return "Sin resultados" + (text.isEmpty ? " en ese período." : " para «\(text)».")
        }
        var lines = ["\(groups.count) resultado(s). Horas en \(timeZone.identifier)."]
        for group in groups {
            let record = group.frame
            lines.append("")
            lines.append(header(for: record))
            if group.frameCount > 1 {
                let ids = group.frameIds.map { "#\($0)" }.joined(separator: ", ")
                lines.append("\(group.frameCount) cuadros parecidos entre \(format(group.firstCapturedAt)) y \(format(group.lastCapturedAt)): \(ids)")
            }
            if let url = record.url { lines.append("url: \(url)") }
            let excerpt = record.text.replacingOccurrences(of: "\n", with: " ")
            if !excerpt.isEmpty { lines.append(excerpt) }
        }
        return lines.joined(separator: "\n")
    }

    private func frame(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let id = (arguments["id"] as? NSNumber)?.int64Value else {
            throw ToolError(message: "falta `id` (entero)")
        }
        guard let record = try storage.frame(id: id) else {
            throw ToolError(message: "no existe el cuadro #\(id)")
        }
        var lines = [header(for: record)]
        if let url = record.url { lines.append("url: \(url)") }
        if let difference = record.visualDifference {
            lines.append(String(format: "diferencia visual con el cuadro anterior: %.3f", difference))
        }
        lines.append("")
        if record.text.isEmpty {
            lines.append("(sin texto extraído)")
        } else if record.text.count > Self.maxFrameCharacters {
            lines.append(String(record.text.prefix(Self.maxFrameCharacters)))
            lines.append("… (texto recortado a \(Self.maxFrameCharacters) caracteres)")
        } else {
            lines.append(record.text)
        }

        var content: [[String: Any]] = [["type": "text", "text": lines.joined(separator: "\n")]]
        if arguments["incluir_imagen"] as? Bool == true {
            if let path = record.imagePath, let data = FileManager.default.contents(atPath: path) {
                content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"])
            } else {
                content.append(["type": "text", "text": "(la captura ya no está en disco)"])
            }
        }
        return ["content": content, "isError": false]
    }

    private func stats() throws -> String {
        var lines = ["Cuadros guardados: \(try storage.count())"]
        if let last = try storage.lastCaptureDate() {
            lines.append("Última captura: \(format(last))")
        }
        let perApp = try storage.framesPerApp()
        if !perApp.isEmpty {
            lines.append("Apps más registradas:")
            lines += perApp.map { "- \($0.app): \($0.count)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func header(for record: FrameRecord) -> String {
        var parts = ["[#\(record.id)] \(format(record.capturedAt))", record.appName ?? "app desconocida"]
        if let title = record.windowTitle, !title.isEmpty { parts.append(title) }
        parts.append("disparador: \(record.trigger)")
        parts.append("texto por: \(record.textSource)")
        return parts.joined(separator: " · ")
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func date(_ arguments: [String: Any], _ key: String, endOfDayIfDateOnly: Bool = false) throws -> Date? {
        guard let raw = arguments[key] as? String, !raw.isEmpty else { return nil }
        guard let parsed = Self.parseDate(raw, timeZone: timeZone) else {
            throw ToolError(message: "`\(key)` no es una fecha ISO 8601 válida: \(raw)")
        }
        if endOfDayIfDateOnly && parsed.dateOnly {
            return parsed.date.addingTimeInterval(86_400 - 0.001)
        }
        return parsed.date
    }

    /// Accepts full ISO 8601 timestamps, local date-times without zone, and plain dates (local midnight).
    static func parseDate(_ raw: String, timeZone: TimeZone) -> (date: Date, dateOnly: Bool)? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: raw) { return (date, false) }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: raw) { return (date, false) }
        }
        local.dateFormat = "yyyy-MM-dd"
        if let date = local.date(from: raw) { return (date, true) }
        return nil
    }

    private func textResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": false]
    }

    private func errorResult(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func resultResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
