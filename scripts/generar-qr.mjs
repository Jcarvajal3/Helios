#!/usr/bin/env node
// ============================================================================
// Helios — El QR impreso: siempre `https://conhelios.com/qr`.
//
//   node scripts/generar-qr.mjs
//
// Deja en docs/qr/ el QR en SVG (vectorial, para imprenta) y en PNG (2048 px).
// El destino no va en el QR: lo decide la ruta `/qr` del panel
// (`DESTINO_DEL_QR` en panel/src/routes/qr.ts), así que cambiarlo no obliga
// a reimprimir nada. Corrección de errores alta (H): aguanta manchas,
// arrugas o un logo encima.
// ============================================================================

import { mkdirSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const raiz = join(dirname(fileURLToPath(import.meta.url)), '..')
const QRCode = createRequire(join(raiz, 'panel', 'package.json'))('qrcode')

const URL_DEL_QR = 'https://conhelios.com/qr'
const opciones = {
  errorCorrectionLevel: 'H',
  margin: 4,
  color: { dark: '#020B24', light: '#FFFFFF' },
}

const carpeta = join(raiz, 'docs', 'qr')
mkdirSync(carpeta, { recursive: true })

writeFileSync(join(carpeta, 'qr-helios.svg'), await QRCode.toString(URL_DEL_QR, { ...opciones, type: 'svg' }))
await QRCode.toFile(join(carpeta, 'qr-helios.png'), URL_DEL_QR, { ...opciones, width: 2048 })

console.log(`QR de ${URL_DEL_QR} en ${carpeta}`)
