import { useState } from 'react'
import type { FormEvent, ReactNode } from 'react'

import { datos } from '../datos/index.ts'
import { Aviso, Boton, Campo, mensajeDe } from '../ui.tsx'

export function Entrar({ marca, alEntrar }: { marca: ReactNode; alEntrar: () => void }) {
  const [correo, setCorreo] = useState('')
  const [clave, setClave] = useState('')
  const [entrando, setEntrando] = useState(false)
  const [error, setError] = useState('')

  const enviar = async (e: FormEvent) => {
    e.preventDefault()
    setEntrando(true)
    setError('')
    try {
      await datos.entrar(correo.trim(), clave)
      alEntrar()
    } catch (err) {
      setError(mensajeDe(err))
      setEntrando(false)
    }
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center px-4 py-10">
      {marca}
      <h1 className="mt-6 text-[28px] font-semibold leading-tight tracking-tight">
        Tus récipes, sin papel
      </h1>
      <p className="mt-2 text-[16px] text-on-surface-variant">
        Entra con el mismo correo y la misma clave del panel de Helios.
      </p>
      <form onSubmit={(e) => void enviar(e)} className="mt-6 flex flex-col gap-4">
        <Campo
          etiqueta="Correo"
          type="email"
          autoComplete="username"
          inputMode="email"
          required
          value={correo}
          onChange={(e) => setCorreo(e.target.value)}
        />
        <Campo
          etiqueta="Clave"
          type="password"
          autoComplete="current-password"
          required
          value={clave}
          onChange={(e) => setClave(e.target.value)}
        />
        {error && <Aviso>{error}</Aviso>}
        <Boton type="submit" cargando={entrando} className="w-full">
          Entrar
        </Boton>
      </form>
    </main>
  )
}
