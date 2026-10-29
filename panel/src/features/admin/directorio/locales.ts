import type { EstadoLocal } from '@/features/admin/estados'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que la lista de Locales sabe hacer sin la base: la búsqueda por nombre,
// consultorio, razón social, médico titular o RIF. El estado de un local está en `estados.ts`.
//
// Módulo puro: se prueba en Node (`locales.test.ts`). La lista es corta y
// viene entera, así que se filtra en el navegador.
// ═══════════════════════════════════════════════════════════════════════════

/** Sin tildes, sin mayúsculas y sin espacios de sobra. */
export function normalizarTexto(texto: string): string {
  return texto.normalize('NFD').replace(/\p{Diacritic}/gu, '').toLowerCase().trim()
}

/** Solo letras y números: «J-12345678-9» y «j123456789» son el mismo RIF. */
function soloAlfanumerico(texto: string): string {
  return normalizarTexto(texto).replace(/[^a-z0-9]/g, '')
}

type Buscable = {
  name: string
  legalName: string | null
  taxId: string | null
  status: EstadoLocal
  /** El médico titular. Opcional: no todas las listas lo traen. */
  ownerName?: string | null
  /** El nombre del consultorio («Grupo Médico 708»). Opcional, como el titular. */
  consultorio?: string | null
}

/**
 * Si el local casa con lo buscado: nombre (el del médico), consultorio,
 * razón social, médico titular o RIF.
 */
export function casaConLaBusqueda(local: Buscable, texto: string): boolean {
  const aguja = normalizarTexto(texto)
  if (aguja === '') return true

  if (normalizarTexto(local.name).includes(aguja)) return true
  if (local.consultorio && normalizarTexto(local.consultorio).includes(aguja)) return true
  if (local.legalName && normalizarTexto(local.legalName).includes(aguja)) return true
  if (local.ownerName && normalizarTexto(local.ownerName).includes(aguja)) return true

  const rif = soloAlfanumerico(aguja)
  return rif !== '' && local.taxId !== null && soloAlfanumerico(local.taxId).includes(rif)
}

/** La lista filtrada por texto y por estado. Sin filtros, la lista tal cual. */
export function filtrarLocales<T extends Buscable>(
  locales: ReadonlyArray<T>,
  filtro: { texto?: string; estado?: EstadoLocal },
): Array<T> {
  return locales.filter(
    (l) =>
      (!filtro.estado || l.status === filtro.estado) &&
      (!filtro.texto || casaConLaBusqueda(l, filtro.texto)),
  )
}
