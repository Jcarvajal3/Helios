import { PANTALLAS, buscarEnCatalogo } from '@/features/admin/catalogo'
import type { Entrada } from '@/features/admin/catalogo'
import { TODOS_LOS_ESPACIOS } from '@/features/admin/espacios'
import type { MerchantRow } from '@/features/admin/api'
import type { ChargeRow } from '@/features/admin/ops'
import type { UserRow } from '@/features/admin/users'
import { TITULO_DE_GRUPO, enElGrupo, gruposDe } from './consulta'
import type { Consulta, IdGrupo } from './consulta'
import type { PagoEncontrado } from './fuentes'
import {
  opcionDeConsumo,
  opcionDeEntrada,
  opcionDeLocal,
  opcionDePago,
  opcionDePersona,
  opcionDeReciente,
  opcionPreguntar,
  opcionReintentar,
} from './opciones'
import { pareceUnaPregunta } from '@/features/admin/asistente/pregunta'
import type { Opcion } from './opciones'
import type { Reciente } from './recientes'
import {
  POR_GRUPO,
  atajosDeEspacios,
  buscarLocales,
  buscarPagos,
  delNumero,
  ordenarPersonas,
} from './resultados'

// ═══════════════════════════════════════════════════════════════════════════
// Cada fuente como un `Grupo` con su estado, en el orden en que se pinta.
//
// Sin React, para poder probarlo: un fallo es un fallo y no una lista vacía,
// y «Nada con…» solo se dice cuando todo contestó y nada falló.
// ═══════════════════════════════════════════════════════════════════════════

export type EstadoGrupo = 'listo' | 'cargando' | 'error'

export type Grupo = {
  id: IdGrupo
  titulo: string
  estado: EstadoGrupo
  opciones: ReadonlyArray<Opcion>
}

/** Lo que da una fuente de datos, sea del servidor o de la caché. */
export type Fuente<T> = { estado: EstadoGrupo; filas: ReadonlyArray<T> }

// ── Los grupos ─────────────────────────────────────────────────────────────

export type DatosDePaleta = {
  consulta: Consulta
  esSuperAdmin: boolean
  recientes: ReadonlyArray<Reciente>
  personas: Fuente<UserRow>
  locales: Fuente<MerchantRow>
  consumos: Fuente<ChargeRow>
  pagos: Fuente<PagoEncontrado>
  /** Si se ofrece «Preguntarle al asistente». Solo donde hay asistente. */
  preguntar?: boolean
}

type Contenido = { estado: EstadoGrupo; opciones: ReadonlyArray<Opcion> }

/**
 * Una fuente, como contenido de su grupo. Si falló, el grupo lo dice y ofrece
 * reintentar; si espera, se queda sin filas y el grupo pinta su línea de
 * «Buscando…». Nunca se convierte un fallo en una lista vacía.
 */
function deFuente<T>(
  grupo: IdGrupo,
  fuente: Fuente<T>,
  convertir: (filas: ReadonlyArray<T>) => ReadonlyArray<Opcion>,
): Contenido {
  if (fuente.estado === 'error') return { estado: 'error', opciones: [opcionReintentar(grupo)] }
  if (fuente.estado === 'cargando') return { estado: 'cargando', opciones: [] }
  return { estado: 'listo', opciones: convertir(fuente.filas) }
}

/**
 * Los grupos que se pintan, en orden. Un grupo listo y sin nada no sale; uno
 * que espera o que falló, sí, para que se vea que falta algo por saber.
 */
