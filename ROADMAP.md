# Hoja de ruta

Lo que falta, en el orden recomendado. Cada punto dice por qué importa y qué se vio en el uso real.

## Hecho

- [x] Servidor MCP para que asistentes de IA consulten tu historial
- [x] Arranque automático al iniciar sesión (`launchd`)
- [x] Retención automática de capturas y cuadros viejos
- [x] Menos cuadros repetidos: 5 s entre capturas, umbral de duplicado 0,03, descarte por texto idéntico y por cambio de título sin cambio visual
- [x] Capturas más livianas (1440 px, calidad 0,5)
- [x] En navegadores, leer sólo la página, sin pestañas ni barras
- [x] Resultados de búsqueda agrupados por momento
- [x] Tests en GitHub Actions

## 1. Medir con uso real

Antes de agregar funciones, confirmar con varios días de grabación que los ajustes rinden lo estimado:

- cuadros por hora de uso (objetivo: ~3 por minuto activo, antes eran ~8),
- espacio por día (antes ~1 GB por día de uso),
- calidad de las búsquedas: ¿cuántos resultados son momentos distintos?

Hasta el 25/10/2026 hay 3278 cuadros desde el 22/10. Las apps con más cuadros son ChatGPT (953), Google Chrome (858), Claude (496) y YouTube (402).

## 2. Texto de lienzos (Excalidraw y similares)

En apps que dibujan en un `<canvas>`, el árbol de accesibilidad sólo trae la interfaz ("Shapes", "Share", "Library"…). Como eso supera los 100 caracteres de `minAccessibilityChars`, no se usa OCR y lo dibujado no se puede buscar.

Idea: si el texto de accesibilidad es casi todo de la interfaz (frases que se repiten igual en cada cuadro de la misma app), hacer OCR también y combinar o preferir su resultado.

## 3. Ráfagas mientras una app escribe sola

Con ChatGPT se guardaron 81 cuadros casi iguales en media hora en una misma conversación, por `visual_change` mientras la respuesta se iba escribiendo. Cada cuadro tiene un poco más de texto, así que no se descarta como idéntico.

Ideas:

- esperar a que la pantalla deje de cambiar unos segundos antes de guardar por `visual_change`,
- no guardar si el texto nuevo sólo agrega al final del texto del cuadro anterior en la misma ventana, y reemplazar ese cuadro en lugar de sumar otro.

## 4. Varios monitores

Hoy sólo se captura la pantalla principal (`captureMainDisplay`). Lo que pasa en un monitor externo o en el iPad con Universal Control (75 cuadros registrados) se pierde. Es lo que más falta en la captura.

## 5. Interfaz de línea de tiempo

Una página local servida por la API existente para recorrer el día: miniaturas, buscador y filtros por app y fecha. Hoy sólo se usa desde la terminal, desde Claude o con la API, que devuelve JSON crudo.

## 6. Audio y transcripción local

Lo más grande y pesado (modelos Whisper locales de varios cientos de MB). Queda para cuando lo anterior esté firme.
