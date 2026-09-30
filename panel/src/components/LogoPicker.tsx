import { useRef, useState } from 'react'
import { ImageOff, Upload } from 'lucide-react'

import { Button, ErrorBox } from '@/components/ui'
import { uploadMerchantLogo } from '@/features/admin/api'
import { describeError } from '@/lib/supabase'

const ACCEPTED = ['image/jpeg', 'image/png', 'image/webp']

/**
 * Tope del archivo **de origen**, no del que se sube.
 *
 * El bucket acepta 2 MB, pero eso ya no es lo que hay que comprobar aquí: lo
 * que se sube es el thumbnail de 512 px, y una foto de 8 MB de un teléfono
 * acaba pesando decenas de kilobytes. Cortar en 2 MB rechazaría fotos
 * perfectamente válidas por un límite que la imagen final nunca alcanza.
 *
 * El corte que sí tiene sentido es contra un archivo tan grande que
 * decodificarlo cuelgue la pestaña.
 */
const MAX_SOURCE_BYTES = 25 * 1024 * 1024

/**
 * Elegir el logo del comercio subiéndolo a Storage.
 *
 * Antes esto era un campo de texto para pegar una URL. Se cambió porque una
 * URL ajena es una dependencia invisible: el día que el CDN de turno la
 * borra, la tarjeta del local aparece vacía en la app y nadie se entera.
 *
 * La imagen se encoge a un thumbnail de 512 px antes de salir del navegador
 * (`resizeToThumbnail`), así que lo que llega al bucket pesa siempre poco.
 * Eso hace dos cosas a la vez: la app no descarga megabytes para pintar un
 * disco de 40 px, y nadie choca con el límite del bucket por subir una foto
 * normal de teléfono.
 */
export function LogoPicker({
  folder,
  value,
  onChange,
  label = 'Logo de la clínica',
}: {
  /** Carpeta dentro del bucket: el id del comercio, o uno nuevo en el alta. */
  folder: string
  value: string | null
  onChange: (url: string | null) => void
  label?: string
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleFile(file: File) {
    setError(null)

    if (!ACCEPTED.includes(file.type)) {
      setError('El logo tiene que ser JPG, PNG o WebP.')
      return
    }

    if (file.size > MAX_SOURCE_BYTES) {
      setError(
        `Ese archivo pesa ${(file.size / 1024 / 1024).toFixed(0)} MB y es demasiado grande para procesarlo. Prueba con una imagen más pequeña.`,
      )
      return
    }

    setBusy(true)
    try {
      onChange(await uploadMerchantLogo({ folder, file }))
    } catch (e) {
      setError(describeError(e) ?? 'No se pudo subir el logo.')
    } finally {
      setBusy(false)
      // Sin esto, elegir el mismo archivo dos veces seguidas no dispara
      // `change` y el segundo intento no hace nada.
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  return (
    <div className="flex flex-col gap-2">
      <p className="type-body-medium text-on-surface-variant">{label}</p>

      <div className="flex items-center gap-4">
        <div className="flex size-20 shrink-0 items-center justify-center overflow-hidden rounded-[var(--radius-panel-control)] bg-shell-control">
          {value ? (
            <img src={value} alt="" className="size-full object-cover" />
          ) : (
            <ImageOff size={24} className="text-on-surface-variant" />
          )}
        </div>

        <div className="flex flex-col gap-2">
          <Button
            size="sm"
            variant="tonal"
            disabled={busy}
            onClick={() => inputRef.current?.click()}
          >
            <Upload size={16} className="mr-2" />
            {busy ? 'Subiendo…' : value ? 'Cambiar' : 'Subir imagen'}
          </Button>

          {value && (
            <button
              type="button"
              onClick={() => onChange(null)}
              className="type-body-small text-on-surface-variant underline transition-colors hover:text-error"
            >
              {/* Quita la referencia, no el archivo del bucket: si se borrara
                  y el guardado fallara después, el comercio se quedaría
                  apuntando a una imagen que ya no existe. */}
              Quitar logo
            </button>
          )}
        </div>
      </div>

      <input
        ref={inputRef}
        type="file"
        accept={ACCEPTED.join(',')}
        className="hidden"
        onChange={(e) => {
          const file = e.target.files?.[0]
          if (file) void handleFile(file)
        }}
      />

      {error && <ErrorBox title="No se pudo usar esa imagen" detail={error} />}
    </div>
  )
}
