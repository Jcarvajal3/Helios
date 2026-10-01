import { useNavigate } from '@tanstack/react-router'

import { Meter, Stat, StatGrid, estadoDeConsulta, formatUsd, formatPct } from '@/components/ui'
import { StackedBar } from '@/components/charts'
import type { TonoDeMarca } from '@/components/charts'
import { DataTable } from '@/components/DataTable'
import type { Column } from '@/components/DataTable'
import { TRAMOS_DE_USO } from '@/features/admin/riesgo/credito'
import type { TramoDeUso, UsoDeNivel, UsoDelCupo } from '@/features/admin/riesgo/credito'
import { csvDinero } from '@/lib/csv'
import { Bloque } from './Bloque'
import type { ConsultaDeBloque } from './Bloque'

/**
 * Sin usar en gris, usándolo en el tono del área y al tope en ámbar: quien
 * está al tope ya no puede comprar. Los cuatro tramos intermedios van en el
 * mismo tono, separados por su hueco; cada cuenta la dice el globo de la
 * barra (el de `StackedBar`, del kit).
 */
const TONO_DE_USO: Record<TramoDeUso, TonoDeMarca> = {
  '0': 'neutro',
  '1-25': 'area',
  '26-50': 'area',
  '51-75': 'area',
  '76-99': 'area',
  '100': 'warning',
}

/** Cómo está repartida la gente del nivel por el uso de su cupo, en una barra. */
function Reparto({ nivel }: { nivel: UsoDeNivel }) {
  const total = TRAMOS_DE_USO.reduce((s, t) => s + nivel.tramos[t.clave], 0)
  if (total === 0) return <span className="text-panel-muted">—</span>
  return (
    <span className="block w-32">
      <StackedBar
        leyenda={false}
        rotulo={`Registros del ${nivel.rotulo} por uso del cupo`}
        segmentos={TRAMOS_DE_USO.map((t) => ({
          rotulo: t.rotulo,
          valor: nivel.tramos[t.clave],
          tono: TONO_DE_USO[t.clave],
        }))}
      />
    </span>
  )
}

const COLUMNAS: Array<Column<UsoDeNivel>> = [
  { key: 'nivel', header: 'Nivel', identity: true, cell: (r) => r.rotulo, csv: (r) => r.rotulo },
  {
    key: 'limite',
    header: 'Límite por paciente',
    type: 'number',
    cell: (r) => formatUsd(r.limite),
    sort: (r) => r.limite,
    csv: (r) => csvDinero(r.limite),
  },
  {
    key: 'personas',
    header: 'Registros',
    type: 'number',
    info: 'Los registros del nivel, en cualquier estado (activos, congelados, suspendidos o expulsados). Entre paréntesis, los activos.',
    cell: (r) => `${r.personas} (${r.activas})`,
    sort: (r) => r.personas,
    sortDir: 'desc',
    csv: (r) => r.personas,
  },
  {
    key: 'usando',
    header: 'Pacientes con cupo ocupado',
    info: 'Los registros del nivel con alguna cuota sin pagar, que ocupa cupo.',
    type: 'number',
    cell: (r) => r.usando,
    sort: (r) => r.usando,
    sortDir: 'desc',
    csv: (r) => r.usando,
  },
  {
    key: 'ocupado',
    header: 'Cupo ocupado',
    type: 'number',
    info: 'Sin el service fee: el financiado de cada financiamiento que todavía tiene alguna cuota de ese paciente sin pagar. Es la misma cuenta que frena una compra.',
    cell: (r) => formatUsd(r.ocupado),
    sort: (r) => r.ocupado,
    sortDir: 'desc',
    csv: (r) => csvDinero(r.ocupado),
  },
  {
    key: 'disponible-hoy',
    header: 'Cupo disponible hoy',
    type: 'number',
    info: 'Lo que los registros del nivel pueden gastar hoy (sin fee), sumado paciente a paciente. Quien tiene una cuota vencida, la cuenta sin activar o un bloqueo suma cero aunque le quede cupo.',
    cell: (r) => (r.gastableHoy === null ? '—' : formatUsd(r.gastableHoy)),
    sort: (r) => r.gastableHoy,
    csv: (r) => (r.gastableHoy === null ? null : csvDinero(r.gastableHoy)),
  },
  {
    key: 'disponible',
    header: 'Cupo libre',
    type: 'number',
    info: 'El límite menos lo ocupado, sin fee, sin mirar si hoy el paciente puede gastar.',
    cell: (r) => formatUsd(r.disponible),
    sort: (r) => r.disponible,
    csv: (r) => csvDinero(r.disponible),
  },
  {
    key: 'exposicion',
    header: 'Exposición',
    type: 'number',
    info: 'Sin el service fee: el financiado de cada cuota pendiente que no se ha dado por perdida, lo que falta por volver. Es menor que lo ocupado, porque quien pagó la cuota 1 sigue ocupando el financiamiento entero hasta pagar la 2.',
    cell: (r) => formatUsd(r.exposicion),
    sort: (r) => r.exposicion,
    sortDir: 'desc',
    csv: (r) => csvDinero(r.exposicion),
  },
  {
    key: 'uso',
    header: 'Uso del cupo',
    type: 'number',
    info: 'El cupo ocupado sobre el cupo de todos los registros del nivel.',
    cell: (r) => (r.usoPct === null ? '—' : formatPct(r.usoPct)),
    sort: (r) => r.usoPct,
    sortDir: 'desc',
    csv: (r) => r.usoPct,
  },
  {
    key: 'reparto',
    header: 'Registros por uso del cupo',
    info: 'Cuántos registros del nivel tienen su cupo sin usar (gris), usándolo (en el tono del área) o al tope (ámbar). Cada tramo, al pasar el ratón o al enfocar la barra.',
    cell: (r) => <Reparto nivel={r} />,
  },
]

