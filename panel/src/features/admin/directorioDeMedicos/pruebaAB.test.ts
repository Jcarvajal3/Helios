/**
 * Pruebas de la prueba A/B del directorio (`/directorio` contra `/consultas`).
 *
 *   npx tsx src/features/admin/directorioDeMedicos/pruebaAB.test.ts
 *
 * Lo que se vigila: que `admin_directorio_ab()` se lea aunque llegue raro
 * (variantes que faltan, cifras en texto, días desordenados, médicos sin id),
 * que el rango cuente hoy, y que el veredicto no dé ganadora con pocos
 * visitantes ni con menos de 95 % de confianza, y sí cuando la diferencia es
 * clara, con la confianza de una prueba z de dos proporciones.
 */
import {
  MINIMO_DE_VISITANTES,
  leerPruebaAB,
  leerRangoDeLaPrueba,
  rangoDeLaPrueba,
  resumenDeMedicos,
  tasaDeClic,
  veredictoAB,
} from './pruebaAB'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle: unknown = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${JSON.stringify(detalle)}`}`)
}

const cerca = (x: number | null, y: number, tol = 0.001) => x !== null && Math.abs(x - y) < tol

console.log('── Leer admin_directorio_ab() ────────────────────────────────')
const p = leerPruebaAB({
  desde: '2026-11-09',
  hasta: '2026-11-11',
  variantes: [
    { variante: 'b', ruta: '/consultas', visitas: '40', visitantes: 30, clics: 9, visitantes_con_clic: 6, interesados: 4, convertidos: 1 },
    { variante: 'a', ruta: '/directorio', visitas: 50, visitantes: 35, clics: 7, visitantes_con_clic: 5, interesados: 0, convertidos: 0 },
    { variante: 'b', visitas: 999 },
  ],
  dias: [
    { dia: '2026-11-11', a: { visitantes: 10, visitantes_con_clic: 1, clics: 2 }, b: { visitantes: 0 } },
    { dia: '2026-11-09', a: { visitantes: 5, visitantes_con_clic: 2, clics: 2 }, b: null },
    { dia: null, a: {}, b: {} },
    { dia: '2026-11-10', a: 'raro', b: { visitantes: '7', visitantes_con_clic: 3, clics: 4 } },
  ],
  medicos: [
    { merchant_id: 'm1', medico: 'Dra. Ana Lara', precio_cur: 40, moneda: 'USD', en_b: true, clics_a: 3, clics_b: 5, interesados_b: 2, convertidos_b: 1 },
    { merchant_id: 'm2', medico: 'Dr. Luis Paz', precio_cur: null, moneda: 'EUR', en_b: 'true', clics_a: '2' },
    { medico: 'Sin id' },
  ],
  excluidos: { visitas_equipo: 3, clics_equipo: '2' },
  visitas_desde: '2026-11-09',
})
comprueba(p.desde === '2026-11-09' && p.hasta === '2026-11-11', 'el rango')
comprueba(p.a.visitantes === 35 && p.a.ruta === '/directorio', 'A se busca por su letra, no por su posición', p.a)
comprueba(p.b.visitas === 40 && p.b.visitantesConClic === 6 && p.b.interesados === 4, 'B, con un número en texto; la repetida no pisa la primera', p.b)
comprueba(
  JSON.stringify(p.dias.map((d) => d.dia)) === JSON.stringify(['2026-11-09', '2026-11-10', '2026-11-11']),
  'los días, sin el que no tiene fecha y del más viejo al más nuevo',
  p.dias.map((d) => d.dia),
)
comprueba(p.dias[0].b.visitantes === 0 && p.dias[1].a.clics === 0, 'un día sin cifras de una variante va a cero', p.dias)
comprueba(p.dias[1].b.visitantes === 7, 'cifras del día en texto', p.dias[1])
comprueba(p.medicos.length === 2, 'el médico sin id se descarta', p.medicos)
comprueba(p.medicos[0].enB && p.medicos[0].precio === 40 && p.medicos[0].convertidosB === 1, 'un médico de B', p.medicos[0])
comprueba(
  !p.medicos[1].enB && p.medicos[1].precio === null && p.medicos[1].moneda === 'EUR' && p.medicos[1].clicsA === 2 && p.medicos[1].clicsB === 0,
  'en_b solo es verdad con true; sin precio es null, no 0',
  p.medicos[1],
)
comprueba(p.excluidos.visitasEquipo === 3 && p.excluidos.clicsEquipo === 2, 'lo del equipo', p.excluidos)
comprueba(p.visitasDesde === '2026-11-09', 'visitas_desde')

const vacia = leerPruebaAB(null)
comprueba(
  vacia.a.visitantes === 0 && vacia.b.ruta === '/consultas' && vacia.a.ruta === '/directorio' && vacia.dias.length === 0 && vacia.visitasDesde === null,
  'sin respuesta: dos variantes a cero con sus rutas, sin días ni visitas_desde',
  vacia,
)
comprueba(leerPruebaAB({ variantes: 'no', medicos: {}, dias: 3 }).medicos.length === 0, 'listas que no son listas: vacías')
comprueba(leerPruebaAB({ variantes: [{ variante: 'A', visitantes: 9 }] }).a.visitantes === 0, 'una variante en mayúscula no es la a')

