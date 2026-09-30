-- ============================================================================
-- Ronda — Super admin: identidad, permisos y bitácora
--
-- Hasta ahora las funciones sensibles (`reconcile_payment`, `void_charge`,
-- `kyc.review`, alta de comercios) no tenían grant: solo las podía llamar el
-- service role. Eso obligaba a operar por SQL a mano, porque el panel web
-- autentica con la clave publicable y el JWT del usuario — nunca con el
-- service role, que jamás debe salir del servidor.
--
-- Aquí se crea la identidad que faltaba: `platform_admins`. Las funciones de
-- super admin comprueban la pertenencia por su cuenta, así que el panel puede
-- llamarlas con la sesión del usuario y sin secretos en el cliente.
--
-- docs/01-ARQUITECTURA.md §10: "Toda acción de admin escribe en
-- audit.admin_actions (actor, acción, antes/después)". Ese esquema estaba
-- previsto y sin construir; se construye aquí.
-- ============================================================================

create schema if not exists audit;
revoke all on schema audit from public, anon, authenticated;

create type public.platform_role as enum (
  'operador',   -- concilia pagos y revisa KYC; no toca dinero ni parámetros
  'super_admin' -- todo lo anterior más comercios, niveles y ajustes manuales
);

create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  role       public.platform_role not null default 'operador',
  full_name  text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table public.platform_admins is
  'Personal de Helios. Se da de alta a mano en la base: no hay autorregistro.';

alter table public.platform_admins enable row level security;

-- Un admin ve su propia fila, para que el panel sepa qué pintar.
create policy "platform_admins_read_own"
  on public.platform_admins for select to authenticated
  using (user_id = (select auth.uid()));

grant select on public.platform_admins to authenticated;

/** ¿El usuario actual es personal de Ronda activo? */
create or replace function public.is_platform_admin()
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1 from public.platform_admins
    where user_id = auth.uid() and is_active
  );
$$;

revoke all on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- Bitácora
-- ---------------------------------------------------------------------------
-- Append-only, igual que el ledger: una acción de admin que se pueda borrar
-- no sirve como bitácora.

create table if not exists audit.admin_actions (
  id         bigint generated always as identity primary key,
  actor      uuid not null references auth.users (id),
  action     text not null,
  target_id  uuid,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index admin_actions_actor_idx on audit.admin_actions (actor, created_at desc);
create index admin_actions_target_idx on audit.admin_actions (target_id);

create or replace function audit.block_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  raise exception 'audit.% es append-only: % no está permitido', tg_table_name, tg_op;
end;
$$;

create trigger admin_actions_no_update before update on audit.admin_actions
  for each row execute function audit.block_mutation();
create trigger admin_actions_no_delete before delete on audit.admin_actions
  for each row execute function audit.block_mutation();

create or replace function audit.log(
  p_actor uuid, p_action text, p_target uuid, p_detail jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = audit, pg_temp
as $$
  insert into audit.admin_actions (actor, action, target_id, detail)
  values (p_actor, p_action, p_target, p_detail);
$$;

revoke all on function audit.log(uuid, text, uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lecturas del super admin
-- ---------------------------------------------------------------------------
-- Se añaden políticas ADICIONALES sobre las tablas que ya tenían RLS. Las
-- políticas de un mismo comando se combinan con OR, así que el usuario sigue
-- viendo lo suyo y el admin ve todo, sin tocar las reglas existentes.

create policy "payment_reports_read_admin"
  on public.payment_reports for select to authenticated
  using (public.is_platform_admin());

create policy "payment_quotes_read_admin"
  on public.payment_quotes for select to authenticated
  using (public.is_platform_admin());

create policy "quote_items_read_admin"
  on public.payment_quote_items for select to authenticated
  using (public.is_platform_admin());

create policy "installments_read_admin"
  on public.installments for select to authenticated
  using (public.is_platform_admin());

create policy "charges_read_admin"
  on public.charges for select to authenticated
  using (public.is_platform_admin());

create policy "profiles_read_admin"
  on public.profiles for select to authenticated
  using (public.is_platform_admin());

create policy "credit_blocks_read_admin"
  on public.user_credit_blocks for select to authenticated
  using (public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Cola de conciliación
-- ---------------------------------------------------------------------------
-- Una vista con todo lo que el operador necesita para decidir sin abrir cinco
-- pantallas: quién pagó, cuánto en bolívares, con qué referencia, y qué
-- cuotas cubre.

create or replace view public.payment_queue
with (security_invoker = true)
as
select
  r.id                as report_id,
  r.status,
  r.created_at,
  r.bank,
  r.reference,
  r.payer_document,
  r.payer_phone,
  r.rejection_note,
  q.amount_usd,
  q.amount_ves,
  q.fx_rate,
  q.installment_count,
  p.id                as user_id,
  p.full_name,
  p.phone_e164,
  p.status            as user_status,
  -- Señal de fraude: la misma referencia usada en otro reporte no rechazado.
  -- Con 6 dígitos es sospecha, no prueba (ver docs/00-BASES §3.7).
  (
    select count(*) - 1 from public.payment_reports r2
    where r2.bank = r.bank and r2.reference = r.reference
      and r2.reference is not null and r2.status <> 'rejected'
  )                   as reference_collisions
from public.payment_reports r
join public.payment_quotes q on q.id = r.quote_id
join public.profiles p on p.id = r.user_id;

comment on view public.payment_queue is
  'Cola de conciliación del super admin. security_invoker: hereda las RLS de las tablas base.';

grant select on public.payment_queue to authenticated;

-- ---------------------------------------------------------------------------
-- Acciones del super admin
-- ---------------------------------------------------------------------------

/** Concilia o rechaza un pago. Envoltorio de reconcile_payment que comprueba
 *  que quien llama es personal de Ronda y deja rastro en la bitácora. */
create or replace function public.admin_reconcile_payment(
  p_report_id uuid,
  p_approve   boolean,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if not p_approve and (p_note is null or length(trim(p_note)) = 0) then
    raise exception 'Rechazar un pago requiere motivo' using errcode = '22023';
  end if;

  v_result := public.reconcile_payment(p_report_id, v_actor, p_approve, p_note);

  perform audit.log(
    v_actor,
    case when p_approve then 'payment.reconciled' else 'payment.rejected' end,
    p_report_id,
    jsonb_build_object('note', p_note, 'result', v_result)
  );

  return v_result;
end;
$$;

revoke all on function public.admin_reconcile_payment(uuid, boolean, text) from public, anon;
grant execute on function public.admin_reconcile_payment(uuid, boolean, text) to authenticated;

/** Marca un reporte como "en revisión" para sacarlo de la cola de entrada
 *  mientras alguien lo investiga. Evita que dos operadores trabajen el mismo. */
create or replace function public.admin_flag_for_review(p_report_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  update public.payment_reports
    set status = 'in_review', rejection_note = p_note, reviewed_by = v_actor
  where id = p_report_id and status = 'reported';

  if not found then
    raise exception 'Solo se puede marcar un reporte recién llegado' using errcode = '22023';
  end if;

  perform audit.log(v_actor, 'payment.flagged', p_report_id, jsonb_build_object('note', p_note));

  return jsonb_build_object('ok', true, 'status', 'in_review');
end;
$$;

revoke all on function public.admin_flag_for_review(uuid, text) from public, anon;
grant execute on function public.admin_flag_for_review(uuid, text) to authenticated;
