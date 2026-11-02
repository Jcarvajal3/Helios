import { booleano, filaONula, numeroONulo, textoONulo } from '@/lib/json'

// ═══════════════════════════════════════════════════════════════════════════
// La foto de la cédula con la que el paciente confirmó su pago en cuotas
// (docs/00 §15.11, contrato §2.4). Solo el equipo de Helios: la clínica no la
// ve. Lo que leyó el lector no deshace nada: si no cuadra, es una alerta.
// ═══════════════════════════════════════════════════════════════════════════

/** pendiente · leyendo · coincide · no_coincide · no_es_cedula · no_se_pudo_leer · no_se_pudo_bajar */
export type RevisionDeCedula =
  | 'pendiente'
  | 'leyendo'
  | 'coincide'
  | 'no_coincide'
  | 'no_es_cedula'
  | 'no_se_pudo_leer'
  | 'no_se_pudo_bajar'

export type FotoDeCedula = {
  /** La tiene en su perfil (si no, su próxima orden la pide). */
  tieneFoto: boolean
  /** La última que mandó (aunque no esté en su perfil), o null si nunca mandó una. */
  ultima: {
    recibidaEl: string | null
    guardada: boolean
    mime: string | null
    revision: RevisionDeCedula
    /** numero · nombre · numero_y_nombre (con `no_coincide`). */
    motivo: string | null
    numeroLeido: string | null
    nombreLeido: string | null
    orden: number | null
  } | null
}

const REVISIONES: ReadonlySet<string> = new Set([
  'pendiente', 'leyendo', 'coincide', 'no_coincide', 'no_es_cedula', 'no_se_pudo_leer', 'no_se_pudo_bajar',
])

/** Lo que devuelve `admin_patient_id_photo`. */
export function leerFotoDeCedula(crudo: unknown): FotoDeCedula {
  const d = filaONula(crudo) ?? {}
  const revision = textoONulo(d.status)
  return {
    tieneFoto: booleano(d.has_photo),
    ultima: d.photo_id
      ? {
          recibidaEl: textoONulo(d.received_at),
          guardada: booleano(d.stored),
          mime: textoONulo(d.mime),
          revision: revision && REVISIONES.has(revision) ? (revision as RevisionDeCedula) : 'pendiente',
          motivo: textoONulo(d.reason),
          numeroLeido: textoONulo(d.read_number),
          nombreLeido: textoONulo(d.read_name),
          orden: numeroONulo(d.order_number),
        }
      : null,
  }
}

/** La insignia de la revisión: qué dice y con qué tono. */
export function insigniaDeLaRevision(
  revision: RevisionDeCedula,
  motivo: string | null,
): { texto: string; tono: 'success' | 'error' | 'warning' | 'neutral' } {
  switch (revision) {
    case 'coincide':
      return { texto: 'Coincide con sus datos', tono: 'success' }
    case 'no_coincide':
      return {
        texto:
          motivo === 'numero'
            ? 'El número no coincide'
            : motivo === 'nombre'
              ? 'El nombre no coincide'
              : 'El número y el nombre no coinciden',
        tono: 'error',
      }
    case 'no_es_cedula':
      return { texto: 'No parece una cédula', tono: 'error' }
    case 'no_se_pudo_leer':
      return { texto: 'No se pudo revisar', tono: 'warning' }
    case 'no_se_pudo_bajar':
      return { texto: 'No se pudo descargar', tono: 'warning' }
    default:
      return { texto: 'Revisando…', tono: 'neutral' }
  }
}
