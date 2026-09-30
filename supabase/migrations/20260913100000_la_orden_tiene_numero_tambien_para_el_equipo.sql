-- ============================================================================
-- El número de orden llega también al panel del equipo
-- ============================================================================
--
-- `charges.order_number` existe desde 20260822250000 y su propio comentario
-- explica para qué: «el uuid del cobro sirve para el QR, no para hablar.
-- Cuando el cajero tiene que reclamar algo por teléfono, "la orden 1043"
-- funciona y "a3f2b8c1-…" no».
--
-- Y sin embargo el super admin era el único sitio que no lo tenía. El panel
-- del local lo enseña en su columna `# Orden`, la cola de Cobros lo enseña en
-- el desglose de un pago —«Orden #1043 · cuota 2»—, pero `admin_charges` ni lo
-- devolvía ni lo buscaba. O sea: el local llama diciendo un número que el
-- equipo no puede ni ver en su lista ni escribir en su buscador.
--
-- Dos funciones de solo lectura. No toca ni un dato: es lo que ya está en la
-- tabla, dicho.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La lista
-- ---------------------------------------------------------------------------
-- Cambia el RETURNS TABLE, así que hay que tirarla antes: CREATE OR REPLACE no
-- puede cambiar el tipo de retorno de una función.

drop function if exists public.admin_charges(text, uuid, text, date, date, integer);

create or replace function public.admin_charges(
  p_search      text default null,
  p_merchant_id uuid default null,
  p_status      text default null,
  p_from        date default null,
  p_to          date default null,
  p_limit       integer default 100
)
returns table (
  charge_id      uuid,
  order_number   bigint,
  amount_usd     numeric,
  status         text,
  business_date  date,
  created_at     timestamptz,
  confirmed_at   timestamptz,
  void_reason    text,
  user_id        uuid,
  full_name      text,
  phone_e164     text,
  user_status    text,
  merchant_id    uuid,
  merchant_name  text,
  branch_name    text,
  is_group       boolean,
  is_test        boolean,
  installments_paid integer,
  installments_total integer
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_needle text;
  v_order  bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  -- Se compara por igualdad y no por LIKE: el número es único global, así que
  -- quien escribe 1043 quiere ESA orden y no las cuarenta que empiezan por
  -- 1043.
  --
  -- El tope de 18 dígitos no es decorativo: un bigint llega hasta 19 cifras y
  -- el cast de una cadena más larga no devuelve null, revienta. Quien pegue
  -- una referencia bancaria de veinte dígitos en el buscador tiene que ver
  -- «no hay resultados», no una pantalla de error.
  if v_needle ~ '^#?\d{1,18}$' then
    v_order := replace(v_needle, '#', '')::bigint;
  else
    v_order := null;
  end if;

  return query
  select
    ch.id,
    ch.order_number,
    ch.amount_usd,
    ch.status::text,
    ch.business_date,
    ch.created_at,
    ch.confirmed_at,
    ch.void_reason,
    ch.user_id,
    p.full_name,
    p.phone_e164,
    p.status::text,
    m.id,
    m.name,
    b.name,
    -- Un consumo de grupo genera N cargos hermanos con el mismo grupo detrás.
    -- Marcarlo evita que alguien lea ocho filas de $12,50 como ocho consumos
    -- sueltos de una noche rara.
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    -- `ins.` explícito: el OUT parameter de esta función también se llama
    -- `charge_id` y sin calificar la columna Postgres no sabe a cuál se
    -- refiere.
    select ins.charge_id as cid,
           count(*) filter (where ins.status = 'paid')::integer as paid,
           count(*)::integer as total
    from public.installments ins group by 1
  ) i on i.cid = ch.id
  where
    (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    and (p_status is null or ch.status::text = p_status)
    and (p_from is null or ch.business_date >= p_from)
    and (p_to is null or ch.business_date <= p_to)
    and (
      v_needle is null
      -- El número de orden SUMA, no sustituye. Un teléfono venezolano son once
      -- dígitos, así que también casa el patrón de arriba: si lo del número
      -- excluyera al resto, buscar por teléfono en esta pantalla dejaría de
      -- funcionar. Y al revés no hay coste — si el texto no casa con nada, ese
      -- lado del OR simplemente no aporta filas.
      or (v_order is not null and ch.order_number = v_order)
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated;

comment on function public.admin_charges(text, uuid, text, date, date, integer) is
  'La lista de consumos del super admin. Busca por teléfono, nombre, cédula, local y número de orden (con o sin #).';

-- ---------------------------------------------------------------------------
-- 2. La ficha
-- ---------------------------------------------------------------------------
-- Devuelve jsonb, así que el tipo de retorno no cambia y basta con
-- reemplazarla. Va entera porque `create or replace` no admite parches.

create or replace function public.admin_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_charge public.charges%rowtype;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'charge_id', c.id,
    -- Lo que faltaba: el número con el que se habla de esta orden.
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'merchant_net_usd', c.merchant_net_usd,
    'is_group', c.group_id is not null,
    'group_id', c.group_id,
    'is_test', c.is_test,
    'merchant', jsonb_build_object('id', m.id, 'name', m.name),
    'user', case when p.id is null then null else jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone_e164', p.phone_e164
    ) end
  )
  into v_out
  from public.charges c
  join public.merchants m on m.id = c.merchant_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  -- Las cuotas de este consumo.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status::text,
      'paid_at', i.paid_at,
      'written_off_at', i.written_off_at,
      'days_overdue', greatest(v_today - i.due_date, 0)
    ) order by i.sequence)
    from public.installments i where i.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Quiénes se unieron. Los hermanos de un consumo de grupo son los cargos
  -- que comparten `group_id`: cada uno con su persona, su parte y su estado.
  v_out := v_out || jsonb_build_object('group', case
    when v_charge.group_id is null then null
    else (
      select jsonb_build_object(
        'group_id', g.id,
        'name', g.name,
        'business_date', g.business_date,
        'members', coalesce((
          select jsonb_agg(jsonb_build_object(
            'charge_id', c2.id,
            'user_id', c2.user_id,
            'full_name', p2.full_name,
            'phone_e164', p2.phone_e164,
            'amount_usd', c2.amount_usd,
            'status', c2.status::text,
            'installments_paid', (
              select count(*) filter (where i2.status = 'paid')::integer
              from public.installments i2 where i2.charge_id = c2.id
            ),
            'installments_total', (
              select count(*)::integer
              from public.installments i2 where i2.charge_id = c2.id
            ),
            'is_this_one', c2.id = p_charge_id
          ) order by c2.created_at)
          from public.charges c2
          left join public.profiles p2 on p2.id = c2.user_id
          where c2.group_id = g.id
        ), '[]'::jsonb)
      )
      from public.groups g where g.id = v_charge.group_id
    )
  end);

  return v_out;
end;
$$;

revoke all on function public.admin_charge_detail(uuid) from public, anon;
grant execute on function public.admin_charge_detail(uuid) to authenticated;
