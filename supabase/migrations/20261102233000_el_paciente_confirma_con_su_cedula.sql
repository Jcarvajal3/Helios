-- ============================================================================
-- Helios — El paciente confirma con la foto de su cédula (Javier, 2026-11-02;
-- docs/00 §15.11)
--
-- «Cada vez que se registre un nuevo paciente, el usuario debe confirmar
-- enviando su cédula; al enviarla damos por hecho que está confirmando.»
-- Sirve para la cobranza. Sin plantilla nueva de Meta (Javier): la pregunta
-- es la de siempre, con «Sí» / «No».
--
--  1. El paciente que aún no tiene foto de su cédula guardada
--     (`profiles.id_photo_at` null; también los que ya existían) toca «Sí»:
--     la orden queda «aceptó, falta la cédula» (`charges.id_photo_requested_at`)
--     y se le pide la foto. Su «Sí» no confirma nada. Quien ya tiene foto
--     confirma con «Sí» como hasta hoy.
--  2. La foto (una imagen o un PDF) llega al webhook:
--     `helios_patient_id_photo` la anota, la deja como la foto de su perfil y
--     confirma la orden por el mismo camino que el «Sí»
--     (`helios_patient_decision`: revalida el cupo y el estado, avisa al
--     médico). Si la orden venció, la foto se guarda igual y se le contesta
--     lo de siempre. Solo cuenta como cédula la que llega tras tocar «Sí» en
--     esa orden: cualquier otra imagen sigue yendo al lector de comprobantes.
--  3. El plazo no cambia: el «Sí» y la foto, dentro de las 2 horas.
--  4. El lector de comprobantes (la misma Edge Function, la misma cola y los
--     mismos reintentos) baja la foto de 360dialog al bucket PRIVADO
--     `patient-ids` (<perfil>/<wamid>.<ext>) y Claude lee el número y el
--     nombre. La base compara con los del paciente. No deshace nada: si no
--     coincide, no parece una cédula o no se pudo leer, sale la alerta
--     `cedula_no_coincide` en superadmin › Alertas (Javier: confirmar igual y
--     avisar al equipo).
--  5. El superadmin ve la foto en la ficha del paciente: solo el equipo de
--     Helios (`is_platform_admin()`, con MFA; ni la agenda ni el
--     capacitador). Abrirla deja `patient.id_photo_viewed` en la bitácora.
--     El personal de la clínica no la ve: `profiles` y `patient_id_photos`
--     siguen cerrados y el bucket solo deja leer al equipo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El bucket privado
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('patient-ids', 'patient-ids', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;

-- Lo sube el lector con la service_role (no pasa por RLS). Leer: solo el
-- equipo de Helios; el panel lo firma después de `admin_open_patient_id_photo`.
drop policy if exists patient_ids_admin_select on storage.objects;
create policy patient_ids_admin_select on storage.objects
  for select to authenticated
  using (bucket_id = 'patient-ids' and (select public.is_platform_admin()));

-- ---------------------------------------------------------------------------
-- 2. Las fotos
-- ---------------------------------------------------------------------------

create table if not exists public.patient_id_photos (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles (id),
  -- La orden que confirmó (o que ya había vencido).
  charge_id      uuid references public.charges (id),
  -- Un reintento de 360dialog no la anota dos veces.
  wa_message_id  text not null unique,
  phone_e164     text not null,
  media_id       text not null,
  mime           text not null,
  -- En el bucket `patient-ids`. Se fija al llegar; `stored_at` dice si ya se subió.
  storage_path   text not null,
  stored_at      timestamptz,
  status         text not null default 'pendiente'
                 check (status in (
                   'pendiente',         -- por bajar y leer
                   'leyendo',           -- la tiene el lector
                   'coincide',          -- el número y el nombre son los del paciente
                   'no_coincide',       -- reason: numero, nombre o numero_y_nombre
                   'no_es_cedula',      -- el modelo dice que no es una cédula
                   'no_se_pudo_leer',   -- guardada, pero el modelo falló tres veces
                   'no_se_pudo_bajar'   -- 360dialog no la dio en tres intentos
                 )),
  reason         text,
  -- Lo que devolvió el modelo, tal cual, y lo que se comparó.
  extraction     jsonb,
  model          text,
  usage          jsonb,
  read_number    text,
  read_name      text,
  attempts       integer not null default 0,
  taken_at       timestamptz,
  error          text,
  created_at     timestamptz not null default now(),
  reviewed_at    timestamptz
);

comment on table public.patient_id_photos is
  'Cada foto de la cédula que un paciente mandó por WhatsApp para confirmar su pago en cuotas, y lo que leyó el lector (docs/00 §15.11). Solo el equipo de Helios.';

create index if not exists patient_id_photos_profile_idx
  on public.patient_id_photos (profile_id, created_at desc);
create index if not exists patient_id_photos_open_idx
  on public.patient_id_photos (status, created_at)
  where status in ('pendiente', 'leyendo');

alter table public.patient_id_photos enable row level security;
revoke all on public.patient_id_photos from public, anon, authenticated;

alter table public.profiles
  add column if not exists id_photo_path          text,
  add column if not exists id_photo_at            timestamptz,
  add column if not exists id_photo_wa_message_id text;

comment on column public.profiles.id_photo_path is
  'La foto de su cédula en el bucket privado `patient-ids`. Null: aún no la mandó, y su próxima orden se confirma con la foto (docs/00 §15.11).';
comment on column public.profiles.id_photo_at is
  'Cuándo llegó la foto de su cédula por WhatsApp.';
comment on column public.profiles.id_photo_wa_message_id is
  'El wamid del mensaje de WhatsApp que trajo la foto de su cédula.';

alter table public.charges
  add column if not exists id_photo_requested_at timestamptz;

comment on column public.charges.id_photo_requested_at is
  'El paciente tocó «Sí» sin tener foto de su cédula: se le pidió y la orden espera la foto, que es la que la confirma (docs/00 §15.11).';

-- ---------------------------------------------------------------------------
-- 3. ¿Le falta la foto?
-- ---------------------------------------------------------------------------

create or replace function public.helios_patient_needs_id_photo(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select p.id_photo_at is null from public.profiles p where p.id = p_profile_id), true);
$$;

comment on function public.helios_patient_needs_id_photo(uuid) is
  'True si el paciente aún no tiene foto de su cédula guardada: su «Sí» pide la foto y la foto confirma (docs/00 §15.11).';

