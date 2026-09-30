-- ============================================================================
-- Ronda — El total de una cuenta es lo que cobró el local
--
-- La app ya enseña "Cuenta €5,00" en todo el flujo del cobro: lo que el bar
-- cobró, sin el servicio. Fuera de ese flujo seguía enseñando el total CON
-- servicio en todas partes —la actividad de Inicio, el historial, el recibo de
-- una cuenta, las cuentas de un grupo y la lista de entrar a uno— porque es lo
-- único que estas cinco RPC devuelven.
--
-- La regla del producto es una sola: **el consumo se enseña sin el fee, y el
-- fee solo aparece en forma de cuotas.** Para poder cumplirla hace falta que el
-- servidor mande las dos cifras, no una.
--
-- ── Lo que se añade ────────────────────────────────────────────────────────
--
--   `my_purchases`            `total_financed_usd`  y `my_financed_usd`
--   `charge_detail`           `my_financed_usd`     y `members[].financed_usd`
--   `group_detail`            `charges[].financed_usd` y `charges[].my_financed_usd`
--   `helios_group_join_plan`   `charges[].financed_usd`
--
-- Todo sale de sitios que ya existen y son exactos: la cuenta entera de
-- `charges.base_usd`, y la parte de cada quien de `installments.financed_usd`,
-- que guarda el cupo de cada cuota desde 20260830190000. **No hay ninguna regla
-- de tres**: deshacer el fee dividiendo daría mal en los cobros viejos, cuando
-- el porcentaje era 10% y no 20%.
--
-- ⚠️ ES ADITIVA. Ningún campo cambia de significado ni desaparece, así que
-- nada de lo que hay hoy se rompe. La app lee los nuevos con `?? el de antes`,
-- de modo que sin aplicar esta migración las pantallas siguen enseñando lo que
-- enseñaban — y con ella pasan a enseñar el consumo. Se puede aplicar y
-- desplegar en cualquier orden.
--
-- Cuerpos idénticos a los de su última migración salvo lo dicho.
-- ============================================================================


-- ── 1. La actividad y el historial ─────────────────────────────────────────

create or replace function public.my_purchases(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $fn$
declare
  v_user uuid := auth.uid();
  v_rows jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.confirmed_at desc), '[]'::jsonb)
    into v_rows
  from (
    select
      c.id                                   as charge_id,
      c.order_number,
      m.name                                 as merchant_name,
      m.logo_url                             as merchant_logo_url,
      b.name                                 as branch_name,
      c.business_date,
      c.confirmed_at,
      c.status::text                         as status,
      c.amount_usd                           as total_usd,
      -- NUEVO: las dos mismas cifras en CUPO. La pantalla enseña el consumo
      -- —lo que cobró el local— y deja el fee para las cuotas.
      coalesce(c.base_usd, c.amount_usd)     as total_financed_usd,
      mine.my_usd,
      mine.my_financed_usd,
      mine.paid_usd,
      mine.pending_usd,
      mine.installments,
      (c.group_id is not null)               as is_group,
      -- La COPIA manda sobre el join vivo: el nombre que se enseña es el que
      -- tenía el grupo el día del consumo, no el de hoy. El join se queda
      -- para los cobros que el backfill no hubiera alcanzado.
      coalesce(c.group_name, g.name)         as group_name,
      split.people                           as split_between,
      (c.user_id = v_user)                   as i_started_it,
      items.lines                            as items
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    left join public.merchant_branches b on b.id = c.branch_id
    left join public.groups g on g.id = c.group_id
    join lateral (
      select
        sum(i.amount_usd)                                                  as my_usd,
        -- Mi parte en CUPO. Vive en la cuota desde 20260830190000 y es exacta:
        -- no hay que deshacer ninguna regla de tres sobre el fee.
        sum(i.financed_usd)                                                as my_financed_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'paid'), 0)     as paid_usd,
        coalesce(sum(i.amount_usd) filter (where i.status = 'pending'), 0)  as pending_usd,
        jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'sequence', i.sequence,
            'amount_usd', i.amount_usd,
            'due_date', i.due_date,
            'status', i.status,
            'paid_at', i.paid_at
          ) order by i.sequence
        ) as installments
      from public.installments i
      where i.charge_id = c.id and i.user_id = v_user
    ) mine on mine.my_usd is not null
    join lateral (
      select count(distinct i2.user_id) as people
      from public.installments i2
      where i2.charge_id = c.id
    ) split on true
    left join lateral (
      select jsonb_agg(
        jsonb_build_object(
          'name', ci.name,
          'quantity', ci.quantity,
          'unit_price_usd', ci.unit_price_usd,
          'line_total_usd', ci.line_total_usd
        ) order by ci.position, ci.created_at
      ) as lines
      from public.charge_items ci
      where ci.charge_id = c.id
    ) items on true
    order by c.confirmed_at desc
    limit p_limit
  ) q;

  return v_rows;
