/**
 * Pruebas de los contadores del menú.
 *
 *   npx tsx src/components/layouts/contadores.test.ts
 *
 * Lo que se vigila: que el rojo salga solo de lo que Inicio considera pasado
 * de plazo, que una cola vacía nunca sea urgente y que sumar dos colas (o un
 * grupo plegado) no invente un cero cuando no se leyó nada.
 */
import { resumirAlertasAltas } from '@/components/admin/inicio/colas'
import { cifraDelContador, contadorDeCola, rotuloDelContador, sumarContadores } from './contadores'
import type { Contador } from './contadores'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual(real: Contador | undefined, esperado: Contador | undefined, titulo: string) {
  comprueba(JSON.stringify(real) === JSON.stringify(esperado), titulo, JSON.stringify(real))
}

console.log('── La urgencia es el plazo «pasado» de Inicio ────────────────')
igual(contadorDeCola({ cantidad: 3, plazo: 'pasado' }), { n: 3, urgente: true }, 'pasado → rojo')
igual(contadorDeCola({ cantidad: 3, plazo: 'hoy' }), { n: 3, urgente: false }, 'hoy → neutro')
igual(
  contadorDeCola({ cantidad: 3, plazo: 'puede_esperar' }),
  { n: 3, urgente: false },
  'puede esperar → neutro',
)
igual(
  contadorDeCola({ cantidad: 0, plazo: 'pasado' }),
  { n: 0, urgente: false },
  'una cola vacía nunca es urgente, aunque su plazo sea «pasado»',
)

console.log('── Con los resúmenes de verdad ───────────────────────────────')
igual(
  contadorDeCola(resumirAlertasAltas({ pendientesAltas: 2, pendientesMedias: 5, revisadas: 0 })),
  { n: 2, urgente: false },
  'las alertas altas son de hoy, nunca rojo',
)
igual(
  contadorDeCola(resumirAlertasAltas({ pendientesAltas: 0, pendientesMedias: 5, revisadas: 0 })),
  { n: 0, urgente: false },
  'sin altas, cero',
)

console.log('── Sumar ─────────────────────────────────────────────────────')
igual(sumarContadores([undefined, undefined]), undefined, 'sin leer nada, nada (no un cero)')
igual(sumarContadores([{ n: 2, urgente: false }, undefined]), { n: 2, urgente: false }, 'lo que se sepa')
igual(
  sumarContadores([
    { n: 2, urgente: false },
    { n: 1, urgente: true },
  ]),
  { n: 3, urgente: true },
  'urgente si lo es cualquiera',
)

console.log('── La pastilla ───────────────────────────────────────────────')
comprueba(cifraDelContador(7) === '7', 'una cifra corta va entera')
comprueba(cifraDelContador(120) === '99+', 'más de 99 no cabe')
comprueba(rotuloDelContador({ n: 1, urgente: false }) === '1 pendiente', 'singular')
comprueba(
  rotuloDelContador({ n: 3, urgente: true }) === '3 pendientes, con atraso',
  'el lector de pantalla oye el atraso',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
