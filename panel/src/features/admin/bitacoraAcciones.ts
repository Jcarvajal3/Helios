// ═══════════════════════════════════════════════════════════════════════════
// El vocabulario de la bitácora: el verbo de cada código de acción, los temas
// del filtro y el nombre de los valores que guardan algunas acciones.
//
// Los códigos son los que escribe la base, comprobados uno a uno contra los
// `audit.log(...)` de las migraciones. La primera versión se escribió a ojo
// —`payment.reconcile`, `kyc.review`— y el resultado fue una pantalla que decía
// «Nada con estos filtros» encima de once pagos aprobados. Antes de añadir una
// entrada aquí, se mira la migración.
// ═══════════════════════════════════════════════════════════════════════════

/** El verbo de cada acción, en pasado y con sujeto humano delante. */
export const ACCION_VERBO: Record<string, string | undefined> = {
  // ── Pagos reportados ─────────────────────────────────────────────────────
  'payment.reconciled': 'aprobó un pago reportado',
  'payment.rejected': 'rechazó un pago reportado',
  'payment.flagged': 'dejó un pago en revisión',
  'payment.statement_linked': 'ligó un movimiento del extracto a un pago aprobado',

  // ── Banco ────────────────────────────────────────────────────────────────
  'statement.import': 'importó un extracto del banco',
  'statement.imported': 'importó un extracto del banco',
  'bank_balance.recorded': 'anotó el saldo del banco',
  'deposit.assigned': 'asignó un abono sin dueño',
  'deposit.discarded': 'descartó un abono sin dueño',

  // ── Alertas de riesgo (20260925113000) ───────────────────────────────────
  'risk_alert.reviewed': 'revisó una alerta de riesgo',

  // ── Cuentas ──────────────────────────────────────────────────────────────
  'user.set_status': 'cambió el estado de una cuenta',
  'user.set_level': 'cambió el nivel de un paciente',
  'user.set_blacklist': 'cambió la marca interna de una cuenta',
  'user.blocked': 'bloqueó una cuenta a mano',
  'user.unblocked': 'quitó el bloqueo de una cuenta',
  'account.set_test': 'cambió la marca de prueba de una cuenta',

  // ── Consumos ─────────────────────────────────────────────────────────────
  'charge.void': 'anuló un cobro pendiente',
  'charge.reverted': 'revirtió un financiamiento ya confirmado',

  // ── Cobranza ─────────────────────────────────────────────────────────────
  'late_fee.waived': 'condonó un cargo por atraso',
  'collection.contact': 'anotó una gestión de cobranza',
  'collection_template.set': 'cambió una plantilla de cobranza',
  'collection_template.reset': 'devolvió una plantilla de cobranza a la original',

  // ── Locales ──────────────────────────────────────────────────────────────
  'merchant.created': 'dio de alta una clínica',
  'merchant.status_changed': 'cambió el estado de una clínica',
  'merchant.set_profile': 'cambió el perfil de una clínica',
  'merchant.set_owner': 'cambió el médico titular de una clínica',
  'merchant.payout_account_set': 'cambió la cuenta de pago de una clínica',
  'merchant_application.approved': 'aprobó una solicitud de afiliación',
  'merchant_application.rejected': 'rechazó una solicitud de afiliación',
  'merchant.set_terms': 'cambió las condiciones de liquidación de una clínica',
  'merchant.terms_changed': 'cambió las condiciones de liquidación de una clínica',
  'merchant.staff_added': 'añadió personal a una clínica',
  'merchant.staff_updated': 'cambió los datos de alguien del personal de una clínica',
  'merchant.staff_removed': 'dio de baja a alguien del personal de una clínica',
  'merchant.staff_password_reset': 'reinició la contraseña de alguien del personal de una clínica',

  // ── Pagos a locales ──────────────────────────────────────────────────────
  'merchant.payout': 'registró una transferencia a una clínica',
  'merchant.paid': 'registró una transferencia a una clínica',

  // ── Reglas y frenos ──────────────────────────────────────────────────────
  'level.configure': 'cambió la configuración de un nivel',
  'parameter.set': 'cambió un parámetro del negocio',
  'holiday.set': 'añadió un feriado al calendario',
  'holiday.removed': 'quitó un feriado del calendario',
  'fx_rate.manual': 'cargó la tasa BCV a mano',
  'fx_rate.sync': 'trajo la tasa BCV del día',
  'payment_destination.set': 'cambió la cuenta de cobro',
  'terms.published': 'publicó una versión de las condiciones del comprobante',
  'maintenance.on': 'encendió el mantenimiento',
  'maintenance.off': 'apagó el mantenimiento',

  // ── Accesos al panel ─────────────────────────────────────────────────────
  'platform_admin.set': 'dio acceso al panel',
  'platform_admin.revoke': 'revocó un acceso al panel',
  'platform_admin.restore': 'devolvió un acceso al panel',
  'security.require_mfa': 'cambió la exigencia del segundo factor',

  // ── Asistente (fase 6) ───────────────────────────────────────────────────
  // «Javier hizo una pregunta al asistente». La escribe admin_assistant_log.
  'assistant.question': 'hizo una pregunta al asistente',
}

