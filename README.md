# Bitácora

**Tu bitácora de pantalla: local, privada y open source.**

Bitácora registra lo que aparece en tu pantalla y lo convierte en texto que podés buscar. Todo se procesa en tu Mac: nada sale de tu computadora.

```bash
bitacora record --serve      # graba y expone la API local
bitacora search "presupuesto reunión"
```

## Cómo funciona

Bitácora no graba video continuo. Guarda un **cuadro** sólo cuando pasa algo que importa:

| Disparador | Cuándo |
|---|---|
| `manual` | `bitacora capture`, o al iniciar |
| `app_switch` | cambiaste de aplicación |
| `window_focus` | cambió la ventana o pestaña activa |
| `clipboard` | copiaste algo |
| `typing_pause` | dejaste de escribir (1,5 s) |
| `scroll_stop` | dejaste de desplazarte (0,8 s) |
| `click` | hiciste clic |
| `visual_change` | la pantalla cambió lo suficiente (muestreo cada 3 s) |
| `idle` | pasaron 5 min sin guardar nada |

```
eventos ─► cola de disparadores ─► el de mayor prioridad ─► antirrebote (5 s)
        ─► privacidad (bloqueo, apps excluidas, incógnito)
        ─► captura (ScreenCaptureKit) ─► ¿cambió? (histograma + SSIM)
        ─► texto: accesibilidad ─(poco texto)─► OCR (Vision) ─► ¿texto nuevo?
        ─► JPEG en disco + fila en SQLite con índice FTS5
```

- **¿Cambió la pantalla?** Se compara una miniatura en grises de 96 px con la del último cuadro guardado. La diferencia promedia la distancia de Hellinger entre histogramas (cambios globales) y 1 − SSIM por bloques de 8×8 (cambios locales). Por debajo de 0,03 el cuadro se descarta como duplicado, aunque haya cambiado el título de la ventana.
- **Texto:** primero se lee el árbol de accesibilidad de la ventana activa, que da el texto exacto y es barato. En navegadores y apps web se lee sólo la página, sin pestañas, barras ni extensiones. Si trae menos de 100 caracteres (lienzos, juegos, escritorio remoto) se usa OCR de Vision.
- **¿Texto nuevo?** Si el texto es idéntico al del último cuadro guardado, no se guarda: no agregaría nada a las búsquedas.
- **Búsqueda:** SQLite FTS5 con `remove_diacritics`, así que `cancion` encuentra "canción" y las palabras se buscan por prefijo.

## Privacidad

- No se registran teclas: del teclado sólo se observa *cuándo* dejás de escribir.
- Nunca se leen campos de contraseña (`AXSecureTextField`).
- No se captura con la pantalla bloqueada ni en gestores de contraseñas.
- Tampoco en ventanas cuyo título indica navegación privada o incógnito.
- La API escucha sólo en `127.0.0.1` y rechaza pedidos con otro `Host` (protección contra DNS rebinding).
- Los datos viven en `~/.bitacora`. Para borrar todo: `rm -rf ~/.bitacora`.

## Instalación

Requiere macOS 14 o superior y Xcode o las Command Line Tools (Swift 6).

```bash
git clone <tu-repo>/bitacora && cd bitacora
swift build -c release
cp .build/release/bitacora /usr/local/bin/
bitacora doctor --request   # pide los permisos
```

macOS otorga los permisos a la app que ejecuta `bitacora` (Terminal, iTerm…):

- **Grabación de pantalla** (obligatorio): para las capturas.
- **Accesibilidad** (recomendado): para el texto exacto, los títulos de ventana y los disparadores de clic, teclado y scroll.

## Uso

```bash
bitacora record [--serve] [--verbose]   # Ctrl-C para terminar
bitacora capture                        # un cuadro ahora
bitacora search <texto> [--app Safari] [--limit 50]
bitacora stats
bitacora serve                          # sólo la API
bitacora doctor [--request]
bitacora mcp                            # servidor MCP (lo lanza tu asistente)
```

### API local (`http://127.0.0.1:3939`)

| Ruta | Respuesta |
|---|---|
| `GET /health` | estado y cantidad de cuadros |
| `GET /search?q=&app=&from=&to=&limit=` | resultados con fragmento resaltado (`from` y `to` en epoch) |
| `GET /frames/<id>` | metadatos y texto completo |
| `GET /frames/<id>/image` | la captura en JPEG |

### Servidor MCP para asistentes de IA

`bitacora mcp` habla el [Model Context Protocol](https://modelcontextprotocol.io) por stdio, así que Claude u otro asistente compatible puede consultar tu historial cuando le preguntás algo como "¿qué leía ayer sobre índices?".

| Herramienta | Qué hace |
|---|---|
| `buscar` | texto, app y período (ISO 8601); con texto vacío lista lo más reciente |
| `ver_cuadro` | texto completo de un cuadro y, si se pide, la captura |
| `estadisticas` | cantidad de cuadros, última captura y apps más registradas |

Es de sólo lectura: no captura, no edita y no borra. El asistente recibe únicamente lo que devuelve cada consulta.

Claude Code:

```bash
claude mcp add --scope user bitacora -- ~/.local/bin/bitacora mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "bitacora": { "command": "/Users/<tu-usuario>/.local/bin/bitacora", "args": ["mcp"] }
  }
}
```

## Configuración

`~/.bitacora/config.json` es opcional y cualquier campo omitido usa su valor por defecto. Mirá [`config.example.json`](config.example.json).

## Desarrollo

```bash
swift build
swift test
BITACORA_HOME=/tmp/bitacora-dev swift run bitacora record --verbose
```

| Módulo | Responsabilidad |
|---|---|
| `Trigger.swift` | tipos de disparador, prioridad, antirrebote |
| `EventSources.swift` | observa el escritorio y emite disparadores |
| `CaptureEngine.swift` | el pipeline completo de un cuadro |
| `FrameComparer.swift` | miniatura en grises, histograma y SSIM |
| `Accessibility.swift` | contexto de ventana, texto accesible, filtros de privacidad |
| `TextExtraction.swift` | OCR con Vision y elección de la fuente de texto |
| `Storage.swift` | SQLite + FTS5 |
| `APIServer.swift` | HTTP de sólo lectura en loopback |
| `MCPServer.swift` | servidor MCP (JSON-RPC por stdio) |

## Hoja de ruta

- [ ] Varios monitores
- [ ] Retención automática (borrar cuadros viejos)
- [ ] Audio y transcripción local
- [ ] Interfaz de línea de tiempo
- [x] Servidor MCP para que asistentes de IA consulten tu historial
- [ ] Agente de inicio de sesión (`launchd`)

## Licencia

MIT. Mirá [LICENSE](LICENSE).

Bitácora es una implementación independiente, escrita desde cero.
