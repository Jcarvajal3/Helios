import { useRef, useState } from 'react'
import { Trash2, Upload } from 'lucide-react'

import { datos } from '../datos/index.ts'
import type { Perfil } from '../modelo.ts'
import { prepararFirma, prepararLogo } from '../recipe/imagenes.ts'
import { Aviso, Boton, mensajeDe } from '../ui.tsx'

/** El botón de subir la firma o el logo. Prepara la imagen y la deja puesta. */
export function SubirImagen({
  tipo,
  tieneImagen,
  alCambiarPerfil,
  variante = 'secundario',
  etiqueta,
}: {
  tipo: 'firma' | 'logo'
  tieneImagen: boolean
  alCambiarPerfil: (p: Perfil) => void
  variante?: 'primario' | 'secundario'
  etiqueta?: string
}) {
  const entrada = useRef<HTMLInputElement>(null)
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  const alElegir = async (archivo: File | undefined) => {
    if (!archivo) return
    setOcupado(true)
    setError('')
    try {
      const png = await (tipo === 'firma' ? prepararFirma(archivo) : prepararLogo(archivo))
      alCambiarPerfil(await datos.subirImagen(tipo, png))
    } catch (e) {
      setError(mensajeDe(e))
    } finally {
      setOcupado(false)
      if (entrada.current) entrada.current.value = ''
    }
  }

  const quitar = async () => {
    setOcupado(true)
    setError('')
    try {
      alCambiarPerfil(await datos.quitarImagen(tipo))
    } catch (e) {
      setError(mensajeDe(e))
    } finally {
      setOcupado(false)
    }
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2">
        <input
          ref={entrada}
          type="file"
          accept="image/*"
          className="sr-only"
          tabIndex={-1}
          aria-hidden
          onChange={(e) => void alElegir(e.target.files?.[0])}
        />
        <Boton
          variante={variante}
          cargando={ocupado}
          icono={<Upload aria-hidden className="size-4" />}
          onClick={() => entrada.current?.click()}
        >
          {etiqueta ?? (tieneImagen ? 'Cambiar' : tipo === 'firma' ? 'Subir firma' : 'Subir logo')}
        </Boton>
        {tieneImagen && (
          <Boton
            variante="peligro"
            disabled={ocupado}
            icono={<Trash2 aria-hidden className="size-4" />}
            onClick={() => void quitar()}
          >
            Quitar
          </Boton>
        )}
      </div>
      {error && <Aviso>{error}</Aviso>}
    </div>
  )
}
