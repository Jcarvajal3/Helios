-- ============================================================================
-- Ronda — Ver el grupo y cobrarle
--
-- Segunda mitad de la vuelta a los grupos (20260828000000). Aquella dejó el
-- grupo, los techos y el entrar/salir; esta pone lo que se mira y lo que
-- cobra.
--
-- `confirm_charge_as_group` y `claim_charge_share` van al final y están
-- GENERADAS a partir de sus gemelas de la mesa, que ya estaban probadas: solo
-- se sustituyó lo que hablaba de la mesa. Todo lo demás —el PIN devuelto en
-- vez de lanzado, la cascada, el asiento en tres patas, las cuotas, los
-- bloques de crédito, el adelanto al comercio— se conserva verbatim, que es
-- justo el motivo de generarlas en vez de transcribirlas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lo que se mira
-- ---------------------------------------------------------------------------
/**
 * Mis grupos de esta noche, con el estado de cada uno.
 *
 * Enseña las cifras de TODOS los integrantes, no solo las mías: quien va a
 * pagar tiene que poder ver con qué cuenta antes de poner el PIN, y un grupo
 * donde no sabes de cuánto dispones es justo la conversación que este producto
 * viene a quitar de la barra. Entrar al grupo es aceptar también eso, y la
 * pantalla de entrada lo dice antes.
 */
create or replace function public.my_groups()
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

  select coalesce(jsonb_agg(x order by x->>'created_at'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'group_id',    g.id,
      'name',        g.name,
      'invite_code', g.invite_code,
      'created_at',  g.created_at,
      'created_by_me', g.created_by = v_user,
      'closes_at',   public.helios_business_day_end(g.business_date),
      'members', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'user_id',       p.user_id,
                 'name',          p.name,
                 'is_me',         p.user_id = v_user,
                 'cap_usd',       p.cap_usd,
                 'spent_usd',     p.spent_usd,
                 'capacity_usd',  p.capacity_usd,
                 'can_take_debt', p.can_take_debt
               ) order by p.user_id), '[]'::jsonb)
        from public.group_participants(g.id) p
      ),
      'my_cap_usd',    mine.cap_usd,
      'my_spent_usd',  mine.spent_usd,
      'my_left_usd',   greatest(least(mine.cap_usd - mine.spent_usd,
                                      public.available_usd(v_user)), 0),
      'my_max_cap_usd', mine.spent_usd + public.available_usd(v_user),
      -- Lo que el grupo puede cubrir de una cuenta que se reparta parejo.
      'pot_usd',       public.group_pot_usd(g.id),
      -- N × $2,50: por debajo de eso la cuenta no se puede dividir entre
      -- tantos. Se dice ANTES de escanear; descubrirlo con el QR ya leído es
      -- enterarse de pie en la caja.
      'min_charge_usd', (select count(*) from public.group_participants(g.id)
                         where can_take_debt) * public.min_share_usd(),
      'min_share_usd', public.min_share_usd()
    ) as x
    from public.groups g
    join public.group_members mine
      on mine.group_id = g.id and mine.user_id = v_user and mine.left_at is null
    where g.business_date = v_bdate
  ) s;

  return v_rows;
end;
$$;

revoke all on function public.my_groups() from public, anon;
grant execute on function public.my_groups() to authenticated;

/**
 * Un grupo entero: integrantes, techos y lo que se ha gastado en él.
 *
 * SECURITY DEFINER igualmente para poder decir QUIÉN inició cada cobro: los
 * nombres de los perfiles no se leen por RLS fuera de lo que ya expone
 * `my_groups`.
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

  return jsonb_build_object(
    'group_id',    v_group.id,
    'name',        v_group.name,
    'invite_code', v_group.invite_code,
    'created_by_me', v_group.created_by = v_user,
    'closes_at',   public.helios_business_day_end(v_group.business_date),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id',       p.user_id,
               'name',          p.name,
               'is_me',         p.user_id = v_user,
               'cap_usd',       p.cap_usd,
               'spent_usd',     p.spent_usd,
               'capacity_usd',  p.capacity_usd,
               'can_take_debt', p.can_take_debt
             ) order by p.user_id), '[]'::jsonb)
      from public.group_participants(p_group_id) p
    ),
    'my_cap_usd',     v_mine.cap_usd,
    'my_spent_usd',   v_mine.spent_usd,
    'my_left_usd',    greatest(least(v_mine.cap_usd - v_mine.spent_usd, v_avail), 0),
    'my_max_cap_usd', v_mine.spent_usd + v_avail,
    'pot_usd',        public.group_pot_usd(p_group_id),
    'min_share_usd',  public.min_share_usd(),
    'charges', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'charge_id',   c.id,
               'merchant_name', mm.name,
               'amount_usd',  c.amount_usd,
               'confirmed_at', c.confirmed_at,
               'started_by',  pr.full_name,
               'my_share_usd', (select sum(i.amount_usd) from public.installments i
                                where i.charge_id = c.id and i.user_id = v_user)
             ) order by c.confirmed_at desc), '[]'::jsonb)
      from public.charges c
      join public.merchants mm on mm.id = c.merchant_id
      left join public.profiles pr on pr.id = c.user_id
      where c.group_id = p_group_id and c.status = 'confirmed'
    )
  );
end;
$$;

revoke all on function public.group_detail(uuid) from public, anon;
grant execute on function public.group_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El reparto, antes del PIN
-- ---------------------------------------------------------------------------
/**
 * El reparto que se va a hacer, tal cual.
 *
 * `even_share_usd` va aparte a propósito: es lo que habría tocado a partes
 * iguales, y sin esa cifra al lado no hay forma de leer que tu parte subió
 * porque a alguien no le llegaba el techo.
 *
 * No lanza: devuelve el motivo. Una pantalla tiene que poder maquetar "esta
 * cuenta es muy chica para dividirla entre 5", y un error de PostgREST no se
 * maqueta.
 */
