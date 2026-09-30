/**
 * Genera `mapa.json`, el mapa de pantallas y cifras que lee la función
 * `admin-asistente`, a partir del catálogo del panel.
 *
 *   npm run asistente:mapa                      → ruta por defecto
 *   npm run asistente:mapa -- <ruta/mapa.json>  → donde se diga
 *
 * Por defecto lo escribe en la carpeta de la función dentro del mismo repo:
 * `supabase/functions/admin-asistente/mapa.json`. La función llega en la fase
 * 5 (plan §11); hasta entonces el asistente está apagado (`VITE_ASISTENTE`).
 * Se vuelve a generar cada vez que cambia una pantalla o una cifra del
 * catálogo, y se comitea junto a la función.
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { CATALOGO } from '../src/features/admin/catalogo'
import { construirMapa } from '../src/features/admin/asistente/mapa'

/** La raíz del panel es la carpeta de encima de `scripts/`; la del repo, la de encima. */
function rutaPorDefecto(): string {
  const panel = resolve(dirname(fileURLToPath(import.meta.url)), '..')
  return resolve(panel, '..', 'supabase/functions/admin-asistente/mapa.json')
}

const destino = process.argv[2] ? resolve(process.argv[2]) : rutaPorDefecto()
const mapa = construirMapa(CATALOGO)

mkdirSync(dirname(destino), { recursive: true })
writeFileSync(destino, `${JSON.stringify(mapa, null, 2)}\n`, 'utf8')

console.log(
  `mapa.json: ${mapa.pantallas.length} pantallas, ${mapa.fichas.length} fichas y ` +
    `${mapa.cifras.length} cifras → ${destino}`,
)
