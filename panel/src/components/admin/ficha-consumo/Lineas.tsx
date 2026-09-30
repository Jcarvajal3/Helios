import { Card, Divider, Seccion, formatUsd } from '@/components/ui'
import type { ChargeDetail } from '@/features/admin/consumos'
import { redondear } from './comun'

/**
 * Qué se consumió: las líneas del local, con el precio unitario.
 *
 * El unitario no es adorno: con la cantidad y el subtotal a secas, comprobar
 * una línea obliga a dividir de cabeza, que es justo lo que hace un operador
 * cuando alguien reclama que le cobraron de más.
 */
export function Lineas({ detail }: { detail: ChargeDetail }) {
  const suma = redondear(detail.items.reduce((total, i) => total + i.lineTotalUsd, 0))

  return (
    <Seccion titulo="Qué se financió">
      <Card>
        <ul className="flex flex-col gap-3">
          {/* Las líneas no traen id propio y el nombre puede repetirse: la
              posición dentro del cobro es la única clave estable. */}
          {detail.items.map((item, index) => (
            <li key={`${index}-${item.name}`} className="flex items-baseline gap-3">
              <div className="min-w-0 flex-1">
                <p className="truncate type-panel-body text-on-surface">{item.name}</p>
                <p className="tabular-nums type-panel-caption text-on-surface-variant">
                  {item.quantity} × {formatUsd(item.unitPriceUsd)}
                </p>
              </div>
              <span className="tabular-nums type-panel-body font-semibold text-on-surface">
                {formatUsd(item.lineTotalUsd)}
              </span>
            </li>
          ))}
        </ul>

        <Divider className="my-3" />

        <div className="flex items-baseline justify-between gap-4 type-panel-body">
          <span className="text-on-surface-variant">
            Suma de las líneas
            {/* Que no cuadre con el consumo es un dato: el cajero tecleó un
                monto libre encima del carrito. */}
            {Math.abs(suma - detail.financedUsd) >= 0.01 && (
              <span className="ml-2 type-panel-caption text-warning">
                no cuadra con el financiamiento ({formatUsd(detail.financedUsd)})
              </span>
            )}
          </span>
          <span className="tabular-nums type-panel-body font-semibold text-on-surface">
            {formatUsd(suma)}
          </span>
        </div>
      </Card>
    </Seccion>
  )
}
