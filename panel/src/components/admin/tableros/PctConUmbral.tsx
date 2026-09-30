import { Badge, formatPct } from '@/components/ui'
import { MarcaConGlobo, colorDeTono } from '@/components/charts'
import { senalPorUmbral } from '@/features/admin/umbrales'
import type { Umbral } from '@/features/admin/umbrales'
import { pctDeUmbral } from './senales'

/**
 * Un porcentaje de una tabla (mora, impago) con el color que le da su umbral.
 *
 * Por debajo de la alerta va en texto, sin pastilla: una columna entera de
 * verdes era ruido y escondía la fila que sí cruza. La que cruza lleva la
 * pastilla con icono, y el umbral que cruza en su globo, que sale al pasar
 * el ratón o al llegar con Tab.
 */
export function PctConUmbral({
  valor,
  umbral,
  apagado = false,
  rotulo = 'Cruza su umbral',
}: {
  valor: number | null
  umbral: Umbral | null
  /** Una cifra que todavía puede cambiar (una cosecha en curso): en gris y sin color. */
  apagado?: boolean
  /** El título del globo: qué cifra es. «Impago», «Mora». */
  rotulo?: string
}) {
  if (valor === null) return <span className="text-panel-muted">—</span>

  const texto = formatPct(valor)
  const senal = apagado ? undefined : senalPorUmbral(valor, umbral, pctDeUmbral)
  if (!senal) return <span className={apagado ? 'text-panel-muted' : undefined}>{texto}</span>

  return (
    <MarcaConGlobo
      titulo={rotulo}
      filas={[{ key: 'valor', rotulo: senal.texto, valor: texto, color: colorDeTono(senal.tone), forma: 'punto' }]}
      className="relative z-10 inline-flex rounded-full"
    >
      <Badge tone={senal.tone} icono>
        {texto}
      </Badge>
    </MarcaConGlobo>
  )
}
