import { useMemo, useState } from 'react'
import type { ComponentType, ReactNode } from 'react'
import { useRouterState } from '@tanstack/react-router'
import { ChevronDown } from 'lucide-react'

import { useRolDelEquipo } from '@/features/admin/role'
import { useMenu } from './kit'
import { useVersionDelAdmin } from './version'

/**
 * El «espacio de trabajo» de la maqueta, el mismo en Operaciones, Personas y
 * Mensajes: las vistas de la pestaña en botones, una fila de herramientas
 * (buscar, filtrar por estado, exportar CSV) y un panel con la tabla, su
 * título, su ayuda y cuántos hay. Cada fila acaba en «Abrir caso →», que lleva
 * a la ficha de Pro de ese caso: allí están las acciones.
 */

export type Lectura = { cargando: boolean; fallo: boolean; reintentar?: () => void }

export type Columna = { rotulo: string; numero?: boolean }

export type Fila = {
  id: string
  /** Una por columna. */
  celdas: ReactNode[]
  /** Lo que se busca y lo que va al CSV, en el orden de las columnas. */
  textos: string[]
  /** La última columna: una etiqueta. */
  estado: string
  tono?: 'ambar' | 'verde'
  /** El enlace a la ficha («Abrir caso →»), ya armado con su ruta. */
  abrir?: ReactNode
}

export type Vista<T extends string> = { id: T; rotulo: string }

/** Las vistas de una pestaña en botones de vidrio («Revisión · Abonos sin dueño…»). */
export function Opciones<T extends string>({
  vistas,
  valor,
  onCambio,
}: {
  vistas: ReadonlyArray<Vista<T>>
  valor: T
  onCambio: (v: T) => void
}) {
  if (vistas.length < 2) return null
  return (
    <nav className="lt-opciones" aria-label="Vistas de esta pestaña">
      {vistas.map((v) => (
        <button key={v.id} type="button" className="lt-opcion" aria-pressed={v.id === valor} onClick={() => onCambio(v.id)}>
          {v.rotulo}
        </button>
      ))}
    </nav>
  )
}

