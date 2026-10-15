/**
 * Pruebas de la comparación entre el bot de avisos y el equipo.
 *
 *   npx tsx src/features/admin/avisosBnc.test.ts
 *
 * Lo que más importa es `equipo_rechazo`: es la cifra que decide si el bot se
 * puede activar, así que no puede esconderse en otra categoría.
 */
import { comparar, resumir, ventajaDelBot } from './avisosBnc'
import type { AvisoBnc, DecisionBot, EstadoPago } from './avisosBnc'

let failures = 0

function check(ok: boolean, label: string, detail: string) {
  if (!ok) failures++
  console.log(`${ok ? 'OK  ' : 'FALLA'} ${label.padEnd(34)} ${detail}`)
}

function aviso(decision: DecisionBot, estado: EstadoPago | null, extra: Partial<AvisoBnc> = {}): AvisoBnc {
  return {
    id: Math.random().toString(36).slice(2),
    recibidoEn: '2026-10-12T23:07:30Z',
    texto: 'BNC Pago Movil Recibido …',
    remitente: '2622',
    referencia: '158795645',
    montoVes: 5442.41,
    telefono: '0424***9037',
    pagadoEn: '2026-10-12T23:07:00Z',
    decision,
    modo: 'sombra',
    decididoEn: '2026-10-12T23:08:40Z',
    nota: null,
    emparejadoPorBot: estado !== null,
    pago:
      estado === null
        ? null
        : {
            id: 'r1',
            userId: 'u1',
            persona: 'Ana',
            referencia: '795645',
            telefono: '04242149037',
            reportadoEn: '2026-10-12T23:08:36Z',
            estado,
            revisadoEn: '2026-10-12T23:38:40Z',
            revisadoPor: 'Operadora',
            motivoRechazo: null,
            montoVes: 5442.41,
            montoUsd: 5.5,
          },
    ...extra,
  }
}

// ── Cada decisión en su sitio ──────────────────────────────────────────────
check(comparar(aviso('aprobaria', 'reconciled')) === 'coinciden', 'aprobaría y el equipo aprobó', 'coinciden')
check(comparar(aviso('aprobaria', 'rejected')) === 'equipo_rechazo', 'aprobaría y el equipo rechazó', 'equipo_rechazo')
check(comparar(aviso('aprobaria', 'duplicate')) === 'equipo_rechazo', 'aprobaría y era duplicado', 'equipo_rechazo')
check(comparar(aviso('aprobaria', 'reported')) === 'falta_equipo', 'aprobaría y el equipo no ha decidido', 'falta_equipo')
check(comparar(aviso('aprobaria', 'in_review')) === 'falta_equipo', 'aprobaría y está en revisión', 'falta_equipo')
check(comparar(aviso('ya_aprobado', 'reconciled')) === 'equipo_antes', 'el equipo fue antes', 'equipo_antes')
check(comparar(aviso('aprobado', 'reconciled')) === 'bot_aprobo', 'modo activo', 'bot_aprobo')
check(comparar(aviso('varios', 'reported')) === 'para_equipo', 'varios', 'para_equipo')
check(comparar(aviso('telefono_distinto', 'reconciled')) === 'para_equipo', 'teléfono distinto', 'para_equipo')
check(comparar(aviso('error', 'reported')) === 'para_equipo', 'error al aprobar', 'para_equipo')
check(comparar(aviso('remitente_ajeno', 'reported')) === 'para_equipo', 'remitente ajeno', 'para_equipo')
check(comparar(aviso('esperando', null)) === 'sin_reporte', 'sin reporte', 'sin_reporte')
check(comparar(aviso('ilegible', null)) === 'ilegible', 'ilegible', 'ilegible')

// ── Lo que se gana ─────────────────────────────────────────────────────────
check(ventajaDelBot(aviso('aprobaria', 'reconciled')) === 1800, 'media hora de ventaja', '1800 s')
check(ventajaDelBot(aviso('aprobaria', 'rejected')) === null, 'sin ventaja si el equipo rechazó', 'null')
check(
  ventajaDelBot(
    aviso('aprobaria', 'reconciled', { decididoEn: '2026-10-12T23:40:00Z' }),
  ) === null,
  'el equipo antes que el bot no cuenta',
  'null',
)

// ── El resumen ─────────────────────────────────────────────────────────────
const r = resumir([
  aviso('aprobaria', 'reconciled'),
  aviso('aprobaria', 'reconciled', { decididoEn: '2026-10-12T23:28:40Z' }),
  aviso('aprobaria', 'rejected'),
  aviso('aprobaria', 'reported'),
  aviso('varios', 'reported'),
  aviso('esperando', null),
  aviso('ilegible', null),
])
check(r.avisos === 7, 'avisos', String(r.avisos))
check(r.aprobaria === 4, 'aprobaría', String(r.aprobaria))
check(r.coinciden === 2, 'coinciden', String(r.coinciden))
check(r.equipoRechazo === 1, 'el equipo rechazó', String(r.equipoRechazo))
check(r.faltaEquipo === 1, 'falta el equipo', String(r.faltaEquipo))
check(r.paraEquipo === 1, 'para el equipo', String(r.paraEquipo))
check(r.sinReporte === 1 && r.ilegibles === 1, 'sin reporte e ilegibles', `${r.sinReporte}/${r.ilegibles}`)
check(r.medianaVentaja === 1200, 'mediana de dos (30 y 10 min)', String(r.medianaVentaja))
check(resumir([]).medianaVentaja === null, 'sin avisos no hay mediana', 'null')

console.log(failures === 0 ? '\n=== TODO OK ===' : `\n=== ${failures} FALLOS ===`)
process.exit(failures === 0 ? 0 : 1)
