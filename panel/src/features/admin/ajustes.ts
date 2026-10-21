import { comoFila, comoLista, textoONulo } from '@/lib/json'
import { supabase } from '@/lib/supabase'

// ═══════════════════════════════════════════════════════════════════════════
// Lo que se toca una vez y después hay que poder auditar: los parámetros del
// negocio, el calendario, los términos, las plantillas de cobranza y la
// seguridad del panel.
//
// Los parámetros se LEEN con `useParametros` (features/admin/useParametros.ts),
// que comparte la caché con el resto del panel; aquí solo se escriben.
// ═══════════════════════════════════════════════════════════════════════════

// ── Parámetros del negocio ────────────────────────────────────────────────

/**
 * Fija un parámetro desde una fecha. Solo super admin; la nota queda en la
 * historia del parámetro y en la bitácora (`parameter.set`).
 */
export async function setBusinessParameter(params: {
  key: string
  value: number
  effectiveFrom?: string
  note?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_business_parameter', {
    p_key: params.key,
    p_value: params.value,
    p_effective_from: params.effectiveFrom ?? null,
    p_note: params.note ?? null,
  })
  if (error) throw error
}

// ── Feriados ──────────────────────────────────────────────────────────────

export type Holiday = { day: string; name: string; kind: string }

export async function fetchHolidays(year?: number): Promise<Holiday[]> {
  const { data, error } = await supabase.rpc('admin_holidays', { p_year: year ?? null })
  if (error) throw error

  return comoLista(data)
    .map(comoFila)
    .map((row) => ({
      day: String(row.day),
      name: String(row.name),
      kind: String(row.kind),
    }))
}

export async function setHoliday(params: {
  day: string
  name?: string
  kind?: string
  remove?: boolean
}): Promise<void> {
  const { error } = await supabase.rpc('admin_set_holiday', {
    p_day: params.day,
    p_name: params.name ?? null,
    p_kind: params.kind ?? 'nacional',
    p_remove: params.remove ?? false,
  })
  if (error) throw error
}

// ── Términos ──────────────────────────────────────────────────────────────

export type TermsVersion = {
  version: string
  summary: string | null
  url: string | null
  publishedAt: string
  isCurrent: boolean
  publishedByName: string
  acceptedCount: number
  firstAcceptedAt: string | null
}

export async function fetchTermsVersions(): Promise<{
  peopleTotal: number
  pendingCurrent: number
  rows: TermsVersion[]
}> {
  const { data, error } = await supabase.rpc('admin_terms_versions')
  if (error) throw error

  const raw = comoFila(data)
  return {
    peopleTotal: Number(raw.people_total),
    pendingCurrent: Number(raw.pending_current),
    rows: comoLista(raw.rows)
      .map(comoFila)
      .map((r) => ({
        version: String(r.version),
        summary: textoONulo(r.summary),
        url: textoONulo(r.url),
        publishedAt: String(r.published_at),
        isCurrent: Boolean(r.is_current),
        publishedByName: String(r.published_by_name),
        acceptedCount: Number(r.accepted_count),
        firstAcceptedAt: textoONulo(r.first_accepted_at),
      })),
  }
}

export async function publishTerms(params: {
  version: string
  body: string
  summary?: string
  url?: string
}): Promise<void> {
  const { error } = await supabase.rpc('admin_publish_terms', {
    p_version: params.version,
    p_body: params.body,
    p_summary: params.summary ?? null,
    p_url: params.url ?? null,
  })
  if (error) throw error
}

// ── Plantillas de cobranza ────────────────────────────────────────────────

export type CollectionTemplate = {
  bucket: string
  label: string
  body: string
  defaultBody: string
  edited: boolean
  updatedAt: string
  updatedByName: string
}

/**
 * Las plantillas por tramos (`p_tramos`): `t1`…`t4`, una por tramo de atraso
 * (20261019220000), con `{dias_atraso}` entre las variables. Las de antes
 * (Por vencer, Vence hoy, las cinco por bucket y `t5`) se quedan en la base
 * sin uso y aquí no se piden.
 */
export async function fetchCollectionTemplates(): Promise<{
  variables: string[]
  rows: CollectionTemplate[]
}> {
  const { data, error } = await supabase.rpc('admin_collection_templates', { p_tramos: true })
  if (error) throw error

  const raw = comoFila(data)
  return {
    variables: comoLista(raw.variables).map(String),
    rows: comoLista(raw.rows)
      .map(comoFila)
      .map((r) => ({
        bucket: String(r.bucket),
        label: String(r.label),
        body: String(r.body),
        defaultBody: String(r.default_body),
        edited: Boolean(r.edited),
        updatedAt: String(r.updated_at),
        updatedByName: String(r.updated_by_name),
      })),
  }
}

