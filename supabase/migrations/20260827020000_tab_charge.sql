-- ============================================================================
-- Ronda — Cobrar a la mesa
--
-- El gemelo de `confirm_charge_as_group`, con tres diferencias que son todo el
-- cambio de modelo:
--
--   1. No hay retención que consumir. La capacidad de cada quien se calcula en
--      el momento: `min(techo − gastado, saldo disponible)`.
--   2. El reparto es en cascada (`helios_split_shares`), no a partes iguales.
--   3. Nadie queda fuera por elección de nadie. Fuera quedan, y lo decide el
--      servidor solo, quien tiene una cuota vencida y quien no llega al mínimo
--      por persona.
--
-- Lo que NO cambia: una deuda independiente por persona contra su propio
-- límite, dos cuotas por deuda, el asiento contable y el adelanto al comercio.
-- ============================================================================

/**
 * Quiénes hay en la mesa y con cuánta capacidad, en el orden del reparto.
 *
 * Sale como función propia porque la usan los dos lados —el preview que se
 * enseña antes del PIN y el cobro que escribe— y tienen que ver EXACTAMENTE lo
 * mismo. Si el preview y el cobro calcularan la capacidad por separado, el
 * usuario aprobaría un reparto y se le cobraría otro.
 *
 * El orden por `user_id` es el mismo que usa `helios_split_shares` para repartir
 * los céntimos sobrantes: fijarlo aquí es lo que hace el reparto reproducible.
 */
