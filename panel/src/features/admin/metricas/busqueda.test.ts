/**
 * Pruebas de la URL de Métricas y del registro de pestañas.
 *
 *   npx tsx src/features/admin/metricas/busqueda.test.ts
 *
 * Lo que se vigila: que el registro sea el de la reorganización del 27-09
 * (siete pestañas, sus sub-pestañas y la primera por defecto), que la semana
 * llegue siempre como un lunes y nunca futura, que la semana en curso, la
 * pestaña Semana y la primera sub-pestaña no se escriban en la URL, que el
 * local sea un uuid, que cada pestaña se quede solo con sus claves, y que
 * cada enlace viejo (`vista=cohortes`, `vista=cobranza&sub=cupos`…) llegue a
 * su sitio nuevo con lo que traía.
 */
import {
  IDS_PESTANA,
  PESTANAS,
  PESTANA_POR_DEFECTO,
  definicionDe,
  descripcionDelLugar,
  idsDeSubpestanas,
  nombreDelLugar,
  periodoDe,
  subPorDefecto,
  subpestanasDe,
} from './pestanas'
import {
  VALIDADORES,
  busquedaDeMetricas,
  busquedaDelLugar,
  comunDe,
  lugarDe,
  propiaDe,
  semanaDeLaUrl,
  semanaElegida,
  subDe,
  traducirEnlaceViejo,
  validarBusquedaMetricas,
  vistaDe,
  vistaDeLaUrl,
} from './busqueda'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

/**
 * Sin las claves que valen `undefined` —así se escribe en la URL— y por orden
 * alfabético, para comparar sin depender del orden en que se armó.
 */
function limpia(o: object): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(o)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => a.localeCompare(b)),
  )
}

/** La URL que acaba escrita al validar `raw`. */
function url(raw: Record<string, unknown>): Record<string, unknown> {
  return limpia(validarBusquedaMetricas(raw, HOY))
}

// Hoy es el sábado 26 de septiembre de 2026 (día operativo): su lunes es el 21.
const HOY = '2026-09-26'
const UUID = '0B6F6C1E-3D7A-4F3E-9D2A-1C2B3A4D5E6F'
const LOCAL = UUID.toLowerCase()

console.log('── El registro (Javier, 27-09) ───────────────────────────────')
igual(
  IDS_PESTANA,
  ['semana', 'cobros', 'mora', 'caja', 'locales', 'gente', 'global'],
  'las siete pestañas, en su orden',
)
igual(
  PESTANAS.map((p) => p.titulo),
  ['Semana', 'Cobros', 'Riesgo', 'Caja', 'Clínicas', 'Pacientes', 'Global'],
  'con sus rótulos',
)
igual(PESTANA_POR_DEFECTO, 'semana', 'Semana es la de por defecto')
igual(
  Object.fromEntries(IDS_PESTANA.map((id) => [id, idsDeSubpestanas(id)])),
  {
    semana: ['resumen', 'rendimiento'],
    cobros: ['calendario', 'impago-por-cuota'],
    mora: ['resumen', 'cupos', 'rendimiento'],
    caja: ['balance', 'proyeccion'],
    locales: [],
    gente: ['resumen', 'uso', 'retencion'],
    global: [],
  },
  'las sub-pestañas de cada una, en su orden',
)
igual(
  IDS_PESTANA.map((id) => subpestanasDe(id).map((s) => s.titulo).join(' · ')),
  [
    'Resumen · Rendimiento',
    'Semanas · Impago por cuota',
    'Resumen · Cupos · Rendimiento',
    'Balance · Proyección y banco',
    '',
    'Resumen · Uso · Retención',
    '',
  ],
  'con sus rótulos',
)
igual(
  IDS_PESTANA.map((id) => subPorDefecto(id) ?? null),
  ['resumen', 'calendario', 'resumen', 'balance', null, 'resumen', null],
  'la primera es la de por defecto; Clínicas y Global no tienen',
)
{
  const sinDescripcion = PESTANAS.flatMap((p) =>
    [p.descripcion, ...p.subpestanas.map((s) => s.descripcion)].filter((d) => d.trim() === '').map(() => p.id),
  )
  igual(sinDescripcion, [], 'toda pestaña y sub-pestaña dice qué contesta')
  const largas = PESTANAS.flatMap((p) => p.subpestanas.filter((s) => s.descripcion.length > 130).map((s) => `${p.id}/${s.id}`))
  igual(largas, [], 'y en una línea (130 caracteres como mucho)')
  const conServicio = PESTANAS.flatMap((p) =>
    [p.titulo, p.pregunta, p.descripcion, ...p.subpestanas.flatMap((s) => [s.titulo, s.descripcion])].filter((t) =>
      /servicio/i.test(t),
    ),
  )
  igual(conServicio, [], 'el fee se llama «service fee» o «fee», nunca «servicio»')
}
igual(
  PESTANAS.map((p) => p.tono),
  ['gerencia', 'cobranza', 'cobranza', 'caja', 'gerencia', 'gerencia', 'gerencia'],
  'cada pestaña en el tono de su área',
)
igual(
  definicionDe('cobros').subpestanas.map((s) => s.carpeta),
  ['cohortes', 'cobranza'],
  'Cobros lo pintan Cohortes y Cobranza (el impago); Avisos se mudó a Notificaciones',
)
igual(definicionDe('mora').subpestanas.map((s) => s.carpeta), ['cobranza', 'cobranza', 'cobranza'], 'Riesgo, entero de Cobranza')
igual(definicionDe('global').carpeta, 'general', 'Global, una sola vista de General')
igual(Object.keys(VALIDADORES).sort(), [...IDS_PESTANA].sort(), 'toda pestaña tiene su validador')

