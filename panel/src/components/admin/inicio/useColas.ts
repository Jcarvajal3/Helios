import { useNavigate } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'

import { COLA_PAGOS_REPORTADOS } from '@/components/admin/FichaCobro'
import { abrirEnCola } from '@/components/admin/ModoCola'
import { abrirCasoEnCola } from '@/components/admin/ficha-persona/CobranzaCola'
import type { OrigenDelCaso } from '@/components/admin/ficha-persona/CobranzaCola'
import type { IdPantalla } from '@/features/admin/catalogo'
import type { Destino } from '@/features/admin/catalogo/tipos'
import { consultaCartera, consultaPromesas } from '@/features/admin/cobranza/consultas'
import {
  resumirAbonos,
  resumirAlertasAltas,
  resumirCartera,
  resumirPagosALocales,
  resumirPagosReportados,
  resumirPromesasDeHoy,
} from './colas'
import type { IdCola, Lectura, Resumen } from './colas'
import {
  TOPE_ABONOS,
  consultaAbonosSinDueno,
  consultaDeudaConLocales,
  consultaPagosPorAprobar,
  consultaRecuentoDeAlertas,
} from './consultas'
import { hoyOperativo } from './reloj'

/** Una fila de «Tu cola», lista para pintar. */
export type ColaDeInicio = {
  id: IdCola
  nombre: string
  /** La pantalla del catálogo donde se trabaja: de ella salen su área y su icono. */
  pantalla: IdPantalla
  /** La lista ya filtrada: adonde lleva el nombre de la fila. */
  lista: Destino
  lectura: Lectura
  /** Abre el primero en modo cola, o la lista si esa cola no tiene ficha. */
  empezar: (resumen: Resumen) => void
}

function leer<T>(q: UseQueryResult<T>, resumir: (datos: T) => Resumen): Lectura {
  if (q.isError) return { estado: 'error', reintentar: () => void q.refetch() }
  if (q.data === undefined) return { estado: 'cargando' }
  return { estado: 'listo', resumen: resumir(q.data) }
}

/**
 * Las colas de los cuatro equipos, en el orden del menú. Gerencia no tiene
 * colas.
 */
export function useColas(): ColaDeInicio[] {
  const cobranza = useColasDeCobranza()
  const caja = useColasDeCaja()
  const riesgo = useColasDeRiesgo()
  return [...cobranza, ...caja, ...riesgo]
}

/** Navegar a una lista, sin más. */
function useIrALista(): (destino: Destino) => void {
  const navigate = useNavigate()
  return (destino) => void navigate(destino)
}

// ── Caja ───────────────────────────────────────────────────────────────────

function useColasDeCaja(): ColaDeInicio[] {
  const irA = useIrALista()
  const locales = useQuery(consultaDeudaConLocales())

  const aLocales: Destino = { to: '/admin/pagos-clinicas', search: { solo: 'atrasados' } }

  return [
    {
      id: 'pagos-a-locales',
      nombre: 'Pagos a clínicas atrasadas',
      pantalla: 'pagos-a-locales',
      lista: aLocales,
      lectura: leer(locales, resumirPagosALocales),
      empezar: () => irA(aLocales),
    },
  ]
}

// ── Cobranza ───────────────────────────────────────────────────────────────

function useColasDeCobranza(): ColaDeInicio[] {
  const navigate = useNavigate()
  const promesas = useQuery(consultaPromesas())
  const cartera = useQuery(consultaCartera())
  const pagos = useQuery(consultaPagosPorAprobar())
  const abonos = useQuery(consultaAbonosSinDueno())

  const ahora = Date.now()

  // Se recalcula en cada pintura, como en la cartera: «Vence mañana» cambia solo a las 10:00.
  const hoy = hoyOperativo()

  /** El caso de la primera persona, con la barra para pasar a la siguiente. */
  function abrirCaso(origen: OrigenDelCaso, ids: string[]) {
    const primero = ids.at(0)
    if (!primero) return
    abrirCasoEnCola(origen, ids)
    void navigate({ to: '/admin/pacientes/$id', params: { id: primero }, search: { tab: 'cobranza' } })
  }

  return [
    {
      id: 'promesas-hoy',
      nombre: 'Promesas que vencen hoy',
      pantalla: 'promesas',
      lista: { to: '/admin/cobranza', search: { vista: 'promesas' } },
      lectura: leer(promesas, resumirPromesasDeHoy),
      empezar: ({ ids }) => abrirCaso({ lista: 'promesas', estado: 'vence_hoy' }, ids),
    },
    {
      id: 'sin-contactar',
      nombre: 'Vencidos sin contactar',
      pantalla: 'cartera-vencida',
      lista: { to: '/admin/cobranza', search: { tramo: 'sin_contactar' } },
      lectura: leer(cartera, (d) => resumirCartera(d.rows, 'sin_contactar', hoy)),
      empezar: ({ ids }) => abrirCaso({ lista: 'cobranza', tramo: 'sin_contactar' }, ids),
    },
    {
      id: 'recordar-hoy',
      nombre: 'Vence mañana',
      pantalla: 'cartera-vencida',
      lista: { to: '/admin/cobranza', search: { tramo: 'recordar_hoy' } },
      lectura: leer(cartera, (d) => resumirCartera(d.rows, 'recordar_hoy', hoy)),
      empezar: ({ ids }) => abrirCaso({ lista: 'cobranza', tramo: 'recordar_hoy' }, ids),
    },
    {
      id: 'pagos-reportados',
      nombre: 'Pagos reportados',
      pantalla: 'pagos-reportados',
      lista: { to: '/admin/cobros' },
      lectura: leer(pagos, (d) => resumirPagosReportados(d, ahora)),
      empezar: ({ ids }) => {
        const primero = ids.at(0)
        if (!primero) return
        abrirEnCola(COLA_PAGOS_REPORTADOS, ids)
        void navigate({ to: '/admin/cobros/$id', params: { id: primero }, search: {} })
      },
    },
    {
      id: 'abonos',
      nombre: 'Abonos sin dueño',
      pantalla: 'abonos-sin-dueno',
      lista: { to: '/admin/cobros', search: { vista: 'abonos' } },
      lectura: leer(abonos, (d) => resumirAbonos(d, TOPE_ABONOS)),
      // La lista abre el primero con «Siguiente abono» dentro: es su modo cola.
      empezar: ({ ids }) => {
        const primero = ids.at(0)
        if (primero) {
          void navigate({ to: '/admin/cobros', search: { vista: 'abonos', asignar: primero } })
        }
      },
    },
  ]
}

// ── Riesgo ─────────────────────────────────────────────────────────────────

function useColasDeRiesgo(): ColaDeInicio[] {
  const irA = useIrALista()
  const alertas = useQuery(consultaRecuentoDeAlertas())

  const aAlertas: Destino = { to: '/admin/alertas', search: { gravedad: 'alta' } }

  // Las alertas no tienen ficha: abre su lista.
  return [
    {
      id: 'alertas-altas',
      nombre: 'Alertas de gravedad alta',
      pantalla: 'alertas',
      lista: aAlertas,
      lectura: leer(alertas, resumirAlertasAltas),
      empezar: () => irA(aAlertas),
    },
  ]
}
