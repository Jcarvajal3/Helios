#!/usr/bin/env node
/**
 * Generador de design tokens de Helios.
 *
 *   node tokens/build.mjs        (o `npm run tokens` desde panel/)
 *
 * Lee `helios.tokens.json` (la única fuente de verdad) y escribe:
 *
 *   panel/src/theme/tokens.gen.ts      → tokens como JS (motion, SVG, gráficos)
 *   panel/src/styles/tokens.gen.css    → @theme de Tailwind v4 + tema oscuro + clases .type-*
 *
 * Los dos archivos están marcados como generados y NO se editan a mano.
 *
 * Es el generador de Ronda (tokens/build.mjs) sin la app: Helios es solo web,
 * así que no hay nombres de familia de React Native ni `Ronda-app/`. Lo nuevo
 * son dos cosas:
 *
 *   1. DOS TEMAS. `color.role` es el claro, el de por defecto; `color.roleDark`
 *      el oscuro, con las mismas claves. El CSS pone el claro en `@theme` y el
 *      oscuro en `[data-theme='dark']` (y en `[data-theme='auto']` si el sistema
 *      pide oscuro), redefiniendo las mismas variables.
 *   2. CONTRASTE. Antes de escribir nada comprueba WCAG 2.1 en las parejas que
 *      el panel pinta de verdad (texto sobre tarjeta, sobre lienzo, sobre el
 *      primario…) en los dos temas, y falla si alguna no llega: 4,5:1 para
 *      texto, 3:1 para lo que no es texto (bordes, iconos inactivos).
 *
 * Sin dependencias: solo Node.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const PANEL = join(ROOT, 'panel');

const T = JSON.parse(readFileSync(join(HERE, 'helios.tokens.json'), 'utf8'));

// `comment` es documentación para quien lee el JSON, no un token.
const strip = (o) =>
  Object.fromEntries(Object.entries(o).filter(([k]) => k !== 'comment'));

const BANNER = `/**
 * ARCHIVO GENERADO — NO EDITAR A MANO.
 *
 * Fuente: tokens/helios.tokens.json
 * Regenerar: node tokens/build.mjs   (o \`npm run tokens\` desde panel/)
 *
 * Basado en Material 3 Expressive. Los valores de shape, tipografía, motion,
 * state y sizing están verificados contra androidx.compose.material3.
 * Los colores salen del logo de Helios, no de la regla tonal de M3.
 */
