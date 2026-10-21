// ═══════════════════════════════════════════════════════════════════════════
// Las pestañas de Métricas (`/admin/metricas`) y sus sub-pestañas, en el
// orden en que se pintan (Javier, 27-09: «Ya casi llegamos al superadmin
// perfecto y usable»).
//
// Es el registro: el marco, el catálogo (Ctrl K) y las pruebas leen de aquí
// qué pestañas hay, qué sub-pestañas tiene cada una (la primera es la de por
// defecto), cómo se llaman, qué contesta cada una, en qué tono se pintan,
// qué periodo miran y si se parten por local. Una sub-pestaña nueva se da de
// alta aquí y en `MarcoMetricas.tsx` (qué componente la pinta).
//
// Las carpetas del código NO se renombran: `cohortes/`, `cobranza/` y
// `general/` siguen, y cada sub-pestaña dice en `carpeta` cuál la pinta.
//
// Puro, sin React ni Supabase: se prueba con `npx tsx`.
// ═══════════════════════════════════════════════════════════════════════════

/** Las siete pestañas, en su orden. La primera es la de por defecto. */
export const IDS_PESTANA = ['semana', 'cobros', 'mora', 'caja', 'locales', 'gente', 'global'] as const

export type IdPestana = (typeof IDS_PESTANA)[number]

/**
 * La carpeta del código que pinta una sub-pestaña
 * (`components/admin/metricas/<carpeta>/`, `features/admin/metricas/<carpeta>/`).
 * También es el espacio de sus claves de caché (`claveMetricas`), que no
 * cambian al mover una sub-pestaña de sitio.
 */
export type CarpetaDeMetricas =
  | 'semana'
  | 'cohortes'
  | 'cobranza'
  | 'caja'
  | 'locales'
  | 'gente'
  | 'general'

/**
 * El tono de la pestaña: lo que el marco escribe en `data-area` alrededor de
 * ella (y de su subrayado y su banda de sub-pestañas), y con él el color de
 * la serie principal de sus gráficos. Los tonos son los de `styles.css`; el
 * lima nunca es un tono.
 */
export type TonoDePestana = 'neutro' | 'cobranza' | 'caja' | 'gerencia'

/**
 * Qué periodo mira lo que se ve:
 *   semana           la semana de arriba elige lo que se ve
 *   desde-el-inicio  todo desde el primer día: el selector de la semana se
 *                    cambia por la etiqueta «Desde el inicio»
 *   hoy              la foto de hoy: el selector se cambia por «Hoy»
 */
export type Periodo = 'semana' | 'desde-el-inicio' | 'hoy'

/** Cómo se parte por el local de arriba. */
export type ModoLocal = 'filtra' | 'parcial' | 'ignora'

export type DefinicionSubpestana<TSub extends string = string> = {
  id: TSub
  /** El rótulo de la píldora. */
  titulo: string
  /**
   * Qué contesta, en una línea: va en «Pestaña › Sub-pestaña — descripción»
   * encima del contenido y en su entrada de Ctrl K.
   */
  descripcion: string
  /** La carpeta que la pinta. */
  carpeta: CarpetaDeMetricas
  /** Si no mira el periodo de su pestaña. */
  periodo?: Periodo
}

type Registro = {
  /** El rótulo de la pestaña. */
  titulo: string
  tono: TonoDePestana
  /** El periodo de la pestaña; una sub-pestaña puede mirar otro. */
  periodo: Periodo
  /**
   * `filtra`: todo lo de la pestaña se parte por el local elegido.
   * `parcial`: casi todo; lo que no se parte lo dice en su sitio con
   * `NoSeParte`, nunca con un cero. `ignora`: nada se parte y el selector se
   * apaga con el motivo.
   */
  local: ModoLocal
  /** La pregunta que contesta la pestaña entera, en una línea: la lee quien busca en Ctrl K. */
  pregunta: string
  /**
   * Una pestaña sin sub-pestañas: qué contesta (la línea de «dónde estás») y
   * qué carpeta la pinta. Con sub-pestañas lo dice cada una.
   */
  descripcion: string
  carpeta: CarpetaDeMetricas
  /** En su orden; la primera es la de por defecto. Vacío: no tiene. */
  subpestanas: ReadonlyArray<DefinicionSubpestana>
}

