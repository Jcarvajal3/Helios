import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { FichaDelLead } from '@/components/admin/agenda/FichaDelLead'
import { FormularioDeLead } from '@/components/admin/agenda/FormularioDeLead'
import { useToast } from '@/components/Toast'
import { diaOperativo } from '@/components/ui'
import { asignarmeMedicos, consultaAgenda, refrescarAgenda } from '@/features/admin/agenda/api'
import {
  ESTADO_DEL_LEAD,
  ROTULO_FASE,
  ROTULO_MODO,
  delAlcance,
  filtrarAgenda,
  ordenarAgenda,
} from '@/features/admin/agenda/agenda'
import type { Lead } from '@/features/admin/agenda/agenda'
import { useSession } from '@/features/auth/session'
import { CabeceraLite, Pildoras, inicialesDeMedico } from './kit'

/**
 * La Agenda de Helios Lite, con la estructura de la maqueta: tres números
 * arriba, «Traer médicos», cuatro vistas (Mis médicos, Sin encargado,
 * Visitas agendadas, Todos), el buscador y una tabla.
 *
 * Los datos y las acciones son los de Pro: «Traer médicos» es «Asignarme»
 * (hasta 20 por contactar por persona) y «Abrir contacto» abre la ficha del
 * médico de Pro (`FichaDelLead`), con sus gestiones, la visita y la edición.
 * No están aquí las tres fases, el calendario ni la actividad del equipo.
 */
type Vista = 'mios' | 'sin_asignar' | 'visitas' | 'todos'

const VISTAS: ReadonlyArray<{ id: Vista; rotulo: string }> = [
  { id: 'mios', rotulo: 'Mis médicos' },
  { id: 'sin_asignar', rotulo: 'Sin encargado' },
  { id: 'visitas', rotulo: 'Visitas agendadas' },
  { id: 'todos', rotulo: 'Todos' },
]

/** Cuántos médicos por contactar puede tener cada persona con «Traer médicos» (20261029140000). */
const POR_TANDA = 20

const ENTERO = new Intl.NumberFormat('es-VE')

const terminado = (l: Lead) => l.estado === 'convertido' || l.estado === 'descartado'

