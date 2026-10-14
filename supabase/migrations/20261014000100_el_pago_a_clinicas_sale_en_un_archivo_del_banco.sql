-- ============================================================================
-- Helios — El pago a las clínicas sale en un archivo del banco
--
-- El pago diario a las clínicas se hace con el «pago masivo a proveedores»
-- del banco: se carga un .xlsm con una fila por transferencia. El panel lo
-- arma con lo de esta función, que da en una sola llamada lo que se le debe
-- hoy a cada clínica (con lo atrasado), en bolívares, y su cuenta de
-- transferencia. Solo transferencia: el pago masivo no acepta Pago Móvil.
--
-- Nueva: `admin_bulk_payout_sheet() → jsonb` (solo el equipo, solo lee).
--
--   today_date, fx_rate_usd, fx_rate_eur
--   debit_account   la primera cuenta de cobro activa de transferencia
--                   (`payment_destinations`), como sugerencia de la cuenta a
--                   debitar; null si no hay.
--   merchants[]     cada clínica con algo en el pago de hoy:
--     merchant_id, merchant_name, is_test, email,
--     has_payout_account, bank, account_holder, holder_document,
--     account_number (null = sin cuenta de transferencia), pago_movil_phone,
--     lineas, pending_usd, pending_usd_part, pending_eur, pending_ves
--
-- Las líneas son las de `in_next_run` de `admin_merchant_settlements`: lo
-- pendiente que vence antes del pago de hoy. Los bolívares van como los
-- calcula `admin_report_merchant_payout` sin tasa escrita: lo de dólares a la
-- BCV del dólar y lo de euros a la del euro, cada parte redondeada al céntimo
-- y luego sumadas. `pending_ves` es null si falta la tasa de una parte.
-- ============================================================================

create or replace function public.admin_bulk_payout_sheet()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy     date    := public.helios_business_date(now());
  v_corte   date    := public.helios_next_settlement_run(now());
  v_usd     numeric := public.current_fx_rate('BCV', v_hoy);
  v_eur     numeric := public.current_fx_rate('BCV_EUR', v_hoy);
  v_debito  jsonb;
  v_filas   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
           'bank_name',      d.bank_name,
           'holder_name',    d.holder_name,
           'rif',            d.rif,
           'account_number', d.account_number)
  into v_debito
  from public.payment_destinations d
  where d.method = 'transferencia'
    and d.is_active
    and d.account_number is not null
  order by d.sort_order, d.created_at
  limit 1;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.merchant_name, q.merchant_id), '[]'::jsonb)
  into v_filas
  from (
    select
      m.id                              as merchant_id,
      m.name                            as merchant_name,
      m.is_test,
      nullif(btrim(m.email), '')        as email,
      a.merchant_id is not null         as has_payout_account,
      a.bank,
      a.account_holder,
      a.holder_document,
      a.account_number,
      a.pago_movil_phone,
      l.lineas,
      l.pending_usd,
      l.pending_usd_part,
      l.pending_eur,
      case
        when (l.pending_usd_part > 0 and v_usd is null)
          or (l.pending_eur > 0 and v_eur is null) then null
        else coalesce(round(l.pending_usd_part * v_usd, 2), 0)
           + coalesce(round(l.pending_eur * v_eur, 2), 0)
      end                               as pending_ves
    from (
      select
        s.merchant_id,
        count(*)::int                                          as lineas,
        sum(s.amount_usd - s.paid_usd)                         as pending_usd,
        coalesce(sum(coalesce(s.amount_cur, s.amount_usd) - s.paid_cur)
                   filter (where s.currency is distinct from 'EUR'), 0) as pending_usd_part,
        coalesce(sum(coalesce(s.amount_cur, s.amount_usd) - s.paid_cur)
                   filter (where s.currency = 'EUR'), 0)       as pending_eur
      from public.settlements s
      where s.status in ('pending', 'partial')
        and coalesce(s.due_date, s.business_date) < v_corte
      group by s.merchant_id
    ) l
    join public.merchants m on m.id = l.merchant_id
    left join public.merchant_payout_accounts a on a.merchant_id = m.id
    where l.pending_usd > 0.005
  ) q;

  return jsonb_build_object(
    'today_date',    v_hoy,
    'fx_rate_usd',   v_usd,
    'fx_rate_eur',   v_eur,
    'debit_account', v_debito,
    'merchants',     v_filas
  );
end;
$$;

revoke all on function public.admin_bulk_payout_sheet() from public, anon;
grant execute on function public.admin_bulk_payout_sheet() to authenticated;

comment on function public.admin_bulk_payout_sheet() is
  'Lo que se le paga hoy a cada clínica, en bolívares, con su cuenta de transferencia: los datos del archivo de pago masivo del banco. Solo el equipo.';
