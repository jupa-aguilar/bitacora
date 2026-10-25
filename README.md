# Bitácora

[![Tests](https://github.com/jupa-aguilar/bitacora/actions/workflows/tests.yml/badge.svg)](https://github.com/jupa-aguilar/bitacora/actions/workflows/tests.yml)

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
- **Ráfagas:** mientras una respuesta se escribe sola o corre un video, los `visual_change` llegan uno tras otro en la misma ventana y con casi el mismo texto. Si el texto nuevo conserva al menos el 90 % de las líneas del último cuadro (`burstMinTextOverlap`) y la ráfaga empezó hace menos de 2 min (`burstWindow`), el cuadro nuevo reemplaza al anterior en lugar de sumarse: queda uno solo, con el estado final, y la captura vieja se borra.
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
git clone https://github.com/jupa-aguilar/bitacora.git && cd bitacora
scripts/install.sh          # compila, firma e instala en ~/.local/bin
bitacora doctor --request   # pide los permisos
```

`scripts/install.sh` también sirve para actualizar: reemplaza el binario sin cortar una grabación en curso y reinicia el arranque automático si está activo. Si tenés un certificado **Apple Development** (gratis: Xcode → Ajustes → Cuentas → Administrar certificados → **+**), el script firma con él, y macOS conserva los permisos entre versiones. Sin certificado se firma ad hoc y macOS puede pedirlos de nuevo tras cada actualización.

Sin cuenta de Apple también sirve un certificado local de firma llamado `Bitacora Local Signing` en el llavero de inicio de sesión: el script lo usa si no encuentra uno de Apple. macOS tiene que confiar en él para firmar código, si no, niega los permisos aunque estén activados (error `-3801`):

```bash
security find-certificate -c "Bitacora Local Signing" -p > /tmp/bitacora-cert.pem && security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/bitacora-cert.pem && rm /tmp/bitacora-cert.pem
```

Si otorgaste los permisos antes de confiar en el certificado, quitá «bitacora» de Grabación de pantalla y Accesibilidad y agregalo de nuevo.

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
bitacora install | uninstall            # arranque automático al iniciar sesión
bitacora clean [--dry-run]              # aplica la retención ahora
```

### Arranque automático

`bitacora install` crea un LaunchAgent (`~/Library/LaunchAgents/local.bitacora.record.plist`) que corre `bitacora record --serve` al iniciar sesión y lo reinicia si se cae. El registro queda en `~/.bitacora/logs/bitacora.log`. `bitacora uninstall` lo quita sin tocar tus datos.

Con launchd, macOS otorga los permisos al binario `bitacora`, no a Terminal. La primera vez:

1. `bitacora install`: macOS pide Grabación de pantalla y Accesibilidad para «bitacora».
2. Activalos en Ajustes → Privacidad y seguridad.
3. `bitacora install` de nuevo para que arranque con los permisos.

Si instalás con `scripts/install.sh` y un certificado Apple Development, los permisos se conservan entre versiones. Con firma ad hoc macOS puede pedirlos otra vez: repetí los pasos 2 y 3.

### Retención

Para que el disco no crezca sin límite, cada hora (y con `bitacora clean`) se aplican dos reglas:

| Opción | Por defecto | Qué borra |
|---|---|---|
| `imageRetentionDays` | 30 | las capturas más viejas; el texto sigue buscable |
| `textRetentionDays` | 0 (nunca) | cuadros completos, con su texto |

`bitacora clean --dry-run` muestra qué se borraría sin borrar nada, y `bitacora stats` muestra cuánto ocupan las capturas. Nunca se borra un archivo fuera de `~/.bitacora/frames`.

### API local (`http://127.0.0.1:3939`)

| Ruta | Respuesta |
|---|---|
| `GET /health` | estado y cantidad de cuadros |
| `GET /search?q=&app=&from=&to=&limit=` | resultados agrupados por momento, con fragmento resaltado (`from` y `to` en epoch) |
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
| `Retention.swift` | borrado de capturas y cuadros viejos |
| `LaunchAgent.swift` | arranque automático con launchd |

## Hoja de ruta

- [x] Servidor MCP para que asistentes de IA consulten tu historial
- [x] Retención automática (borrar capturas y cuadros viejos)
- [x] Agente de inicio de sesión (`launchd`)
- [ ] Texto de lienzos (Excalidraw y similares) con OCR
- [x] Menos cuadros mientras una app escribe sola o corre un video
- [ ] Varios monitores
- [ ] Interfaz de línea de tiempo
- [ ] Audio y transcripción local

El detalle, con lo que se vio en el uso real, está en [ROADMAP.md](ROADMAP.md).

## Licencia

MIT. Mirá [LICENSE](LICENSE).

Bitácora es una implementación independiente, escrita desde cero.
