import { useQuery } from '@tanstack/react-query'
import { Link, useRouterState } from '@tanstack/react-router'

import { diaOperativo, formatPhone } from '@/components/ui'
import {
  consultaColaDeAvisos,
  consultaCorreosRecientes,
} from '@/features/admin/avisos/api'
import {
  ESTADO_AVISO,
  PLANTILLAS,
  estadoDeCorreo,
} from '@/features/admin/avisos/avisos'
import { PlantillasCobranza } from '@/components/admin/PlantillasCobranza'
import { consultaPlantillas } from '@/features/admin/cobranza/consultas'
import { Abrir, lecturaDe, tonoDe } from './OperacionesLite'
import { fechaCorta } from './ResultadosLite'
import { EspacioDeTrabajo } from './espacio'
import type { Fila } from './espacio'

/**
 * Mensajes de Helios Lite (`/admin/avisos`): Avisos de hoy, Correos y
 * Plantillas, como el espacio de trabajo de la maqueta. Cuál se ve lo dice la
 * pestaña del marco (`?vista=correos|plantillas`). WhatsApp es la bandeja de
 * Pro, con el vestido de Lite.
 */
export function MensajesLite() {
  const vista = useRouterState({ select: (s) => vistaDe(s.location.search) })
  if (vista === 'correos') return <Correos />
  if (vista === 'plantillas') return <Plantillas />
  return <AvisosDeHoy />
}

function vistaDe(search: unknown): string | undefined {
  const v = (search as Record<string, unknown> | undefined)?.vista
  return typeof v === 'string' ? v : undefined
}

function AvisosDeHoy() {
  const dia = diaOperativo()
  const q = useQuery(consultaColaDeAvisos(dia))
  const filas: Fila[] = (q.data ?? []).map((a) => {
    const estado = ESTADO_AVISO[a.status]
    return {
      id: a.id,
      celdas: [
        a.patientName ?? 'Sin nombre',
        a.templateLabel,
        formatPhone(a.phone),
        a.orderNumber === null ? '—' : `#${a.orderNumber}`,
      ],
      textos: [
        a.patientName ?? '',
        a.templateLabel,
        a.phone ?? '',
        a.orderNumber === null ? '' : `#${a.orderNumber}`,
      ],
      estado: estado.label,
      tono: tonoDe(estado.tone),
      abrir: a.profileId ? (
        <Abrir to="/admin/pacientes/$id" params={{ id: a.profileId }} />
      ) : undefined,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Avisos de hoy"
      ayuda="Los WhatsApp que hay que mandar a mano hoy. Para mandarlos uno tras otro, el modo cola."
      columnas={[
        { rotulo: 'Destinatario' },
        { rotulo: 'Motivo' },
        { rotulo: 'Teléfono' },
        { rotulo: 'Orden' },
      ]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="avisos-de-hoy"
      vacio="No hay avisos para hoy."
      extra={
        <Link
          to="/admin/avisos"
          search={{ cola: true } as never}
          className="lt-boton-suave"
        >
          Mandar en modo cola →
        </Link>
      }
    />
  )
}

function Correos() {
  const q = useQuery(consultaCorreosRecientes())
  const filas: Fila[] = (q.data?.filas ?? []).map((a) => {
    const estado = estadoDeCorreo(a)
    const fecha = fechaCorta(a.sentAt ?? a.createdAt)
    return {
      id: a.id,
      celdas: [
        a.patientName ?? a.email ?? 'Sin nombre',
        a.templateLabel,
        a.email ?? '—',
        fecha,
      ],
      textos: [a.patientName ?? '', a.templateLabel, a.email ?? '', fecha],
      estado: estado.label,
      tono: tonoDe(estado.tone),
      abrir: a.profileId ? (
        <Abrir to="/admin/pacientes/$id" params={{ id: a.profileId }} />
      ) : undefined,
    }
  })
  return (
    <EspacioDeTrabajo
      titulo="Correos"
      ayuda="Los últimos 200: entregas y rebotes, sin perder el caso asociado."
      columnas={[
        { rotulo: 'Destinatario' },
        { rotulo: 'Contenido' },
        { rotulo: 'Correo' },
        { rotulo: 'Fecha' },
      ]}
      filas={filas}
      lectura={lecturaDe(q)}
      archivo="correos"
      vacio="No se ha mandado ningún correo."
    />
  )
}

function Plantillas() {
  const q = useQuery(consultaPlantillas())
  const automaticas: Fila[] = PLANTILLAS.map((p) => ({
    id: p.clave,
    celdas: [p.rotulo, p.canal, p.cuando],
    textos: [p.rotulo, p.canal, p.cuando],
    estado: 'Automática',
    tono: 'verde' as const,
  }))
  const deCobranza: Fila[] = (q.data?.rows ?? []).map((t) => ({
    id: `cobranza-${t.bucket}`,
    celdas: [
      t.label,
      'WhatsApp manual',
      `Cobranza · ${t.edited ? `editada el ${fechaCorta(t.updatedAt)}` : 'la de siempre'}`,
    ],
    textos: [
      t.label,
      'WhatsApp manual',
      t.edited ? `editada el ${fechaCorta(t.updatedAt)}` : '',
    ],
    estado: 'De cobranza',
  }))
  return (
    <>
      <EspacioDeTrabajo
        titulo="Plantillas de avisos y cobranza"
        ayuda="Qué se manda, por qué canal y cuándo. Las de cobranza se editan abajo."
        columnas={[
          { rotulo: 'Plantilla' },
          { rotulo: 'Canal' },
          { rotulo: 'Uso' },
        ]}
        filas={[...automaticas, ...deCobranza]}
        lectura={{
          cargando: false,
          fallo: q.isError,
          reintentar: () => void q.refetch(),
        }}
        archivo="plantillas"
      />
      {/* El editor de Pro de las plantillas de cobranza, con su vista previa. */}
      <section className="lt-panel" style={{ marginTop: 20 }}>
        <div className="lt-panel-cabeza">
          <div>
            <h2>Editar las plantillas de cobranza</h2>
            <p>
              El texto que se manda por WhatsApp a quien tiene una cuota
              vencida, según su tramo.
            </p>
          </div>
        </div>
        <div style={{ padding: '0 24px 24px' }}>
          <PlantillasCobranza />
        </div>
      </section>
    </>
  )
}
