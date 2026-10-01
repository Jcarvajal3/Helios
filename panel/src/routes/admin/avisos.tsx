import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import { PlantillasCobranza } from '@/components/admin/PlantillasCobranza'
import { AvisosDeHoy } from '@/components/admin/avisos/AvisosDeHoy'
import { Correos, FILTROS_DE_CORREOS } from '@/components/admin/avisos/Correos'
import type { FiltroDeCorreos } from '@/components/admin/avisos/Correos'
import { PlantillasDeAvisos } from '@/components/admin/avisos/PlantillasDeAvisos'
import { Tabs, diaOperativo } from '@/components/ui'
import { consultaColaDeAvisos, consultaCorreosRecientes } from '@/features/admin/avisos/api'
import { colaDeTrabajo, rebotadosSinCorregir } from '@/features/admin/avisos/avisos'
import { comoBooleano, comoDia, comoEntero, comoTexto, unoDe } from '@/lib/busqueda'

type Vista = 'hoy' | 'correos' | 'plantillas'
const VISTAS: readonly Vista[] = ['hoy', 'correos', 'plantillas']

/**
 * Todo en la URL, cada pestaña con lo suyo:
 *
 *   hoy         `dia` (sin él, hoy en Caracas) y `cola`, el modo cola.
 *   correos     `estado`, `q` y `pagina`.
 */
type AvisosSearch = {
  vista?: Vista
  dia?: string
  cola?: true
  estado?: FiltroDeCorreos
  q?: string
  pagina?: number
}

export const Route = createFileRoute('/admin/avisos')({
  staticData: { title: 'Avisos', width: 'wide' },
  component: AvisosPage,
  validateSearch: (search: Record<string, unknown>): AvisosSearch => ({
    vista: unoDe(VISTAS, search.vista),
    dia: comoDia(search.dia),
    cola: comoBooleano(search.cola),
    estado: unoDe(FILTROS_DE_CORREOS, search.estado),
    q: comoTexto(search.q),
    pagina: comoEntero(search.pagina, { min: 2, max: 100_000 }),
  }),
})

/**
 * Avisos: lo que se le dice a cada paciente (plan §7.2, contrato §2.2).
 *
 *   Avisos de hoy  la cola diaria de WhatsApp: cada aviso con su texto,
 *                  «Abrir WhatsApp», «Enviado» y «Omitir», y el modo cola.
 *   Correos        el comprobante y los recordatorios por correo, con su
 *                  estado; los rebotados se corrigen y se reenvían.
 *   Plantillas     los avisos automáticos (solo lectura) y las plantillas de
 *                  WhatsApp de la cobranza.
 *
 * Sustituye a las Notificaciones de Ronda (push y promociones): Helios no
 * tiene app, así que lo que va por WhatsApp lo manda una persona.
 */
function AvisosPage() {
  const navigate = useNavigate({ from: '/admin/avisos' })
  const search = Route.useSearch()
  const vista = search.vista ?? 'hoy'

  // Las mismas claves que los contadores del menú: no cuestan otra llamada.
  const porMandar = useQuery({ ...consultaColaDeAvisos(diaOperativo()), select: (d) => colaDeTrabajo(d).length })
  const rebotados = useQuery({ ...consultaCorreosRecientes(), select: (d) => rebotadosSinCorregir(d.filas).length })

  return (
    <>
      <Tabs
        options={[
          { value: 'hoy', label: 'Avisos de hoy', insignia: porMandar.data },
          { value: 'correos', label: 'Correos', insignia: rebotados.data },
          { value: 'plantillas', label: 'Plantillas' },
        ]}
        value={vista}
        onChange={(v) => void navigate({ search: v === 'hoy' ? {} : { vista: v } })}
      />

      {vista === 'hoy' && (
        <AvisosDeHoy
          dia={search.dia}
          enCola={search.cola === true}
          onDia={(dia) => void navigate({ search: (prev) => ({ ...prev, dia, cola: undefined }), replace: true })}
          onCola={(enCola) => void navigate({ search: (prev) => ({ ...prev, cola: enCola ? true : undefined }) })}
        />
      )}

      {vista === 'correos' && (
        <Correos
          filtro={search.estado}
          q={search.q}
          pagina={search.pagina ?? 1}
          onCambiar={(patch) =>
            void navigate({
              search: (prev) => ({
                ...prev,
                ...patch,
                pagina: patch.pagina !== undefined && patch.pagina > 1 ? patch.pagina : undefined,
              }),
              replace: patch.q !== undefined,
            })
          }
        />
      )}

      {vista === 'plantillas' && (
        <div className="flex flex-col gap-shell-gap-block">
          <PlantillasDeAvisos />
          <PlantillasCobranza />
        </div>
      )}
    </>
  )
}