revoke all on function public.helios_patient_needs_id_photo(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Los textos: pedir la foto y el acuse
-- ---------------------------------------------------------------------------

-- Igual que 20261019000200, con `pide_cedula` y `cedula_recibida` (textos
-- aprobados por Javier el 2026-11-02).
create or replace function public.helios_patient_decision_text(p_charge_id uuid, p_kind text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      public.charges%rowtype;
  v_nombre text;
  v_med    text;
  v_txt    text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return null;
  end if;

  select coalesce(nullif(btrim(p.first_name), ''), nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 1), ''))
    into v_nombre
  from public.profiles p where p.id = v_c.user_id;
  v_med := public.helios_doctor_ref(v_c.merchant_id);

  v_txt := case p_kind
    when 'no' then
      format(E'Entendido%s. No se registró ningún pago en cuotas y no debes nada 💙\nSi fue un error, pídele a %s que te lo envíe de nuevo.',
             coalesce(', ' || v_nombre, ''), v_med)
    when 'vencida' then
      coalesce(v_nombre || ', ', '') ||
      format(E'esta solicitud venció porque pasaron más de 2 horas ⌛. No te preocupes: no se registró nada.\nSi aún quieres pagar tu consulta en cuotas, pídele a %s que te la envíe otra vez.',
             v_med)
    when 'cuota_vencida' then
      coalesce(v_nombre || ', ', '') ||
      'no pudimos confirmar este pago en cuotas porque tienes una cuota pendiente. En cuanto la pagues podrás volver a usar Helios 💙'
    when 'no_disponible' then
      coalesce(v_nombre || ', ', '') ||
      'en este momento no pudimos confirmar tu pago en cuotas y no se registró ningún cargo. Si quieres, te ayudamos por aquí.'
    when 'pide_cedula' then
      'Para confirmar tu pago en cuotas necesitamos una foto de tu cédula 🪪. Envíala por aquí.'
    when 'cedula_recibida' then
      format('✅ ¡Gracias%s! Recibimos tu cédula y tu pago en cuotas quedó confirmado.', coalesce(', ' || v_nombre, ''))
  end;

  -- Sin nombre, la frase empieza con mayúscula.
  return upper(left(v_txt, 1)) || substr(v_txt, 2);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. El «Sí» de quien no tiene foto: se le pide
-- ---------------------------------------------------------------------------

-- Igual que la versión en la base (20261019000200), con el paso del «Sí» sin
-- foto antes de anotar la respuesta.
create or replace function public.helios_patient_decision(
  p_charge_id     uuid,
  p_decision      text,
  p_from_phone    text,
  p_wa_message_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_c        public.charges%rowtype;
  v_p        public.profiles%rowtype;
  v_decision text := lower(btrim(coalesce(p_decision, '')));
  v_msg_id   text := nullif(btrim(coalesce(p_wa_message_id, '')), '');
  v_ok       boolean;
  v_limit    numeric(18,4);
begin
  if v_decision not in ('si', 'no') or v_msg_id is null then
    return jsonb_build_object('ok', false, 'reason', 'peticion_invalida');
  end if;

  -- Un reintento del mismo mensaje: lo que ya se decidió.
  select * into v_c from public.charges where answer_wa_message_id = v_msg_id;
  if found then
    return jsonb_build_object('ok', v_c.status in ('confirmed', 'declined'), 'duplicate', true,
                              'charge_id', v_c.id, 'status', v_c.status::text,
                              'order_number', v_c.order_number);
  end if;

  select * into v_c from public.charges where id = p_charge_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_existe');
  end if;

  if v_c.status <> 'pending' then
    -- NUEVO (2026-10-19): pulsó el botón de una orden que ya venció.
    if v_c.status = 'expired' and v_c.answered_at is null then
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'vencida'));
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_pendiente', 'status', v_c.status::text);
  end if;

  if v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'vencida');
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'vencida'));
    return jsonb_build_object('ok', false, 'reason', 'vencida', 'status', 'expired');
  end if;

  select * into v_p from public.profiles where id = v_c.user_id for update;

  if regexp_replace(coalesce(p_from_phone, ''), '\D', '', 'g')
     <> regexp_replace(coalesce(v_p.phone_e164, '-'), '\D', '', 'g') then
    return jsonb_build_object('ok', false, 'reason', 'otro_telefono');
  end if;

  -- NUEVO (2026-11-02): sin foto de su cédula, el «Sí» no confirma: se le
  -- pide la foto y es la foto la que confirma (`helios_patient_id_photo`).
  -- La respuesta no se anota: la orden sigue pendiente, con su plazo.
  if v_decision = 'si' and v_p.id_photo_at is null then
    update public.charges
       set id_photo_requested_at = coalesce(id_photo_requested_at, now())
     where id = v_c.id;
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'pide_cedula'));
    return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'pending',
                              'reason', 'pide_cedula', 'order_number', v_c.order_number);
  end if;

  update public.charges
     set answered_at = now(), answer_wa_message_id = v_msg_id
   where id = v_c.id;

  if v_decision = 'no' then
    update public.charges
       set status = 'declined', decline_reason = 'paciente'
     where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'rechazada');
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'no'));
    return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'declined',
                              'decline_reason', 'paciente', 'order_number', v_c.order_number);
  end if;

  -- «Sí»: revalidar lo que pudo cambiar mientras esperaba.
  v_ok := v_p.status = 'active'
          and not v_p.is_blacklisted
          and not public.helios_spend_blocked(v_p.id)
          and public.can_take_debt(v_p.id);

  if v_ok then
    begin
      perform public.helios_assert_merchant_operating(v_c.merchant_id);
    exception when others then
      v_ok := false;
    end;
  end if;

  if v_ok then
    -- El cupo ocupado incluye ya la reserva de ESTA orden.
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_ok := public.helios_credit_used_usd(v_p.id) <= coalesce(v_limit, 0);
  end if;

  if v_ok then
    begin
      perform public.helios_finalize_charge(v_c.id, 'whatsapp', null);
    exception when others then
      -- Se deshace todo lo de la confirmación; la orden se rechaza abajo.
      v_ok := false;
    end;
  end if;

  if not v_ok then
    update public.charges
       set status = 'declined', decline_reason = 'no_disponible'
     where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'rechazada');
    -- Al paciente: si debe una cuota, que la pague; si no, sin detalles.
    if public.helios_available_blocked_reason(v_p.id) = 'cuota_vencida' then
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'cuota_vencida'),
                                         '[{"id":"paciente:pagar","title":"Pagar mi cuota"}]'::jsonb);
    else
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'no_disponible'),
                                         '[{"id":"paciente:ayuda","title":"Hablar con alguien"}]'::jsonb);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_disponible', 'charge_id', v_c.id,
                              'status', 'declined', 'order_number', v_c.order_number);
  end if;

  perform public.helios_notify_staff_of_charge(v_c.id, 'aceptada');
  return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'confirmed',
                            'order_number', v_c.order_number);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. La foto llega: se anota y confirma
-- ---------------------------------------------------------------------------