console.log('── El rango ──────────────────────────────────────────────────')
comprueba(JSON.stringify(rangoDeLaPrueba(7, '2026-11-09')) === JSON.stringify({ desde: '2026-11-03', hasta: '2026-11-09' }), '7 días con hoy dentro')
comprueba(rangoDeLaPrueba(30, '2026-03-01').desde === '2026-01-31', '30 días cruzando febrero')
comprueba(rangoDeLaPrueba(90, '2026-11-09').desde === '2026-08-12', '90 días')
comprueba(leerRangoDeLaPrueba(14) === 14 && leerRangoDeLaPrueba('90') === 90, 'el rango de la dirección, número o texto')
comprueba(
  leerRangoDeLaPrueba(15) === undefined && leerRangoDeLaPrueba('') === undefined && leerRangoDeLaPrueba(null) === undefined && leerRangoDeLaPrueba('30 días') === undefined,
  'otro rango no vale',
)

console.log('── La tasa de clic ───────────────────────────────────────────')
comprueba(tasaDeClic({ visitantes: 0, visitantesConClic: 0 }) === null, 'sin visitantes no hay tasa (no es 0 %)')
comprueba(cerca(tasaDeClic({ visitantes: 200, visitantesConClic: 10 }), 0.05), '10 de 200 es 5 %')
comprueba(tasaDeClic({ visitantes: 3, visitantesConClic: 5 }) === 1, 'más clicadores que visitantes no pasa del 100 %')

console.log('── El veredicto ──────────────────────────────────────────────')
const pocos = veredictoAB({ visitantes: 99, visitantesConClic: 5 }, { visitantes: 500, visitantesConClic: 100 })
comprueba(pocos.estado === 'pocos_datos' && pocos.ganadora === null, `con menos de ${MINIMO_DE_VISITANTES} en una variante, no hay ganadora`, pocos)
comprueba(pocos.delante === 'b', 'pero se dice quién va delante', pocos)

const sinNadie = veredictoAB({ visitantes: 0, visitantesConClic: 0 }, { visitantes: 0, visitantesConClic: 0 })
comprueba(sinNadie.estado === 'pocos_datos' && sinNadie.confianza === null && sinNadie.delante === null, 'sin visitantes: sin confianza ni delantera', sinNadie)

const igual = veredictoAB({ visitantes: 1000, visitantesConClic: 50 }, { visitantes: 1000, visitantesConClic: 50 })
comprueba(igual.estado === 'sin_diferencia' && igual.delante === null && cerca(igual.confianza, 0) && igual.diferencia === null, 'iguales: sin diferencia', igual)

const ceros = veredictoAB({ visitantes: 300, visitantesConClic: 0 }, { visitantes: 300, visitantesConClic: 0 })
comprueba(ceros.estado === 'sin_diferencia' && ceros.z === 0, 'las dos al 0 %: z = 0, sin dividir por cero', ceros)

// 5 % contra 6 % con 1000 por variante: z ≈ 0,98, confianza ≈ 67 %.
const flojo = veredictoAB({ visitantes: 1000, visitantesConClic: 50 }, { visitantes: 1000, visitantesConClic: 60 })
comprueba(flojo.estado === 'sin_diferencia' && flojo.delante === 'b', 'una diferencia pequeña no gana', flojo)
comprueba(cerca(flojo.z, 0.981, 0.005) && cerca(flojo.confianza, 0.673, 0.005), 'z y confianza de la prueba de dos proporciones', flojo)
comprueba(cerca(flojo.diferencia, 0.2), 'B clica un 20 % más que A', flojo)

// 5 % contra 8 % con 1000 por variante: z ≈ 2,72, confianza ≈ 99,3 %.
const claro = veredictoAB({ visitantes: 1000, visitantesConClic: 50 }, { visitantes: 1000, visitantesConClic: 80 })
comprueba(claro.estado === 'gana' && claro.ganadora === 'b', 'una diferencia clara: gana B', claro)
comprueba(cerca(claro.z, 2.719, 0.005) && cerca(claro.confianza, 0.9935, 0.001), 'z ≈ 2,72 y confianza ≈ 99,3 %', claro)
comprueba(cerca(claro.diferencia, 0.6), 'B clica un 60 % más', claro)

const ganaA = veredictoAB({ visitantes: 400, visitantesConClic: 60 }, { visitantes: 400, visitantesConClic: 30 })
comprueba(ganaA.estado === 'gana' && ganaA.ganadora === 'a' && cerca(ganaA.diferencia, 1) && ganaA.z !== null && ganaA.z < 0, 'también gana A: un 100 % más, z negativo', ganaA)

// Justo por debajo del listón: z ≈ 1,90 → 94,3 %.
const casi = veredictoAB({ visitantes: 500, visitantesConClic: 40 }, { visitantes: 500, visitantesConClic: 58 })
comprueba(casi.estado === 'sin_diferencia' && casi.confianza !== null && casi.confianza > 0.9 && casi.confianza < 0.95, 'con 94 % de confianza todavía no gana', casi)

const otraEnCero = veredictoAB({ visitantes: 200, visitantesConClic: 0 }, { visitantes: 200, visitantesConClic: 20 })
comprueba(otraEnCero.estado === 'gana' && otraEnCero.ganadora === 'b' && otraEnCero.diferencia === null, 'frente a un 0 % no hay diferencia relativa que escribir', otraEnCero)

console.log('── La tabla por médico ───────────────────────────────────────')
const r = resumenDeMedicos(p.medicos)
comprueba(r.enB === 1 && r.clicsA === 5 && r.clicsB === 5, 'cuántos entran en B y los clics de cada variante', r)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
