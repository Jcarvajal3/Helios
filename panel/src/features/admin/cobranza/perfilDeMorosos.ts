import { formatUsd, formatNumero } from '@/components/ui'
import { comoFila, comoLista, filaONula, numero, numeroONulo, texto } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// Por cobrar › Morosos: cómo es la gente que debe algo vencido, frente a la
// que ya tuvo que pagar y está al día, de todas las semanas y locales
// (`admin_perfil_de_morosos`, 20260929130000).
//
// Aquí se lee la respuesta y se arman las filas que se comparan: cada rasgo
// con su cifra en «Morosos» y en «Al día» y, si es una parte, su porcentaje
// para la barra. Un porcentaje se calcula sobre quien tiene el dato (el sexo,
// sobre quien tiene sexo conocido), y sin nadie con el dato no hay cifra.
//
// Puro: se prueba en `perfilDeMorosos.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

export type RasgosDeGrupo = {
  personas: number
  /** Cuántos deben algo vencido o perdido (solo tiene sentido en «Morosos»). */
  vencidas: number
  atrasoMedioDias: number | null
  edad: { conocida: number; mediana: number | null; tramos: Record<TramoDeEdad, number> }
  sexo: { F: number; M: number; sinDato: number }
  plataforma: { android: number; ios: number; otra: number; sinDato: number }
  nivelMedio: number | null
  /** Su primer consumo en Ronda fue hace menos de 4 semanas. */
  nuevos: number
  enGrupo: number
  sinAvisos: number
  /** Lo que ha consumido en Ronda, sin fee, de media por persona. */
  consumoMedioUsd: number | null
  ciudades: ReadonlyArray<{ ciudad: string; personas: number }>
  ciudadesOtras: number
}

export const TRAMOS_DE_EDAD = ['18-24', '25-34', '35-44', '45+'] as const
export type TramoDeEdad = (typeof TRAMOS_DE_EDAD)[number]

export type PerfilDeMorosos = {
  businessDate: string
  /** `null`: nadie debe nada vencido (o nadie está al día). */
  morosos: RasgosDeGrupo | null
  alDia: RasgosDeGrupo | null
}

function leerGrupo(raw: unknown): RasgosDeGrupo | null {
  const r = filaONula(raw)
  if (r === null) return null
  const edad = comoFila(r.edad)
  const tramos = comoFila(edad.tramos)
  const sexo = comoFila(r.sexo)
  const plataforma = comoFila(r.plataforma)
  return {
    personas: numero(r.personas),
    vencidas: numero(r.vencidas),
    atrasoMedioDias: numeroONulo(r.atraso_medio_dias),
    edad: {
      conocida: numero(edad.conocida),
      mediana: numeroONulo(edad.mediana),
      tramos: {
        '18-24': numero(tramos['18-24']),
        '25-34': numero(tramos['25-34']),
        '35-44': numero(tramos['35-44']),
        '45+': numero(tramos['45+']),
      },
    },
    sexo: { F: numero(sexo.F), M: numero(sexo.M), sinDato: numero(sexo.sin_dato) },
    plataforma: {
      android: numero(plataforma.android),
      ios: numero(plataforma.ios),
      otra: numero(plataforma.otra),
      sinDato: numero(plataforma.sin_dato),
    },
    nivelMedio: numeroONulo(r.nivel_medio),
    nuevos: numero(r.nuevos),
    enGrupo: numero(r.en_grupo),
    sinAvisos: numero(r.sin_avisos),
    consumoMedioUsd: numeroONulo(r.consumo_medio_usd),
    ciudades: comoLista(r.ciudades).map((c) => {
      const f = comoFila(c)
      return { ciudad: texto(f.ciudad), personas: numero(f.personas) }
    }),
    ciudadesOtras: numero(r.ciudades_otras),
  }
}

export function leerPerfilDeMorosos(raw: unknown): PerfilDeMorosos {
  const d = comoFila(raw)
  return {
    businessDate: texto(d.business_date),
    morosos: leerGrupo(d.morosos),
    alDia: leerGrupo(d.al_dia),
  }
}

// ── Las filas que se comparan ──────────────────────────────────────────────

/** La cifra de un grupo en una fila: el texto y, si es una parte, su porcentaje (0-100). */
export type CeldaDeRasgo = { texto: string; pct: number | null } | null

export type FilaDeRasgo = {
  clave: string
  rotulo: string
  /** Qué quiere decir, con el denominador: el globo de la fila. */
  ayuda: string
  morosos: CeldaDeRasgo
  alDia: CeldaDeRasgo
}

