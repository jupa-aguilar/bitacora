import Foundation
import Network

/// Minimal read-only HTTP/1.1 API on 127.0.0.1.
///
/// Routes:
/// - `GET /health`
/// - `GET /search?q=texto&app=Safari&from=<epoch>&to=<epoch>&limit=20`
/// - `GET /frames/<id>`
/// - `GET /frames/<id>/image`
///
/// Requests whose `Host` header is not localhost are rejected (DNS-rebinding protection), and no
/// CORS headers are sent, so web pages cannot read your history.
public final class APIServer: @unchecked Sendable {
    private let storage: Storage
    private let port: UInt16
    private let queue = DispatchQueue(label: "bitacora.api")
    private var listener: NWListener?

    public init(storage: Storage, port: UInt16) {
        self.storage = storage
        self.port = port
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready: Log.info("API listening on http://127.0.0.1:\(port)")
            case .failed(let error): Log.info("API failed: \(error)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.send(self.respond(toHead: head), on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Routing

    func respond(toHead head: String) -> HTTPResponse {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return .error(400, "bad request") }
        guard parts[0] == "GET" else { return .error(405, "only GET is supported") }

        let host = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst(5).trimmingCharacters(in: .whitespaces) ?? ""
        let hostname = host.split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost"].contains(hostname) else { return .error(403, "forbidden host") }

        guard let components = URLComponents(string: String(parts[1])) else { return .error(400, "bad url") }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        let segments = components.path.split(separator: "/").map(String.init)

        do {
            switch segments.first {
            case "health":
                return try .json(Health(status: "ok", frames: storage.count(), lastCapture: storage.lastCaptureDate()))
            case "search":
                let search = SearchQuery(
                    text: query["q"] ?? "",
                    app: query["app"].flatMap { $0.isEmpty ? nil : $0 },
                    from: query["from"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                    to: query["to"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                    limit: query["limit"].flatMap(Int.init) ?? 20
                )
                return try .json(storage.search(search))
            case "frames":
                guard segments.count >= 2, let id = Int64(segments[1]) else { return .error(400, "invalid frame id") }
                guard let frame = try storage.frame(id: id) else { return .error(404, "frame not found") }
                if segments.count == 3, segments[2] == "image" {
                    guard let path = frame.imagePath,
                          let data = FileManager.default.contents(atPath: path)
                    else { return .error(404, "image not found") }
                    return HTTPResponse(status: 200, reason: "OK", contentType: "image/jpeg", body: data)
                }
                return .json(frame)
            default:
                return .error(404, "not found")
            }
        } catch {
            return .error(500, "\(error)")
        }
    }
}

struct Health: Codable {
    let status: String
    let frames: Int
    let lastCapture: Date?
}

struct HTTPResponse {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, reason: "OK", contentType: "application/json; charset=utf-8", body: body)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        let reasons = [400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"]
        let body = (try? encoder.encode(["error": message])) ?? Data()
        return HTTPResponse(status: status, reason: reasons[status] ?? "Error", contentType: "application/json; charset=utf-8", body: body)
    }
}