const REGISTRO = {
  semana: {
    titulo: 'Semana',
    tono: 'gerencia',
    periodo: 'semana',
    local: 'parcial',
    pregunta: '¿Cómo va el negocio esta semana frente a las anteriores?',
    descripcion: 'Lo financiado en la semana y cómo va frente a las anteriores.',
    carpeta: 'semana',
    subpestanas: [
      {
        id: 'resumen',
        titulo: 'Resumen',
        descripcion:
          'Total financiado (sin comisión), Comisión Helios + IVA y total a cobrar de la semana, con los financiamientos y los pacientes.',
        carpeta: 'semana',
      },
      {
        id: 'rendimiento',
        titulo: 'Rendimiento',
        descripcion: 'Las cifras que mandan, semana a semana, frente a la anterior y a sus metas.',
        carpeta: 'semana',
      },
    ],
  },
  cobros: {
    titulo: 'Cobros',
    tono: 'cobranza',
    periodo: 'semana',
    local: 'filtra',
    pregunta: 'De lo financiado una semana: cuánto hay que cobrar (financiamiento + comisión), cuánto se cobró y cuánto falta.',
    descripcion: 'Lo que hay que cobrar de cada semana de financiamientos y cómo va.',
    carpeta: 'cohortes',
    // Una semana sola, con sus cuotas y quién la debe, es trabajo: vive en
    // Por cobrar › Cohortes (28-09). Los avisos de una cohorte, en
    // Notificaciones › Rendimiento (29-09). Aquí queda lo que compara semanas.
    subpestanas: [
      {
        // El id sigue siendo `calendario`: es lo que llevan los enlaces guardados.
        id: 'calendario',
        titulo: 'Semanas',
        descripcion:
          'Todas las semanas comparadas: lo que hay que cobrar y cómo va, y la curva y las clínicas de la elegida.',
        carpeta: 'cohortes',
      },
      // Sigue cada semana de financiamientos como Semanas: por eso está
      // aquí y no en Riesgo, que es la foto de la cartera al corte.
      {
        id: 'impago-por-cuota',
        titulo: 'Impago por cuota',
        descripcion: 'Qué parte de la cuota 1 y de la cuota 2 sigue sin pagar al terminar la gracia.',
        carpeta: 'cobranza',
      },
    ],
  },
  // El id sigue siendo `mora`: es lo que llevan la URL y los enlaces guardados.
  mora: {
    titulo: 'Riesgo',
    tono: 'cobranza',
    periodo: 'semana',
    local: 'filtra',
    pregunta: '¿Cuánto está vencido y en qué tramo, cuánto cupo está ocupado y cuánto recupera la cobranza?',
    descripcion: 'Lo vencido y en qué tramo, el cupo ocupado y lo que recupera la cobranza.',
    carpeta: 'cobranza',
    subpestanas: [
      {
        id: 'resumen',
        titulo: 'Resumen',
        descripcion: 'Lo vencido al cierre de la semana y en qué tramo, lo que vencía frente a lo que entró y el cambio de tramo.',
        carpeta: 'cobranza',
      },
      {
        id: 'cupos',
        titulo: 'Cupos',
        descripcion: 'Qué parte de su cupo (sin comisión) usan hoy los pacientes de cada nivel.',
        carpeta: 'cobranza',
        periodo: 'hoy',
      },
      {
        id: 'rendimiento',
        titulo: 'Rendimiento',
        descripcion: 'Lo que consiguió la cobranza en la semana: lo recuperado, las gestiones, las promesas y la cura por tramo.',
        carpeta: 'cobranza',
      },
    ],
  },
  caja: {
    titulo: 'Caja',
    tono: 'caja',
    periodo: 'semana',
    local: 'parcial',
    pregunta: '¿Cuánto dinero hay, cuánto entra y sale, y cuánto hará falta?',
    descripcion: 'El dinero que hay, el que entra y sale, y el que hará falta.',
    carpeta: 'caja',
    subpestanas: [
      {
        id: 'balance',
        titulo: 'Balance',
        descripcion: 'Lo que entró y salió en la semana, el balance de hoy según el libro y el capital comprometido.',
        carpeta: 'caja',
      },
      {
        id: 'proyeccion',
        titulo: 'Proyección y banco',
        descripcion: 'Lo que entrará y saldrá día a día hasta que vence lo que hoy está en la calle, y el saldo del banco.',
        carpeta: 'caja',
        periodo: 'hoy',
      },
    ],
  },
  locales: {
    titulo: 'Clínicas',
    tono: 'gerencia',
    periodo: 'semana',
    local: 'filtra',
    pregunta: '¿Cuánto se financia en cada clínica y cómo pagan sus pacientes?',
    descripcion: 'Lo financiado (sin comisión) en cada clínica en la semana y cómo pagan sus pacientes. Pulsa una clínica para ver su ficha.',
    carpeta: 'locales',
    subpestanas: [],
  },
  gente: {
    titulo: 'Pacientes',
    tono: 'gerencia',
    periodo: 'semana',
    local: 'parcial',
    pregunta: '¿Cuántos pacientes registraron las clínicas y cuántos pagaron en cuotas?',
    descripcion: 'Pacientes registrados por las clínicas y pacientes que pagaron en cuotas en la ventana, con los estados de las cuentas y los niveles.',
    carpeta: 'gente',
    subpestanas: [],
  },
  global: {
    titulo: 'Global',
    tono: 'gerencia',
    periodo: 'desde-el-inicio',
    local: 'parcial',
    pregunta: '¿Cómo va el negocio desde el primer día: pacientes, financiado, dinero y riesgo?',
    descripcion: 'Todo el negocio desde el primer día: registros y pacientes, financiado (sin comisión), lo que se debe, lo cobrado y el riesgo.',
    carpeta: 'general',
    subpestanas: [],
  },
} as const satisfies { readonly [TId in IdPestana]: Registro }