console.log('\n── El periodo de cada sitio ──────────────────────────────────')
igual(periodoDe('semana', 'resumen'), 'semana', 'Semana mira la semana')
igual(periodoDe('global'), 'desde-el-inicio', 'Global, desde el inicio')
igual(periodoDe('mora', 'cupos'), 'hoy', 'Riesgo › Cupos, hoy')
igual(periodoDe('cobros', 'impago-por-cuota'), 'semana', 'Cobros › Impago por cuota, hasta la semana elegida')
igual(periodoDe('caja', 'proyeccion'), 'hoy', 'Caja › Proyección, desde hoy')
igual(periodoDe('locales'), 'semana', 'Clínicas, la semana')

console.log('\n── El nombre de un sitio ─────────────────────────────────────')
igual(nombreDelLugar({ vista: 'cobros', sub: 'impago-por-cuota' }), 'Cobros › Impago por cuota', 'pestaña › sub-pestaña')
igual(nombreDelLugar({ vista: 'mora' }), 'Riesgo › Resumen', 'sin sub, la primera')
igual(nombreDelLugar({ vista: 'locales' }), 'Clínicas', 'sin sub-pestañas, solo la pestaña')
igual(
  descripcionDelLugar({ vista: 'cobros', sub: 'calendario' }),
  'Todas las semanas comparadas: lo que hay que cobrar y cómo va, y la curva y las clínicas de la elegida.',
  'lo que contesta, con las palabras de Javier',
)

console.log('\n── La semana ─────────────────────────────────────────────────')
igual(semanaDeLaUrl('2026-09-14', HOY), '2026-09-14', 'un lunes pasado, tal cual')
igual(semanaDeLaUrl('2026-09-17', HOY), '2026-09-14', 'un jueves, a su lunes')
igual(semanaDeLaUrl('2026-09-20', HOY), '2026-09-14', 'un domingo, al lunes de SU semana')
igual(semanaDeLaUrl('2026-09-21', HOY), undefined, 'la semana en curso no se escribe')
igual(semanaDeLaUrl('2026-09-24', HOY), undefined, 'un día de la semana en curso, tampoco')
igual(semanaDeLaUrl('2026-10-05', HOY), undefined, 'una semana futura es la en curso')
igual(semanaDeLaUrl('2026-02-30', HOY), undefined, 'un día que no existe no pasa')
igual(semanaDeLaUrl('ayer', HOY), undefined, 'un texto cualquiera no pasa')
igual(semanaDeLaUrl(20260914, HOY), undefined, 'un número no es un día')
igual(semanaDeLaUrl('2025-12-31', HOY), '2025-12-29', 'cruza de año: el lunes es del año anterior')

igual(
  semanaElegida(undefined, HOY),
  { lunes: '2026-09-21', domingo: '2026-09-27', enCurso: true, lunesHoy: '2026-09-21' },
  'sin semana, la en curso',
)
igual(
  semanaElegida('2026-09-14', HOY),
  { lunes: '2026-09-14', domingo: '2026-09-20', enCurso: false, lunesHoy: '2026-09-21' },
  'con semana, esa',
)
igual(semanaElegida(undefined, '2026-09-21').lunes, '2026-09-21', 'el lunes (día operativo) ya es la semana nueva')

