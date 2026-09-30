import { useEffect, useId, useMemo, useState } from 'react'
import type { KeyboardEvent, MouseEvent, ReactNode } from 'react'
import { ArrowDown, ArrowUp, ChevronsUpDown, Columns3, Download, Rows3 } from 'lucide-react'

import { Badge, Button, Checkbox, InfoDot, Tooltip } from '@/components/ui'
import { Capa, useFlotante } from '@/components/kit/flotante'
import { construirCsv, descargarCsv } from '@/lib/csv'
import type { CsvColumn } from '@/lib/csv'
import { formatoMontoEditable } from '@/lib/montos'

// ═══════════════════════════════════════════════════════════════════════════
// La tabla de las listas largas.
//
// `Table` sigue existiendo y sigue siendo la correcta para las treinta y pico
// tablas cortas que viven dentro de una ficha o de una pestaña de ajustes:
// cinco filas que ya vienen en el orden que importa no necesitan nada de esto.
//
// Esto es para las otras: las que traen cien filas de siete columnas y son el
// trabajo del día. Ahí faltaba todo lo que alguien da por supuesto al ver una
// cabecera de tabla:
//
//   · no se podía ordenar por ninguna columna, en ninguna tabla. Para saber
//     quién debe más había que leer las cien filas.
//   · la cabecera no se quedaba fija: a la fila treinta ya no sabías qué
//     columna estabas mirando.
//   · la tabla desbordaba a lo ancho y al desplazarte se iba el nombre, así
//     que te quedabas mirando cifras que no sabías de quién eran.
//   · y la consulta cortaba en cien filas sin decirlo, que es el fallo
//     peligroso de siempre: el que parece una respuesta legítima.
//
// El orden se hace en cliente a propósito. Sobre cien filas es instantáneo y
// no cuesta un viaje al servidor; el día que la lista crezca de verdad, lo que
// hará falta no es ordenar en el servidor sino paginar, y eso cambia la forma
// de los datos, no la de esta tabla.
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Qué clase de dato lleva la columna. No es decoración: decide la alineación
 * y las cifras tabulares, que antes iban a mano celda a celda y bastaba con
 * que una se olvidara para descuadrar la columna entera.
 */
export type ColumnType = 'text' | 'number'

