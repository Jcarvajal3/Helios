/**
 * Reduce una imagen a un thumbnail antes de subirla.
 *
 * El logo se ve, como mucho, en un disco de 80 px en el panel y en una
 * tarjeta de media pantalla en el móvil. Guardar el JPEG de 3 MB que sale de
 * la cámara para pintarlo a ese tamaño castiga a quien peor conexión tiene:
 * la app descarga megabytes para tirar el 99% de los píxeles.
 *
 * Se hace en el navegador y no en el servidor a propósito. Las
 * transformaciones de imagen de Supabase Storage son un extra de pago, y
 * montar una función aparte para esto sería un servicio nuevo que mantener
 * cuando el navegador ya trae un canvas.
 *
 * Efecto secundario que importa: como el archivo sale siempre por debajo del
 * límite del bucket, nadie choca con "máximo 2 MB" por subir una foto normal
 * de teléfono.
 */

/** Lado máximo del thumbnail. Cubre pantallas a 3x sin pasarse. */
const MAX_SIDE = 512

/** Alto para una foto, invisible para un logo, y ahorra bastante peso. */
const QUALITY = 0.85

export type ResizedImage = {
  blob: Blob
  /** Extensión que le toca al archivo resultante, ya sin el punto. */
  extension: string
  width: number
  height: number
}

export async function resizeToThumbnail(file: File): Promise<ResizedImage> {
  const bitmap = await createImageBitmap(file)

  try {
    const scale = Math.min(1, MAX_SIDE / Math.max(bitmap.width, bitmap.height))
    // Nunca se agranda: un logo de 100 px estirado a 512 pesa más y se ve
    // peor que el original.
    const width = Math.round(bitmap.width * scale)
    const height = Math.round(bitmap.height * scale)

    const canvas = document.createElement('canvas')
    canvas.width = width
    canvas.height = height

    const context = canvas.getContext('2d')
    if (!context) throw new Error('El navegador no pudo procesar la imagen.')

    // Un PNG con transparencia sobre un canvas vacío se convierte a JPEG con
    // el fondo en negro. Los logos suelen ser PNG transparentes, así que se
    // conserva el PNG cuando lo era y solo se re-comprime a JPEG lo que ya
    // venía opaco.
    const keepsAlpha = file.type === 'image/png' || file.type === 'image/webp'
    const mime = keepsAlpha ? file.type : 'image/jpeg'

    context.drawImage(bitmap, 0, 0, width, height)

    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, mime, QUALITY),
    )

    if (!blob) throw new Error('El navegador no pudo procesar la imagen.')

    return {
      blob,
      extension: mime === 'image/png' ? 'png' : mime === 'image/webp' ? 'webp' : 'jpg',
      width,
      height,
    }
  } finally {
    // Sin esto la imagen decodificada se queda en memoria hasta que el
    // recolector se digne; en un alta tras otra se nota.
    bitmap.close()
  }
}
