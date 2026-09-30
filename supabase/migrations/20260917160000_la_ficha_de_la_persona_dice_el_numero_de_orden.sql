-- ============================================================================
-- Ronda — La ficha de la persona dice el número de orden
--
-- «Consumos y cuotas» enseñaba día, local, monto y estado. Para saber de qué
-- orden hablaba una fila había que abrir Consumos y buscarla por fecha y
-- comercio, aunque la persona que llama ya lo tiene delante: el número es lo
-- que el local dicta y lo único que identifica una orden entre cientos
-- (20260822250000).
--
-- Se añade `order_number` a las dos listas —los consumos y las cuotas— para
-- que el panel pueda enseñarlo y, al pulsar una fila, abrir la factura del
-- consumo (`/admin/consumos/$id`, que ya existe). La cuota ya traía su
-- `charge_id`, así que la fila de una cuota lleva a la misma ficha que la de
-- su consumo.
--
-- ADITIVA: ninguna clave cambia de significado ni desaparece. El panel lee
-- `order_number` como opcional, así que sin esta migración aplicada la
-- columna sale con un guion en vez de romperse.
--
-- Cuerpo idéntico al de 20260911180000 salvo las dos claves nuevas.
-- ============================================================================

create or replace function public.admin_user_detail(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'is_test', p.is_test,
    'created_at', p.created_at
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at
  ));

  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd) filter (where status = 'pending'), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and due_date < v_today), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      -- El número de la orden de la que sale esta cuota: es lo que el equipo
      -- teclea en el buscador y lo que el local dicta por teléfono.
      'order_number', ch.order_number,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0)
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'order_number', ch.order_number,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'status', v.status,
      'rejection_reason', v.rejection_reason,
      'rejection_detail', v.rejection_detail,
      'reviewed_at', v.reviewed_at,
      'created_at', v.created_at
    )
    from kyc.verifications v
    where v.user_id = p_user_id
    order by v.created_at desc limit 1
  ));

  -- Bits. El saldo va con SUS MOVIMIENTOS y no solo con la cifra: la pregunta
  -- que llega a soporte no es cuántos tiene, es de dónde salieron.
  v_result := v_result || jsonb_build_object('bits', (
    select jsonb_build_object(
      'balance', coalesce(sum(amount), 0),
      'awarded_count', count(*) filter (where amount > 0),
      'last_award_at', max(created_at) filter (where amount > 0)
    )
    from public.bits_entries where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('bits_entries', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id,
      'amount', e.amount,
      'reason', e.reason,
      'created_at', e.created_at,
      -- De qué cuota salió. `business_date` es el día de la COMPRA, que con la
      -- escalera es la mitad de la explicación: los Bits son la distancia
      -- entre esa fecha y el día en que se pagó.
      'business_date', ch.business_date,
      'due_date', i.due_date,
      'paid_at', i.paid_at,
      'merchant_name', m.name
    ) order by e.created_at desc)
    from public.bits_entries e
    left join public.installments i on i.id = e.installment_id
    left join public.charges ch on ch.id = i.charge_id
    left join public.merchants m on m.id = ch.merchant_id
    where e.user_id = p_user_id
  ), '[]'::jsonb));

  return v_result;
end;
$$;

revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;
