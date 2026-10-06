# Design tokens de Helios

Sistema **Material 3 Expressive** con la marca de Helios. Es el de Ronda
(`Ronda/tokens`) con otra paleta, dos temas y sin la app.

`helios.tokens.json` es la única fuente de verdad. Todo lo demás se genera.

```bash
node tokens/build.mjs              # genera y valida
node tokens/build.mjs --contraste  # solo imprime la tabla de contraste
```

o, desde `panel/`:

```bash
npm run tokens
```

## Qué genera

| Archivo | Para qué |
|---|---|
| `panel/src/styles/tokens.gen.css` | `@theme` de Tailwind v4 (tema claro), el tema oscuro y las clases `.type-*` |
| `panel/src/theme/tokens.gen.ts` | Los mismos tokens como JS (motion, SVG, gráficos) |

Los dos llevan cabecera de "archivo generado". **No se editan a mano**: el
siguiente build los pisa.

## Color

Sale del logo (`brand/helios-logo.svg`):

| Rol | Claro | Oscuro | De dónde |
|---|---|---|---|
| `primary` | `#0040B8` | `#8FC8FF` | la acción: entre la palabra (`#002770`) y el rayo más oscuro |
| `primaryBright` | `#015CF1` | `#C0E3FF` | el rayo más oscuro (`#045EF3`) |
| `secondary` | `#0057D9` | `#A5D8FE` | entre los dos azules |
| lienzo (`surfaceContainerLowest`) | `#F3F6FB` | `#0A101C` | |
| tarjeta (`surfaceContainerLow`) | `#FFFFFF` | `#111A2B` | |
| texto (`onSurface`) | `#0F1A2E` | `#EEF3FB` | |

**Dos temas.** `color.role` es el claro, el de por defecto: una recepción
trabaja con luz de día. `color.roleDark` tiene las mismas claves (el build
falla si no). En el CSS el claro va en `@theme` y el oscuro redefine las
mismas variables en `:root[data-theme='dark']` y, con
`data-theme='auto'`, cuando el sistema pide oscuro. El panel lo cambia desde el
pie del menú (`src/lib/tema.ts`).

**Contraste.** El build comprueba WCAG 2.1 en las parejas que el panel pinta
de verdad, en los dos temas, y no escribe nada si alguna no llega: 4,5:1 para
texto, 3:1 para bordes e iconos inactivos.

Las superficies no siguen al pie de la letra el orden tonal de M3: se nombran
por su papel en el armazón (`shell.surface`). `surfaceContainerLowest` es el
lienzo y `surfaceContainerLow` la tarjeta que flota encima.

## Tipografía

**Outfit** (geométrica redondeada, cercana a la palabra del logotipo) para
display, headline y title; **Source Sans 3** (la de Ronda) para body y label.
Las dos se cargan de Google Fonts en `panel/src/styles.css`.

## De dónde salen los demás valores

Shape, tipografía, motion, state layers y tamaños de componente son los de
Ronda, verificados contra el código fuente de `androidx.compose.material3`:
`ExpressiveMotionTokens.kt`, `ShapeTokens.kt`, `TypeScaleTokens.kt`,
`StateTokens.kt`, `Button*Tokens.kt`, `FabBaselineTokens.kt`.

**Damping.** La spec da el *ratio* de amortiguación (ζ). framer-motion espera
el *coeficiente* `c = 2·ζ·√(k·m)`: `damping` ya es el coeficiente y
`dampingRatio` queda como referencia.
