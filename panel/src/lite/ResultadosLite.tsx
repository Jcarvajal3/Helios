import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { resumirPromesasDeHoy, ordenarComoLaCartera } from '@/components/admin/inicio/colas'
import { consultaCaja, consultaDeudaConLocales } from '@/components/admin/inicio/consultas'
import { diaOperativo, formatUsd } from '@/components/ui'
import { sumarDias } from '@/components/kit/rango'
import { consultaCartera, consultaPromesas } from '@/features/admin/cobranza/consultas'
import { RESULTADO } from '@/features/admin/cobranza/gestion'
import type { CollectionRow } from '@/features/admin/cobranza/cartera'
import type { MerchantPayable } from '@/features/admin/api'
import { consultaRecuperado } from '@/features/admin/metricas/cobranza/api'
import {
  CabeceraLite,
  CifraDeFranja,
  Franja,
  Pildoras,
  SelectorDePeriodo,
  cambio,
  diasDe,
  inicialesDeMedico,
  textoDeCambio,
} from './kit'
import type { Periodo } from './kit'

/**
 * Resultados de Helios Lite: la pantalla «Cobranza y caja» de la maqueta.
 *
 *   Cobranza  deuda vencida, por vencer, lo recuperado en el periodo y las
 *             promesas de hoy; y los pacientes con algo vencido.
 *   Caja      la caja, lo que se debe a los médicos y la Comisión Helios;
 *             y los pagos previstos a cada médico.
 *
 * Con las mismas lecturas que Pro. Lo que no cabe aquí (cohortes, riesgo,
 * proyección, las métricas por semana…) sigue en «Más vistas del admin
 * original», que abre las Métricas de Pro: `/admin/metricas?vista=…`.
 */
type Vista = 'cobranza' | 'caja'

const VISTAS: ReadonlyArray<{ id: Vista; rotulo: string }> = [
  { id: 'cobranza', rotulo: 'Cobranza' },
  { id: 'caja', rotulo: 'Caja' },
]

/** Las pestañas de Métricas de Pro, para «Más vistas del admin original». */
const VISTAS_ORIGINALES: ReadonlyArray<{ vista: string; rotulo: string }> = [
  { vista: 'juan-pablo', rotulo: 'Resumen de negocio' },
  { vista: 'semana', rotulo: 'Semana' },
  { vista: 'cobros', rotulo: 'Cobros y cohortes' },
  { vista: 'mora', rotulo: 'Riesgo' },
  { vista: 'caja', rotulo: 'Caja y proyección' },
  { vista: 'locales', rotulo: 'Actividad por clínica' },
  { vista: 'gente', rotulo: 'Pacientes' },
  { vista: 'global', rotulo: 'Global' },
]

const ENTERO = new Intl.NumberFormat('es-VE')

export function ResultadosLite() {
  const [vista, setVista] = useState<Vista>('cobranza')
  const [periodo, setPeriodo] = useState<Periodo>('7d')

  return (
    <>
      <CabeceraLite
        titulo="Cobranza y caja"
        descripcion="Deuda, recuperación y disponibilidad para pagos."
        derecha={vista === 'cobranza' ? <SelectorDePeriodo periodo={periodo} onCambio={setPeriodo} /> : undefined}
      />
      <Pildoras opciones={VISTAS} valor={vista} onCambio={setVista} etiqueta="Vistas de Cobranza y caja" />

      {vista === 'cobranza' ? <Cobranza periodo={periodo} /> : <Caja />}

      <details className="lt-desplegable">
        <summary>Más vistas del admin original</summary>
        <p>Las métricas completas: periodos propios, cohortes maduras, gracia, riesgo, exposición y proyección de caja.</p>
        <div className="lt-herramientas" style={{ margin: 0 }}>
          {VISTAS_ORIGINALES.map((v) => (
            <Link
              key={v.vista}
              to="/admin/metricas"
              search={{ vista: v.vista } as never}
              className="lt-boton-suave"
            >
              {v.rotulo}
            </Link>
          ))}
        </div>
      </details>
    </>
  )
}

// ── Cobranza ───────────────────────────────────────────────────────────────

