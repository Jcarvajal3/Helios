import { useDeferredValue, useState } from 'react'
import { keepPreviousData, useQuery } from '@tanstack/react-query'

import { AltaLocal } from '@/components/admin/directorio/AltaLocal'
import { RevisarSolicitud } from '@/components/admin/directorio/Solicitudes'
import { consultaDeudaConLocales } from '@/components/admin/inicio/consultas'
import { diaOperativo, formatPhone, formatUsd } from '@/components/ui'
import { fetchMerchants } from '@/features/admin/api'
import { consultaSolicitudes } from '@/features/admin/clinicas/api'
import type { SolicitudDeAfiliacion } from '@/features/admin/clinicas/clinicas'
import { consultaInteresados } from '@/features/admin/directorioDeMedicos/api'
import { rotuloDelInteresado } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { estadoDe } from '@/features/admin/estados'
import { fetchCharges } from '@/features/admin/ops'
import { consultaCambiosPropuestos } from '@/features/admin/pacientes/api'
import { SOLO_QUIEN_AFILIA, usePuedeAfiliar } from '@/features/admin/role'
import { consultaTablero } from '@/features/admin/seguimiento/api'
import { ESTADO_DEL_SEGUIMIENTO, estadoDelSeguimiento } from '@/features/admin/seguimiento/seguimiento'
import { fetchPaginaDeUsuarios } from '@/features/admin/users'
import { ClicsLite } from './ClicsLite'
import { Abrir, lecturaDe, tonoDe } from './OperacionesLite'
import { fechaCorta } from './ResultadosLite'
import { EspacioDeTrabajo, Opciones } from './espacio'
import type { Fila } from './espacio'

/**
 * Personas de Helios Lite, como el espacio de trabajo de la maqueta. «Abrir
 * caso» lleva a la ficha de Pro del médico, del paciente o de la orden: allí
 * se pausa una clínica, se desactiva un paciente o se anula una orden.
 */
const ENTERO = new Intl.NumberFormat('es-VE')

// ── Médicos y centros (/admin/clinicas) ────────────────────────────────────

type VistaDeMedicos = 'directorio' | 'clinicas' | 'solicitudes' | 'interesados'

export function ClinicasLite() {
  const [vista, setVista] = useState<VistaDeMedicos>('directorio')
  const [dandoDeAlta, setDandoDeAlta] = useState(false)
  const puedeAfiliar = usePuedeAfiliar()

  return (
    <>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 7, alignItems: 'flex-start' }}>
        <Opciones
          vistas={[
            { id: 'directorio', rotulo: 'Directorio' },
            { id: 'clinicas', rotulo: 'Clínicas' },
            { id: 'solicitudes', rotulo: 'Pendientes de aprobación' },
            { id: 'interesados', rotulo: 'Interesados' },
          ]}
          valor={vista}
          onCambio={setVista}
        />
        <button
          type="button"
          className="lt-opcion"
          style={{ marginTop: -4 }}
          disabled={!puedeAfiliar}
          title={puedeAfiliar ? undefined : SOLO_QUIEN_AFILIA}
          onClick={() => setDandoDeAlta(true)}
        >
          + Registrar médico
        </button>
      </div>
      {vista === 'directorio' && <ClicsLite />}
      {vista === 'clinicas' && <Clinicas />}
      {vista === 'solicitudes' && <Solicitudes />}
      {vista === 'interesados' && <Interesados />}
      {dandoDeAlta && <AltaLocal onClose={() => setDandoDeAlta(false)} />}
    </>
  )
}