end;
$fn$;

revoke all on function public.my_purchases(integer) from public, anon;
grant execute on function public.my_purchases(integer) to authenticated;

-- ── 2. El recibo de una cuenta ─────────────────────────────────────────────

create or replace function public.charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user     uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_payers   integer;
  v_allowed  boolean;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found or v_charge.status <> 'confirmed' then
    raise exception 'Cuenta no encontrada' using errcode = 'P0002';
  end if;

  -- Participante, integrante del grupo (presente o pasado), o quien la pagó.
  v_allowed :=
    exists (select 1 from public.installments i
            where i.charge_id = v_charge.id and i.user_id = v_user)
    or (v_charge.group_id is not null and exists (
          select 1 from public.group_members m
          where m.group_id = v_charge.group_id and m.user_id = v_user))
    or v_charge.user_id = v_user;

  if not v_allowed then
    raise exception 'No puedes ver esta cuenta' using errcode = '42501';
  end if;

  select count(distinct i.user_id) into v_payers
  from public.installments i where i.charge_id = v_charge.id;

  return jsonb_build_object(
    'charge_id',            v_charge.id,
    'order_number',         v_charge.order_number,
    'merchant_name',        (select m.name from public.merchants m where m.id = v_charge.merchant_id),
    'merchant_logo_url',    (select m.logo_url from public.merchants m where m.id = v_charge.merchant_id),
    'merchant_tax_id',      (select m.tax_id from public.merchants m where m.id = v_charge.merchant_id),
    'business_date',        v_charge.business_date,
    'confirmed_at',         v_charge.confirmed_at,
    'amount_usd',           v_charge.amount_usd,
    'financed_usd',         coalesce(v_charge.base_usd, v_charge.amount_usd),
    'consumer_fee_usd',     coalesce(v_charge.consumer_fee_usd, 0),
    'consumer_fee_vat_usd', coalesce(v_charge.consumer_fee_vat_usd, 0),
    'group_id',             v_charge.group_id,
    -- La copia manda sobre el join vivo, como en `my_purchases`: el nombre
    -- que tenía el grupo esa noche.
    'group_name',           coalesce(v_charge.group_name,
                              (select g.name from public.groups g where g.id = v_charge.group_id)),
    'started_by',           (select p.full_name from public.profiles p where p.id = v_charge.user_id),
    'started_by_me',        v_charge.user_id = v_user,
    'split_between',        greatest(v_payers, 1),
    'my_share_usd', (
      select sum(i.amount_usd) from public.installments i
      where i.charge_id = v_charge.id and i.user_id = v_user
    ),
    -- NUEVO: mi parte en CUPO, que es la que el recibo enseña como consumo.
    'my_financed_usd', (
      select sum(i.financed_usd) from public.installments i
      where i.charge_id = v_charge.id and i.user_id = v_user
    ),
    'my_installments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id',         i.id,
               'sequence',   i.sequence,
               'amount_usd', i.amount_usd,
               'due_date',   i.due_date,
               'status',     i.status
             ) order by i.sequence), '[]'::jsonb)
      from public.installments i
      where i.charge_id = v_charge.id and i.user_id = v_user
    ),
    /**
     * Quién pagó qué. La unión de los que tienen cuotas y, si es de grupo,
     * los que están en el grupo y no participaron — con su motivo si consta.
     * Ordenados por `user_id` para que la tinta por persona (app) coincida
     * con la del detalle del grupo.
     */
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id',   x.user_id,
               'name',      pr.full_name,
               'is_me',     x.user_id = v_user,
               'share_usd', x.share_usd,
               -- NUEVO: lo que esa persona puso EN CUPO. Es lo que hace que
               -- las filas de "quién pagó qué" sumen la cuenta del local.
               'financed_usd', x.financed_usd,
               'reason',    case
                              when x.share_usd is not null then null
                              when coalesce(v_charge.base_usd, v_charge.amount_usd) <
                                   (v_payers + 1) * public.min_share_usd()
                                then 'too_small'
                              else null
                            end
             ) order by x.user_id), '[]'::jsonb)
      from (
        select i.user_id, sum(i.amount_usd) as share_usd,
               sum(i.financed_usd) as financed_usd
        from public.installments i
        where i.charge_id = v_charge.id
        group by i.user_id
        union all
        select m.user_id, null::numeric, null::numeric
        from public.group_members m
        where v_charge.group_id is not null
          and m.group_id = v_charge.group_id
          and m.left_at is null
          and not exists (select 1 from public.installments i2
                          where i2.charge_id = v_charge.id and i2.user_id = m.user_id)
      ) x
      join public.profiles pr on pr.id = x.user_id
    ),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'name',           ci.name,
               'quantity',       ci.quantity,
               'unit_price_usd', ci.unit_price_usd,
               'line_total_usd', ci.line_total_usd
             ) order by ci.position, ci.created_at), '[]'::jsonb)
      from public.charge_items ci
      where ci.charge_id = v_charge.id
    )
  );
