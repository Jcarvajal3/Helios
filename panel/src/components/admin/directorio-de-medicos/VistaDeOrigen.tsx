import type { UseQueryResult } from '@tanstack/react-query'
import { Compass } from 'lucide-react'

import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { EmptyState, SkeletonTable, Stat, StatGrid } from '@/components/ui'
import { FUENTES_DE_BUSQUEDA, nombreDeFuente } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type { FilaDeOrigen, OrigenesDelDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'

/**
 * Superadmin › Directorio de médicos › Origen: de dónde vinieron las visitas
 * que terminaron en un clic al WhatsApp de un médico, en los últimos 30 días.
 * Es la medida del SEO en pacientes y no en visitas: un buscador que trae
 * mil visitas y ningún clic no sirve.
 *
 * Arriba, cuántos clics trajeron los buscadores (con IA o sin ella) frente
 * al total. Debajo, tres tablas: por fuente, por página de entrada y por
 * página del clic. Los datos salen de `admin_directorio_origenes`
 * (migración 20261030120000); el origen lo apunta el navegador del paciente
 * (`features/directorio/origen.ts`), sin nada que diga quién es.
 */
export function VistaDeOrigen({ consulta }: { consulta: UseQueryResult<OrigenesDelDirectorio> }) {
  if (consulta.isPending) return <SkeletonTable rows={6} columns={3} />
  if (consulta.isError) {
    return (
      <SeccionSinLeer
        titulo="No se pudo leer de dónde llegan los clics"
        error={consulta.error}
        onReintentar={() => void consulta.refetch()}
      />
    )
  }

  const o = consulta.data
  const total = o.porFuente.reduce((s, f) => s + f.clics, 0)
  if (total === 0) {
    return (
      <EmptyState
        icon={<Compass size={40} />}
        title="Todavía no hay clics con origen"
        description="Desde el 30/10/2026, cada toque al botón de WhatsApp de un médico guarda de dónde vino la visita (Google, ChatGPT, Instagram…). Aparecerán aquí."
      />
    )
  }

  const deBuscadores = o.porFuente
    .filter((f) => (FUENTES_DE_BUSQUEDA as readonly string[]).includes(f.clave))
    .reduce((s, f) => s + f.clics, 0)
  const conIa = o.porFuente
    .filter((f) => ['chatgpt', 'perplexity', 'gemini', 'copilot'].includes(f.clave))
    .reduce((s, f) => s + f.clics, 0)

  return (
    <div className="flex flex-col gap-6">
      <StatGrid cols={3}>
        <Stat
          label={`Clics · ${o.dias} días`}
          value={String(total)}
          info="Toques públicos al botón de WhatsApp de un médico. No cuentan los del equipo ni los del personal de las clínicas."
        />
        <Stat
          label="Desde buscadores"
          value={String(deBuscadores)}
          hint={total ? `${Math.round((deBuscadores / total) * 100)}% de los clics` : undefined}
          info="Visitas que llegaron desde Google, Bing, DuckDuckGo, Yahoo o un asistente con IA y terminaron en un clic al WhatsApp."
        />
        <Stat
          label="Desde asistentes con IA"
          value={String(conIa)}
          hint="ChatGPT, Perplexity, Gemini y Copilot"
          info="ChatGPT marca sus enlaces (utm_source=chatgpt.com); los demás se reconocen por la página de donde vino la visita."
        />
      </StatGrid>

      <TablaDeOrigen
        filas={o.porFuente}
        cabecera="Fuente"
        nombre={nombreDeFuente}
        conVisitantes
        archivo="directorio-origen-por-fuente"
      />
      <TablaDeOrigen
        filas={o.porEntrada}
        cabecera="Página de entrada"
        info="La primera página de Helios que abrió la visita. Las 20 que más clics trajeron."
        nombre={(c) => (c === 'sin_dato' ? nombreDeFuente(c) : c)}
        archivo="directorio-origen-por-entrada"
      />
      <TablaDeOrigen
        filas={o.porPagina}
        cabecera="Página del clic"
        info="Donde se tocó el botón de WhatsApp: el directorio, una especialidad o la ficha de un médico. Las 20 con más clics."
        nombre={(c) => (c === 'sin_dato' ? nombreDeFuente(c) : c)}
        archivo="directorio-origen-por-pagina"
      />
    </div>
  )
}

function TablaDeOrigen({
  filas,
  cabecera,
  info,
  nombre,
  conVisitantes = false,
  archivo,
}: {
  filas: FilaDeOrigen[]
  cabecera: string
  info?: string
  nombre: (clave: string) => string
  conVisitantes?: boolean
  archivo: string
}) {
  const columnas: Array<Column<FilaDeOrigen>> = [
    {
      key: 'clave',
      header: cabecera,
      info,
      identity: true,
      sort: (f) => nombre(f.clave),
      csv: (f) => nombre(f.clave),
      cell: (f) => <span className="font-medium text-on-surface">{nombre(f.clave)}</span>,
    },
    {
      key: 'clics',
      header: 'Clics',
      type: 'number',
      sort: (f) => f.clics,
      sortDir: 'desc',
      csv: (f) => String(f.clics),
      cell: (f) => <span className="tabular-nums text-on-surface">{f.clics}</span>,
    },
    ...(conVisitantes
      ? [
          {
            key: 'visitantes',
            header: 'Personas',
            info: 'Navegadores distintos que hicieron esos clics.',
            type: 'number' as const,
            sort: (f: FilaDeOrigen) => f.visitantes,
            sortDir: 'desc' as const,
            csv: (f: FilaDeOrigen) => String(f.visitantes ?? ''),
            cell: (f: FilaDeOrigen) => <span className="tabular-nums text-on-surface">{f.visitantes ?? '—'}</span>,
          },
        ]
      : []),
  ]
  return (
    <DataTable
      rows={filas}
      rowKey={(f) => f.clave}
      columns={columnas}
      noun={['fila', 'filas']}
      exportar={{ archivo }}
    />
  )
}
