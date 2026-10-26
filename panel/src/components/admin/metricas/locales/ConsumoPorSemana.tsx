import { Link } from '@tanstack/react-router'

import { ChartCard, SERIE } from '@/components/charts'
import { columnaBajo } from '@/components/charts/geometria'
import { Globo, lecturaDelPunto, useSenalado } from '@/components/charts/lectura'
import type { FilaDelGlobo } from '@/components/charts/lectura'
import { Table, Td, Tr, formatUsd, formatUsdShort } from '@/components/ui'
import { busquedaConLocal } from '@/features/admin/metricas/locales/consultas'
import { pequenosMultiplos, textoDeCima } from '@/features/admin/metricas/locales/multiples'
import type { BarraDeMultiplo, FilaDeMultiplo } from '@/features/admin/metricas/locales/multiples'
import { semanaCorta } from '@/features/admin/metricas/locales/semanas'
import type { LocalesDeLaSemana } from '@/features/admin/metricas/locales/tipos'

/**
 * «Consumo por semana»: un gráfico pequeño por local, las ocho últimas
 * semanas, todos con LA MISMA escala. Así la altura de una barra se compara
 * con la de otro local sin leer los números: un local que vende la mitad
 * tiene barras de la mitad.
 *
 * La semana elegida va en el tono del área y las anteriores en gris; un cero
 * deja una marca en la base. La barra más alta va escrita arriba y la tabla
 * entera, a un clic en la cabecera. Cada fila es un gráfico pequeño que se
 * lee como los del kit: el globo al pasar el ratón, las flechas con el
 * teclado.
 */
export function ConsumoPorSemana({ d }: { d: LocalesDeLaSemana }) {
  const m = pequenosMultiplos(d)
  const cima = textoDeCima(m.cima)

  return (
    <ChartCard
      titulo="Financiado por semana y clínica (sin comisión)"
      info="Sin la Comisión Helios: el financiado de cada clínica en las ocho últimas semanas. Todas las clínicas comparten la escala, así que las alturas se comparan entre sí. Si la semana elegida está en curso, su barra va a medias y la nota la compara con la anterior a la misma altura."
      resumen={
        m.filas.length > 0
          ? `Misma escala para todos, de $0 a ${formatUsdShort(m.escala.tope)}, ${m.rango}.`
          : undefined
      }
      tabla={m.filas.length > 0 ? <TablaDeMultiplos semanas={m.semanas} filas={m.filas} /> : undefined}
    >
      {m.filas.length === 0 ? (
        <p className="type-panel-body text-panel-muted">Ninguna clínica se financió en estas ocho semanas.</p>
      ) : (
        <div className="flex flex-col gap-4">
          {cima && <p className="type-panel-caption text-on-surface-variant">La barra más alta: {cima}</p>}
          <ul className="flex flex-col gap-4">
            {m.filas.map((f) => (
              <FilaDeMultiplos key={f.merchantId} f={f} d={d} />
            ))}
          </ul>
        </div>
      )}
    </ChartCard>
  )
}

/** Lo que dice el globo de una barra: su facturado, sus consumos y sus usuarios. */
function filasDeLaBarra(b: BarraDeMultiplo): FilaDelGlobo[] {
  return [
    {
      key: 'consumo',
      rotulo: 'financiado, sin comisión',
      valor: formatUsd(b.valor),
      color: b.valor > 0 && b.destacada ? SERIE.principal : SERIE.tenue,
      forma: 'punto',
    },
    { key: 'consumos', rotulo: b.consumos === 1 ? 'financiamiento' : 'financiamientos', valor: String(b.consumos), color: 'transparent' },
    { key: 'personas', rotulo: b.personas === 1 ? 'paciente' : 'pacientes', valor: String(b.personas), color: 'transparent' },
  ]
}

