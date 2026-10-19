/**
 * Pruebas del catálogo del super admin y de su búsqueda.
 *
 *   npx tsx src/features/admin/catalogo/catalogo.test.ts
 *
 * Sin framework, como el resto. Lo que se comprueba aquí no lo ve el
 * compilador: un id repetido, un título vacío, una pantalla que nadie puso en
 * el menú, o una búsqueda que deja de encontrar lo que la gente teclea.
 */
import { superAdminNavGroups, superAdminNavPie } from '@/config/navigation'
import { IDS_PESTANA } from '@/features/admin/metricas/pestanas'
import { CATALOGO, PANTALLAS, buscarEnCatalogo, normalizar } from './index'
import { ajustes } from './ajustes'
import { caja } from './caja'
import { cobranza } from './cobranza'
import { directorio } from './directorio'
import { gerencia } from './gerencia'
import { glosario } from './glosario'
import { inicio } from './inicio'
import { riesgo } from './riesgo'
import { pantallasDeMetricas } from './metricas/pantallas'
import type { Entrada } from './tipos'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

/** Los ids de todo lo que devuelve una búsqueda, sin agrupar. */
function ids(texto: string): string[] {
  const r = buscarEnCatalogo(texto)
  return [...r.pantallas, ...r.acciones, ...r.cifras, ...r.terminos].map((e) => e.id)
}

console.log('── El catálogo está bien formado ────────────────────────────')
{
  const vistos = new Set<string>()
  const repetidos = CATALOGO.map((e) => e.id).filter((id) => {
    const ya = vistos.has(id)
    vistos.add(id)
    return ya
  })
  comprueba(repetidos.length === 0, 'no hay ids repetidos', repetidos.join(', '))

  const sinTitulo = CATALOGO.filter((e) => e.titulo.trim() === '').map((e) => e.id)
  comprueba(sinTitulo.length === 0, 'ningún título vacío', sinTitulo.join(', '))

  const sinDescripcion = CATALOGO.filter((e) => e.descripcion.trim() === '').map((e) => e.id)
  comprueba(sinDescripcion.length === 0, 'ninguna descripción vacía', sinDescripcion.join(', '))

  const cifrasCojas = CATALOGO.filter(
    (e) => e.tipo === 'cifra' && (!e.que.trim() || !e.rpc.startsWith('admin_')),
  ).map((e) => e.id)
  comprueba(cifrasCojas.length === 0, 'toda cifra dice qué es y de qué RPC sale', cifrasCojas.join(', '))

  const terminos = CATALOGO.filter((e) => e.tipo === 'termino')
  comprueba(
    terminos.length >= 20,
    `el glosario tiene al menos 20 términos (${terminos.length})`,
    `solo ${terminos.length}`,
  )

  // Las cifras del negocio no se escriben como número: cambian sin tocar esto.
  const conCifraEscrita = CATALOGO.filter((e) =>
    /\b\d+ d[ií]as\b|\$\s?\d/.test(
      `${e.descripcion} ${e.tipo === 'termino' ? e.definicion : ''} ${e.tipo === 'cifra' ? e.que : ''}`,
    ),
  ).map((e) => e.id)
  comprueba(
    conCifraEscrita.length === 0,
    'ninguna definición escribe plazos ni montos del negocio',
    conCifraEscrita.join(', '),
  )
}

