import { formatDay } from '@/components/ui'
import type { BadgeTone } from '@/components/ui'

// ═══════════════════════════════════════════════════════════════════════════
// Una gestión de cobranza: por dónde, qué pasó y qué queda por hacer.
//
// Módulo puro: lo usan la lista, el caso y las pruebas. Los valores son los
// del `check` de `collection_contacts` (migración 20260925100000); un nombre
// mal escrito aquí es una gestión que la base rechaza.
// ═══════════════════════════════════════════════════════════════════════════

// ── Canal ──────────────────────────────────────────────────────────────────

export type Canal = 'whatsapp' | 'llamada' | 'en_local' | 'otro'

/** En el orden en que se ofrecen: lo que más se usa, arriba. */
export const CANALES: readonly Canal[] = ['llamada', 'whatsapp', 'en_local', 'otro']

export const ROTULO_CANAL: Record<Canal, string> = {
  whatsapp: 'WhatsApp',
  llamada: 'Llamada',
  en_local: 'En la clínica',
  otro: 'Otro',
}

/** «Por dónde», dicho dentro de una frase. */
const POR_CANAL: Record<Canal, string> = {
  whatsapp: 'por WhatsApp',
  llamada: 'por teléfono',
  en_local: 'en la clínica',
  otro: 'por otro medio',
}

// ── Resultado ──────────────────────────────────────────────────────────────

export type Resultado =
  | 'contesto'
  | 'no_contesta'
  | 'numero_equivocado'
  | 'mensaje_enviado'
  | 'promesa'
  | 'otro'

export const RESULTADOS: readonly Resultado[] = [
  'contesto',
  'no_contesta',
  'numero_equivocado',
  'mensaje_enviado',
  'promesa',
  'otro',
]

/** El rótulo y el tono de cada resultado. «Número equivocado» es un dato roto. */
export const RESULTADO: Record<Resultado, { label: string; tone: BadgeTone }> = {
  contesto: { label: 'Contestó', tone: 'success' },
  no_contesta: { label: 'No contesta', tone: 'warning' },
  numero_equivocado: { label: 'Número equivocado', tone: 'error' },
  mensaje_enviado: { label: 'Mensaje enviado', tone: 'neutral' },
  promesa: { label: 'Prometió pagar', tone: 'brand' },
  otro: { label: 'Otro', tone: 'neutral' },
}

// ── El formulario de «Anotar una gestión» ──────────────────────────────────

export type BorradorGestion = {
  canal: Canal
  /** Vacío hasta que se elige: el resultado es obligatorio. */
  resultado: Resultado | ''
  nota: string
  /** 'YYYY-MM-DD' o vacío. Solo cuenta con el resultado «Prometió pagar». */
  fechaPrometida: string
  /** 'YYYY-MM-DD' o vacío: el día en que hay que volver a llamar. */
  volverALlamar: string
  /** El nombre de la plantilla de WhatsApp que se mandó, si se mandó una. */
  plantilla: string
}

export function borradorInicial(inicial: Partial<BorradorGestion> = {}): BorradorGestion {
  return {
    canal: 'llamada',
    resultado: '',
    nota: '',
    fechaPrometida: '',
    volverALlamar: '',
    plantilla: '',
    ...inicial,
  }
}

/**
 * Por qué no se puede anotar todavía, o `undefined` si se puede.
 *
 * Las mismas reglas que `admin_log_contact`, con `hoy` = día operativo: dichas
 * antes de pulsar y no en una caja roja después.
 */
export function motivoParaNoAnotar(b: BorradorGestion, hoy: string): string | undefined {
  if (b.resultado === '') return 'Elige qué pasó en la gestión.'
  if (b.resultado === 'promesa') {
    if (b.fechaPrometida === '') return 'Escribe el día en que prometió pagar.'
    if (b.fechaPrometida < hoy) return 'La fecha prometida ya pasó.'
  }
  if (b.volverALlamar !== '' && b.volverALlamar < hoy) {
    return 'El día para volver a llamar ya pasó.'
  }
  return undefined
}

/** Lo que se manda a la base. Los vacíos viajan como `null`. */
export type GestionNueva = {
  canal: Canal
  resultado: Resultado
  nota: string | null
  fechaPrometida: string | null
  volverALlamar: string | null
  plantilla: string | null
}

/**
 * El borrador, listo para `logContact`. La fecha prometida solo viaja con
 * «Prometió pagar»: si se escribió y luego se cambió el resultado, el campo
 * ya no se ve y no puede guardarse a escondidas.
 */
export function aGestion(b: BorradorGestion & { resultado: Resultado }): GestionNueva {
  return {
    canal: b.canal,
    resultado: b.resultado,
    nota: b.nota.trim() || null,
    fechaPrometida: b.resultado === 'promesa' && b.fechaPrometida ? b.fechaPrometida : null,
    volverALlamar: b.volverALlamar || null,
    plantilla: b.plantilla.trim() || null,
  }
}

/**
 * La frase de arriba del diálogo: qué va a quedar escrito.
 *
 * No dice «hablaste con» si nadie contestó: el registro sirve para que quien
 * retome el caso sepa qué pasó, y una frase que miente sobre eso lo estropea.
 */
export function resumenDeGestion(nombre: string, b: BorradorGestion): string {
  const por = POR_CANAL[b.canal]
  const hecho = (() => {
    switch (b.resultado) {
      case 'contesto':
        return `hablaste con ${nombre} ${por}`
      case 'promesa':
        return b.fechaPrometida
          ? `${nombre} prometió ${por} pagar el ${formatDay(b.fechaPrometida)}`
          : `${nombre} prometió ${por} pagar`
      case 'no_contesta':
        return `se intentó contactar a ${nombre} ${por} y no contestó`
      case 'numero_equivocado':
        return `el número de ${nombre} es equivocado`
      case 'mensaje_enviado':
        return `se envió un mensaje a ${nombre} ${por}`
      case 'otro':
      case '':
        return `hubo una gestión con ${nombre} ${por}`
    }
  })()

  const despues = b.volverALlamar
    ? ` La próxima acción queda para el ${formatDay(b.volverALlamar)}.`
    : ''

  return `Queda anotado que ${hecho}.${despues} Se guarda con tu nombre y la hora.`
}

/** El aviso de después de guardar. */
export function avisoDeGestionAnotada(g: GestionNueva): string {
  if (g.resultado === 'promesa' && g.fechaPrometida) {
    return `Gestión anotada: prometió pagar el ${formatDay(g.fechaPrometida)}.`
  }
  return `Gestión anotada: ${RESULTADO[g.resultado].label.toLowerCase()}.`
}
