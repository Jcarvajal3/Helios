// ═══════════════════════════════════════════════════════════════════════════
// Helios — Comprobantes de pago de compras: bajar el adjunto de 360dialog y
// guardarlo en el bucket privado `payment-receipts` (`compras/<solicitud>/<media>.<ext>`).
// Misma descarga que `lector-comprobantes` (primero la URL, luego el archivo).
// ═══════════════════════════════════════════════════════════════════════════

export const MAX_BYTES_COMPROBANTE = 10 * 1024 * 1024
export const BUCKET_COMPROBANTES = 'payment-receipts'

export type ConfigD360 = { d360_api_key: string | null; d360_base_url: string | null }

/** Dónde se guarda un archivo (el bucket lo pone quien implementa esto). */
export type AlmacenComprobantes = {
  subir(ruta: string, bytes: Uint8Array, mime: string): Promise<void>
}

/** La URL de descarga de Meta, apuntada al host de 360dialog. */
export function urlDeDescarga(urlDeMeta: string, base: string): string {
  const u = new URL(urlDeMeta)
  return `${base.replace(/\/+$/, '')}${u.pathname}${u.search}`
}

export function extensionDe(mime: string): string {
  if (mime === 'image/png') return 'png'
  if (mime === 'image/webp') return 'webp'
  if (mime === 'application/pdf') return 'pdf'
  return 'jpg'
}

/** Un id de adjunto apto para una ruta de archivo. */
export function mediaLimpio(id: string): string {
  return id.replace(/[^a-zA-Z0-9._-]/g, '').slice(0, 80) || 'adjunto'
}

/** La ruta del comprobante en el bucket. */
export function rutaDelComprobante(solicitudId: string, mediaId: string, mime: string): string {
  const carpeta = solicitudId.replace(/[^a-zA-Z0-9-]/g, '').slice(0, 64) || 'sin-solicitud'
  return `compras/${carpeta}/${mediaLimpio(mediaId)}.${extensionDe(mime)}`
}

/** Baja un adjunto de 360dialog. Los errores no llevan la clave ni la URL. */
export async function bajarAdjunto360(
  mediaId: string,
  cfg: ConfigD360,
  fetchFn: typeof fetch = fetch,
): Promise<Uint8Array> {
  if (!cfg.d360_api_key || !cfg.d360_base_url) throw new Error('Falta la configuración de 360dialog')
  const base = cfg.d360_base_url.replace(/\/+$/, '')
  const cabeceras = { 'D360-API-KEY': cfg.d360_api_key }

  const meta = await fetchFn(`${base}/${encodeURIComponent(mediaId)}`, {
    headers: cabeceras,
    signal: AbortSignal.timeout(15000),
  })
  if (!meta.ok) throw new Error(`360dialog no dio el adjunto (${meta.status})`)
  const { url } = (await meta.json()) as { url?: string }
  if (!url) throw new Error('360dialog no devolvió la URL del adjunto')

  const archivo = await fetchFn(urlDeDescarga(url, base), {
    headers: cabeceras,
    signal: AbortSignal.timeout(30000),
  })
  if (!archivo.ok) throw new Error(`No se pudo bajar el adjunto (${archivo.status})`)
  const bytes = new Uint8Array(await archivo.arrayBuffer())
  if (bytes.byteLength === 0) throw new Error('El adjunto viene vacío')
  if (bytes.byteLength > MAX_BYTES_COMPROBANTE) throw new Error('El adjunto pesa más de 10 MB')
  return bytes
}
