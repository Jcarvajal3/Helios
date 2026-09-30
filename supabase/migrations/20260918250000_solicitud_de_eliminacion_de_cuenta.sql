-- ============================================================================
-- Ronda — Solicitud de eliminación de cuenta
--
-- Apple 5.1.1(v) exige que una app que permite crear una cuenta permita
-- también iniciar su eliminación **desde dentro de la app**, sin mandar a
-- nadie a escribir un correo ni a llamar por teléfono. Google pide lo mismo en
-- su Data deletion policy.
--
-- ---------------------------------------------------------------------------
-- Se solicita aquí; se ejecuta a mano
-- ---------------------------------------------------------------------------
-- Esta migración NO borra nada y no hay ningún automatismo colgado de ella.
-- Solo registra la solicitud: el equipo la lee, la revisa y ejecuta la
-- eliminación por su cuenta. Es deliberado — un borrado automático de una
-- cuenta con historial de crédito es irreversible y no admite un "se disparó
-- solo".
--
-- ---------------------------------------------------------------------------
-- Por qué hay requisitos y por qué se comprueban en el servidor
-- ---------------------------------------------------------------------------
-- La cuenta sostiene una deuda. Mientras quede dinero en el aire no se puede
-- cerrar el expediente que lo prueba, así que la solicitud solo se admite con
-- las tres condiciones a cero:
--
--   1. Ninguna cuota pendiente de pago.
--   2. Ningún pago reportado esperando verificación — puede acabar rechazado,
--      y entonces la deuda vuelve.
--   3. Ningún grupo abierto — esta noche todavía le pueden cargar una cuenta.
--
-- La app las pinta para que nadie llegue a ciegas al final del formulario,
-- pero quien manda es `request_account_deletion`: las vuelve a comprobar
-- antes de insertar. Una comprobación que solo vive en el cliente es una
-- comprobación que no existe.
-- ============================================================================

create type public.account_deletion_status as enum (
  'pending',    -- esperando a que el equipo la revise
  'completed',  -- la cuenta se eliminó
  'rejected',   -- el equipo no procede, y `review_note` dice por qué
  'cancelled'   -- la retiró la propia persona
);

create table if not exists public.account_deletion_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  /** Lo que escribe la persona. Obligatorio: es lo que se revisa. */
  reason       text not null,
  status       public.account_deletion_status not null default 'pending',
  requested_at timestamptz not null default now(),
  /**
   * El estado de la cuenta en el momento de pedirlo, tal como lo devolvió
   * `my_deletion_eligibility`. Se guarda para que el día que alguien pregunte
   * "¿no debía nada cuando lo pidió?" haya una respuesta que no dependa de
   * reconstruir la deuda de hace tres semanas.
   */
  eligibility  jsonb not null default '{}'::jsonb,
  reviewed_by  uuid references auth.users (id),
  reviewed_at  timestamptz,
  review_note  text
);

comment on table public.account_deletion_requests is
  'Solicitudes de eliminacion de cuenta enviadas desde la app. No borran nada: las revisa y las ejecuta el equipo a mano.';

-- Una sola solicitud viva por persona. Pedirlo dos veces no crea dos casos:
-- el segundo intento devuelve el primero.
create unique index if not exists account_deletion_requests_una_abierta
  on public.account_deletion_requests (user_id)
  where status = 'pending';

-- La cola del equipo, por orden de llegada.
create index if not exists account_deletion_requests_cola
  on public.account_deletion_requests (requested_at)
  where status = 'pending';

alter table public.account_deletion_requests enable row level security;

revoke all on table public.account_deletion_requests from public, anon, authenticated;
grant select on table public.account_deletion_requests to authenticated;

-- Cada quien ve la suya; el equipo las ve todas.
create policy account_deletion_requests_select
  on public.account_deletion_requests
  for select to authenticated
  using (user_id = auth.uid() or public.is_platform_admin());

-- No hay policy de insert ni de update a propósito: la solicitud entra por
-- `request_account_deletion`, que comprueba los requisitos, y se resuelve por
-- `admin_resolve_deletion_request`, que exige super admin y deja rastro en la
-- bitácora. Un grant de update sobre la tabla sería una tercera puerta que
-- nadie vigila.

