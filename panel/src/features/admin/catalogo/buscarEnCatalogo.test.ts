/**
 * Pruebas del orden de `buscarEnCatalogo` (`index.ts`, junto a este archivo).
 *
 *   npx tsx src/features/admin/catalogo/buscarEnCatalogo.test.ts
 *
 * Con entradas inventadas, para que no dependan de lo que cada equipo escriba
 * en su archivo del catálogo. Lo que se prueba con las entradas reales vive en
 * `catalogo.test.ts`.
 */
import { House } from 'lucide-react'

import { buscarEn, buscarEnCatalogo } from './index'
import type { Ambito, Entrada } from './index'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

function pantalla(
  id: string,
  titulo: string,
  espacio: Ambito,
  sinonimos: string[] = [],
  descripcion = 'Una pantalla.',
): Entrada {
  return { tipo: 'pantalla', id, titulo, descripcion, espacio, sinonimos, destino: { to: '/admin' }, icono: House }
}

const ENTRADAS: Entrada[] = [
  pantalla('reportados', 'Pagos reportados', 'caja', ['cobros']),
  pantalla('locales', 'Pagos a clínicas', 'caja'),
  pantalla('medio', 'Ticket medio', 'gerencia'),
  pantalla('promedio', 'Ticket promedio', 'riesgo'),
  pantalla('kyc', 'Verificaciones', 'riesgo', ['kyc', 'identidad']),
  pantalla('desc', 'Otra cosa', 'caja', [], 'Donde se revisa el depósito del día.'),
  pantalla('alertas', 'Alertas', 'riesgo', ['alertas de riesgo']),
  pantalla('cuotas', 'Cuotas', 'riesgo', ['pagos atrasados']),
]

const ids = (texto: string) => buscarEn(ENTRADAS, texto, { limite: 10 }).pantallas.map((p) => p.id)

console.log('── Varias palabras a medias ──────────────────────────────────')
igual(ids('pago reportado')[0], 'reportados', '«pago reportado» encuentra «Pagos reportados»')
igual(ids('reportados pag')[0], 'reportados', 'en cualquier orden')
igual(ids('pag rep')[0], 'reportados', 'con la mitad de cada palabra')

console.log('\n── Letras sueltas y palabras cortas ─────────────────────────')
igual(ids('t'), ['medio', 'promedio'], 'una letra: solo lo que empieza por ella')
igual(ids('a'), ['alertas', 'locales'], 'una letra no busca dentro: «a» no trae medio catálogo')
igual(ids('de'), [], 'con dos letras solo cuentan los comienzos: «de» no se busca dentro de «identidad»')
igual(ids('deposito'), ['desc'], 'con tres o más, sí')

console.log('\n── Los empates ──────────────────────────────────────────────')
igual(ids('ticket'), ['medio', 'promedio'], 'a igualdad, el título más corto primero')
igual(ids('pagos'), ['reportados', 'locales', 'cuotas'], 'un sinónimo va detrás de los títulos; a igual largo, el orden del catálogo')

console.log('\n── La firma de siempre ──────────────────────────────────────')
igual(typeof buscarEnCatalogo('dinero').total, 'number', 'buscarEnCatalogo(texto) sigue sin opciones')
igual(buscarEnCatalogo('').total, 0, 'y una búsqueda vacía no devuelve nada')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