console.log('\n── La vista, la sub-pestaña y la clínica ───────────────────────')
igual(vistaDeLaUrl(undefined), 'semana', 'sin vista, Semana')
igual(vistaDeLaUrl('caja'), 'caja', 'una vista que existe')
igual(vistaDeLaUrl('dinero'), 'semana', 'una que no existe, Semana')

igual(url({ vista: 'semana' }), {}, '?vista=semana no se escribe: es la de por defecto')
igual(url({ vista: 'semana', sub: 'resumen' }), {}, 'ni su primera sub-pestaña')
igual(url({ sub: 'rendimiento' }), { sub: 'rendimiento' }, 'Semana › Rendimiento es solo ?sub=rendimiento')
igual(url({ vista: 'cobros', sub: 'impago-por-cuota' }), { sub: 'impago-por-cuota', vista: 'cobros' }, 'una sub-pestaña que no es la primera, sí')
igual(url({ vista: 'cobros', sub: 'avisos' }), { vista: 'cobros' }, 'Avisos ya no es de Cobros (la ruta la lleva antes a Notificaciones › Rendimiento)')
igual(url({ vista: 'mora', sub: 'resumen' }), { vista: 'mora' }, 'la primera no se escribe')
igual(url({ vista: 'mora', sub: 'calendario' }), { vista: 'mora' }, 'una sub-pestaña de otra pestaña se cae: la primera')
igual(url({ vista: 'locales', sub: 'resumen' }), { vista: 'locales' }, 'Clínicas no tiene sub-pestañas')
igual(url({ vista: 'global', local: UUID }), { local: LOCAL, vista: 'global' }, 'la clínica, un uuid en minúsculas')
igual(url({ vista: 'global', local: 'la-quinta' }), { vista: 'global' }, 'una clínica que no es un uuid no pasa')
igual(url({ vista: 'cobros', semana: '2026-09-10' }), { semana: '2026-09-07', vista: 'cobros' }, 'la semana, a su lunes')

console.log('\n── Cada pestaña, solo con lo suyo ────────────────────────────')
igual(url({ vista: 'caja', sub: 'proyeccion', horizonte: '8' }), { horizonte: '8', sub: 'proyeccion', vista: 'caja' }, 'Caja se queda su horizonte')
igual(url({ vista: 'gente', horizonte: '8' }), { vista: 'gente' }, 'lo de otra pestaña se cae')
igual(url({ vista: 'cobros', cuota: '2' }), { cuota: '2', vista: 'cobros' }, 'Cobros › Semanas se queda la cuota de la curva')
igual(
  url({ vista: 'cobros', sub: 'impago-por-cuota', cuota: 2, dim: 'local' }),
  { cuota: '2', dim: 'local', sub: 'impago-por-cuota', vista: 'cobros' },
  'Impago por cuota, su cuota y su «Partido por»',
)
igual(url({ vista: 'mora', dim: 'local', cuota: 2 }), { vista: 'mora' }, 'Riesgo no tiene claves propias')
igual(url({ vista: 'cobros', modo: 'todas', sub: 'resumen' }), { vista: 'cobros' }, '«modo» ya no es de nadie')

