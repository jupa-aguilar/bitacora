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
- [x] Medición con uso real (ver abajo)
- [x] Ráfagas de `visual_change`: el cuadro nuevo reemplaza al anterior (ver abajo)

## 1. Medir con uso real ✓

Medido el 25/10/2026 sobre los cuadros del 22/10 al 25/10. La primera prueba es la del 22/10 de 12:49 a 14:03, antes de los ajustes.

| | Primera prueba | Con los ajustes |
|---|---|---|
| Cuadros | 618 | 2767 |
| Cuadros por minuto con actividad | 11,2 | 3,7 |
| Capturas a menos de 5 s de la anterior | muchas | 0 |
| Tamaño medio de una captura | 218 KB | 107–140 KB |

- **Espacio por día:** 206 MB (23/10, 1501 cuadros), 66 MB (24/10) y 48 MB (25/10 hasta las 17 h). Antes era cerca de 1 GB. Con la retención de 30 días, las capturas ocuparían entre 2 y 6 GB como máximo.
- **Texto:** 91 % por accesibilidad, 9 % por OCR.
- **Búsquedas:** los 2767 cuadros son unos 1000 momentos distintos (misma app y ventana en menos de un minuto), unos 2,7 cuadros por momento. La agrupación de resultados los junta bien.
- **Disparadores:** `visual_change` es el que más cuadros genera (34 %). Por app: ChatGPT 38 %, Claude 50 % y YouTube 58 %. Casi siempre la ventana era la misma que la del cuadro anterior, y en más del 80 % de los casos el texto también era casi igual. Eso llevó al punto 3.
- **`idle` repetidos:** 47 de 92 cuadros `idle` tienen el mismo texto que el anterior, porque `idle` nunca se descarta. Ver el punto 7.

## 2. Texto de lienzos (Excalidraw y similares)

En apps que dibujan en un `<canvas>`, el árbol de accesibilidad sólo trae la interfaz ("Shapes", "Share", "Library"…). Como eso supera los 100 caracteres de `minAccessibilityChars`, no se usa OCR y lo dibujado no se puede buscar.

Idea: si el texto de accesibilidad es casi todo de la interfaz (frases que se repiten igual en cada cuadro de la misma app), hacer OCR también y combinar o preferir su resultado.

## 3. Ráfagas mientras una app escribe sola o corre un video ✓

Con ChatGPT se guardaron 81 cuadros casi iguales en media hora en una misma conversación, por `visual_change` mientras la respuesta se iba escribiendo. En YouTube pasaba lo mismo con el video avanzando. Cada cuadro tenía un poco más de texto, o una línea distinta, así que no se descartaba como idéntico.

**Lo que se hizo:** un `visual_change` en la misma ventana (misma app y mismo título) reemplaza al último cuadro guardado cuando se cumplen dos condiciones:

- el texto nuevo conserva al menos el 90 % de las líneas del anterior (`burstMinTextOverlap`), así que casi nada se pierde,
- la ráfaga empezó hace menos de 2 min (`burstWindow`), así que un video largo deja un cuadro cada 2 min y no uno solo.

El cuadro conserva su id y su disparador original. Toma la hora, el texto y la captura nuevos, y la captura vieja se borra. Los clics, el teclado, el scroll y los cambios de app siguen sumando cuadros como antes.

**Efecto esperado,** simulando la regla sobre los cuadros del 22/10 al 25/10:

| | Cuadros | ChatGPT | Claude | YouTube |
|---|---|---|---|---|
| Antes | 2781 | 852 | 558 | 337 |
| Con la regla | 2130 (−23 %) | 629 (−26 %) | 345 (−38 %) | 181 (−46 %) |

Falta confirmarlo con una grabación nueva.

**Para más adelante:** aplicar la misma regla también a `scroll_stop` y `click` bajaría el total a unos 1700 cuadros (−38 %). Queda afuera por ahora porque esos cuadros muestran otra parte de la pantalla aunque el texto sea el mismo.

## 4. Varios monitores

Hoy sólo se captura la pantalla principal (`captureMainDisplay`). Lo que pasa en un monitor externo o en el iPad con Universal Control (75 cuadros registrados) se pierde. Es lo que más falta en la captura.

## 5. Interfaz de línea de tiempo

Una página local servida por la API existente para recorrer el día: miniaturas, buscador y filtros por app y fecha. Hoy sólo se usa desde la terminal, desde Claude o con la API, que devuelve JSON crudo.

## 6. Audio y transcripción local

Lo más grande y pesado (modelos Whisper locales de varios cientos de MB). Queda para cuando lo anterior esté firme.

## 7. `idle` sin cambios

Los cuadros `idle` (cada 5 min sin capturas) nunca se descartan, aunque la pantalla y el texto sean los mismos que en el cuadro anterior. Pasa en 47 de 92 casos. Ocupa poco, pero se podría guardar sólo la hora, sin una captura nueva, o no guardar nada.