export function construirGrupos(d: DatosDePaleta): Grupo[] {
  const c = d.consulta
  const catalogo = c.forma === 'texto' ? buscarEnCatalogo(c.texto) : null
  const deCatalogo = (grupo: IdGrupo, entradas: ReadonlyArray<Entrada>): Contenido => ({
    estado: 'listo',
    opciones: entradas.map((e) => opcionDeEntrada(e, grupo, d.esSuperAdmin)),
  })

  function contenido(grupo: IdGrupo): Contenido {
    switch (grupo) {
      case 'recientes':
        return {
          estado: 'listo',
          opciones: d.recientes
            .map((r) => opcionDeReciente(r, d.esSuperAdmin))
            .filter((o): o is Opcion => o !== null),
        }
      case 'atajos': {
        const yaEstan = new Set(d.recientes.filter((r) => r.tipo === 'catalogo').map((r) => r.id))
        const atajos = atajosDeEspacios(PANTALLAS, TODOS_LOS_ESPACIOS).filter((p) => !yaEstan.has(p.id))
        return deCatalogo(grupo, atajos)
      }
      case 'pantallas':
        return deCatalogo(grupo, catalogo?.pantallas ?? [])
      case 'acciones':
        return deCatalogo(grupo, catalogo?.acciones ?? [])
      case 'cifras':
        return deCatalogo(grupo, catalogo?.cifras ?? [])
      case 'terminos':
        return deCatalogo(grupo, catalogo?.terminos ?? [])
      case 'personas':
        return deFuente(grupo, d.personas, (filas) =>
          ordenarPersonas(filas, c).slice(0, POR_GRUPO).map(opcionDePersona),
        )
      case 'locales':
        return deFuente(grupo, d.locales, (filas) => buscarLocales(filas, c).map(opcionDeLocal))
      case 'consumos':
        return deFuente(grupo, d.consumos, (filas) => delNumero(filas, c.orden).map(opcionDeConsumo))
      case 'pagos':
        return deFuente(grupo, d.pagos, (filas) => buscarPagos(filas, c.referencia).map(opcionDePago))
      case 'asistente':
        return { estado: 'listo', opciones: [opcionPreguntar(c.texto)] }
    }
  }

  const grupos = gruposDe(c)
    .map((id): Grupo => ({ id, titulo: TITULO_DE_GRUPO[id], ...contenido(id) }))
    .filter((g) => g.estado !== 'listo' || g.opciones.length > 0)

  // Con texto, lo tecleado también se le puede preguntar al asistente: al
  // final de todo, o lo primero si tiene forma de pregunta («¿cuánto…?»).
  if (!d.preguntar || c.forma === 'vacio') return grupos
  const asistente: Grupo = { id: 'asistente', titulo: TITULO_DE_GRUPO.asistente, ...contenido('asistente') }
  return pareceUnaPregunta(c.texto) ? [asistente, ...grupos] : [...grupos, asistente]
}

// ── El resumen ─────────────────────────────────────────────────────────────

export type Resumen = {
  /** Cuántos resultados de verdad hay: las líneas de fallo no cuentan. */
  encontrados: number
  /** Algún grupo sigue esperando al servidor. */
  esperando: boolean
  /** Los grupos que fallaron. */
  fallidos: ReadonlyArray<IdGrupo>
}

export function resumir(grupos: ReadonlyArray<Grupo>): Resumen {
  return {
    // «Preguntarle al asistente» no es algo encontrado: con solo eso, sigue
    // siendo «Nada con…».
    encontrados: grupos
      .filter((g) => g.estado === 'listo' && g.id !== 'asistente')
      .reduce((n, g) => n + g.opciones.length, 0),
    esperando: grupos.some((g) => g.estado === 'cargando'),
    fallidos: grupos.filter((g) => g.estado === 'error').map((g) => g.id),
  }
}

/**
 * Si toca decir «Nada con…». Solo cuando se buscó, ya contestó todo y nada
 * falló: con un grupo caído, «nada» sería mentira.
 */
export function noHayNada(c: Consulta, r: Resumen): boolean {
  return c.forma !== 'vacio' && !r.esperando && r.fallidos.length === 0 && r.encontrados === 0
}

/** Lo que lee el lector de pantalla cuando la búsqueda termina. */
export function anuncioDe(c: Consulta, r: Resumen): string {
  if (c.forma === 'vacio' || r.esperando) return ''
  if (noHayNada(c, r)) return `Nada con «${c.texto}».`
  const cuantos = `${r.encontrados} ${r.encontrados === 1 ? 'resultado' : 'resultados'}.`
  const fallos = r.fallidos.map((g) => ` No se pudo buscar en ${enElGrupo(g)}.`).join('')
  return `${cuantos}${fallos}`
}
