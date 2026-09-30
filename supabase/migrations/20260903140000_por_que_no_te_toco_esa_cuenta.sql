-- ============================================================================
-- Ronda — Por qué no te tocó esa cuenta
--
-- En "Lo que se gastó", una cuenta en la que no participaste se pintaba como
-- cualquier otra con "$0,00". El código lo dejaba igual A PROPÓSITO, para no
-- asustar: de las cuatro causas posibles, tres son el sistema funcionando
-- bien. El efecto fue el contrario del buscado — un cero sin explicación,
-- junto a cifras que sí son deuda, se lee como un fallo de la app.
--
-- La app ya cambió el cero por "no te tocó", que es un estado y no un importe.
-- Falta la mitad que solo el servidor sabe: CUÁL de las causas fue.
--
-- ── Solo se dice lo que se puede probar ─────────────────────────────────────
--
-- Las causas son cuatro (docs/00 §2.7.5):
--
--   1. La cuenta no admitía a uno más cuando entraste — no llega a
--      `(deudores + 1) × $2,50`. **Comprobable ahora mismo**, con los datos
--      que hay: es aritmética sobre la propia cuenta.
--   2. Tenías una cuota vencida cuando se cobró.
--   3. Se te había agotado el aporte en ese momento.
--   4. La carrera: entraste en el mismo instante en que se confirmaba.
--
-- La 2 y la 3 dependen de tu estado EN AQUEL MOMENTO, y ese estado no se
-- guarda: hoy podrías estar al día y tener aporte de sobra, y adivinarlo con
-- los datos de ahora sería inventarse un motivo. La 4 es un fallo conocido y
-- no tiene nada que decirle al usuario.
--
-- Así que se devuelve `'too_small'` o nada. Un motivo inventado en una
-- pantalla de dinero es peor que ningún motivo: el usuario no puede
-- comprobarlo y sí puede reclamarlo.
--
-- La clasificación es la MISMA que la de `helios_group_split_gaps` —su primera
-- rama, y por el mismo orden— para que la vista de diagnóstico y la pantalla
-- no puedan contradecirse sobre la misma cuenta.
-- ============================================================================

/**
 * Cuerpo de 20260829040000 más `my_share_reason` en cada cuenta. Todo lo demás
 * es idéntico, incluida la regla de que un grupo muerto calla las capacidades
 * de los demás.
 */
create or replace function public.group_detail(p_group_id uuid)
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
  v_avail numeric(18,4);
  v_alive boolean;
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
  v_avail := public.available_usd(v_user);

  v_alive := v_group.business_date = public.helios_business_date(now());

  return jsonb_build_object(
    'group_id',    v_group.id,
    'name',        v_group.name,
    'invite_code', v_group.invite_code,
    'created_by_me', v_group.created_by = v_user,
    'closes_at',   public.helios_business_day_end(v_group.business_date),
    'is_alive',    v_alive,
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id',       p.user_id,
               'name',          p.name,
               'is_me',         p.user_id = v_user,
               -- El techo y lo gastado son hechos de ESA noche: no dicen nada
               -- de hoy y se quedan.
               'cap_usd',       p.cap_usd,
               'spent_usd',     p.spent_usd,
               -- La capacidad SÍ es de hoy —es `min(techo − gastado,
               -- disponible)`— así que en un grupo muerto delataría el saldo
               -- de crédito actual de gente que compartió una noche contigo
               -- hace meses. Se calla.
               'capacity_usd',  case when v_alive then p.capacity_usd else null end,
               'can_take_debt', case when v_alive then p.can_take_debt else null end
             ) order by p.user_id), '[]'::jsonb)
      from public.group_participants(p_group_id) p
    ),
    'my_cap_usd',     v_mine.cap_usd,
    'my_spent_usd',   v_mine.spent_usd,
    -- Lo mío sí puedo verlo siempre: es mi propio saldo.
    'my_left_usd',    greatest(least(v_mine.cap_usd - v_mine.spent_usd, v_avail), 0),
    'my_max_cap_usd', v_mine.spent_usd + v_avail,
    'pot_usd',        case when v_alive then public.group_pot_usd(p_group_id) else null end,
    'min_share_usd',  public.min_share_usd(),
    'charges', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'charge_id',   c.id,
               'merchant_name', mm.name,
               'amount_usd',  c.amount_usd,
               'confirmed_at', c.confirmed_at,
               'started_by',  pr.full_name,
               'my_share_usd', mine.total,
               /**
                * NUEVO: por qué no te tocó nada, cuando se puede probar.
                *
                * `null` cuando sí participaste —no hay nada que explicar— y
                * también cuando no participaste por un motivo que no consta.
                * La app enseña "no te tocó" a secas en ese caso, que es
                * verdad, en vez de una píldora que no lo sería.
                */
               'my_share_reason', case
                 when mine.total is not null then null
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
      -- Se saca a un `lateral` porque ahora hace falta DOS veces —la cifra y
      -- el motivo— y repetir la subconsulta la haría correr dos veces por
      -- fila, además de dejar dos sitios donde equivocarse.
      left join lateral (
        select sum(i.amount_usd) as total
        from public.installments i
        where i.charge_id = c.id and i.user_id = v_user
      ) mine on true
      where c.group_id = p_group_id and c.status = 'confirmed'
    )
  );
end;
$$;

revoke all on function public.group_detail(uuid) from public, anon;
grant execute on function public.group_detail(uuid) to authenticated;

comment on function public.group_detail(uuid) is
  'El grupo por dentro: gente, cifras y las cuentas de la noche, con el motivo por el que alguna no te tocó cuando consta. Ver docs/00-BASES 2.7.';