/**
 * Una imagen o un documento del teléfono de un paciente. Si ese teléfono
 * tiene una orden esperando la foto de su cédula (tocó «Sí» sin tenerla), la
 * anota, la deja como la foto de su perfil y confirma la orden por el mismo
 * camino que el «Sí». Si no, `handled` false y el webhook sigue como antes
 * (el bot del paciente y el lector de comprobantes).
 *
 * Cuenta la orden pendiente; también la que venció sin respuesta, si el
 * paciente aún no tiene foto: se guarda y se le dice lo de siempre. Un
 * archivo que no es imagen ni PDF no se guarda: se le vuelve a pedir la foto.
 */
create or replace function public.helios_patient_id_photo(
  p_from_phone    text,
  p_wa_message_id text,
  p_media_id      text,
  p_mime          text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_msg   text := nullif(btrim(coalesce(p_wa_message_id, '')), '');
  v_media text := nullif(btrim(coalesce(p_media_id, '')), '');
  v_mime  text := lower(btrim(coalesce(p_mime, '')));
  v_tel   text := regexp_replace(coalesce(p_from_phone, ''), '\D', '', 'g');
  v_c     public.charges%rowtype;
  v_foto  public.patient_id_photos%rowtype;
  v_ext   text;
  v_ruta  text;
  v_res   jsonb;
  v_acuse uuid;
begin
  if v_msg is null or v_tel = '' then
    return jsonb_build_object('ok', false, 'handled', false, 'reason', 'peticion_invalida');
  end if;

  -- Un reintento del mismo mensaje.
  select * into v_foto from public.patient_id_photos where wa_message_id = v_msg;
  if found then
    return jsonb_build_object('ok', true, 'handled', true, 'duplicate', true, 'id_photo_id', v_foto.id,
                              'charge_id', v_foto.charge_id);
  end if;

  select c.* into v_c
  from public.charges c
  join public.profiles p on p.id = c.user_id
  where regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = v_tel
    and c.id_photo_requested_at is not null
    and c.answered_at is null
    and (c.status = 'pending' or (c.status = 'expired' and p.id_photo_at is null))
    and c.id_photo_requested_at > now() - interval '24 hours'
  order by c.id_photo_requested_at desc
  limit 1
  for update of c;

  if not found then
    return jsonb_build_object('ok', false, 'handled', false, 'reason', 'no_esperada');
  end if;

  if v_media is null or v_mime not in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf') then
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'pide_cedula'));
    return jsonb_build_object('ok', false, 'handled', true, 'reason', 'formato', 'charge_id', v_c.id);
  end if;

  v_ext := case v_mime when 'image/png' then 'png' when 'image/webp' then 'webp'
                       when 'image/heic' then 'heic' when 'application/pdf' then 'pdf' else 'jpg' end;
  v_ruta := v_c.user_id || '/' || regexp_replace(v_msg, '[^A-Za-z0-9._-]', '_', 'g') || '.' || v_ext;

  insert into public.patient_id_photos (profile_id, charge_id, wa_message_id, phone_e164, media_id, mime, storage_path)
  values (v_c.user_id, v_c.id, v_msg, coalesce(public.helios_wa_e164(p_from_phone), p_from_phone), v_media, v_mime, v_ruta)
  returning * into v_foto;

  update public.profiles
     set id_photo_path = v_ruta, id_photo_at = now(), id_photo_wa_message_id = v_msg
   where id = v_c.user_id;

  -- El mismo camino que el «Sí»: con la foto ya guardada, confirma.
  v_res := public.helios_patient_decision(v_c.id, 'si', p_from_phone, v_msg);

  -- El acuse, antes que la bienvenida que encoló la confirmación: salen por
  -- orden de `next_attempt_at` y las dos tienen el mismo now().
  if v_res ->> 'status' = 'confirmed' and public.helios_whatsapp_window_open(p_from_phone) then
    begin
      v_acuse := public.helios_whatsapp_patient_text(
        p_from_phone, public.helios_patient_decision_text(v_c.id, 'cedula_recibida'), v_c.user_id);
      update public.outbound_messages
         set next_attempt_at = now() - interval '1 second'
       where id = v_acuse;
    exception when others then
      raise warning 'No se encoló el acuse de la cédula de %: %', v_c.user_id, sqlerrm;
    end;
  end if;

  return v_res || jsonb_build_object('handled', true, 'id_photo_id', v_foto.id);
end;
$$;

comment on function public.helios_patient_id_photo(text, text, text, text) is
  'El webhook de WhatsApp: una imagen o un PDF de un paciente con una orden esperando la foto de su cédula. La anota y confirma la orden como el «Sí» (docs/00 §15.11, docs/01 §5.2).';

revoke all on function public.helios_patient_id_photo(text, text, text, text) from public, anon, authenticated;
grant execute on function public.helios_patient_id_photo(text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 7. El lector: bajar la foto y leerla
-- ---------------------------------------------------------------------------

/** Las palabras de un nombre, en minúsculas y sin acentos ni partículas. */
create or replace function public.helios_palabras_del_nombre(p text)
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(w order by w), '{}')
  from regexp_split_to_table(
         translate(lower(coalesce(p, '')), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'),
         '[^a-z]+') as w
  where length(w) >= 2 and w not in ('de', 'del', 'la', 'las', 'los', 'y', 'da', 'di', 'van', 'von');
$$;

/**
 * La siguiente tanda de fotos por bajar y leer (como `lector_tomar`). Una que
 * se quedó «leyendo» 10 minutos cuenta como fallo.
 */
create or replace function public.lector_cedula_tomar(p_limit integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid;
  v_rows jsonb;
begin
  for v_id in
    select id from public.patient_id_photos
    where status = 'leyendo' and taken_at < now() - interval '10 minutes'
    for update skip locked
  loop
    perform public.lector_cedula_fallo(v_id, 'El lector no respondió en 10 minutos');
  end loop;

  with tomadas as (
    select id from public.patient_id_photos
    where status = 'pendiente'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
    order by created_at
    limit greatest(1, least(coalesce(p_limit, 3), 10))
    for update skip locked
  ), hechas as (
    update public.patient_id_photos f
       set status = 'leyendo', attempts = f.attempts + 1, taken_at = now()
      from tomadas t
     where f.id = t.id
    returning f.id, f.media_id, f.mime, f.storage_path, f.stored_at, f.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'media_id', media_id, 'mime', mime,
                                               'ruta', storage_path, 'guardada', stored_at is not null)
                            order by created_at), '[]'::jsonb)
    into v_rows
  from hechas;

  return v_rows;
end;
$$;

/**
 * La foto ya está en el bucket (`p_guardada`) aunque la lectura falle: así
 * el siguiente intento no la vuelve a bajar.
 */
create or replace function public.lector_cedula_guardada(p_id uuid)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.patient_id_photos set stored_at = coalesce(stored_at, now()) where id = p_id;
$$;

/**
 * Algo falló: se reintenta hasta tres veces, con dos minutos entre una y
 * otra. A la tercera, alerta para el equipo. Si ni siquiera se pudo bajar, la
 * foto no existe: el perfil vuelve a no tenerla (su próxima orden la pide).
 */
