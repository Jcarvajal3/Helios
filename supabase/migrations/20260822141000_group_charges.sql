-- ============================================================================
-- Ronda — Cobrar a un grupo
--
-- El comercio hace UNA venta y se le liquida UNA vez. Lo que se reparte es la
-- cuenta por cobrar: cada integrante queda con su propia deuda y su propio
-- plan de dos cuotas, contra su propio límite (docs/05 §2).
--
-- Asiento de una venta de $80 repartida entre 4:
--
--     Dr user_receivable(A)  20
--     Dr user_receivable(B)  20
--     Dr user_receivable(C)  20
--     Dr user_receivable(D)  20
--     Cr merchant_payable    64   (80%)
--     Cr platform_revenue    16   (20%)
--
-- docs/00-BASES §3.6 pone el listón: "si un miembro no tiene saldo, ¿el
-- cajero se queda esperando mientras 8 personas discuten? El flujo tiene que
-- resolverlo en 5 segundos o no sirve". Por eso `preview_group_charge`
-- devuelve de una sola vez quién puede y quién no, con el motivo — para que
-- la app enseñe la lista y quien inicia decida sin más idas al servidor.
-- ============================================================================

/**
 * Quién podría pagar y quién no, si este cobro se reparte en este grupo.
 *
 * No cambia nada: solo informa. Se llama nada más escanear, así que la
 * pantalla ya sabe el reparto antes de que nadie toque un botón.
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
  v_charge   public.charges%rowtype;
  v_group    public.groups%rowtype;
  v_members  integer;
  v_share    numeric(18,4);
  v_rows     jsonb;
  v_can      integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  select * into v_group from public.groups where id = p_group_id and status = 'active';
  if not found then
    raise exception 'Grupo no encontrado' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = v_user
      and status = 'active' and can_initiate
  ) then
    raise exception 'No puedes iniciar cobros en este grupo' using errcode = '42501';
  end if;

  select count(*) into v_members
  from public.group_members
  where group_id = p_group_id and status = 'active';

  if v_members = 0 then
    raise exception 'El grupo no tiene integrantes activos' using errcode = '22023';
  end if;

  -- Reparto a partes iguales. El último céntimo se ajusta al confirmar.
  v_share := round(v_charge.amount_usd / v_members, 4);

  select coalesce(jsonb_agg(to_jsonb(q) order by q.name), '[]'::jsonb), count(*) filter (where q.can_pay)
    into v_rows, v_can
  from (
    select
      m.user_id,
      p.full_name                        as name,
      v_share                            as share_usd,
      m.max_per_transaction_usd,
      coalesce(l.monthly_limit_usd, 0)
        - coalesce(b.charged_usd, 0)     as available_usd,
      -- Tres razones posibles para no poder, en el orden en que le importan
      -- a quien mira la pantalla.
      case
        when p.status <> 'active'                                then 'cuenta_bloqueada'
        when v_share > m.max_per_transaction_usd                 then 'supera_su_tope'
        when v_share > coalesce(l.monthly_limit_usd, 0)
                       - coalesce(b.charged_usd, 0)              then 'sin_saldo'
        when v_share < 2.50                                      then 'bajo_el_minimo'
        else null
      end                                as blocked_reason,
      (
        p.status = 'active'
        and v_share <= m.max_per_transaction_usd
        and v_share <= coalesce(l.monthly_limit_usd, 0) - coalesce(b.charged_usd, 0)
        and v_share >= 2.50
      )                                  as can_pay
    from public.group_members m
    join public.profiles p on p.id = m.user_id
    left join public.levels l on l.level = p.level
    left join public.user_credit_blocks b
      on b.user_id = m.user_id and b.closed_at is null
    where m.group_id = p_group_id and m.status = 'active'
  ) q;

  return jsonb_build_object(
    'charge_id', v_charge.id,
    'group_id', v_group.id,
    'group_name', v_group.name,
    'amount_usd', v_charge.amount_usd,
    'member_count', v_members,
    'share_usd', v_share,
    'can_pay_count', v_can,
    'everyone_can_pay', v_can = v_members,
    'members', v_rows
  );
end;
$$;

revoke all on function public.preview_group_charge(uuid, uuid) from public, anon;
grant execute on function public.preview_group_charge(uuid, uuid) to authenticated;

/**
 * Confirma el cobro repartiéndolo entre los integrantes indicados.
 *
 * `p_user_ids` permite excluir a quien viene corto: los demás asumen una
 * parte mayor, pero **siempre dentro de su propio tope y de su límite**. Si
 * alguno no llega, la operación entera se cae con el motivo — nunca se carga
 * a nadie por encima de lo que autorizó, que es la razón de que los topes
 * existan (docs/05 §2).
 */