create or replace function public.preview_group_charge(
  p_charge_id uuid,
  p_group_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user     uuid := auth.uid();
  v_group    public.groups%rowtype;
  v_charge   public.charges%rowtype;
  v_parts    jsonb := '[]'::jsonb;
  v_split    jsonb;
  v_rows     jsonb := '[]'::jsonb;
  v_row      record;
  v_shares   jsonb;
  v_share    numeric(18,4);
  v_my       numeric(18,4) := 0;
  v_eligible integer := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if not exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = v_user and left_at is null
  ) then
    raise exception 'No estás en este grupo' using errcode = '42501';
  end if;

  select * into v_group  from public.groups  where id = p_group_id;
  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  for v_row in select * from public.group_participants(p_group_id) loop
    if v_row.can_take_debt then
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_row.user_id, 'capacity_usd', v_row.capacity_usd
      );
      if v_row.capacity_usd >= public.min_share_usd() then
        v_eligible := v_eligible + 1;
      end if;
    end if;
  end loop;

  v_split  := public.helios_split_shares(v_charge.amount_usd, v_parts);
  v_shares := coalesce(v_split->'shares', '[]'::jsonb);

  for v_row in select * from public.group_participants(p_group_id) loop
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
    'group_id',      p_group_id,
    'group_name',    v_group.name,
    'closes_at',     public.helios_business_day_end(v_group.business_date),
    'amount_usd',    v_charge.amount_usd,
    'split_between', v_split->'split_between',
    'capacity_usd',  v_split->'capacity_usd',
    'min_total_usd', v_split->'min_total_usd',
    'even_share_usd', case when v_eligible > 0
      then round(v_charge.amount_usd / v_eligible, 2) else null end,
    'my_share_usd',  v_my,
    'members',       v_rows
  );
end;
$$;

