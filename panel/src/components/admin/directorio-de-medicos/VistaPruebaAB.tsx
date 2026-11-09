import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { FlaskConical } from 'lucide-react'

import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'
import { BarChart, LineChart } from '@/components/charts'
import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import {
  Badge,
  Callout,
  EmptyState,
  Filtro,
  Segmented,
  SkeletonStats,
  SkeletonTable,
  Table,
  Td,
  Tr,
  diaOperativo,
  formatDay,
  formatDayShort,
  formatMoneda,
  formatPct,
} from '@/components/ui'
import { consultaPruebaAB } from '@/features/admin/directorioDeMedicos/api'
import {
  CONFIANZA_NECESARIA,
  MINIMO_DE_VISITANTES,
  RANGOS_DE_LA_PRUEBA,
  rangoDeLaPrueba,
  resumenDeMedicos,
  tasaDeClic,
  veredictoAB,
} from '@/features/admin/directorioDeMedicos/pruebaAB'
import type {
  CifrasDeVariante,
  MedicoDeLaPrueba,
  PruebaAB,
  RangoDeLaPrueba,
  Variante,
  VeredictoAB,
} from '@/features/admin/directorioDeMedicos/pruebaAB'

const OPCIONES_RANGO = RANGOS_DE_LA_PRUEBA.map((d) => ({ value: String(d), label: `${d} días` }))

const LETRA: Record<Variante, string> = { a: 'A', b: 'B' }
const QUE_ES: Record<Variante, string> = {
  a: 'Sin inicial; el botón de WhatsApp va directo al médico.',
  b: 'Inicial de $15 (solo en el texto) y consultas de hasta $60; el botón va al WhatsApp de Helios con el código del médico.',
}

const cuenta = (n: number) => String(Math.round(n))
const tasa = (t: number | null) => (t === null ? '—' : formatPct(t * 100, 1))
/** La confianza hacia abajo: un 94,8 % no se escribe «95 %», que es el listón. */
const confianza = (c: number) => formatPct(Math.floor(c * 100), 0)
const masQue = (d: number) => formatPct(d * 100, 0)

/**
 * Superadmin › Directorio de médicos › Prueba A/B (docs/06): A, `/directorio`
 * (sin inicial, el botón va directo al médico), contra B, `/consultas`
 * (inicial de $15, el botón va al WhatsApp de Helios).
 *
 * Arriba el rango (7, 14, 30 o 90 días de Caracas, hoy incluido) y el
 * veredicto: una prueba z de dos proporciones sobre la tasa de clic
 * (visitantes que tocaron un botón / visitantes), que no da ganadora con
 * menos de 100 visitantes por variante ni con menos de 95 % de confianza.
 * Debajo, las dos variantes lado a lado, la serie diaria y la tabla por
 * médico. Solo cuenta el tráfico público: lo del equipo y las clínicas se
 * dice aparte. Los datos salen de `admin_directorio_ab`.
 *
 * La usan Pro (`?vista=ab`) y Lite (la pestaña «Prueba A/B», con el vestido
 * de Lite): el rango va en la dirección (`?dias=`) y lo cambia quien la monta.
 */
export function VistaPruebaAB({
  dias,
  onDias,
}: {
  dias: RangoDeLaPrueba
  onDias: (dias: RangoDeLaPrueba) => void
}) {
  const rango = rangoDeLaPrueba(dias, diaOperativo())
  const consulta = useQuery(consultaPruebaAB(rango))
  const p = consulta.data

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-end gap-x-5 gap-y-2">
        <Filtro label="Rango">
          <Segmented
            options={OPCIONES_RANGO}
            value={String(dias)}
            onChange={(v) => {
              const d = RANGOS_DE_LA_PRUEBA.find((r) => String(r) === v)
              if (d) onDias(d)
            }}
          />
        </Filtro>
        <p className="type-panel-caption text-on-surface-variant">
          Del {formatDayShort(rango.desde)} al {formatDayShort(rango.hasta)}, días de Caracas
          {consulta.isFetching && !consulta.isPending ? ' · actualizando…' : ''}
        </p>
      </div>

      {consulta.isPending && (
        <>
          <SkeletonStats />
          <SkeletonTable rows={7} columns={3} />
        </>
      )}

      {consulta.isError && !p && (
        <SeccionSinLeer
          titulo="No se pudo leer la prueba A/B"
          error={consulta.error}
          onReintentar={() => void consulta.refetch()}
        />
      )}

      {p && <Resultados prueba={p} />}
    </div>
  )
}

