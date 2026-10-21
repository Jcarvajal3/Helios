-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El inbox de WhatsApp distingue a los médicos de los pacientes
--
-- El Inbox de 360dialog no sabe quién es cada número: para él todos son
-- chats. La base sí lo sabe, con la misma regla que el webhook
-- (`helios_whatsapp_inbound`):
--
--   · Médico (o su personal): un número registrado para el bot
--     (`staff_whatsapp_numbers`, sin revocar) de alguien activo en la clínica
--     como gerente o cajero. Gana sobre «paciente», como en el bot.
--   · Paciente: un perfil con ese teléfono o, si no, el que el bot del
--     paciente dejó apuntado en `whatsapp_contacts`.
--   · Ninguno de los dos: no viene en la respuesta.
--
-- La Edge Function `whatsapp-inbox` la llama con los wa_id de cada página
-- de chats (con el JWT de quien pide) para etiquetar cada chat y, si se
-- pide, filtrar por médicos o pacientes.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_whatsapp_inbox_contacts(p_wa_ids text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_out jsonb := '{}'::jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Una página del Inbox trae como mucho 100 chats.
  if coalesce(cardinality(p_wa_ids), 0) > 200 then
    raise exception 'Demasiados chats de una vez' using errcode = '22023';
  end if;

  select coalesce(jsonb_object_agg(x.wa_id, x.quien), '{}'::jsonb)
    into v_out
  from (
    select w.wa_id,
           case
             when m.user_id is not null then jsonb_build_object(
               'tipo', 'medico',
               'nombre', public.helios_staff_name(m.user_id),
               'rol', m.role,
               'merchant_id', m.merchant_id,
               'clinica', m.clinica)
             when p.id is not null then jsonb_build_object(
               'tipo', 'paciente',
               'nombre', coalesce(nullif(btrim(p.full_name), ''),
                                  nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '')),
               'profile_id', p.id)
           end as quien
    from (
      select distinct on (t.e164) t.wa_id, t.e164
      from (select u.v as wa_id, public.helios_wa_e164(u.v) as e164
            from unnest(p_wa_ids) as u(v)) t
      where t.e164 is not null
    ) w
    left join lateral (
      select n.user_id, n.merchant_id, mu.role::text as role, me.name as clinica
      from public.staff_whatsapp_numbers n
      join public.merchant_users mu
        on mu.user_id = n.user_id and mu.merchant_id = n.merchant_id and mu.is_active
       and mu.role in ('gerente', 'cajero')
      join public.merchants me on me.id = n.merchant_id
      where n.phone_e164 = w.e164 and n.revoked_at is null
      order by n.created_at
      limit 1
    ) m on true
    left join lateral (
      select pr.*
      from public.profiles pr
      where pr.id = coalesce(
        (select q.id from public.profiles q
          where q.phone_e164 = w.e164
          order by q.created_at desc limit 1),
        (select coalesce(c.patient_profile_id, c.profile_id)
           from public.whatsapp_contacts c
          where c.phone_e164 = w.e164))
    ) p on m.user_id is null
  ) x
  where x.quien is not null;

  return v_out;
end;
$$;

comment on function public.admin_whatsapp_inbox_contacts(text[]) is
  'Quién es cada chat del inbox de WhatsApp: {wa_id: {tipo: medico|paciente, nombre, …}} con la regla del webhook (el número del bot gana sobre el perfil). Solo personal de Helios (is_platform_admin). La llama la Edge Function whatsapp-inbox.';

revoke all on function public.admin_whatsapp_inbox_contacts(text[]) from public, anon;
grant execute on function public.admin_whatsapp_inbox_contacts(text[]) to authenticated;
