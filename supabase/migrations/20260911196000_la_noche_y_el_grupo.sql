-- ============================================================================
-- Ronda — El detalle de un consumo en grupo, y el resumen por noche
--
-- Dos preguntas que la pestaña de Consumos no sabía contestar.
--
-- ---------------------------------------------------------------------------
-- 1. «Grupo» era una etiqueta y nada más
-- ---------------------------------------------------------------------------
-- Un consumo de grupo genera un cargo por persona. La tabla los marca, pero
-- para saber quiénes se unieron y cuánto le tocó a cada uno había que ir
-- persona por persona. Y esa es justo la llamada que llega: «mi amigo dice que
-- pagó lo suyo, ¿por qué a mí me sigue apareciendo?».
--
-- ---------------------------------------------------------------------------
-- 2. Una noche no es un día
-- ---------------------------------------------------------------------------
-- El resumen por local y día operativo contesta la pregunta con la que el
-- equipo abre el lunes: cómo fue el viernes en cada sitio. Lleva las personas
-- **nuevas frente a repetidas**, que es lo que distingue un local que está
-- construyendo clientela de uno que vive de los mismos veinte.
--
-- «Nueva» quiere decir que esa persona no había consumido nunca en ese local,
-- no que se registrara esa noche: lo que se está midiendo es si el local trae
-- gente, no si Ronda la trae.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- El detalle de un consumo
-- ---------------------------------------------------------------------------

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

comment on function public.admin_charge_detail(uuid) is
  'Un consumo con sus cuotas y, si fue en grupo, quienes se unieron y cuanto le toco a cada uno. Contesta "mi amigo dice que pago lo suyo" sin abrir cuatro fichas.';

revoke all on function public.admin_charge_detail(uuid) from public, anon;
grant execute on function public.admin_charge_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- El resumen por noche
-- ---------------------------------------------------------------------------

create or replace function public.admin_nights(
  p_days        integer default 14,
  p_merchant_id uuid default null
)
returns table (
  business_date   date,
  merchant_id     uuid,
  merchant_name   text,
  charge_count    integer,
  financed_usd    numeric,
  avg_ticket_usd  numeric,
  distinct_users  integer,
  new_users       integer,
  repeat_users    integer,
  first_sale_at   timestamptz,
  last_sale_at    timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 14), 180), 1);
  v_from  date;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (v_days - 1);

  return query
  with noches as (
    select
      c.business_date as d,
      c.merchant_id   as mid,
      c.user_id       as uid,
      c.amount_usd,
      c.confirmed_at,
      -- ¿Había consumido antes en ESTE local? Se mira contra toda su historia
      -- con el local, no contra la ventana: alguien que vino en julio y vuelve
      -- hoy no es clientela nueva.
      not exists (
        select 1 from public.charges c0
        where c0.merchant_id = c.merchant_id
          and c0.user_id = c.user_id
          and c0.status = 'confirmed'
          and c0.business_date < c.business_date
      ) as es_nuevo
    from public.charges c
    where c.status = 'confirmed'
      and not c.is_test
      and c.business_date between v_from and v_today
      and (p_merchant_id is null or c.merchant_id = p_merchant_id)
  )
  select
    n.d,
    n.mid,
    m.name,
    count(*)::integer,
    sum(n.amount_usd)::numeric,
    round(sum(n.amount_usd) / count(*), 2),
    count(distinct n.uid)::integer,
    count(distinct n.uid) filter (where n.es_nuevo)::integer,
    count(distinct n.uid) filter (where not n.es_nuevo)::integer,
    min(n.confirmed_at),
    max(n.confirmed_at)
  from noches n
  join public.merchants m on m.id = n.mid
  group by n.d, n.mid, m.name
  order by n.d desc, sum(n.amount_usd) desc;
end;
$$;

comment on function public.admin_nights(integer, uuid) is
  'Por local y dia operativo: consumos, financiado, ticket, y personas nuevas frente a repetidas. "Nueva" es que no habia consumido nunca en ESE local, que es lo que mide si el local trae gente.';

revoke all on function public.admin_nights(integer, uuid) from public, anon;
grant execute on function public.admin_nights(integer, uuid) to authenticated;
