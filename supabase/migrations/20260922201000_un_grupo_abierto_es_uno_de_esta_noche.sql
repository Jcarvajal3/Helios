-- ============================================================================
-- Ronda — Un grupo abierto es uno de esta noche
--
-- Pedir la eliminación de la cuenta (Apple 5.1.1(v)) exige no estar en ningún
-- grupo abierto, y `my_deletion_eligibility` lo decidía con
-- `groups.status = 'active'`. Esa columna ya no dice nada: nace en 'active' y
-- nadie la pasa a 'closed' desde que 20260827030000 retiró `close_group`. Un
-- grupo se cierra con su día operativo (20260828000000), no con su estado.
--
-- Así, para la base todo grupo seguía abierto para siempre, y quien hubiera
-- estado en uno —una sola noche, hace un mes— no podía pedir la eliminación
-- nunca. En producción, el 2026-09-22: 14 grupos, los 14 en 'active', y 24
-- personas sin poder pedirla.
--
-- ── Qué es un grupo abierto ────────────────────────────────────────────────
--
-- El de la noche en curso: lo que la app enseña en Grupos → Esta noche, y lo
-- que se cierra solo a las 10:00 de Caracas (`helios_business_day_end`).
--
--   abierto      business_date >= helios_business_date(now())
--   Anteriores   business_date <  helios_business_date(now())   (my_past_groups)
--
-- `my_groups` escribe `=`. Aquí va `>=` para que abierto sea exactamente lo que
-- todavía no está en Anteriores, sin hueco entre los dos. Hoy es el mismo
-- conjunto: solo `create_group` inserta grupos, y siempre con la fecha de hoy.
--
-- ── Lo que cambia ──────────────────────────────────────────────────────────
--
--   · `my_deletion_eligibility`: `open_groups` cuenta los grupos de esta noche
--     de los que la persona no ha salido.
--   · `request_account_deletion` no se toca: no cuenta grupos por su lado,
--     rechaza con el `can_request` de `my_deletion_eligibility`.
--   · `admin_group_metrics`: `groups.open` —el «N siguen abiertos» de
--     Crecimiento → Grupos— contaba todos los grupos de la historia.
--   · Los comentarios de `groups`: la tabla se describía como un archivo que
--     la app no lee, y `status` no avisaba de que no sirve para esto.
--
-- Los cuerpos son los de 20260918250000 y 20260919140000 salvo esas líneas.
-- ============================================================================

-- ── 1. ¿Puede esta cuenta solicitar la eliminación? ────────────────────────

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

  -- Los grupos de esta noche de los que no ha salido: en ellos todavía le
  -- pueden cargar una cuenta. Se cumple esperando a las 10:00 o saliendo.
  select count(*)
    into v_groups
  from public.group_members gm
  join public.groups g on g.id = gm.group_id
  where gm.user_id = v_user
    and gm.left_at is null
    and g.business_date >= public.helios_business_date(now());

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

revoke all on function public.my_deletion_eligibility() from public, anon;
grant execute on function public.my_deletion_eligibility() to authenticated;

-- ── 2. Crecimiento → Grupos: los que siguen abiertos ───────────────────────

