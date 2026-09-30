/**
 * Pruebas del rango de fechas de `Periodo`.
 *
 *   npx tsx src/components/kit/rango.test.ts
 *
 * Lo que se vigila: que el botón diga el rango en corto y con el año solo
 * cuando cruza de uno a otro, que una fecha escrita a mano se lea con el día
 * primero y se rechace si no existe, y que «Rango propio» explique por qué no
 * vale en el orden en que se rellena.
 */
import { escribirFecha, leerFecha, leerRangoPropio, rangoCorto, rangoDeAlLado } from './rango'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

function igual<TValor>(sale: TValor, espera: TValor, titulo: string) {
  comprueba(JSON.stringify(sale) === JSON.stringify(espera), titulo, JSON.stringify(sale))
}

console.log('── rangoCorto ────────────────────────────────────────────────')
igual(rangoCorto({ from: '2026-08-27', to: '2026-09-25' }), '27 ago – 25 sep', 'dos meses del mismo año')
igual(rangoCorto({ from: '2026-09-01', to: '2026-09-25' }), '1 sep – 25 sep', 'dentro de un mes')
igual(rangoCorto({ from: '2026-09-25', to: '2026-09-25' }), '25 sep', 'un solo día')
igual(
  rangoCorto({ from: '2025-12-28', to: '2026-01-03' }),
  '28 dic 2025 – 3 ene 2026',
  'cruzando de año, con los dos años',
)

console.log('── leerFecha ─────────────────────────────────────────────────')
igual(leerFecha('27/08/2026'), '2026-08-27', 'el día primero, con barras')
igual(leerFecha('27/8/2026'), '2026-08-27', 'sin el cero del mes')
igual(leerFecha(' 27-08-26 '), '2026-08-27', 'con guiones, año corto y espacios')
igual(leerFecha('27.08.2026'), '2026-08-27', 'con puntos')
igual(leerFecha('2026-08-27'), '2026-08-27', 'la forma ISO')
igual(leerFecha('29/02/2028'), '2028-02-29', 'un 29 de febrero bisiesto')
igual(leerFecha('29/02/2026'), null, 'un 29 de febrero que no existe')
igual(leerFecha('31/04/2026'), null, 'un 31 de abril')
igual(leerFecha('08/27/2026'), null, 'el formato de EE. UU. no se lee al revés')
igual(leerFecha(''), null, 'vacío')
igual(leerFecha('ayer'), null, 'texto')
igual(escribirFecha('2026-08-27'), '27/08/2026', 'escribirFecha es la inversa')

console.log('── leerRangoPropio ───────────────────────────────────────────')
igual(
  leerRangoPropio('27/08/2026', '25/09/2026', '2026-09-25'),
  { rango: { from: '2026-08-27', to: '2026-09-25' } },
  'un rango bueno',
)
igual(
  leerRangoPropio('25/09/2026', '25/09/2026', '2026-09-25'),
  { rango: { from: '2026-09-25', to: '2026-09-25' } },
  'un solo día vale',
)
comprueba('error' in leerRangoPropio('27/08', '25/09/2026', '2026-09-25'), 'una fecha a medias no vale')
igual(
  leerRangoPropio('26/09/2026', '25/09/2026', '2026-09-25'),
  { error: 'La fecha de inicio va después de la final.' },
  'al revés, se dice',
)
igual(
  leerRangoPropio('20/09/2026', '30/09/2026', '2026-09-25'),
  { error: 'Solo hay datos hasta el 25/09/2026.' },
  'después del máximo, se dice hasta cuándo',
)

console.log('── rangoDeAlLado ─────────────────────────────────────────────')
{
  const hoy = '2026-09-25'
  igual(
    rangoDeAlLado({ from: '2026-08-27', to: hoy }, -1, hoy),
    { from: '2026-07-28', to: '2026-08-26' },
    'desde «30 días», los 30 anteriores',
  )
  igual(
    rangoDeAlLado({ from: '2026-07-28', to: '2026-08-26' }, 1, hoy),
    { from: '2026-08-27', to: hoy },
    'y de vuelta',
  )
  igual(
    rangoDeAlLado({ from: '2026-09-10', to: '2026-09-20' }, 1, hoy),
    { from: '2026-09-15', to: hoy },
    'hacia delante no pasa de hoy: acaba en hoy con el mismo largo',
  )
  igual(
    rangoDeAlLado({ from: '2026-09-01', to: hoy }, -1, hoy),
    { from: '2026-08-01', to: '2026-08-31' },
    'desde «Este mes», el mes pasado entero',
  )
  igual(
    rangoDeAlLado({ from: '2026-08-01', to: '2026-08-31' }, 1, hoy),
    { from: '2026-09-01', to: hoy },
    'y hacia delante, el mes en curso hasta hoy',
  )
  igual(
    rangoDeAlLado({ from: '2026-03-01', to: '2026-03-31' }, -1, hoy),
    { from: '2026-02-01', to: '2026-02-28' },
    'febrero sale con sus 28 días',
  )
  igual(
    rangoDeAlLado({ from: '2026-01-01', to: '2026-01-31' }, -1, hoy),
    { from: '2025-12-01', to: '2025-12-31' },
    'y el mes cruza de año',
  )
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