export async function setCollectionTemplate(bucket: string, body: string): Promise<void> {
  const { error } = await supabase.rpc('admin_set_collection_template', {
    p_bucket: bucket,
    p_body: body,
  })
  if (error) throw error
}

export async function resetCollectionTemplate(bucket: string): Promise<void> {
  const { error } = await supabase.rpc('admin_reset_collection_template', {
    p_bucket: bucket,
  })
  if (error) throw error
}

// ── Seguridad ─────────────────────────────────────────────────────────────

export type SecurityStatus = {
  requireMfa: boolean
  teamTotal: number
  teamWithMfa: number
  /** Solo se puede exigir cuando no queda nadie sin su segundo factor. */
  canRequire: boolean
  members: Array<{
    userId: string
    fullName: string | null
    email: string | null
    role: string
    hasMfa: boolean
  }>
}

export async function fetchSecurityStatus(): Promise<SecurityStatus> {
  const { data, error } = await supabase.rpc('admin_security_status')
  if (error) throw error

  const raw = comoFila(data)
  return {
    requireMfa: Boolean(raw.require_mfa),
    teamTotal: Number(raw.team_total),
    teamWithMfa: Number(raw.team_with_mfa),
    canRequire: Boolean(raw.can_require),
    members: comoLista(raw.members)
      .map(comoFila)
      .map((m) => ({
        userId: String(m.user_id),
        fullName: textoONulo(m.full_name),
        email: textoONulo(m.email),
        role: String(m.role),
        hasMfa: Boolean(m.has_mfa),
      })),
  }
}

export async function setRequireMfa(require: boolean): Promise<void> {
  const { error } = await supabase.rpc('admin_set_require_mfa', { p_require: require })
  if (error) throw error
}

// ── Exportación contable ──────────────────────────────────────────────────

export type AccountingExport = {
  month: string
  from: string
  to: string
  summary: {
    collectedUsd: number
    paidOutUsd: number
    revenueUsd: number
    vatUsd: number
    writtenOffUsd: number
    transactions: number
  }
  byAccount: Array<{
    account: string
    debitUsd: number
    creditUsd: number
    netUsd: number
    debitVes: number
    creditVes: number
  }>
  entries: Array<{
    businessDate: string
    createdAt: string
    type: string
    memo: string | null
    account: string
    debitUsd: number
    creditUsd: number
    fxRate: number | null
    debitVes: number
    creditVes: number
    counterparty: string | null
  }>
}

export async function fetchAccountingExport(month: string): Promise<AccountingExport> {
  const { data, error } = await supabase.rpc('admin_accounting_export', {
    p_month: month,
  })
  if (error) throw error

  const raw = comoFila(data)
  const summary = comoFila(raw.summary)
  return {
    month: String(raw.month),
    from: String(raw.from),
    to: String(raw.to),
    summary: {
      collectedUsd: Number(summary.collected_usd),
      paidOutUsd: Number(summary.paid_out_usd),
      revenueUsd: Number(summary.revenue_usd),
      vatUsd: Number(summary.vat_usd),
      writtenOffUsd: Number(summary.written_off_usd),
      transactions: Number(summary.transactions),
    },
    byAccount: comoLista(raw.by_account)
      .map(comoFila)
      .map((a) => ({
        account: String(a.account),
        debitUsd: Number(a.debit_usd),
        creditUsd: Number(a.credit_usd),
        netUsd: Number(a.net_usd),
        debitVes: Number(a.debit_ves ?? 0),
        creditVes: Number(a.credit_ves ?? 0),
      })),
    entries: comoLista(raw.entries)
      .map(comoFila)
      .map((e) => ({
        businessDate: String(e.business_date),
        createdAt: String(e.created_at),
        type: String(e.type),
        memo: textoONulo(e.memo),
        account: String(e.account),
        debitUsd: Number(e.debit_usd),
        creditUsd: Number(e.credit_usd),
        fxRate: e.fx_rate == null ? null : Number(e.fx_rate),
        debitVes: Number(e.debit_ves ?? 0),
        creditVes: Number(e.credit_ves ?? 0),
        counterparty: textoONulo(e.counterparty),
      })),
  }
}