export type Column<T> = {
  /** Identifica la columna para ordenar y para ocultarla. */
  key: string
  header: string
  /**
   * El contenido de la celda. `filasVisibles` es lo mismo que recibe
   * `onRowClick`: un enlace de la celda que abre la ficha en modo cola lo
   * necesita para apuntar la cola en el orden que se ve.
   */
  cell: (row: T, filasVisibles: T[]) => ReactNode
  /**
   * Por qué valor se ordena. Sin esto la columna no se puede ordenar, que es
   * lo correcto para una columna que no tiene un orden que signifique algo.
   *
   * `null` es "este dato no existe en esta fila" y se va siempre al final,
   * suba o baje el orden: una fila sin deuda no es la que menos debe, es otra
   * cosa.
   */
  sort?: (row: T) => string | number | null
  type?: ColumnType
  /**
   * Hacia dónde ordena el PRIMER clic. Por defecto ascendente.
   *
   * En una fecha o en un importe, el extremo que se busca es casi siempre el
   * alto: quién debe más, quién se registró ayer. Empezar por el bajo obliga a
   * pulsar dos veces siempre y a mirar una primera pantalla de ceros y de
   * fechas de hace un año. Los textos se quedan en ascendente, que ahí la A
   * sí es por donde se empieza.
   */
  sortDir?: 'asc' | 'desc'
  /**
   * La columna ancla: se queda pegada a la izquierda al desplazarse en
   * horizontal y no se puede ocultar, porque sin ella las cifras de la derecha
   * no son de nadie.
   *
   * Tiene que ser la PRIMERA de la lista y solo puede haber una: se pega con
   * `left: 0`, así que una columna ancla en mitad de la tabla se montaría
   * encima de las que tiene delante.
   */
  identity?: boolean
  /**
   * Oculta al abrir. Sigue en el menú de columnas para quien la quiera.
   *
   * La lista es para encontrar a alguien, no para saberlo todo de él: siete
   * columnas de dos líneas cada una son la mitad de filas en pantalla. Lo que
   * se consulta de vez en cuando —el nivel, el último consumo— empieza
   * escondido y la ficha lo tiene entero.
   */
  hidden?: boolean
  /**
   * No sale en el menú de columnas: siempre a la vista.
   *
   * Es para las columnas que dan sentido a otra. Un total con la comisión de
   * Ronda dentro solo se enseña al lado de sus sumandos; si el consumo se
   * pudiera ocultar, el total se quedaría solo, que es justo lo que no se
   * hace.
   */
  fija?: boolean
  /**
   * La regla de esta columna, en una frase, colgada de su cabecera.
   *
   * Es lo que sustituye a los bloques de «Cómo se lee» del pie: un párrafo
   * que explica cuatro columnas se lee una vez y estorba las otras
   * doscientas, y además está lejos de la columna que explica. Aquí la regla
   * vive pegada al rótulo del dato al que se refiere, y solo aparece cuando
   * alguien la pide.
   */
  info?: string
  /**
   * El valor de esta columna en el CSV de «Exportar CSV». Sin esto, la
   * columna no sale en el archivo (los botones de acción, por ejemplo).
   *
   * Un número sale con coma decimal y sin separador de miles, que es lo que
   * Excel en es-VE sabe sumar; para fijar los decimales de un monto, devuelve
   * ya el texto con `csvDinero` (lib/csv.ts). `null` es una celda vacía, que
   * no es un cero.
   */
  csv?: (row: T) => string | number | null
}

/**
 * Si la columna sale en el menú de columnas.
 *
 * Una columna sin rótulo —la de los botones de acción— salía como una casilla
 * sin nombre, y al desmarcarla desaparecían los botones sin saber por qué. No
 * se puede ocultar, igual que la de identidad y las `fija`.
 */
function esOcultable<T>(columna: Column<T>): boolean {
  return !columna.identity && !columna.fija && columna.header.trim() !== ''
}

/**
 * Si el clic o la tecla vienen de un control DENTRO de la fila —un enlace, un
 * botón, una casilla—. Esos hacen lo suyo y no abren la ficha, aunque la
 * celda se olvide de parar la propagación.
 */
const CONTROLES =
  'a, button, input, select, textarea, label, summary, [role="button"], [role="link"], [contenteditable="true"]'

function vieneDeUnControl(target: EventTarget, fila: HTMLElement): boolean {
  if (!(target instanceof Element)) return false
  const control = target.closest(CONTROLES)
  return control !== null && control !== fila && fila.contains(control)
}

/** Un número para Excel en es-VE: coma decimal y sin miles. */
function celdaCsv(valor: string | number | null): string | null {
  if (valor === null) return null
  if (typeof valor === 'number') return formatoMontoEditable(valor) || null
  return valor
}

/**
 * El nombre que abre su ficha desde una celda: en blanco y subrayado al pasar
 * por encima. No en lima: el lima es la acción principal de la pantalla, y
 * cien nombres en lima serían cien acciones principales.
 */
export const ENLACE_EN_CELDA =
  'font-medium text-on-surface decoration-panel-muted underline-offset-2 hover:underline'

/** Por qué columna y en qué sentido va la tabla. */
export type OrdenDeTabla = { key: string; dir: 'asc' | 'desc' }
type Orden = OrdenDeTabla

/**
 * La marca de una fila con tono: una raya de 2 px en el borde izquierdo de la
 * primera celda. Nada de teñir la fila entera: diez filas ámbar seguidas
 * gritaban más que lo que había que leer en ellas, y el estado ya lo dice la
 * insignia de su columna.
 */