/** Las sub-pestañas de una pestaña, por su id. `never` si no tiene. */
export type IdSubpestana<TId extends IdPestana> = (typeof REGISTRO)[TId]['subpestanas'][number]['id']

/**
 * Un sitio de Métricas: una pestaña y, si tiene, una de sus sub-pestañas. Sin
 * `sub`, la primera. Es lo que guarda un enlace entre pestañas.
 */
export type Lugar = { [TId in IdPestana]: { vista: TId; sub?: IdSubpestana<TId> } }[IdPestana]

export type DefinicionPestana = Registro & { id: IdPestana }

/** Las pestañas, en su orden. */
export const PESTANAS: ReadonlyArray<DefinicionPestana> = IDS_PESTANA.map((id) => ({ id, ...REGISTRO[id] }))

/**
 * La pestaña que se ve sin `?vista=`: Semana, la primera. Es lo que más se
 * mira (el progreso semana a semana) y se abre en la semana en curso.
 */
export const PESTANA_POR_DEFECTO = 'semana' satisfies IdPestana

/** La definición de una pestaña. Siempre existe: el tipo del id lo garantiza. */
export function definicionDe(id: IdPestana): DefinicionPestana {
  const encontrada = PESTANAS.find((p) => p.id === id)
  if (!encontrada) throw new Error(`No hay ninguna pestaña de Métricas con el id «${id}»`)
  return encontrada
}

/** Las sub-pestañas de una pestaña, en su orden. Vacío si no tiene. */
export function subpestanasDe<TId extends IdPestana>(id: TId): ReadonlyArray<DefinicionSubpestana<IdSubpestana<TId>>> {
  return REGISTRO[id].subpestanas
}

/** Los ids de las sub-pestañas de una pestaña. */
export function idsDeSubpestanas<TId extends IdPestana>(id: TId): ReadonlyArray<IdSubpestana<TId>> {
  return subpestanasDe(id).map((s) => s.id)
}

/** La sub-pestaña que se ve sin `?sub=`: la primera. `undefined` si no tiene. */
export function subPorDefecto<TId extends IdPestana>(id: TId): IdSubpestana<TId> | undefined {
  return subpestanasDe(id).at(0)?.id
}

/**
 * La sub-pestaña que se mira: la pedida si es de esa pestaña, y si no la
 * primera. `null` si la pestaña no tiene sub-pestañas.
 */
export function subpestanaDe<TId extends IdPestana>(
  id: TId,
  sub: unknown,
): DefinicionSubpestana<IdSubpestana<TId>> | null {
  const todas = subpestanasDe(id)
  return todas.find((s) => s.id === sub) ?? todas.at(0) ?? null
}

/** El periodo de lo que se ve: el de la sub-pestaña, o el de su pestaña. */
export function periodoDe(id: IdPestana, sub?: string): Periodo {
  return subpestanaDe(id, sub)?.periodo ?? definicionDe(id).periodo
}

/**
 * El nombre de un sitio, como se escribe en la línea de «dónde estás» y en
 * Ctrl K: «Cobros › Calendario», o «Locales» para una pestaña sin
 * sub-pestañas.
 */
export function nombreDelLugar(lugar: Lugar): string {
  const pestana = definicionDe(lugar.vista)
  const sub = subpestanaDe(lugar.vista, lugar.sub)
  return sub ? `${pestana.titulo} › ${sub.titulo}` : pestana.titulo
}

/** Lo que contesta un sitio, en una línea: la descripción de su sub-pestaña, o la de su pestaña. */
export function descripcionDelLugar(lugar: Lugar): string {
  return subpestanaDe(lugar.vista, lugar.sub)?.descripcion ?? definicionDe(lugar.vista).descripcion
}

/** La carpeta que pinta un sitio. */
export function carpetaDelLugar(lugar: Lugar): CarpetaDeMetricas {
  return subpestanaDe(lugar.vista, lugar.sub)?.carpeta ?? definicionDe(lugar.vista).carpeta
}