end;
$$;

revoke all on function public.charge_detail(uuid) from public, anon;
grant execute on function public.charge_detail(uuid) to authenticated;

-- ── 3. Las cuentas de un grupo ─────────────────────────────────────────────

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
               -- NUEVO: la cuenta del local, sin el servicio. Es la cifra que
               -- la fila enseña como total, igual que en el resto de la app.
               'financed_usd', coalesce(c.base_usd, c.amount_usd),
               'confirmed_at', c.confirmed_at,
               'started_by',  pr.full_name,
               'my_share_usd', mine.total,
               'my_financed_usd', mine.financed,
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
        select sum(i.amount_usd) as total, sum(i.financed_usd) as financed
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

-- ── 4. Lo que asumes al entrar a un grupo ──────────────────────────────────

create or replace function public.helios_group_join_plan(p_group_id uuid, p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_avail       numeric(18,4) := public.available_usd(p_user);
  v_assigned    numeric(18,4) := 0;
  v_payable     numeric(18,4) := 0;
  v_count       integer := 0;
  v_skipped     integer := 0;
  v_skipped_usd numeric(18,4) := 0;
  v_row         record;
  v_deb         record;
  v_parts       jsonb;
  v_split       jsonb;
  v_mine        numeric(18,4);
  v_mine_pay    numeric(18,4);
  v_n           integer;
  v_charges     jsonb := '[]'::jsonb;
  v_merchant    text;
begin
  for v_row in select * from public.helios_group_open_charges(p_group_id, p_user) loop
    v_parts := '[]'::jsonb;
    v_n     := 0;

    -- El nombre del local, que es por lo que la mesa reconoce una cuenta. Un
    -- `order_number` no le dice nada a nadie de pie en una barra.
    select m.name into v_merchant
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    where c.id = v_row.charge_id;

    -- La capacidad de quien ya debía es su parte actual. Ver la cabecera de
    -- 20260903000000: da el mismo reparto que volver a mirarle el saldo y hace
    -- imposible generarle deuda a alguien que no está delante del teléfono.
    for v_deb in select * from public.charge_debtors(v_row.charge_id) loop
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_deb.user_id, 'capacity_usd', v_deb.financed_usd
      );
      v_n := v_n + 1;
    end loop;

    v_parts := v_parts || jsonb_build_object(
      'user_id', p_user, 'capacity_usd', greatest(v_avail - v_assigned, 0)
    );

    -- El céntimo suelto es de quien puso ESTA cuenta, no de quien entra.
    v_split := public.helios_split_shares(v_row.base_usd, v_parts, v_row.payer_id);

    /**
     * ESTA CUENTA NO DA PARA UNO MÁS. Se salta, no se bloquea.
     *
     * `too_small` significa exactamente eso y solo eso: el total no llega a
     * `(deudores + 1) × $2,50`. No puede venir de los deudores viejos —sus
     * partes ya cumplen el mínimo, por construcción— así que el que sobra es
     * siempre el que quiere entrar.
     *
     * Se comprueba ANTES que `ok`, porque `reason` solo viene cuando falló.
     */
    if v_split->>'reason' = 'too_small' then
      v_skipped     := v_skipped + 1;
      v_skipped_usd := v_skipped_usd + v_row.amount_usd;
      v_charges     := v_charges || jsonb_build_object(
        'charge_id',    v_row.charge_id,
        'merchant_name', coalesce(v_merchant, 'Un local'),
        'amount_usd',   v_row.amount_usd,
        'financed_usd', v_row.base_usd,
        'my_payable_usd', null::numeric,
        'skipped',      true
      );
      continue;
    end if;

    if not coalesce((v_split->>'ok')::boolean, false) then
      return jsonb_build_object(
        'ok', false,
        'reason', 'no_capacity',
        'blocking_amount_usd', v_row.amount_usd,
        'blocking_split_between', v_n + 1
      );
    end if;

    select (s->>'share_usd')::numeric into v_mine
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = p_user;

    -- Se quedó fuera de ESTA cuenta por no llegar al mínimo con lo que le
    -- queda. Entrar sería entrar a medias, así que no entra.
    if v_mine is null then
      return jsonb_build_object(
        'ok', false,
        'reason', 'no_capacity',
        'blocking_amount_usd', v_row.amount_usd,
        'blocking_split_between', v_n + 1
      );
    end if;

    v_mine_pay := coalesce(
      (public.helios_payables(v_split->'shares', v_row.base_usd, v_row.amount_usd,
                             v_row.payer_id)
        ->>p_user::text)::numeric, 0);

    v_assigned := v_assigned + v_mine;
    v_payable  := v_payable + v_mine_pay;
    v_count    := v_count + 1;

    -- Lo que se paga, no lo que se financia: es la cifra que aparece en las
    -- cuotas, y por tanto la única que se puede comprobar después. Las dos
    -- difieren en el fee del servicio (20260830190000).
    v_charges := v_charges || jsonb_build_object(
      'charge_id',    v_row.charge_id,
      'merchant_name', coalesce(v_merchant, 'Un local'),
      'amount_usd',   v_row.amount_usd,
      'financed_usd', v_row.base_usd,
      'my_payable_usd', v_mine_pay,
      'skipped',      false
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'charge_count', v_count,
    'financed_usd', v_assigned,
    'payable_usd', v_payable,
    -- Las que se quedaron fuera por pequeñas. La pantalla de entrada las dice:
    -- quien entra tiene derecho a saber de qué NO va a ser parte.
    'skipped_charge_count', v_skipped,
    'skipped_usd', v_skipped_usd,
    -- NUEVO: el desglose, en orden de consumo y con las saltadas dentro.
    'charges', v_charges
  );
end;
$$;

revoke all on function public.helios_group_join_plan(uuid, uuid)
  from public, anon, authenticated;