console.log('\n── El menú sale del catálogo ────────────────────────────────')
{
  // El pie (la ruta de QA) también es menú.
  const enElMenu = [...superAdminNavGroups.flatMap((g) => g.items), ...superAdminNavPie].map((i) => i.path)
  const fuera = PANTALLAS.filter((p) => !enElMenu.includes(p.destino.to)).map((p) => p.id)
  comprueba(fuera.length === 0, 'toda pantalla del catálogo está en el menú', fuera.join(', '))

  const repetidas = enElMenu.filter((p, i) => enElMenu.indexOf(p) !== i)
  comprueba(repetidas.length === 0, 'ninguna ruta sale dos veces en el menú', repetidas.join(', '))

  const orden = superAdminNavGroups.map((g) => g.espacio)
  comprueba(
    orden.join(' ') === 'inicio cobranza caja directorio ajustes',
    'el menú va siempre en el mismo orden: Inicio y Métricas, Cobranza y riesgo, Caja y contabilidad, Directorio y Ajustes',
    orden.join(' '),
  )

  const arriba = superAdminNavGroups.at(0)
  comprueba(
    arriba !== undefined &&
      arriba.title === undefined &&
      arriba.items.map((i) => i.label).join(', ') === 'Inicio, Métricas',
    'Inicio y Métricas van sueltas arriba, sin rótulo',
    JSON.stringify(arriba?.items.map((i) => i.label)),
  )

  const bloques = superAdminNavGroups
    .filter((g) => g.title)
    .map((g) => `${g.title}: ${g.items.map((i) => i.label).join(', ')}`)
  comprueba(
    bloques.join(' | ') ===
      'Cobranza y riesgo: Por cobrar, Pagos reportados, Avisos, WhatsApp, Alertas | ' +
        'Caja y contabilidad: Pagos a clínicas, Libro y cierre de mes | ' +
        'Directorio: Pacientes, Clínicas, Financiamientos | Ajustes: Ajustes',
    'los bloques del menú, con sus pantallas en orden (CONTRATOS §1)',
    bloques.join(' | '),
  )

  comprueba(
    superAdminNavGroups.every((g) => g.espacio === 'inicio' || g.title),
    'todo bloque menos Inicio lleva rótulo, que es lo que se pulsa para plegarlo',
  )

  const abonos = PANTALLAS.find((p) => p.id === 'abonos-sin-dueno')
  comprueba(
    abonos?.destino.to === '/admin/cobros' && abonos.destino.search?.vista === 'abonos',
    'Abonos sin dueño apunta a su pestaña de Pagos reportados',
    JSON.stringify(abonos?.destino),
  )

  const niveles = PANTALLAS.find((p) => p.id === 'niveles-y-cupos')
  comprueba(
    niveles?.destino.to === '/admin/ajustes' && niveles.destino.search?.tab === 'niveles',
    'Niveles y cupos es una sección de Ajustes',
    JSON.stringify(niveles?.destino),
  )

  const promesas = PANTALLAS.find((p) => p.id === 'promesas')
  comprueba(
    promesas?.destino.to === '/admin/cobranza' && promesas.destino.search?.vista === 'promesas',
    'Promesas apunta a su pestaña de Por cobrar',
    JSON.stringify(promesas?.destino),
  )
}

