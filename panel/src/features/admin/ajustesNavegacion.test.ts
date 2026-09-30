/**
 * Pruebas de la URL de Ajustes.
 *
 *   npx tsx src/features/admin/ajustesNavegacion.test.ts
 *
 * Lo que se vigila: que cada `?tab=` de una sección llegue a su sitio, que lo
 * podado de Ronda (versión de la app, eliminaciones, QA) ya no exista, y que
 * los filtros de cada sección pasen validados o no pasen.
 */
import {
  GRUPOS_AJUSTES,
  PESTANAS_AJUSTES,
  leerBusquedaAjustes,
  pestanaActiva,
  rotuloDePestana,
} from './ajustesNavegacion'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── Las secciones ─────────────────────────────────────────────')
comprueba(PESTANAS_AJUSTES.length === 10, 'diez secciones', String(PESTANAS_AJUSTES.length))
for (const podada of ['promociones', 'version', 'eliminaciones', 'qa']) {
  comprueba(!PESTANAS_AJUSTES.includes(podada as never), `${podada} ya no es de Ajustes`)
}
comprueba(
  GRUPOS_AJUSTES[0]?.secciones.map((s) => s.value).join() === 'tasa,parametros,niveles,feriados,cobro',
  'Niveles y cupos es una regla, junto a los parámetros',
  GRUPOS_AJUSTES[0]?.secciones.map((s) => s.value).join(),
)
comprueba(
  new Set(PESTANAS_AJUSTES).size === PESTANAS_AJUSTES.length,
  'ninguna sección se repite',
)
comprueba(
  GRUPOS_AJUSTES.map((g) => g.titulo).join(',') === 'Reglas,El comprobante,Equipo,Registro,Emergencia',
  'los cinco grupos, en su orden',
  GRUPOS_AJUSTES.map((g) => g.titulo).join(','),
)
comprueba(
  GRUPOS_AJUSTES.find((g) => g.tono === 'error')?.secciones.map((s) => s.value).join() ===
    'mantenimiento',
  'solo Mantenimiento va en rojo',
)
comprueba(rotuloDePestana('cobro') === 'Cuenta de cobro', 'el rótulo de una sección')
comprueba(rotuloDePestana('terminos') === 'Condiciones', 'los términos son las condiciones del comprobante')

console.log('\n── ?tab= ──────────────────────────────────────────────────────')
for (const tab of PESTANAS_AJUSTES) {
  comprueba(leerBusquedaAjustes({ tab }).tab === tab, `?tab=${tab} pasa`)
}
comprueba(leerBusquedaAjustes({ tab: 'foo' }).tab === undefined, '?tab=foo no pasa')
comprueba(leerBusquedaAjustes({ tab: 'version' }).tab === undefined, '?tab=version (podada) no pasa')
comprueba(pestanaActiva(undefined) === 'tasa', 'sin tab, la tasa')
comprueba(pestanaActiva('niveles') === 'niveles', 'Niveles y cupos, ella misma')
comprueba(pestanaActiva('bitacora') === 'bitacora', 'una sección, ella misma')

console.log('\n── Los filtros ───────────────────────────────────────────────')
const bien = leerBusquedaAjustes({
  tab: 'bitacora',
  tema: 'cobranza',
  quien: '839BBA23-640E-4F57-9280-C814013233BC',
  desde: '2026-09-01',
  hasta: '2026-09-30',
  pagina: '3',
})
comprueba(bien.tema === 'cobranza', 'un tema de la bitácora pasa', String(bien.tema))
comprueba(
  bien.quien === '839bba23-640e-4f57-9280-c814013233bc',
  'quién: un uuid, en minúsculas',
  String(bien.quien),
)
comprueba(bien.desde === '2026-09-01' && bien.hasta === '2026-09-30', 'las fechas pasan')
comprueba(bien.pagina === 3, 'la página llega como número', String(bien.pagina))

const mal = leerBusquedaAjustes({
  tema: 'pagos-usuarios',
  quien: 'Javier',
  desde: '2026-02-30',
  pagina: 1,
  anio: 1999,
})
comprueba(mal.tema === undefined, 'un tema que ya no existe no pasa', String(mal.tema))
comprueba(mal.quien === undefined, 'quién que no es un uuid no pasa')
comprueba(mal.desde === undefined, 'un día que no existe no pasa')
comprueba(mal.pagina === undefined, 'la página 1 no se escribe')
comprueba(mal.anio === undefined, 'un año fuera de rango no pasa')
comprueba(leerBusquedaAjustes({ anio: 2027 }).anio === 2027, 'un año válido pasa')

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
