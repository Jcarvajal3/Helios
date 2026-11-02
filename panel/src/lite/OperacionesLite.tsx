import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { ExportacionContable } from '@/components/admin/ExportacionContable'
import { Libro } from '@/components/admin/Libro'
import type { FiltrosLibro } from '@/components/admin/Libro'
import { destinoDeAlerta } from '@/components/admin/alertas/TablaDeAlertas'
import { ListaDelCierre } from '@/components/admin/caja/ListaDelCierre'
import { fetchPorCobrar } from '@/components/admin/calendario-de-cobro/usePorCobrar'
import { consultaAbonosSinDueno, consultaDeudaConLocales, consultaPagosPorAprobar } from '@/components/admin/inicio/consultas'
import { ordenarComoLaCartera } from '@/components/admin/inicio/colas'
import { diaOperativo, formatUsd, formatVes } from '@/components/ui'
import { sumarDias } from '@/components/kit/rango'
import { fetchMerchantPayouts } from '@/features/admin/api'
import { fetchRevisionBot } from '@/features/admin/avisosBncApi'
import type { DecisionBot } from '@/features/admin/avisosBnc'
import { consultaCartera, consultaPromesas } from '@/features/admin/cobranza/consultas'
import type { CollectionRow } from '@/features/admin/cobranza/cartera'
import { estadoDe } from '@/features/admin/estados'
import { fetchRevisionLector } from '@/features/admin/lectorComprobantesApi'
import { ESTADO_DE_LA_LECTURA } from '@/features/admin/lectorComprobantes'
import { consultaDeLaLista } from '@/features/admin/metricas/cohortes/consultas'
import { pastillaDeSemana } from '@/features/admin/metricas/cohortes/estados'
import { rotuloDeSemana } from '@/features/admin/metricas/cohortes/semanas'
import { fetchAlertas } from '@/features/admin/riesgo/consultas'
import { GRAVEDAD, ROTULO_TIPO_ALERTA } from '@/features/admin/riesgo/alertas'
import { fechaCorta } from './ResultadosLite'
import { EspacioDeTrabajo, Opciones } from './espacio'
import type { Fila, Lectura } from './espacio'

/**
 * Operaciones de Helios Lite, como el espacio de trabajo de la maqueta: cada
 * pestaña con sus vistas en botones y, en cada vista, una tabla con su
 * buscador, su filtro de estado y su CSV. «Abrir caso» lleva a la ficha de
 * Pro, donde se aprueba, se asigna o se registra.
 */

/** El tono de una etiqueta de Pro, en los dos de la maqueta. */
export function tonoDe(tono: string): Fila['tono'] {
  if (tono === 'warning' || tono === 'error') return 'ambar'
  if (tono === 'success') return 'verde'
  return undefined
}

/** Lo que el espacio necesita saber de una consulta. */
export function lecturaDe(q: { isPending: boolean; isError: boolean; refetch: () => unknown }): Lectura {
  return { cargando: q.isPending, fallo: q.isError, reintentar: () => void q.refetch() }
}

export /**
 * El enlace de una fila. Recibe la ruta ya armada (`to`, `params`, `search`):
 * cada vista lleva a una ficha distinta, así que aquí el enlace no se tipa por
 * ruta.
 */
const EnlaceSuelto = Link as unknown as (props: Record<string, unknown>) => React.JSX.Element

export function Abrir({ children = 'Abrir caso →', ...enlace }: { children?: ReactNode } & Record<string, unknown>) {
  return (
    <EnlaceSuelto {...enlace} className="lt-boton-texto">
      {children}
    </EnlaceSuelto>
  )
}

const ENTERO = new Intl.NumberFormat('es-VE')

// ── Pagos reportados (/admin/cobros) ───────────────────────────────────────

type VistaDeCobros = 'revision' | 'abonos' | 'bnc' | 'comprobantes'

export function CobrosLite() {
  const [vista, setVista] = useState<VistaDeCobros>('revision')
  return (
    <>
      <Opciones
        vistas={[
          { id: 'revision', rotulo: 'Revisión' },
          { id: 'abonos', rotulo: 'Abonos sin dueño' },
          { id: 'bnc', rotulo: 'Avisos BNC' },
          { id: 'comprobantes', rotulo: 'Comprobantes' },
        ]}
        valor={vista}
        onCambio={setVista}
      />
      {vista === 'revision' && <Revision />}
      {vista === 'abonos' && <Abonos />}
      {vista === 'bnc' && <AvisosBnc />}
      {vista === 'comprobantes' && <Comprobantes />}
    </>
  )
}

