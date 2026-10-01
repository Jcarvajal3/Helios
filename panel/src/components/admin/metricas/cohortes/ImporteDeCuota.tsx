import { formatUsd } from '@/components/ui'
import { desgloseCorto } from '@/features/admin/metricas/cohortes/desglose'
import type { Desglose } from '@/features/admin/metricas/lectura'

/**
 * Un importe que se cobra (payable: una cuota, lo que hay que cobrar de una
 * semana, lo cobrado, lo vencido…), SIEMPRE con su desglose visible debajo,
 * en pequeño. Es la condición de la excepción que aprobó Javier para
 * Cohortes: el total lleva el fee dentro, pero sus dos sumandos se ven.
 *
 * `linea`: la cifra y debajo «Facturado $X (sin fee) · service fee + IVA $Y»
 * (una tarjeta). `compacta`: la cifra y debajo «facturado $X · fee + IVA $Y»
 * (una fila con sitio). `celda`: la cifra y debajo «facturado $X» y «fee +
 * IVA $Y» en dos líneas (una tabla ancha: la columna mide lo que la cifra, no
 * la frase).
 */
export function ImporteDeCuota({
  importe,
  variante = 'linea',
  prefijo = '',
  claseCifra = 'type-panel-body font-semibold text-on-surface',
  alinear = 'derecha',
  className = '',
}: {
  importe: Desglose
  variante?: 'linea' | 'compacta' | 'celda'
  /** Lo que va delante de la cifra: «de ». */
  prefijo?: string
  claseCifra?: string
  /** La compacta, en una columna de cifras (derecha) o detrás de otra cosa (izquierda). */
  alinear?: 'derecha' | 'izquierda'
  className?: string
}) {
  const compacta = variante !== 'linea'

  if (variante === 'celda') {
    return (
      <span
        className={`flex flex-col ${alinear === 'derecha' ? 'items-end' : 'items-start'} ${className}`}
      >
        <span className={`tabular-nums ${claseCifra}`}>
          {prefijo}
          {formatUsd(importe.payableUsd)}
        </span>
        <span className="type-panel-caption whitespace-nowrap tabular-nums text-panel-muted">
          financiado {formatUsd(importe.financedUsd)}
        </span>
        <span className="type-panel-caption whitespace-nowrap tabular-nums text-panel-muted">
          fee + IVA {formatUsd(importe.feeUsd)}
        </span>
      </span>
    )
  }

  return (
    <span
      className={`flex flex-col gap-0.5 ${
        compacta ? (alinear === 'derecha' ? 'items-end' : 'items-start') : ''
      } ${className}`}
    >
      <span className={`tabular-nums ${claseCifra}`}>
        {prefijo}
        {formatUsd(importe.payableUsd)}
      </span>
      <span
        className={`type-panel-caption tabular-nums text-panel-muted ${compacta ? 'whitespace-nowrap' : ''}`}
      >
        {compacta ? desgloseCorto(importe) : <LineaDelDesglose d={importe} />}
      </span>
    </span>
  )
}

/**
 * «Facturado $X (sin fee) · service fee + IVA $Y» (el texto de `lineaDelDesglose`),
 * partida por el punto: si no cabe en una línea, baja entera la segunda
 * parte y no se separa una cifra de su nombre.
 */
export function LineaDelDesglose({ d }: { d: Pick<Desglose, 'financedUsd' | 'feeUsd'> }) {
  return (
    <>
      <span className="whitespace-nowrap">Financiado {formatUsd(d.financedUsd)} (sin fee)</span>
      {' · '}
      <span className="whitespace-nowrap">service fee + IVA {formatUsd(d.feeUsd)}</span>
    </>
  )
}
