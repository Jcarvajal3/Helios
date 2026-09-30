-- ============================================================================
-- Ronda — Los grupos de antes se pueden mirar
--
-- Un grupo vive una noche: `my_groups` solo devuelve los del día operativo en
-- curso, así que a las 10 AM el grupo de anoche desaparece de la pestaña sin
-- dejar nada detrás. Lo que se gastó sigue en Cuotas y en el historial, pero
-- repartido en compras sueltas: no queda forma de contestar "¿quiénes
-- estábamos?", "¿cuánto puso cada uno?" ni "¿cuánto fue esa noche en total?".
--
-- Aquí están las dos lecturas que faltaban. Son SOLO LECTURA por diseño y no
-- por convención de pantalla:
--
--   · No mandan `invite_code`. Sin código no hay a quién invitar a una noche
--     que ya terminó, y la pantalla no puede enseñarlo aunque quiera.
--   · No mandan capacidad, bote ni `can_take_debt`. Esas tres son del HOY de
--     cada persona —`min(techo − gastado, disponible)`— así que en un grupo
--     muerto delatarían el saldo de crédito actual de gente con la que se
--     compartió una noche hace meses. Es la misma razón por la que
--     `group_detail` las calla cuando el grupo ya no está vivo.
--
-- Lo que sí viajan son HECHOS de esa noche y no cambian nunca más: el techo
-- que cada quien puso, lo que se le cargó, las cuentas del local y la parte de
-- quien mira.
--
-- ── Las cifras son CUPO ────────────────────────────────────────────────────
--
-- Todo lo que sale de aquí es lo financiado —lo que cobró el local, sin el fee
-- del servicio—, que es de lo que es techo un aporte (`spent_usd` se suma con
-- lo financiado, ver `20260830190000_el_fee_no_come_cupo`). La deuda con el
-- fee dentro se paga por cuotas y vive en Cuotas y en el recibo de cada
-- cuenta, que es donde ya se mira. Mezclar las dos clases en una sola columna
-- fue el bug de los grupos (docs/00 §2.11).
--
-- ── Quién sale en la lista de integrantes ──────────────────────────────────
--
-- Los que terminaron dentro, MÁS quien se fue habiendo gastado. Un grupo vivo
-- solo cuenta a los que siguen dentro (`group_participants`), pero aquí eso
-- dejaría una noche donde la suma de lo de cada uno no llega al total del
-- grupo, sin nada que lo explique. Quien puso dinero sale, se haya ido o no.
-- ============================================================================

-- ── 1. La lista ────────────────────────────────────────────────────────────

/**
 * Mis grupos ya cerrados, del más reciente al más viejo.
 *
 * El corte es el mismo que el de `my_groups` por el otro lado: `business_date`
 * anterior al día operativo en curso. Los dos juntos cubren todos los grupos
 * en los que estoy y ninguno sale en los dos.
 *
 * Tope de 50. Un grupo por noche es lo normal, así que son casi dos meses de
 * salidas; más atrás de eso la pregunta ya no es "¿quiénes estábamos?" sino
 * "¿qué compré?", y esa la contesta el historial del perfil, que los trae
 * todos.
 */
create or replace function public.my_past_groups()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_bdate date := public.helios_business_date(now());
  v_rows  jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- El `order by` va DENTRO del agregado además de en el subselect: sin él,
  -- el orden del `jsonb_agg` es el que quiera el plan, y el `limit` de abajo
  -- no lo garantiza.
  select coalesce(jsonb_agg(x order by x->>'business_date' desc,
                                     x->>'created_at' desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'group_id',      g.id,
      'name',          g.name,
      'business_date', g.business_date,
      'created_at',    g.created_at,
      'closed_at',     public.helios_business_day_end(g.business_date),
      'created_by_me', g.created_by = v_user,
      'members', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'user_id',   m.user_id,
                 'name',      p.full_name,
                 'is_me',     m.user_id = v_user,
                 'cap_usd',   m.cap_usd,
                 'spent_usd', m.spent_usd
               ) order by m.user_id), '[]'::jsonb)
        from public.group_members m
        join public.profiles p on p.id = m.user_id
        where m.group_id = g.id
          and (m.left_at is null or m.spent_usd > 0)
      ),
      'my_cap_usd',   mine.cap_usd,
      'my_spent_usd', mine.spent_usd,
      -- El total de la noche sale de las CUENTAS y no de sumar lo de cada
      -- quien: es lo que cobró el local, que es un hecho suyo y no depende de
      -- a quién le tocó.
      'spent_usd', (
        select coalesce(sum(coalesce(c.base_usd, c.amount_usd)), 0)
        from public.charges c
        where c.group_id = g.id and c.status = 'confirmed'
      ),
      'charges_count', (
        select count(*)
        from public.charges c
        where c.group_id = g.id and c.status = 'confirmed'
      )
    ) as x
    from public.groups g
    join public.group_members mine
      on mine.group_id = g.id and mine.user_id = v_user and mine.left_at is null
    where g.business_date < v_bdate
    order by g.business_date desc, g.created_at desc
    limit 50
  ) s;

  return v_rows;
