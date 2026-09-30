import { formatUsd, formatPorcentaje } from '@/components/ui'
import type { SenalDeCifra } from '@/components/ui'
import { pctDeUmbral } from '@/components/admin/tableros/senales'
import { textoDeDesglose } from '@/features/admin/metricas/formato'
import type { Delta } from '@/features/admin/metricas/formato'
import type { TonoDePestana } from '@/features/admin/metricas/pestanas'
import { valorDe } from '@/features/admin/parametros'
import type { Parametros } from '@/features/admin/parametros'
import { progresoDeMeta } from '@/features/admin/semana'
import { senalPorUmbral, senalPorUmbralAlto, umbralCobroATiempo, umbralMora } from '@/features/admin/umbrales'
import { etiquetaDeSemana } from './etiquetas'
import { FILAS, cambioDeFila, escribir, tonoDeFila } from './filas'
import type { DefinicionDeFila, DestinoDeFila } from './filas'
import type { RespuestaSemanas } from './tipos'

// ═══════════════════════════════════════════════════════════════════════════
// Las cinco cifras de arriba de la pestaña: consumo (sin fee), service fee
// sin IVA, personas, cobrado a tiempo y mora, cada una con su cambio frente
// a la anterior, su chispa de las últimas ocho semanas, su meta o su umbral
// y una línea.
//
// No hay aritmética nueva: cada cifra ES una fila de la tabla (`filas.ts`),
// con su mismo valor, su misma comparación y su mismo destino. Así la tarjeta
// y la tabla no pueden decir cosas distintas.
//
// Puro: se prueba en `cifras.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Las semanas de la chispa: las ocho últimas, aunque la tabla enseñe más. */
export const SEMANAS_DE_LA_CHISPA = 8

export type IdCifra = 'consumo' | 'servicio' | 'personas' | 'a-tiempo' | 'mora'

export type CifraDeLaSemana = {
  id: IdCifra
  titulo: string
  /** Ya escrita. «—» si no hay con qué medirla. */
  valor: string
  delta: Delta | null
  /** Solo al cruzar un `umbral_*`. */
  senal?: SenalDeCifra
  /** Una línea: la meta, el desglose o lo que la completa. */
  pie: string
  info: string
  chispa: {
    valores: Array<number | null>
    etiquetas: string[]
    rotulo: string
    formato: (n: number) => string
    /**
     * El nombre de la serie junto a la cifra, en el globo de cada barra de la
     * chispa: «Consumo (sin fee)». Es el título de la tarjeta, así el globo
     * también dice si el consumo lleva el fee.
     */
    serie: string
  }
  destino: DestinoDeFila
  /** El área de la cifra: su chispa va en ese tono (consumo en rosa, cobro en azul). */
  tono: TonoDePestana
}

export type DatosDeLasCifras = {
  respuesta: RespuestaSemanas
  /** El local elegido: las metas son de todo Ronda y con local no se miden. */
  local: string | null
  /** Los parámetros del negocio (metas y umbrales). Sin ellos, sin metas ni pastillas. */
  parametros: Parametros | undefined
}

/** El orden de la maqueta. */
export const ORDEN_DE_CIFRAS: ReadonlyArray<IdCifra> = ['consumo', 'servicio', 'personas', 'a-tiempo', 'mora']

/**
 * El título de cada tarjeta. El consumo dice que va sin el fee y el fee se
 * llama por su nombre: «service fee», nunca «servicio».
 */
export const TITULOS_DE_CIFRAS: Record<IdCifra, string> = {
  consumo: 'Total financiado (sin fee)',
  servicio: 'Service fee sin IVA',
  personas: 'Pacientes que se financiaron',
  'a-tiempo': 'Cobrado a tiempo',
  mora: 'Mora',
}

function filaDe(id: IdCifra): DefinicionDeFila {
  const fila = FILAS.find((f) => f.id === id)
  if (!fila) throw new Error(`La cifra «${id}» no tiene fila en la tabla.`)
  return fila
}