export type TemaBitacora = {
  value: string
  label: string
  /** Null es «no filtres»: el tema «Todo». */
  acciones: string[] | null
}

/**
 * Los temas del filtro. Un operador piensa por tema, no por código.
 *
 * Un tema casi nunca es un código: «pagos reportados» son el aprobado, el
 * rechazado y el que se dejó en revisión. Por eso cada uno lleva su lista y la
 * consulta filtra con `= any`.
 *
 * Van también los códigos que se renombraron por el camino —`merchant.paid`,
 * `statement.imported`, `merchant.terms_changed`—: las líneas de agosto siguen
 * ahí con el nombre de entonces.
 */
export const FILTROS_BITACORA: ReadonlyArray<TemaBitacora> = [
  { value: '', label: 'Todo', acciones: null },
  {
    value: 'pagos-reportados',
    label: 'Pagos reportados',
    acciones: ['payment.reconciled', 'payment.rejected', 'payment.flagged', 'payment.statement_linked'],
  },
  {
    value: 'banco',
    label: 'Banco',
    acciones: [
      'statement.import',
      'statement.imported',
      'bank_balance.recorded',
      'deposit.assigned',
      'deposit.discarded',
    ],
  },
  {
    value: 'pagos-locales',
    label: 'Pagos a clínicas',
    acciones: ['merchant.payout', 'merchant.paid'],
  },
  {
    value: 'cobranza',
    label: 'Cobranza',
    acciones: [
      'collection.contact',
      'late_fee.waived',
      'collection_template.set',
      'collection_template.reset',
    ],
  },
  {
    value: 'consumos',
    label: 'Financiamientos',
    acciones: ['charge.void', 'charge.reverted'],
  },
  {
    value: 'alertas',
    label: 'Alertas de riesgo',
    acciones: ['risk_alert.reviewed'],
  },
  {
    value: 'cuentas',
    label: 'Cuentas',
    acciones: [
      'user.set_status',
      'user.set_level',
      'user.set_blacklist',
      'user.blocked',
      'user.unblocked',
      'account.set_test',
    ],
  },
  {
    value: 'locales',
    label: 'Clínicas',
    acciones: [
      'merchant.created',
      'merchant.status_changed',
      'merchant.set_profile',
      'merchant.set_owner',
      'merchant.payout_account_set',
      'merchant_application.approved',
      'merchant_application.rejected',
      'merchant.set_terms',
      'merchant.terms_changed',
      'merchant.staff_added',
      'merchant.staff_updated',
      'merchant.staff_removed',
      'merchant.staff_password_reset',
    ],
  },
  {
    value: 'reglas',
    label: 'Reglas y frenos',
    acciones: [
      'level.configure',
      'parameter.set',
      'holiday.set',
      'holiday.removed',
      'fx_rate.manual',
      'fx_rate.sync',
      'payment_destination.set',
      'terms.published',
      'maintenance.on',
      'maintenance.off',
    ],
  },
  {
    value: 'accesos',
    label: 'Accesos al panel',
    acciones: [
      'platform_admin.set',
      'platform_admin.revoke',
      'platform_admin.restore',
      'security.require_mfa',
    ],
  },
  {
    value: 'asistente',
    label: 'Pregunta al asistente',
    acciones: ['assistant.question'],
  },
]

/** Los temas que se pueden escribir en la URL (todos menos «Todo»). */
export const TEMAS_BITACORA: ReadonlyArray<string> = FILTROS_BITACORA.map((f) => f.value).filter(
  (v) => v !== '',
)

/** Los códigos que componen un tema. Sin tema, sin filtro. */
export function accionesDelTema(value: string | undefined): string[] | null {
  if (!value) return null
  return FILTROS_BITACORA.find((f) => f.value === value)?.acciones ?? null
}

// ── Valores con nombre ────────────────────────────────────────────────────

/** El resultado de una gestión de cobranza (`collection_contacts.outcome`). */
export const RESULTADO_GESTION: Record<string, string | undefined> = {
  contesto: 'Contestó',
  no_contesta: 'No contesta',
  numero_equivocado: 'Número equivocado',
  mensaje_enviado: 'Mensaje enviado',
  promesa: 'Prometió pagar',
  otro: 'Otro',
}

/** El canal de una gestión de cobranza. */
export const CANAL_GESTION: Record<string, string | undefined> = {
  whatsapp: 'WhatsApp',
  llamada: 'Llamada',
  en_local: 'En la clínica',
  otro: 'Otro',
}

/**
 * El tipo de una alerta de riesgo, por el prefijo de su clave: es lo que
 * `admin_review_risk_alert` guarda en `detail.kind`. `noche` y `primer_tope`
 * ya no se generan, pero sus revisiones siguen en la bitácora y se leen.
 */
export const TIPO_ALERTA: Record<string, string | undefined> = {
  relacionada: 'Cuenta relacionada con otra',
  sobre_cupo: 'Financiamiento por encima de su cupo',
  noche: 'Varios financiamientos en un día',
  primer_tope: 'Primer financiamiento al tope del cupo',
}

/** Qué clase de cuenta marcó `account.set_test`. */
export const CLASE_DE_CUENTA: Record<string, string | undefined> = {
  user: 'persona',
  merchant: 'local',
}