function Cobranza({ periodo }: { periodo: Periodo }) {
  const dias = diasDe(periodo)
  const hoy = diaOperativo()
  const desde = sumarDias(hoy, -(dias - 1))

  const cartera = useQuery(consultaCartera())
  const promesas = useQuery(consultaPromesas())
  const recuperado = useQuery(consultaRecuperado(desde, hoy, null))
  const recuperadoAntes = useQuery(consultaRecuperado(sumarDias(hoy, -(2 * dias - 1)), sumarDias(hoy, -dias), null))

  const filas = cartera.data?.rows ?? []
  const vencidos = ordenarComoLaCartera(filas.filter((f) => f.overdueUsd > 0))
  const porVencer = filas.filter((f) => f.upcomingUsd > 0)
  const ahora = recuperado.data?.recuperado.usd
  const antes = recuperadoAntes.data?.recuperado.usd
  const delta = ahora !== undefined && antes !== undefined ? cambio(ahora, antes) : undefined
  const deHoy = promesas.data ? resumirPromesasDeHoy(promesas.data).cantidad : undefined

  return (
    <>
      <Franja>
        <CifraDeFranja
          rotulo="Deuda vencida"
          a="/admin/cobranza"
          valor={cartera.data && formatUsd(vencidos.reduce((s, f) => s + f.overdueUsd, 0))}
          destacado={cartera.data && ENTERO.format(vencidos.length)}
          pie={vencidos.length === 1 ? 'paciente' : 'pacientes'}
          fallo={cartera.isError}
          reintentar={() => void cartera.refetch()}
        />
        <CifraDeFranja
          rotulo="Por vencer"
          a="/admin/cobranza"
          valor={cartera.data && formatUsd(porVencer.reduce((s, f) => s + f.upcomingUsd, 0))}
          destacado={cartera.data && ENTERO.format(porVencer.length)}
          pie="pacientes con cuotas en 7 días"
          fallo={cartera.isError}
          reintentar={() => void cartera.refetch()}
        />
        <CifraDeFranja
          rotulo="Recuperado"
          valor={ahora === undefined ? undefined : formatUsd(ahora)}
          destacado={delta === undefined ? undefined : textoDeCambio(delta)}
          pie={delta === undefined ? 'de lo vencido, en el periodo' : 'respecto al periodo anterior'}
          fallo={recuperado.isError}
          reintentar={() => void recuperado.refetch()}
        />
        <CifraDeFranja
          rotulo="Promesas para hoy"
          a="/admin/cobranza"
          valor={deHoy === undefined ? undefined : ENTERO.format(deHoy)}
          pie={deHoy ? 'requieren seguimiento' : 'ninguna vence hoy'}
          fallo={promesas.isError}
          reintentar={() => void promesas.refetch()}
        />
      </Franja>

      <section className="lt-panel">
        <div className="lt-panel-cabeza">
          <h2>Pendientes de seguimiento</h2>
          {cartera.data && <span className="lt-etiqueta">{ENTERO.format(vencidos.length)} pacientes</span>}
        </div>
        <div className="lt-desliza">
          <table className="lt-tabla">
            <thead>
              <tr>
                <th>Paciente</th>
                <th className="lt-num">Vencido</th>
                <th>Atraso</th>
                <th>Última gestión</th>
                <th>Estado</th>
                <th>
                  <span className="sr-only">Abrir</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {cartera.isPending && <FilaVacia columnas={6}>Leyendo…</FilaVacia>}
              {cartera.isError && <FilaVacia columnas={6}>No se pudo leer la cartera.</FilaVacia>}
              {cartera.isSuccess && vencidos.length === 0 && <FilaVacia columnas={6}>Nadie tiene cuotas vencidas.</FilaVacia>}
              {vencidos.slice(0, 50).map((f) => (
                <FilaDeCobranza key={f.userId} fila={f} />
              ))}
            </tbody>
          </table>
        </div>
        {vencidos.length > 50 && (
          <div className="lt-nota">
            Se ven los 50 primeros, en el orden de trabajo de la cartera.{' '}
            <Link to="/admin/cobranza" className="lt-boton-texto">
              Ver los {ENTERO.format(vencidos.length)} →
            </Link>
          </div>
        )}
      </section>
    </>
  )
}

function FilaDeCobranza({ fila: f }: { fila: CollectionRow }) {
  const gestion = f.lastContactAt
    ? `${f.lastContactOutcome ? RESULTADO[f.lastContactOutcome].label : 'Gestión'} · ${fechaCorta(f.lastContactAt)}`
    : 'Sin contactar'
  const estado = f.promiseDate ? 'Promesa de pago' : f.contactedSinceDue ? 'En gestión' : 'Pendiente'

  return (
    <tr>
      <td>
        <strong style={{ fontWeight: 550 }}>{f.fullName ?? 'Sin nombre'}</strong>
        {f.merchants[0] && <div className="lt-celda-sub">{f.merchants[0]}</div>}
      </td>
      <td className="lt-num">{formatUsd(f.overdueUsd)}</td>
      <td>{f.daysOverdue === 1 ? '1 día' : `${ENTERO.format(f.daysOverdue)} días`}</td>
      <td>{gestion}</td>
      <td>
        <span className="lt-etiqueta" data-tono={estado === 'Pendiente' ? 'ambar' : 'verde'}>
          {estado}
        </span>
      </td>
      <td style={{ textAlign: 'right' }}>
        <Link to="/admin/pacientes/$id" params={{ id: f.userId }} className="lt-boton-texto">
          Revisar →
        </Link>
      </td>
    </tr>
  )
}

