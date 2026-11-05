import { useState } from 'react'
import type { FormEvent } from 'react'
import { CheckCircle2, Send } from 'lucide-react'

import { datos } from '../datos/index.ts'
import { correoValido } from '../recipe/util.ts'
import { Aviso, Boton, Campo, mensajeDe } from '../ui.tsx'

/** El correo del paciente y el botón de enviar. Después se puede mandar a otro. */
export function EnviarCorreo({
  recipeId,
  correoInicial,
  antesDeEnviar,
  alEnviar,
  listoParaEnviar = true,
}: {
  recipeId: string
  correoInicial: string
  /** Por si el PDF aún no está guardado. */
  antesDeEnviar?: () => Promise<void>
  alEnviar?: (correo: string) => void
  listoParaEnviar?: boolean
}) {
  const [correo, setCorreo] = useState(correoInicial)
  const [enviando, setEnviando] = useState(false)
  const [enviadoA, setEnviadoA] = useState('')
  const [error, setError] = useState('')

  const enviar = async (e: FormEvent) => {
    e.preventDefault()
    const destino = correo.trim()
    if (!correoValido(destino)) {
      setError('Revisa el correo: parece incompleto.')
      return
    }
    setEnviando(true)
    setError('')
    try {
      await antesDeEnviar?.()
      await datos.enviar(recipeId, destino)
      setEnviadoA(destino)
      alEnviar?.(destino)
    } catch (err) {
      setError(mensajeDe(err))
    } finally {
      setEnviando(false)
    }
  }

  if (enviadoA) {
    return (
      <div className="aparecer flex flex-wrap items-center justify-between gap-2 rounded-medium bg-success-container px-3.5 py-2.5 text-on-success-container">
        <span className="flex min-w-0 items-center gap-2 text-[15px] font-semibold">
          <CheckCircle2 aria-hidden className="size-5 shrink-0" />
          <span className="min-w-0 break-words">Enviado a {enviadoA}</span>
        </span>
        <button
          type="button"
          className="min-h-9 text-[14px] font-semibold underline"
          onClick={() => {
            setEnviadoA('')
            setCorreo('')
          }}
        >
          Enviar a otro correo
        </button>
      </div>
    )
  }

  return (
    <form onSubmit={(e) => void enviar(e)} noValidate className="flex flex-col gap-3">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
        <Campo
          etiqueta="Correo del paciente"
          type="email"
          inputMode="email"
          autoComplete="off"
          placeholder="paciente@correo.com"
          className="min-w-0 flex-1"
          value={correo}
          onChange={(e) => {
            setCorreo(e.target.value)
            setError('')
          }}
        />
        <Boton
          type="submit"
          cargando={enviando}
          disabled={!listoParaEnviar}
          icono={<Send aria-hidden className="size-4" />}
          className="sm:mt-[26px]"
        >
          Enviar
        </Boton>
      </div>
      {error && <Aviso>{error}</Aviso>}
    </form>
  )
}