function FilaDeMultiplos({ f, d }: { f: FilaDeMultiplo; d: LocalesDeLaSemana }) {
  const lectura = f.barras.map((b) => `${semanaCorta(b.semana)}: ${formatUsd(b.valor)}`).join(', ')
  const n = f.barras.length
  const { punto, senalar, lienzo } = useSenalado(n, columnaBajo)
  const activa = punto === null ? null : (f.barras[punto] ?? null)
  const titulo = (b: BarraDeMultiplo) => `${f.nombre} · ${semanaCorta(b.semana)}${b.destacada && d.semana.enCurso ? ' (a medias)' : ''}`

  return (
    // En el teléfono, el nombre y el importe arriba y las barras debajo, de
    // lado a lado: en una fila, las dos columnas fijas dejaban 30 px al gráfico.
    <li className="grid grid-cols-[minmax(0,1fr)_auto] items-end gap-x-4 gap-y-1.5 sm:grid-cols-[minmax(0,8rem)_minmax(0,1fr)_minmax(0,7rem)] sm:gap-4">
      <Link
        to="/admin/metricas"
        search={busquedaConLocal({ semana: d.semana.desde, enCurso: d.semana.enCurso, local: f.merchantId })}
        className="truncate pb-0.5 type-panel-label text-on-surface decoration-panel-muted underline-offset-2 hover:underline"
      >
        {f.nombre}
      </Link>

      <div
        role="img"
        aria-label={`Financiado por semana de ${f.nombre}, sin comisión. Las flechas recorren las semanas. ${lectura}`}
        {...lienzo}
        // Al entrar con el tabulador, el globo sale ya en la semana elegida.
        onFocus={() => {
          if (punto === null) senalar(n - 1)
        }}
        className="relative flex h-16 touch-pan-y items-end gap-1.5 rounded-t-extra-small border-b border-panel-hairline-strong max-sm:col-span-2 max-sm:row-start-2"
      >
        {f.barras.map((b, i) => (
          <span
            key={b.semana}
            aria-hidden
            className="min-w-0 flex-1 rounded-t-[3px] transition-opacity duration-[var(--transition-fast)]"
            style={{
              // Un cero deja su marca en la base; lo demás, al menos 3 px
              // para que un consumo pequeño no se confunda con ninguno.
              height: b.valor > 0 ? `max(3px, ${(b.fraccion * 100).toFixed(2)}%)` : '2px',
              backgroundColor: b.valor > 0 && b.destacada ? SERIE.principal : SERIE.tenue,
              opacity: punto === null || punto === i ? 1 : 0.5,
            }}
          />
        ))}
        {activa && punto !== null && (
          <Globo x={((punto + 0.5) / n) * 100} titulo={titulo(activa)} filas={filasDeLaBarra(activa)} />
        )}
      </div>
      {/* Fuera del lienzo: lo de dentro de un role="img" no se lee. */}
      <span aria-live="polite" className="sr-only">
        {activa ? lecturaDelPunto(titulo(activa), filasDeLaBarra(activa)) : ''}
      </span>

      <div className="flex min-w-0 flex-col items-end gap-0.5">
        <span className="type-panel-label tabular-nums text-on-surface">{formatUsd(f.ultimo)}</span>
        {f.nota && <span className="truncate type-panel-caption text-on-surface-variant">{f.nota}</span>}
      </div>
    </li>
  )
}

function TablaDeMultiplos({ semanas, filas }: { semanas: ReadonlyArray<string>; filas: ReadonlyArray<FilaDeMultiplo> }) {
  return (
    <Table headers={['Clínica', ...semanas.map(semanaCorta)]}>
      {filas.map((f) => (
        <Tr key={f.merchantId}>
          <Td>{f.nombre}</Td>
          {f.barras.map((b) => (
            <Td key={b.semana} className="text-right tabular-nums">
              {formatUsd(b.valor)}
            </Td>
          ))}
        </Tr>
      ))}
    </Table>
  )
}