revoke all on function public.preview_group_charge(uuid, uuid) from public, anon;
grant execute on function public.preview_group_charge(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La capacidad de quien se adjudica una parte después
-- ---------------------------------------------------------------------------
/**
 * Si además está en el grupo que pagó la cuenta, su techo sigue mandando: una
 * adjudicación posterior no es la puerta trasera para saltárselo.
 */
-- El parámetro pasa de `p_tab_id` a `p_group_id`, y `create or replace` no
-- deja renombrar parámetros: hay que soltarla antes.
drop function if exists public.claimant_capacity(uuid, uuid);

create or replace function public.claimant_capacity(p_user uuid, p_group_id uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select greatest(least(
    public.available_usd(p_user),
    coalesce(
      (select m.cap_usd - m.spent_usd
       from public.group_members m
       where m.group_id = p_group_id and m.user_id = p_user and m.left_at is null),
      public.available_usd(p_user)
    )
  ), 0);
$$;

revoke all on function public.claimant_capacity(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Los avisos
-- ---------------------------------------------------------------------------
/**
 * Push a cada integrante con su parte.
 *
 * Es la baranda de docs/05 §2: con la autorización dada al entrar, el aviso
 * instantáneo es lo único que te dice que acaba de nacerte una deuda. Y lleva
 * una frase que el modelo del ticket no necesitaba: **cuando tu parte sale por
 * encima de lo parejo, dice por qué**. Con techos propios, absorber lo de
 * quien no llegaba es el caso normal, no el raro.
 */
create or replace function public.notify_group_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group    text;
  v_merchant text;
  v_who      text;
  v_count    integer;
  v_even     numeric(18,4);
  v_member   record;
  v_extra    text;
begin
  if new.status <> 'confirmed' or old.status = 'confirmed' or new.group_id is null then
    return null;
  end if;

  select g.name into v_group from public.groups g where g.id = new.group_id;
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
      'group_charge',
      format('%s pagó en %s', v_who, v_merchant),
      format('Te tocaron $%s de una cuenta de $%s entre %s, en %s.%s Se paga en dos cuotas.',
             trim(to_char(v_member.total, 'FM999999990.00')),
             trim(to_char(new.amount_usd, 'FM999999990.00')),
             v_count, coalesce(v_group, 'tu grupo'), v_extra),
      jsonb_build_object(
        'charge_id', new.id,
        'group_id', new.group_id,
        'amount_usd', v_member.total,
        'initiated_by', new.user_id
      )
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_group_charge() from public, anon, authenticated;

drop trigger if exists charges_notify_group on public.charges;
create trigger charges_notify_group
  after update on public.charges
  for each row execute function public.notify_group_charge();

/**
 * Aviso al resto cuando entra alguien.
 *
 * Sin esto, quien está en el grupo no tiene forma de saber que el reparto
 * cambió — y el reparto determina cuánto va a pagar en la próxima ronda. Es
 * información suya, no del que entra.
 */
create or replace function public.notify_group_joined()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name   text;
  v_group  text;
  v_member record;
  v_count  integer;
begin
  -- Solo al entrar de verdad: un `update` que solo mueve el techo no avisa.
  if tg_op = 'UPDATE' and old.left_at is null then
    return null;
  end if;

  select coalesce(p.full_name, 'Alguien') into v_name
  from public.profiles p where p.id = new.user_id;
  select g.name into v_group from public.groups g where g.id = new.group_id;

  select count(*) into v_count from public.group_members
  where group_id = new.group_id and left_at is null;

  for v_member in
    select user_id from public.group_members
    where group_id = new.group_id and left_at is null and user_id <> new.user_id
  loop
    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s entró a %s', v_name, coalesce(v_group, 'tu grupo')),
      format('Ya son %s. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.',
             v_count),
      jsonb_build_object('group_id', new.group_id, 'user_id', new.user_id)
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_group_joined() from public, anon, authenticated;

drop trigger if exists group_members_notify_joined on public.group_members;
create trigger group_members_notify_joined
  after insert or update on public.group_members
  for each row execute function public.notify_group_joined();

-- ---------------------------------------------------------------------------
-- 5. El cobro y la adjudicación posterior — generadas, ver la cabecera
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.confirm_charge_as_group(p_charge_id uuid, p_group_id uuid, p_idempotency_key text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_group_id  uuid;
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

  v_group_id := p_group_id;

  if not exists (
    select 1 from public.group_members
    where group_id = v_group_id
      and user_id = v_user
      and left_at is null
      and business_date = public.helios_business_date(now())
  ) then
    raise exception 'No perteneces a este grupo' using errcode = '42501';
  end if;

  -- Se bloquean las filas del grupo antes de leer capacidades: dos cobros
  -- simultáneos en el mismo grupo no pueden repartir cada uno sobre el mismo
  -- techo sin verse.
  perform 1 from public.group_members
  where group_id = v_group_id and left_at is null
  order by user_id
  for update;

  for v_row in select * from public.group_participants(v_group_id) loop
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

  v_revenue        := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_merchant_share := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id,
          format('Venta repartida en mesa entre %s personas', v_count))
  returning id into v_tx;

  /**
   * Las cuatro patas de una vez, saltándose las que valen cero.
   *
   * El filtro no es cosmético: `ledger.entries` tiene un check
   * (`entries_one_side`) que rechaza un asiento con debe y haber en cero, y
   * hay dos casos reales que lo producen — un comercio con comisión 0, y un
   * cobro sin IVA (los anteriores a este modelo). Enumerar y filtrar cubre
   * los dos sin un `if` por pata.
   */
  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (v_acct_pay, 0::numeric, v_merchant_share),
    (v_acct_rev, 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_merchant_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

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
    update public.group_members
      set spent_usd = spent_usd + v_share
    where group_id = v_group_id and user_id = v_row.user_id;

    update public.user_credit_blocks
      set charged_usd = charged_usd + v_share
    where id = v_block.id;
  end loop;

  v_upfront := round(v_merchant_share * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  update public.charges
    set status = 'confirmed', user_id = v_user, group_id = v_group_id,
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
$function$
;

revoke all on function public.confirm_charge_as_group(uuid, uuid, text, text) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, text, text) to authenticated;

CREATE OR REPLACE FUNCTION public.claim_charge_share(p_token text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_parts   jsonb := '[]'::jsonb;
  v_split   jsonb;
  v_row     record;
  v_new     numeric(18,4);
  v_mine    numeric(18,4);
  v_delta   numeric(18,4);
  v_tx      uuid;
  v_due_1   date;
  v_due_2   date;
  v_half    numeric(18,4);
  v_block   public.user_credit_blocks%rowtype;
  v_limit   numeric(18,4);
  v_count   integer := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges
  where share_token = trim(p_token) for update;

  if not found then
    raise exception 'Ese código no corresponde a ninguna orden' using errcode = 'P0002';
  end if;

  if public.helios_business_day_end(v_charge.business_date) <= now() then
    raise exception 'Esta orden ya se cerró: solo se reparte durante la misma noche'
      using errcode = '22023';
  end if;

  if exists (select 1 from public.installments
             where charge_id = v_charge.id and user_id = v_user) then
    raise exception 'Ya tienes una parte de esta orden' using errcode = '22023';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes asumir deuda nueva' using errcode = '22023';
  end if;

  -- Se bloquean las cuotas de la orden antes de leerlas: dos personas
  -- escaneando el mismo QR a la vez no pueden repartir cada una sobre la foto
  -- vieja.
  perform 1 from public.installments
  where charge_id = v_charge.id order by user_id, sequence for update;

  for v_row in select * from public.charge_debtors(v_charge.id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.share_usd
    );
    v_count := v_count + 1;
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', v_user,
    'capacity_usd', public.claimant_capacity(v_user, v_charge.group_id)
  );

  v_split := public.helios_split_shares(v_charge.amount_usd, v_parts);

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Ya son % en esta cuenta de $%: entrar dejaría a alguien por debajo del mínimo',
        v_count, v_charge.amount_usd using errcode = '22023';
    else
      raise exception 'No te alcanza el saldo para tomar una parte de esta cuenta'
        using errcode = '22023';
    end if;
  end if;

  -- Las fechas del consumo, no las de hoy.
  select due_date into v_due_1 from public.installments
  where charge_id = v_charge.id and sequence = 1 limit 1;
  select due_date into v_due_2 from public.installments
  where charge_id = v_charge.id and sequence = 2 limit 1;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'claim:' || v_charge.id::text || ':' || v_user::text,
          v_charge.business_date, v_charge.id,
          format('Reparto posterior: entra 1 persona, ahora son %s',
                 (v_split->>'split_between')::integer))
  returning id into v_tx;

  -- --- A los que ya debían: se les baja ------------------------------------
  for v_row in select * from public.charge_debtors(v_charge.id) loop
    select (s->>'share_usd')::numeric into v_new
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = v_row.user_id;

    v_delta := v_row.share_usd - coalesce(v_new, v_row.share_usd);
    continue when v_delta <= 0;

    v_half := round(v_new / 2, 4);

    update public.installments set amount_usd = v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 1;
    update public.installments set amount_usd = v_new - v_half
    where charge_id = v_charge.id and user_id = v_row.user_id and sequence = 2;

    update public.user_credit_blocks
      set charged_usd = charged_usd - v_delta
    where user_id = v_row.user_id and closed_at is null;

    -- Si la orden salió de una mesa, el techo gastado también se libera.
    if v_charge.group_id is not null then
      update public.group_members
        set spent_usd = greatest(spent_usd - v_delta, 0)
      where group_id = v_charge.group_id and user_id = v_row.user_id;
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), 0, v_delta);

    perform public.notify(
      v_row.user_id,
      'group_charge',
      'Tu parte bajó',
      format('Alguien más entró en la cuenta de $%s. Tu parte pasó a $%s.',
             trim(to_char(v_charge.amount_usd, 'FM999999990.00')),
             trim(to_char(v_new, 'FM999999990.00'))),
      jsonb_build_object('charge_id', v_charge.id, 'amount_usd', v_new)
    );
  end loop;

  -- --- Al que entra: su deuda ----------------------------------------------
  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = v_user;

  select monthly_limit_usd into v_limit
  from public.levels l join public.profiles p on p.level = l.level
  where p.id = v_user;

  select * into v_block from public.user_credit_blocks
  where user_id = v_user and closed_at is null for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (v_user) returning * into v_block;
  end if;

  if v_block.charged_usd + v_mine > v_limit then
    raise exception 'Tu límite no cubre $%', v_mine using errcode = '22023';
  end if;

  v_half := round(v_mine / 2, 4);

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
    (v_charge.id, v_user, 1, v_half, v_due_1),
    (v_charge.id, v_user, 2, v_mine - v_half, v_due_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + v_mine
  where id = v_block.id;

  if v_charge.group_id is not null then
    update public.group_members
      set spent_usd = spent_usd + v_mine
    where group_id = v_charge.group_id and user_id = v_user and left_at is null;
  end if;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  values (v_tx, ledger.get_or_create_account('user_receivable', v_user), v_mine, 0);

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'share_usd', v_mine,
    'split_between', (v_split->>'split_between')::integer,
    'due_1', v_due_1,
    'due_2', v_due_2
  );
end;
$function$
;

revoke all on function public.claim_charge_share(text, text) from public, anon;
grant execute on function public.claim_charge_share(text, text) to authenticated;
