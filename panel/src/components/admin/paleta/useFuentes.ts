import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'

import { fetchMerchants } from '@/features/admin/api'
import type { MerchantRow } from '@/features/admin/api'
import { fetchCharges } from '@/features/admin/ops'
import type { ChargeRow } from '@/features/admin/ops'
import { fetchUsers } from '@/features/admin/users'
import type { UserRow } from '@/features/admin/users'
import { agujaDeReferencia } from './consulta'
import { personasAPedir } from './resultados'
import type { Consulta } from './consulta'
import { buscarPagosPorReferencia } from './fuentes'
import type { PagoEncontrado } from './fuentes'
import type { EstadoGrupo, Fuente } from './grupos'

/** Una fuente, más la forma de volver a preguntarle si falló. */
export type FuenteViva<T> = Fuente<T> & { reintentar: () => void }

export type FuentesDePaleta = {
  personas: FuenteViva<UserRow>
  locales: FuenteViva<MerchantRow>
  consumos: FuenteViva<ChargeRow>
  pagos: FuenteViva<PagoEncontrado>
}

/**
 * Lo que vale una búsqueda hecha: medio minuto. Volver a teclear lo mismo
 * enseguida (borrar una letra y ponerla) no repite la consulta.
 */
const FRESCO = 30_000

/**
 * El estado de una consulta, visto desde la paleta.
 *
 * `esperando` es el retardo de lo tecleado: mientras corre, lo que hay en
 * pantalla es la respuesta a otro texto, así que el grupo dice «Buscando…» en
 * vez de enseñarla. Un reintento en marcha también es «Buscando…», no el
 * fallo de antes.
 */
function useFuente<T>(q: UseQueryResult<T[]>, esperando: boolean): FuenteViva<T> {
  let estado: EstadoGrupo = 'listo'
  if (esperando || q.isPending) estado = 'cargando'
  else if (q.isError) estado = q.isFetching ? 'cargando' : 'error'

  // El mismo objeto mientras no cambie nada: la paleta arma los grupos con
  // `useMemo` sobre esto, y mover la selección no debe volver a armarlos.
  const { data, refetch } = q
  return useMemo(
    () => ({
      estado,
      filas: estado === 'listo' ? (data ?? []) : [],
      reintentar: () => void refetch(),
    }),
    [estado, data, refetch],
  )
}

/**
 * Las cuatro fuentes de la paleta. `consulta` es la de lo tecleado tras el
 * retardo; cada consulta al servidor solo corre si su forma la pide.
 *
 * Las claves van bajo `paleta` para no pisar la caché de las pantallas:
 * Personas pide cincuenta filas y aquí se piden las que enseña la paleta, o
 * veinte cuando son cifras y se reordenan. Los locales sí comparten clave con
 * el resto del panel: es la lista entera, se filtra aquí y casi siempre ya está.
 */
export function useFuentes(consulta: Consulta, esperando: boolean): FuentesDePaleta {
  const aguja = consulta.personas
  const tope = personasAPedir(consulta)
  const personas = useQuery({
    queryKey: ['paleta', 'personas', aguja, tope],
    queryFn: () => fetchUsers({ search: aguja ?? '', limit: tope }),
    enabled: aguja !== null,
    staleTime: FRESCO,
  })

  // Con la almohadilla, `admin_charges` compara solo el número de orden. Sin
  // ella casaría también con teléfonos que contienen esas cifras, y con un
  // tope pequeño la orden buscada podría quedarse fuera.
  const orden = consulta.orden
  const consumos = useQuery({
    queryKey: ['paleta', 'consumos', orden],
    queryFn: () => fetchCharges({ search: `#${orden ?? ''}`, limit: 3 }),
    enabled: orden !== null,
    staleTime: FRESCO,
  })

  const referencia = consulta.referencia === null ? null : agujaDeReferencia(consulta.referencia)
  const pagos = useQuery({
    queryKey: ['paleta', 'pagos', referencia],
    queryFn: () => buscarPagosPorReferencia(referencia ?? ''),
    enabled: referencia !== null,
    staleTime: FRESCO,
  })

  const locales = useQuery({
    queryKey: ['merchants'],
    queryFn: fetchMerchants,
    staleTime: 5 * 60_000,
  })

  return {
    personas: useFuente(personas, esperando),
    consumos: useFuente(consumos, esperando),
    pagos: useFuente(pagos, esperando),
    // Se filtra en el cliente con lo tecleado, sin retardo.
    locales: useFuente(locales, false),
  }
}