end;
$$;

comment on function public.my_past_groups() is
  'Los grupos ya cerrados de quien llama, del más reciente al más viejo (50). '
  'Solo hechos de esa noche: ni código de invitación, ni capacidad, ni bote.';

revoke all on function public.my_past_groups() from public, anon;
grant execute on function public.my_past_groups() to authenticated;

-- ── 2. El detalle ──────────────────────────────────────────────────────────

/**
 * Una noche por dentro: quién estuvo, cuánto puso cada uno y qué se consumió.
 *
 * Es el gemelo muerto de `group_detail`, y está aparte a propósito en vez de
 * ser un `if` dentro de aquél: `group_detail` alimenta la pantalla desde la
 * que se invita, se paga y se mueve el aporte, y esas tres cosas necesitan
 * cifras de hoy. Separarlos es lo que hace que la pantalla del archivo no
 * pueda enseñar —ni por descuido— un dato vivo.
 *
 * Vale para cualquier grupo en el que siga estando, vivo o no; `business_date`
 * dice de qué noche es. No refuerza el corte de las 10 AM porque no hay nada
 * que proteger: lo que devuelve es un subconjunto de lo que `group_detail` ya
 * daba.
 */
create or replace function public.past_group_detail(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_mine  public.group_members%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_mine from public.group_members
  where group_id = p_group_id and user_id = v_user and left_at is null;

  if not found then
    raise exception 'No estás en este grupo' using errcode = '42501';
  end if;

  select * into v_group from public.groups where id = p_group_id;

  return jsonb_build_object(
    'group_id',      v_group.id,
    'name',          v_group.name,
    'business_date', v_group.business_date,
    'closed_at',     public.helios_business_day_end(v_group.business_date),
    'created_by_me', v_group.created_by = v_user,
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id',   m.user_id,
               'name',      p.full_name,
               'is_me',     m.user_id = v_user,
               'cap_usd',   m.cap_usd,
               'spent_usd', m.spent_usd
             ) order by m.user_id), '[]'::jsonb)
      from public.group_members m
      join public.profiles p on p.id = m.user_id
      where m.group_id = p_group_id
        and (m.left_at is null or m.spent_usd > 0)
    ),
    'my_cap_usd',   v_mine.cap_usd,
    'my_spent_usd', v_mine.spent_usd,
    -- Sin el total de la noche, que sí manda la lista. Aquí la pantalla dibuja
    -- un anillo con un segmento por persona, y la regla de ese anillo es que
    -- la cifra del centro sea la SUMA DE LOS SEGMENTOS: mandar un total
    -- calculado por otro camino es abrir la puerta a que el centro contradiga
    -- al dibujo que tiene alrededor. Las dos cifras son la misma desde que el
    -- fee no come cupo, y esta es la que el anillo puede probar.
    'charges', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'charge_id',     c.id,
               'merchant_name', mm.name,
               'financed_usd',  coalesce(c.base_usd, c.amount_usd),
               'confirmed_at',  c.confirmed_at,
               'started_by',    pr.full_name,
               -- `null` cuando no me tocó nada de esta cuenta. Cero no vale:
               -- una parte de €0 y no tener parte son cosas distintas y la
               -- fila las dice distinto.
               'my_financed_usd', case when mine.n > 0 then mine.financed end,
               /**
                * Por qué no me tocó, cuando se puede probar.
                *
                * Solo hay un motivo demostrable a posteriori —la cuenta era
                * muy chica para repartirla entre uno más— y es el mismo que
                * calcula `group_detail`. Los otros tres (§2.7.5) dependen del
                * estado que tenía cada quien EN AQUEL MOMENTO, que no se
                * guarda: adivinarlo con los datos de hoy sería inventarse un
                * motivo en una pantalla de dinero.
                */
               'my_share_reason', case
                 when mine.n > 0 then null
                 when coalesce(c.base_usd, c.amount_usd) <
                      ((select count(distinct i.user_id) from public.installments i
                        where i.charge_id = c.id) + 1) * public.min_share_usd()
                   then 'too_small'
                 else null
               end
             ) order by c.confirmed_at desc), '[]'::jsonb)
      from public.charges c
      join public.merchants mm on mm.id = c.merchant_id
      left join public.profiles pr on pr.id = c.user_id
      left join lateral (
        select count(*) as n,
               coalesce(sum(i.financed_usd), sum(i.amount_usd)) as financed
        from public.installments i
        where i.charge_id = c.id and i.user_id = v_user
      ) mine on true
      where c.group_id = p_group_id and c.status = 'confirmed'
    )
  );
end;
$$;

comment on function public.past_group_detail(uuid) is
  'Una noche de grupo por dentro, solo para mirar: integrantes con lo que puso '
  'cada uno, el total del local y las cuentas con la parte de quien llama.';

revoke all on function public.past_group_detail(uuid) from public, anon;
grant execute on function public.past_group_detail(uuid) to authenticated;
