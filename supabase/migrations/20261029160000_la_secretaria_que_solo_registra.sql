-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La secretaria que solo registra
--
-- Javier, 2026-10-29: al crear una secretaria, el médico decide si puede
-- consultar el historial de pagos en cuotas. Con `solo_registra` (la casilla
-- del alta, marcada por defecto) registra pacientes y ve sus comisiones, y
-- nada más: sin la pestaña «Pagos en cuotas», sin la ficha de cada orden y
-- sin los montos de las consultas que ya registró. Se puede cambiar después
-- desde «Editar».
--
-- El corte es de la base, no del panel: las RPC del historial
-- (`merchant_transactions`, `merchant_transactions_summary`,
-- `merchant_sales_by_staff`, `merchant_charge_detail` y
-- `merchant_charge_items`) le responden con un error que dice por qué, en
-- vez de una lista vacía que parecería legítima. «Mis pagos en cuotas» del
-- bot pasa por `merchant_transactions`, así que el bot le dice lo mismo.
--
-- Lo que sí sigue igual: registrar (con la pantalla de espera,
-- `helios_charge_for_staff`, de la orden que acaba de registrar), reenviarle
-- algo al paciente y sus comisiones (`merchant_commissions`,
-- `merchant_commission_items`: el monto de la comisión, no el de la consulta).
--
-- La columna nace en false: las secretarias que ya existen conservan lo que
-- tenían. Solo tiene sentido para el rol `cajero`.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.merchant_users
  add column if not exists solo_registra boolean not null default false;

alter table public.merchant_users
  add constraint merchant_users_solo_registra_es_de_secretaria
  check (not solo_registra or role = 'cajero');

comment on column public.merchant_users.solo_registra is
  'Secretaria que solo registra pacientes y ve sus comisiones: sin historial de pagos en cuotas ni sus montos (2026-10-29).';

-- ── Quién mira ─────────────────────────────────────────────────────────────

-- Si quien llama es una secretaria que solo registra. Un administrador de
-- cualquier clínica no lo es nunca.
create or replace function public.helios_solo_registra()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
           select 1 from public.merchant_users mu
           where mu.user_id = auth.uid() and mu.is_active
             and mu.role = 'cajero' and mu.solo_registra
         )
     and not exists (
           select 1 from public.merchant_users mu
           where mu.user_id = auth.uid() and mu.is_active and mu.role = 'gerente'
         );
$$;

revoke all on function public.helios_solo_registra() from public, anon;
grant execute on function public.helios_solo_registra() to authenticated;

create or replace function public.helios_assert_ve_el_historial()
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if public.helios_solo_registra() then
    raise exception 'Tu cuenta es para registrar pacientes y ver tus comisiones. El historial de pagos en cuotas lo consulta el administrador de la clínica.'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.helios_assert_ve_el_historial() from public, anon, authenticated;

-- ── El personal: alta, edición y lista ─────────────────────────────────────

drop function if exists public.merchant_staff_add(uuid, text, text, text, public.merchant_role, uuid);

