-- ============================================================================
-- Ronda — Puerta de servicio para las funciones de borde
--
-- Las funciones de borde hablaban con el esquema `kyc` usando `.schema('kyc')`,
-- y eso no puede funcionar: PostgREST solo atiende los esquemas declarados en
-- `[api] schemas`, que son `public` y `graphql_public`. El esquema `kyc` queda
-- fuera A PROPÓSITO — es lo que impide que un cliente con la clave anónima se
-- asome a las verificaciones de nadie.
--
-- Así que no se expone `kyc`: se abren envoltorios en `public`, con
-- `security definer`, revocados de todo el mundo y concedidos solo al rol de
-- servicio. Es el mismo patrón con el que la app llega a `kyc` desde el primer
-- día; lo único nuevo es que ahora quien llama es el servidor.
--
-- Cada envoltorio comprueba la propiedad del expediente por su cuenta. No se
-- fía de que la función de borde ya lo hiciera: si mañana alguien llama a esta
-- RPC desde otro sitio, la comprobación sigue estando donde tiene que estar.
-- ============================================================================

-- ¿Se puede empezar una verificación con este expediente?
--
-- Se consulta ANTES de crear la sesión en Didit para no gastar una sesión —y
-- una verificación del tramo gratuito— en un expediente ajeno o ya resuelto.
create or replace function public.kyc_verification_is_open(
  p_verification_id uuid,
  p_user_id         uuid
)
returns boolean
language sql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
  select exists (
    select 1 from kyc.verifications
    where id = p_verification_id
      and user_id = p_user_id
      and status in ('pending', 'processing')
  );
$$;

revoke all on function public.kyc_verification_is_open(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.kyc_verification_is_open(uuid, uuid)
  to service_role;


-- Enlaza la sesión de Didit con el expediente.
create or replace function public.kyc_attach_didit_session(
  p_verification_id uuid,
  p_user_id         uuid,
  p_session_id      text
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

  perform kyc.attach_didit_session(p_verification_id, p_session_id);
end;
$$;

revoke all on function public.kyc_attach_didit_session(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.kyc_attach_didit_session(uuid, uuid, text)
  to service_role;


-- Registra el veredicto que llega por webhook.
--
-- Aquí no hay usuario que comprobar: quien llama es Didit, y lo que autentica
-- la llamada es la firma HMAC que la función de borde ya verificó antes de
-- llegar a este punto. La sesión es la llave del expediente.
create or replace function public.kyc_record_didit_decision(
  p_session_id text,
  p_status     text,
  p_document   text default null,
  p_first_name text default null,
  p_last_name  text default null,
  p_full_name  text default null,
  p_birth_date date default null,
  p_detail     text default null,
  p_signals    jsonb default '{}'::jsonb
)
returns jsonb
language sql
security definer
set search_path = public, kyc, pg_temp
as $$
  select kyc.record_didit_decision(
    p_session_id, p_status, p_document, p_first_name, p_last_name,
    p_full_name, p_birth_date, p_detail, p_signals
  );
$$;

revoke all on function public.kyc_record_didit_decision(
  text, text, text, text, text, text, date, text, jsonb
) from public, anon, authenticated;
grant execute on function public.kyc_record_didit_decision(
  text, text, text, text, text, text, date, text, jsonb
) to service_role;