function Resultados({ prueba: p }: { prueba: PruebaAB }) {
  const v = veredictoAB(p.a, p.b)
  const medicos = useMemo(() => columnasPorMedico(), [])
  const resumen = resumenDeMedicos(p.medicos)
  const antesDeLasVisitas = p.visitasDesde !== null && p.desde !== '' && p.visitasDesde > p.desde

  return (
    <>
      <Veredicto veredicto={v} prueba={p} />

      <Comparacion a={p.a} b={p.b} />

      {p.visitasDesde === null ? (
        <Callout tone="info" titulo="Todavía no hay visitas apuntadas">
          Las visitas se cuentan desde que se publicó la prueba. Hasta que lleguen, la tasa de clic no se puede calcular.
        </Callout>
      ) : antesDeLasVisitas ? (
        <Callout tone="warning" titulo={`Las visitas se cuentan desde el ${formatDay(p.visitasDesde)}`}>
          Antes de ese día solo se apuntaban los clics: esos clics salen en «Clics» pero no en la tasa de clic, que solo
          cuenta a quien visitó la página. Para comparar bien, elige un rango que empiece después.
        </Callout>
      ) : null}

      <p className="type-panel-caption text-on-surface-variant">
        Solo cuenta el tráfico público. No entran {p.excluidos.visitasEquipo}{' '}
        {p.excluidos.visitasEquipo === 1 ? 'visita' : 'visitas'} ni {p.excluidos.clicsEquipo}{' '}
        {p.excluidos.clicsEquipo === 1 ? 'clic' : 'clics'} del equipo y del personal de las clínicas en este rango.
        {p.visitasDesde !== null && !antesDeLasVisitas && <> Visitas contadas desde el {formatDay(p.visitasDesde)}.</>}
      </p>

      <LineChart
        title="Tasa de clic por día"
        summary={
          <>
            A {tasa(v.tasaA)} · B {tasa(v.tasaB)} en todo el rango
          </>
        }
        series={[
          { key: 'a', label: 'A · /directorio' },
          { key: 'b', label: 'B · /consultas' },
        ]}
        principal={1}
        points={p.dias.map((d) => {
          const ta = tasaDeClic(d.a)
          const tb = tasaDeClic(d.b)
          return {
            key: d.dia,
            label: formatDayShort(d.dia),
            values: [ta === null ? null : ta * 100, tb === null ? null : tb * 100],
            note: `A: ${d.a.visitantes} · B: ${d.b.visitantes}`,
          }
        })}
        format={(n) => formatPct(n, 1)}
        formatShort={(n) => formatPct(n, 0)}
        ejeLabel="Día"
        unidadLabel="Visitantes"
        footnote="Visitantes que tocaron un botón de WhatsApp entre los visitantes del día, en cada variante. Un día sin visitantes es un hueco, no un cero. Con pocos visitantes al día la línea salta mucho: el veredicto mira el rango entero."
        empty="Todavía no hay visitantes en este rango."
      />

      <BarChart
        title="Visitantes por día"
        summary={
          <>
            A {p.a.visitantes} · B {p.b.visitantes} en todo el rango
          </>
        }
        enteros
        series={[
          { key: 'a', label: 'A · /directorio' },
          { key: 'b', label: 'B · /consultas' },
        ]}
        points={p.dias.map((d) => ({
          key: d.dia,
          label: formatDayShort(d.dia),
          values: [d.a.visitantes, d.b.visitantes],
          note: `${d.a.clics + d.b.clics} ${d.a.clics + d.b.clics === 1 ? 'clic' : 'clics'}`,
        }))}
        format={cuenta}
        formatShort={cuenta}
        ejeLabel="Día"
        unidadLabel="Clics"
        footnote="Navegadores distintos que abrieron cada página ese día. La barra ancha es A; la de dentro, B."
        empty="Todavía no hay visitantes en este rango."
      />

      {p.medicos.length === 0 ? (
        <EmptyState
          icon={<FlaskConical size={40} />}
          title="Ningún médico entra en B ni tiene clics en este rango"
          description="En B salen los médicos publicados con una consulta de más de $15 y hasta $60 (o su equivalente en euros)."
        />
      ) : (
        <DataTable
          rows={p.medicos}
          rowKey={(m) => m.merchantId}
          columns={medicos}
          noun={['médico', 'médicos']}
          summary={
            <>
              {resumen.enB} {resumen.enB === 1 ? 'entra' : 'entran'} hoy en B · {resumen.clicsA} clics en A y{' '}
              {resumen.clicsB} en B
            </>
          }
          exportar={{ archivo: 'directorio-prueba-ab' }}
        />
      )}
    </>
  )
}

