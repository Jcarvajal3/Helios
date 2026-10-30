import { useEffect, useId, useRef, useState } from 'react'
import type { KeyboardEvent } from 'react'
import { Check, Search } from 'lucide-react'

import { Campo, CampoDeTexto, ENTRADA, Flechita, bordeDe, descritoPor } from './piezas'
import { IconoDeEspecialidad } from '@/components/directorio/IconoDeEspecialidad'
import { buscarEspecialidades, normalizar } from '@/features/directorio/directorio'
import type { Especialidad } from '@/features/directorio/directorio'
import { ESPECIALIDADES } from '@/features/directorio/especialidades'

/** La de la lista que se llama exactamente así («Otras» no cuenta: no es un nombre). */
function especialidadLlamada(texto: string): Especialidad | null {
  const t = normalizar(texto)
  if (!t) return null
  return ESPECIALIDADES.find((e) => e.clave !== 'otra' && normalizar(e.nombre) === t) ?? null
}

/**
 * LA ESPECIALIDAD DEL ALTA — un desplegable con buscador sobre la lista
 * cerrada del directorio (`ESPECIALIDADES`), con el icono de cada una.
 *
 * Se escribe para filtrar (sin tildes ni mayúsculas, y entiende «dentista» u
 * «ojos»: `buscarEspecialidades`) y se elige con el ratón, el dedo o las
 * flechas y Enter. Lo que se guarda es el nombre tal cual de la lista, y de
 * ese nombre sale la clave del directorio
 * (`helios_directorio_especialidad_sugerida`): así no entran erratas.
 *
 * «Otras especialidades» abre un campo para escribirla: es la salida cuando
 * la suya no está. Un valor que no es de la lista (lo que traiga un borrador)
 * se trata igual.
 */
