-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El inbox de WhatsApp señala a los interesados del directorio
--
-- Quien toca el botón de una tarjeta del directorio (`/directorio` o
-- `/consultas`) escribe al WhatsApp de Helios con el código DIR-XXXX y queda
-- en `directory_leads` (`bot_directorio_interesado`). Desde el 2026-11-09 el
-- bot le pide día y hora para la cita y el equipo sigue la conversación a
-- mano desde superadmin › WhatsApp: ahí hace falta verlos aparte y saber con
-- qué médico agendar.
--
-- `admin_whatsapp_inbox_contacts` (de 20261021230000, todo igual) añade a
-- cada chat `interesado` si su teléfono está en `directory_leads`, sea de la
-- variante que sea:
--
--   {wa_id: {tipo?, …, interesado: {medicos: [{merchant_id, medico,
--            variante, first_at, last_at}]}}}
--
-- `medicos`: uno por médico por el que escribió, el último mensaje primero;
-- `medico` es el nombre de la tarjeta (el propio o el de la ficha, como
-- `admin_directorio_interesados`). Un interesado que no es médico ni
-- paciente viene sin `tipo`, solo con `interesado`; uno que además es
-- paciente (o médico) trae las dos cosas. La Edge Function `whatsapp-inbox`
-- filtra con `?quien=directorio` los que traen `interesado`.
-- ═══════════════════════════════════════════════════════════════════════════

-- Buscar los interesados por teléfono sin recorrer la tabla (la clave única
-- empieza por el médico).
create index if not exists directory_leads_phone_idx
  on public.directory_leads (phone_e164);

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
           nullif(
             coalesce(
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
               end,
               '{}'::jsonb)
             || case
                  when i.medicos is not null then
                    jsonb_build_object('interesado', jsonb_build_object('medicos', i.medicos))
                  else '{}'::jsonb
                end,
             '{}'::jsonb) as quien
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
    -- Los médicos por los que escribió desde el directorio (cualquier
    -- variante), el último mensaje primero. Sin ninguno, null.
    left join lateral (
      select jsonb_agg(jsonb_build_object(
               'merchant_id', l.merchant_id,
               'medico', coalesce(dl.display_name, public.helios_doctor_name(l.merchant_id)),
               'variante', l.variant,
               'first_at', l.first_at,
               'last_at', l.last_at)
             order by l.last_at desc, l.first_at desc, l.id) as medicos
      from public.directory_leads l
      left join public.directory_listings dl on dl.merchant_id = l.merchant_id
      where l.phone_e164 = w.e164
    ) i on true
  ) x
  where x.quien is not null;

  return v_out;
end;
$$;

comment on function public.admin_whatsapp_inbox_contacts(text[]) is
  'Quién es cada chat del inbox de WhatsApp: {wa_id: {tipo: medico|paciente, nombre, …, interesado: {medicos: [{merchant_id, medico, variante, first_at, last_at}]}}} con la regla del webhook (el número del bot gana sobre el perfil); `interesado` si el teléfono está en directory_leads (un interesado sin perfil viene solo con él). Solo personal de Helios (is_platform_admin). La llama la Edge Function whatsapp-inbox.';

revoke all on function public.admin_whatsapp_inbox_contacts(text[]) from public, anon;
grant execute on function public.admin_whatsapp_inbox_contacts(text[]) to authenticated;