/** «18 nuevos en Ronda» (o «en el local»): la fila «Usuarios nuevos». */
function usuariosNuevos(n: number, conLocal: boolean): string {
  const donde = conLocal ? 'en la clínica' : 'en Helios'
  if (n === 0) return `Ningún paciente nuevo ${donde}`
  return `${n} ${n === 1 ? 'nuevo' : 'nuevos'} ${donde}`
}

/** Las cinco cifras, en el orden de la maqueta. */
export function cifrasDeLaSemana({ respuesta, local, parametros }: DatosDeLasCifras): CifraDeLaSemana[] {
  const ultimas = respuesta.semanas.slice(-SEMANAS_DE_LA_CHISPA)
  const elegida = respuesta.semanas.at(-1)
  if (!elegida) return []
  const c = elegida.cifras
  const anterior = respuesta.comparacion.cifras
  const etiquetas = ultimas.map((s) => etiquetaDeSemana(s.desde, s.hasta))
  const conMetas = local === null

  function cifra(id: IdCifra, pie: string, senal?: SenalDeCifra): CifraDeLaSemana {
    const fila = filaDe(id)
    const formato = (n: number) => escribir(n, fila.formato)
    return {
      id,
      titulo: TITULOS_DE_CIFRAS[id],
      valor: escribir(fila.valor(c), fila.formato),
      delta: cambioDeFila(fila, c, anterior),
      senal,
      pie,
      info: fila.ayuda,
      chispa: {
        valores: ultimas.map((s) => fila.valor(s.cifras)),
        etiquetas,
        rotulo: `${TITULOS_DE_CIFRAS[id]}, de las últimas ${ultimas.length} semanas`,
        formato,
        serie: TITULOS_DE_CIFRAS[id],
      },
      destino: fila.destino,
      tono: tonoDeFila(id),
    }
  }

  // Consumo, frente a su meta semanal (que es de todo Ronda).
  const metaConsumo = conMetas ? valorDe(parametros, 'meta_financiado_semana_usd') : null
  const progreso = progresoDeMeta(c.consumo.consumoUsd, metaConsumo, 'subir')
  const pieConsumo =
    metaConsumo !== null && progreso?.pct != null
      ? `Meta semanal ${formatUsd(metaConsumo)} · ${elegida.enCurso ? 'va' : 'llegó'} al ${formatPorcentaje(progreso.pct)}`
      : `${c.consumo.consumos} ${c.consumo.consumos === 1 ? 'financiamiento' : 'financiamientos'}`

  // Cobrado a tiempo: su pastilla sale del umbral; su meta, de las metas.
  const aTiempo = c.cobro.aTiempo
  const metaCobro = conMetas ? valorDe(parametros, 'meta_cobro_a_tiempo_pct') : null
  const pieCobro =
    aTiempo.pct === null
      ? 'Ninguna cuota con el plazo cerrado todavía'
      : `De ${aTiempo.juzgadas} ${aTiempo.juzgadas === 1 ? 'cuota' : 'cuotas'} con el plazo cerrado` +
        (metaCobro === null ? '' : ` · meta ${pctDeUmbral(metaCobro)}`)

  // Mora: su pastilla sale del umbral; lo vencido va con sus dos partes.
  const mora = c.riesgo.moraPct
  const vencido = c.riesgo.vencido
  const pieMora =
    mora === null
      ? 'Nada por cobrar al cierre'
      : vencido.payableUsd > 0
        ? `${textoDeDesglose(vencido)} vencidos`
        : 'Nada vencido'

  return [
    cifra('consumo', pieConsumo),
    cifra('servicio', 'Nunca se suma al financiamiento'),
    cifra('personas', usuariosNuevos(c.gente.primerConsumo, local !== null)),
    cifra('a-tiempo', pieCobro, senalPorUmbralAlto(aTiempo.pct, umbralCobroATiempo(parametros), pctDeUmbral)),
    cifra('mora', pieMora, senalPorUmbral(mora, umbralMora(parametros), pctDeUmbral)),
  ]
}
