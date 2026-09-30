/**
 * Pruebas de la escala de los gráficos.
 *
 *   npx tsx src/components/escala.test.ts
 *
 * Sin framework, como el resto: es aritmética pura. Lo que se comprueba aquí
 * no se ve mirando la pantalla —un eje que dice «13 / 10 / 8 / 5 / 3» parece
 * un eje— y se rompe en silencio en cuanto alguien toca la lista de pasos.
 *
 * El caso que más importa es el del eje ENTERO: cuenta personas, y con un paso
 * de 2,5 el eje dibuja marcas que no existen.
 */
import { escalaBonita } from './charts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: string) {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function marcas(max: number, entera = false) {
  return escalaBonita(max, entera).marcas
}

console.log('── El tope nunca deja una barra fuera ───────────────────────')
for (const max of [1, 2, 3, 5, 8, 12, 47, 99, 100, 437.2, 1284.5, 9999]) {
  const { tope } = escalaBonita(max)
  comprueba(tope >= max, `${max} cabe bajo su tope`, `tope ${tope} < max ${max}`)
}

console.log('\n── Eje entero: ni una marca con decimales ───────────────────')
for (const max of [1, 2, 3, 4, 5, 6, 8, 9, 12, 13, 17, 23, 47, 88, 131, 227]) {
  const m = marcas(max, true)
  comprueba(
    m.every((x) => Number.isInteger(x)),
    `${max} → ${m.join(' / ')}`,
    'hay marcas decimales',
  )
  comprueba(
    escalaBonita(max, true).tope >= max,
    `${max} cabe bajo su tope entero`,
    'la barra se sale',
  )
}

console.log('\n── El caso que lo motivó ────────────────────────────────────')
comprueba(
  marcas(12).some((x) => !Number.isInteger(x)),
  '12 sin `entera` sigue dando marcas de 2,5 (el eje de dinero no cambia)',
  'la escala normal cambió de comportamiento',
)
comprueba(
  JSON.stringify(marcas(12, true)) === JSON.stringify([0, 5, 10, 15]),
  '12 con `entera` da 0 / 5 / 10 / 15',
  `dio ${marcas(12, true).join(' / ')}`,
)

console.log('\n── El dinero conserva sus pasos finos ───────────────────────')
comprueba(
  JSON.stringify(marcas(437.2)) === JSON.stringify([0, 150, 300, 450]),
  '437,20 → 0 / 150 / 300 / 450',
  `dio ${marcas(437.2).join(' / ')}`,
)

console.log('\n── Vacío y basura no revientan ──────────────────────────────')
for (const max of [0, -5, NaN, Infinity]) {
  const { tope, marcas: m } = escalaBonita(max)
  comprueba(tope === 0 && m.length === 1, `${max} da una escala vacía`, `tope ${tope}`)
}

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