export function AgendaLite() {
  const yo = useSession()?.user.id ?? null
  const client = useQueryClient()
  const avisar = useToast()
  const [vista, setVista] = useState<Vista>('mios')
  const [texto, setTexto] = useState('')
  const [abiertoId, setAbiertoId] = useState<string | null>(null)
  const [editando, setEditando] = useState<Lead | null>(null)

  const hoy = diaOperativo()
  const ahora = useMemo(() => new Date(), [])
  const agenda = useQuery(consultaAgenda())
  const todos = useMemo(() => agenda.data ?? [], [agenda.data])

  const misPorContactar = todos.filter((l) => yo !== null && l.responsableId === yo && l.estado === 'nuevo').length
  const sinEncargado = todos.filter((l) => l.responsableId === null && !terminado(l)).length
  const visitas = todos.filter((l) => l.estado === 'reunion').length
  const libres = todos.filter((l) => l.responsableId === null && l.estado === 'nuevo').length
  const meTocan = Math.min(Math.max(0, POR_TANDA - misPorContactar), libres)

  const filas = useMemo(() => {
    const deLaVista =
      vista === 'visitas'
        ? todos.filter((l) => l.estado === 'reunion')
        : vista === 'sin_asignar'
          ? todos.filter((l) => l.responsableId === null && !terminado(l))
          : delAlcance(todos, vista === 'mios' ? 'mios' : 'todos', yo)
    const ordenadas = ordenarAgenda(filtrarAgenda(deLaVista, { texto }), hoy, ahora)
    // Los que nos contactaron ellos, primero: por la web y luego por el QR.
    const puesto = (l: (typeof ordenadas)[number]) => (l.webEl !== null ? 0 : l.qrEl !== null ? 1 : 2)
    return [...ordenadas].sort((a, b) => puesto(a) - puesto(b))
  }, [todos, vista, texto, yo, hoy, ahora])

  const asignar = useMutation({
    mutationFn: () => asignarmeMedicos(POR_TANDA),
    onSuccess: (n) => {
      refrescarAgenda(client)
      avisar(n === 0 ? 'No quedan médicos por contactar sin encargado.' : `Te ${n === 1 ? 'tocó 1 médico' : `tocaron ${n} médicos`} por contactar.`)
      if (n > 0) setVista('mios')
    },
  })

  const abierto = abiertoId ? todos.find((l) => l.id === abiertoId) : undefined
  const motivo =
    meTocan === 0
      ? misPorContactar >= POR_TANDA
        ? `Ya tienes ${misPorContactar} por contactar: escríbeles antes de pedir más.`
        : 'No quedan médicos por contactar sin encargado.'
      : `Te tocan ${meTocan} de los ${libres} sin encargado.`

  return (
    <>
      <CabeceraLite
        titulo="Agenda"
        descripcion="Contactos y visitas de capacitación, con fecha, dirección y teléfono."
      />

      <div className="lt-agenda-cuentas">
        <div>
          <strong>{agenda.data ? ENTERO.format(misPorContactar) : '—'}</strong>Por contactar · mis médicos
        </div>
        <div>
          <strong>{agenda.data ? ENTERO.format(sinEncargado) : '—'}</strong>Sin encargado
        </div>
        <div>
          <strong>{agenda.data ? ENTERO.format(visitas) : '—'}</strong>Visitas de capacitación
        </div>
      </div>

      <div className="lt-herramientas">
        <button
          type="button"
          className="lt-boton-suave"
          disabled={asignar.isPending || meTocan === 0}
          title={motivo}
          onClick={() => asignar.mutate()}
        >
          <span aria-hidden>+</span> {asignar.isPending ? 'Trayendo…' : 'Traer médicos'}
        </button>
        <span className="lt-leyenda" style={{ margin: 0 }}>
          Hasta {POR_TANDA} nuevos pendientes por persona
        </span>
      </div>

      <Pildoras opciones={VISTAS} valor={vista} onCambio={setVista} etiqueta="Vistas de Agenda" />

      <div className="lt-herramientas">
        <input
          className="lt-campo"
          type="search"
          value={texto}
          onChange={(e) => setTexto(e.target.value)}
          placeholder="Buscar médico, especialidad, dirección o teléfono"
          aria-label="Buscar en la Agenda"
        />
      </div>
      <p className="lt-leyenda">Hora de Venezuela · los vencidos permanecen visibles hasta registrar el resultado.</p>

      <section className="lt-panel">
        <div className="lt-desliza">
          <table className="lt-tabla">
            <thead>
              <tr>
                <th>Médico</th>
                <th>Encargado / fase</th>
                <th>Visita de capacitación</th>
                <th>Dirección exacta / contacto</th>
                <th>Próximo contacto</th>
                <th>Estado</th>
                <th>
                  <span className="sr-only">Abrir</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {agenda.isPending && (
                <tr>
                  <td colSpan={7} className="lt-vacio">
                    Leyendo la Agenda…
                  </td>
                </tr>
              )}
              {agenda.isError && (
                <tr>
                  <td colSpan={7} className="lt-vacio">
                    No se pudo leer la Agenda.{' '}
                    <button type="button" className="lt-boton-texto" onClick={() => void agenda.refetch()}>
                      Reintentar
                    </button>
                  </td>
                </tr>
              )}
              {agenda.isSuccess && filas.length === 0 && (
                <tr>
                  <td colSpan={7} className="lt-vacio">
                    No hay médicos en esta vista.
                  </td>
                </tr>
              )}
              {filas.map((l) => (
                <FilaDeLaAgenda key={l.id} lead={l} ahora={ahora} onAbrir={() => setAbiertoId(l.id)} />
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {abierto && !editando && (
        <FichaDelLead
          key={abierto.id}
          lead={abierto}
          hoy={hoy}
          ahora={ahora}
          onEditar={() => setEditando(abierto)}
          onClose={() => setAbiertoId(null)}
        />
      )}

      {editando && (
        <FormularioDeLead
          lead={editando}
          yo={yo}
          onGuardado={(g) => {
            setEditando(null)
            setAbiertoId(g.id)
          }}
          onClose={() => setEditando(null)}
        />
      )}
    </>
  )
}

function FilaDeLaAgenda({ lead: l, ahora, onAbrir }: { lead: Lead; ahora: Date; onAbrir: () => void }) {
  const vencida = l.estado === 'reunion' && l.reunion !== null && new Date(l.reunion) < ahora
  const estado = vencida ? 'Vencido · sin resultado' : ESTADO_DEL_LEAD[l.estado].label

  return (
    <tr>
      <td>
        <div className="lt-medico">
          <span className="lt-medico-avatar" aria-hidden>
            {inicialesDeMedico(l.nombre)}
          </span>
          <div>
            <strong>{l.nombre}</strong>
            {l.webEl && (
              <span className="lt-etiqueta" data-tono="verde" style={{ marginTop: 5 }}>
                ★ Prioridad · Web · nos contactó
              </span>
            )}
            {l.qrEl && (
              <span className="lt-etiqueta" data-tono="verde" style={{ marginTop: 5 }}>
                ★ Prioridad · QR · nos contactó
              </span>
            )}
            <small>{l.especialidad ?? 'Sin especialidad'}</small>
          </div>
        </div>
      </td>
      <td>
        {l.responsable ?? 'Sin encargado'}
        <div className="lt-celda-sub">{ROTULO_FASE[l.fase].label}</div>
      </td>
      <td>
        <strong style={{ fontWeight: 600 }}>{l.reunion ? fechaYHora(l.reunion) : 'Sin programar'}</strong>
        <div className="lt-celda-sub">
          {l.reunion ? (l.modo ? ROTULO_MODO[l.modo] : 'Visita') : 'Visita aún no agendada'}
        </div>
      </td>
      <td>
        <div>{l.direccion ?? 'Dirección pendiente'}</div>
        <div className="lt-celda-sub">{l.telefono ?? 'Teléfono pendiente'}</div>
      </td>
      <td>{l.volverEl ? fechaDelDia(l.volverEl) : 'Sin programar'}</td>
      <td>
        <span className="lt-etiqueta" data-tono={vencida ? 'ambar' : l.estado === 'convertido' ? 'verde' : undefined}>
          {estado}
        </span>
      </td>
      <td style={{ textAlign: 'right' }}>
        <button type="button" className="lt-boton-texto" onClick={onAbrir}>
          Abrir contacto →
        </button>
      </td>
    </tr>
  )
}

function fechaYHora(instante: string): string {
  return new Intl.DateTimeFormat('es-VE', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'America/Caracas' }).format(
    new Date(instante),
  )
}

function fechaDelDia(dia: string): string {
  return new Date(`${dia}T12:00:00-04:00`).toLocaleDateString('es-VE', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: 'America/Caracas',
  })
}