create or replace function public.merchant_staff_add(
  p_merchant_id   uuid,
  p_email         text,
  p_password      text,
  p_full_name     text,
  p_role          public.merchant_role,
  p_branch_id     uuid default null,
  -- NUEVO: solo cuenta para una secretaria. Sin el parámetro, como antes.
  p_solo_registra boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_user   uuid;
  v_branch uuid;
  v_solo   boolean := p_role = 'cajero' and coalesce(p_solo_registra, false);
begin
  perform public.helios_assert_staff_manager(p_merchant_id);

  -- Helios (H8): el rol «inventario» era del catálogo de productos, que no
  -- existe. Queda en el enum por las filas viejas, pero no se asigna.
  if p_role = 'inventario' then
    raise exception 'El rol inventario no existe en Helios: elige administrador o secretaria'
      using errcode = '22023';
  end if;

  v_user   := public.admin_create_auth_account(p_email, p_password, p_full_name);
  v_branch := public.helios_branch_for_role(p_merchant_id, p_role, p_branch_id);

  insert into public.merchant_users (user_id, merchant_id, branch_id, role, solo_registra)
  values (v_user, p_merchant_id, v_branch, p_role, v_solo)
  on conflict (user_id, merchant_id, branch_id) do update
    set role = excluded.role, is_active = true, solo_registra = excluded.solo_registra;

  perform audit.log(v_actor, 'merchant.staff_added', p_merchant_id,
    jsonb_build_object(
      'user_id',       v_user,
      'email',         lower(trim(p_email)),
      'role',          p_role,
      'solo_registra', v_solo
    ));

  return jsonb_build_object('ok', true, 'user_id', v_user, 'branch_id', v_branch);
end;
$$;

revoke all on function public.merchant_staff_add(uuid, text, text, text, public.merchant_role, uuid, boolean)
  from public, anon;
grant execute on function public.merchant_staff_add(uuid, text, text, text, public.merchant_role, uuid, boolean)
  to authenticated;

drop function if exists public.merchant_staff_update(uuid, uuid, text, public.merchant_role, uuid);

create or replace function public.merchant_staff_update(
  p_merchant_id   uuid,
  p_user_id       uuid,
  p_full_name     text,
  p_role          public.merchant_role,
  p_branch_id     uuid default null,
  -- NUEVO: null deja lo que tenía. Para un administrador siempre es false.
  p_solo_registra boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor      uuid := auth.uid();
  v_antes      public.merchant_role;
  v_solo_antes boolean;
  v_solo       boolean;
  v_nombre     text := nullif(trim(coalesce(p_full_name, '')), '');
  v_branch     uuid;
begin
  perform public.helios_assert_staff_manager(p_merchant_id, p_user_id);

  select role, solo_registra into v_antes, v_solo_antes
  from public.merchant_users
  where merchant_id = p_merchant_id and user_id = p_user_id and is_active
  order by created_at
  limit 1;

  if v_antes is null then
    raise exception 'Esa persona no es personal de este comercio' using errcode = 'P0002';
  end if;

  -- Helios (H8): el rol «inventario» era del catálogo de productos, que no
  -- existe. Queda en el enum por las filas viejas, pero no se asigna.
  if p_role = 'inventario' and v_antes is distinct from 'inventario' then
    raise exception 'El rol inventario no existe en Helios: elige administrador o secretaria'
      using errcode = '22023';
  end if;

  -- Candado 2: cambiarse el propio rol deja al local sin quien gestione su
  -- personal. El nombre sí se puede cambiar.
  if p_user_id = v_actor and p_role is distinct from v_antes then
    raise exception 'No puedes cambiarte el rol a ti mismo. Que lo haga otro gerente o el equipo de Helios.'
      using errcode = '42501';
  end if;

  v_solo := p_role = 'cajero' and coalesce(p_solo_registra, v_solo_antes, false);

  if v_nombre is not null then
    update auth.users
      set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
                               || jsonb_build_object('full_name', v_nombre),
          updated_at = now()
    where id = p_user_id;

    -- Solo si ya existe: una cuenta de panel no tiene fila en `profiles` y
    -- crearla aqui la metería en el padrón de consumidores, que es otra cosa.
    update public.profiles set full_name = v_nombre where id = p_user_id;
  end if;

  if p_role is distinct from v_antes or p_branch_id is not null then
    v_branch := public.helios_branch_for_role(p_merchant_id, p_role, p_branch_id);

    update public.merchant_users
      set is_active = false
    where merchant_id = p_merchant_id and user_id = p_user_id;

    insert into public.merchant_users (user_id, merchant_id, branch_id, role, solo_registra)
    values (p_user_id, p_merchant_id, v_branch, p_role, v_solo)
    on conflict (user_id, merchant_id, branch_id) do update
      set role = excluded.role, is_active = true, solo_registra = excluded.solo_registra;
  elsif v_solo is distinct from v_solo_antes then
    update public.merchant_users
      set solo_registra = v_solo
    where merchant_id = p_merchant_id and user_id = p_user_id and is_active;
  end if;

  perform audit.log(v_actor, 'merchant.staff_updated', p_merchant_id,
    jsonb_build_object(
      'user_id',             p_user_id,
      'name',                v_nombre,
      'before',              v_antes,
      'after',               p_role,
      'solo_registra_antes', v_solo_antes,
      'solo_registra',       v_solo
    ));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.merchant_staff_update(uuid, uuid, text, public.merchant_role, uuid, boolean)
  from public, anon;
grant execute on function public.merchant_staff_update(uuid, uuid, text, public.merchant_role, uuid, boolean)
  to authenticated;

create or replace function public.merchant_staff_list(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  perform public.helios_assert_staff_manager(p_merchant_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id',       mu.user_id,
    'name',          coalesce(p.full_name, au.raw_user_meta_data ->> 'full_name'),
    'email',         au.email,
    'phone',         p.phone_e164,
    'role',          mu.role,
    'branch_id',     mu.branch_id,
    'branch',        b.name,
    'created_at',    mu.created_at,
    -- Para que la pantalla pueda apagar «cambiar mi rol» y «darme de baja»
    -- en vez de dejar que el servidor lo rechace despues de pulsar.
    'is_self',       mu.user_id = auth.uid(),
    -- NUEVO (2026-10-29).
    'solo_registra', mu.solo_registra
  ) order by mu.created_at), '[]'::jsonb) into v_rows
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.profiles p on p.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  return jsonb_build_object('rows', v_rows);
end;
$$;

-- ── El historial: cerrado para quien solo registra ─────────────────────────
-- Las definiciones vivas, con una sola línea nueva: la guardia.

CREATE OR REPLACE FUNCTION public.merchant_transactions(p_from date, p_to date, p_limit integer DEFAULT 500)
 RETURNS TABLE(charge_id uuid, order_number bigint, business_date date, confirmed_at timestamp with time zone, amount_usd numeric, merchant_sale_usd numeric, customer_name text, staff_name text, cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date, concept text, beneficiary_name text, receipt_status text, staff_commission_usd numeric, registered_by_name text, status text, expires_at timestamp with time zone, currency text, merchant_sale_cur numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.created_at as creado,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro,
           c.concept as concepto,
           c.beneficiary_name as atendido,
           c.staff_commission_usd as comision,
           c.status::text as estado,
           c.expires_at as vence,
           c.currency as moneda,
           coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)) as sale_cur
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status in ('confirmed', 'pending', 'declined', 'expired')
      and c.business_date between p_from and p_to
      -- El gerente de ESA clínica ve todos; cualquier otro, solo los suyos.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    order by c.business_date desc, coalesce(c.confirmed_at, c.created_at) desc
    limit v_limit
  ),
  cuotas as (
    select (m.id)                                                  as cid,
           (x->>'sequence')::integer                               as seq,
           (x->>'due_date')::date                                  as due,
           public.helios_settlement_run_for((x->>'due_date')::date) as run
    from mias m
    cross join lateral jsonb_array_elements(public.helios_charge_planned_installments(m.id)) x
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         p.full_name,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         c1.due,
         c1.run,
         c2.due,
         c2.run,
         m.concepto,
         m.atendido,
         case when m.estado = 'confirmed' then public.helios_charge_receipt(m.id) ->> 'status'
              else 'sin_enviar' end,
         m.comision,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         m.estado,
         case when m.estado in ('pending', 'expired') then m.vence end,
         m.moneda,
         m.sale_cur
  from mias m
  left join public.profiles p on p.id = m.quien
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, coalesce(m.conf, m.creado) desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.merchant_transactions_summary(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
  v_orders     integer := 0;
  v_sale       numeric := 0;
  v_charged    numeric := 0;
  v_days       integer := 0;
  v_por_moneda jsonb;
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  select
    count(*)::integer,
    coalesce(sum(public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)), 0),
    coalesce(sum(c.amount_usd), 0),
    count(distinct c.business_date)::integer
  into v_orders, v_sale, v_charged, v_days
  from public.charges c
  where c.merchant_id in (select public.my_merchant_ids())
    and c.status = 'confirmed'
    and c.business_date between p_from and p_to
    and (c.merchant_id = v_gerente_de or c.requested_by = v_me);

  select coalesce(jsonb_agg(jsonb_build_object('currency', m.currency, 'sale', m.sale)
                            order by m.currency <> 'USD', m.currency), '[]'::jsonb)
  into v_por_moneda
  from (
    select coalesce(c.currency, 'USD') as currency,
           round(sum(coalesce(c.base_cur,
             public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd))), 2) as sale
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    group by 1
  ) m;

  return jsonb_build_object(
    'scope',            case when v_gerente_de is null then 'self' else 'gerente' end,
    'order_count',      v_orders,
    'sale_usd',         round(v_sale, 2),
    'sale_by_currency', v_por_moneda,
    'charged_usd',      round(v_charged, 2),
    'avg_ticket_usd',   public.helios_avg_ticket_usd(v_sale, v_orders),
    'active_days',      v_days
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.merchant_sales_by_staff(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gerente_de uuid := public.my_merchant_id_as_gerente();
  v_me         uuid := auth.uid();
  v_rows       jsonb;
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',          x.user_id,
           'name',             x.nombre,
           'role',             x.role,
           'is_active',        x.is_active,
           'is_self',          x.is_self,
           'order_count',      x.order_count,
           'sale_usd',         x.sale_usd,
           'sale_by_currency', (
             select coalesce(jsonb_agg(jsonb_build_object('currency', m.currency, 'sale', m.sale)
                                       order by m.currency <> 'USD', m.currency), '[]'::jsonb)
             from (
               select coalesce(c2.currency, 'USD') as currency,
                      round(sum(coalesce(c2.base_cur,
                        public.helios_merchant_sale_usd(c2.base_usd, c2.vat_usd, c2.amount_usd))), 2) as sale
               from public.charges c2
               where c2.merchant_id = x.merchant_id
                 and c2.requested_by is not distinct from x.user_id
                 and c2.status = 'confirmed'
                 and c2.business_date between p_from and p_to
               group by 1
             ) m
           ),
           'charged_usd',      x.charged_usd,
           'avg_ticket_usd',   public.helios_avg_ticket_usd(x.sale_usd, x.order_count),
           'active_days',      x.active_days,
           'last_sale_at',     x.last_sale_at,
           -- Helios: la comisión devengada por esos financiamientos.
           'commission_usd',   x.commission_usd
         ) order by x.sale_usd desc, x.nombre), '[]'::jsonb)
  into v_rows
  from (
    select c.requested_by                                as user_id,
           c.merchant_id                                 as merchant_id,
           public.helios_staff_name(c.requested_by)       as nombre,
           (select mu.role::text
              from public.merchant_users mu
             where mu.user_id = c.requested_by
               and mu.merchant_id = c.merchant_id
             order by mu.is_active desc, mu.created_at desc
             limit 1)                                    as role,
           coalesce((select bool_or(mu.is_active)
                       from public.merchant_users mu
                      where mu.user_id = c.requested_by
                        and mu.merchant_id = c.merchant_id), false) as is_active,
           c.requested_by = v_me                         as is_self,
           count(*)::integer                             as order_count,
           round(sum(public.helios_merchant_sale_usd(
             c.base_usd, c.vat_usd, c.amount_usd)), 2)   as sale_usd,
           round(sum(c.amount_usd), 2)                   as charged_usd,
           count(distinct c.business_date)::integer      as active_days,
           max(c.confirmed_at)                           as last_sale_at,
           round(coalesce(sum(sc.amount_usd) filter (where sc.status <> 'revertida'), 0), 2)
                                                         as commission_usd
    from public.charges c
    left join public.staff_commissions sc on sc.charge_id = c.id
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    group by c.requested_by, c.merchant_id
  ) x;

  return jsonb_build_object(
    'scope', case when v_gerente_de is null then 'self' else 'gerente' end,
    'rows',  v_rows
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.merchant_charge_detail(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_charge  public.charges%rowtype;
  v_gerente boolean;
  v_out     jsonb;
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := coalesce(public.my_merchant_id_as_gerente() = v_charge.merchant_id, false);

  if not v_gerente and v_charge.requested_by is distinct from auth.uid() then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- El nombre del paciente, y nada más de él (ni deuda ni pagos).
    'customer_name', p.full_name,
    'staff_name', public.helios_staff_name(c.requested_by),
    'merchant_sale_usd', public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd),
    'base_usd', c.base_usd,
    'vat_usd', c.vat_usd,
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', case when v_gerente then c.merchant_fee_usd end,
    'merchant_fee_vat_usd', case when v_gerente then c.merchant_fee_vat_usd end,
    'merchant_net_usd', case when v_gerente then c.merchant_net_usd end,
    -- En la moneda en la que cobró la clínica: lo que se le enseña.
    'currency', c.currency,
    'merchant_sale_cur', coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)),
    'base_cur', c.base_cur,
    'consumer_fee_cur', c.consumer_fee_cur,
    'consumer_fee_vat_cur', c.consumer_fee_vat_cur,
    'merchant_net_cur', case when v_gerente then c.merchant_net_cur end,
    'is_gerente', v_gerente,
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission_usd', c.staff_commission_usd,
    'commission_staff_name', case when c.commission_staff_id is not null
                                  then public.helios_staff_name(c.commission_staff_id) end,
    'payer_count', 1
  )
  into v_out
  from public.charges c
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd,
      'line_total_cur', round(ci.line_total_usd * coalesce(v_charge.base_cur, v_charge.base_usd)
                              / nullif(v_charge.base_usd, 0), 2)
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Las cuotas del paciente: SOLO sus fechas y cuándo se le paga a la clínica
  -- la mitad que corresponde. Nunca si el paciente pagó.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'sequence', m.seq,
      'due_date', m.due,
      'run_date', public.helios_settlement_run_for(m.due),
      'paid_to_merchant_on', (
        select max(coalesce(mp.paid_on, mp.business_date))
        from public.settlements s
        join public.merchant_payout_items it on it.settlement_id = s.id
        join public.merchant_payouts mp on mp.id = it.payout_id
        where s.charge_id = p_charge_id
          and s.reason = 'scheduled_installment'
          and s.business_date = m.due
          and s.status = 'paid'
      )
    ) order by m.seq)
    from (
      select i.sequence as seq, min(i.due_date) as due
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.sequence
    ) m
  ), '[]'::jsonb));

  -- Cuándo se le paga a la clínica cada parte: el adelanto (si lo hay), cada
  -- mitad y la comisión del personal. Los montos, solo al gerente. Cada parte
  -- en su moneda (`currency`, `amount_cur`): la consulta en la de la orden y
  -- la comisión en dólares.
  v_out := v_out || jsonb_build_object('payouts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', x.kind,
      'sequence', x.seq,
      'due_date', x.due,
      'run_date', public.helios_settlement_run_for(x.due),
      'amount_usd', case when v_gerente or x.kind = 'staff_commission' then x.amount end,
      'paid_usd', case when v_gerente or x.kind = 'staff_commission' then x.paid end,
      'status', case when v_gerente or x.kind = 'staff_commission' then x.status end,
      'currency', x.moneda,
      'amount_cur', case when v_gerente or x.kind = 'staff_commission' then x.amount_c end,
      'paid_cur', case when v_gerente or x.kind = 'staff_commission' then x.paid_c end
    ) order by x.due, x.seq nulls first)
    from (
      select 'advance'::text    as kind,
             null::smallint     as seq,
             s.due_date         as due,
             s.amount_usd       as amount,
             s.paid_usd         as paid,
             s.status::text     as status,
             s.currency         as moneda,
             s.amount_cur       as amount_c,
             s.paid_cur         as paid_c
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'advance'

      union all

      select 'installment',
             m.seq,
             m.due,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             coalesce(s.currency, v_charge.currency),
             s.amount_cur,
             s.paid_cur
      from (
        select i.sequence as seq, min(i.due_date) as due
        from public.installments i
        where i.charge_id = p_charge_id
        group by i.sequence
      ) m
      left join public.settlements s
        on s.charge_id = p_charge_id
       and s.reason = 'scheduled_installment'
       and s.business_date = m.due

      union all

      select 'staff_commission',
             null::smallint,
             s.due_date,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             s.currency,
             s.amount_cur,
             s.paid_cur
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'staff_commission'
    ) x
  ), '[]'::jsonb));

  return v_out;
end;
$function$;

CREATE OR REPLACE FUNCTION public.merchant_charge_items(p_charge_id uuid)
 RETURNS TABLE(id uuid, product_id uuid, name text, quantity integer, unit_price_usd numeric, line_total_usd numeric, "position" smallint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select ci.id,
         ci.product_id,
         ci.name,
         ci.quantity,
         ci.unit_price_usd,
         ci.line_total_usd,
         ci.position
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  where ci.charge_id = p_charge_id
    and c.merchant_id in (select public.my_merchant_ids())
    and (c.merchant_id = public.my_merchant_id_as_gerente() or c.requested_by = auth.uid())
    -- La secretaria que solo registra no consulta el historial (2026-10-29).
    and not public.helios_solo_registra()
  order by ci.position, ci.created_at;
$function$;