`;

// ─── Utilidades ─────────────────────────────────────────────────────────────

const kebab = (s) => s.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase();
const rem = (px) => `${+(px / 16).toFixed(4)}rem`;
const ts = (v) => JSON.stringify(v, null, 2);

/**
 * La spec de M3 da el RATIO de amortiguación (zeta). framer-motion espera el
 * COEFICIENTE c = 2 * zeta * sqrt(k * m). Pasar 0.6 donde va 33.94 produce un
 * rebote descontrolado.
 */
const dampingCoefficient = (zeta, k, m) => +(2 * zeta * Math.sqrt(k * m)).toFixed(2);

// ─── Colores y contraste ────────────────────────────────────────────────────

const LIGHT = T.color.role;
const DARK = T.color.roleDark;

{
  const faltan = Object.keys(LIGHT).filter((k) => !(k in DARK));
  const sobran = Object.keys(DARK).filter((k) => !(k in LIGHT));
  if (faltan.length || sobran.length) {
    throw new Error(
      `color.roleDark tiene que tener las mismas claves que color.role. ` +
        `Faltan: ${faltan.join(', ') || '—'}. Sobran: ${sobran.join(', ') || '—'}.`,
    );
  }
}

/** Luminancia relativa de WCAG 2.1 de un hex #RRGGBB. */
function luminancia(hex) {
  const m = /^#([0-9a-f]{6})$/i.exec(hex);
  if (!m) throw new Error(`«${hex}» no es un color #RRGGBB.`);
  const n = parseInt(m[1], 16);
  const canal = (c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  const r = canal((n >> 16) & 255);
  const g = canal((n >> 8) & 255);
  const b = canal(n & 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contraste(a, b) {
  const [x, y] = [luminancia(a), luminancia(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}

/**
 * Las parejas que el panel pinta de verdad: [texto, fondo, mínimo].
 * 4,5 es texto normal (AA); 3 es lo que no es texto o es texto grande.
 */
const PAREJAS = [
  ['onSurface', 'surfaceContainerLow', 4.5],
  ['onSurface', 'surfaceContainerLowest', 4.5],
  ['onSurface', 'surfaceContainerHigh', 4.5],
  ['onSurfaceVariant', 'surfaceContainerLow', 4.5],
  ['onSurfaceVariant', 'surfaceContainerLowest', 4.5],
  ['onSurfaceVariant', 'surfaceContainerHigh', 4.5],
  ['onSurfaceFaint', 'surfaceContainerLow', 4.5],
  ['primary', 'surfaceContainerLow', 4.5],
  ['primary', 'surfaceContainerLowest', 4.5],
  ['onPrimary', 'primary', 4.5],
  ['onPrimary', 'primaryBright', 4.5],
  ['onPrimaryContainer', 'primaryContainer', 4.5],
  ['onSecondary', 'secondary', 4.5],
  ['onSecondaryContainer', 'secondaryContainer', 4.5],
  ['error', 'surfaceContainerLow', 4.5],
  ['onError', 'error', 4.5],
  ['onErrorContainer', 'errorContainer', 4.5],
  ['warning', 'surfaceContainerLow', 4.5],
  ['onWarning', 'warning', 4.5],
  ['onWarningContainer', 'warningContainer', 4.5],
  ['success', 'surfaceContainerLow', 4.5],
  ['onSuccess', 'success', 4.5],
  ['onSuccessContainer', 'successContainer', 4.5],
  ['onInverseSurface', 'inverseSurface', 4.5],
  ['logoWordmark', 'surfaceContainerLowest', 4.5],
  ['logoWordmark', 'surface', 4.5],
  ['placeholder', 'surfaceContainerLow', 3],
  ['outline', 'surfaceContainerLow', 3],
];

function validarContraste() {
  const filas = [];
  const fallos = [];
  for (const [tema, roles] of [['claro', LIGHT], ['oscuro', DARK]]) {
    for (const [texto, fondo, minimo] of PAREJAS) {
      const c = contraste(roles[texto], roles[fondo]);
      filas.push({ tema, par: `${texto} / ${fondo}`, c, minimo });
      if (c < minimo) fallos.push(`${tema}: ${texto} (${roles[texto]}) sobre ${fondo} (${roles[fondo]}) = ${c.toFixed(2)}:1, pide ${minimo}:1`);
    }
  }
  return { filas, fallos };
}

// ─── Tipografía y motion ────────────────────────────────────────────────────

const typeRoles = Object.entries(strip(T.type));

/** Rol tipográfico expandido. */
const resolvedType = Object.fromEntries(
  typeRoles.map(([role, v]) => {
    if (!(v.family in T.font.family)) {
      throw new Error(`El rol tipográfico ${role} pide la familia «${v.family}», que font.family no define.`);
    }
    return [
      role,
      {
        family: v.family, // 'display' | 'body'
        fontSize: v.size,
        lineHeight: v.line,
        letterSpacing: v.tracking,
        fontWeight: v.weight,
      },
    ];
  }),
);

const springs = Object.fromEntries(
  ['spatial', 'effects'].map((kind) => [
    kind,
    Object.fromEntries(
      Object.entries(strip(T.motion.spring[kind])).map(([speed, s]) => [
        speed,
        {
          stiffness: s.stiffness,
          mass: s.mass,
          damping: dampingCoefficient(s.damping, s.stiffness, s.mass),
          dampingRatio: s.damping,
        },
      ]),
    ),
  ]),
);

/**
 * Armazón: `surface` y `radius` guardan NOMBRES de rol, no valores. Se
 * resuelven aquí, una vez por tema: un nombre mal escrito revienta el build en
 * vez de colarse como `undefined` hasta la pantalla.
 */
function lookup(table, name, what) {
  if (!(name in table)) {
    throw new Error(`shell: "${name}" no existe en ${what}. Revisa helios.tokens.json.`);
  }
  return table[name];
}

const superficiesDe = (roles) =>
  Object.fromEntries(
    Object.entries(strip(T.shell.surface)).map(([k, name]) => [k, lookup(roles, name, 'color.role')]),
  );

const resolvedShell = {
  surface: superficiesDe(LIGHT),
  radius: Object.fromEntries(
    Object.entries(strip(T.shell.radius)).map(([k, name]) => [k, lookup(strip(T.shape), name, 'shape')]),
  ),
  shapeKey: strip(T.shell.radius),
  padding: strip(T.shell.padding),
  size: strip(T.shell.size),
  gap: strip(T.shell.gap),
};

// ─── tokens.gen.ts ──────────────────────────────────────────────────────────

function buildTs() {
  const size = { ...strip(T.size), button: strip(T.size.button) };

  return `${BANNER}
// ─── Color ──────────────────────────────────────────────────────────────────

/** Hex crudos del logo. Prefiere \`colorRoles\` en componentes. */
export const brand = ${ts(T.color.brand)} as const;

/**
 * Roles semánticos M3 del tema CLARO, el de por defecto. En el DOM manda el
 * CSS (\`var(--color-*)\`, que cambia con el tema); esto es para lo que no
 * puede leer una variable, como un canvas.
 */
export const colorRoles = ${ts(LIGHT)} as const;

/** Los mismos roles en el tema oscuro. */
export const colorRolesDark = ${ts(DARK)} as const;

/** Degradados del sol del logo, listos para CSS o SVG. */
export const gradients = ${ts(T.color.gradient)} as const;

// ─── Tipografía ─────────────────────────────────────────────────────────────

export const fontFamilies = ${ts({
    display: T.font.family.display.css,
    body: T.font.family.body.css,
  })} as const;

export const fontWeights = ${ts(T.font.weight)} as const;

/** Los 15 roles tipográficos de M3 x 2 énfasis. \`family\` + \`fontWeight\` con \`fontFamilies\`. */
export const type = ${ts(resolvedType)} as const;

export type TypeRole = keyof typeof type;

// ─── Shape ──────────────────────────────────────────────────────────────────

export const shape = ${ts(strip(T.shape))} as const;

export type ShapeKey = keyof typeof shape;

// ─── Espaciado y layout ─────────────────────────────────────────────────────

/** Grid de 4dp de M3. La clave es el multiplicador: \`space[4] === 16 === p-4\`. */
export const space = ${ts(strip(T.space))} as const;

export const layout = ${ts(strip(T.layout))} as const;

// ─── Armazón ────────────────────────────────────────────────────────────────

/**
 * La capa semántica que comparten todas las pantallas: qué superficie, qué
 * radio, qué medida y qué hueco le toca a cada tipo de pieza. Las superficies
 * son las del tema claro; en el DOM se leen del CSS, que cambia con el tema.
 */
export const shell = ${ts(resolvedShell)} as const;

// ─── Tamaños de componente ──────────────────────────────────────────────────

export const buttonSizes = ${ts(size.button)} as const;

export type ButtonSize = keyof typeof buttonSizes;

export const fabSizes = ${ts(size.fab)} as const;

export const iconSizes = ${ts(size.icon)} as const;

// ─── Motion ─────────────────────────────────────────────────────────────────

/**
 * Los 6 muelles de M3 Expressive. \`damping\` ya viene como COEFICIENTE, que es
 * lo que espera el spring de framer-motion; \`dampingRatio\` es el de la spec.
 */
export const spring = ${ts(springs)} as const;

export const duration = ${ts(strip(T.motion.duration))} as const;

/** Curvas de M3 como tuplas [x1, y1, x2, y2]. */
export const easing = ${ts(T.motion.easing)} as const;

export const pressScale = ${ts(strip(T.motion.pressScale))} as const;

// ─── State layers ───────────────────────────────────────────────────────────

/** Opacidad de la capa de estado (overlay del color de contenido). */
export const stateLayer = ${ts(strip(T.state))} as const;
`;
}

// ─── tokens.gen.css (Tailwind v4) ───────────────────────────────────────────

/** Las variables de color de un tema: roles y superficies del armazón. */
function variablesDeColor(roles, sangria) {
  const L = [];
  for (const [k, v] of Object.entries(roles)) L.push(`${sangria}--color-${kebab(k)}: ${v};`);
  for (const [k, v] of Object.entries(superficiesDe(roles))) L.push(`${sangria}--color-shell-${kebab(k)}: ${v};`);
  return L;
}

function buildCss() {
  const L = [];
  L.push('/*');
  L.push(' * ARCHIVO GENERADO — NO EDITAR A MANO.');
  L.push(' * Fuente: tokens/helios.tokens.json · Regenerar: npm run tokens');
  L.push(' *');
  L.push(" * El tema claro es el de por defecto y vive en @theme. El oscuro redefine las");
  L.push(" * mismas variables en [data-theme='dark'] y, con [data-theme='auto'], cuando");
  L.push(' * el sistema pide oscuro. Las utilidades de Tailwind leen var(--color-*), así');
  L.push(' * que cambian solas con el tema.');
  L.push(' */');
  L.push('');
  L.push('@theme {');

  L.push('  /* ── Color (tema claro) ────────────────────────────────────────── */');
  for (const [k, v] of Object.entries(LIGHT)) L.push(`  --color-${kebab(k)}: ${v};`);
  L.push('');
  for (const [k, v] of Object.entries(T.color.brand)) L.push(`  --color-brand-${kebab(k)}: ${v};`);

  L.push('');
  L.push('  /* ── Shape ─────────────────────────────────────────────────────── */');
  for (const [k, v] of Object.entries(strip(T.shape))) L.push(`  --radius-${kebab(k)}: ${v}px;`);

  L.push('');
  L.push('  /* ── Tipografía ────────────────────────────────────────────────── */');
  L.push(`  --font-display: ${T.font.family.display.css};`);
  L.push(`  --font-body: ${T.font.family.body.css};`);
  L.push('');
  for (const [role, v] of Object.entries(resolvedType)) {
    const n = kebab(role);
    L.push(`  --text-${n}: ${rem(v.fontSize)};`);
    L.push(`  --text-${n}--line-height: ${rem(v.lineHeight)};`);
    L.push(`  --text-${n}--letter-spacing: ${rem(v.letterSpacing)};`);
    L.push(`  --text-${n}--font-weight: ${v.fontWeight};`);
  }

  L.push('');
  L.push('  /* ── Armazón ───────────────────────────────────────────────────── */');
  for (const [k, v] of Object.entries(resolvedShell.surface)) L.push(`  --color-shell-${kebab(k)}: ${v};`);
  for (const [k, v] of Object.entries(resolvedShell.radius)) L.push(`  --radius-shell-${kebab(k)}: ${v}px;`);
  for (const [k, v] of Object.entries(resolvedShell.padding)) L.push(`  --spacing-shell-pad-${kebab(k)}: ${v}px;`);
  for (const [k, v] of Object.entries(resolvedShell.size)) L.push(`  --spacing-shell-${kebab(k)}: ${v}px;`);
  for (const [k, v] of Object.entries(resolvedShell.gap)) L.push(`  --spacing-shell-gap-${kebab(k)}: ${v}px;`);

  L.push('');
  L.push('  /* ── Motion (curvas y duraciones) ──────────────────────────────── */');
  for (const [k, v] of Object.entries(strip(T.motion.duration))) L.push(`  --duration-${kebab(k)}: ${v}ms;`);
  for (const [k, v] of Object.entries(T.motion.easing)) L.push(`  --ease-${kebab(k)}: cubic-bezier(${v.join(', ')});`);

  L.push('');
  L.push('  /* ── Tamaños de componente ─────────────────────────────────────── */');
  for (const [k, v] of Object.entries(strip(T.size.button))) L.push(`  --height-btn-${k}: ${v.height}px;`);
  for (const [k, v] of Object.entries(T.size.fab)) L.push(`  --height-fab-${k}: ${v.container}px;`);
  L.push(`  --height-touch: ${T.layout.touchTarget}px;`);
  L.push('}');

  L.push('');
  L.push('/* ── Tema oscuro ──────────────────────────────────────────────────── */');
  L.push(":root[data-theme='dark'] {");
  L.push('  color-scheme: dark;');
  L.push(...variablesDeColor(DARK, '  '));
  L.push('}');
  L.push('');
  L.push('@media (prefers-color-scheme: dark) {');
  L.push("  :root[data-theme='auto'] {");
  L.push('    color-scheme: dark;');
  L.push(...variablesDeColor(DARK, '    '));
  L.push('  }');
  L.push('}');

  L.push('');
  L.push('/*');
  L.push(' * Valores que no pertenecen a un namespace de Tailwind. Viven en :root');
  L.push(' * para que el JS los pueda leer, pero no generan utilidades.');
  L.push(' */');
  L.push(':root {');
  L.push('  color-scheme: light;');
  for (const kind of ['spatial', 'effects']) {
    for (const [speed, s] of Object.entries(springs[kind])) {
      L.push(`  --spring-${kind}-${speed}-stiffness: ${s.stiffness};`);
      L.push(`  --spring-${kind}-${speed}-damping: ${s.damping};`);
      L.push(`  --spring-${kind}-${speed}-mass: ${s.mass};`);
    }
  }
  L.push('');
  for (const [k, v] of Object.entries(strip(T.state))) L.push(`  --state-${kebab(k)}: ${v};`);
  L.push('');
  for (const [k, v] of Object.entries(T.layout.margin)) L.push(`  --layout-margin-${kebab(k)}: ${v}px;`);
  L.push(`  --layout-pane-spacing: ${T.layout.paneSpacing}px;`);
  L.push('}');

  L.push('');
  L.push('/*');
  L.push(' * Una clase por rol tipográfico. Las utilidades `text-*` que genera');
  L.push(' * Tailwind desde --text-* no incluyen la familia, y en Helios la familia');
  L.push(' * cambia según el rol (Outfit en títulos, Source Sans 3 en cuerpo).');
  L.push(' */');
  L.push('@layer components {');
  for (const [role, v] of Object.entries(resolvedType)) {
    const n = kebab(role);
    L.push(`  .type-${n} {`);
    L.push(`    font-family: var(--font-${v.family});`);
    L.push(`    font-size: ${rem(v.fontSize)};`);
    L.push(`    line-height: ${rem(v.lineHeight)};`);
    L.push(`    letter-spacing: ${rem(v.letterSpacing)};`);
    L.push(`    font-weight: ${v.fontWeight};`);
    L.push('  }');
  }
  L.push('}');
  L.push('');

  return L.join('\n');
}

// ─── Escritura ──────────────────────────────────────────────────────────────

function write(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content, 'utf8');
  console.log('  ✓', path.replace(ROOT + '\\', '').replace(ROOT + '/', ''));
}

const soloComprobar = process.argv.includes('--contraste');
const { filas, fallos } = validarContraste();

if (soloComprobar || fallos.length) {
  for (const f of filas) {
    const marca = f.c >= f.minimo ? 'ok ' : 'NO ';
    console.log(`  ${marca} ${f.tema.padEnd(6)} ${f.par.padEnd(46)} ${f.c.toFixed(2).padStart(5)}:1 (pide ${f.minimo})`);
  }
}
if (fallos.length) {
  console.error(`\nContraste insuficiente en ${fallos.length} ${fallos.length === 1 ? 'pareja' : 'parejas'}:`);
  for (const f of fallos) console.error(`  · ${f}`);
  process.exit(1);
}
if (soloComprobar) process.exit(0);

console.log('Generando tokens desde tokens/helios.tokens.json');
write(join(PANEL, 'src/theme/tokens.gen.ts'), buildTs());
write(join(PANEL, 'src/styles/tokens.gen.css'), buildCss());
console.log(
  `Listo. ${Object.keys(LIGHT).length} roles de color × 2 temas, ` +
    `${typeRoles.length} roles tipográficos, 6 muelles; ${filas.length} parejas de contraste en AA.`,
);