function Clinicas() {
  const q = useQuery({ queryKey: ['merchants'], queryFn: fetchMerchants })
  const deuda = useQuery(consultaDeudaConLocales())
  const porPagar = new Map((deuda.data ?? []).map((m) => [m.merchantId, m.totalPendingUsd]))
  const filas: Fila[] = (q.data ?? [])
    .filter((m) => !m.isTest)
    .map((m) => {
      const estado = estadoDe('local', m.status)
      const debe = porPagar.get(m.id) ?? 0
      return {
        id: m.id,
        celdas: [
          <span key="n">
            <strong style={{ fontWeight: 550 }}>{m.name}</strong>
            {m.consultorio && <div className="lt-celda-sub">{m.consultorio}</div>}
          </span>,
          formatUsd(debe),
          ENTERO.format(m.sales30d),
          fechaCorta(m.createdAt),
        ],
        textos: [m.name, formatUsd(debe), String(m.sales30d), fechaCorta(m.createdAt)],
        estado: estado.label,
        tono: tonoDe(estado.tone),
        abrir: <Abrir to="/admin/clinicas/$id" params={{ id: m.id }}>Ver médico →</Abrir>,
      }
    })
  return (
    <EspacioDeTrabajo
      titulo="Clínicas"
      ayuda="Estado, lo que se les debe y su actividad. En la ficha: perfil, condiciones, cuenta de pago, personal y pausar o terminar."
      columnas={[{ rotulo: 'Médico / clínica' }, { rotulo: 'Por pagar', numero: true }, { rotulo: 'Consultas 30 días', numero: true }, { rotulo: 'Alta' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      buscar="Buscar médico o consultorio"
      archivo="clinicas"
      vacio="No hay clínicas."
    />
  )
}

function Solicitudes() {
  const q = useQuery(consultaSolicitudes())
  const [revisando, setRevisando] = useState<SolicitudDeAfiliacion | null>(null)
  const filas: Fila[] = (q.data ?? []).map((s) => ({
    id: s.id,
    celdas: [s.alta.ownerName || s.alta.clinicName, s.alta.specialty || '—', s.alta.clinicName, fechaCorta(s.createdAt)],
    textos: [s.alta.ownerName || s.alta.clinicName, s.alta.specialty, s.alta.clinicName, fechaCorta(s.createdAt)],
    estado: s.status === 'pending' ? 'Pendiente' : s.status === 'approved' ? 'Aprobada' : 'Rechazada',
    tono: s.status === 'pending' ? ('ambar' as const) : s.status === 'approved' ? ('verde' as const) : undefined,
    abrir: (
      <button type="button" className="lt-boton-texto" onClick={() => setRevisando(s)}>
        Revisar →
      </button>
    ),
  }))
  return (
    <>
      <EspacioDeTrabajo
        titulo="Solicitudes de afiliación"
        ayuda="Revisa el expediente antes del alta: perfil, condiciones y contacto."
        columnas={[{ rotulo: 'Solicitante' }, { rotulo: 'Especialidad' }, { rotulo: 'Consultorio' }, { rotulo: 'Recibida' }]}
        filas={filas}
        lectura={lecturaDe(q)}
        archivo="solicitudes"
        vacio="No hay solicitudes por aprobar."
      />
      {revisando && <RevisarSolicitud solicitud={revisando} onClose={() => setRevisando(null)} />}
    </>
  )
}

function Interesados() {
  const q = useQuery(consultaInteresados())
  const filas: Fila[] = (q.data ?? []).map((i) => ({
    id: i.id,
    celdas: [i.medico, formatPhone(i.telefono), ENTERO.format(i.mensajes), fechaCorta(i.ultimaVez)],
    textos: [i.medico, i.telefono, String(i.mensajes), fechaCorta(i.ultimaVez)],
    estado: i.conversion ? rotuloDelInteresado(i) : i.paciente ? 'Ya es paciente' : 'Interesado',
    tono: i.conversion ? ('verde' as const) : undefined,
    abrir: i.paciente ? (
      <Abrir to="/admin/pacientes/$id" params={{ id: i.paciente.id }}>Ver paciente →</Abrir>
    ) : (
      <Abrir to="/admin/directorio" search={{ medico: i.medicoId }}>Ver médico →</Abrir>
    ),
  }))
  return (
    <EspacioDeTrabajo
      titulo="Interesados del directorio"
      ayuda="Quién escribió al WhatsApp de Helios desde la tarjeta de un médico, y si llegó a ser paciente."
      columnas={[{ rotulo: 'Médico' }, { rotulo: 'Teléfono' }, { rotulo: 'Mensajes', numero: true }, { rotulo: 'Última vez' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="interesados"
      vacio="Todavía nadie escribió desde el directorio."
    />
  )
}

// ── Pacientes (/admin/pacientes) ───────────────────────────────────────────

type VistaDePacientes = 'pacientes' | 'cambios'

export function PacientesLite() {
  const [vista, setVista] = useState<VistaDePacientes>('pacientes')
  return (
    <>
      <Opciones
        vistas={[
          { id: 'pacientes', rotulo: 'Pacientes' },
          { id: 'cambios', rotulo: 'Cambios propuestos' },
        ]}
        valor={vista}
        onCambio={setVista}
      />
      {vista === 'pacientes' ? <Pacientes /> : <CambiosPropuestos />}
    </>
  )
}

/** Cuántos pacientes se traen: el tope de `admin_user_directory` por página. */
const TOPE_PACIENTES = 200

function Pacientes() {
  // La base busca por nombre, teléfono y cédula; se le pregunta cuando se deja de teclear.
  const [busqueda, setBusqueda] = useState('')
  const buscada = useDeferredValue(busqueda.trim())
  const q = useQuery({
    queryKey: ['admin-users', 'lite', TOPE_PACIENTES, buscada],
    queryFn: () => fetchPaginaDeUsuarios({ search: buscada || undefined, pagina: 1, porPagina: TOPE_PACIENTES }),
    placeholderData: keepPreviousData,
  })
  const filas: Fila[] = (q.data?.filas ?? []).map((u) => {
    const estado = estadoDe('persona', u.status)
    return {
      id: u.userId,
      celdas: [u.fullName ?? 'Sin nombre', `Nivel ${u.level}`, formatUsd(u.openDebtUsd), formatPhone(u.phone)],
      textos: [u.fullName ?? '', `Nivel ${u.level}`, formatUsd(u.openDebtUsd), u.phone ?? ''],
      estado: estado.label,
      tono: tonoDe(estado.tone),
      abrir: <Abrir to="/admin/pacientes/$id" params={{ id: u.userId }} />,
    }
  })
  const total = q.data?.total ?? 0
  return (
    <EspacioDeTrabajo
      titulo="Pacientes"
      ayuda="Cuenta, nivel y deuda. En la ficha: datos, consultas, pagos, cobranza, historial y desactivar."
      columnas={[{ rotulo: 'Paciente' }, { rotulo: 'Nivel' }, { rotulo: 'Deuda', numero: true }, { rotulo: 'Teléfono' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      buscar="Buscar paciente, teléfono o cédula"
      alBuscar={setBusqueda}
      archivo="pacientes"
      vacio="No hay pacientes."
      nota={total > TOPE_PACIENTES ? `Se ven ${ENTERO.format(TOPE_PACIENTES)} de ${ENTERO.format(total)}: busca para encontrar al resto.` : undefined}
    />
  )
}

function CambiosPropuestos() {
  const q = useQuery(consultaCambiosPropuestos('pendiente'))
  const filas: Fila[] = (q.data ?? []).map((c) => {
    const campos = c.diferencias.map((d) => d.rotulo).join(', ')
    const propuesta = c.diferencias.map((d) => d.propuesto ?? '—').join(' · ')
    return {
      id: c.id,
      celdas: [c.patientName ?? 'Sin nombre', campos, propuesta, c.merchantName ?? '—'],
      textos: [c.patientName ?? '', campos, propuesta, c.merchantName ?? ''],
      estado: c.status === 'pendiente' ? 'Pendiente' : c.status,
      tono: 'ambar' as const,
      abrir: <Abrir to="/admin/pacientes/$id" params={{ id: c.profileId }} search={{ tab: 'datos' }}>Revisar →</Abrir>,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Cambios propuestos de pacientes"
      ayuda="Lo que una clínica pidió corregir. Compara el valor actual y el propuesto en la ficha antes de decidir."
      columnas={[{ rotulo: 'Paciente' }, { rotulo: 'Campo' }, { rotulo: 'Propuesta' }, { rotulo: 'Clínica' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="cambios-propuestos"
      vacio="No hay cambios por revisar."
    />
  )
}

// ── Órdenes (/admin/financiamientos) ───────────────────────────────────────

export function OrdenesLite() {
  const q = useQuery({ queryKey: ['admin-charges', 'lite', 300], queryFn: () => fetchCharges({ limit: 300 }) })
  const filas: Fila[] = (q.data ?? [])
    .filter((c) => !c.isTest)
    .map((c) => {
      const estado = estadoDe('consumo', c.status)
      const medico = c.doctorName ?? c.merchantName
      const orden = c.orderNumber === null ? '—' : `#${c.orderNumber}`
      return {
        id: c.chargeId,
        celdas: [orden, c.fullName ?? 'Sin nombre', medico, formatUsd(c.financedUsd)],
        textos: [orden, c.fullName ?? '', medico, formatUsd(c.financedUsd)],
        estado: estado.label,
        tono: tonoDe(estado.tone),
        abrir: <Abrir to="/admin/financiamientos/$id" params={{ id: c.chargeId }} />,
      }
    })
  return (
    <EspacioDeTrabajo
      titulo="Órdenes"
      ayuda="Las 300 más recientes: consulta sin comisión y estado. En la ficha: cuotas, factura, anular o revertir."
      columnas={[{ rotulo: 'Orden' }, { rotulo: 'Paciente' }, { rotulo: 'Médico' }, { rotulo: 'Consulta', numero: true }]}
      filas={filas}
      lectura={lecturaDe(q)}
      buscar="Buscar orden, paciente o médico"
      archivo="ordenes"
      vacio="No hay órdenes."
    />
  )
}

// ── Seguimiento (/admin/seguimiento) ───────────────────────────────────────

export function SeguimientoLite() {
  const hoy = diaOperativo()
  const q = useQuery(consultaTablero())
  const filas: Fila[] = (q.data ?? [])
    .filter((c) => !c.esPrueba && c.estado !== 'terminated')
    .map((c) => {
      const estado = ESTADO_DEL_SEGUIMIENTO[estadoDelSeguimiento(c, hoy)]
      const ultima = c.ultimoContacto ? fechaCorta(c.ultimoContacto.cuando) : 'Nunca'
      const volver = c.volverEl ? (c.volverEl === hoy ? 'Hoy' : fechaCorta(c.volverEl)) : 'Sin fecha'
      const nombre = c.medico ?? c.nombre
      return {
        id: c.id,
        celdas: [nombre, ultima, volver, c.ultimaOrden ? fechaCorta(c.ultimaOrden) : 'Ninguna'],
        textos: [nombre, ultima, volver, c.ultimaOrden ? fechaCorta(c.ultimaOrden) : ''],
        estado: estado.label,
        tono: tonoDe(estado.tone),
        abrir: <Abrir to="/admin/seguimiento" search={{ clinica: c.id }}>Abrir caso →</Abrir>,
      }
    })
  return (
    <EspacioDeTrabajo
      titulo="Seguimiento"
      ayuda="Médicos y clínicas que necesitan contacto para usar Helios. En el caso: su personal, llamar y anotar."
      columnas={[{ rotulo: 'Caso' }, { rotulo: 'Último contacto' }, { rotulo: 'Volver a llamar' }, { rotulo: 'Última orden' }]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="seguimiento"
      vacio="No hay clínicas en seguimiento."
    />
  )
}
