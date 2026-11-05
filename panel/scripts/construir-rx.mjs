#!/usr/bin/env node
// ============================================================================
// RX (récipes) se publica con el panel, en conhelios.com/rx: al compilar en
// Vercel, compila `rx/` y deja el resultado en `public/rx`, de donde sale como
// archivos estáticos. Ver rx/README.md.
//
// En local no hace nada, para que `npm run build` siga siendo el de siempre
// (con `--forzar` lo hace igual). Si RX no compila, avisa y sigue: un error en
// RX no puede frenar una publicación del panel. /rx se queda sin página y ya.
// ============================================================================

import { execSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const AQUI = path.dirname(fileURLToPath(import.meta.url))
const RX = path.resolve(AQUI, '..', '..', 'rx')
const DESTINO = path.resolve(AQUI, '..', 'public', 'rx')

if (!process.env.VERCEL && !process.argv.includes('--forzar')) process.exit(0)

fs.rmSync(DESTINO, { recursive: true, force: true })

try {
  // Con NODE_ENV=production, npm se saltaría las herramientas de compilar.
  execSync('npm ci --include=dev --no-audit --no-fund', { cwd: RX, stdio: 'inherit' })
  execSync('npm run build', { cwd: RX, stdio: 'inherit' })
  fs.cpSync(path.join(RX, 'dist'), DESTINO, { recursive: true })
  console.log('RX: listo en public/rx')
} catch (error) {
  fs.rmSync(DESTINO, { recursive: true, force: true })
  console.warn('RX: no se pudo compilar; el panel sigue sin /rx.', error)
}
