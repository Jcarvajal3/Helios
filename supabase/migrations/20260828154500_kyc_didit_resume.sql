-- ============================================================================
-- Ronda — Poder volver a la verificación que quedó a medias
--
-- Si alguien sale del flujo de Didit sin terminar, su verificación se queda en
-- 'processing' y nadie la resuelve: el trabajo está a medias del lado del
-- proveedor, así que no hay webhook que llegue. La app se quedaba en
-- "Verificando tu identidad" con un spinner, sin botón de volver, y la única
-- salida era CERRAR SESIÓN.
--
-- Con el sistema anterior no pasaba: las fotos ya estaban subidas y el
-- servicio acababa decidiendo con lo que hubiera. Ahora la mitad del proceso
-- vive fuera, y hay que poder regresar a ella.
--
-- Se guarda el enlace de la sesión para reabrir LA MISMA en vez de crear otra:
-- retoma donde lo dejó, y no gasta una verificación más del tramo gratuito.
-- ============================================================================

alter table kyc.verifications
  add column if not exists didit_session_url text;

comment on column kyc.verifications.didit_session_url is
  'Enlace de la sesión de Didit. Permite retomar una verificación abandonada '
  'sin empezar otra.';


create or replace function kyc.attach_didit_session(
  p_verification_id uuid,
  p_session_id      text,
  p_session_url     text default null
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

  update kyc.verifications
     set didit_session_id  = p_session_id,
         didit_session_url = coalesce(p_session_url, didit_session_url),
         status            = 'processing',
         updated_at        = now()
   where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, 'processing', 'system',
          jsonb_build_object('provider', 'didit', 'session_id', p_session_id));
end;
$$;

revoke all on function kyc.attach_didit_session(uuid, text, text)
  from public, anon, authenticated;


create or replace function public.kyc_attach_didit_session(
  p_verification_id uuid,
  p_user_id         uuid,
  p_session_id      text,
  p_session_url     text default null
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

  perform kyc.attach_didit_session(p_verification_id, p_session_id, p_session_url);
end;
$$;

revoke all on function public.kyc_attach_didit_session(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.kyc_attach_didit_session(uuid, uuid, text, text)
  to service_role;


-- ---------------------------------------------------------------------------
-- El enlace pendiente, para su dueño
-- ---------------------------------------------------------------------------
--
-- Esta sí la llama la app con la sesión de la persona, no el servidor. Devuelve
-- únicamente el enlace de SU verificación en curso: sin identificadores, sin
-- estado, sin nada más. `auth.uid()` es lo que acota la fila, así que no hay
-- parámetro con el que pedir la de otro.

create or replace function public.kyc_my_pending_session()
returns text
language sql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
  select v.didit_session_url
  from kyc.verifications v
  where v.user_id = auth.uid()
    and v.status = 'processing'
    and v.didit_session_url is not null
  order by v.created_at desc
  limit 1;
$$;

revoke all on function public.kyc_my_pending_session() from public, anon;
grant execute on function public.kyc_my_pending_session() to authenticated;