export function CampoDeEspecialidad({
  id,
  valor,
  onChange,
  alSalir,
  error,
}: {
  id: string
  /** El texto que se guarda en `specialty`. */
  valor: string
  onChange: (valor: string) => void
  alSalir?: () => void
  error?: string | null
}) {
  const lista = useId()
  const elegida = especialidadLlamada(valor)
  const [otra, setOtra] = useState(() => !!valor.trim() && !elegida)
  const [abierto, setAbierto] = useState(false)
  const [consulta, setConsulta] = useState('')
  const [activa, setActiva] = useState(0)
  const caja = useRef<HTMLUListElement>(null)
  const quiereEscribirOtra = useRef(false)

  const opciones = buscarEspecialidades(consulta)
  const clave = otra ? 'otra' : elegida?.clave

  // La opción activa siempre a la vista al moverse con las flechas.
  useEffect(() => {
    if (!abierto) return
    caja.current?.querySelector<HTMLElement>(`[data-indice="${activa}"]`)?.scrollIntoView({ block: 'nearest' })
  }, [activa, abierto])

  useEffect(() => {
    if (otra && quiereEscribirOtra.current) {
      quiereEscribirOtra.current = false
      document.getElementById(`${id}-otra`)?.focus()
    }
  }, [otra, id])

  function abrir() {
    setConsulta('')
    setActiva(0)
    setAbierto(true)
  }

  function elegir(e: Especialidad) {
    setAbierto(false)
    setConsulta('')
    if (e.clave === 'otra') {
      quiereEscribirOtra.current = true
      if (!otra) onChange('')
      setOtra(true)
      return
    }
    setOtra(false)
    onChange(e.nombre)
    alSalir?.()
  }

  function alTeclear(ev: KeyboardEvent<HTMLInputElement>) {
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      ev.preventDefault()
      if (!abierto) return abrir()
      const paso = ev.key === 'ArrowDown' ? 1 : -1
      setActiva((a) => (a + paso + opciones.length) % opciones.length)
    } else if (ev.key === 'Enter') {
      if (!abierto) return
      // Enter elige, no envía el formulario.
      ev.preventDefault()
      elegir(opciones[activa])
    } else if (ev.key === 'Escape' && abierto) {
      ev.preventDefault()
      setAbierto(false)
      setConsulta('')
    }
  }

  /**
   * Al dejar el campo con algo escrito: si solo casa una de la lista, o solo
   * una tiene una palabra que empieza así, esa (escribir «urolog» y pasar al
   * siguiente no debe perderse, aunque «neurología» también lo lleve dentro).
   */
  function alDejar() {
    if (!abierto) return
    const casan = opciones.filter((o) => o.clave !== 'otra')
    const primera = normalizar(consulta).split(' ')[0] ?? ''
    const empiezan = casan.filter((o) =>
      normalizar(o.nombre)
        .split(' ')
        .some((p) => p.startsWith(primera)),
    )
    const unica = casan.length === 1 ? casan[0] : empiezan.length === 1 ? empiezan[0] : null
    if (primera && unica) elegir(unica)
    else {
      setAbierto(false)
      setConsulta('')
      if (valor.trim()) alSalir?.()
    }
  }

  const idActiva = abierto && opciones[activa] ? `${lista}-${opciones[activa].clave}` : undefined
  const texto = abierto ? consulta : otra ? 'Otras especialidades' : (elegida?.nombre ?? '')
  const errorDeLista = otra ? null : error

  return (
    <div>
      <Campo id={id} etiqueta="Especialidad" error={errorDeLista}>
        <span
          aria-hidden
          className={`pointer-events-none absolute inset-y-0 left-3.5 my-auto grid size-6 place-items-center rounded-full ${
            clave && !abierto ? 'bg-portada-cielo-3 text-portada-azul' : 'text-portada-tinta-3'
          }`}
        >
          {clave && !abierto ? (
            <IconoDeEspecialidad clave={clave} className="size-3.5" strokeWidth={2} />
          ) : (
            <Search className="size-4" strokeWidth={2} />
          )}
        </span>
        <input
          id={id}
          type="text"
          role="combobox"
          aria-expanded={abierto}
          aria-controls={lista}
          aria-autocomplete="list"
          aria-activedescendant={idActiva}
          aria-invalid={errorDeLista ? true : undefined}
          aria-describedby={descritoPor(id, null, errorDeLista)}
          autoComplete="off"
          autoCapitalize="sentences"
          enterKeyHint="next"
          spellCheck={false}
          placeholder={abierto ? 'Escribe para buscar…' : 'Elige tu especialidad'}
          value={texto}
          onFocus={abrir}
          onClick={() => !abierto && abrir()}
          onChange={(e) => {
            setConsulta(e.target.value)
            setActiva(0)
            setAbierto(true)
          }}
          onKeyDown={alTeclear}
          onBlur={alDejar}
          className={`${ENTRADA} ${bordeDe(errorDeLista)} pl-12 pr-10`}
        />
        <Flechita />
        {abierto && (
          <ul
            ref={caja}
            id={lista}
            role="listbox"
            aria-label="Especialidades"
            className="absolute inset-x-0 top-[calc(100%+6px)] z-30 max-h-[min(19rem,50dvh)] overflow-y-auto overscroll-contain rounded-2xl border border-portada-linea bg-white p-1.5 shadow-[0_18px_40px_-18px_rgba(5,15,44,0.35)]"
          >
            {opciones.map((o, i) => {
              const marcada = o.clave === clave
              return (
                <li
                  key={o.clave}
                  id={`${lista}-${o.clave}`}
                  role="option"
                  aria-selected={i === activa}
                  data-indice={i}
                  // `mousedown` y no `click`: el campo no pierde el foco
                  // antes de elegir.
                  onMouseDown={(ev) => {
                    ev.preventDefault()
                    elegir(o)
                  }}
                  onMouseMove={() => i !== activa && setActiva(i)}
                  className={`flex min-h-11 cursor-pointer items-center gap-3 rounded-xl px-2.5 py-2 text-[0.95rem] tracking-[-0.01em] text-portada-tinta ${
                    i === activa ? 'bg-portada-niebla' : ''
                  } ${o.clave === 'otra' && i > 0 ? 'mt-1 border-t border-portada-linea pt-2.5' : ''}`}
                >
                  <span
                    aria-hidden
                    className={`grid size-8 shrink-0 place-items-center rounded-full ${
                      marcada ? 'bg-portada-azul text-white' : 'bg-portada-cielo-3 text-portada-azul'
                    }`}
                  >
                    <IconoDeEspecialidad clave={o.clave} className="size-4" strokeWidth={1.9} />
                  </span>
                  <span className="min-w-0 flex-1">{o.nombre}</span>
                  {marcada && <Check aria-hidden className="size-4 shrink-0 text-portada-azul" strokeWidth={2.2} />}
                </li>
              )
            })}
            {opciones.length === 1 && (
              <li role="presentation" className="px-2.5 pb-1 pt-0.5 text-[0.85rem] text-portada-tinta-3">
                No la encontramos en la lista: elige «Otras especialidades» y escríbela.
              </li>
            )}
          </ul>
        )}
      </Campo>
      {otra && (
        <CampoDeTexto
          id={`${id}-otra`}
          etiqueta="¿Cuál es tu especialidad?"
          className="mt-4"
          value={valor}
          onChange={onChange}
          alSalir={alSalir}
          error={error && !valor.trim() ? 'Escribe tu especialidad.' : error}
          autoCapitalize="sentences"
          enterKeyHint="next"
          placeholder="Escríbela como quieras que la lean tus pacientes"
        />
      )}
    </div>
  )
}