/** El panel de una vista: herramientas, cabecera y tabla. */
export function EspacioDeTrabajo({
  titulo,
  ayuda,
  columnas,
  filas,
  lectura,
  buscar = `Buscar en ${titulo.toLowerCase()}`,
  archivo,
  extra,
  vacio = 'No hay nada en esta vista.',
  nota,
  alBuscar,
}: {
  titulo: string
  ayuda: string
  columnas: ReadonlyArray<Columna>
  filas: ReadonlyArray<Fila>
  lectura: Lectura
  /** El texto del buscador. */
  buscar?: string
  /** El nombre del CSV, sin extensión. */
  archivo: string
  /** Más herramientas a la derecha (un botón de la vista). */
  extra?: ReactNode
  vacio?: string
  /** Una línea al pie del panel. */
  nota?: ReactNode
  /**
   * La búsqueda la hace la base: lo escrito se le pasa aquí y las filas ya
   * llegan filtradas (Pacientes, que son miles).
   */
  alBuscar?: (texto: string) => void
}) {
  const [texto, setTexto] = useState('')
  const [estado, setEstado] = useState('Todos')

  const estados = useMemo(() => ['Todos', ...new Set(filas.map((f) => f.estado))], [filas])
  const estadoElegido = estados.includes(estado) ? estado : 'Todos'
  const vistas = useMemo(() => {
    const aguja = alBuscar ? '' : texto.trim().toLowerCase()
    return filas.filter(
      (f) =>
        (estadoElegido === 'Todos' || f.estado === estadoElegido) &&
        (!aguja || [...f.textos, f.estado].join(' ').toLowerCase().includes(aguja)),
    )
  }, [filas, texto, estadoElegido, alBuscar])

  function exportar() {
    const celda = (v: string) => `"${v.replaceAll('"', '""')}"`
    const cuerpo = [[...columnas.map((c) => c.rotulo), 'Estado'], ...vistas.map((f) => [...f.textos, f.estado])]
      .map((fila) => fila.map(celda).join(','))
      .join('\r\n')
    // La marca BOM delante: sin ella, Excel abre las tildes como «Ã³».
    const url = URL.createObjectURL(new Blob([String.fromCharCode(0xfeff) + cuerpo], { type: 'text/csv;charset=utf-8' }))
    const a = document.createElement('a')
    a.href = url
    a.download = `helios-${archivo}.csv`
    a.click()
    URL.revokeObjectURL(url)
  }

  const ancho = columnas.length + 2

  return (
    <>
      <div className="lt-herramientas">
        <input
          className="lt-campo"
          type="search"
          value={texto}
          onChange={(e) => {
            setTexto(e.target.value)
            alBuscar?.(e.target.value)
          }}
          placeholder={buscar}
          aria-label={buscar}
        />
        <FiltroDeEstado estados={estados} valor={estadoElegido} onCambio={setEstado} />
        <button type="button" className="lt-boton-suave" onClick={exportar} disabled={vistas.length === 0}>
          Exportar CSV
        </button>
        {extra}
      </div>

      <section className="lt-panel">
        <div className="lt-panel-cabeza">
          <div>
            <h2>{titulo}</h2>
            <p>{ayuda}</p>
          </div>
          {!lectura.cargando && !lectura.fallo && (
            <span className="lt-etiqueta">
              {vistas.length} {vistas.length === 1 ? 'registro' : 'registros'}
            </span>
          )}
        </div>
        <div className="lt-desliza">
          <table className="lt-tabla">
            <thead>
              <tr>
                {columnas.map((c) => (
                  <th key={c.rotulo} className={c.numero ? 'lt-num' : undefined}>
                    {c.rotulo}
                  </th>
                ))}
                <th>Estado</th>
                <th>
                  <span className="sr-only">Abrir</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {lectura.cargando && <FilaDeAviso columnas={ancho}>Leyendo…</FilaDeAviso>}
              {lectura.fallo && (
                <FilaDeAviso columnas={ancho}>
                  No se pudo leer.{' '}
                  {lectura.reintentar && (
                    <button type="button" className="lt-boton-texto" onClick={lectura.reintentar}>
                      Reintentar
                    </button>
                  )}
                </FilaDeAviso>
              )}
              {!lectura.cargando && !lectura.fallo && vistas.length === 0 && (
                <FilaDeAviso columnas={ancho}>{filas.length === 0 ? vacio : 'Nada coincide con la búsqueda.'}</FilaDeAviso>
              )}
              {vistas.map((f) => (
                <tr key={f.id}>
                  {f.celdas.map((c, i) => (
                    <td key={i} className={columnas[i]?.numero ? 'lt-num' : undefined}>
                      {c}
                    </td>
                  ))}
                  <td>
                    <span className="lt-etiqueta" data-tono={f.tono}>
                      {f.estado}
                    </span>
                  </td>
                  <td style={{ textAlign: 'right' }}>{f.abrir}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {nota && <div className="lt-nota">{nota}</div>}
      </section>
    </>
  )
}

function FilaDeAviso({ columnas, children }: { columnas: number; children: ReactNode }) {
  return (
    <tr>
      <td colSpan={columnas} className="lt-vacio">
        {children}
      </td>
    </tr>
  )
}

/** «Todos ⌄»: el estado de la última columna, en el menú de vidrio. */
function FiltroDeEstado({ estados, valor, onCambio }: { estados: string[]; valor: string; onCambio: (e: string) => void }) {
  const { abierto, setAbierto, caja } = useMenu()
  return (
    <div ref={caja} className="lt-periodo">
      <button
        type="button"
        className="lt-boton-suave"
        aria-haspopup="menu"
        aria-expanded={abierto}
        onClick={() => setAbierto((v) => !v)}
      >
        {valor} <ChevronDown size={13} aria-hidden />
      </button>
      {abierto && (
        <div className="lt-periodo-menu" role="menu" aria-label="Filtrar por estado" style={{ left: 0, right: 'auto' }}>
          {estados.map((e) => (
            <button
              key={e}
              type="button"
              role="menuitemradio"
              aria-checked={e === valor}
              onClick={() => {
                onCambio(e)
                setAbierto(false)
              }}
            >
              {e}
              <span aria-hidden>{e === valor ? '✓' : ''}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

/**
 * La pantalla de una ruta en cada versión: la de Lite si Lite está elegido y
 * quien mira es del equipo de Helios (super admin u operador); si no, la de
 * Pro. El rol de la agenda y el capacitador no tienen Lite: su marco es el
 * reducido de Pro.
 *
 * `entiende`: las claves de la búsqueda que la pantalla de Lite sabe leer
 * (por defecto, ninguna o `vista`). Si la dirección trae otra —un enlace a
 * una acción de Pro, como `?asignar=` un abono o `?clinica=` en
 * Seguimiento—, se abre la pantalla de Pro con esa acción, dentro del marco
 * de Lite. `'todas'`: la pantalla de Lite siempre (Ajustes).
 */
export function conLite(
  Pro: ComponentType,
  Lite: ComponentType,
  entiende: ReadonlyArray<string> | 'todas' = ['vista'],
): () => React.JSX.Element {
  function PaginaEnSuVersion() {
    const version = useVersionDelAdmin()
    const rol = useRolDelEquipo()
    // Las claves como un texto: un arreglo nuevo en cada lectura repintaría
    // la pantalla con cada movimiento del router.
    const claves = useRouterState({
      select: (s) => Object.keys((s.location.search as Record<string, unknown> | undefined) ?? {}).join(','),
    })
    const delEquipo = rol === 'super_admin' || rol === 'operador'
    const laEntiende = entiende === 'todas' || claves === '' || claves.split(',').every((k) => entiende.includes(k))
    return version === 'lite' && delEquipo && laEntiende ? <Lite /> : <Pro />
  }
  return PaginaEnSuVersion
}