-- ---------------------------------------------------------------------------
-- ¿Puede esta cuenta solicitarlo?
-- ---------------------------------------------------------------------------
-- Devuelve las tres condiciones con su cifra, no un sí o un no: la pantalla
-- tiene que poder decir "te quedan 3 cuotas por 45,60 €" y no solo "no
-- puedes". Un requisito sin el número al lado no se puede cumplir.

create or replace function public.my_deletion_eligibility()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user       uuid := auth.uid();
  v_due_count  integer;
  v_due_amount numeric(18,4);
  v_in_review  integer;
  v_groups     integer;
  v_request    public.account_deletion_requests%rowtype;
begin
  if v_user is null then
    raise exception 'No hay sesion iniciada' using errcode = '28000';
  end if;

  select count(*), coalesce(sum(amount_usd), 0)
    into v_due_count, v_due_amount
  from public.installments
  where user_id = v_user
    and status = 'pending';

  select count(*)
    into v_in_review
  from public.payment_reports
  where user_id = v_user
    and status in ('reported', 'in_review');

  select count(*)
    into v_groups
  from public.group_members gm
  join public.groups g on g.id = gm.group_id
  where gm.user_id = v_user
    and gm.left_at is null
    and g.status = 'active';

  select * into v_request
  from public.account_deletion_requests
  where user_id = v_user
    and status = 'pending';

  return jsonb_build_object(
    'can_request',
      v_due_count = 0 and v_in_review = 0 and v_groups = 0 and v_request.id is null,
    'due_count',          v_due_count,
    'due_amount_usd',     v_due_amount,
    'payments_in_review', v_in_review,
    'open_groups',        v_groups,
    'pending_request',
      case when v_request.id is null then null else jsonb_build_object(
        'id',           v_request.id,
        'requested_at', v_request.requested_at
      ) end
  );
end;
$$;

comment on function public.my_deletion_eligibility() is
  'Las tres condiciones para solicitar la eliminacion de la cuenta, cada una con su cifra, y la solicitud abierta si ya la hay.';

revoke all on function public.my_deletion_eligibility() from public, anon;
grant execute on function public.my_deletion_eligibility() to authenticated;

-- ---------------------------------------------------------------------------
-- Enviar la solicitud
-- ---------------------------------------------------------------------------