create or replace function public.lector_cedula_fallo(p_id uuid, p_error text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_f public.patient_id_photos%rowtype;
begin
  select * into v_f from public.patient_id_photos where id = p_id for update;
  if not found or v_f.status <> 'leyendo' then
    return v_f.status;
  end if;

  if v_f.attempts < 3 then
    update public.patient_id_photos
       set status = 'pendiente', error = left(p_error, 1000)
     where id = v_f.id;
    return 'pendiente';
  end if;

  update public.patient_id_photos
     set status = case when v_f.stored_at is null then 'no_se_pudo_bajar' else 'no_se_pudo_leer' end,
         error = left(p_error, 1000),
         reviewed_at = now()
   where id = v_f.id
  returning * into v_f;

  if v_f.status = 'no_se_pudo_bajar' then
    update public.profiles
       set id_photo_path = null, id_photo_at = null, id_photo_wa_message_id = null
     where id = v_f.profile_id and id_photo_wa_message_id = v_f.wa_message_id;
  end if;

  return v_f.status;
end;
$$;

/**
 * Lo que leyó el modelo (`es_cedula`, `numero`, `nombres`, `apellidos`). La
 * base compara: el número, solo sus cifras; el nombre, que cada palabra del
 * nombre registrado salga en la cédula (sin acentos ni partículas).
 */
create or replace function public.lector_cedula_leida(
  p_id         uuid,
  p_extraction jsonb,
  p_model      text,
  p_usage      jsonb
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_f       public.patient_id_photos%rowtype;
  v_p       public.profiles%rowtype;
  v_numero  text := nullif(btrim(coalesce(p_extraction ->> 'numero', '')), '');
  v_nombre  text := nullif(btrim(concat_ws(' ', p_extraction ->> 'nombres', p_extraction ->> 'apellidos')), '');
  v_suyo    text[];
  v_leido   text[];
  v_num_ok  boolean;
  v_nom_ok  boolean;
  v_status  text;
  v_reason  text;
begin
  select * into v_f from public.patient_id_photos where id = p_id for update;
  if not found or v_f.status <> 'leyendo' then
    return v_f.status;
  end if;
  select * into v_p from public.profiles where id = v_f.profile_id;

  v_num_ok := v_numero is not null
              and ltrim(regexp_replace(v_numero, '\D', '', 'g'), '0')
                  = ltrim(regexp_replace(coalesce(v_p.document_number, ''), '\D', '', 'g'), '0')
              and regexp_replace(v_numero, '\D', '', 'g') <> '';

  v_suyo  := public.helios_palabras_del_nombre(
               coalesce(nullif(btrim(v_p.full_name), ''), concat_ws(' ', v_p.first_name, v_p.last_name)));
  v_leido := public.helios_palabras_del_nombre(v_nombre);
  v_nom_ok := cardinality(v_suyo) > 0 and v_suyo <@ v_leido;

  if coalesce((p_extraction ->> 'es_cedula')::boolean, false) is not true then
    v_status := 'no_es_cedula';
  elsif v_num_ok and v_nom_ok then
    v_status := 'coincide';
  else
    v_status := 'no_coincide';
    v_reason := case when not v_num_ok and not v_nom_ok then 'numero_y_nombre'
                     when not v_num_ok then 'numero' else 'nombre' end;
  end if;

  update public.patient_id_photos
     set status = v_status, reason = v_reason,
         extraction = p_extraction, model = left(p_model, 200), usage = p_usage,
         read_number = left(v_numero, 40), read_name = left(v_nombre, 200),
         stored_at = coalesce(stored_at, now()), error = null, reviewed_at = now()
   where id = v_f.id;

  return v_status;
end;
$$;

revoke all on function public.helios_palabras_del_nombre(text) from public, anon, authenticated;
revoke all on function public.lector_cedula_tomar(integer) from public, anon, authenticated;
revoke all on function public.lector_cedula_guardada(uuid) from public, anon, authenticated;
revoke all on function public.lector_cedula_fallo(uuid, text) from public, anon, authenticated;
revoke all on function public.lector_cedula_leida(uuid, jsonb, text, jsonb) from public, anon, authenticated;
grant execute on function public.lector_cedula_tomar(integer) to service_role;
grant execute on function public.lector_cedula_guardada(uuid) to service_role;
grant execute on function public.lector_cedula_fallo(uuid, text) to service_role;
grant execute on function public.lector_cedula_leida(uuid, jsonb, text, jsonb) to service_role;

-- El lector se despierta también por una foto de cédula pendiente (igual que
-- 20261021200000, con la segunda cola).
create or replace function public.helios_lector_despertar()
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_url   text;
  v_clave text;
begin
  if not exists (
    select 1 from public.payment_receipt_reads
    where status = 'pendiente'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
  ) and not exists (
    select 1 from public.patient_id_photos
    where status = 'pendiente'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
  ) then
    return false;
  end if;

  v_url   := public.helios_vault_secret('lector_url');
  v_clave := public.helios_vault_secret('lector_clave');
  if v_url is null or v_clave is null then
    return false;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '3000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '5000');
    perform extensions.http((
      'POST', v_url,
      array[extensions.http_header('x-helios-clave', v_clave)],
      'application/json', '{}'
    )::extensions.http_request);
  exception when others then
    raise warning 'lector: no se pudo despertar: %', sqlerrm;
    return false;
  end;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. El superadmin: la foto en la ficha del paciente
-- ---------------------------------------------------------------------------

/** La foto de la cédula de un paciente y lo que leyó el lector (sin abrirla). */
create or replace function public.admin_patient_id_photo(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_p   public.profiles%rowtype;
  v_f   public.patient_id_photos%rowtype;
  v_ord bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_p from public.profiles where id = p_user;
  if not found then
    raise exception 'No existe ese paciente' using errcode = 'P0002';
  end if;

  -- La de su perfil; si no tiene (no se pudo bajar), la última que mandó.
  select * into v_f from public.patient_id_photos
   where profile_id = p_user
   order by (wa_message_id = v_p.id_photo_wa_message_id) desc nulls last, created_at desc
   limit 1;
  if not found then
    return jsonb_build_object('has_photo', false, 'needs_photo', v_p.id_photo_at is null);
  end if;

  select c.order_number into v_ord from public.charges c where c.id = v_f.charge_id;

  return jsonb_build_object(
    'has_photo',    v_p.id_photo_at is not null,
    'needs_photo',  v_p.id_photo_at is null,
    'photo_id',     v_f.id,
    'received_at',  v_f.created_at,
    'stored',       v_f.stored_at is not null,
    'mime',         v_f.mime,
    'status',       v_f.status,
    'reason',       v_f.reason,
    'read_number',  v_f.read_number,
    'read_name',    v_f.read_name,
    'reviewed_at',  v_f.reviewed_at,
    'order_number', v_ord
  );
end;
$$;

/**
 * Abrir la foto: deja `patient.id_photo_viewed` en la bitácora y devuelve su
 * ruta en el bucket privado, que el panel firma por diez minutos (el bucket
 * solo deja leer al equipo de Helios).
 */
create or replace function public.admin_open_patient_id_photo(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_p public.profiles%rowtype;
  v_f public.patient_id_photos%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_p from public.profiles where id = p_user;
  select * into v_f from public.patient_id_photos
   where profile_id = p_user and stored_at is not null
   order by (wa_message_id = v_p.id_photo_wa_message_id) desc nulls last, created_at desc
   limit 1;
  if not found then
    raise exception 'Ese paciente no tiene foto de su cédula guardada' using errcode = 'P0002';
  end if;

  perform audit.log(auth.uid(), 'patient.id_photo_viewed', p_user,
    jsonb_build_object('photo_id', v_f.id, 'path', v_f.storage_path));

  return jsonb_build_object('bucket', 'patient-ids', 'path', v_f.storage_path, 'mime', v_f.mime);
end;
$$;

revoke all on function public.admin_patient_id_photo(uuid) from public, anon;
revoke all on function public.admin_open_patient_id_photo(uuid) from public, anon;
grant execute on function public.admin_patient_id_photo(uuid) to authenticated;
grant execute on function public.admin_open_patient_id_photo(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. La alerta para el equipo: `cedula_no_coincide`
-- ---------------------------------------------------------------------------

-- Igual que la versión en la base, con el tipo nuevo en la lista.
create or replace function public.admin_review_risk_alert(p_alert_key text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_key   text := trim(coalesce(p_alert_key, ''));
  v_note  text := nullif(trim(coalesce(p_note, '')), '');
  v_at    timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_key !~ ('^(relacionada|sobre_cupo|telefono_repetido|correo_repetido|correo_rebotado'
               '|rafaga_de_altas|rafaga_de_pacientes_nuevos|secretaria_concentrada'
               '|impago_primera_cuota_clinica|exposicion_clinica|referencia_repetida'
               '|cupo_al_limite_al_estrenar|consultas_de_cedula_excesivas|cedula_no_coincide)'
               ':[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.+$') then
    raise exception 'No existe la alerta «%»', v_key using errcode = '22023';
  end if;

  insert into public.risk_alert_reviews (alert_key, reviewed_by, reviewed_at, note)
  values (v_key, v_actor, now(), v_note)
  on conflict (alert_key) do update
    set reviewed_by = excluded.reviewed_by,
        reviewed_at = excluded.reviewed_at,
        note        = excluded.note
  returning reviewed_at into v_at;

  perform audit.log(v_actor, 'risk_alert.reviewed', split_part(v_key, ':', 2)::uuid,
    jsonb_build_object(
      'alert_key', v_key,
      'kind',      split_part(v_key, ':', 1),
      'note',      v_note
    ));

  return jsonb_build_object('ok', true, 'alert_key', v_key, 'reviewed_at', v_at);
end;
$$;

-- `admin_risk_alerts`: igual que la versión en la base (20261005000100), con
-- el tipo `cedula_no_coincide` (la CTE `cedula` y su rama del union).

CREATE OR REPLACE FUNCTION public.admin_risk_alerts(p_limit integer DEFAULT 200, p_kinds text[] DEFAULT NULL::text[], p_subject_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_today   date    := public.helios_business_date(now());
  v_limit   integer := greatest(least(coalesce(p_limit, 200), 1000), 1);
  v_window  constant integer := 90;
  -- Antes de esta fecha los límites cambiaron por migración, sin bitácora.
  c_escalera constant date := date '2026-09-10';
  v_desde   date;
  v_semana  date;
  -- Umbrales (docs/01 §3).
  v_altas     numeric := public.helios_parameter('alert_charges_per_merchant_day', 10);
  v_nuevos    numeric := public.helios_parameter('alert_new_patients_per_merchant_day', 8);
  v_staff_pct numeric := public.helios_parameter('alert_staff_share_pct', 80);
  v_staff_min numeric := public.helios_parameter('alert_staff_share_min_charges', 5);
  v_fpd_pct   numeric := public.helios_parameter('alert_fpd_merchant_pct', 25);
  v_fpd_min   numeric := public.helios_parameter('alert_fpd_min_cases', 5);
  v_expo      numeric := public.helios_parameter('alert_merchant_exposure_usd', 3000);
  v_estreno   numeric := public.helios_parameter('alert_first_charge_limit_pct', 90);
  v_consultas integer := public.helios_eligibility_lookups_per_staff_day();
  v_kinds     text[]  := array[
    'telefono_repetido', 'correo_repetido', 'correo_rebotado',
    'rafaga_de_altas', 'rafaga_de_pacientes_nuevos', 'secretaria_concentrada',
    'impago_primera_cuota_clinica', 'exposicion_clinica',
    'referencia_repetida', 'cupo_al_limite_al_estrenar', 'consultas_de_cedula_excesivas',
    'consumo_sobre_cupo', 'cedula_no_coincide'];
  v_out jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_desde  := v_today - (v_window - 1);
  v_semana := date_trunc('week', v_today::timestamp)::date;

  with
  persona as (
    select p.id,
           coalesce(nullif(btrim(p.full_name), ''), nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '')) as nombre,
           p.status::text as status, p.created_at, p.is_test, p.level,
           p.phone_e164, lower(btrim(p.email)) as email, p.email_invalid_at
    from public.profiles p
  ),
  clinica as (
    select m.id, m.name, m.is_test from public.merchants m
  ),

  -- ── Paciente: teléfono y correo repetidos ───────────────────────────────
  tel as (
    select p.phone_e164 as valor, count(*) as n,
           (array_agg(p.id order by p.created_at desc, p.id desc))[1] as nuevo,
           max(p.created_at) as desde,
           jsonb_agg(jsonb_build_object('user_id', p.id, 'full_name', p.nombre, 'status', p.status,
                                        'created_at', p.created_at) order by p.created_at, p.id) as pacientes
    from persona p
    where not p.is_test and p.phone_e164 is not null
    group by p.phone_e164
    having count(*) > 1
  ),
  mail as (
    select p.email as valor, count(*) as n,
           (array_agg(p.id order by p.created_at desc, p.id desc))[1] as nuevo,
           max(p.created_at) as desde,
           jsonb_agg(jsonb_build_object('user_id', p.id, 'full_name', p.nombre, 'status', p.status,
                                        'created_at', p.created_at) order by p.created_at, p.id) as pacientes
    from persona p
    where not p.is_test and p.email is not null and p.email <> ''
    group by p.email
    having count(*) > 1
  ),

  -- ── Paciente: el correo rebotó ──────────────────────────────────────────
  rebote as (
    select p.id, p.email, p.email_invalid_at,
           (select jsonb_build_object('event', o.last_event, 'at', o.last_event_at,
                                      'message_id', o.id, 'template_key', o.template_key)
              from public.outbound_messages o
             where o.profile_id = p.id and o.channel = 'email'
               and o.last_event in ('bounced', 'complained')
             order by o.last_event_at desc nulls last, o.created_at desc
             limit 1) as ultimo
    from persona p
    where p.email_invalid_at is not null and not p.is_test
  ),

  -- ── Clínica: ráfagas de un día ──────────────────────────────────────────
  altas as (
    select c.merchant_id, c.business_date as dia, count(*) as n,
           (array_agg(c.confirmed_at order by c.confirmed_at))[v_altas::integer + 1] as desde
    from public.charges c
    where c.confirmed_at is not null and not c.is_test
      and c.business_date >= v_desde
    group by c.merchant_id, c.business_date
    having count(*) > v_altas
  ),
  nuevos as (
    select p.registered_merchant_id as merchant_id,
           public.helios_business_date(p.created_at) as dia, count(*) as n,
           (array_agg(p.created_at order by p.created_at))[v_nuevos::integer + 1] as desde
    from public.profiles p
    where p.registered_merchant_id is not null and not p.is_test
      and public.helios_business_date(p.created_at) >= v_desde
    group by 1, 2
    having count(*) > v_nuevos
  ),

  -- ── Personal: una sola persona hace casi todas las altas de la semana ──
  semana_staff as (
    select c.merchant_id,
           date_trunc('week', c.business_date::timestamp)::date as lunes,
           c.requested_by as staff_id,
           count(*) as n,
           sum(count(*)) over (partition by c.merchant_id, date_trunc('week', c.business_date::timestamp)) as total,
           max(c.confirmed_at) as ultimo
    from public.charges c
    where c.confirmed_at is not null and not c.is_test
      and c.business_date >= v_desde
    group by c.merchant_id, date_trunc('week', c.business_date::timestamp), c.requested_by
  ),
  concentrada as (
    select s.*, round(s.n * 100.0 / s.total, 1) as pct,
           (select count(distinct mu.user_id) from public.merchant_users mu
             where mu.merchant_id = s.merchant_id and mu.is_active) as personal
    from semana_staff s
    where s.total >= v_staff_min
      and s.n * 100.0 / s.total > v_staff_pct
  ),

  -- ── Clínica: sus pacientes no pagan la 1ª cuota ─────────────────────────
  fpd as (
    select c.merchant_id,
           count(*) as casos,
           count(*) filter (where i.status = 'pending') as impagas,
           max(i.due_date) filter (where i.status = 'pending') as ultima_impaga
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.sequence = 1
      and i.due_date < v_today
      and i.due_date >= v_desde
      and c.status = 'confirmed'
      and not c.is_test and not i.is_test
    group by c.merchant_id
    having count(*) >= v_fpd_min
       and count(*) filter (where i.status = 'pending') * 100.0 / count(*) > v_fpd_pct
  ),

  -- ── Clínica: deuda viva originada ───────────────────────────────────────
  expo as (
    select c.merchant_id,
           sum(i.amount_usd) as deuda,
           sum(i.financed_usd) as principal,
           sum(i.amount_usd) filter (where i.due_date < v_today) as vencida,
           count(distinct i.user_id) as pacientes,
           max(c.confirmed_at) as ultimo
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.status = 'pending'
      and i.written_off_at is null
      and c.status = 'confirmed'
      and not c.is_test and not i.is_test
    group by c.merchant_id
    having sum(i.amount_usd) > v_expo
  ),

  -- ── Paciente: la misma referencia de pago en pacientes distintos ────────
  ref_base as (
    select r.id, r.user_id, r.bank, r.reference, r.status::text as status, r.created_at,
           lower(regexp_replace(r.reference, '[^0-9A-Za-z]', '', 'g')) as ref
    from public.payment_reports r
    join persona p on p.id = r.user_id and not p.is_test
    where r.reference is not null
      and r.status <> 'rejected'
  ),
  refs as (
    select b.ref,
           count(distinct b.user_id) as personas,
           count(distinct lower(btrim(coalesce(b.bank, '')))) = 1 as mismo_banco,
           (array_agg(b.user_id order by b.created_at desc, b.id desc))[1] as nuevo,
           max(b.created_at) as desde,
           jsonb_agg(jsonb_build_object('report_id', b.id, 'user_id', b.user_id, 'bank', b.bank,
                                        'reference', b.reference, 'status', b.status,
                                        'created_at', b.created_at) order by b.created_at) as pagos
    from ref_base b
    where length(b.ref) >= 6
    group by b.ref
    having count(distinct b.user_id) > 1
       and max(b.created_at) >= (v_desde::timestamp at time zone 'America/Caracas')
  ),

  -- ── Paciente: estrenó usando casi todo su cupo ──────────────────────────
  primero as (
    select distinct on (c.user_id)
           c.user_id, c.id as charge_id, c.order_number, c.business_date, c.confirmed_at,
           c.merchant_id, coalesce(c.base_usd, c.amount_usd) as base
    from public.charges c
    where c.confirmed_at is not null and c.user_id is not null and not c.is_test
    order by c.user_id, c.confirmed_at, c.id
  ),
  estreno as (
    select x.*, l.monthly_limit_usd as limite,
           round(x.base * 100.0 / nullif(l.monthly_limit_usd, 0), 1) as pct
    from (
      select pr.*, coalesce(public.helios_level_at(pr.user_id, pr.confirmed_at), p.level) as nivel
      from primero pr
      join persona p on p.id = pr.user_id and not p.is_test
      where pr.business_date >= v_desde
    ) x
    join public.levels l on l.level = x.nivel
    where l.monthly_limit_usd > 0
      and x.base * 100.0 / l.monthly_limit_usd > v_estreno
  ),

  -- ── Personal: consultas de cédula por encima del límite ─────────────────
  consultas as (
    select e.staff_user_id,
           public.helios_business_date(e.created_at) as dia,
           count(*) as n,
           count(*) filter (where e.result = 'limite') as bloqueadas,
           min(e.merchant_id::text)::uuid as merchant_id,
           coalesce((array_agg(e.created_at order by e.created_at))[v_consultas],
                    min(e.created_at) filter (where e.result = 'limite')) as desde
    from public.eligibility_lookups e
    where e.created_at >= (v_desde::timestamp at time zone 'America/Caracas')
    group by e.staff_user_id, public.helios_business_date(e.created_at)
    having count(*) >= v_consultas
        or count(*) filter (where e.result = 'limite') > 0
  ),

  -- ── Paciente: la foto de su cédula no cuadra (2026-11-02) ───────────────
  cedula as (
    select f.id, f.profile_id, f.charge_id, f.status, f.reason, f.read_number, f.read_name,
           coalesce(f.reviewed_at, f.created_at) as desde
    from public.patient_id_photos f
    where f.status in ('no_coincide', 'no_es_cedula', 'no_se_pudo_leer', 'no_se_pudo_bajar')
      and f.created_at >= (v_desde::timestamp at time zone 'America/Caracas')
  ),

  -- ── Paciente: financiamiento sobre el cupo (Ronda) ──────────────────────
  deuda as (
    select
      i.user_id, i.charge_id,
      min(i.created_at)                                             as abierta,
      sum(i.financed_usd)                                           as financiado,
      case when bool_and(i.status = 'paid') then max(i.paid_at) end as saldada
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not c.is_test and not i.is_test
    group by i.user_id, i.charge_id
  ),
  sobre as (
    select
      d.*,
      coalesce((
        select sum(o.financiado) from deuda o
         where o.user_id = d.user_id and o.charge_id <> d.charge_id
           and o.abierta < d.abierta
           and (o.saldada is null or o.saldada > d.abierta)
      ), 0) as ocupado,
      exists (
        select 1 from public.installments j
         where j.user_id = d.user_id and j.charge_id <> d.charge_id and not j.is_test
           and j.created_at < d.abierta
           and j.due_date < public.helios_business_date(d.abierta)
           and (j.paid_at is null or j.paid_at > d.abierta)
      ) as en_mora,
      coalesce(public.helios_level_at(d.user_id, d.abierta), p.level) as nivel
    from deuda d
    join public.profiles p on p.id = d.user_id
    where public.helios_business_date(d.abierta) >= greatest(v_desde, c_escalera)
  ),
  sobre_con_limite as (
    select s.*,
      coalesce((
        select (a.detail -> 'before' ->> 'monthly_limit_usd')::numeric
          from audit.admin_actions a
         where a.action = 'level.configure'
           and (a.detail ->> 'level')::smallint = s.nivel
           and a.created_at > s.abierta
         order by a.created_at
         limit 1
      ), l.monthly_limit_usd) as limite
    from sobre s
    join public.levels l on l.level = s.nivel
  ),
  sobre_cupo as (
    select x.*,
      array_remove(array[
        case when x.ocupado + x.financiado > x.limite + 0.01 then 'sobre_cupo' end,
        case when x.en_mora then 'en_mora' end
      ], null) as motivos
    from sobre_con_limite x
    where x.ocupado + x.financiado > x.limite + 0.01 or x.en_mora
  ),

  -- ── Todas, con la misma forma ───────────────────────────────────────────
  alerta (alert_key, kind, severity, subject_type, subject_id, user_id, merchant_id, detected_at, detail) as (
    select 'telefono_repetido:' || t.nuevo || ':' || t.valor, 'telefono_repetido',
           case when t.n >= 3 then 'alta' else 'media' end,
           'paciente', t.nuevo, t.nuevo, null::uuid, t.desde,
           jsonb_build_object('phone_e164', t.valor, 'patient_count', t.n, 'patients', t.pacientes)
    from tel t

    union all
    select 'correo_repetido:' || m.nuevo || ':' || m.valor, 'correo_repetido',
           case when m.n >= 3 then 'alta' else 'media' end,
           'paciente', m.nuevo, m.nuevo, null::uuid, m.desde,
           jsonb_build_object('email', m.valor, 'patient_count', m.n, 'patients', m.pacientes)
    from mail m

    union all
    select 'correo_rebotado:' || r.id || ':' || coalesce(r.email, ''), 'correo_rebotado', 'alta',
           'paciente', r.id, r.id, null::uuid, r.email_invalid_at,
           jsonb_build_object('email', r.email, 'email_invalid_at', r.email_invalid_at,
                              'event', r.ultimo ->> 'event', 'event_at', r.ultimo ->> 'at',
                              'message_id', r.ultimo ->> 'message_id',
                              'template_key', r.ultimo ->> 'template_key')
    from rebote r

    union all
    select 'rafaga_de_altas:' || a.merchant_id || ':' || a.dia, 'rafaga_de_altas',
           case when a.n > 2 * v_altas then 'alta' else 'media' end,
           'clinica', a.merchant_id, null::uuid, a.merchant_id, a.desde,
           jsonb_build_object('business_date', a.dia, 'charge_count', a.n, 'threshold', v_altas,
                              'merchant_id', a.merchant_id, 'merchant_name', k.name)
    from altas a join clinica k on k.id = a.merchant_id and not k.is_test

    union all
    select 'rafaga_de_pacientes_nuevos:' || n.merchant_id || ':' || n.dia, 'rafaga_de_pacientes_nuevos',
           case when n.n > 2 * v_nuevos then 'alta' else 'media' end,
           'clinica', n.merchant_id, null::uuid, n.merchant_id, n.desde,
           jsonb_build_object('business_date', n.dia, 'patient_count', n.n, 'threshold', v_nuevos,
                              'merchant_id', n.merchant_id, 'merchant_name', k.name)
    from nuevos n join clinica k on k.id = n.merchant_id and not k.is_test

    union all
    select 'secretaria_concentrada:' || s.staff_id || ':' || s.merchant_id || ':' || s.lunes,
           'secretaria_concentrada', 'media',
           'personal', s.staff_id, null::uuid, s.merchant_id, s.ultimo,
           jsonb_build_object('week_start', s.lunes, 'charge_count', s.n, 'merchant_charge_count', s.total,
                              'share_pct', s.pct, 'threshold', v_staff_pct,
                              'active_staff', s.personal,
                              'staff_name', public.helios_staff_name(s.staff_id),
                              'merchant_id', s.merchant_id, 'merchant_name', k.name)
    from concentrada s join clinica k on k.id = s.merchant_id and not k.is_test
    where s.personal >= 2

    union all
    select 'impago_primera_cuota_clinica:' || f.merchant_id || ':' || v_semana,
           'impago_primera_cuota_clinica', 'alta',
           'clinica', f.merchant_id, null::uuid, f.merchant_id,
           ((f.ultima_impaga + 1)::timestamp at time zone 'America/Caracas'),
           jsonb_build_object('cases', f.casos, 'unpaid', f.impagas,
                              'fpd_pct', round(f.impagas * 100.0 / f.casos, 1),
                              'threshold', v_fpd_pct, 'min_cases', v_fpd_min,
                              'window_days', v_window,
                              'merchant_id', f.merchant_id, 'merchant_name', k.name)
    from fpd f join clinica k on k.id = f.merchant_id and not k.is_test

    union all
    select 'exposicion_clinica:' || e.merchant_id || ':' || v_semana, 'exposicion_clinica',
           case when e.deuda > 2 * v_expo then 'alta' else 'media' end,
           'clinica', e.merchant_id, null::uuid, e.merchant_id, e.ultimo,
           jsonb_build_object('exposure_usd', e.deuda, 'principal_usd', e.principal,
                              'overdue_usd', coalesce(e.vencida, 0), 'patient_count', e.pacientes,
                              'threshold', v_expo,
                              'merchant_id', e.merchant_id, 'merchant_name', k.name)
    from expo e join clinica k on k.id = e.merchant_id and not k.is_test

    union all
    select 'referencia_repetida:' || r.nuevo || ':' || r.ref, 'referencia_repetida',
           case when r.mismo_banco then 'alta' else 'media' end,
           'paciente', r.nuevo, r.nuevo, null::uuid, r.desde,
           jsonb_build_object('reference', r.ref, 'patient_count', r.personas,
                              'same_bank', r.mismo_banco, 'reports', r.pagos)
    from refs r

    union all
    select 'cupo_al_limite_al_estrenar:' || x.user_id || ':' || x.charge_id, 'cupo_al_limite_al_estrenar',
           'media', 'paciente', x.user_id, x.user_id, x.merchant_id, x.confirmed_at,
           jsonb_build_object('charge_id', x.charge_id, 'order_number', x.order_number,
                              'business_date', x.business_date, 'financed_usd', x.base,
                              'limit_usd', x.limite, 'used_pct', x.pct, 'level', x.nivel,
                              'threshold', v_estreno,
                              'merchant_id', x.merchant_id, 'merchant_name', k.name)
    from estreno x left join clinica k on k.id = x.merchant_id

    union all
    select 'consultas_de_cedula_excesivas:' || q.staff_user_id || ':' || q.dia,
           'consultas_de_cedula_excesivas', 'alta',
           'personal', q.staff_user_id, null::uuid, q.merchant_id, q.desde,
           jsonb_build_object('business_date', q.dia, 'lookups', q.n, 'blocked', q.bloqueadas,
                              'threshold', v_consultas, 'merchant_id', q.merchant_id,
                              'staff_name', public.helios_staff_name(q.staff_user_id),
                              'merchant_name', k.name)
    from consultas q left join clinica k on k.id = q.merchant_id
    where not coalesce(k.is_test, false)

    union all
    select 'sobre_cupo:' || s.user_id || ':' || s.charge_id, 'consumo_sobre_cupo', 'alta',
           'paciente', s.user_id, s.user_id, c.merchant_id, s.abierta,
           jsonb_build_object('charge_id', s.charge_id, 'order_number', c.order_number,
                              'business_date', c.business_date, 'merchant_name', m.name,
                              'financed_usd', s.financiado, 'used_usd', s.ocupado,
                              'limit_usd', s.limite, 'level', s.nivel,
                              'reasons', to_jsonb(s.motivos))
    from sobre_cupo s
    join public.charges   c on c.id = s.charge_id
    join public.merchants m on m.id = c.merchant_id

    union all
    select 'cedula_no_coincide:' || f.profile_id || ':' || f.id, 'cedula_no_coincide',
           case when f.status in ('no_coincide', 'no_es_cedula') then 'alta' else 'media' end,
           'paciente', f.profile_id, f.profile_id, c.merchant_id, f.desde,
           jsonb_build_object('photo_id', f.id, 'status', f.status, 'reason', f.reason,
                              'read_number', f.read_number, 'read_name', f.read_name,
                              'document', p.document_number, 'charge_id', f.charge_id,
                              'order_number', c.order_number, 'merchant_name', m.name)
    from cedula f
    join public.profiles       p on p.id = f.profile_id
    left join public.charges   c on c.id = f.charge_id
    left join public.merchants m on m.id = c.merchant_id
  ),
  completa as (
    select
      a.alert_key,
      a.kind,
      a.severity,
      a.subject_type,
      a.subject_id,
      case a.subject_type
        when 'paciente' then pe.nombre
        when 'clinica'  then k.name
        when 'personal' then coalesce(public.helios_staff_name(a.subject_id), 'Personal de la clínica')
                             || coalesce(' (' || km.name || ')', '')
      end                              as subject_name,
      a.detected_at                    as first_seen_at,
      a.detail,
      a.user_id,
      pe.nombre                        as full_name,
      pe.status                        as user_status,
      a.merchant_id,
      a.detected_at,
      rv.alert_key is not null         as reviewed,
      rv.reviewed_at,
      rv.reviewed_by,
      pa.full_name                     as reviewed_by_name,
      rv.note                          as review_note
    from alerta a
    left join persona pe on pe.id = a.user_id
    left join clinica k  on k.id = a.subject_id and a.subject_type = 'clinica'
    left join clinica km on km.id = a.merchant_id and a.subject_type = 'personal'
    left join public.risk_alert_reviews rv on rv.alert_key = a.alert_key
    left join public.platform_admins pa    on pa.user_id = rv.reviewed_by
    where a.user_id is null or not pe.is_test
  ),
  pedida as (
    select * from completa c
    where (p_kinds is null or c.kind = any(p_kinds))
      and (p_subject_id is null
           or c.subject_id = p_subject_id
           or c.user_id = p_subject_id
           or c.merchant_id = p_subject_id)
  )
  select jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_window,
    'thresholds', jsonb_build_object(
      'alert_charges_per_merchant_day', v_altas,
      'alert_new_patients_per_merchant_day', v_nuevos,
      'alert_staff_share_pct', v_staff_pct,
      'alert_staff_share_min_charges', v_staff_min,
      'alert_fpd_merchant_pct', v_fpd_pct,
      'alert_fpd_min_cases', v_fpd_min,
      'alert_merchant_exposure_usd', v_expo,
      'alert_first_charge_limit_pct', v_estreno,
      'eligibility_lookups_per_staff_day', v_consultas
    ),
    -- Los tipos siempre, con o sin alertas y sin el filtro de `p_kinds`: son
    -- los contadores de las pestañas (con `p_subject_id`, los de esa ficha).
    'counts', (
      select jsonb_object_agg(x.kind, jsonb_build_object(
        'total',           x.total,
        'unreviewed',      x.unreviewed,
        'unreviewed_high', x.unreviewed_high
      ))
      from (
        select
          k.kind,
          count(c.alert_key)                                                       as total,
          count(c.alert_key) filter (where not c.reviewed)                         as unreviewed,
          count(c.alert_key) filter (where not c.reviewed and c.severity = 'alta') as unreviewed_high
        from unnest(v_kinds) as k(kind)
        left join completa c
          on c.kind = k.kind
         and (p_subject_id is null or c.subject_id = p_subject_id
              or c.user_id = p_subject_id or c.merchant_id = p_subject_id)
        group by k.kind
      ) x
    ),
    'total',     (select count(*) from pedida),
    'truncated', (select count(*) from pedida) > v_limit,
    -- Sin revisar primero, las graves antes, y la más reciente arriba.
    'rows', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.reviewed, s.severity = 'media', s.first_seen_at desc nulls last, s.alert_key)
      from (
        select * from pedida
        order by reviewed, severity = 'media', first_seen_at desc nulls last, alert_key
        limit v_limit
      ) s
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$function$;
