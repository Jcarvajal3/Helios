/**
 * Pruebas de los deudores por comportamiento: la lectura de
 * `admin_deudores_por_perfil`, los textos de cada perfil y la frase.
 *
 *   npx tsx src/features/admin/metricas/cobranza/deudores.test.ts
 *
 * Lo que se vigila: que un perfil que no viene salga con su cero (y no
 * desaparezca), que una persona con un perfil desconocido no se cuele, que el
 * orden sea el de la cola, que un importe traiga siempre su desglose, que
 * «sin historia» no se lea como un 0 % de recuperación y que los textos
 * digan los umbrales de la base y no unos escritos a mano.
 */
import { leerDeudores, textoDeRecuperacion } from './deudores'
import { PERFILES_DEUDOR, UMBRALES_DEL_CONTRATO, estaEnMora, queEsElPerfil } from './perfiles'
import { cuotaDe, validarCobranza, validarImpago } from './busqueda'

let fallos = 0

function igual<T>(dio: T, esperado: T, titulo: string) {
  const a = JSON.stringify(dio)
  const b = JSON.stringify(esperado)
  const ok = a === b
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — dio ${a}, se esperaba ${b}`}`)
}

const persona = (orden: number, perfil: string, extra: Record<string, unknown> = {}) => ({
  user_id: `u${orden}`,
  nombre: `Paciente ${orden}`,
  telefono: '584120000000',
  estado: 'frozen',
  nivel: 1,
  perfil,
  prioridad: 'alta',
  orden,
  motivo: 'No ha pagado ninguna cuota y lleva 5 días de atraso',
  vencido: { payable_usd: 12.32, financed_usd: 10, fee_usd: 2.32 },
  por_vencer: { payable_usd: 0, financed_usd: 0, fee_usd: 0 },
  dias_atraso: 5,
  tramo: 't2',
  cuotas_vencidas: 1,
  proximo_vencimiento: null,
  cuotas_pagadas: 0,
  pagadas_a_tiempo: 0,
  pagadas_tarde: 0,
  atraso_medio_al_pagar: null,
  promesas_hechas: 0,
  promesas_cumplidas: 0,
  promesas_rotas: 0,
  gestiones: 1,
  gestiones_sin_respuesta: 1,
  dias_desde_ultima_gestion: 2,
  reportes_rechazados: 0,
  antiguedad_dias: 20,
  tiene_push: true,
  locales: ['La Quinta Bar'],
  ...extra,
})

const crudo = {
  hoy: '2026-09-26',
  merchant_id: null,
  umbrales: { promesa_rota_dias: 10, se_le_paso_pct: 75, recuperacion_dias: 30 },
  en_mora: { personas: 3, vencido: { payable_usd: 36.96, financed_usd: 30, fee_usd: 6.96 } },
  perfiles: [
    {
      perfil: 'nunca_ha_pagado',
      prioridad: 'alta',
      personas: 2,
      vencido: { payable_usd: 24.64, financed_usd: 20, fee_usd: 4.64 },
      por_vencer: { payable_usd: 0, financed_usd: 0, fee_usd: 0 },
      atraso_medio_dias: 5,
      recuperacion: {
        episodios: 58,
        personas: 24,
        vencido: { payable_usd: 483.28, financed_usd: 392.26, fee_usd: 91.02 },
        recuperado: { payable_usd: 309.05, financed_usd: 250.84, fee_usd: 58.21 },
        pct: 63.9,
        dias: 30,
      },
    },
    {
      perfil: 'se_le_paso',
      prioridad: 'baja',
      personas: 1,
      vencido: { payable_usd: 12.32, financed_usd: 10, fee_usd: 2.32 },
      por_vencer: { payable_usd: 0, financed_usd: 0, fee_usd: 0 },
      atraso_medio_dias: 1,
      recuperacion: { episodios: 0, personas: 0, vencido: {}, recuperado: {}, pct: null, dias: 30 },
    },
    { perfil: 'vigilar', prioridad: 'baja', personas: 4, vencido: {}, por_vencer: {}, recuperacion: null },
  ],
  personas: [
    persona(3, 'se_le_paso', { prioridad: 'baja' }),
    persona(1, 'nunca_ha_pagado'),
    persona(2, 'nunca_ha_pagado'),
    persona(4, 'perfil_que_no_existe'),
  ],
}