create or replace function public.confirm_charge_as_group(
  p_charge_id       uuid,
  p_group_id        uuid,
  p_user_ids        uuid[],
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_charge    public.charges%rowtype;
  v_terms     public.merchant_settlement_terms%rowtype;
  v_count     integer;
  v_share     numeric(18,4);
  v_remainder numeric(18,4);
  v_bdate     date;
  v_due_1     date;
  v_due_2     date;
  v_tx        uuid;
  v_acct_pay  uuid;
  v_acct_rev  uuid;
  v_upfront   numeric(18,4);
  v_revenue   numeric(18,4);
  v_merchant_share numeric(18,4);
  v_member    record;
  v_amount    numeric(18,4);
  v_block     public.user_credit_blocks%rowtype;
  v_limit     numeric(18,4);
  v_i         integer := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_count := coalesce(array_length(p_user_ids, 1), 0);
  if v_count = 0 then
    raise exception 'Selecciona al menos una persona' using errcode = '22023';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'already_confirmed', true);
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.group_members
    where group_id = p_group_id and user_id = v_user
      and status = 'active' and can_initiate
  ) then
    raise exception 'No puedes iniciar cobros en este grupo' using errcode = '42501';
  end if;

  -- Todos los indicados tienen que ser integrantes activos del grupo.
  if (
    select count(*) from public.group_members
    where group_id = p_group_id and user_id = any(p_user_ids) and status = 'active'
  ) <> v_count then
    raise exception 'Alguien de la lista no es integrante activo del grupo'
      using errcode = '22023';
  end if;

  v_share := round(v_charge.amount_usd / v_count, 4);
  -- El céntimo que sobra del reparto lo asume quien inicia el cobro: es quien
  -- está delante del cajero y quien decidió el reparto.
  v_remainder := v_charge.amount_usd - (v_share * v_count);

  if v_share < 2.50 then
    raise exception 'La parte de cada quien quedaría en $%, y el mínimo es $2,50', v_share
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_acct_pay := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev := ledger.get_or_create_account('platform_revenue', null);

  v_revenue := round(v_charge.amount_usd * v_terms.commission_pct / 100, 4);
  v_merchant_share := v_charge.amount_usd - v_revenue;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id,
          format('Venta repartida entre %s personas', v_count))
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, 0, v_merchant_share),
    (v_tx, v_acct_rev, 0, v_revenue);

  -- --- Una deuda por integrante -----------------------------------------
  for v_member in
    select m.user_id, m.max_per_transaction_usd, p.status as profile_status, p.full_name
    from public.group_members m
    join public.profiles p on p.id = m.user_id
    where m.group_id = p_group_id and m.user_id = any(p_user_ids) and m.status = 'active'
    order by m.user_id
    for update of m
  loop
    v_i := v_i + 1;
    -- El primero de la lista carga con el céntimo sobrante si lo hay; se
    -- ordena por user_id para que el reparto sea determinista.
    v_amount := v_share + (case when v_i = 1 then v_remainder else 0 end);

    if v_member.profile_status <> 'active' then
      raise exception 'La cuenta de % está bloqueada', coalesce(v_member.full_name, 'un integrante')
        using errcode = '22023';
    end if;

    if v_amount > v_member.max_per_transaction_usd then
      raise exception 'A % le tocarían $% y su tope en este grupo es $%',
        coalesce(v_member.full_name, 'un integrante'), v_amount, v_member.max_per_transaction_usd
        using errcode = '22023';
    end if;

    select monthly_limit_usd into v_limit
    from public.levels l
    join public.profiles p on p.level = l.level
    where p.id = v_member.user_id;

    select * into v_block
    from public.user_credit_blocks
    where user_id = v_member.user_id and closed_at is null
    for update;

    if not found then
      insert into public.user_credit_blocks (user_id) values (v_member.user_id)
      returning * into v_block;
    end if;

    if v_block.charged_usd + v_amount > v_limit then
      raise exception 'A % no le alcanza el saldo: le tocarían $% y tiene $%',
        coalesce(v_member.full_name, 'un integrante'), v_amount,
        (v_limit - v_block.charged_usd)
        using errcode = '22023';
    end if;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_member.user_id), v_amount, 0);

    insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date) values
      (v_charge.id, v_member.user_id, 1, round(v_amount / 2, 4), v_due_1),
      (v_charge.id, v_member.user_id, 2, v_amount - round(v_amount / 2, 4), v_due_2);

    update public.user_credit_blocks
      set charged_usd = charged_usd + v_amount
    where id = v_block.id;
  end loop;

  -- --- Adelanto devengado al comercio (sin mover caja) -------------------
  v_upfront := round(v_charge.amount_usd * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  update public.charges
    set status = 'confirmed', user_id = v_user, group_id = p_group_id,
        business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id;

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'split_between', v_count,
    'share_usd', v_share,
    'due_1', v_due_1,
    'due_2', v_due_2
  );
end;
$$;

revoke all on function public.confirm_charge_as_group(uuid, uuid, uuid[], text) from public, anon;
grant execute on function public.confirm_charge_as_group(uuid, uuid, uuid[], text) to authenticated;