/** Una parte de un total, en %; `null` sin nadie con el dato. */
export function parte(n: number, de: number): number | null {
  return de > 0 ? (n / de) * 100 : null
}

function celdaPct(n: number, de: number): CeldaDeRasgo {
  const p = parte(n, de)
  return p === null ? null : { texto: `${formatNumero(p, 0)} %`, pct: p }
}

function tramoMasComun(g: RasgosDeGrupo): TramoDeEdad | null {
  let mejor: TramoDeEdad | null = null
  for (const t of TRAMOS_DE_EDAD) {
    if (g.edad.tramos[t] > 0 && (mejor === null || g.edad.tramos[t] > g.edad.tramos[mejor])) mejor = t
  }
  return mejor
}

const RASGOS: ReadonlyArray<{
  clave: string
  rotulo: string
  ayuda: string
  celda: (g: RasgosDeGrupo) => CeldaDeRasgo
}> = [
  {
    clave: 'edad',
    rotulo: 'Edad (mediana)',
    ayuda: 'La mitad tiene menos y la otra mitad más. Sale del perfil o del documento de identidad.',
    celda: (g) => (g.edad.mediana === null ? null : { texto: `${formatNumero(g.edad.mediana, 0)} años`, pct: null }),
  },
  {
    clave: 'tramo',
    rotulo: 'Tramo de edad más común',
    ayuda: 'El tramo con más gente y qué parte de quien tiene la edad conocida cae en él.',
    celda: (g) => {
      const t = tramoMasComun(g)
      if (t === null) return null
      const p = parte(g.edad.tramos[t], g.edad.conocida)
      return { texto: `${t} años · ${formatNumero(p ?? 0, 0)} %`, pct: p }
    },
  },
  {
    clave: 'mujeres',
    rotulo: 'Mujeres',
    ayuda: 'Sobre quien tiene el sexo registrado (lo pone la clínica al registrarlo).',
    celda: (g) => celdaPct(g.sexo.F, g.sexo.F + g.sexo.M),
  },
  // Fuera «Con iPhone», «Se financió en grupo» y «Sin avisos»: los tres
  // salían de la app de Ronda (el aparato, los grupos y el push). Los datos
  // se siguen leyendo (`plataforma`, `enGrupo`, `sinAvisos`) por si la base
  // los manda, pero en Helios no dicen nada.
  {
    clave: 'nuevos',
    rotulo: 'Menos de 4 semanas en Helios',
    ayuda: 'Su primer financiamiento en Helios, en cualquier clínica, fue hace menos de cuatro semanas.',
    celda: (g) => celdaPct(g.nuevos, g.personas),
  },
  {
    clave: 'consumo',
    rotulo: 'Financiamiento medio en Helios',
    ayuda: 'Lo que se ha financiado cada paciente desde que entró, sin fee: el financiado, de media.',
    celda: (g) => (g.consumoMedioUsd === null ? null : { texto: formatUsd(g.consumoMedioUsd), pct: null }),
  },
  {
    clave: 'nivel',
    rotulo: 'Nivel medio',
    ayuda: 'El nivel de hoy, de 0 a 4.',
    celda: (g) => (g.nivelMedio === null ? null : { texto: formatNumero(g.nivelMedio, 1), pct: null }),
  },
  {
    clave: 'ciudad',
    rotulo: 'Ciudad principal',
    ayuda: 'La ciudad desde la que se verificó, por su IP (sin VPN). Una ciudad con menos de 3 pacientes no se nombra.',
    celda: (g) => {
      if (g.ciudades.length === 0) return null
      const c = g.ciudades[0]
      const conCiudad = g.ciudades.reduce((a, x) => a + x.personas, 0) + g.ciudadesOtras
      const p = parte(c.personas, conCiudad)
      return { texto: `${c.ciudad} · ${formatNumero(p ?? 0, 0)} %`, pct: p }
    },
  },
]

/** Las filas que se comparan, en el orden en que se leen. */
export function filasDeRasgos(p: PerfilDeMorosos): FilaDeRasgo[] {
  return RASGOS.map((r) => ({
    clave: r.clave,
    rotulo: r.rotulo,
    ayuda: r.ayuda,
    morosos: p.morosos ? r.celda(p.morosos) : null,
    alDia: p.alDia ? r.celda(p.alDia) : null,
  }))
}