/** Quién gana y con qué confianza, o por qué todavía no se puede decir. */
function Veredicto({ veredicto: v, prueba: p }: { veredicto: VeredictoAB; prueba: PruebaAB }) {
  const tasas = `A ${tasa(v.tasaA)} · B ${tasa(v.tasaB)}`
  const liston = formatPct(CONFIANZA_NECESARIA * 100, 0)

  if (v.estado === 'gana' && v.ganadora) {
    const g = v.ganadora
    const otra: Variante = g === 'a' ? 'b' : 'a'
    return (
      <Callout tone="success" titulo={`Gana ${LETRA[g]} (${p[g].ruta}), con ${confianza(v.confianza ?? 0)} de confianza`}>
        Su tasa de clic es {tasa(g === 'a' ? v.tasaA : v.tasaB)} frente a {tasa(g === 'a' ? v.tasaB : v.tasaA)} de{' '}
        {LETRA[otra]}
        {v.diferencia !== null ? `: un ${masQue(v.diferencia)} más de visitantes que tocan un botón.` : '.'}
      </Callout>
    )
  }

  const quienVa =
    v.delante === null
      ? 'van igual'
      : `${LETRA[v.delante]} va delante${v.diferencia !== null ? ` por un ${masQue(v.diferencia)}` : ''}`

  if (v.estado === 'pocos_datos') {
    return (
      <Callout tone="info" titulo="Aún no hay una diferencia clara: faltan visitantes">
        Hacen falta al menos {MINIMO_DE_VISITANTES} visitantes en cada variante; van {p.a.visitantes} en A y{' '}
        {p.b.visitantes} en B.
        {v.tasaA !== null && v.tasaB !== null && <> Por ahora, {tasas} ({quienVa}), sin confianza todavía.</>}
      </Callout>
    )
  }

  return (
    <Callout tone="info" titulo="Aún no hay una diferencia clara">
      {tasas}.{' '}
      {v.delante === null
        ? 'Las dos van igual.'
        : `${quienVa}, pero la confianza es de ${confianza(v.confianza ?? 0)} y hacen falta ${liston}.`}
    </Callout>
  )
}

