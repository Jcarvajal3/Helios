// Los iconos 3D de las especialidades del directorio.
//
//   node scripts/iconos-3d/servidor.mjs
//
// Abre http://localhost:3012 en un navegador: la página modela cada icono con
// three.js, los enseña en una hoja y, con «Guardar», los escribe en
// panel/public/images/especialidades/<nombre>.webp. Para añadir uno, se
// modela en iconos.html y se asigna en
// panel/src/components/directorio/IlustracionDeEspecialidad.tsx.
import { createServer } from 'node:http'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const aqui = dirname(fileURLToPath(import.meta.url))
const destino = join(aqui, '..', '..', 'panel', 'public', 'images', 'especialidades')
const PUERTO = 3012

createServer(async (req, res) => {
  const guardar = req.url?.match(/^\/guardar\/([a-z0-9_-]+)$/)
  if (req.method === 'POST' && guardar) {
    const trozos = []
    for await (const t of req) trozos.push(t)
    await mkdir(destino, { recursive: true })
    await writeFile(join(destino, `${guardar[1]}.webp`), Buffer.concat(trozos))
    res.writeHead(204).end()
    return
  }
  if (req.url === '/' || req.url === '/iconos.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
    res.end(await readFile(join(aqui, 'iconos.html')))
    return
  }
  res.writeHead(404).end()
}).listen(PUERTO, () => console.log(`Iconos 3D en http://localhost:${PUERTO}`))