console.log('\n── Métricas ─────────────────────────────────────────────────')
{
  const deMetricas = PANTALLAS.filter((p) => p.destino.to === '/admin/metricas')
  comprueba(
    deMetricas[0]?.id === 'metricas',
    'la primera pantalla de /admin/metricas es Métricas, que es la dueña de la ruta',
    deMetricas.map((p) => p.id).join(', '),
  )
  // Cada sub-pestaña, su nombre y su destino: `metricas/destinos.test.ts`.
  for (const id of IDS_PESTANA) {
    const p = PANTALLAS.find((x) => x.id === `metricas-${id}`)
    const vista = p?.destino.to === '/admin/metricas' ? (p.destino.search?.vista ?? 'semana') : null
    comprueba(vista === id, `la pestaña ${id} tiene su pantalla y lleva a su vista`, JSON.stringify(p?.destino))
  }
  comprueba(
    PANTALLAS.filter((p) => p.destino.to === '/admin/metricas').every((p) => p.espacio === 'metricas'),
    'todo lo de /admin/metricas es del ámbito de Métricas',
  )


  const primera = (texto: string) => buscarEnCatalogo(texto).pantallas[0]?.id
  comprueba(primera('metricas') === 'metricas', '«metricas» encuentra Métricas', String(primera('metricas')))
  // Cinco pestañas tienen su «Resumen»: salen todos, y el de Semana (donde
  // redirige la pantalla vieja) entre ellos.
  comprueba(
    buscarEnCatalogo('resumen').pantallas.some((p) => p.id === 'metricas-semana-resumen'),
    '«resumen» (nombre viejo) encuentra Métricas › Semana › Resumen',
    buscarEnCatalogo('resumen').pantallas.map((p) => p.id).join(', '),
  )
  comprueba(primera('crecimiento') === 'metricas-gente', '«crecimiento» lleva a Métricas › Pacientes', String(primera('crecimiento')))
  comprueba(
    primera('riesgo de credito') === 'metricas-mora',
    '«riesgo de credito» lleva a Métricas › Riesgo',
    String(primera('riesgo de credito')),
  )
  comprueba(primera('dinero') === 'metricas-caja', '«dinero» lleva a Métricas › Caja', String(primera('dinero')))

  // Los nombres de antes de la reorganización del 27-09 siguen encontrando su sitio.
  comprueba(primera('cohortes') === 'por-cobrar-por-semana', '«cohortes» lleva a Por cobrar › Cohortes', String(primera('cohortes')))
  comprueba(
    buscarEnCatalogo('cohortes').pantallas.some((p) => p.id === 'metricas-cobros'),
    '«cohortes» encuentra también Métricas › Cobros',
    buscarEnCatalogo('cohortes').pantallas.map((p) => p.id).join(', '),
  )
  comprueba(
    primera('comparar todas') === 'metricas-cobros-calendario',
    '«comparar todas» lleva a Métricas › Cobros › Semanas',
    String(primera('comparar todas')),
  )
  comprueba(
    buscarEnCatalogo('avisos').pantallas.some((p) => p.id === 'avisos'),
    '«avisos» encuentra Avisos (la cola de WhatsApp y las plantillas)',
    buscarEnCatalogo('avisos').pantallas.map((p) => p.id).join(', '),
  )
  comprueba(
    primera('cobranza y riesgo') === 'metricas-mora',
    '«cobranza y riesgo» lleva a Métricas › Riesgo',
    String(primera('cobranza y riesgo')),
  )
  comprueba(primera('general') === 'metricas-global', '«general» lleva a Métricas › Global', String(primera('general')))
  comprueba(
    primera('primera cuota') === 'metricas-cobros-impago-por-cuota',
    '«primera cuota» lleva a Cobros › Impago por cuota',
    String(primera('primera cuota')),
  )
  comprueba(
    buscarEnCatalogo('cupos').pantallas.some((p) => p.id === 'metricas-mora-cupos'),
    '«cupos» encuentra Métricas › Riesgo › Cupos',
    buscarEnCatalogo('cupos').pantallas.map((p) => p.id).join(', '),
  )
  comprueba(
    buscarEnCatalogo('calendario').pantallas.some((p) => p.id === 'metricas-cobros-calendario'),
    '«calendario» encuentra Métricas › Cobros › Semanas, que se llamaba así',
    buscarEnCatalogo('calendario').pantallas.map((p) => p.id).join(', '),
  )
  comprueba(
    buscarEnCatalogo('quién debe de esta semana').pantallas[0]?.id === 'por-cobrar-por-semana',
    '«quién debe de esta semana» lleva a Por cobrar › Cohortes',
    buscarEnCatalogo('quién debe de esta semana').pantallas.map((p) => p.id).join(', '),
  )
  comprueba(primera('niveles') === 'niveles-y-cupos', '«niveles» lleva a Ajustes › Niveles y cupos', String(primera('niveles')))
}

console.log('\n── La búsqueda ──────────────────────────────────────────────')
comprueba(normalizar('  Dueño   ÁRBOL ') === 'dueno arbol', 'normaliza tildes, eñes, mayúsculas y espacios')