create or replace function public.tab_participants(p_tab_id uuid)
returns table (
  user_id       uuid,
  name          text,
  cap_usd       numeric,
  spent_usd     numeric,
  capacity_usd  numeric,
  can_take_debt boolean
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    m.user_id,
    p.full_name,
    m.cap_usd,
    m.spent_usd,
    greatest(least(m.cap_usd - m.spent_usd, public.available_usd(m.user_id)), 0),
    public.can_take_debt(m.user_id)
  from public.tab_members m
  join public.profiles p on p.id = m.user_id
  where m.tab_id = p_tab_id and m.left_at is null
  order by m.user_id;
$$;

revoke all on function public.tab_participants(uuid) from public, anon, authenticated;

/**
 * El reparto que se va a hacer, tal cual, ANTES de pedir el PIN.
 *
 * Devuelve el desglose completo: quién pone cuánto, con qué techo y cuánto le
 * queda. Quien va a pagar lo ve entero — es la decisión del 2026-08-27, y es
 * también lo que hace que absorber la parte de otro sea una cosa que se ve y
 * no una que se descubre en el estado de cuenta.
 *
 * `even_share_usd` va aparte a propósito: es lo que habría tocado a partes
 * iguales, y sin esa cifra al lado no hay forma de leer que tu parte subió
 * porque alguien no llegaba.
 *
 * No lanza: devuelve el motivo. Una pantalla tiene que poder maquetar
 * "esta cuenta es muy chica para dividirla entre 5", y un error de PostgREST
 * no se maqueta.
 */
create or replace function public.preview_tab_charge(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user    uuid := auth.uid();
  v_tab_id  uuid;
  v_tab     public.tabs%rowtype;
  v_charge  public.charges%rowtype;
  v_parts   jsonb := '[]'::jsonb;
  v_split   jsonb;
  v_rows    jsonb := '[]'::jsonb;
  v_row     record;
  v_shares  jsonb;
  v_share   numeric(18,4);
  v_my      numeric(18,4) := 0;
  v_eligible integer := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_tab_id := public.my_open_tab_id();
  if v_tab_id is null then
    return jsonb_build_object('ok', false, 'reason', 'no_tab');
  end if;

  select * into v_tab from public.tabs where id = v_tab_id;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  -- Quiénes pueden entrar en el reparto. `can_take_debt` es la única
  -- exclusión automática y no la decide nadie de la mesa.
  for v_row in select * from public.tab_participants(v_tab_id) loop
    if v_row.can_take_debt then
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_row.user_id, 'capacity_usd', v_row.capacity_usd
      );
      if v_row.capacity_usd >= public.min_share_usd() then
        v_eligible := v_eligible + 1;
      end if;
    end if;
  end loop;

  v_split := public.helios_split_shares(v_charge.amount_usd, v_parts);
  v_shares := coalesce(v_split->'shares', '[]'::jsonb);

  -- El desglose, integrante a integrante, con su parte ya asignada.
  for v_row in select * from public.tab_participants(v_tab_id) loop
    select (s->>'share_usd')::numeric into v_share
    from jsonb_array_elements(v_shares) s
    where (s->>'user_id')::uuid = v_row.user_id;

    if v_row.user_id = v_user then
      v_my := coalesce(v_share, 0);
    end if;

    v_rows := v_rows || jsonb_build_object(
      'user_id',      v_row.user_id,
      'name',         v_row.name,
      'is_me',        v_row.user_id = v_user,
      'cap_usd',      v_row.cap_usd,
      'spent_usd',    v_row.spent_usd,
      'capacity_usd', v_row.capacity_usd,
      'share_usd',    v_share,
      'participates', v_share is not null,
      'at_cap',       coalesce((
        select (s->>'at_cap')::boolean from jsonb_array_elements(v_shares) s
        where (s->>'user_id')::uuid = v_row.user_id
      ), false),
      'blocked_reason', case
        when not v_row.can_take_debt then 'overdue'
        when v_row.capacity_usd < public.min_share_usd() then 'no_capacity'
        else null
      end
    );
  end loop;

  return jsonb_build_object(
    'ok',            coalesce((v_split->>'ok')::boolean, false),
    'reason',        v_split->>'reason',
    'tab_id',        v_tab_id,
    'closes_at',     public.helios_business_day_end(v_tab.business_date),
    'amount_usd',    v_charge.amount_usd,
    'split_between', v_split->'split_between',
    'capacity_usd',  v_split->'capacity_usd',
    'min_total_usd', v_split->'min_total_usd',
    -- Lo que habría tocado a partes iguales. La referencia contra la que se
    -- lee el reparto en cascada.
    'even_share_usd', case when v_eligible > 0
      then round(v_charge.amount_usd / v_eligible, 2) else null end,
    'my_share_usd',  v_my,
    'members',       v_rows
  );
end;
$$;

revoke all on function public.preview_tab_charge(uuid) from public, anon;
grant execute on function public.preview_tab_charge(uuid) to authenticated;

/**
 * Cobrar y repartir. Exige PIN.
 *
 * El PIN va lo PRIMERO y se devuelve fallido en vez de lanzarse: un `raise`
 * revertiría el intento recién anotado y convertiría el cobro en un oráculo
 * para probar PINes sin rastro (ver 20260824170000_pin_to_pay).
 *
 * El reparto se recalcula AQUÍ, dentro de la transacción y con las filas
 * bloqueadas. Lo que enseñó el preview no se acepta como entrada: entre mirar
 * y confirmar puede haber entrado alguien, haberse ido otro o haberse gastado
 * un saldo en otra barra.
 */
create or replace function public.confirm_charge_as_tab(
  p_charge_id       uuid,
  p_idempotency_key text,
  p_pin             text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_tab_id  uuid;
  v_terms   public.merchant_settlement_terms%rowtype;
  v_parts   jsonb := '[]'::jsonb;
  v_split   jsonb;
  v_shares  jsonb;
  v_row     record;
  v_share   numeric(18,4);
  v_my      numeric(18,4) := 0;
  v_count   integer;
  v_bdate   date;
  v_due_1   date;
  v_due_2   date;
  v_tx      uuid;
  v_acct_pay uuid;
  v_acct_rev uuid;
  v_upfront  numeric(18,4);
  v_revenue  numeric(18,4);
  v_merchant_share numeric(18,4);
  v_confirmed_at   timestamptz;
  v_block   public.user_credit_blocks%rowtype;
  v_limit   numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    return jsonb_build_object(
      'ok', true, 'charge_id', v_charge.id, 'already_confirmed', true,
      'confirmed_at', v_charge.confirmed_at
    );
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status
      using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo'
      using errcode = '22023';
  end if;

  v_tab_id := public.my_open_tab_id();
  if v_tab_id is null then
    raise exception 'No estás compartiendo gastos ahora mismo' using errcode = '22023';
  end if;

  -- Se bloquean las filas de la mesa antes de leer capacidades: dos cobros
  -- simultáneos en la misma mesa no pueden repartir cada uno sobre el mismo
  -- techo sin verse.
  perform 1 from public.tab_members
  where tab_id = v_tab_id and left_at is null
  order by user_id
  for update;

  for v_row in select * from public.tab_participants(v_tab_id) loop
    if v_row.can_take_debt then
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_row.user_id, 'capacity_usd', v_row.capacity_usd
      );
    end if;
  end loop;

  v_split := public.helios_split_shares(v_charge.amount_usd, v_parts);

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Entre % la cuenta mínima es $% y esta es de $%',
        v_split->>'split_between', v_split->>'min_total_usd', v_charge.amount_usd
        using errcode = '22023';
    else
      raise exception 'La mesa llega a $% y la cuenta es de $%',
        v_split->>'capacity_usd', v_charge.amount_usd
        using errcode = '22023';
    end if;
  end if;

  v_shares := v_split->'shares';
  v_count  := (v_split->>'split_between')::integer;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2
  from public.helios_installment_due_dates(v_bdate);

  v_acct_pay := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev := ledger.get_or_create_account('platform_revenue', null);

  v_revenue        := round(v_charge.amount_usd * v_terms.commission_pct / 100, 4);
  v_merchant_share := v_charge.amount_usd - v_revenue;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id,
          format('Venta repartida en mesa entre %s personas', v_count))
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, 0, v_merchant_share),
    (v_tx, v_acct_rev, 0, v_revenue);

  -- --- Una deuda por integrante, contra su propio límite -------------------
  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(v_shares) s
    order by 1
  loop
    v_share := v_row.share;
    if v_row.user_id = v_user then v_my := v_share; end if;

    select monthly_limit_usd into v_limit
    from public.levels l
    join public.profiles p on p.level = l.level
    where p.id = v_row.user_id;

    select * into v_block
    from public.user_credit_blocks
    where user_id = v_row.user_id and closed_at is null
    for update;

    if not found then
      insert into public.user_credit_blocks (user_id) values (v_row.user_id)
      returning * into v_block;
    end if;

    -- El límite del nivel es el tope duro y va por encima de cualquier techo
    -- de mesa. La capacidad ya lo respeta; esto es el cinturón.
    if v_block.charged_usd + v_share > v_limit then
      raise exception 'Alguien de la mesa ya no tiene límite para $%', v_share
        using errcode = '22023';
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), v_share, 0);

    insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
      (v_charge.id, v_row.user_id, 1, round(v_share / 2, 4), v_due_1),
      (v_charge.id, v_row.user_id, 2, v_share - round(v_share / 2, 4), v_due_2);

    -- El techo es acumulativo por la noche: aquí es donde se gasta.
    update public.tab_members
      set spent_usd = spent_usd + v_share
    where tab_id = v_tab_id and user_id = v_row.user_id;

    update public.user_credit_blocks
      set charged_usd = charged_usd + v_share
    where id = v_block.id;
  end loop;

  v_upfront := round(v_charge.amount_usd * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  update public.charges
    set status = 'confirmed', user_id = v_user, tab_id = v_tab_id,
        business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id
  returning confirmed_at into v_confirmed_at;

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'split_between', v_count,
    'share_usd', v_my,
    'even_share_usd', round(v_charge.amount_usd / v_count, 2),
    'due_1', v_due_1,
    'due_2', v_due_2,
    'confirmed_at', v_confirmed_at
  );