create or replace function public.request_account_deletion(p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user   uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_elig   jsonb;
  v_row    public.account_deletion_requests%rowtype;
begin
  if v_user is null then
    raise exception 'No hay sesion iniciada' using errcode = '28000';
  end if;

  v_elig := public.my_deletion_eligibility();

  -- Ya hay una abierta: se devuelve esa. Un segundo toque del botón —o un
  -- reintento de red— no puede abrir un caso duplicado en la cola del equipo.
  select * into v_row
  from public.account_deletion_requests
  where user_id = v_user
    and status = 'pending';

  if found then
    return jsonb_build_object(
      'id',           v_row.id,
      'requested_at', v_row.requested_at,
      'already_open', true
    );
  end if;

  if length(v_reason) < 10 then
    raise exception 'Indicanos el motivo de tu solicitud, aunque sea brevemente.'
      using errcode = '22023';
  end if;

  if not (v_elig->>'can_request')::boolean then
    raise exception 'Tu cuenta todavia no cumple los requisitos para solicitar la eliminacion.'
      using errcode = 'P0001';
  end if;

  insert into public.account_deletion_requests (user_id, reason, eligibility)
  values (v_user, left(v_reason, 2000), v_elig)
  returning * into v_row;

  return jsonb_build_object(
    'id',           v_row.id,
    'requested_at', v_row.requested_at,
    'already_open', false
  );
end;
$$;

comment on function public.request_account_deletion(text) is
  'Registra la solicitud de eliminacion si la cuenta cumple los requisitos. No borra nada: la ejecuta el equipo.';

revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Retirarla
-- ---------------------------------------------------------------------------
-- Mientras el equipo no la haya resuelto, la solicitud es de quien la mandó.
-- Sin esta función, un toque por error se convierte en un correo a soporte.

create or replace function public.cancel_account_deletion()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_row  public.account_deletion_requests%rowtype;
begin
  if v_user is null then
    raise exception 'No hay sesion iniciada' using errcode = '28000';
  end if;

  update public.account_deletion_requests
  set status = 'cancelled'
  where user_id = v_user
    and status = 'pending'
  returning * into v_row;

  return jsonb_build_object('cancelled', v_row.id is not null);
end;
$$;

comment on function public.cancel_account_deletion() is
  'Retira la solicitud de eliminacion que la propia persona tenga abierta.';

revoke all on function public.cancel_account_deletion() from public, anon;
grant execute on function public.cancel_account_deletion() to authenticated;

-- ---------------------------------------------------------------------------
-- La cola del equipo
-- ---------------------------------------------------------------------------
-- Ajustes → Eliminación de cuentas. Devuelve la solicitud con los datos de la
-- persona al lado —nombre, teléfono y cédula— porque lo primero que hay que
-- hacer con una es identificar la cuenta, y sin eso habría que ir a buscarla
-- a otra pantalla con un uuid en la mano.

create or replace function public.admin_deletion_requests(
  p_status public.account_deletion_status default 'pending'
)
returns table (
  id              uuid,
  user_id         uuid,
  full_name       text,
  phone_e164      text,
  document_number text,
  profile_status  public.profile_status,
  reason          text,
  status          public.account_deletion_status,
  requested_at    timestamptz,
  eligibility     jsonb,
  reviewed_at     timestamptz,
  reviewer_name   text,
  review_note     text
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select
    r.id,
    r.user_id,
    p.full_name,
    p.phone_e164,
    p.document_number,
    p.status,
    r.reason,
    r.status,
    r.requested_at,
    r.eligibility,
    r.reviewed_at,
    rev.full_name,
    r.review_note
  from public.account_deletion_requests r
  left join public.profiles p   on p.id = r.user_id
  left join public.profiles rev on rev.id = r.reviewed_by
  -- Sin estado, todas: es como se consulta un caso ya resuelto.
  where p_status is null or r.status = p_status
  -- Las pendientes, la más antigua primero —es el orden en que se atienden—;
  -- las resueltas, la última primero, que es la que se viene a comprobar.
  order by
    case when r.status = 'pending' then r.requested_at end asc,
    case when r.status <> 'pending' then r.requested_at end desc;
end;
$fn$;

comment on function public.admin_deletion_requests(public.account_deletion_status) is
  'Las solicitudes de eliminacion de cuenta con los datos de la persona al lado. Sin estado, todas.';

revoke all on function public.admin_deletion_requests(public.account_deletion_status) from public, anon;
grant execute on function public.admin_deletion_requests(public.account_deletion_status) to authenticated;

-- ---------------------------------------------------------------------------
-- Cerrar un caso
-- ---------------------------------------------------------------------------
-- No borra la cuenta: marca lo que el equipo YA hizo por su cuenta. La nota es
-- obligatoria al rechazar, porque un caso rechazado sin motivo escrito es un
-- caso que nadie puede revisar dos meses después.
--
-- Pide super admin, como condonar un cargo: lo que se está anotando es la
-- destrucción de los datos de una persona.

create or replace function public.admin_resolve_deletion_request(
  p_id     uuid,
  p_status public.account_deletion_status,
  p_note   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
  v_row   public.account_deletion_requests%rowtype;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede resolver una solicitud de eliminacion'
      using errcode = '42501';
  end if;

  if p_status not in ('completed', 'rejected') then
    raise exception 'Una solicitud se cierra como completada o rechazada'
      using errcode = '22023';
  end if;

  if p_status = 'rejected' and v_note is null then
    raise exception 'Escribe el motivo del rechazo' using errcode = '22023';
  end if;

  update public.account_deletion_requests
  set status      = p_status,
      reviewed_by = v_actor,
      reviewed_at = now(),
      review_note = v_note
  where id = p_id
    and status = 'pending'
  returning * into v_row;

  if not found then
    raise exception 'Esa solicitud ya no esta pendiente' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'account_deletion.' || p_status, p_id, jsonb_build_object(
    'user_id', v_row.user_id,
    'note',    v_note
  ));

  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end;
$fn$;

comment on function public.admin_resolve_deletion_request(uuid, public.account_deletion_status, text) is
  'Marca una solicitud como completada o rechazada. No borra la cuenta: anota lo que el equipo ya hizo.';

revoke all on function public.admin_resolve_deletion_request(uuid, public.account_deletion_status, text) from public, anon;
grant execute on function public.admin_resolve_deletion_request(uuid, public.account_deletion_status, text) to authenticated;