comprueba(
  buscarEnCatalogo('extracto').acciones.some((a) => a.id === 'importar-extracto'),
  '«extracto» encuentra «Importar el extracto del banco»',
  ids('extracto').join(', '),
)
comprueba(
  buscarEnCatalogo('kyc').pantallas.length === 0,
  '«kyc» no encuentra ninguna pantalla: Helios no verifica identidades',
  ids('kyc').join(', '),
)
comprueba(
  ids('estado de cuenta').includes('importar-extracto'),
  '«estado de cuenta» también encuentra el extracto',
  ids('estado de cuenta').join(', '),
)
comprueba(
  ids('ESTADO DE CUENTA').includes('importar-extracto'),
  'sin importar las mayúsculas',
)
comprueba(
  buscarEnCatalogo('abonos sin dueno').pantallas[0]?.id === 'abonos-sin-dueno',
  '«abonos sin dueno», sin la eñe, encuentra Abonos sin dueño',
  ids('abonos sin dueno').join(', '),
)
comprueba(
  buscarEnCatalogo('cartera').pantallas[0]?.id === 'cartera-vencida' &&
    buscarEnCatalogo('cartera').pantallas.some((p) => p.id === 'metricas-mora'),
  '«cartera», el nombre viejo, sigue llevando a Por cobrar antes que a Métricas › Riesgo',
  buscarEnCatalogo('cartera').pantallas.map((p) => p.id).join(', '),
)
{
  // «Cobros» es hoy una pestaña de Métricas (Javier, 27-09) y su título manda
  // sobre el sinónimo viejo de Pagos reportados, que sigue saliendo: justo
  // detrás de las cinco pantallas de Cobros (la pestaña y sus cuatro
  // sub-pestañas), así que se mira con sitio para una más.
  const r = buscarEnCatalogo('cobros', { limite: 6 })
  comprueba(
    r.pantallas[0]?.id === 'metricas-cobros' && r.pantallas.some((p) => p.id === 'pagos-reportados'),
    '«cobros» lleva a Métricas › Cobros, y Pagos reportados (su nombre viejo) sigue saliendo',
    r.pantallas.map((p) => p.id).join(', '),
  )
}
comprueba(
  ids('castigado').includes('dado-por-perdido'),
  '«castigado» encuentra Dado por perdido',
  ids('castigado').join(', '),
)
comprueba(
  ids('calendario de cobro').includes('por-cobrar-por-dia') &&
    ids('lo que vence').includes('por-cobrar-por-dia'),
  '«calendario de cobro» y «lo que vence» encuentran Por cobrar por día',
  ids('calendario de cobro').join(', '),
)

console.log('\n── El fee se llama «service fee» (Javier, 27-09) ──────────────')
{
  // Lo que se LEE: título, descripción, qué es y definición. Los sinónimos
  // guardan «servicio» y «comisión» a propósito, para que la búsqueda vieja
  // siga encontrando. Solo los ficheros de primer nivel: los de cada pestaña
  // de Métricas son de su dueño.
  const primerNivel: ReadonlyArray<Entrada> = [
    ...ajustes,
    ...caja,
    ...cobranza,
    ...directorio,
    ...gerencia,
    ...glosario,
    ...inicio,
    ...riesgo,
    ...pantallasDeMetricas,
  ]
  const leido = (e: Entrada) =>
    [e.titulo, e.descripcion, e.tipo === 'cifra' ? e.que : '', e.tipo === 'termino' ? e.definicion : ''].join(' ')
  // «servicio» a secas es el fee; «el servicio de Fly.io» o «cuenta de
  // servicio» no lo son, pero aquí no sale ninguno.
  const conServicio = primerNivel.filter((e) => /\bservicio\b/i.test(leido(e))).map((e) => e.id)
  comprueba(conServicio.length === 0, 'ninguna entrada llama «servicio» al fee', conServicio.join(', '))
  // La comisión que queda es la de la clínica, que no es el service fee.
  const conComision = primerNivel
    .filter((e) => /comisi[oó]n(?! de la clínica)/i.test(leido(e).replace(/la comisión y cuándo se le paga/, '')))
    .map((e) => e.id)
  comprueba(conComision.length === 0, 'ninguna entrada llama «comisión» al fee', conComision.join(', '))
}
comprueba(ids('servicio').includes('servicio-ronda'), '«servicio», el nombre viejo, encuentra Service fee', ids('servicio').join(', '))
comprueba(ids('service fee').includes('servicio-ronda'), '«service fee» encuentra su entrada del glosario', ids('service fee').join(', '))
comprueba(
  ids('servicio ganado').includes('comision-ganada') && ids('comisión').includes('comision-ganada'),
  '«servicio ganado» y «comisión» siguen llevando a Service fee ganado, sin IVA',
  ids('servicio ganado').join(', '),
)
comprueba(ids('sin fee').includes('consumo'), '«sin fee» encuentra qué es un financiamiento sin fee', ids('sin fee').join(', '))

comprueba(
  buscarEnCatalogo('   ').total === 0 && buscarEnCatalogo('').total === 0,
  'una búsqueda vacía no devuelve nada',
)
comprueba(
  buscarEnCatalogo('a', { limite: 2 }).pantallas.length <= 2,
  'el límite se respeta por grupo',
)

console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
process.exit(fallos === 0 ? 0 : 1)