console.log('\n── Los enlaces viejos llegan a su sitio ──────────────────────')
igual(url({ vista: 'general' }), { vista: 'global' }, 'General → Global')
igual(url({ vista: 'global', sub: 'resumen' }), { vista: 'global' }, 'Global › Resumen → Global, que ya no tiene sub-pestañas')
igual(url({ vista: 'global', sub: 'cupos', local: UUID }), { local: LOCAL, sub: 'cupos', vista: 'mora' }, 'Global › Cupos → Riesgo › Cupos, con su clínica')
igual(url({ vista: 'cobros', sub: 'recordatorios', cuota: '2' }), { cuota: '2', vista: 'cobros' }, 'Cobros › Recordatorios: la ruta la lleva antes a Notificaciones')
igual(url({ vista: 'general', local: UUID }), { local: LOCAL, vista: 'global' }, 'con su clínica')
igual(url({ vista: 'cohortes' }), { vista: 'cobros' }, 'Cohortes → Cobros (la ruta lo lleva antes a Por cobrar › Cohortes)')
igual(url({ vista: 'cohortes', modo: 'una', cuota: '2', semana: '2026-09-14' }), { cuota: '2', semana: '2026-09-14', vista: 'cobros' }, 'Cohortes › Una semana, con su cuota y su semana')
igual(url({ vista: 'cohortes', modo: 'todas' }), { vista: 'cobros' }, 'Cohortes › Comparar todas → Cobros › Semanas, la primera')
igual(url({ vista: 'avisos', semana: '2026-09-14' }), { semana: '2026-09-14' }, 'Avisos, igual: la ruta la lleva antes a Notificaciones')
igual(url({ vista: 'cobranza' }), { vista: 'mora' }, 'Cobranza y riesgo → Riesgo')
igual(url({ vista: 'cobranza', sub: 'resumen' }), { vista: 'mora' }, '… › Resumen → Riesgo › Resumen')
igual(url({ vista: 'cobranza', sub: 'rendimiento' }), { sub: 'rendimiento', vista: 'mora' }, '… › Rendimiento')
igual(
  url({ vista: 'cobranza', sub: 'primera-cuota', cuota: 2, dim: 'nivel' }),
  { cuota: '2', dim: 'nivel', sub: 'impago-por-cuota', vista: 'cobros' },
  '… › Primera cuota → Cobros › Impago por cuota, con su cuota y su «Partido por»',
)
igual(
  url({ vista: 'mora', sub: 'impago-por-cuota', cuota: 2, semana: '2026-09-14' }),
  { cuota: '2', semana: '2026-09-14', sub: 'impago-por-cuota', vista: 'cobros' },
  'Mora › Impago por cuota → Cobros, con su cuota y su semana',
)
igual(url({ vista: 'cobranza', sub: 'cupos', local: UUID }), { local: LOCAL, sub: 'cupos', vista: 'mora' }, '… › Cupos → Riesgo › Cupos, con su clínica')
igual(traducirEnlaceViejo({ vista: 'caja', sub: 'balance', semana: 'x' }), { vista: 'caja', sub: 'balance', semana: 'x' }, 'lo que no es viejo pasa tal cual')
{
  // TanStack mezcla la URL cruda con lo validado: lo que no es de nadie tiene
  // que volver como `undefined` para que el router lo quite de la URL.
  const b: Record<string, unknown> = validarBusquedaMetricas({ vista: 'cohortes', modo: 'todas', otra: '1', horizonte: '8' }, HOY)
  igual(
    ['modo', 'otra', 'horizonte'].map((k) => [k in b, b[k]]),
    [
      [true, undefined],
      [true, undefined],
      [true, undefined],
    ],
    'las claves sueltas (el «modo» viejo, una de otra pestaña) vuelven vacías y se caen de la URL',
  )
}

console.log('\n── Armar y desarmar ──────────────────────────────────────────')
{
  const b = validarBusquedaMetricas(
    { vista: 'cobros', sub: 'impago-por-cuota', dim: 'nivel', semana: '2026-09-14', local: UUID },
    HOY,
  )
  igual(vistaDe(b), 'cobros', 'la vista de una búsqueda')
  igual(subDe('cobros', b), 'impago-por-cuota', 'la sub-pestaña de una búsqueda')
  igual(lugarDe(b), { vista: 'cobros', sub: 'impago-por-cuota' }, 'su sitio')
  igual(comunDe(b), { semana: '2026-09-14', local: LOCAL }, 'lo común de una búsqueda')
  igual(limpia(propiaDe('cobros', b)), { dim: 'nivel' }, 'lo propio, sin lo del marco')
  igual(
    limpia(busquedaDeMetricas('caja', VALIDADORES.caja({}), comunDe(b))),
    { local: LOCAL, semana: '2026-09-14', vista: 'caja' },
    'cambiar de pestaña conserva la semana y la clínica y suelta lo de la anterior',
  )
  igual(limpia(busquedaDeMetricas('semana', VALIDADORES.semana({}), {})), {}, 'Semana sin nada es la URL desnuda')
  igual(
    limpia(busquedaDeMetricas('semana', VALIDADORES.semana({}), {}, 'resumen')),
    {},
    'Semana › Resumen, también: la primera sub-pestaña no se escribe',
  )
  igual(lugarDe(validarBusquedaMetricas({}, HOY)), { vista: 'semana', sub: 'resumen' }, 'sin nada, Semana › Resumen')
  igual(lugarDe(validarBusquedaMetricas({ vista: 'locales' }, HOY)), { vista: 'locales' }, 'Clínicas, sin sub')
  igual(
    limpia(busquedaDelLugar({ vista: 'mora', sub: 'cupos' }, { local: LOCAL })),
    { local: LOCAL, sub: 'cupos', vista: 'mora' },
    'un sitio con el misma clínica',
  )
  igual(limpia(busquedaDelLugar({ vista: 'caja', sub: 'balance' })), { vista: 'caja' }, 'un sitio en su primera sub-pestaña')
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
