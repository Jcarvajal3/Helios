import { useEffect, useId, useRef, useState } from 'react'
import { LoaderCircle, Plus, Search } from 'lucide-react'

import { datos } from '../datos/index.ts'

// El campo de medicamento: se escribe y aparece una lista para elegir, sin
// farmacias ni precios. Lo que no esté en la lista se puede usar tal cual: el
// campo nunca obliga a elegir. Al emitir el récipe, la base lo anota sin precio.

export function BuscadorMedicamento({
  etiqueta,
  valor,
  alCambiar,
  indice,
}: {
  etiqueta: string
  valor: string
  alCambiar: (texto: string) => void
  /** Para enfocar el campo al agregar un medicamento. */
  indice: number
}) {
  const id = useId()
  const idLista = `${id}-lista`
  const [abierta, setAbierta] = useState(false)
  const [opciones, setOpciones] = useState<string[]>([])
  const [buscando, setBuscando] = useState(false)
  const [activa, setActiva] = useState(-1)
  const lista = useRef<HTMLUListElement>(null)

  const texto = valor.trim()
  const buscable = texto.length >= 2
  const yaEsta = opciones.some((o) => o.toLowerCase() === texto.toLowerCase())
  const conEscrito = buscable && !yaEsta && !buscando
  const total = opciones.length + (conEscrito ? 1 : 0)

  useEffect(() => {
    if (!abierta || !buscable) {
      setOpciones([])
      setBuscando(false)
      return
    }
    let vigente = true
    setBuscando(true)
    const espera = setTimeout(() => {
      datos
        .buscarMedicamentos(texto)
        .catch(() => [] as string[])
        .then((encontrados) => {
          if (!vigente) return
          setOpciones(encontrados)
          setActiva(-1)
          setBuscando(false)
        })
    }, 200)
    return () => {
      vigente = false
      clearTimeout(espera)
    }
  }, [texto, abierta, buscable])

  useEffect(() => {
    if (activa >= 0) lista.current?.children[activa]?.scrollIntoView({ block: 'nearest' })
  }, [activa])

  const elegir = (nombre: string) => {
    alCambiar(nombre)
    setAbierta(false)
    setActiva(-1)
  }

  const alTeclear = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Escape') {
      setAbierta(false)
      return
    }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      setAbierta(true)
      if (total === 0) return
      const paso = e.key === 'ArrowDown' ? 1 : -1
      setActiva((a) => (a + paso + total) % total)
      return
    }
    if (e.key === 'Enter' && abierta) {
      e.preventDefault()
      if (activa >= 0 && activa < opciones.length) elegir(opciones[activa])
      else setAbierta(false)
    }
  }

  const mostrar = abierta && buscable

  return (
    <div className="relative min-w-0 flex-1">
      <label htmlFor={id} className="mb-1 block text-[14px] font-semibold text-on-surface-variant">
        {etiqueta}
        <span className="text-error"> *</span>
      </label>
      <div className="relative">
        <Search aria-hidden className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-on-surface-faint" />
        <input
          id={id}
          role="combobox"
          aria-expanded={mostrar}
          aria-controls={idLista}
          aria-autocomplete="list"
          aria-activedescendant={mostrar && activa >= 0 ? `${idLista}-${activa}` : undefined}
          autoComplete="off"
          maxLength={160}
          placeholder="Busca o escribe el medicamento"
          data-medicamento={indice}
          value={valor}
          onChange={(e) => {
            alCambiar(e.target.value)
            setAbierta(true)
          }}
          onFocus={() => setAbierta(true)}
          onBlur={() => setAbierta(false)}
          onKeyDown={alTeclear}
          className="h-11 w-full rounded-medium border border-outline-variant bg-surface pl-9 pr-9 text-[16px] text-on-surface outline-none transition-colors placeholder:text-placeholder focus:border-primary focus:ring-2 focus:ring-primary/15"
        />
        {buscando && mostrar && (
          <LoaderCircle aria-hidden className="absolute right-3 top-1/2 size-4 -translate-y-1/2 animate-spin text-on-surface-faint" />
        )}
      </div>

      {mostrar && (
        <ul
          ref={lista}
          id={idLista}
          role="listbox"
          aria-label={etiqueta}
          // Sin esto, tocar la lista le quita el foco al campo y se cierra antes de elegir.
          onMouseDown={(e) => e.preventDefault()}
          className="absolute inset-x-0 top-full z-30 mt-1 max-h-64 overflow-y-auto rounded-medium border border-outline-variant bg-surface py-1 shadow-lg"
        >
          {opciones.map((nombre, i) => (
            <li
              key={nombre}
              id={`${idLista}-${i}`}
              role="option"
              aria-selected={activa === i}
              onClick={() => elegir(nombre)}
              className={`cursor-pointer px-3 py-2.5 text-[15px] leading-snug ${activa === i ? 'bg-primary-container text-on-primary-container' : 'hover:bg-surface-container-high'}`}
            >
              {nombre}
            </li>
          ))}
          {conEscrito && (
            <li
              id={`${idLista}-${opciones.length}`}
              role="option"
              aria-selected={activa === opciones.length}
              onClick={() => elegir(texto)}
              className={`flex cursor-pointer items-start gap-2 px-3 py-2.5 text-[15px] leading-snug ${opciones.length > 0 ? 'border-t border-outline-variant/70' : ''} ${activa === opciones.length ? 'bg-primary-container text-on-primary-container' : 'hover:bg-surface-container-high'}`}
            >
              <Plus aria-hidden className="mt-0.5 size-4 shrink-0" />
              <span className="min-w-0 break-words">
                Usar «{texto}»
                {opciones.length === 0 && <span className="block text-[13px] text-on-surface-faint">No está en la lista. Lo anotamos al emitir el récipe.</span>}
              </span>
            </li>
          )}
          {buscando && opciones.length === 0 && (
            <li role="presentation" className="px-3 py-2.5 text-[14px] text-on-surface-faint">
              Buscando…
            </li>
          )}
        </ul>
      )}
    </div>
  )
}
