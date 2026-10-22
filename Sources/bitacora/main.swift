import BitacoraCore
import Foundation

let usage = """
    bitacora — tu bitácora de pantalla, local y privada

    Uso:
      bitacora record [--serve] [--verbose]   Graba la pantalla (Ctrl-C para terminar)
      bitacora serve                          Sirve la API local en 127.0.0.1
      bitacora search <texto> [--app <app>] [--limit <n>]
      bitacora capture                        Guarda un cuadro ahora mismo
      bitacora stats                          Resumen de lo grabado
      bitacora doctor [--request]             Revisa (o pide) los permisos de macOS
      bitacora mcp                            Servidor MCP por stdio para asistentes de IA

    Datos en ~/.bitacora (o $BITACORA_HOME). Configuración opcional: ~/.bitacora/config.json
    """

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let arg = raw[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if ["app", "limit"].contains(name), index + 1 < raw.count {
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(arg)
            }
            index += 1
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func openStorage(_ paths: DataPaths) -> Storage {
    do {
        try paths.createDirectories()
        return try Storage(path: paths.database.path)
    } catch {
        fail("no se pudo abrir la base de datos: \(error)")
    }
}

func loadConfig(_ paths: DataPaths) -> BitacoraConfig {
    do {
        return try BitacoraConfig.load(from: paths)
    } catch {
        fail("config.json inválido: \(error)")
    }
}

let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

func printFrame(_ frame: FrameRecord) {
    let when = dateFormatter.string(from: frame.capturedAt)
    let app = frame.appName ?? "?"
    let title = frame.windowTitle.map { " — \($0)" } ?? ""
    print("#\(frame.id)  \(when)  [\(frame.trigger)]  \(app)\(title)")
    let excerpt = frame.text.replacingOccurrences(of: "\n", with: " ")
    if !excerpt.isEmpty { print("    \(excerpt.prefix(300))") }
}

func doctor(paths: DataPaths, request: Bool) {
    if request {
        ScreenCapturer.requestPermission()
        AccessibilityReader.requestTrust()
    }
    let screen = ScreenCapturer.hasPermission
    let ax = AccessibilityReader.isTrusted
    print("Grabación de pantalla: \(screen ? "✅ concedido" : "❌ falta (Ajustes → Privacidad y seguridad → Grabación de pantalla)")")
    print("Accesibilidad:         \(ax ? "✅ concedido" : "❌ falta (Ajustes → Privacidad y seguridad → Accesibilidad)")")
    print("Datos:                 \(paths.root.path)")
    if ax {
        let reader = AccessibilityReader()
        let context = reader.currentContext()
        let text = context.pid.map { reader.readText(pid: $0) } ?? ""
        print("Ventana actual:        \(context.appName ?? "?") — \(context.windowTitle ?? "(sin título)")")
        print("Texto accesible:       \(TextSelector.meaningfulLength(text)) caracteres")
    }
    if !screen || !ax {
        print("\nLos permisos se otorgan a la app que ejecuta bitacora (Terminal, iTerm, etc.).")
        print("Probá `bitacora doctor --request` para que macOS los pida.")
    }
}

func run() async {
    let args = Arguments(Array(CommandLine.arguments.dropFirst()))
    let paths = DataPaths()
    Log.verbose = args.flags.contains("verbose")

    switch args.positional.first {
    case "record":
        guard ScreenCapturer.hasPermission else {
            doctor(paths: paths, request: true)
            fail("falta el permiso de Grabación de pantalla")
        }
        let config = loadConfig(paths)
        let storage = openStorage(paths)
        let engine = CaptureEngine(config: config, paths: paths, storage: storage)
        if args.flags.contains("serve") {
            startServer(storage: storage, port: config.port)
        }
        await MainActor.run {
            let sources = EventSources(engine: engine, config: config)
            sources.start()
            Recorder.sources = sources
        }
        Log.info("grabando en \(paths.root.path) — Ctrl-C para terminar")
        signal(SIGINT) { _ in
            FileHandle.standardError.write(Data("\nbitácora cerrada\n".utf8))
            exit(0)
        }

    case "serve":
        let config = loadConfig(paths)
        startServer(storage: openStorage(paths), port: config.port)

    case "search":
        let text = args.positional.dropFirst().joined(separator: " ")
        let storage = openStorage(paths)
        do {
            let results = try storage.search(SearchQuery(
                text: text,
                app: args.options["app"],
                limit: args.options["limit"].flatMap(Int.init) ?? 20
            ))
            if results.isEmpty { print("Sin resultados.") }
            results.forEach(printFrame)
        } catch {
            fail("\(error)")
        }
        exit(0)

    case "capture":
        guard ScreenCapturer.hasPermission else { fail("falta el permiso de Grabación de pantalla (bitacora doctor)") }
        let config = loadConfig(paths)
        let storage = openStorage(paths)
        let engine = CaptureEngine(config: config, paths: paths, storage: storage)
        await engine.submit(Trigger(.manual))
        let outcome = await engine.tick()
        switch outcome {
        case .stored(let id, _, _, let source):
            if let frame = try? storage.frame(id: id) { printFrame(frame) }
            print("texto extraído por: \(source.rawValue)")
        case .skipped(let reason):
            print("No se guardó: \(reason)")
        default:
            print("No se guardó.")
        }
        exit(0)

    case "stats":
        let storage = openStorage(paths)
        do {
            print("Cuadros guardados: \(try storage.count())")
            if let last = try storage.lastCaptureDate() { print("Último: \(dateFormatter.string(from: last))") }
            let perApp = try storage.framesPerApp()
            if !perApp.isEmpty {
                print("\nPor app:")
                for row in perApp { print("  \(String(row.count).padding(toLength: 7, withPad: " ", startingAt: 0)) \(row.app)") }
            }
        } catch {
            fail("\(error)")
        }
        exit(0)

    case "doctor":
        doctor(paths: paths, request: args.flags.contains("request"))
        exit(0)

    case "mcp":
        // stdout carries only protocol messages; everything else goes to stderr.
        let server = MCPServer(storage: openStorage(paths))
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = server.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
        exit(0)

    case nil, "help":
        print(usage)
        exit(0)

    default:
        print(usage)
        exit(1)
    }
}

/// Keeps long-running objects alive while the main run loop spins.
enum Recorder {
    nonisolated(unsafe) static var sources: EventSources?
    nonisolated(unsafe) static var server: APIServer?
}

func startServer(storage: Storage, port: UInt16) {
    let server = APIServer(storage: storage, port: port)
    do { try server.start() } catch { fail("API: \(error)") }
    Recorder.server = server
}

Task { await run() }
RunLoop.main.run()
