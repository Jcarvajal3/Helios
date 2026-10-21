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
import { diaOperativo } from '@/components/ui'
import { consultaColaDeAvisos, consultaCorreosRecientes } from '@/features/admin/avisos/api'
import { consultaCambiosPropuestos } from '@/features/admin/pacientes/api'
import {
  resumirAbonos,
  resumirAlertasAltas,
  resumirAvisosDeHoy,
  resumirCambiosPropuestos,
  resumirCartera,
  resumirCorreosRebotados,
  resumirPagoDeHoy,
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
  const avisos = useColasDeAvisos()
  const caja = useColasDeCaja()
  const riesgo = useColasDeRiesgo()
  return [...cobranza, ...avisos, ...caja, ...riesgo]
}

// ── Avisos y datos de los pacientes ────────────────────────────────────────

function useColasDeAvisos(): ColaDeInicio[] {
  const irA = useIrALista()
  const hoy = useQuery(consultaColaDeAvisos(diaOperativo()))
  const correos = useQuery(consultaCorreosRecientes())
  const cambios = useQuery(consultaCambiosPropuestos('pendiente'))

  const aAvisos: Destino = { to: '/admin/avisos' }
  const aRebotados: Destino = { to: '/admin/avisos', search: { vista: 'correos', estado: 'rebotados' } }
  const aCambios: Destino = { to: '/admin/pacientes', search: { vista: 'cambios' } }

  return [
    {
      id: 'avisos-hoy',
      nombre: 'Avisos de hoy por mandar',
      pantalla: 'avisos',
      lista: aAvisos,
      lectura: leer(hoy, resumirAvisosDeHoy),
      // El modo cola de Avisos de hoy: un aviso a la vez, con teclas.
      empezar: () => irA({ to: '/admin/avisos', search: { cola: true } }),
    },
    {
      id: 'correos-rebotados',
      nombre: 'Correos rebotados',
      pantalla: 'avisos',
      lista: aRebotados,
      lectura: leer(correos, (d) => resumirCorreosRebotados(d.filas)),
      empezar: () => irA(aRebotados),
    },
    {
      id: 'cambios-propuestos',
      nombre: 'Cambios de datos propuestos',
      pantalla: 'personas',
      lista: aCambios,
      lectura: leer(cambios, resumirCambiosPropuestos),
      empezar: () => irA(aCambios),
    },
  ]
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
  const aHoy: Destino = { to: '/admin/pagos-clinicas', search: {} }

  return [
    {
      id: 'pago-de-hoy',
      nombre: 'Pago de hoy a clínicas',
      pantalla: 'pagos-a-locales',
      lista: aHoy,
      lectura: leer(locales, resumirPagoDeHoy),
      empezar: () => irA(aHoy),
    },
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

  // Se recalcula en cada pintura, como en la cartera: el día cambia solo a medianoche.
  // (No hay cola de «Vence mañana»: los recordatorios antes del vencimiento
  // salen solos por WhatsApp y correo.)
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
