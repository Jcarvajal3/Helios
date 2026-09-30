/**
 * Pruebas del perfil de los morosos (Por cobrar › Morosos).
 *
 *   npx tsx src/features/admin/cobranza/perfilDeMorosos.test.ts
 *
 * Lo que se vigila: que se lea la respuesta entera, que cada porcentaje vaya
 * sobre quien tiene el dato (no sobre todos) y que sin grupo o sin dato no se
 * invente una cifra.
 */
import { filasDeRasgos, leerPerfilDeMorosos, parte } from './perfilDeMorosos'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

const grupo = (extra: Record<string, unknown> = {}) => ({
  personas: 10,
  vencidas: 8,
  atraso_medio_dias: 3.5,
  edad: { conocida: 8, mediana: 31, tramos: { '18-24': 1, '25-34': 6, '35-44': 1, '45+': 0 } },
  sexo: { F: 3, M: 6, sin_dato: 1 },
  plataforma: { android: 6, ios: 2, otra: 0, sin_dato: 2 },
  nivel_medio: 1.2,
  nuevos: 5,
  en_grupo: 4,
  sin_avisos: 7,
  consumo_medio_usd: 17.35,
  ciudades: [{ ciudad: 'Caracas', personas: 6 }],
  ciudades_otras: 2,
  ...extra,
})

const p = leerPerfilDeMorosos({
  business_date: '2026-09-29',
  morosos: grupo(),
  al_dia: grupo({ personas: 20, vencidas: 0, sexo: { F: 10, M: 10, sin_dato: 0 } }),
})

comprueba(p.businessDate === '2026-09-29' && p.morosos !== null && p.alDia !== null, 'los dos grupos')
comprueba(p.morosos?.edad.tramos['25-34'] === 6, 'los tramos de edad')
comprueba(leerPerfilDeMorosos({ business_date: '2026-09-29', morosos: null, al_dia: grupo() }).morosos === null, 'sin morosos, null')

const filas = filasDeRasgos(p)
const fila = (clave: string) => filas.find((f) => f.clave === clave)
comprueba(fila('mujeres')?.morosos?.texto === '33 %', 'mujeres sobre quien tiene sexo (3 de 9)', fila('mujeres')?.morosos?.texto)
comprueba(fila('mujeres')?.alDia?.pct === 50, 'y en quien está al día, la mitad')
comprueba(fila('ios')?.morosos?.texto === '25 %', 'iPhone sobre quien tiene teléfono conocido (2 de 8)', fila('ios')?.morosos?.texto)
comprueba(fila('avisos')?.morosos?.pct === 70, 'sin avisos sobre todos')
comprueba(fila('tramo')?.morosos?.texto === '25-34 años · 75 %', 'el tramo más común sobre quien tiene edad', fila('tramo')?.morosos?.texto)
comprueba(fila('ciudad')?.morosos?.texto === 'Caracas · 75 %', 'la ciudad sobre quien tiene ciudad (6 de 8)', fila('ciudad')?.morosos?.texto)
comprueba(fila('edad')?.morosos?.pct === null, 'la mediana no lleva barra')
comprueba(fila('nuevos')?.rotulo === 'Menos de 4 semanas en Helios', 'los rasgos hablan de toda la gente, no de una semana')
comprueba(
  filasDeRasgos({ businessDate: '2026-09-29', morosos: grupo_(), alDia: null }).every((f) => f.alDia === null),
  'sin grupo, ninguna cifra',
)

function grupo_() {
  return leerPerfilDeMorosos({ business_date: 'x', morosos: grupo(), al_dia: null }).morosos
}

comprueba(parte(1, 0) === null, 'sin nadie con el dato, no hay parte')

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
