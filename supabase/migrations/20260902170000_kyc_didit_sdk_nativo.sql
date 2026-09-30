-- ============================================================================
-- Ronda — La verificación pasa a hacerse dentro de la app
--
-- Hasta ahora la persona salía al navegador del sistema para verificarse con
-- Didit y volvía por un deep link. Con el SDK nativo
-- (@didit-protocol/sdk-react-native) el flujo ocurre dentro de Ronda, sin salir
-- a ninguna parte: cámara, lectura del documento, selfie y prueba de vida son
-- pantallas nativas.
--
-- Lo que cambia aquí abajo es qué se guarda de la sesión. El SDK no abre una
-- URL: consume el `session_token` que devuelve `POST /v3/session/` junto al
-- `session_id` y al enlace. Ese token es de vida corta y Didit no publica una
-- forma de renovarlo, así que se guarda para poder RETOMAR una verificación
-- abandonada y, cuando ya no sirva, la app abrirá una sesión nueva.
--
-- El enlace se sigue guardando: es la salida de emergencia si el SDK no puede
-- arrancar en ese teléfono. Sin él, un fallo nativo dejaría a la persona
-- exactamente donde estaba antes de 20260828154500 — mirando un spinner con
-- "cerrar sesión" como única puerta.
--
-- ⚠️ `kyc_my_pending_session` cambia de tipo de retorno (text → jsonb). Una
-- build vieja de la app que la llame va a recibir un objeto donde esperaba una
-- URL. Se acepta porque todavía no hay ninguna publicada; el día que la haya,
-- esto tendría que ser una función nueva al lado de la vieja.
-- ============================================================================

alter table kyc.verifications
  add column if not exists didit_session_token text;

comment on column kyc.verifications.didit_session_token is
  'Token de sesión de Didit, el que consume el SDK nativo. De vida corta: si '
  'caducó, la app abre una sesión nueva en vez de retomar esta.';


-- ---------------------------------------------------------------------------
-- Guardar la sesión, ahora con token
-- ---------------------------------------------------------------------------
--
-- Se retiran las versiones anteriores en vez de dejar que convivan con la
-- nueva: `create or replace` reemplaza por firma y no por nombre, y ya hubo que
-- tapiar una puerta así en 20260829000000.
--
-- La de dos argumentos (20260828120100) quedó huérfana cuando aquella migración
-- se llevó por delante a su único llamador, y con la nueva firma pasaría de
-- inútil a peligrosa: como los dos últimos argumentos tienen valor por defecto,
-- una llamada de dos argumentos ya no sabría a cuál de las dos ir.

drop function if exists kyc.attach_didit_session(uuid, text);
drop function if exists kyc.attach_didit_session(uuid, text, text);

create function kyc.attach_didit_session(
  p_verification_id uuid,
  p_session_id      text,
  p_session_url     text default null,
  p_session_token   text default null
)
returns void
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_row kyc.verifications%rowtype;
begin
  select * into v_row from kyc.verifications
  where id = p_verification_id for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  if v_row.status not in ('pending', 'processing') then
    raise exception 'La verificación ya está resuelta' using errcode = '22023';
  end if;

  -- El token va con `coalesce` igual que el enlace: quien vuelva a enlazar la
  -- misma sesión sin él —una llamada vieja— no debe borrar el que ya había.
  update kyc.verifications
     set didit_session_id    = p_session_id,
         didit_session_url   = coalesce(p_session_url, didit_session_url),
         didit_session_token = coalesce(p_session_token, didit_session_token),
         status              = 'processing',
         updated_at          = now()
   where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, 'processing', 'system',
          jsonb_build_object('provider', 'didit', 'session_id', p_session_id));
end;
$$;

revoke all on function kyc.attach_didit_session(uuid, text, text, text)
  from public, anon, authenticated;


drop function if exists public.kyc_attach_didit_session(uuid, uuid, text, text);

create function public.kyc_attach_didit_session(
  p_verification_id uuid,
  p_user_id         uuid,
  p_session_id      text,
  p_session_url     text default null,
  p_session_token   text default null
)
returns void
language plpgsql
security definer
set search_path = public, kyc, pg_temp
as $$
begin
  if not exists (
    select 1 from kyc.verifications
    where id = p_verification_id and user_id = p_user_id
  ) then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  perform kyc.attach_didit_session(
    p_verification_id, p_session_id, p_session_url, p_session_token
  );
end;
$$;

revoke all on function public.kyc_attach_didit_session(uuid, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.kyc_attach_didit_session(uuid, uuid, text, text, text)
  to service_role;


-- ---------------------------------------------------------------------------
-- La sesión pendiente, para su dueño
-- ---------------------------------------------------------------------------
--
-- Devuelve token y enlace de SU verificación en curso, nada más: sin
-- identificadores internos y sin estado. `auth.uid()` es lo que acota la fila,
-- así que no hay parámetro con el que pedir la de otro.
--
-- `null` cuando no hay ninguna en curso, para que la app distinga "no hay nada
-- que retomar" de "hay una sesión sin token".

drop function if exists public.kyc_my_pending_session();

create function public.kyc_my_pending_session()
returns jsonb
language sql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
  select jsonb_build_object(
    'session_token', v.didit_session_token,
    'session_url',   v.didit_session_url
  )
  from kyc.verifications v
  where v.user_id = auth.uid()
    and v.status = 'processing'
    and (v.didit_session_token is not null or v.didit_session_url is not null)
  order by v.created_at desc
  limit 1;
$$;

revoke all on function public.kyc_my_pending_session() from public, anon;
grant execute on function public.kyc_my_pending_session() to authenticated;
