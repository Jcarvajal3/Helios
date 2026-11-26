/**
 * Helios Lab — vocabulario compartido por el portal del médico y el admin
 * (docs/09-HELIOS-LAB.md). Los valores son los de la base; los rótulos, lo
 * que se lee en pantalla.
 */

export type ModoLab = 'apagado' | 'prueba' | 'todos'

export type KitTipo = 'sangre' | 'orina' | 'biopsia'

export const KITS: readonly KitTipo[] = ['sangre', 'orina', 'biopsia']

export const ROTULO_KIT: Record<KitTipo, string> = {
  sangre: 'Sangre',
  orina: 'Orina',
  biopsia: 'Biopsia',
}

export type EstadoMuestra =
  | 'lista_para_retirar'
  | 'retirada'
  | 'en_laboratorio'
  | 'resultado_recibido'
  | 'resultado_entregado'
  | 'anulada'

/** El recorrido normal, en orden (sin `anulada`). */
export const PASOS_MUESTRA: readonly EstadoMuestra[] = [
  'lista_para_retirar',
  'retirada',
  'en_laboratorio',
  'resultado_recibido',
  'resultado_entregado',
]

export const ROTULO_ESTADO: Record<EstadoMuestra, string> = {
  lista_para_retirar: 'Lista para retirar',
  retirada: 'Retirada',
  en_laboratorio: 'En el laboratorio',
  resultado_recibido: 'Resultado listo',
  resultado_entregado: 'Resultado entregado',
  anulada: 'Anulada',
}

export type TonoEstado = 'neutral' | 'warning' | 'error' | 'success' | 'brand'

export const TONO_ESTADO: Record<EstadoMuestra, TonoEstado> = {
  lista_para_retirar: 'warning',
  retirada: 'brand',
  en_laboratorio: 'brand',
  resultado_recibido: 'brand',
  resultado_entregado: 'success',
  anulada: 'neutral',
}

export type EstadoPago = 'por_leer' | 'cuadra' | 'para_revisar' | 'verificado' | 'rechazado'

export const ROTULO_PAGO: Record<EstadoPago, string> = {
  por_leer: 'Leyendo la captura',
  cuadra: 'Cuadra, por confirmar',
  para_revisar: 'Por revisar',
  verificado: 'Verificado',
  rechazado: 'Rechazado',
}

export const TONO_PAGO: Record<EstadoPago, TonoEstado> = {
  por_leer: 'neutral',
  cuadra: 'brand',
  para_revisar: 'warning',
  verificado: 'success',
  rechazado: 'error',
}

export type CanalResultado = 'correo' | 'whatsapp'

export const ROTULO_CANAL: Record<CanalResultado, string> = {
  correo: 'Correo',
  whatsapp: 'WhatsApp',
}

export type EstadoParada = 'pendiente' | 'completada' | 'saltada'
export type TipoParada = 'consultorio' | 'laboratorio'
export type EstadoRuta = 'borrador' | 'en_curso' | 'cerrada'

/** Las partes del precio, con los nombres que se ven (nunca «fee»). */
export const ROTULOS_PRECIO = {
  base: 'Base del laboratorio',
  cargo: 'Cargo Helios',
  comision: 'Tu comisión',
  comisionMedico: 'Comisión del médico',
  precio: 'Precio al paciente',
} as const

/** Precio al paciente: base + cargo + comisión, en centavos para no sumar floats. */
export function precioAlPaciente(base: number, cargo: number, comision: number): number {
  return Math.round(base * 100 + cargo * 100 + comision * 100) / 100
}