console.log('── La lectura ──────────────────────────────────────────────────')
{
  const d = leerDeudores(crudo)
  igual(d.perfiles.map((p) => p.perfil), [...PERFILES_DEUDOR], 'salen los siete perfiles, en su orden')
  igual(
    d.perfiles.find((p) => p.perfil === 'promesa_rota')?.personas,
    0,
    'un perfil que no vino sale con cero pacientes',
  )
  igual(
    d.perfiles.find((p) => p.perfil === 'reincidente')?.prioridad,
    'media',
    'y con la prioridad que le toca',
  )
  igual(d.personas.map((p) => p.userId), ['u1', 'u2', 'u3'], 'la lista va en el orden de la cola y sin perfiles raros')
  igual(
    d.personas[0].vencido,
    { payableUsd: 12.32, financedUsd: 10, feeUsd: 2.32 },
    'lo vencido llega con su desglose',
  )
  igual(d.umbrales.promesaRotaDias, 10, 'los umbrales salen de la respuesta')
  igual(d.umbrales.vigilarDias, UMBRALES_DEL_CONTRATO.vigilarDias, 'y el que falta, del contrato')
  igual(d.perfiles.find((p) => p.perfil === 'vigilar')?.recuperacion, null, 'vigilar no tiene recuperación')
  igual(d.enMora.personas, 3, 'los pacientes en mora')
}

console.log('── Recuperación ────────────────────────────────────────────────')
{
  const d = leerDeudores(crudo)
  igual(
    textoDeRecuperacion(d.perfiles[0].recuperacion),
    'Histórico: cobrado el 64 % de lo vencido en 30 días (58 casos)',
    'con historia, el porcentaje y cuántas veces',
  )
  igual(
    textoDeRecuperacion(d.perfiles.find((p) => p.perfil === 'se_le_paso')?.recuperacion ?? null),
    'Sin historia todavía',
    'sin episodios no es un 0 %',
  )
  igual(textoDeRecuperacion(null), 'No aplica: todavía no debe nada', 'vigilar')
}

console.log('── Los textos de cada perfil ───────────────────────────────────')
{
  igual(
    queEsElPerfil('se_le_paso', { ...UMBRALES_DEL_CONTRATO, seLePasoPct: 75, seLePasoDias: 1 }),
    'Lleva 1 día de atraso o menos y pagó a tiempo el 75 % de sus cuotas o más.',
    'dice los umbrales que manda la base, en singular si toca',
  )
  igual(
    queEsElPerfil('promesa_rota', UMBRALES_DEL_CONTRATO),
    'Prometió pagar un día de los últimos 14 y no pagó.',
    'promesa rota con sus catorce días',
  )
  igual(estaEnMora('vigilar'), false, 'vigilar no está en mora')
  igual(estaEnMora('se_le_paso'), true, 'se le pasó sí')
}

console.log('── La URL ──────────────────────────────────────────────────────')
{
  // La sub-pestaña es del marco (`pestanas.ts`): Cobranza no se la queda.
  igual(validarCobranza({ sub: 'resumen', perfil: 'reincidente', dim: 'local' }), {}, 'Riesgo no tiene claves propias')
  igual(validarImpago({ sub: 'otra', dim: 'semana' }), { dim: 'semana' }, 'el impago, su «Partido por»')
  igual(validarImpago({ dim: 'raro' }), { dim: undefined }, 'lo desconocido se cae')
  igual(cuotaDe({}), 1, 'sin cuota, la 1')
  igual(cuotaDe({ cuota: '2' }), 2, 'con cuota=2, la 2')
}

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
