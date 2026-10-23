/**
 * Pruebas de lo que pinta la navegación de Métricas.
 *
 *   npx tsx src/features/admin/metricas/navegacion.test.ts
 *
 * Lo que se vigila: que cada pestaña lleve a su primera sub-pestaña con la
 * misma semana y el mismo local y sin las claves de la que se deja; que las
 * sub-pestañas conserven las claves de su pestaña; que se marque bien dónde
 * se está (la página, o la pestaña que la contiene); que Locales no tenga
 * banda; y que la línea de «dónde estás» diga el nombre y lo que contesta.
 */
import { validarBusquedaMetricas } from './busqueda'
import { enlacesDePestanas, enlacesDeSubpestanas, lugarEscrito, motivoSinSemana } from './navegacion'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

/** Sin las claves vacías y por orden alfabético: lo que va en la URL. */
function limpia(o: object): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(o)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => a.localeCompare(b)),
  )
}

const HOY = '2026-09-26'
const LOCAL = '11111111-1111-4111-8111-111111111111'

console.log('── Nivel 1: las pestañas ─────────────────────────────────────')
{
  const aqui = validarBusquedaMetricas(
    { vista: 'cobros', sub: 'impago-por-cuota', cuota: '2', semana: '2026-09-14', local: LOCAL },
    HOY,
  )
  const pestanas = enlacesDePestanas(aqui)
  igual(
    pestanas.map((p) => p.rotulo),
    ['Juan Pablo', 'Semana', 'Cobros', 'Riesgo', 'Caja', 'Clínicas', 'Pacientes', 'Global'],
    'las ocho, en su orden',
  )
  igual(
    pestanas.map((p) => p.actual),
    [null, null, 'seccion', null, null, null, null, null],
    'Cobros es la sección en la que se está (se ve otra sub-pestaña que la suya por defecto)',
  )
  igual(
    limpia(pestanas[3].busqueda),
    { local: LOCAL, semana: '2026-09-14', vista: 'mora' },
    'Riesgo: su primera sub-pestaña, con la misma semana y clínica, sin la cuota de Cobros',
  )
  igual(limpia(pestanas[0].busqueda), { local: LOCAL, semana: '2026-09-14' }, 'Juan Pablo no escribe su vista')
  igual(limpia(pestanas[1].busqueda), { local: LOCAL, semana: '2026-09-14', vista: 'semana' }, 'Semana sí')
  igual(
    limpia(pestanas[2].busqueda),
    { local: LOCAL, semana: '2026-09-14', vista: 'cobros' },
    'la activa lleva a su primera sub-pestaña',
  )
  igual(pestanas.map((p) => p.tono), ['gerencia', 'gerencia', 'cobranza', 'cobranza', 'caja', 'gerencia', 'gerencia', 'gerencia'], 'cada una con su tono')
}
{
  const enResumen = enlacesDePestanas(validarBusquedaMetricas({ vista: 'mora' }, HOY))
  igual(enResumen[3].actual, 'pagina', 'en la primera sub-pestaña, la pestaña es la página')
  const enLocales = enlacesDePestanas(validarBusquedaMetricas({ vista: 'locales' }, HOY))
  igual(enLocales[5].actual, 'pagina', 'una pestaña sin sub-pestañas, también')
  const sinNada = enlacesDePestanas(validarBusquedaMetricas({}, HOY))
  igual(sinNada.map((p) => p.actual), ['pagina', null, null, null, null, null, null, null], 'sin nada, Juan Pablo')
}

console.log('\n── Nivel 2: las sub-pestañas ─────────────────────────────────')
{
  const aqui = validarBusquedaMetricas(
    { vista: 'cobros', sub: 'impago-por-cuota', cuota: '2', semana: '2026-09-14', local: LOCAL },
    HOY,
  )
  const subs = enlacesDeSubpestanas(aqui)
  igual(subs.map((s) => s.rotulo), ['Semanas', 'Impago por cuota'], 'las de Cobros')
  igual(subs.map((s) => s.actual), [null, 'pagina'], 'marcada la que se ve')
  igual(subs.map((s) => s.tono), ['cobranza', 'cobranza'], 'en el tono de su pestaña')
  igual(
    limpia(subs[1].busqueda),
    { cuota: '2', local: LOCAL, semana: '2026-09-14', sub: 'impago-por-cuota', vista: 'cobros' },
    'Impago por cuota, con la misma cuota, semana y clínica',
  )
  igual(
    limpia(subs[0].busqueda),
    { cuota: '2', local: LOCAL, semana: '2026-09-14', vista: 'cobros' },
    'Semanas, la primera, sin escribirla',
  )
}
igual(enlacesDeSubpestanas(validarBusquedaMetricas({ vista: 'locales' }, HOY)), [], 'Clínicas no tiene banda')
igual(
  enlacesDeSubpestanas(validarBusquedaMetricas({ vista: 'semana' }, HOY)).map((s) => `${s.rotulo}:${s.actual ?? '-'}`),
  ['Resumen:pagina', 'Rendimiento:-'],
  'Semana, en Resumen',
)
igual(enlacesDeSubpestanas(validarBusquedaMetricas({}, HOY)), [], 'sin nada, Juan Pablo: sin banda')
igual(
  enlacesDeSubpestanas(validarBusquedaMetricas({ vista: 'cobros', sub: 'impago-por-cuota', dim: 'local' }, HOY)).map((s) =>
    limpia(s.busqueda),
  ),
  [
    { dim: 'local', vista: 'cobros' },
    { dim: 'local', sub: 'impago-por-cuota', vista: 'cobros' },
  ],
  'el «Partido por» del impago se queda al cambiar de sub-pestaña de Cobros',
)

console.log('\n── Dónde estás ───────────────────────────────────────────────')
igual(
  lugarEscrito({ vista: 'cobros', sub: 'calendario' }),
  {
    ruta: ['Cobros', 'Semanas'],
    descripcion: 'Todas las semanas comparadas: lo que hay que cobrar y cómo va, y la curva y las clínicas de la elegida.',
    tono: 'cobranza',
    periodo: 'semana',
  },
  'Cobros › Semanas, con lo que contesta',
)
igual(lugarEscrito({ vista: 'locales' }).ruta, ['Clínicas'], 'una pestaña sin sub-pestañas, solo ella')
igual(lugarEscrito({ vista: 'mora', sub: 'cupos' }).periodo, 'hoy', 'Riesgo › Cupos mira hoy')
igual(lugarEscrito({ vista: 'global' }).periodo, 'desde-el-inicio', 'Global, desde el inicio')
igual(
  motivoSinSemana('Riesgo › Cupos', 'hoy'),
  'Riesgo › Cupos es de hoy: la semana no la cambia.',
  'lo que dice el hueco de la semana',
)

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