create or replace function public.admin_group_metrics(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  -- Un grupo es de prueba si lo es quien lo creó: no hay bandera propia y no
  -- hace falta, porque un grupo sin cargos no entra en ninguna cifra de aquí.
  grupos as (
    select g.id, g.name, g.created_at, g.business_date,
           public.helios_business_date(g.created_at) as dia
    from public.groups g
    join public.profiles p on p.id = g.created_by and not p.is_test
  ),
  miembros as (
    select gm.group_id, count(*)::int as n
    from public.group_members gm
    join grupos g on g.id = gm.group_id
    where gm.status <> 'left'
    group by 1
  ),
  -- Los cargos de la ventana, marcados con si fueron de grupo. `payers` sale
  -- de las cuotas: es entre cuánta gente se repartió esa cuenta de verdad, no
  -- cuánta gente hay apuntada en el grupo.
  cargos as (
    select c.id, c.group_id, c.business_date as dia,
           coalesce(c.base_usd, c.amount_usd) as fin,
           (select count(distinct i.user_id)
            from public.installments i where i.charge_id = c.id)::int as payers
    from public.charges c
    where c.status = 'confirmed' and not c.is_test
      and c.business_date between v_from and v_to
  )
  select jsonb_build_object(
    'business_date', v_today,
    -- El rango QUE SE USÓ, no el que se pidió: la pantalla lo pinta, y si el
    -- servidor recortó el «hasta» a hoy hay que verlo ahí y no descubrirlo
    -- comparando barras.
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,

    'groups', jsonb_build_object(
      'total',     (select count(*) from grupos),
      'created',   (select count(*) from grupos where dia between v_from and v_to),
      -- Los de esta noche, sea cual sea la ventana: es una foto de ahora.
      'open',      (select count(*) from grupos where business_date >= v_today),
      -- Grupos que pusieron al menos una cuenta en la ventana. Un grupo creado
      -- y nunca usado es el fracaso silencioso de esta función.
      'with_spend', (select count(distinct group_id) from cargos where group_id is not null),
      'avg_members', (select coalesce(round(avg(n), 1), 0) from miembros)
    ),

    -- Grupo contra individual, en las dos monedas que importan: cuántas
    -- cuentas y cuánto dinero.
    'split', jsonb_build_object(
      'group_charges',  (select count(*) from cargos where group_id is not null),
      'solo_charges',   (select count(*) from cargos where group_id is null),
      'group_financed', (select coalesce(sum(fin), 0) from cargos where group_id is not null),
      'solo_financed',  (select coalesce(sum(fin), 0) from cargos where group_id is null),
      'group_avg_usd',  (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is not null),
      'solo_avg_usd',   (select coalesce(round(avg(fin), 2), 0) from cargos where group_id is null),
      'avg_payers',     (select coalesce(round(avg(payers), 2), 0) from cargos where group_id is not null)
    ),

    'series', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.day)
      from (
        select (v_from + k)              as day,
               coalesce(gc.n, 0)::int    as groups_created,
               coalesce(ca.n, 0)::int    as group_charges,
               coalesce(ca.f, 0)         as group_financed_usd
        from generate_series(0, v_days - 1) as g(k)
        left join (
          select dia, count(*) as n from grupos
          where dia between v_from and v_to group by 1
        ) gc on gc.dia = v_from + k
        left join (
          select dia, count(*) as n, sum(fin) as f from cargos
          where group_id is not null group by 1
        ) ca on ca.dia = v_from + k
      ) s
    ), '[]'::jsonb),

    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
        'group_id',     t.id,
        'name',         t.name,
        'members',      coalesce(m.n, 0),
        'charges',      t.cuentas,
        'financed_usd', t.financiado
      ) order by t.financiado desc)
      from (
        select g.id, g.name,
               count(ca.id)::int         as cuentas,
               coalesce(sum(ca.fin), 0)  as financiado
        from grupos g
        join cargos ca on ca.group_id = g.id
        group by g.id, g.name
        order by 4 desc
        limit 10
      ) t
      left join miembros m on m.group_id = t.id
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

revoke all on function public.admin_group_metrics(date, date) from public, anon;
grant execute on function public.admin_group_metrics(date, date) to authenticated;

-- ── 3. Lo que dice el esquema ──────────────────────────────────────────────
-- Es lo primero que lee quien consulta la tabla, y decía lo contrario de lo
-- que pasa: por eso `status = 'active'` parecía una forma válida de preguntar.

comment on table public.groups is
  'Los grupos de una noche. Cada uno vive un dia operativo (business_date) y se cierra solo cuando termina, a las 10:00 de Caracas: abierto mientras business_date >= helios_business_date(now()).';

comment on column public.groups.status is
  'No dice si el grupo esta abierto: nace en active y nada lo cambia. Abierto o cerrado sale de business_date.';