// ── Caja ───────────────────────────────────────────────────────────────────

function Caja() {
  const caja = useQuery(consultaCaja())
  const deuda = useQuery(consultaDeudaConLocales())

  const medicos = (deuda.data ?? []).filter((m) => !m.isTest && m.totalPendingUsd > 0)
  const previstos = [...medicos].sort((a, b) => a.nextRunDate.localeCompare(b.nextRunDate) || b.nextRunUsd - a.nextRunUsd)
  const porPagar = medicos.reduce((s, m) => s + m.totalPendingUsd, 0)
  const transferencias = medicos.filter((m) => m.nextRunUsd > 0).length

  return (
    <>
      <Franja>
        <CifraDeFranja
          rotulo="Caja disponible"
          valor={caja.data && formatUsd(caja.data.cash)}
          pie="según el libro"
          fallo={caja.isError}
          reintentar={() => void caja.refetch()}
        />
        <CifraDeFranja
          rotulo="Por pagar a médicos"
          a="/admin/pagos-clinicas"
          valor={deuda.data && formatUsd(porPagar)}
          destacado={deuda.data && ENTERO.format(transferencias)}
          pie="transferencias previstas"
          fallo={deuda.isError}
          reintentar={() => void deuda.refetch()}
        />
        <CifraDeFranja
          rotulo="Comisión cobrada"
          valor={caja.data && formatUsd(caja.data.commissionCollected)}
          pie="la que los pacientes ya pagaron"
          fallo={caja.isError}
          reintentar={() => void caja.refetch()}
        />
        <CifraDeFranja
          rotulo="Comisión generada"
          valor={caja.data && formatUsd(caja.data.platformRevenue)}
          pie="al confirmarse cada consulta"
          fallo={caja.isError}
          reintentar={() => void caja.refetch()}
        />
      </Franja>

      <section className="lt-panel">
        <div className="lt-panel-cabeza">
          <h2>Pagos previstos</h2>
          {deuda.data && <span className="lt-etiqueta">{ENTERO.format(previstos.length)} médicos</span>}
        </div>
        <div className="lt-desliza">
          <table className="lt-tabla">
            <thead>
              <tr>
                <th>Médico</th>
                <th className="lt-num">Por transferir</th>
                <th>Fecha prevista</th>
                <th>Concepto</th>
                <th>Estado</th>
                <th>
                  <span className="sr-only">Abrir</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {deuda.isPending && <FilaVacia columnas={6}>Leyendo…</FilaVacia>}
              {deuda.isError && <FilaVacia columnas={6}>No se pudo leer lo que se debe a los médicos.</FilaVacia>}
              {deuda.isSuccess && previstos.length === 0 && <FilaVacia columnas={6}>No hay pagos pendientes.</FilaVacia>}
              {previstos.map((m) => (
                <FilaDeCaja key={m.merchantId} medico={m} />
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </>
  )
}

function FilaDeCaja({ medico: m }: { medico: MerchantPayable }) {
  const nombre = m.doctorName ?? m.merchantName
  const atrasado = m.overdueUsd > 0
  const monto = m.nextRunUsd > 0 ? m.nextRunUsd : m.totalPendingUsd
  const fecha = m.nextRunUsd > 0 ? m.nextRunDate : (m.proximoPago?.fecha ?? m.nextRunDate)

  return (
    <tr>
      <td>
        <div className="lt-medico">
          <span className="lt-medico-avatar" aria-hidden>
            {inicialesDeMedico(nombre)}
          </span>
          <strong>{nombre}</strong>
        </div>
      </td>
      <td className="lt-num">{formatUsd(monto)}</td>
      <td>{fecha === m.todayDate ? 'Hoy' : fechaCorta(fecha)}</td>
      <td>Consultas</td>
      <td>
        <span className="lt-etiqueta" data-tono={atrasado ? 'ambar' : undefined}>
          {atrasado ? 'Atrasado' : 'Pendiente'}
        </span>
      </td>
      <td style={{ textAlign: 'right' }}>
        <Link to="/admin/pagos-clinicas/$id" params={{ id: m.merchantId }} className="lt-boton-texto">
          Revisar →
        </Link>
      </td>
    </tr>
  )
}

// ── Comunes ────────────────────────────────────────────────────────────────

function FilaVacia({ columnas, children }: { columnas: number; children: React.ReactNode }) {
  return (
    <tr>
      <td colSpan={columnas} className="lt-vacio">
        {children}
      </td>
    </tr>
  )
}

/** «5 nov.» de un día o un instante, en Caracas. */
export function fechaCorta(valor: string): string {
  const instante = valor.length === 10 ? new Date(`${valor}T12:00:00-04:00`) : new Date(valor)
  return instante.toLocaleDateString('es-VE', { day: 'numeric', month: 'short', timeZone: 'America/Caracas' })
}