function Revision() {
  const q = useQuery(consultaPagosPorAprobar())
  const filas: Fila[] = (q.data ?? []).map((p) => {
    const estado = estadoDe('pago', p.status)
    return {
      id: p.reportId,
      celdas: [p.fullName ?? 'Sin nombre', formatVes(p.amountVes), p.reference ?? '—', fechaCorta(p.createdAt)],
      textos: [p.fullName ?? '', formatVes(p.amountVes), p.reference ?? '', fechaCorta(p.createdAt)],
      estado: estado.label,
      tono: tonoDe(estado.tone),
      abrir: <Abrir to="/admin/cobros/$id" params={{ id: p.reportId }} />,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Pagos reportados"
      ayuda="Contrasta lo reportado, el extracto y las cuotas antes de decidir."
      columnas={[{ rotulo: 'Paciente' }, { rotulo: 'Reportado · Bs', numero: true }, { rotulo: 'Referencia' }, { rotulo: 'Reportado el' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="pagos-reportados"
      vacio="No hay pagos por revisar."
    />
  )
}

function Abonos() {
  const q = useQuery(consultaAbonosSinDueno())
  const filas: Fila[] = (q.data ?? [])
    .filter((a) => a.deHelios)
    .map((a) => ({
      id: a.id,
      celdas: [a.reference || a.description || '—', formatVes(a.amountVes), fechaCorta(a.movedOn), a.bank || '—'],
      textos: [a.reference || a.description || '', formatVes(a.amountVes), fechaCorta(a.movedOn), a.bank || ''],
      estado: 'Sin identificar',
      tono: 'ambar' as const,
      abrir: <Abrir to="/admin/cobros" search={{ vista: 'abonos', asignar: a.id }}>Asignar →</Abrir>,
    }))
  return (
    <EspacioDeTrabajo
      titulo="Abonos sin dueño"
      ayuda="Movimientos recibidos que todavía no están asociados a un paciente."
      columnas={[{ rotulo: 'Movimiento' }, { rotulo: 'Importe · Bs', numero: true }, { rotulo: 'Fecha' }, { rotulo: 'Banco' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="abonos-sin-dueno"
      vacio="Todos los abonos tienen dueño."
    />
  )
}

const DECISION: Record<DecisionBot, string> = {
  ilegible: 'Ilegible',
  esperando: 'Esperando el pago',
  varios: 'Varios posibles',
  telefono_distinto: 'Teléfono distinto',
  remitente_ajeno: 'Remitente ajeno',
  ya_aprobado: 'Ya aprobado',
  aprobaria: 'Lo aprobaría',
  aprobado: 'Aprobado',
  error: 'Error',
}

function AvisosBnc() {
  const hoy = diaOperativo()
  const desde = sumarDias(hoy, -29)
  const q = useQuery({ queryKey: ['bank-sms-review', desde, hoy], queryFn: () => fetchRevisionBot(desde, hoy) })
  const filas: Fila[] = (q.data?.avisos ?? []).map((a, i) => ({
    id: `${a.recibidoEn}-${i}`,
    celdas: [a.remitente ?? 'BNC', a.referencia ?? '—', a.montoVes === null ? '—' : formatVes(a.montoVes), fechaCorta(a.recibidoEn)],
    textos: [a.remitente ?? '', a.referencia ?? '', a.montoVes === null ? '' : formatVes(a.montoVes), fechaCorta(a.recibidoEn)],
    estado: DECISION[a.decision],
    tono: a.decision === 'aprobado' || a.decision === 'ya_aprobado' ? 'verde' : a.decision === 'aprobaria' ? undefined : 'ambar',
    abrir: a.pago ? <Abrir to="/admin/cobros/$id" params={{ id: a.pago.id }}>Ver pago →</Abrir> : undefined,
  }))
  return (
    <EspacioDeTrabajo
      titulo="Avisos del BNC"
      ayuda="Los avisos del banco de los últimos 30 días, junto al pago que les corresponde."
      columnas={[{ rotulo: 'Aviso' }, { rotulo: 'Referencia' }, { rotulo: 'Monto · Bs', numero: true }, { rotulo: 'Recibido' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="avisos-bnc"
      vacio="No llegaron avisos del banco en estos días."
    />
  )
}

function Comprobantes() {
  const hoy = diaOperativo()
  const desde = sumarDias(hoy, -6)
  const q = useQuery({ queryKey: ['receipt-reads', desde, hoy], queryFn: () => fetchRevisionLector(desde, hoy) })
  const filas: Fila[] = (q.data?.lecturas ?? []).map((l, i) => {
    const estado = ESTADO_DE_LA_LECTURA[l.estado]
    return {
      id: `${l.llego}-${i}`,
      celdas: [l.persona || l.telefono || 'Sin identificar', l.referencia || '—', l.montoVes === null ? '—' : formatVes(l.montoVes), fechaCorta(l.llego)],
      textos: [l.persona || l.telefono || '', l.referencia || '', l.montoVes === null ? '' : formatVes(l.montoVes), fechaCorta(l.llego)],
      estado,
      abrir: l.reportId ? (
        <Abrir to="/admin/cobros/$id" params={{ id: l.reportId }} />
      ) : l.userId ? (
        <Abrir to="/admin/pacientes/$id" params={{ id: l.userId }}>Ver paciente →</Abrir>
      ) : undefined,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Comprobantes"
      ayuda="Las capturas que llegaron por WhatsApp esta semana y qué hizo el lector con cada una."
      columnas={[{ rotulo: 'Paciente' }, { rotulo: 'Referencia' }, { rotulo: 'Monto · Bs', numero: true }, { rotulo: 'Recibido' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="comprobantes"
      vacio="No llegaron comprobantes esta semana."
    />
  )
}

// ── Por cobrar (/admin/cobranza) ───────────────────────────────────────────

type VistaDeCobranza = 'cartera' | 'morosos' | 'cohortes' | 'calendario' | 'promesas'

export function CobranzaLite() {
  const [vista, setVista] = useState<VistaDeCobranza>('cartera')
  return (
    <>
      <Opciones
        vistas={[
          { id: 'cartera', rotulo: 'Cartera' },
          { id: 'morosos', rotulo: 'Morosos' },
          { id: 'cohortes', rotulo: 'Cohortes' },
          { id: 'calendario', rotulo: 'Calendario' },
          { id: 'promesas', rotulo: 'Promesas' },
        ]}
        valor={vista}
        onCambio={setVista}
      />
      {vista === 'cartera' && <Cartera />}
      {vista === 'morosos' && <Morosos />}
      {vista === 'cohortes' && <Cohortes />}
      {vista === 'calendario' && <Calendario />}
      {vista === 'promesas' && <Promesas />}
    </>
  )
}

function plazoDe(f: CollectionRow): { estado: string; tono: Fila['tono'] } {
  if (f.overdueUsd > 0) return { estado: 'Plazo vencido', tono: 'ambar' }
  if (f.bucket === 'vence_hoy') return { estado: 'Vence hoy', tono: 'ambar' }
  return { estado: 'Plazo vigente', tono: undefined }
}

function AbrirPaciente({ id }: { id: string }) {
  return <Abrir to="/admin/pacientes/$id" params={{ id }} search={{ tab: 'cobranza' }} />
}

function Cartera() {
  const q = useQuery(consultaCartera())
  const filas: Fila[] = ordenarComoLaCartera(q.data?.rows ?? []).map((f) => {
    const partes = f.overdueUsd > 0 ? f.overdueDesglose : f.upcomingDesglose
    const plazo = plazoDe(f)
    return {
      id: f.userId,
      celdas: [
        f.fullName ?? 'Sin nombre',
        partes ? formatUsd(partes.financedUsd) : '—',
        partes ? formatUsd(partes.feeUsd) : '—',
        formatUsd(f.overdueUsd > 0 ? f.overdueUsd : f.upcomingUsd),
      ],
      textos: [f.fullName ?? '', partes ? formatUsd(partes.financedUsd) : '', partes ? formatUsd(partes.feeUsd) : '', formatUsd(f.openUsd)],
      ...plazo,
      abrir: <AbrirPaciente id={f.userId} />,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Cartera por cobrar"
      ayuda="Lo que vence en los próximos 7 días y lo vencido, con el financiamiento y la Comisión Helios por separado."
      columnas={[{ rotulo: 'Paciente' }, { rotulo: 'Financiamiento', numero: true }, { rotulo: 'Comisión', numero: true }, { rotulo: 'Total', numero: true }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="cartera"
      vacio="No hay cuotas por cobrar."
    />
  )
}

function Morosos() {
  const q = useQuery(consultaCartera())
  const filas: Fila[] = ordenarComoLaCartera((q.data?.rows ?? []).filter((f) => f.overdueUsd > 0)).map((f) => ({
    id: f.userId,
    celdas: [f.fullName ?? 'Sin nombre', formatUsd(f.overdueUsd), ENTERO.format(f.daysOverdue), f.lastContactAt ? fechaCorta(f.lastContactAt) : 'Nunca'],
    textos: [f.fullName ?? '', formatUsd(f.overdueUsd), String(f.daysOverdue), f.lastContactAt ? fechaCorta(f.lastContactAt) : 'Nunca'],
    estado: f.promiseDate ? 'Promesa de pago' : f.contactedSinceDue ? 'Contactado' : 'Sin contactar',
    tono: f.contactedSinceDue || f.promiseDate ? undefined : 'ambar',
    abrir: <AbrirPaciente id={f.userId} />,
  }))
  return (
    <EspacioDeTrabajo
      titulo="Morosos"
      ayuda="Prioriza por atraso, en el orden de trabajo de la cartera."
      columnas={[{ rotulo: 'Paciente' }, { rotulo: 'Vencido', numero: true }, { rotulo: 'Días de atraso', numero: true }, { rotulo: 'Último contacto' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="morosos"
      vacio="Nadie tiene cuotas vencidas."
    />
  )
}

function Cohortes() {
  const hoy = diaOperativo()
  const q = useQuery(consultaDeLaLista(null))
  const filas: Fila[] = [...(q.data?.cohortes ?? [])]
    .sort((a, b) => b.semana.localeCompare(a.semana))
    .map((c) => {
      const pastilla = pastillaDeSemana(c, hoy)
      return {
        id: c.semana,
        celdas: [
          rotuloDeSemana(c.semana),
          formatUsd(c.consumoUsd),
          formatUsd(c.aCobrar.cobrado.importe.payableUsd),
          formatUsd(c.aCobrar.falta.importe.payableUsd),
        ],
        textos: [rotuloDeSemana(c.semana), formatUsd(c.consumoUsd), formatUsd(c.aCobrar.cobrado.importe.payableUsd), formatUsd(c.aCobrar.falta.importe.payableUsd)],
        estado: pastilla.texto,
        tono: tonoDe(pastilla.tono),
        abrir: <Abrir to="/admin/cobranza" search={{ vista: 'semana', cohorte: c.semana }}>Ver semana →</Abrir>,
      }
    })
  return (
    <EspacioDeTrabajo
      titulo="Cohortes de cobranza"
      ayuda="Cada semana de consultas: lo financiado, lo cobrado y lo que falta. Una semana incompleta no es un impago."
      columnas={[{ rotulo: 'Semana' }, { rotulo: 'Financiado', numero: true }, { rotulo: 'Cobrado', numero: true }, { rotulo: 'Falta', numero: true }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="cohortes"
    />
  )
}

function Calendario() {
  const hoy = diaOperativo()
  const desde = sumarDias(hoy, -7)
  const hasta = sumarDias(hoy, 14)
  const q = useQuery({ queryKey: ['lite', 'por-cobrar', desde, hasta], queryFn: () => fetchPorCobrar(desde, hasta, 'pendiente') })
  const filas: Fila[] = (q.data?.porDia ?? [])
    .filter((d) => d.cuotas > 0)
    .map((d) => ({
      id: d.dia,
      celdas: [d.dia === hoy ? 'Hoy' : fechaCorta(d.dia), ENTERO.format(d.personas), ENTERO.format(d.cuotasSinPagar), formatUsd(d.totalUsd)],
      textos: [fechaCorta(d.dia), String(d.personas), String(d.cuotasSinPagar), formatUsd(d.totalUsd)],
      estado: d.vencido ? 'Vencido' : d.dia === hoy ? 'Vence hoy' : 'Por vencer',
      tono: d.vencido || d.dia === hoy ? ('ambar' as const) : undefined,
      abrir: (
        <Abrir to="/admin/cobranza" search={{ vista: 'calendario', dia: d.dia }}>
          Ver el día →
        </Abrir>
      ),
    }))
  return (
    <EspacioDeTrabajo
      titulo="Calendario de cobro"
      ayuda="Qué vence cada día, de la semana pasada a dos semanas adelante, sin lo ya pagado."
      columnas={[{ rotulo: 'Fecha' }, { rotulo: 'Pacientes', numero: true }, { rotulo: 'Cuotas sin pagar', numero: true }, { rotulo: 'Por cobrar', numero: true }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="calendario-de-cobro"
      vacio="No vence nada en estos días."
    />
  )
}

function Promesas() {
  const q = useQuery(consultaPromesas())
  const filas: Fila[] = (q.data?.filas ?? []).map((p) => {
    const estado = estadoDe('promesa', p.estado)
    return {
      id: `${p.userId}-${p.fecha}`,
      celdas: [p.nombre ?? 'Sin nombre', fechaCorta(p.fecha), formatUsd(p.vencidoHoyUsd), p.telefono ?? '—'],
      textos: [p.nombre ?? '', fechaCorta(p.fecha), formatUsd(p.vencidoHoyUsd), p.telefono ?? ''],
      estado: estado.label,
      tono: tonoDe(estado.tone),
      abrir: <AbrirPaciente id={p.userId} />,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Promesas de pago"
      ayuda="Compromisos, fechas y cumplimiento. Una promesa no es un cobro."
      columnas={[{ rotulo: 'Paciente' }, { rotulo: 'Fecha prometida' }, { rotulo: 'Vencido hoy', numero: true }, { rotulo: 'Teléfono' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="promesas"
      vacio="No hay promesas de pago."
    />
  )
}

// ── Pagos a médicos (/admin/pagos-clinicas) ────────────────────────────────

type VistaDePagos = 'por_pagar' | 'transferencias'

export function PagosClinicasLite() {
  const [vista, setVista] = useState<VistaDePagos>('por_pagar')
  return (
    <>
      <Opciones
        vistas={[
          { id: 'por_pagar', rotulo: 'Por pagar' },
          { id: 'transferencias', rotulo: 'Transferencias' },
        ]}
        valor={vista}
        onCambio={setVista}
      />
      {vista === 'por_pagar' ? <PorPagar /> : <Transferencias />}
    </>
  )
}

function PorPagar() {
  const q = useQuery(consultaDeudaConLocales())
  const filas: Fila[] = (q.data ?? [])
    .filter((m) => !m.isTest && m.totalPendingUsd > 0)
    .sort((a, b) => a.nextRunDate.localeCompare(b.nextRunDate))
    .map((m) => {
      const nombre = m.doctorName ?? m.merchantName
      const dia = m.nextRunDate === m.todayDate ? 'Hoy' : fechaCorta(m.nextRunDate)
      return {
        id: m.merchantId,
        celdas: [nombre, formatUsd(m.nextRunUsd), formatUsd(m.totalPendingUsd), dia],
        textos: [nombre, formatUsd(m.nextRunUsd), formatUsd(m.totalPendingUsd), dia],
        estado: m.overdueUsd > 0 ? 'Atrasado' : m.nextRunUsd > 0 ? 'Por pagar' : 'Programado',
        tono: m.overdueUsd > 0 || m.nextRunUsd > 0 ? ('ambar' as const) : undefined,
        abrir: <Abrir to="/admin/pagos-clinicas/$id" params={{ id: m.merchantId }} />,
      }
    })
  return (
    <EspacioDeTrabajo
      titulo="Pagos a médicos y clínicas"
      ayuda="Lo que se debe a cada médico y su día de pago. Sin la Comisión Helios: la paga el paciente."
      columnas={[{ rotulo: 'Médico / clínica' }, { rotulo: 'Toca pagar', numero: true }, { rotulo: 'Pendiente total', numero: true }, { rotulo: 'Día' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="pagos-a-medicos"
      vacio="No se le debe nada a ningún médico."
    />
  )
}

function Transferencias() {
  const hoy = diaOperativo()
  const desde = sumarDias(hoy, -59)
  const q = useQuery({
    queryKey: ['merchant-payouts', null, desde, hoy, null, 200],
    queryFn: () => fetchMerchantPayouts({ from: desde, to: hoy, limit: 200 }),
  })
  const filas: Fila[] = (q.data ?? []).map((p) => ({
    id: p.id,
    celdas: [p.merchantName, formatUsd(p.amountUsd), p.reference ?? '—', fechaCorta(p.paidOn)],
    textos: [p.merchantName, formatUsd(p.amountUsd), p.reference ?? '', fechaCorta(p.paidOn)],
    estado: 'Registrada',
    tono: 'verde' as const,
    abrir: <Abrir to="/admin/pagos-clinicas/pago/$id" params={{ id: p.id }} />,
  }))
  return (
    <EspacioDeTrabajo
      titulo="Histórico de transferencias"
      ayuda="Qué se pagó a cada médico en los últimos 60 días, con su referencia."
      columnas={[{ rotulo: 'Destino' }, { rotulo: 'Importe', numero: true }, { rotulo: 'Referencia' }, { rotulo: 'Pagado el' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="transferencias"
      vacio="No hay transferencias en estos días."
    />
  )
}

// ── Contabilidad (/admin/contabilidad) ─────────────────────────────────────

type VistaDeContabilidad = 'cierre' | 'libro' | 'exportacion'

/**
 * El cierre, el libro y la exportación son las piezas de Pro (tienen sus
 * propias comprobaciones, filtros y descargas), dentro de un panel de la
 * maqueta.
 */
export function ContabilidadLite() {
  const hoy = diaOperativo()
  const esteMes = hoy.slice(0, 7)
  const [vista, setVista] = useState<VistaDeContabilidad>('cierre')
  const [mes, setMes] = useState(esteMes)
  const [filtros, setFiltros] = useState<FiltrosLibro>({})

  const paneles: Record<VistaDeContabilidad, { titulo: string; ayuda: string; contenido: ReactNode }> = {
    cierre: {
      titulo: 'Cierre de mes',
      ayuda: 'Comprueba los pendientes antes de exportar el cierre.',
      contenido: <ListaDelCierre mes={mes} hoy={hoy} />,
    },
    libro: {
      titulo: 'Libro de asientos',
      ayuda: 'Sigue la trazabilidad de cada movimiento.',
      contenido: <Libro filtros={filtros} onCambiar={(f) => setFiltros((previo) => ({ ...previo, ...f }))} />,
    },
    exportacion: {
      titulo: 'Exportación contable',
      ayuda: 'El mes para el contador: consulta, comisión e IVA por separado.',
      contenido: <ExportacionContable mes={mes} maximo={esteMes} onMes={setMes} />,
    },
  }
  const panel = paneles[vista]

  return (
    <>
      <Opciones
        vistas={[
          { id: 'cierre', rotulo: 'Cierre de mes' },
          { id: 'libro', rotulo: 'Libro de asientos' },
          { id: 'exportacion', rotulo: 'Exportación' },
        ]}
        valor={vista}
        onCambio={setVista}
      />
      {vista === 'cierre' && (
        <div className="lt-herramientas">
          <input
            className="lt-campo"
            style={{ width: 200 }}
            type="month"
            value={mes}
            max={esteMes}
            onChange={(e) => e.target.value && setMes(e.target.value)}
            aria-label="Mes del cierre"
          />
        </div>
      )}
      <section className="lt-panel">
        <div className="lt-panel-cabeza">
          <div>
            <h2>{panel.titulo}</h2>
            <p>{panel.ayuda}</p>
          </div>
        </div>
        <div style={{ padding: '0 24px 24px' }}>{panel.contenido}</div>
      </section>
    </>
  )
}

// ── Alertas (/admin/alertas) ───────────────────────────────────────────────

export function AlertasLite() {
  const q = useQuery({ queryKey: ['riesgo', 'alertas', 'lite', 500], queryFn: () => fetchAlertas({ limite: 500, tipos: null }) })
  const filas: Fila[] = (q.data?.filas ?? []).map((a, i) => {
    const destino = destinoDeAlerta(a)
    return {
      id: `${a.tipo}-${a.sujeto.id}-${i}`,
      celdas: [a.nombre ?? 'Sin nombre', ROTULO_TIPO_ALERTA[a.tipo], GRAVEDAD[a.gravedad].rotulo, a.revisadaEn ? fechaCorta(a.revisadaEn) : '—'],
      textos: [a.nombre ?? '', ROTULO_TIPO_ALERTA[a.tipo], GRAVEDAD[a.gravedad].rotulo, a.revisadaEn ? fechaCorta(a.revisadaEn) : ''],
      estado: a.revisada ? 'Revisada' : 'Pendiente',
      tono: a.revisada ? ('verde' as const) : ('ambar' as const),
      abrir: destino ? <Abrir {...destino} /> : undefined,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Alertas de riesgo"
      ayuda="Revisa gravedad, motivo y cuenta relacionada. Una alerta avisa; no bloquea."
      columnas={[{ rotulo: 'Caso' }, { rotulo: 'Motivo' }, { rotulo: 'Gravedad' }, { rotulo: 'Revisada el' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="alertas"
      vacio="No hay alertas."
    />
  )
}
