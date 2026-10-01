-- ============================================================================
-- Helios — El historial de correos dice los rebotados (H6/H7)
--
-- El panel (Avisos › Historial) filtra los correos por lo que pasó en Resend,
-- no solo por el estado de la cola: `admin_outbound_history(p_status =>
-- 'rebotado')` trae los que rebotaron o se marcaron como spam, y
-- `'entregado'` los entregados. Lo demás, igual que en 20261004000200.
-- ============================================================================

/**
 * El historial de la cola, correos incluidos (docs/01 §2.2). Filtros
 * opcionales: canal, estado y `p_q` (nombre, cédula, teléfono, correo, número
 * de orden o id del proveedor). Lo más nuevo primero. `total_count` es el
 * total con los filtros, para paginar.
 *
 * Además de los estados de la cola, `p_status` acepta los del correo en
 * Resend: `rebotado` (last_event bounced o complained) y `entregado`
 * (delivered, opened o clicked).
 */
create or replace function public.admin_outbound_history(
  p_channel text    default null,
  p_status  text    default null,
  p_q       text    default null,
  p_limit   integer default 50,
  p_offset  integer default 0
)
returns table (
  id              uuid,
  channel         text,
  template_key    text,
  template_label  text,
  profile_id      uuid,
  patient_name    text,
  phone_e164      text,
  email           text,
  charge_id       uuid,
  order_number    bigint,
  due_date        date,
  subject         text,
  rendered_text   text,
  status          text,
  provider_id     text,
  last_event      text,
  last_event_at   timestamptz,
  attempts        integer,
  next_attempt_at timestamptz,
  last_error      text,
  created_at      timestamptz,
  sent_at         timestamptz,
  sent_by_name    text,
  total_count     bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_q      text := nullif(lower(btrim(coalesce(p_q, ''))), '');
  v_digits text;
  v_limit  integer := greatest(least(coalesce(p_limit, 50), 500), 1);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_digits := nullif(regexp_replace(coalesce(v_q, ''), '\D', '', 'g'), '');

  return query
  select
    o.id, o.channel, o.template_key, t.label,
    o.profile_id,
    coalesce(nullif(btrim(p.full_name), ''), btrim(concat_ws(' ', p.first_name, p.last_name))),
    coalesce(case when o.channel = 'whatsapp_manual' then o.recipient end, p.phone_e164),
    case when o.channel = 'email' then o.recipient else p.email end,
    o.charge_id, c.order_number, o.installment_due_date,
    o.subject, o.rendered_text, o.status,
    o.provider_id, o.last_event, o.last_event_at, o.attempts, o.next_attempt_at, o.last_error,
    o.created_at, o.sent_at,
    case when o.sent_by is not null then coalesce(pa.full_name, 'Alguien del equipo') end,
    count(*) over ()
  from public.outbound_messages o
  join public.notification_templates t on t.key = o.template_key
  join public.profiles p on p.id = o.profile_id
  left join public.charges c on c.id = o.charge_id
  left join public.platform_admins pa on pa.user_id = o.sent_by
  where (p_channel is null or o.channel = p_channel)
    and (
      p_status is null
      or (p_status = 'rebotado'  and o.last_event in ('bounced', 'complained'))
      or (p_status = 'entregado' and o.last_event in ('delivered', 'opened', 'clicked'))
      or (p_status not in ('rebotado', 'entregado') and o.status = p_status)
    )
    and (
      v_q is null
      or lower(coalesce(p.full_name, concat_ws(' ', p.first_name, p.last_name))) like '%' || v_q || '%'
      or lower(coalesce(o.recipient, '')) like '%' || v_q || '%'
      or lower(coalesce(p.email, '')) like '%' || v_q || '%'
      or lower(coalesce(o.provider_id, '')) = v_q
      or (v_digits is not null and (
            coalesce(p.document_number, '') like '%' || v_digits || '%'
            or regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') like '%' || v_digits || '%'
            or c.order_number::text = v_digits))
    )
  order by o.created_at desc, o.id
  limit v_limit offset v_offset;
end;
$$;

revoke all on function public.admin_outbound_history(text, text, text, integer, integer) from public, anon;
grant execute on function public.admin_outbound_history(text, text, text, integer, integer) to authenticated;
