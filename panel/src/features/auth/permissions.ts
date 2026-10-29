import type { MerchantRole, StaffContext } from '@/features/auth/session'

/**
 * Qué puede ver cada rol de la clínica.
 *
 * En la base los roles siguen llamándose como en Ronda —`gerente` y
 * `cajero`—; en la interfaz son **Administrador** y **Secretaria**. El rol
 * `inventario` de Ronda no existe en Helios (no hay catálogo): quien lo
 * tuviera se trata como si no fuera personal de la clínica (`session.ts`).
 *
 * La **secretaria** registra pagos en cuotas y consulta los que registró
 * ella, y sus comisiones; el **administrador** ve los de toda la clínica y
 * además el dinero —métricas, lo que Helios le transfiere y su personal—.
 * La secretaria que **solo registra** (`soloRegistra`, a criterio del médico
 * al crearla; 2026-10-29) registra y ve sus comisiones: ni la pestaña de
 * pagos en cuotas ni la ficha de cada orden.
 *
 * `cuenta` no es una pestaña de la barra: es quién eres y cómo salir, que
 * vive en el pie del sidebar. Por eso la conservan los dos roles.
 *
 * ⚠️ Esto es solo la UI. La barrera real está en la base:
 *
 * - `settlements` y `merchant_settlement_terms` los limita RLS al rol
 *   `gerente`: Métricas y Pagos están cerradas de verdad.
 * - `merchant_transactions`, `merchant_transactions_summary` y
 *   `merchant_charge_detail` dejan entrar a cualquier personal de la clínica,
 *   pero quien no es gerente solo recibe los pagos en cuotas que registró él.
 * - `merchant_sales_export` —la descarga para contabilidad— pide gerente.
 * - Las RPC del historial le responden 42501 a la secretaria que solo
 *   registra (`helios_assert_ve_el_historial`).
 *
 * Sin este mapa, una secretaria que entrara a Pagos no vería un error: vería
 * **cero** — la RLS le devuelve lista vacía. Es el fallo más peligroso de
 * todos, el que parece una respuesta legítima.
 */
export type MerchantSection =
  | 'registrar'
  | 'financiamientos'
  | 'comisiones'
  // Dentro de Comisiones: las de todo el personal y no solo las propias.
  | 'comisiones-de-todos'
  | 'metricas'
  // Descargar los pagos en cuotas para contabilidad.
  | 'contabilidad'
  | 'pagos'
  | 'personal'
  | 'cuenta'

const SECTIONS_BY_ROLE: Record<MerchantRole, MerchantSection[]> = {
  gerente: [
    'registrar',
    'financiamientos',
    'comisiones',
    'comisiones-de-todos',
    'metricas',
    'contabilidad',
    'pagos',
    // Solo el administrador, y no es una decisión de pantalla: si una
    // secretaria pudiera gestionar el personal, podría ascenderse a
    // administradora ella misma y el rol dejaría de separar nada. Lo mismo
    // comprueba el servidor en `can_manage_merchant_staff`.
    'personal',
    'cuenta',
  ],
  cajero: ['registrar', 'financiamientos', 'comisiones', 'cuenta'],
}

/** La secretaria que solo registra: sin el historial de pagos en cuotas. */
const SECTIONS_SOLO_REGISTRA: MerchantSection[] = ['registrar', 'comisiones', 'cuenta']

/** Lo que decide qué ve una persona de la clínica: su rol y, si es
 *  secretaria, si solo registra. */
export type Acceso = Pick<StaffContext, 'role' | 'soloRegistra'>

export function canSee(acceso: Acceso, section: MerchantSection): boolean {
  const secciones =
    acceso.role === 'cajero' && acceso.soloRegistra
      ? SECTIONS_SOLO_REGISTRA
      : SECTIONS_BY_ROLE[acceso.role]
  return secciones.includes(section)
}

/** Etiqueta legible del rol, para la pantalla de Cuenta. */
export const ROLE_LABEL: Record<MerchantRole, string> = {
  gerente: 'Administrador',
  cajero: 'Secretaria',
}