const MARCA_DE_TONO: Record<'warning' | 'error', string> = {
  warning: 'shadow-[inset_2px_0_0_var(--color-warning)]',
  error: 'shadow-[inset_2px_0_0_var(--color-error)]',
}

export function DataTable<T>({
  rows,
  rowKey,
  columns,
  onRowClick,
  rowTone,
  limit,
  total,
  noun,
  summary,
  exportar,
  ordenEnServidor,
  className = '',
}: {
  rows: Array<T>
  rowKey: (row: T) => string
  columns: Array<Column<T>>
  /**
   * Abre la fila. Con esto la fila se pulsa, se enfoca con Tab y se abre con
   * Enter o Espacio. Lo pulsable de dentro de una celda no la dispara.
   *
   * `filasVisibles` son las filas en el orden que ve la persona, con el
   * orden de columna que haya elegido: es lo que necesita el modo cola para
   * que «siguiente» sea la fila de debajo y no la del orden del servidor.
   */
  onRowClick?: (row: T, filasVisibles: T[]) => void
  /** Marca la fila en el borde izquierdo, para lo que hay que ver antes de leerlo. */
  rowTone?: (row: T) => 'warning' | 'error' | undefined
  /**
   * El tope que pidió la consulta. Si llegan tantas filas como el tope, la
   * tabla lo dice: puede haber más y no se están viendo.
   */
  limit?: number
  /**
   * Cuántas filas hay en total cuando la lista pagina en el servidor: el
   * recuento dice «312 personas» aunque la página traiga cincuenta. Ordenar y
   * exportar siguen siendo de la página que se ve.
   */
  total?: number
  /** Cómo se llama una fila y cómo se llaman varias: ['persona', 'personas']. */
  noun: [string, string]
  /**
   * Las cifras de lo que se está viendo, en una línea junto al recuento:
   * «28 consumos · 12 confirmados · €340,00 de principal».
   *
   * Es lo que sustituye a la fila de tarjetas grandes encima de una lista.
   * Cuatro tarjetas de cifra son para un tablero, donde la cifra ES el
   * contenido; encima de una lista filtrada eran cuatro ceros ocupando el
   * sitio de doce filas.
   */
  summary?: ReactNode
  /**
   * Pone «Exportar CSV» en la barra de la tabla. Baja las filas que se ven
   * —con el filtro y el orden de ahora— y las columnas que tienen `csv`,
   * estén a la vista o no. `archivo` va sin extensión.
   */
  exportar?: { archivo: string }
  /**
   * El orden lo hace el servidor. En una lista paginada, ordenar en el
   * navegador solo reordenaría la página que se ve: «lo más nuevo arriba»
   * serían los más nuevos DE ESTA PÁGINA. Con esto la tabla no toca el orden
   * de las filas: pinta el que le dan y avisa de cada clic, y solo se pueden
   * ordenar las columnas de `claves` (las que el servidor sabe ordenar).
   */
  ordenEnServidor?: {
    orden: OrdenDeTabla | null
    claves: ReadonlyArray<string>
    onOrden: (orden: OrdenDeTabla | null) => void
  }
  className?: string
}) {
  const [ordenLocal, setOrdenLocal] = useState<Orden | null>(null)
  const orden = ordenEnServidor ? ordenEnServidor.orden : ordenLocal
  const [apretada, setApretada] = useState(false)
  // Las que la tabla declara como ocultas empiezan ocultas; el menú de
  // columnas las devuelve cuando hacen falta.
  const [ocultas, setOcultas] = useState<Array<string>>(() =>
    columns.filter((c) => c.hidden && esOcultable(c)).map((c) => c.key),
  )

  const visibles = columns.filter((c) => !esOcultable(c) || !ocultas.includes(c.key))

  const ordenadas = useMemo(() => {
    if (ordenEnServidor || !orden) return rows
    const columna = columns.find((c) => c.key === orden.key)
    if (!columna?.sort) return rows

    const factor = orden.dir === 'asc' ? 1 : -1
    const sacar = columna.sort

    return [...rows].sort((a, b) => {
      const x = sacar(a)
      const y = sacar(b)

      // Lo que no existe no compite: va al final en los dos sentidos.
      if (x === null || x === '') return y === null || y === '' ? 0 : 1
      if (y === null || y === '') return -1

      if (typeof x === 'number' && typeof y === 'number') return (x - y) * factor
      return String(x).localeCompare(String(y), 'es') * factor
    })
  }, [rows, orden, columns, ordenEnServidor])

  function alternarOrden(key: string) {
    const primero = columns.find((c) => c.key === key)?.sortDir ?? 'asc'
    const siguiente = (previo: Orden | null): Orden | null => {
      if (previo?.key !== key) return { key, dir: primero }
      if (previo.dir === primero) return { key, dir: primero === 'asc' ? 'desc' : 'asc' }
      // Tercer clic: se quita el orden y vuelve el que trajo el servidor, que
      // en varias de estas listas ya es el que importa —lo más reciente, lo
      // más atrasado— y no habría manera de recuperarlo.
      return null
    }
    if (ordenEnServidor) ordenEnServidor.onOrden(siguiente(ordenEnServidor.orden))
    else setOrdenLocal(siguiente)
  }

  /** Si la columna se puede ordenar aquí: con orden en el servidor, solo las que él sabe. */
  function ordenable(columna: Column<T>): boolean {
    if (!columna.sort) return false
    return !ordenEnServidor || ordenEnServidor.claves.includes(columna.key)
  }

  const celda = apretada ? 'px-4 py-2' : 'px-4 py-2.5'
  const truncada = limit !== undefined && rows.length >= limit

  const columnasCsv = columns.filter((c) => c.csv !== undefined)

  function bajarCsv() {
    if (!exportar) return
    const csv: Array<CsvColumn<T>> = columnasCsv.map((c) => ({
      header: c.header.trim() || c.key,
      value: (row) => (c.csv ? celdaCsv(c.csv(row)) : null),
    }))
    descargarCsv(exportar.archivo, construirCsv(csv, ordenadas))
  }

  function alPulsarFila(event: MouseEvent<HTMLTableRowElement>, row: T) {
    if (!onRowClick || vieneDeUnControl(event.target, event.currentTarget)) return
    // Quien arrastra para copiar una referencia no quiere abrir la ficha.
    if (window.getSelection()?.toString()) return
    onRowClick(row, ordenadas)
  }

  function alTeclearFila(event: KeyboardEvent<HTMLTableRowElement>, row: T) {
    // Solo con el foco en la fila misma: un Enter en un botón de dentro es de
    // ese botón.
    if (!onRowClick || event.target !== event.currentTarget) return
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      onRowClick(row, ordenadas)
    }
  }

  return (
    <div className={className}>
      <div className="mb-2 flex flex-wrap items-center gap-3">
        <p className="type-panel-body tabular-nums text-on-surface-variant">
          <span className="text-on-surface">{(total ?? rows.length).toLocaleString('es-VE')}</span>{' '}
          {(total ?? rows.length) === 1 ? noun[0] : noun[1]}
          {summary && <> · {summary}</>}
        </p>

        {/* El tope de la consulta, dicho. Antes se cortaba en cien filas sin
            avisar y el operador creía que estaba viendo el padrón entero. */}
        {truncada && (
          <Badge tone="warning" icono>
            Solo las primeras {limit} · afina la búsqueda para ver el resto
          </Badge>
        )}

        <div className="ml-auto flex items-center gap-1">
          {exportar && columnasCsv.length > 0 && (
            <Button size="sm" variant="text" onClick={bajarCsv} disabled={ordenadas.length === 0}>
              <Download size={15} aria-hidden />
              Exportar CSV
            </Button>
          )}

          <BotonHerramienta
            label={apretada ? 'Filas cómodas' : 'Filas apretadas'}
            activo={apretada}
            onClick={() => setApretada((v) => !v)}
          >
            <Rows3 size={15} aria-hidden />
          </BotonHerramienta>

          <MenuColumnas
            columns={columns}
            ocultas={ocultas}
            onAlternar={(key) =>
              setOcultas((previas) =>
                previas.includes(key)
                  ? previas.filter((k) => k !== key)
                  : [...previas, key],
              )
            }
          />
        </div>
      </div>

      {/*
        La tabla desplaza dentro de su propia caja, en los dos ejes.

        No es un capricho: una cabecera pegajosa se pega al contenedor que
        desplaza, y en cuanto hay uno entre ella y la ventana deja de pegarse a
        la ventana. Y hace falta uno, porque siete columnas de contenido no
        caben aunque el contenido tenga tope de ancho. Con la caja acotada las
        dos cosas salen solas: la cabecera se pega a su borde de arriba y la
        columna de identidad al de la izquierda.

        (El apaño de overflow-y:clip para conservar el scroll de la página no
        sirve: junto a un overflow-x:auto, `clip` computa a `hidden` y vuelve a
        crear contenedor de desplazamiento.)
      */}
      <div className="overflow-auto rounded-panel-card border border-panel-hairline bg-panel-card [max-height:var(--panel-table-max-h)]">
        {/*
          border-separate y no collapse: con las celdas colapsadas el borde
          pertenece a la rejilla y no a la celda, así que la cabecera pegajosa
          se desplaza dejando su propia línea atrás.
        */}
        <table className="w-full min-w-max border-separate border-spacing-0">
          <thead>
            <tr>
              {visibles.map((columna) => (
                <th
                  key={columna.key}
                  scope="col"
                  aria-sort={
                    orden?.key === columna.key
                      ? orden.dir === 'asc'
                        ? 'ascending'
                        : 'descending'
                      : ordenable(columna)
                        ? 'none'
                        : undefined
                  }
                  // Se pega al borde de arriba de SU caja, no al de la ventana.
                  // La de identidad se pega además a la izquierda, así que en
                  // la esquina se cruzan las dos y necesita ir por encima.
                  className={`sticky top-0 border-b border-panel-hairline bg-panel-card ${celda} ${
                    columna.type === 'number' ? 'text-right' : 'text-left'
                  } ${columna.identity ? 'left-0 z-30' : 'z-20'}`}
                >
                  <Cabecera
                    columna={columna}
                    ordenable={ordenable(columna)}
                    orden={orden}
                    onOrdenar={() => alternarOrden(columna.key)}
                  />
                </th>
              ))}
            </tr>
          </thead>

          <tbody>
            {ordenadas.map((row) => {
              const tono = rowTone?.(row)

              return (
                <tr
                  key={rowKey(row)}
                  // Con Tab se llega a la fila y con Enter se abre, como con
                  // el ratón. El foco se marca en las celdas, igual que el
                  // hover, más la barra lima de «estás aquí» en la primera.
                  tabIndex={onRowClick ? 0 : undefined}
                  onClick={onRowClick ? (event) => alPulsarFila(event, row) : undefined}
                  onKeyDown={onRowClick ? (event) => alTeclearFila(event, row) : undefined}
                  className={`group/fila ${onRowClick ? 'cursor-pointer outline-none' : ''}`}
                >
                  {visibles.map((columna, i) => (
                    <td
                      key={columna.key}
                      // El borde y el fondo van en la celda y no en la fila:
                      // con border-separate una <tr> no dibuja bordes, y la
                      // celda pegada necesita fondo opaco propio —una sticky
                      // transparente deja ver pasar las columnas de al lado—.
                      // La marca de tono va en la primera; el foco, que
                      // se pinta después, la tapa mientras dura.
                      className={`border-b border-panel-hairline bg-panel-card align-middle type-panel-body text-on-surface group-last/fila:border-b-0 ${celda} ${
                        i === 0 && tono ? MARCA_DE_TONO[tono] : ''
                      } ${
                        onRowClick
                          ? 'transition-colors duration-[var(--transition-fast)] group-hover/fila:bg-panel-raised group-focus-visible/fila:bg-panel-raised'
                          : ''
                      } ${
                        onRowClick && i === 0
                          ? 'group-focus-visible/fila:shadow-[inset_2px_0_0_var(--color-primary)]'
                          : ''
                      } ${columna.type === 'number' ? 'text-right tabular-nums' : ''} ${
                        columna.identity ? 'sticky left-0 z-10' : ''
                      }`}
                    >
                      {columna.cell(row, ordenadas)}
                    </td>
                  ))}
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}

/** El contenido de una cabecera: un botón si se puede ordenar, texto si no. */
function Cabecera<T>({
  columna,
  ordenable,
  orden,
  onOrdenar,
}: {
  columna: Column<T>
  ordenable: boolean
  orden: Orden | null
  onOrdenar: () => void
}) {
  // La regla de la columna va pegada a su rótulo, y en el lado por el que se
  // lee la columna: a la derecha del texto, salvo en las de cifras, que se
  // leen de derecha a izquierda porque van alineadas a la derecha.
  const regla = columna.info ? (
    <InfoDot title={columna.header} what={columna.info} />
  ) : null

  // A 12 y 600, en minúscula de frase y en el gris de tercer nivel: la
  // cabecera rotula la columna sin competir con las filas que se leen.
  if (!ordenable) {
    return (
      <span
        className={`inline-flex items-center gap-1 type-panel-caption font-semibold text-panel-muted ${
          columna.type === 'number' ? 'flex-row-reverse' : ''
        }`}
      >
        {columna.header}
        {regla}
      </span>
    )
  }

  const activa = orden?.key === columna.key

  return (
    <span
      className={`inline-flex items-center gap-1 ${
        columna.type === 'number' ? 'flex-row-reverse' : ''
      }`}
    >
      <button
        type="button"
        onClick={onOrdenar}
        className={`group/orden inline-flex items-center gap-1 type-panel-caption font-semibold transition-colors duration-[var(--transition-fast)] ${
          columna.type === 'number' ? 'flex-row-reverse' : ''
        } ${activa ? 'text-on-surface' : 'text-panel-muted hover:text-on-surface'}`}
      >
        {columna.header}
        {/* La flecha doble solo aparece al pasar por encima: siete columnas con
            un icono permanente cada una son siete puntos de ruido en la fila que
            más se mira. Con el dedo no hay "por encima" que valga, así que ahí
            se queda puesta y a media tinta: la mitad del ruido a cambio de que
            se sepa que la columna se puede ordenar. */}
        {activa ? (
          orden.dir === 'asc' ? (
            <ArrowUp size={12} aria-hidden />
          ) : (
            <ArrowDown size={12} aria-hidden />
          )
        ) : (
          <ChevronsUpDown
            size={12}
            aria-hidden
            className="opacity-0 transition-opacity group-hover/orden:opacity-100 group-focus-visible/orden:opacity-100 pointer-coarse:opacity-50"
          />
        )}
      </button>
      {regla}
    </span>
  )
}

/** El cuadrado de una herramienta de la barra: encendido mientras está puesta o abierta. */
function claseHerramienta(activo: boolean): string {
  return `inline-flex size-panel-control-sm items-center justify-center rounded-panel-control transition-colors duration-[var(--transition-fast)] ${
    activo
      ? 'bg-panel-control text-on-surface'
      : 'text-on-surface-variant hover:bg-panel-raised hover:text-on-surface'
  }`
}

/** Un botón de icono de la barra de la tabla, con su nombre en un globo. */
function BotonHerramienta({
  children,
  label,
  activo = false,
  onClick,
}: {
  children: ReactNode
  label: string
  activo?: boolean
  onClick?: () => void
}) {
  return (
    <Tooltip contenido={label}>
      <button
        type="button"
        onClick={onClick}
        aria-label={label}
        aria-pressed={activo}
        className={claseHerramienta(activo)}
      >
        {children}
      </button>
    </Tooltip>
  )
}

/**
 * Qué columnas se ven.
 *
 * Siete columnas fijas para todo el mundo era el problema: quien concilia
 * quiere referencias y montos, y quien hace cobranza quiere teléfonos y días
 * de atraso. La de identidad no aparece en la lista porque no se puede quitar
 * —sin ella la fila no es de nadie—, y tampoco las que no tienen rótulo (ver
 * `esOcultable`).
 *
 * No es el `Menu` del kit: un menú se cierra al elegir, y aquí se marcan y
 * desmarcan varias casillas seguidas. Usa la misma maquinaria de lo que flota
 * —portal, volteo, Escape y clic fuera—, y dentro las casillas se recorren
 * con Tab.
 */
function MenuColumnas<T>({
  columns,
  ocultas,
  onAlternar,
}: {
  columns: Array<Column<T>>
  ocultas: Array<string>
  onAlternar: (key: string) => void
}) {
  const [abierto, setAbierto] = useState(false)
  const id = useId()
  const opcionales = columns.filter(esOcultable)

  const flotante = useFlotante<HTMLButtonElement>({
    abierto,
    lado: 'abajo',
    alineacion: 'fin',
    separacion: 6,
    alCerrar: () => setAbierto(false),
  })

  // Al abrir, el foco entra en la primera casilla.
  useEffect(() => {
    if (!abierto) return
    flotante.capaRef.current?.querySelector<HTMLElement>('input')?.focus({ preventScroll: true })
  }, [abierto, flotante.capaRef])

  // La capa va en un portal al final de la página: salir de ella con Tab la
  // cierra y el foco sigue desde el botón, como si estuviera justo detrás.
  function alTeclear(evento: KeyboardEvent<HTMLDivElement>) {
    if (evento.key !== 'Tab') return
    const casillas = Array.from(evento.currentTarget.querySelectorAll<HTMLElement>('input'))
    const activo = document.activeElement
    const haciaAtras = evento.shiftKey && activo === casillas.at(0)
    const haciaDelante = !evento.shiftKey && activo === casillas.at(-1)
    if (!haciaAtras && !haciaDelante) return
    if (haciaAtras) evento.preventDefault()
    flotante.anclaRef.current?.focus()
    setAbierto(false)
  }

  return (
    <>
      <Tooltip contenido="Qué columnas se ven">
        <button
          ref={flotante.anclaRef}
          type="button"
          aria-label="Qué columnas se ven"
          aria-haspopup="dialog"
          aria-expanded={abierto}
          aria-controls={abierto ? id : undefined}
          onClick={(evento) => {
            evento.stopPropagation()
            setAbierto((v) => !v)
          }}
          className={claseHerramienta(abierto)}
        >
          <Columns3 size={15} aria-hidden />
        </button>
      </Tooltip>

      <Capa
        flotante={flotante}
        abierto={abierto}
        id={id}
        role="dialog"
        aria-label="Qué columnas se ven"
        onKeyDown={alTeclear}
        className="anim-globo flex max-h-96 w-64 flex-col overflow-y-auto rounded-panel-card border border-panel-hairline-strong bg-panel-control p-1.5 shadow-2xl"
      >
        <p className="px-2.5 pb-1 pt-1.5 type-panel-caption font-semibold text-on-surface-variant">
          Columnas a la vista
        </p>
        {opcionales.map((columna) => (
          <div
            key={columna.key}
            className="rounded-panel-control px-2.5 py-2 transition-colors duration-[var(--transition-fast)] hover:bg-shell-inset"
          >
            <Checkbox
              id={`${id}-${columna.key}`}
              label={columna.header}
              checked={!ocultas.includes(columna.key)}
              onChange={() => onAlternar(columna.key)}
            />
          </div>
        ))}
      </Capa>
    </>
  )
}
