import BitacoraCore
import Foundation

let usage = """
    bitacora — tu bitácora de pantalla, local y privada

    Uso:
      bitacora record [--serve] [--verbose]   Graba la pantalla (Ctrl-C para terminar)
      bitacora serve                          Sirve la API local en 127.0.0.1
      bitacora search <texto> [--app <app>] [--limit <n>]
      bitacora actividad [desde] [hasta] [--min <minutos>]
                                              En qué estuviste: bloques por app y ventana, y totales
                                              (fechas ISO 8601, "hoy" o "ayer"; por defecto, hoy)
      bitacora capture                        Guarda un cuadro ahora mismo
      bitacora stats                          Resumen de lo grabado
      bitacora doctor [--request]             Revisa (o pide) los permisos de macOS
      bitacora mcp                            Servidor MCP por stdio para asistentes de IA
      bitacora install                        Graba sola al iniciar sesión (launchd)
      bitacora uninstall                      Quita el arranque automático
      bitacora clean [--dry-run]              Aplica la retención: borra capturas viejas

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
                if ["app", "limit", "min"].contains(name), index + 1 < raw.count {
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

let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter
}()

func printFrame(_ frame: FrameRecord, group: SearchGroup? = nil) {
    let when = dateFormatter.string(from: frame.capturedAt)
    let app = frame.appName ?? "?"
    let title = frame.windowTitle.map { " — \($0)" } ?? ""
    print("#\(frame.id)  \(when)  [\(frame.trigger)]  \(app)\(title)")
    if let group, group.frameCount > 1 {
        let range = "\(timeFormatter.string(from: group.firstCapturedAt))–\(timeFormatter.string(from: group.lastCapturedAt))"
        print("    (\(group.frameCount) cuadros parecidos, \(range))")
    }
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
    print("Arranque automático:   \(LaunchAgent.isLoaded ? "activo (bitacora uninstall para quitarlo)" : "inactivo (bitacora install)")")
    if ax {
        let reader = AccessibilityReader()
        let context = reader.currentContext()
        let text = context.pid.map { reader.readText(pid: $0) } ?? ""
        print("Ventana actual:        \(context.appName ?? "?") — \(context.windowTitle ?? "(sin título)")")
        print("Texto accesible:       \(TextSelector.meaningfulLength(text)) caracteres")
    }
    if !screen || !ax {
        print("\nLos permisos se otorgan a la app que ejecuta bitacora (Terminal, iTerm, etc.).")
        print("Con el arranque automático se otorgan al binario: \(executableURL.path)")
        print("Probá `bitacora doctor --request` para que macOS los pida.")
    }
}

func run() async {
    let args = Arguments(Array(CommandLine.arguments.dropFirst()))
    let paths = DataPaths()
    Log.verbose = args.flags.contains("verbose")

    switch args.positional.first {
    case "record":
        let underLaunchd = LaunchAgent.isRunningUnderLaunchd
        if let denial = await ScreenCapturer.verifyAccess() {
            if underLaunchd {
                // Nobody sees a terminal here: let macOS show its prompts, then exit cleanly so
                // launchd does not retry in a loop.
                ScreenCapturer.requestPermission()
                AccessibilityReader.requestTrust()
                Log.info("falta el permiso de Grabación de pantalla para \(executableURL.path) (\(denial)). Activalo en Ajustes → Privacidad y seguridad → Grabación de pantalla y después corré `bitacora install`.")
                exit(0)
            }
            doctor(paths: paths, request: true)
            fail("falta el permiso de Grabación de pantalla")
        }
        if underLaunchd && !AccessibilityReader.isTrusted {
            AccessibilityReader.requestTrust()
        }
        let config = loadConfig(paths)
        let storage = openStorage(paths)
        let engine = CaptureEngine(config: config, paths: paths, storage: storage)
        if args.flags.contains("serve") {
            startServer(storage: storage, port: config.port)
        }
        startRetention(Retention(storage: storage, paths: paths, config: config))
        await MainActor.run {
            let sources = EventSources(engine: engine, config: config)
            sources.start()
            Recorder.sources = sources
        }
        Log.info("grabando en \(paths.root.path)" + (underLaunchd ? " (arranque automático)" : " — Ctrl-C para terminar"))
        let stop: @convention(c) (Int32) -> Void = { _ in
            FileHandle.standardError.write(Data("\nbitácora cerrada\n".utf8))
            exit(0)
        }
        signal(SIGINT, stop)
        signal(SIGTERM, stop)

    case "serve":
        let config = loadConfig(paths)
        startServer(storage: openStorage(paths), port: config.port)

    case "search":
        let text = args.positional.dropFirst().joined(separator: " ")
        let storage = openStorage(paths)
        do {
            let groups = try storage.searchGrouped(SearchQuery(
                text: text,
                app: args.options["app"],
                limit: args.options["limit"].flatMap(Int.init) ?? 20
            ))
            if groups.isEmpty { print("Sin resultados.") }
            for group in groups { printFrame(group.frame, group: group) }
        } catch {
            fail("\(error)")
        }
        exit(0)

    case "actividad", "activity":
        let positional = Array(args.positional.dropFirst())
        guard let period = ActivityPeriod.resolve(from: positional.first, to: positional.dropFirst().first,
                                                  timeZone: .current) else {
            fail("período inválido: usá fechas ISO 8601 (2026-10-23 o 2026-10-23T09:00), \"hoy\" o \"ayer\"")
        }
        let storage = openStorage(paths)
        do {
            let samples = try storage.activitySamples(from: period.from.addingTimeInterval(-ActivitySummary.defaultMaxGap),
                                                      to: period.to)
            let summary = ActivitySummary(samples: samples, from: period.from, to: period.to)
            let minDuration = args.options["min"].flatMap(Double.init).map { $0 * 60 }
                ?? ActivityReport.defaultMinDuration(from: period.from, to: period.to)
            print(ActivityReport.render(summary, minDuration: minDuration, timeZone: .current))
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
            let config = loadConfig(paths)
            let usage = ByteCountFormatter.string(fromByteCount: Retention.diskUsage(of: paths.frames), countStyle: .file)
            let keep = config.imageRetentionDays > 0 ? "se borran a los \(config.imageRetentionDays) días" : "se guardan para siempre"
            print("Capturas en disco: \(usage) (\(keep))")
            let perApp = try storage.framesPerApp()
            if !perApp.isEmpty {
                print("\nPor app:")
                for row in perApp { print("  \(String(row.count).padding(toLength: 7, withPad: " ", startingAt: 0)) \(row.app)") }
            }
        } catch {
            fail("\(error)")
        }
        exit(0)

    case "clean":
        let config = loadConfig(paths)
        let dryRun = args.flags.contains("dry-run")
        do {
            let report = try Retention(storage: openStorage(paths), paths: paths, config: config).run(dryRun: dryRun)
            print(report.isEmpty ? "No hay nada para limpiar." : report.summary.prefix(1).uppercased() + report.summary.dropFirst() + ".")
        } catch {
            fail("\(error)")
        }
        exit(0)

    case "install":
        if executableURL.path.contains("/.build/") {
            fail("instalá primero el binario (por ejemplo en ~/.local/bin) y corré `bitacora install` desde ahí")
        }
        let agent = LaunchAgent(executable: executableURL, paths: paths)
        do {
            try agent.install()
        } catch {
            fail("\(error)")
        }
        print("Arranque automático activado: Bitácora graba al iniciar sesión y se reinicia si se cae.")
        print("Registro: \(agent.logFile.path)")
        print("""

            Si macOS pide permisos, activá «bitacora» en Ajustes → Privacidad y seguridad →
            Grabación de pantalla y Accesibilidad, y después volvé a correr `bitacora install`.
            Al actualizar el binario puede que macOS los pida de nuevo.
            """)
        exit(0)

    case "uninstall":
        do {
            try LaunchAgent.uninstall()
        } catch {
            fail("\(error)")
        }
        print("Arranque automático quitado. Tus datos siguen en \(paths.root.path).")
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
    nonisolated(unsafe) static var retentionTimer: DispatchSourceTimer?
}

/// Absolute path of this binary, as launchd and the privacy settings see it.
let executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()

/// Applies retention shortly after start and then every hour, off the main thread.
func startRetention(_ retention: Retention) {
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 10, repeating: 3_600)
    timer.setEventHandler {
        do {
            let report = try retention.run()
            if !report.isEmpty { Log.info("retención: \(report.summary)") }
        } catch {
            Log.info("retención falló: \(error)")
        }
    }
    timer.resume()
    Recorder.retentionTimer = timer
}

func startServer(storage: Storage, port: UInt16) {
    let server = APIServer(storage: storage, port: port)
    do { try server.start() } catch { fail("API: \(error)") }
    Recorder.server = server
}

Task { await run() }
RunLoop.main.run()
