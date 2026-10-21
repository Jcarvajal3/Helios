/**
 * Pruebas de cómo se escribe el desglose de lo que se cobra en Cohortes.
 *
 *   npx tsx src/features/admin/metricas/cohortes/desglose.test.ts
 *
 * Lo que se vigila: que el total a cobrar vaya siempre con sus dos sumandos
 * (consumo sin comisión y Comisión Helios), con las palabras que pidió Javier, y que
 * ninguna diga «servicio».
 */
import { desgloseCorto, desgloseEnFrase, importeYDesglose, lineaDelDesglose } from './desglose'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const total = { payableUsd: 1419.26, financedUsd: 1152, feeUsd: 267.26 }

igual(
  lineaDelDesglose(total),
  'Financiado $1.152,00 (sin comisión) · Comisión Helios + IVA $267,26',
  'la línea bajo una cifra: financiamiento sin comisión y Comisión Helios',
)
igual(desgloseCorto(total), 'financiado $1.152,00 · comisión + IVA $267,26', 'en una celda: financiamiento · comisión')
igual(
  desgloseEnFrase(total),
  'financiado $1.152,00 + Comisión Helios + IVA $267,26',
  'dentro de una frase, para ir entre paréntesis',
)
igual(importeYDesglose(total), '$1.419,26 (financiado $1.152,00 · comisión + IVA $267,26)', 'el importe y su desglose en una línea')
igual(
  [lineaDelDesglose(total), desgloseCorto(total), desgloseEnFrase(total), importeYDesglose(total)].some((t) =>
    /servicio/i.test(t),
  ),
  false,
  'ninguno dice «servicio»',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallos.`)
if (fallos > 0) process.exit(1)
