-- ============================================================================
-- Helios — El aviso del BNC respalda un pago en su ficha
--
-- La ficha de un pago registrado (Pagos reportados › un pago) solo cotejaba
-- contra el extracto importado. Sin extracto todavía, quien aprobaba tenía que
-- marcar «Aprobar sin cotejo» y escribir un motivo aunque el SMS del BNC de
-- ese Pago Móvil ya hubiera llegado. Ahora la ficha enseña los avisos del BNC
-- que encajan con el pago, como respaldo para decidir.
--
-- `admin_bank_sms_for_report`: los avisos ligados a ese pago y los que
-- encajan por referencia (la misma regla que el bot,
-- `helios_bank_sms_ref_match`), con el monto (±1 Bs) y el día
-- (`helios_bank_sms_day_match`) dichos aparte. Solo lectura.
-- ============================================================================

create or replace function public.admin_bank_sms_for_report(p_report_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_pr   public.payment_reports%rowtype;
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_pr from public.payment_reports where id = p_report_id;
  if not found then
    raise exception 'No existe ese pago' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',            n.id,
      'received_at',   n.received_at,
      'reference',     n.reference,
      'amount_ves',    n.amount_ves,
      'payer_phone',   case when n.payer_phone_prefix is not null and n.payer_phone_last4 is not null
                            then n.payer_phone_prefix || '***' || n.payer_phone_last4 end,
      'paid_at',       n.paid_at,
      'outcome',       n.outcome,
      'linked',        n.report_id = v_pr.id,
      'linked_other',  n.report_id is not null and n.report_id <> v_pr.id,
      'amount_ok',     v_pr.declared_amount_ves is not null and n.amount_ves is not null
                         and abs(n.amount_ves - v_pr.declared_amount_ves) <= 1,
      'day_ok',        n.paid_at is not null
                         and public.helios_bank_sms_day_match(n.paid_at, v_pr.paid_on, v_pr.created_at)
    ) order by (n.report_id = v_pr.id) desc, n.received_at desc), '[]'::jsonb)
  into v_rows
  from public.bank_sms_notices n
  where n.report_id = v_pr.id
     or public.helios_bank_sms_ref_match(n.reference, v_pr.reference);

  return jsonb_build_object('report_id', v_pr.id, 'notices', v_rows);
end;
$$;

comment on function public.admin_bank_sms_for_report(uuid) is
  'Los avisos del BNC (SMS) ligados a un pago registrado o que encajan con su referencia, con el monto y el día cotejados aparte. Solo lectura.';

revoke all on function public.admin_bank_sms_for_report(uuid) from public, anon;
grant execute on function public.admin_bank_sms_for_report(uuid) to authenticated;