/** Las dos variantes lado a lado, cifra por cifra. */
function Comparacion({ a, b }: { a: CifrasDeVariante; b: CifrasDeVariante }) {
  const filas: Array<{ rotulo: string; a: string; b: string; fuerte?: boolean }> = [
    { rotulo: 'Visitantes', a: cuenta(a.visitantes), b: cuenta(b.visitantes) },
    { rotulo: 'Visitas', a: cuenta(a.visitas), b: cuenta(b.visitas) },
    { rotulo: 'Clics al WhatsApp', a: cuenta(a.clics), b: cuenta(b.clics) },
    { rotulo: 'Visitantes que tocaron', a: cuenta(a.visitantesConClic), b: cuenta(b.visitantesConClic) },
    { rotulo: 'Tasa de clic', a: tasa(tasaDeClic(a)), b: tasa(tasaDeClic(b)), fuerte: true },
    // En A el botón va directo al médico: no hay interesados que contar.
    { rotulo: 'Interesados', a: '—', b: cuenta(b.interesados) },
    { rotulo: 'Pacientes', a: '—', b: cuenta(b.convertidos) },
  ]
  return (
    <div className="flex flex-col gap-2">
      <Table
        headers={[
          'Cifra',
          { label: `A · ${a.ruta}`, info: QUE_ES.a },
          { label: `B · ${b.ruta}`, info: QUE_ES.b },
        ]}
      >
        {filas.map((f) => (
          <Tr key={f.rotulo}>
            <Td className={f.fuerte ? 'font-semibold' : 'text-on-surface-variant'}>{f.rotulo}</Td>
            <Td className={`tabular-nums ${f.fuerte ? 'font-semibold' : ''}`}>{f.a}</Td>
            <Td className={`tabular-nums ${f.fuerte ? 'font-semibold' : ''}`}>{f.b}</Td>
          </Tr>
        ))}
      </Table>
      <p className="type-panel-caption text-on-surface-variant">
        Visitantes: navegadores distintos. Tasa de clic: visitantes que tocaron un botón de WhatsApp entre los visitantes.
        Interesados y pacientes solo existen en B: en A el botón va directo al WhatsApp del médico, sin pasar por el de
        Helios, así que no se pueden contar (—, no cero).
      </p>
    </div>
  )
}

function columnasPorMedico(): Array<Column<MedicoDeLaPrueba>> {
  const numero = (key: string, header: string, valor: (m: MedicoDeLaPrueba) => number, info?: string): Column<MedicoDeLaPrueba> => ({
    key,
    header,
    info,
    type: 'number',
    sort: valor,
    sortDir: 'desc',
    csv: valor,
    cell: (m) => <span className="tabular-nums text-on-surface">{valor(m)}</span>,
  })
  return [
    {
      key: 'medico',
      header: 'Médico',
      identity: true,
      sort: (m) => m.medico,
      csv: (m) => m.medico,
      cell: (m) => (
        <span className="flex flex-col">
          <span className="font-medium text-on-surface">{m.medico}</span>
          <span className="type-panel-caption text-on-surface-variant">
            {m.precio === null ? 'Sin precio' : `Consulta ${formatMoneda(m.precio, m.moneda)}`}
          </span>
        </span>
      ),
    },
    numero('clicsA', 'Clics A', (m) => m.clicsA),
    numero('clicsB', 'Clics B', (m) => m.clicsB),
    numero('interesadosB', 'Interesados B', (m) => m.interesadosB, 'Escribieron al WhatsApp de Helios desde su tarjeta de /consultas.'),
    numero('convertidosB', 'Pacientes B', (m) => m.convertidosB, 'De esos interesados, los que ya tuvieron una orden confirmada con este médico.'),
    {
      key: 'enB',
      header: 'En B',
      info: 'Si hoy sale en /consultas: publicado y con una consulta de más de $15 y hasta $60 (o su equivalente en euros).',
      sort: (m) => (m.enB ? 1 : 0),
      sortDir: 'desc',
      csv: (m) => (m.enB ? 'Sí' : 'No'),
      cell: (m) => (m.enB ? <Badge tone="success">Sí</Badge> : <Badge tone="neutral">Solo A</Badge>),
    },
  ]
}
