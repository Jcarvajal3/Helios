-- ============================================================================
-- El archivo de grupos no enseña el fee: lo de cada quien sale de sus cuotas
-- ============================================================================
-- REGLA (Javier, 2026-09-22): ningún total lleva el fee de Ronda sumado. Los
-- montos son lo que se descontó del saldo; el fee solo aparece como cuotas o
-- como línea aparte de un desglose.
--
-- `my_past_groups` y `past_group_detail` leían lo de cada integrante de
-- `group_members.spent_usd`, que es un CONTADOR del grupo vivo. Hasta
-- 20260830190000 ese contador se sumaba con lo que se paga —fee dentro—, así
-- que los grupos anteriores a esa fecha enseñan en el anillo y en la tarjeta
-- una cifra con fee, y justo debajo las cuentas sin él. En dev, el grupo del
-- 2026-08-28: 4,79 en el anillo para 3,76 de consumo.
--
-- Producción no tiene grupos de antes del cambio (se vació el 2026-09-19) y
-- sus 22 integrantes cuadran. Pero un contador no es un hecho: aquí cada cifra
-- sale de lo que se le cargó a cada quien, que son sus cuotas (`financed_usd`)
-- de las cuentas confirmadas del grupo. Es la misma fuente que ya usaba
-- `my_financed_usd` en las cuentas, así que el anillo y las facturas de debajo
-- no pueden volver a contradecirse.
--
-- ── Y la cara de cada quien ────────────────────────────────────────────────
--
-- El archivo pintaba la inicial: el avatar se leía de `profiles`, y esa tabla
-- solo deja ver a los compañeros de HOY (`profiles_read_group_mates`). Ahora
-- viaja en la respuesta —solo el emoji y la clave del color, nada más del
-- perfil—, igual que en `find_group_by_code`. No abre `profiles`: la RPC ya
-- comprueba que quien pregunta estuvo en el grupo, y el nombre ya viajaba.
--
-- Lo demás es copia literal de 20260921140000.
-- ============================================================================

/**
 * Lo que se le cargó a una persona en un grupo, sin el fee.
 *
 * Suma de sus cuotas de las cuentas confirmadas del grupo. `financed_usd`
 * existe en todas las cuotas desde 20260830190000 (se rellenó hacia atrás); el
 * `coalesce` interior es solo la red por si alguna quedara sin él, y entonces
 * se prefiere no contarla antes que contarla con fee.
 */
create or replace function public.helios_group_member_financed(p_group_id uuid, p_user_id uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(sum(coalesce(i.financed_usd, 0)), 0)
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.group_id = p_group_id
    and c.status = 'confirmed'
    and i.user_id = p_user_id;
$$;

comment on function public.helios_group_member_financed(uuid, uuid) is
  'Lo que se le cargó a una persona en un grupo, sin el fee: la suma de sus cuotas (financed_usd) de las cuentas confirmadas.';

-- Sin grant: solo se llama desde las dos RPC de abajo, que ya comprueban que
-- quien pregunta estuvo en el grupo.
revoke all on function public.helios_group_member_financed(uuid, uuid) from public, anon, authenticated;

-- ── 1. La lista ────────────────────────────────────────────────────────────

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
                 -- NUEVO: la cara que eligió. Ver la cabecera.
                 'avatar_emoji', p.avatar_emoji,
                 'avatar_color', p.avatar_color,
                 'cap_usd',   m.cap_usd,
                 'spent_usd', public.helios_group_member_financed(g.id, m.user_id)
               ) order by m.user_id), '[]'::jsonb)
        from public.group_members m
        join public.profiles p on p.id = m.user_id
        where m.group_id = g.id
          and (m.left_at is null or public.helios_group_member_financed(g.id, m.user_id) > 0)
      ),
      'my_cap_usd',   mine.cap_usd,
      'my_spent_usd', public.helios_group_member_financed(g.id, v_user),
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
               -- NUEVO: la cara que eligió. Ver la cabecera.
               'avatar_emoji', p.avatar_emoji,
               'avatar_color', p.avatar_color,
               'cap_usd',   m.cap_usd,
               'spent_usd', public.helios_group_member_financed(p_group_id, m.user_id)
             ) order by m.user_id), '[]'::jsonb)
      from public.group_members m
      join public.profiles p on p.id = m.user_id
      where m.group_id = p_group_id
        and (m.left_at is null or public.helios_group_member_financed(p_group_id, m.user_id) > 0)
    ),
    'my_cap_usd',   v_mine.cap_usd,
    'my_spent_usd', public.helios_group_member_financed(p_group_id, v_user),
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