/**
 * El uso del cupo por nivel y la exposición total: cuánto se ha prestado,
 * cuánto queda por prestar y cuánto falta por volver. Todo en consumo, sin el
 * service fee. Cada fila abre Personas filtrada por ese nivel; las
 * cifras de arriba llevan a Ajustes › Niveles y cupos, donde se cambia el
 * límite.
 *
 * La consulta llega hecha (Métricas la pide con su local). Con un local, es
 * la gente que ha consumido allí, con todo su cupo: el cupo es de la persona,
 * no del local, y `gente` lo dice encima.
 */
export function Cupos({
  consulta: uso,
  gente,
}: {
  consulta: ConsultaDeBloque<UsoDelCupo> & { isPending: boolean }
  /** De quién son las cifras cuando no es todo el mundo: «La gente que ha consumido en La Quinta». */
  gente?: string
}) {
  const navigate = useNavigate()
  const t = uso.data?.total
  const estado = estadoDeConsulta(uso)
  const reintentar = () => void uso.refetch()

  return (
    <div className="flex flex-col gap-10">
      {gente && <p className="-mb-6 type-panel-body text-on-surface-variant">{gente}, con todo su cupo.</p>}
      <StatGrid cols={4}>
        <Stat
          label="Exposición"
          value={t ? formatUsd(t.exposicion) : ''}
          info="Sin el service fee: el financiado de cada cuota pendiente que no se ha dado por perdida, de todos (también fuera de los niveles activos). Es la parte financiada de «Por cobrar» en Global › Resumen."
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Cupo ocupado"
          value={t ? formatUsd(t.ocupado) : ''}
          hint={t ? `${t.usando} ${t.usando === 1 ? 'paciente' : 'pacientes'} con cupo ocupado` : undefined}
          info="Sin el service fee: el financiado de cada financiamiento que todavía tiene alguna cuota sin pagar, de todos (también fuera de los niveles activos). Es la cuenta que frena una compra."
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Cupo disponible hoy"
          value={t ? (t.gastableHoy === null ? '—' : formatUsd(t.gastableHoy)) : ''}
          hint={
            t
              ? `${formatUsd(t.disponible)} de cupo libre de ${formatUsd(t.cupoTotal)}, sin contar los frenos`
              : undefined
          }
          info="Lo que los registros de los niveles activos pueden gastar hoy (sin fee), sumado paciente a paciente. Quien tiene una cuota vencida, la cuenta sin activar o un bloqueo suma cero aunque le quede cupo; debajo, el cupo libre sin contar esos frenos."
          link={{ to: '/admin/ajustes', search: { tab: 'niveles' } }}
          estado={estado}
          onReintentar={reintentar}
        />
        <Stat
          label="Uso del cupo"
          value={t ? (t.usoPct === null ? '—' : formatPct(t.usoPct)) : ''}
          info="El cupo ocupado por los registros de los niveles activos sobre el cupo total de esos niveles."
          visual={
            t?.usoPct != null && (
              <Meter valor={t.usoPct} max={100} rotulo={`Uso del cupo: ${formatPct(t.usoPct)}`} />
            )
          }
          link={{ to: '/admin/ajustes', search: { tab: 'niveles' } }}
          estado={estado}
          onReintentar={reintentar}
        />
      </StatGrid>

      <Bloque
        titulo="Por nivel"
        info="Quien está fuera de los niveles activos no sale en la tabla, pero lo que debe (financiado, sin fee) sí entra en el cupo ocupado y en la exposición de arriba."
        consulta={uso}
        filas={4}
      >
        {(d) => (
          <>
            <DataTable
              rows={d.niveles}
              rowKey={(r) => String(r.nivel)}
              columns={COLUMNAS}
              noun={['nivel', 'niveles']}
              exportar={{ archivo: 'uso-del-cupo-por-nivel' }}
              // La gente de ese nivel, en Personas.
              onRowClick={(r) => void navigate({ to: '/admin/pacientes', search: { nivel: r.nivel } })}
            />
            {d.fueraDeNivel.personas > 0 && (
              <p className="mt-3 type-panel-caption text-panel-muted">
                Fuera de los niveles activos: {d.fueraDeNivel.personas}{' '}
                {d.fueraDeNivel.personas === 1 ? 'paciente' : 'pacientes'}, que ocupan{' '}
                {formatUsd(d.fueraDeNivel.ocupado)} y deben {formatUsd(d.fueraDeNivel.exposicion)} facturados,
                sin el service fee.
              </p>
            )}
          </>
        )}
      </Bloque>
    </div>
  )
}
