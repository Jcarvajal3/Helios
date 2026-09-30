-- El motivo que el panel pide y no se guardaba.
--
-- Los diálogos del panel piden un motivo para cambiar la cuenta de cobro, el
-- mantenimiento, una promoción, el equipo, los avisos automáticos y los
-- niveles, pero estas funciones no tenían dónde recibirlo y se perdía. Cada una
-- gana p_note text default null AL FINAL, lo lleva a su línea de la bitácora
-- como 'note' (la clave que el panel ya pinta como motivo) y sigue aceptando la
-- llamada vieja sin él. Ninguna tabla gana columnas: la bitácora es el registro.
--
-- Cambia la firma, así que se crea la nueva y se borra la vieja: con las dos
-- vivas, PostgREST no sabría a cuál llamar.
--
-- De paso, las ocho que miraban platform_admins a mano pasan a
-- helios_assert_super_admin (segundo factor, 20260925131000), y
-- admin_set_level_config deja de llamar a is_super_admin(uuid), que ninguna
-- migración crea: desde 20260909191000 fallaba siempre (en dev, comprobado).
--
-- Los cuerpos son los vivos de dev; solo cambian la firma, la guarda y el
-- detalle de la bitácora.

-- admin_set_payment_destination: (text, text, text, text) → (text, text, text, text, text)
CREATE OR REPLACE FUNCTION public.admin_set_payment_destination(p_bank_name text, p_rif text, p_phone text, p_holder_name text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
begin
  perform public.helios_assert_super_admin('cambiar la cuenta de cobro');

  if coalesce(trim(p_bank_name), '') = ''
     or coalesce(trim(p_rif), '') = ''
     or coalesce(trim(p_phone), '') = '' then
    raise exception 'Banco, RIF y teléfono son obligatorios' using errcode = '22023';
  end if;

  update public.payment_destinations set is_active = false where is_active;

  insert into public.payment_destinations (bank_name, rif, phone, holder_name, is_active)
  values (trim(p_bank_name), trim(p_rif), trim(p_phone),
          nullif(trim(coalesce(p_holder_name, '')), ''), true)
  returning id into v_id;

  perform audit.log(v_actor, 'payment_destination.set', v_id, jsonb_build_object(
    'bank_name', p_bank_name, 'rif', p_rif, 'phone', p_phone, 'holder_name', p_holder_name,
    'note', nullif(trim(p_note), '')
  ));

  return v_id;
end;
$function$;

revoke all on function public.admin_set_payment_destination(text, text, text, text, text) from public, anon;
grant execute on function public.admin_set_payment_destination(text, text, text, text, text) to authenticated, service_role;
drop function if exists public.admin_set_payment_destination(text, text, text, text);

-- admin_set_maintenance: (boolean, boolean, text, text, text) → (boolean, boolean, text, text, text, text)
CREATE OR REPLACE FUNCTION public.admin_set_maintenance(p_is_active boolean, p_blocks_balance boolean, p_title text, p_message text, p_expected_back text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := public.helios_assert_super_admin('encender el mantenimiento');
  v_before public.platform_maintenance%rowtype;
begin
  select * into v_before from public.platform_maintenance;

  if p_is_active then
    if p_title is null or length(trim(p_title)) < 3 then
      raise exception 'El aviso necesita un título' using errcode = '22023';
    end if;
    if p_message is null or length(trim(p_message)) < 10 then
      raise exception 'Explica qué pasa: es lo único que el usuario va a leer'
        using errcode = '22023';
    end if;
  end if;

  update public.platform_maintenance set
    is_active      = p_is_active,
    blocks_balance = p_blocks_balance,
    title          = coalesce(nullif(trim(coalesce(p_title, '')), ''), title),
    message        = coalesce(nullif(trim(coalesce(p_message, '')), ''), message),
    expected_back  = nullif(trim(coalesce(p_expected_back, '')), ''),
    -- Cuándo empezó ESTE episodio. Se conserva mientras siga encendido para
    -- poder decir cuánto lleva caído.
    started_at     = case
      when p_is_active and not v_before.is_active then now()
      when p_is_active then v_before.started_at
      else null
    end,
    updated_by     = v_actor,
    updated_at     = now()
  where id;

  perform audit.log(
    v_actor,
    case when p_is_active then 'maintenance.on' else 'maintenance.off' end,
    null,
    jsonb_build_object(
      'before', jsonb_build_object(
        'is_active', v_before.is_active,
        'blocks_balance', v_before.blocks_balance
      ),
      'after', jsonb_build_object(
        'is_active', p_is_active,
        'blocks_balance', p_blocks_balance,
        'title', p_title,
        'message', p_message,
        'expected_back', p_expected_back
      ),
      'note', nullif(trim(p_note), '')
    )
  );

  return public.helios_maintenance();
end;
$function$;

revoke all on function public.admin_set_maintenance(boolean, boolean, text, text, text, text) from public, anon;
grant execute on function public.admin_set_maintenance(boolean, boolean, text, text, text, text) to authenticated, service_role;
drop function if exists public.admin_set_maintenance(boolean, boolean, text, text, text);

-- admin_send_promo: (text, text, text, integer, text) → (text, text, text, integer, text, text)
CREATE OR REPLACE FUNCTION public.admin_send_promo(p_title text, p_body text, p_audience text, p_level integer DEFAULT NULL::integer, p_href text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_title    text := trim(coalesce(p_title, ''));
  v_body     text := trim(coalesce(p_body, ''));
  v_campaign public.promo_campaigns%rowtype;
  v_people   integer;
  v_devices  integer;
begin
  perform public.helios_assert_super_admin('mandar promociones');

  -- Los límites son de la bandeja del sistema, no nuestros: Android corta el
  -- título sobre los 65 caracteres y el cuerpo sobre los 240 cuando el aviso
  -- está plegado. Dejar escribir más es dejar mandar una frase que nadie va a
  -- leer entera.
  if length(v_title) = 0 or length(v_title) > 65 then
    raise exception 'El título va entre 1 y 65 caracteres' using errcode = '22023';
  end if;

  if length(v_body) = 0 or length(v_body) > 240 then
    raise exception 'El texto va entre 1 y 240 caracteres' using errcode = '22023';
  end if;

  if p_audience not in ('all', 'active', 'level', 'dormant') then
    raise exception 'Público desconocido: %', p_audience using errcode = '22023';
  end if;

  if p_audience = 'level' and (p_level is null or p_level not between 1 and 5) then
    raise exception 'Ese público necesita un nivel del 1 al 5' using errcode = '22023';
  end if;

  if p_href is not null and p_href not in (
    '/(app)', '/(app)/buscar', '/(app)/grupos', '/(app)/pagos', '/(app)/niveles'
  ) then
    raise exception 'Destino no permitido: %', p_href using errcode = '22023';
  end if;

  -- El doble clic del que manda. Sin esto, dos toques seguidos son dos avisos
  -- idénticos en la pantalla de todo el mundo, y el segundo ya no se puede
  -- recoger.
  if exists (
    select 1 from public.promo_campaigns
    where title = v_title and body = v_body
      and created_at > now() - interval '10 minutes'
  ) then
    raise exception 'Esa misma promoción se mandó hace menos de 10 minutos'
      using errcode = '23505';
  end if;

  insert into public.promo_campaigns (title, body, audience, level, href, sent_by)
  values (v_title, v_body, p_audience, p_level, p_href, v_actor)
  returning * into v_campaign;

  -- Un solo INSERT para todos: el trigger de push se dispara fila a fila y
  -- deja la cola lista. Nada sale a la red desde aquí — el envío real lo hace
  -- el cron unos segundos después, así que el panel no se queda colgado
  -- esperando a Expo con 4.000 mensajes por delante.
  with nuevos as (
    insert into public.notifications (user_id, type, title, body, data, campaign_id)
    select a.user_id, 'promo', v_title, v_body,
           jsonb_strip_nulls(jsonb_build_object('campaign_id', v_campaign.id, 'href', p_href)),
           v_campaign.id
    from public.promo_audience(p_audience, p_level) a
    returning 1
  )
  select count(*) into v_people from nuevos;

  select count(*) into v_devices
  from public.push_deliveries d
  join public.notifications n on n.id = d.notification_id
  where n.campaign_id = v_campaign.id;

  update public.promo_campaigns
     set recipients = v_people, devices = v_devices
   where id = v_campaign.id;

  perform audit.log(v_actor, 'promo.send', v_campaign.id,
    jsonb_build_object('title', v_title, 'audience', p_audience,
                       'level', p_level, 'people', v_people, 'devices', v_devices,
                       'note', nullif(trim(p_note), '')));

  return jsonb_build_object(
    'campaign_id', v_campaign.id,
    'people', v_people,
    'devices', v_devices
  );
end;
$function$;

revoke all on function public.admin_send_promo(text, text, text, integer, text, text) from public, anon;
grant execute on function public.admin_send_promo(text, text, text, integer, text, text) to authenticated, service_role;
drop function if exists public.admin_send_promo(text, text, text, integer, text);
comment on function public.admin_send_promo(text, text, text, integer, text, text) is
  'Manda una promoción a un público. Solo super admin; queda en la bitácora, con el motivo si lo hay.';

-- admin_set_platform_admin: (text, text, text, platform_role) → (text, text, text, platform_role, text)
CREATE OR REPLACE FUNCTION public.admin_set_platform_admin(p_email text, p_password text, p_full_name text, p_role platform_role, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_user  uuid;
begin
  perform public.helios_assert_super_admin('dar de alta al equipo');

  v_user := public.admin_create_auth_account(p_email, p_password, p_full_name);

  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_user, p_role, nullif(trim(coalesce(p_full_name, '')), ''), true);

  perform audit.log(v_actor, 'platform_admin.set', v_user, jsonb_build_object(
    'email', lower(trim(p_email)), 'role', p_role, 'full_name', p_full_name,
    'note', nullif(trim(p_note), '')
  ));

  return v_user;
end;
$function$;

revoke all on function public.admin_set_platform_admin(text, text, text, platform_role, text) from public, anon;
grant execute on function public.admin_set_platform_admin(text, text, text, platform_role, text) to authenticated, service_role;
drop function if exists public.admin_set_platform_admin(text, text, text, platform_role);

-- admin_revoke_platform_admin: (uuid) → (uuid, text)
CREATE OR REPLACE FUNCTION public.admin_revoke_platform_admin(p_user_id uuid, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_super_admin('revocar accesos');

  if p_user_id = v_actor then
    raise exception 'No puedes revocarte a ti mismo' using errcode = '22023';
  end if;

  update public.platform_admins set is_active = false where user_id = p_user_id;

  perform audit.log(v_actor, 'platform_admin.revoke', p_user_id,
    jsonb_build_object('note', nullif(trim(p_note), '')));
end;
$function$;

revoke all on function public.admin_revoke_platform_admin(uuid, text) from public, anon;
grant execute on function public.admin_revoke_platform_admin(uuid, text) to authenticated, service_role;
drop function if exists public.admin_revoke_platform_admin(uuid);

-- admin_restore_platform_admin: (uuid, platform_role) → (uuid, platform_role, text)
CREATE OR REPLACE FUNCTION public.admin_restore_platform_admin(p_user_id uuid, p_role platform_role DEFAULT NULL::platform_role, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_role  public.platform_role;
begin
  perform public.helios_assert_super_admin('devolver accesos');

  select role into v_role from public.platform_admins where user_id = p_user_id;

  if v_role is null then
    raise exception 'Esa persona nunca tuvo acceso al panel' using errcode = '22023';
  end if;

  update public.platform_admins
     set is_active = true,
         role      = coalesce(p_role, role)
   where user_id = p_user_id;

  perform audit.log(v_actor, 'platform_admin.restore', p_user_id, jsonb_build_object(
    'role', coalesce(p_role, v_role),
    'note', nullif(trim(p_note), '')
  ));
end;
$function$;

revoke all on function public.admin_restore_platform_admin(uuid, platform_role, text) from public, anon;
grant execute on function public.admin_restore_platform_admin(uuid, platform_role, text) to authenticated, service_role;
drop function if exists public.admin_restore_platform_admin(uuid, platform_role);

-- admin_publish_notification_template: (text) → (text, text)
CREATE OR REPLACE FUNCTION public.admin_publish_notification_template(p_key text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_tpl   public.notification_templates%rowtype;
begin
  perform public.helios_assert_super_admin('publicar un aviso');

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if v_tpl.draft_title is null or v_tpl.draft_body is null then
    raise exception 'No hay borrador que publicar' using errcode = '22023';
  end if;

  update public.notification_templates
     set title        = v_tpl.draft_title,
         body         = v_tpl.draft_body,
         published_by = v_actor,
         published_at = now(),
         draft_title  = null,
         draft_body   = null,
         draft_by     = null,
         draft_at     = null
   where key = p_key;

  perform audit.log(v_actor, 'notification.publish', null::uuid,
    jsonb_build_object('key', p_key,
                       'title', v_tpl.draft_title,
                       'body', v_tpl.draft_body,
                       'note', nullif(trim(p_note), '')));
end;
$function$;

revoke all on function public.admin_publish_notification_template(text, text) from public, anon;
grant execute on function public.admin_publish_notification_template(text, text) to authenticated, service_role;
drop function if exists public.admin_publish_notification_template(text);

-- admin_reset_notification_template: (text) → (text, text)
CREATE OR REPLACE FUNCTION public.admin_reset_notification_template(p_key text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_super_admin('volver al texto original de un aviso');

  update public.notification_templates
     set title = null, body = null, published_by = null, published_at = null
   where key = p_key;

  perform audit.log(v_actor, 'notification.reset', null::uuid,
    jsonb_build_object('key', p_key, 'note', nullif(trim(p_note), '')));
end;
$function$;

revoke all on function public.admin_reset_notification_template(text, text) from public, anon;
grant execute on function public.admin_reset_notification_template(text, text) to authenticated, service_role;
drop function if exists public.admin_reset_notification_template(text);

-- admin_set_notification_enabled: (text, boolean) → (text, boolean, text)
CREATE OR REPLACE FUNCTION public.admin_set_notification_enabled(p_key text, p_enabled boolean, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_tpl   public.notification_templates%rowtype;
begin
  perform public.helios_assert_super_admin('encender o apagar un aviso');

  select * into v_tpl from public.notification_templates where key = p_key;
  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  if not p_enabled and not v_tpl.can_disable then
    raise exception '"%" no se puede apagar: %', v_tpl.label,
      coalesce(v_tpl.help, 'es información que la persona tiene derecho a recibir')
      using errcode = '42501';
  end if;

  update public.notification_templates set enabled = p_enabled where key = p_key;

  perform audit.log(v_actor,
    case when p_enabled then 'notification.enable' else 'notification.disable' end,
    null::uuid, jsonb_build_object('key', p_key, 'note', nullif(trim(p_note), '')));
end;
$function$;

revoke all on function public.admin_set_notification_enabled(text, boolean, text) from public, anon;
grant execute on function public.admin_set_notification_enabled(text, boolean, text) to authenticated, service_role;
drop function if exists public.admin_set_notification_enabled(text, boolean);

-- admin_set_level_config: (smallint, numeric, numeric, smallint, boolean, text) → (smallint, numeric, numeric, smallint, boolean, text, text)
CREATE OR REPLACE FUNCTION public.admin_set_level_config(p_level smallint, p_monthly_limit_usd numeric, p_required_spend_usd numeric, p_required_months smallint, p_is_active boolean, p_label text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_before jsonb;
begin
  perform public.helios_assert_super_admin('configurar los niveles');

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  if p_level = 0 then
    raise exception 'El nivel 0 no se configura: es no tener nivel, y se sale de él verificando la identidad'
      using errcode = '22023';
  end if;

  if p_monthly_limit_usd < 0 or p_required_spend_usd < 0 or p_required_months < 0 then
    raise exception 'Los valores de un nivel no pueden ser negativos'
      using errcode = '22023';
  end if;

  -- Activar un nivel con límite cero le daría a quien ascienda un cupo de
  -- cero: subiría de nivel para no poder gastar.
  if p_is_active and p_monthly_limit_usd <= 0 then
    raise exception 'Un nivel activo necesita un límite mayor que cero'
      using errcode = '22023';
  end if;

  select to_jsonb(l) into v_before from public.levels l where l.level = p_level;
  if v_before is null then
    raise exception 'Nivel no encontrado' using errcode = 'P0002';
  end if;

  update public.levels
    set monthly_limit_usd  = p_monthly_limit_usd,
        required_spend_usd = p_required_spend_usd,
        required_months    = p_required_months,
        is_active          = p_is_active,
        label              = coalesce(nullif(trim(p_label), ''), label),
        updated_at         = now()
  where level = p_level;

  perform audit.log(v_actor, 'level.configure', null, jsonb_build_object(
    'level', p_level,
    'before', v_before,
    'after', (select to_jsonb(l) from public.levels l where l.level = p_level),
    'note', nullif(trim(p_note), '')
  ));
end;
$function$;

revoke all on function public.admin_set_level_config(smallint, numeric, numeric, smallint, boolean, text, text) from public, anon;
grant execute on function public.admin_set_level_config(smallint, numeric, numeric, smallint, boolean, text, text) to authenticated, service_role;
drop function if exists public.admin_set_level_config(smallint, numeric, numeric, smallint, boolean, text);

