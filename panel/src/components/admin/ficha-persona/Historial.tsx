import { useInfiniteQuery } from '@tanstack/react-query'

import {
  Button,
  Card,
  NoSePudoLeer,
  Seccion,
  SkeletonList,
  formatDateTime,
} from '@/components/ui'
import { describirEvento } from '@/features/admin/bitacora'
import { fetchAuditLog } from '@/features/admin/ops'
import { SeccionSinLeer } from '@/components/admin/directorio/SeccionSinLeer'

/** Cuántas líneas se piden de cada vez. */
const PAGINA = 50

// ── 7. Bitácora de esta persona ────────────────────────────────────────────

/**
 * Todo lo que se le hizo a esta cuenta, incluido lo que hizo el estado
 * automático: cada congelación, cada cargo y cada bajada de nivel, con el
 * mismo formato que las acciones de una persona. Es lo que contesta «¿por qué
 * está congelada?» sin salir de la ficha.
 *
 * Se lee por páginas: antes cortaba en cincuenta sin decirlo, y una cuenta
 * con historia larga parecía no tener nada anterior.
 */
export function PestanaHistorial({ userId }: { userId: string }) {
  const query = useInfiniteQuery({
    queryKey: ['admin-audit', 'persona', userId],
    queryFn: ({ pageParam }) => fetchAuditLog({ target: userId, limit: PAGINA, offset: pageParam }),
    initialPageParam: 0,
    getNextPageParam: (ultima, paginas) => {
      const leidas = paginas.reduce((n, p) => n + p.rows.length, 0)
      return ultima.rows.length > 0 && leidas < ultima.total ? leidas : undefined
    },
  })

  const filas = query.data?.pages.flatMap((p) => p.rows) ?? []
  const total = query.data?.pages.at(-1)?.total ?? 0

  return (
    <Seccion
      titulo="Bitácora"
      info="Todo lo que se le hizo a esta cuenta, incluido lo que hizo el estado automático: cada congelación, cada cargo y cada bajada de nivel."
    >
      {query.isPending && <SkeletonList rows={2} />}

      {query.isError && filas.length === 0 && (
        <SeccionSinLeer
          titulo="No se pudo leer la bitácora"
          error={query.error}
          onReintentar={() => void query.refetch()}
        />
      )}

      {query.isSuccess && filas.length === 0 && (
        <Card>
          <p className="type-panel-body text-on-surface-variant">
            Nada registrado todavía sobre esta cuenta.
          </p>
        </Card>
      )}

      {filas.length > 0 && (
        <div className="flex flex-col gap-3">
          <ul className="flex flex-col divide-y divide-panel-hairline rounded-panel-card border border-panel-hairline bg-panel-card">
          {filas.map((e) => {
            const linea = describirEvento(e)
            return (
              <li key={e.id} className="px-4 py-3">
                <p className="type-panel-body text-on-surface">{linea.frase}</p>
                <p className="mt-1 type-panel-caption text-on-surface-variant">
                  {formatDateTime(e.createdAt)}
                  {linea.datos.map((d) => ` · ${d.label} ${d.valor}`).join('')}
                </p>
                {linea.cambio && (
                  <p className="mt-1 type-panel-caption text-on-surface-variant">
                    Antes {linea.cambio.antes} · después {linea.cambio.despues}
                  </p>
                )}
                {linea.motivo && (
                  <p className="mt-1 type-panel-caption italic text-on-surface-variant">
                    «{linea.motivo}»
                  </p>
                )}
              </li>
            )
          })}
          </ul>

          <div className="flex flex-wrap items-center gap-3">
            <p className="type-panel-caption text-panel-muted">
              {filas.length < total
                ? `Se ven las ${filas.length} más recientes de ${total}.`
                : `${total} ${total === 1 ? 'línea' : 'líneas'} en total.`}
            </p>
            {query.hasNextPage && (
              <Button
                size="sm"
                variant="tonal"
                disabled={query.isFetchingNextPage}
                onClick={() => void query.fetchNextPage()}
              >
                {query.isFetchingNextPage ? 'Leyendo…' : 'Ver más'}
              </Button>
            )}
            {query.isFetchNextPageError && (
              <NoSePudoLeer onReintentar={() => void query.fetchNextPage()} />
            )}
          </div>
        </div>
      )}
    </Seccion>
  )
}