end;
$$;

revoke all on function public.confirm_charge_as_tab(uuid, text, text) from public, anon;
grant execute on function public.confirm_charge_as_tab(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- El aviso, que es el control
-- ---------------------------------------------------------------------------
/**
 * Push a cada integrante con su parte.
 *
 * Es la baranda de docs/05 §2 punto 2: con la autorización dada al entrar, el
 * aviso instantáneo es lo único que te dice que acaba de nacerte una deuda.
 *
 * Y lleva una frase que el modelo de grupo no necesitaba: **cuando tu parte
 * sale por encima de lo parejo, dice por qué**. Con el techo por defecto
 * puesto al saldo entero, absorber lo de quien no llegaba es el caso normal,
 * no el raro; enterarse sin explicación sería la peor forma de descubrirlo.
 */
create or replace function public.notify_tab_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant text;
  v_who      text;
  v_count    integer;
  v_even     numeric(18,4);
  v_member   record;
  v_extra    text;
begin
  if new.status <> 'confirmed' or old.status = 'confirmed' or new.tab_id is null then
    return null;
  end if;

  select m.name into v_merchant from public.merchants m where m.id = new.merchant_id;
  select coalesce(p.full_name, 'Alguien') into v_who
  from public.profiles p where p.id = new.user_id;

  select count(distinct i.user_id) into v_count
  from public.installments i where i.charge_id = new.id;

  v_even := round(new.amount_usd / greatest(v_count, 1), 2);

  for v_member in
    select i.user_id, sum(i.amount_usd) as total
    from public.installments i
    where i.charge_id = new.id and i.user_id <> new.user_id
    group by i.user_id
  loop
    -- Un céntimo por encima de lo parejo es redondeo, no absorción. El umbral
    -- evita convertir el reparto de céntimos en un aviso alarmante.
    v_extra := case
      when v_member.total > v_even + 0.05
        then format(' Te tocó más de lo parejo ($%s) porque a alguien no le llegaba el techo.',
                    trim(to_char(v_even, 'FM999999990.00')))
      else ''
    end;

    perform public.notify(
      v_member.user_id,
      'tab_charge',
      format('%s pagó en %s', v_who, v_merchant),
      format('Te tocaron $%s de una cuenta de $%s entre %s.%s Se paga en dos cuotas.',
             trim(to_char(v_member.total, 'FM999999990.00')),
             trim(to_char(new.amount_usd, 'FM999999990.00')),
             v_count, v_extra),
      jsonb_build_object(
        'charge_id', new.id,
        'tab_id', new.tab_id,
        'amount_usd', v_member.total,
        'initiated_by', new.user_id
      )
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_tab_charge() from public, anon, authenticated;

drop trigger if exists charges_notify_tab on public.charges;
create trigger charges_notify_tab
  after update on public.charges
  for each row execute function public.notify_tab_charge();

/**
 * Aviso al resto de la mesa cuando entra alguien.
 *
 * Sin esto, quien está en la mesa no tiene forma de saber que el reparto
 * cambió — y el reparto es lo que determina cuánto va a pagar en la próxima
 * ronda. Es información suya, no del que entra.
 */
create or replace function public.notify_tab_joined()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name   text;
  v_member record;
  v_count  integer;
begin
  -- Solo al entrar de verdad: un `update` que solo mueve el techo no avisa.
  if tg_op = 'UPDATE' and old.left_at is null then
    return null;
  end if;

  select coalesce(p.full_name, 'Alguien') into v_name
  from public.profiles p where p.id = new.user_id;

  select count(*) into v_count from public.tab_members
  where tab_id = new.tab_id and left_at is null;

  for v_member in
    select user_id from public.tab_members
    where tab_id = new.tab_id and left_at is null and user_id <> new.user_id
  loop
    perform public.notify(
      v_member.user_id,
      'tab_joined',
      format('%s entró a la mesa', v_name),
      format('Ya son %s. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.',
             v_count),
      jsonb_build_object('tab_id', new.tab_id, 'user_id', new.user_id)
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_tab_joined() from public, anon, authenticated;

drop trigger if exists tab_members_notify_joined on public.tab_members;
create trigger tab_members_notify_joined
  after insert or update on public.tab_members
  for each row execute function public.notify_tab_joined();
