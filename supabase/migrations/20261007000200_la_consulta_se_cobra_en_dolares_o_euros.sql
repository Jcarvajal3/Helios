-- ============================================================================
-- Helios — La consulta se cobra en dólares o en euros (Javier, 2026-10-07)
--
-- En el paso del monto, el médico elige la moneda de su consulta: dólares
-- (USD) o euros (EUR). Decisión de Javier del 2026-10-07: **una orden en
-- euros queda en euros hasta que se paga**.
--
--   · El paciente paga cada cuota en bolívares, con la tasa BCV de la moneda
--     de su orden del día en que paga (€56,96 × tasa del euro de ese día).
--   · A la clínica se le paga en bolívares con la tasa BCV de esa moneda del
--     día de la transferencia (€50 × tasa del euro de ese día).
--   · Hacia dentro todo sigue en DÓLARES: el libro, el límite de $150, el
--     mínimo, la mora, las métricas y el superadmin. La orden en euros se
--     pasa a dólares con la tasa cruzada del BCV del día en que se registra
--     (`helios_usd_per_unit`) y esa conversión queda guardada en la orden.
--
-- Lo que hace esta migración:
--
-- 1. **Columnas.** `charges.currency` y `charges.fx_usd_per_unit` (dólares por
--    unidad el día del registro; 1 en las de dólares) y los montos en la
--    moneda de la orden: `base_cur`, `consumer_fee_cur`, `consumer_fee_vat_cur`,
--    `amount_cur`, `merchant_net_cur`. Las columnas `_usd` siguen siendo
--    dólares, literalmente. Las cuotas guardan `amount_cur` y `financed_cur`;
--    las liquidaciones a la clínica, `currency`, `amount_cur` y `paid_cur`; el
--    pago a la clínica, la parte en euros y su tasa. Todo lo de antes se
--    rellena como dólares: `_cur` = `_usd`.
--
-- 2. **El desglose en las dos monedas** (`helios_charge_amounts`): el de la
--    moneda de la orden, que es lo que se le enseña al paciente y a la
--    clínica, y el del libro, que sale de pasar la base a dólares y aplicarle
--    el mismo desglose. Así la comisión es exactamente el 12% en las dos.
--
-- 3. **Registrar**: `preview_patient_charge` y `create_patient_charge` (y los
--    `bot_*` del médico) aceptan `p_amount` y `p_currency`. El mínimo y lo
--    disponible se miden en dólares y se dicen en la moneda de la orden.
--    Reabrir una orden vencida (`staff_resend_confirmation`) la vuelve a pasar
--    a dólares con la tasa de ese día: el médico cobró €100 y siguen siendo
--    €100.
--
-- 4. **Las cuotas y las liquidaciones se ponen su moneda solas**, con un
--    trigger cada una: `helios_assign_debt` sigue siendo la única que crea
--    deuda y no cambia; la cuota toma su parte en la moneda de la orden (la
--    mitad de `amount_cur`, el resto en la segunda) y la liquidación, su parte
--    del neto de la clínica en esa moneda.
--
-- 5. **El pago a la clínica** (`admin_report_merchant_payout`) calcula los
--    bolívares por moneda: lo que va en dólares a la tasa del dólar y lo que va
--    en euros a la del euro, del día del pago.
--
-- 6. **Las lecturas** dicen la moneda: la clínica (`merchant_transactions`,
--    `merchant_charge_detail`, `helios_charge_for_staff`) ve sus montos en la
--    moneda en la que cobró; el superadmin sigue viendo dólares y, aparte, en
--    qué moneda se cobró (`admin_charge_detail`, `admin_user_detail`,
--    `admin_merchant_settlements`, `admin_merchant_payouts`,
--    `admin_payout_detail`).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas
-- ---------------------------------------------------------------------------

alter table public.charges
  add column if not exists currency            text          not null default 'USD',
  add column if not exists fx_usd_per_unit     numeric(18,6) not null default 1,
  add column if not exists base_cur            numeric(18,4),
  add column if not exists consumer_fee_cur    numeric(18,4),
  add column if not exists consumer_fee_vat_cur numeric(18,4),
  add column if not exists amount_cur          numeric(18,4),
  add column if not exists merchant_net_cur    numeric(18,4);

update public.charges
set base_cur             = base_usd,
    consumer_fee_cur     = consumer_fee_usd,
    consumer_fee_vat_cur = consumer_fee_vat_usd,
    amount_cur           = amount_usd,
    merchant_net_cur     = merchant_net_usd
where amount_cur is null;

alter table public.charges drop constraint if exists charges_currency_check;
alter table public.charges
  add constraint charges_currency_check check (
    currency in ('USD', 'EUR')
    and fx_usd_per_unit > 0
    and (currency <> 'USD' or fx_usd_per_unit = 1)
  );

comment on column public.charges.currency is
  'Moneda en la que el médico cobró la consulta: USD o EUR. El paciente paga en bolívares a la tasa BCV de esta moneda del día en que paga.';
comment on column public.charges.fx_usd_per_unit is
  'Dólares por una unidad de `currency` el día del registro (tasa cruzada del BCV). 1 en las órdenes en dólares. Es la que pasó la orden al libro, que es en dólares.';
comment on column public.charges.amount_cur is
  'Lo que paga el paciente, en la moneda de la orden (`amount_usd` es lo mismo pasado a dólares).';

alter table public.installments
  add column if not exists amount_cur   numeric(18,4),
  add column if not exists financed_cur numeric(18,4);

update public.installments
set amount_cur = amount_usd, financed_cur = financed_usd
where amount_cur is null;

comment on column public.installments.amount_cur is
  'Lo que vale la cuota en la moneda de su orden (`charges.currency`). Es lo que paga el paciente, en bolívares a la tasa BCV de esa moneda del día en que paga.';

alter table public.settlements
  add column if not exists currency   text          not null default 'USD',
  add column if not exists amount_cur numeric(18,4),
  add column if not exists paid_cur   numeric(18,4) not null default 0;

update public.settlements
set amount_cur = amount_usd, paid_cur = paid_usd
where amount_cur is null;

alter table public.settlements drop constraint if exists settlements_currency_check;
alter table public.settlements
  add constraint settlements_currency_check check (currency in ('USD', 'EUR'));

comment on column public.settlements.amount_cur is
  'La liquidación en su moneda (`currency`): la de la orden para la consulta, dólares para la comisión del personal. Se le transfiere en bolívares a la tasa BCV de esa moneda del día del pago.';

alter table public.merchant_payout_items
  add column if not exists currency   text not null default 'USD',
  add column if not exists amount_cur numeric(18,4);

update public.merchant_payout_items set amount_cur = amount_usd where amount_cur is null;

alter table public.merchant_payouts
  add column if not exists amount_eur  numeric(18,4),
  add column if not exists fx_rate_eur numeric(18,6);

comment on column public.merchant_payouts.amount_eur is
  'La parte de la transferencia que pagaba liquidaciones en euros, en euros. `fx_rate_eur` es la tasa con la que se pasó a bolívares; `fx_rate` sigue siendo la del dólar.';

-- ---------------------------------------------------------------------------
-- 2. El desglose en las dos monedas
-- ---------------------------------------------------------------------------

/**
 * La moneda de cobro, validada y en mayúsculas. Sin moneda, dólares.
 */
create or replace function public.helios_charge_currency(p_currency text)
returns text
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v text := upper(coalesce(nullif(btrim(p_currency), ''), 'USD'));
begin
  if v not in ('USD', 'EUR') then
    raise exception 'Moneda no válida: dólares (USD) o euros (EUR)' using errcode = '22023';
  end if;
  return v;
end;
$$;

/**
 * El monto de la consulta en la moneda de la orden, validado: positivo, con 2
 * decimales como mucho y, pasado a dólares, al menos el mínimo
 * (`min_charge_usd`). El mínimo se dice en la moneda de la orden.
 */
create or replace function public.helios_assert_charge_amount_in(
  p_amount   numeric,
  p_currency text,
  p_fx       numeric
)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_min numeric := public.helios_min_charge_usd();
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Escribe el monto de la consulta' using errcode = '22023';
  end if;

  if p_amount <> round(p_amount, 2) then
    raise exception 'El monto admite como mucho 2 decimales' using errcode = '22023';
  end if;

  if round(p_amount * p_fx, 2) < v_min then
    raise exception 'El monto mínimo es %',
      public.helios_money_cur_text(
        case when p_currency = 'USD' then v_min else ceil(v_min / p_fx * 100) / 100 end,
        p_currency)
      using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.helios_assert_charge_amount_in(numeric, text, numeric) from public, anon, authenticated;

/**
 * El desglose de una consulta en las dos monedas:
 *
 *   cur  el de la moneda de la orden (`helios_charge_breakdown` sobre el monto
 *        tal cual lo escribió el médico). OJO: sus claves se llaman `*_usd`
 *        porque es el mismo desglose, pero aquí van en la moneda de la orden.
 *   usd  el del libro: la base pasada a dólares (2 decimales) y el mismo
 *        desglose encima. En una orden en dólares, idéntico a `cur`.
 */
create or replace function public.helios_charge_amounts(
  p_amount           numeric,
  p_currency         text,
  p_fx               numeric,
  p_merchant_fee_pct numeric
)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_cur text := public.helios_charge_currency(p_currency);
  v_b   jsonb := public.helios_charge_breakdown(p_amount, p_merchant_fee_pct);
begin
  return jsonb_build_object(
    'currency', v_cur,
    'fx_usd_per_unit', case when v_cur = 'USD' then 1 else p_fx end,
    'cur', v_b,
    'usd', case when v_cur = 'USD' then v_b
                else public.helios_charge_breakdown(round(p_amount * p_fx, 2), p_merchant_fee_pct) end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Las cuotas y las liquidaciones se ponen su moneda solas
-- ---------------------------------------------------------------------------

/**
 * Antes de insertar una cuota: su parte en la moneda de la orden. En dólares,
 * la misma cifra. En euros, el mismo reparto que `helios_assign_debt` hace en
 * dólares (la mitad redondeada en la primera, el resto en la segunda), sobre
 * los montos en euros de la orden.
 */
create or replace function public.helios_installment_currency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c public.charges%rowtype;
begin
  if new.amount_cur is not null then
    return new;
  end if;

  select * into v_c from public.charges where id = new.charge_id;

  if v_c.id is null or v_c.currency = 'USD' or v_c.amount_cur is null then
    new.amount_cur   := new.amount_usd;
    new.financed_cur := new.financed_usd;
    return new;
  end if;

  new.amount_cur := case new.sequence
    when 1 then round(v_c.amount_cur / 2, 2)
    else v_c.amount_cur - round(v_c.amount_cur / 2, 2) end;
  new.financed_cur := case new.sequence
    when 1 then round(coalesce(v_c.base_cur, v_c.amount_cur) / 2, 2)
    else coalesce(v_c.base_cur, v_c.amount_cur) - round(coalesce(v_c.base_cur, v_c.amount_cur) / 2, 2) end;
  return new;
end;
$$;

drop trigger if exists installments_currency on public.installments;
create trigger installments_currency
  before insert on public.installments
  for each row execute function public.helios_installment_currency();

/**
 * Antes de insertar una liquidación: su moneda y su monto en ella. La de la
 * consulta (adelanto, cada mitad, al cobrar) va en la moneda de la orden, en
 * proporción a su parte del neto en dólares; la que completa el neto se lleva
 * exactamente lo que falta, para que las mitades sumen el neto al céntimo. La
 * comisión del personal es en dólares.
 */
create or replace function public.helios_settlement_currency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c        public.charges%rowtype;
  v_net_usd  numeric(18,4);
  v_net_cur  numeric(18,4);
  v_prev_usd numeric(18,4);
  v_prev_cur numeric(18,4);
begin
  if new.reason::text in ('advance', 'scheduled_installment', 'on_collection') then
    select c.* into v_c
    from public.charges c
    where c.id = coalesce(new.charge_id,
                          (select i.charge_id from public.installments i where i.id = new.installment_id));
  end if;

  if v_c.id is null or v_c.currency = 'USD' then
    new.currency   := 'USD';
    new.amount_cur := new.amount_usd;
    return new;
  end if;

  v_net_usd := coalesce(v_c.merchant_net_usd, v_c.amount_usd);
  v_net_cur := coalesce(v_c.merchant_net_cur, v_c.amount_cur);

  select coalesce(sum(s.amount_usd), 0), coalesce(sum(s.amount_cur), 0)
    into v_prev_usd, v_prev_cur
  from public.settlements s
  left join public.installments i on i.id = s.installment_id
  where coalesce(s.charge_id, i.charge_id) = v_c.id
    and s.reason::text in ('advance', 'scheduled_installment', 'on_collection');

  new.currency := v_c.currency;
  new.amount_cur := case
    when v_prev_usd + new.amount_usd >= v_net_usd - 0.005 then greatest(v_net_cur - v_prev_cur, 0)
    else round(v_net_cur * new.amount_usd / nullif(v_net_usd, 0), 2)
  end;
  return new;
end;
$$;

drop trigger if exists settlements_currency on public.settlements;
create trigger settlements_currency
  before insert on public.settlements
  for each row execute function public.helios_settlement_currency();

-- ---------------------------------------------------------------------------
-- 4. Paso 4: la vista previa
-- ---------------------------------------------------------------------------

drop function if exists public.preview_patient_charge(uuid, text, numeric);

create or replace function public.preview_patient_charge(
  p_merchant_id uuid,
  p_document    text,
  p_amount      numeric,
  p_currency    text default 'USD'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_key     text;
  v_p       public.profiles%rowtype;
  v_terms   public.merchant_terms%rowtype;
  v_cur     text := public.helios_charge_currency(p_currency);
  v_bdate   date := public.helios_business_date(now());
  v_fx      numeric;
  v_rate    numeric;
  v_amt     jsonb;
  v_b       jsonb;
  v_bc      jsonb;
  v_due_1   date;
  v_due_2   date;
  v_total   numeric(18,4);
  v_base    numeric(18,4);
  v_first   numeric(18,4);
  v_fin_1   numeric(18,4);
  v_total_c numeric(18,4);
  v_base_c  numeric(18,4);
  v_first_c numeric(18,4);
  v_fin_1_c numeric(18,4);
  v_limit   numeric(18,4);
  v_avail   numeric(18,4);
  v_level1  numeric(18,4) := (select l.monthly_limit_usd from public.levels l where l.level = 1);
  v_min     numeric := public.helios_min_charge_usd();
begin
  if auth.uid() is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if public.helios_staff_role_in(p_merchant_id) is null then
    raise exception 'No tienes permiso para registrar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

  v_fx := public.helios_usd_per_unit(v_cur, v_bdate);
  perform public.helios_assert_charge_amount_in(p_amount, v_cur, v_fx);

  if nullif(btrim(coalesce(p_document, '')), '') is not null then
    v_key := public.helios_document_key(p_document);
    perform public.helios_assert_document_looked_up(p_merchant_id, v_key);
    select * into v_p from public.profiles where document_key = v_key;
  end if;

  select * into v_terms from public.helios_terms_at(p_merchant_id, v_bdate);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  v_amt := public.helios_charge_amounts(p_amount, v_cur, v_fx, coalesce(v_terms.commission_pct, 0));
  v_b   := v_amt->'usd';
  v_bc  := v_amt->'cur';
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  -- El mismo reparto que `helios_assign_debt` (dólares) y que el trigger de
  -- las cuotas (moneda de la orden).
  v_total   := (v_b->>'consumer_total_usd')::numeric;
  v_base    := (v_b->>'base_usd')::numeric;
  v_first   := round(v_total / 2, 2);
  v_fin_1   := round(v_base / 2, 2);
  v_total_c := (v_bc->>'consumer_total_usd')::numeric;
  v_base_c  := (v_bc->>'base_usd')::numeric;
  v_first_c := round(v_total_c / 2, 2);
  v_fin_1_c := round(v_base_c / 2, 2);

  -- Bolívares de hoy por unidad de la moneda de la orden (null sin tasa).
  v_rate := public.helios_fx_rate(v_cur, v_bdate);

  if v_p.id is not null then
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);
    -- Sin decir por qué: si no puede financiar, su disponible es 0.
    if not (v_p.status = 'active' and not v_p.is_blacklisted and public.can_take_debt(v_p.id))
       or v_avail < v_min then
      v_avail := 0;
    end if;
    v_avail := trunc(v_avail, 2);
  end if;

  return jsonb_build_object(
    'currency', v_cur,
    'fx_usd_per_unit', v_fx,
    'tasa_bcv', v_rate,
    -- En dólares, literal: lo del libro.
    'base_usd', v_base,
    'consumer_fee_pct', (v_b->>'consumer_fee_pct')::numeric,
    'consumer_fee_usd', (v_b->>'consumer_fee_usd')::numeric,
    'consumer_fee_vat_usd', (v_b->>'consumer_fee_vat_usd')::numeric,
    -- En la moneda de la orden: lo que se enseña.
    'base_cur', v_base_c,
    'consumer_fee_cur', (v_bc->>'consumer_fee_usd')::numeric,
    'consumer_fee_vat_cur', (v_bc->>'consumer_fee_vat_usd')::numeric,
    'business_date', v_bdate,
    -- Las cuotas llevan la comisión dentro: es donde la clínica puede verla.
    'installments', jsonb_build_array(
      jsonb_build_object('sequence', 1, 'due_date', v_due_1,
                         'amount_usd', v_first, 'financed_usd', v_fin_1,
                         'amount_cur', v_first_c, 'financed_cur', v_fin_1_c,
                         'amount_ves', case when v_rate is not null then round(v_first_c * v_rate, 2) end),
      jsonb_build_object('sequence', 2, 'due_date', v_due_2,
                         'amount_usd', v_total - v_first, 'financed_usd', v_base - v_fin_1,
                         'amount_cur', v_total_c - v_first_c, 'financed_cur', v_base_c - v_fin_1_c,
                         'amount_ves', case when v_rate is not null
                                            then round((v_total_c - v_first_c) * v_rate, 2) end)
    ),
    'late_fee_usd', public.helios_late_fee_usd(),
    'late_fee_grace_days', public.helios_late_fee_grace_days(),
    'cabe', case when v_p.id is null then v_base <= v_level1 else v_base <= v_avail end,
    'disponible_usd', case when v_p.id is null then null else v_avail end,
    'limite_usd', case when v_p.id is null then v_level1 end,
    'disponible_cur', case when v_p.id is null then null else trunc(v_avail / v_fx, 2) end,
    'limite_cur', case when v_p.id is null then trunc(v_level1 / v_fx, 2) end
  );
end;
$$;

revoke all on function public.preview_patient_charge(uuid, text, numeric, text) from public, anon;
grant execute on function public.preview_patient_charge(uuid, text, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Paso 5: registrar
-- ---------------------------------------------------------------------------

drop function if exists public.create_patient_charge(uuid, uuid, jsonb, numeric, text, text, text);

create or replace function public.create_patient_charge(
  p_merchant_id      uuid,
  p_branch_id        uuid,
  p_patient          jsonb,
  p_amount           numeric,
  p_concept          text,
  p_beneficiary_name text,
  p_idempotency_key  text,
  p_currency         text default 'USD'
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_staff      uuid := auth.uid();
  v_key        text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_confirm    boolean := public.helios_patient_confirmation_required();
  v_canal      text := coalesce(nullif(current_setting('helios.canal', true), ''), 'panel');
  v_cur        text;
  v_fx         numeric;
  v_base_usd   numeric(18,4);
  v_existing   public.charges%rowtype;
  v_role       public.merchant_role;
  v_branch     uuid;
  v_concept    text;
  v_benef      text;
  v_doc        text;
  v_in         jsonb;
  v_profile    public.profiles%rowtype;
  v_new        boolean := false;
  v_changes    jsonb := '{}'::jsonb;
  v_field      text;
  v_actual     text;
  v_limit      numeric(18,4);
  v_used       numeric(18,4);
  v_avail      numeric(18,4);
  v_min        numeric := public.helios_min_charge_usd();
  v_terms      public.merchant_terms%rowtype;
  v_amt        jsonb;
  v_b          jsonb;
  v_bc         jsonb;
  v_bdate      date;
  v_charge     public.charges%rowtype;
  v_commission numeric(18,4);
  v_over_msg   text;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if v_key is null or length(v_key) > 200 then
    raise exception 'Falta la clave de idempotencia del formulario' using errcode = '22023';
  end if;

  if v_canal not in ('panel', 'whatsapp') then
    v_canal := 'panel';
  end if;

  -- 1. Idempotencia. El doble clic y la recarga devuelven el mismo
  --    financiamiento sin tocar nada. Serializado por clave.
  perform pg_advisory_xact_lock(hashtextextended('create_patient_charge:' || v_key, 0));

  select * into v_existing from public.charges where idempotency_key = v_key;
  if found then
    if v_existing.merchant_id = p_merchant_id and public.helios_staff_role_in(p_merchant_id) is not null then
      return public.helios_charge_for_staff(v_existing.id);
    end if;
    raise exception 'Esa clave de idempotencia ya se usó en otra orden' using errcode = '22023';
  end if;

  -- 2. Autorización. Gerente: cualquier sede de su clínica (sin sede, la
  --    principal). Secretaria: solo la suya.
  v_role := public.helios_staff_role_in(p_merchant_id);
  if v_role is null then
    raise exception 'No tienes permiso para registrar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

  -- Con la confirmación del paciente, sin WhatsApp no hay a quién preguntar.
  if v_confirm and not public.helios_whatsapp_api_ready() then
    raise exception 'No podemos escribirle a este paciente por WhatsApp. Escribe a Helios'
      using errcode = '22023';
  end if;

  if v_role = 'gerente' then
    v_branch := coalesce(
      p_branch_id,
      (select b.id from public.merchant_branches b
        where b.merchant_id = p_merchant_id and b.is_active
        order by b.is_default desc, b.created_at
        limit 1));
  elsif p_branch_id is not null then
    if not exists (
      select 1 from public.merchant_users mu
      where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active
        and mu.role = 'cajero' and mu.branch_id = p_branch_id
    ) then
      raise exception 'No tienes permiso para registrar en esa sede' using errcode = '42501';
    end if;
    v_branch := p_branch_id;
  else
    if (select count(distinct mu.branch_id) from public.merchant_users mu
         where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active
           and mu.role = 'cajero') > 1 then
      raise exception 'Elige la sede donde se registra el pago en cuotas' using errcode = '22023';
    end if;
    select mu.branch_id into v_branch
    from public.merchant_users mu
    where mu.user_id = v_staff and mu.merchant_id = p_merchant_id and mu.is_active and mu.role = 'cajero'
    limit 1;
  end if;

  if v_branch is null or not exists (
    select 1 from public.merchant_branches b
    where b.id = v_branch and b.merchant_id = p_merchant_id and b.is_active
  ) then
    raise exception 'La sede no es de esta clínica o está inactiva' using errcode = '22023';
  end if;

  -- 3. Moneda, monto, concepto y paciente atendido. El monto se escribe en la
  --    moneda de la orden; el libro, el mínimo y el cupo, en dólares con la
  --    tasa cruzada de hoy.
  v_bdate    := public.helios_business_date(now());
  v_cur      := public.helios_charge_currency(p_currency);
  v_fx       := public.helios_usd_per_unit(v_cur, v_bdate);
  perform public.helios_assert_charge_amount_in(p_amount, v_cur, v_fx);
  v_base_usd := round(p_amount * v_fx, 2);

  v_concept := nullif(regexp_replace(btrim(coalesce(p_concept, '')), '\s+', ' ', 'g'), '');
  if length(v_concept) > 80 then
    raise exception 'El concepto admite como mucho 80 caracteres' using errcode = '22023';
  end if;
  v_concept := coalesce(v_concept, 'Consulta');

  v_benef := nullif(regexp_replace(btrim(coalesce(p_beneficiary_name, '')), '\s+', ' ', 'g'), '');
  if length(v_benef) > 120 then
    raise exception 'El nombre del paciente atendido admite como mucho 120 caracteres' using errcode = '22023';
  end if;

  -- 4. El paciente, por cédula.
  if p_patient is null or jsonb_typeof(p_patient) <> 'object' then
    raise exception 'Faltan los datos del paciente' using errcode = '22023';
  end if;

  v_doc := public.helios_document_key(p_patient->>'document');
  perform public.helios_assert_document_looked_up(p_merchant_id, v_doc);

  select * into v_profile from public.profiles where document_key = v_doc for update;

  if not found then
    -- Nuevo: se validan todos los datos y nace activo, nivel 1. Con la
    -- confirmación, se crea ya aquí: hace falta su teléfono para preguntarle.
    v_in := public.helios_patient_input(p_patient, true);

    insert into public.profiles (
      document_number, first_name, last_name, full_name, birth_date, sex,
      phone_e164, email, state, city, address, occupation,
      reference_name, reference_phone, reference_relationship,
      registered_by, registered_merchant_id
    ) values (
      v_doc, v_in->>'first_name', v_in->>'last_name',
      (v_in->>'first_name') || ' ' || (v_in->>'last_name'),
      (v_in->>'birth_date')::date, v_in->>'sex',
      v_in->>'phone', v_in->>'email', v_in->>'state', v_in->>'city', v_in->>'address',
      v_in->>'occupation', v_in->>'reference_name', v_in->>'reference_phone',
      v_in->>'reference_relationship', v_staff, p_merchant_id
    )
    on conflict (document_key) do nothing
    returning * into v_profile;

    if v_profile.id is null then
      -- Otra sede lo registró entre la búsqueda y el INSERT: es un conocido.
      select * into v_profile from public.profiles where document_key = v_doc for update;
    else
      v_new := true;
    end if;
  end if;

  if not v_new then
    -- Conocido: con la fila bloqueada. Mora, lista negra, bloqueo, expulsión:
    -- el mismo texto neutro que la elegibilidad.
    if v_profile.status <> 'active'
       or v_profile.is_blacklisted
       or public.helios_spend_blocked(v_profile.id)
       or not public.can_take_debt(v_profile.id) then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;

    -- Una sola orden esperando respuesta por paciente (sin decir de qué clínica).
    if exists (
      select 1 from public.charges c
      where c.user_id = v_profile.id and c.status = 'pending' and c.expires_at > now()
    ) then
      raise exception 'Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza'
        using errcode = '22023';
    end if;

    -- Sus datos NO se sobrescriben: lo que venga distinto queda como
    -- propuesta para Helios.
    v_in := public.helios_patient_input(p_patient, false);
    for v_field in select jsonb_object_keys(v_in) loop
      v_actual := to_jsonb(v_profile) ->> (case when v_field = 'phone' then 'phone_e164' else v_field end);
      if v_actual is distinct from v_in->>v_field then
        v_changes := v_changes || jsonb_build_object(v_field,
          jsonb_build_object('antes', v_actual, 'propuesto', v_in->>v_field));
      end if;
    end loop;

    if v_changes <> '{}'::jsonb then
      insert into public.profile_change_requests (profile_id, merchant_id, requested_by, field_changes)
      values (v_profile.id, p_merchant_id, v_staff, v_changes);
    end if;
  end if;

  -- 5. El cupo, en dólares, con la fila bloqueada: la defensa contra el doble
  --    gasto. Cuenta lo reservado por órdenes pendientes. Lo disponible se
  --    dice en la moneda de la orden.
  select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_profile.level;
  v_used  := public.helios_credit_used_usd(v_profile.id);
  v_avail := greatest(coalesce(v_limit, 0) - v_used, 0);

  if not v_new and v_avail < v_min then
    -- Cupo agotado es también «no disponible», sin decir por qué.
    raise exception '%', public.helios_not_available_message() using errcode = '22023';
  end if;

  v_over_msg := format('El monto supera lo disponible (%s).',
                       public.helios_money_cur_text(trunc(v_avail / v_fx, 2), v_cur));
  if v_base_usd > v_avail then
    raise exception '%', v_over_msg using errcode = '22023';
  end if;

  -- 6. Condiciones, desglose (en las dos monedas) y comisión.
  select * into v_terms from public.helios_terms_at(p_merchant_id, v_bdate);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  v_amt := public.helios_charge_amounts(p_amount, v_cur, v_fx, coalesce(v_terms.commission_pct, 0));
  v_b   := v_amt->'usd';
  v_bc  := v_amt->'cur';
  v_commission := public.helios_staff_commission_for(p_merchant_id, v_bdate);

  -- 7. La orden: pendiente (espera el «Sí») o, con el interruptor en 0,
  --    directamente confirmada.
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key, user_id, status,
    business_date, confirmed_at, expires_at, channel,
    amount_usd, base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd,
    currency, fx_usd_per_unit,
    amount_cur, base_cur, consumer_fee_cur, consumer_fee_vat_cur, merchant_net_cur,
    concept, beneficiary_name, terms_version_id,
    staff_commission_usd, commission_staff_id
  ) values (
    p_merchant_id, v_branch, v_staff, v_key, v_profile.id,
    case when v_confirm then 'pending' else 'confirmed' end::public.charge_status,
    v_bdate,
    case when v_confirm then null else now() end,
    case when v_confirm then now() + make_interval(mins => public.helios_patient_confirmation_minutes())
         else now() end,
    v_canal,
    (v_b->>'consumer_total_usd')::numeric, (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric, (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric, (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric, (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric, (v_b->>'merchant_net_usd')::numeric,
    v_cur, (v_amt->>'fx_usd_per_unit')::numeric,
    (v_bc->>'consumer_total_usd')::numeric, (v_bc->>'base_usd')::numeric,
    (v_bc->>'consumer_fee_usd')::numeric, (v_bc->>'consumer_fee_vat_usd')::numeric,
    (v_bc->>'merchant_net_usd')::numeric,
    v_concept, v_benef,
    (select t.id from public.terms_versions t where t.is_current order by t.published_at desc limit 1),
    nullif(v_commission, 0), case when v_commission > 0 then v_staff end
  )
  returning * into v_charge;

  -- Una sola línea libre (D-H4: sin catálogo).
  insert into public.charge_items (charge_id, product_id, name, unit_price_usd, quantity, position)
  values (v_charge.id, null, v_concept, v_charge.base_usd, 1, 0);

  if v_confirm then
    -- 8. La pregunta al paciente, por WhatsApp.
    perform public.helios_enqueue_confirmation(v_charge.id);
  else
    -- 8-12. Asiento, adelanto, cuotas, comisión, comprobante y bienvenida.
    perform public.helios_finalize_charge(v_charge.id, 'whatsapp_manual', v_over_msg);
  end if;

  -- 13. Bitácora.
  perform audit.log(v_staff, 'charge.created', v_charge.id, jsonb_build_object(
    'merchant_id', p_merchant_id,
    'branch_id', v_branch,
    'user_id', v_profile.id,
    'new_patient', v_new,
    'currency', v_cur,
    'fx_usd_per_unit', v_charge.fx_usd_per_unit,
    'base_cur', v_charge.base_cur,
    'base_usd', v_charge.base_usd,
    'amount_usd', v_charge.amount_usd,
    'concept', v_concept,
    'beneficiary_name', v_benef,
    'staff_commission_usd', v_charge.staff_commission_usd,
    'change_request', v_changes <> '{}'::jsonb,
    'business_date', v_bdate,
    'status', case when v_confirm then 'pending' else 'confirmed' end,
    'expires_at', case when v_confirm then v_charge.expires_at end,
    'canal', v_canal
  ));

  return public.helios_charge_for_staff(v_charge.id);
end;
$$;

revoke all on function public.create_patient_charge(uuid, uuid, jsonb, numeric, text, text, text, text) from public, anon;
grant execute on function public.create_patient_charge(uuid, uuid, jsonb, numeric, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Reabrir una orden vencida la vuelve a pasar a dólares con la tasa del día
-- ---------------------------------------------------------------------------

create or replace function public.staff_resend_confirmation(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_me     uuid := auth.uid();
  v_c      public.charges%rowtype;
  v_p      public.profiles%rowtype;
  v_first  uuid;
  v_n      integer;
  v_max    integer := public.helios_confirmation_resends_per_day();
  v_limit  numeric(18,4);
  v_avail  numeric(18,4);
  v_min    numeric := public.helios_min_charge_usd();
  v_terms  public.merchant_terms%rowtype;
  v_amt    jsonb;
  v_b      jsonb;
  v_bc     jsonb;
  v_bdate  date;
  v_comm   numeric(18,4);
  v_fx     numeric;
  v_base_c numeric(18,4);
  v_base   numeric(18,4);
  v_msg    uuid;
  v_reopen boolean := false;
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_c from public.charges where id = p_charge_id for update;

  -- La misma regla que el detalle: el gerente, los de su clínica; la
  -- secretaria, los que registró. El mismo error exista o no.
  if not found or not exists (
    select 1 from public.merchant_users mu
    where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
      and (mu.role = 'gerente' or (mu.role = 'cajero' and v_c.requested_by = v_me))
  ) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  if v_c.status = 'pending' and v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id returning * into v_c;
  end if;

  if v_c.status not in ('pending', 'expired') then
    raise exception 'Esta orden ya no se puede reenviar' using errcode = '22023';
  end if;

  if not public.helios_whatsapp_api_ready() then
    raise exception 'No podemos escribirle a este paciente por WhatsApp. Escribe a Helios'
      using errcode = '22023';
  end if;

  -- Reenvíos de hoy: las preguntas de hoy menos la primera de todas.
  select o.id into v_first
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key = 'confirmar_financiamiento'
  order by o.created_at, o.id limit 1;

  select count(*) into v_n
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key = 'confirmar_financiamiento'
    and o.created_at >= public.helios_business_day_start()
    and o.id is distinct from v_first;

  if v_n >= v_max then
    raise exception 'Ya reenviaste esta solicitud % veces hoy. Inténtalo mañana', v_max
      using errcode = '22023';
  end if;

  if v_c.status = 'expired' then
    v_reopen := true;

    perform public.helios_assert_merchant_operating(v_c.merchant_id);

    select * into v_p from public.profiles where id = v_c.user_id for update;
    if v_p.status <> 'active'
       or v_p.is_blacklisted
       or public.helios_spend_blocked(v_p.id)
       or not public.can_take_debt(v_p.id) then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;

    if exists (
      select 1 from public.charges c
      where c.user_id = v_p.id and c.id <> v_c.id and c.status = 'pending' and c.expires_at > now()
    ) then
      raise exception 'Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza'
        using errcode = '22023';
    end if;

    -- El médico cobró en su moneda y eso no cambia; lo que cambia es la tasa
    -- con la que se pasa a dólares, que es la de hoy.
    v_bdate  := public.helios_business_date(now());
    v_fx     := public.helios_usd_per_unit(v_c.currency, v_bdate);
    v_base_c := coalesce(v_c.base_cur, v_c.base_usd, v_c.amount_usd);
    v_base   := round(v_base_c * v_fx, 2);

    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);
    if v_avail < v_min then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;
    if v_base > v_avail then
      raise exception 'El monto supera lo disponible (%).',
        public.helios_money_cur_text(trunc(v_avail / v_fx, 2), v_c.currency) using errcode = '22023';
    end if;

    select * into v_terms from public.helios_terms_at(v_c.merchant_id, v_bdate);
    if v_terms.id is null then
      raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
        using errcode = '22023';
    end if;

    v_amt  := public.helios_charge_amounts(v_base_c, v_c.currency, v_fx, coalesce(v_terms.commission_pct, 0));
    v_b    := v_amt->'usd';
    v_bc   := v_amt->'cur';
    v_comm := public.helios_staff_commission_for(v_c.merchant_id, v_bdate);

    update public.charges
       set status = 'pending',
           business_date = v_bdate,
           expires_at = now() + make_interval(mins => public.helios_patient_confirmation_minutes()),
           amount_usd = (v_b->>'consumer_total_usd')::numeric,
           base_usd = (v_b->>'base_usd')::numeric,
           vat_pct = (v_b->>'vat_pct')::numeric,
           vat_usd = (v_b->>'vat_usd')::numeric,
           consumer_fee_pct = (v_b->>'consumer_fee_pct')::numeric,
           consumer_fee_usd = (v_b->>'consumer_fee_usd')::numeric,
           consumer_fee_vat_usd = (v_b->>'consumer_fee_vat_usd')::numeric,
           merchant_fee_pct = (v_b->>'merchant_fee_pct')::numeric,
           merchant_fee_usd = (v_b->>'merchant_fee_usd')::numeric,
           merchant_fee_vat_usd = (v_b->>'merchant_fee_vat_usd')::numeric,
           merchant_net_usd = (v_b->>'merchant_net_usd')::numeric,
           fx_usd_per_unit = (v_amt->>'fx_usd_per_unit')::numeric,
           amount_cur = (v_bc->>'consumer_total_usd')::numeric,
           base_cur = (v_bc->>'base_usd')::numeric,
           consumer_fee_cur = (v_bc->>'consumer_fee_usd')::numeric,
           consumer_fee_vat_cur = (v_bc->>'consumer_fee_vat_usd')::numeric,
           merchant_net_cur = (v_bc->>'merchant_net_usd')::numeric,
           terms_version_id = (select t.id from public.terms_versions t
                                where t.is_current order by t.published_at desc limit 1),
           staff_commission_usd = nullif(v_comm, 0),
           commission_staff_id = case when v_comm > 0 then v_c.requested_by end
     where id = v_c.id;
  end if;

  v_msg := public.helios_enqueue_confirmation(v_c.id);

  perform audit.log(v_me, 'charge.confirmation_resent', p_charge_id,
    jsonb_build_object('message_id', v_msg, 'merchant_id', v_c.merchant_id, 'reopened', v_reopen));

  return public.helios_charge_for_staff(p_charge_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Las cuotas previstas y lo que ve la clínica de una orden
-- ---------------------------------------------------------------------------

create or replace function public.helios_charge_planned_installments(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_c       public.charges%rowtype;
  v_out     jsonb;
  v_due_1   date;
  v_due_2   date;
  v_total   numeric(18,4);
  v_base    numeric(18,4);
  v_first   numeric(18,4);
  v_fin_1   numeric(18,4);
  v_total_c numeric(18,4);
  v_base_c  numeric(18,4);
  v_first_c numeric(18,4);
  v_fin_1_c numeric(18,4);
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'sequence', x.sequence, 'due_date', x.due_date,
           'amount_usd', x.amount_usd, 'financed_usd', x.financed_usd,
           'amount_cur', x.amount_cur, 'financed_cur', x.financed_cur)
         order by x.sequence), null)
    into v_out
  from (
    select i.sequence, min(i.due_date) as due_date,
           sum(i.amount_usd) as amount_usd, sum(i.financed_usd) as financed_usd,
           sum(coalesce(i.amount_cur, i.amount_usd)) as amount_cur,
           sum(coalesce(i.financed_cur, i.financed_usd)) as financed_cur
    from public.installments i where i.charge_id = p_charge_id group by i.sequence
  ) x;

  if v_out is not null then
    return v_out;
  end if;

  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return '[]'::jsonb;
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_c.business_date);
  v_total   := v_c.amount_usd;
  v_base    := coalesce(v_c.base_usd, v_c.amount_usd);
  v_first   := round(v_total / 2, 2);
  v_fin_1   := round(v_base / 2, 2);
  v_total_c := coalesce(v_c.amount_cur, v_c.amount_usd);
  v_base_c  := coalesce(v_c.base_cur, v_c.base_usd, v_c.amount_usd);
  v_first_c := round(v_total_c / 2, 2);
  v_fin_1_c := round(v_base_c / 2, 2);

  return jsonb_build_array(
    jsonb_build_object('sequence', 1, 'due_date', v_due_1, 'amount_usd', v_first, 'financed_usd', v_fin_1,
                       'amount_cur', v_first_c, 'financed_cur', v_fin_1_c),
    jsonb_build_object('sequence', 2, 'due_date', v_due_2, 'amount_usd', v_total - v_first,
                       'financed_usd', v_base - v_fin_1,
                       'amount_cur', v_total_c - v_first_c, 'financed_cur', v_base_c - v_fin_1_c)
  );
end;
$$;

create or replace function public.helios_charge_for_staff(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_me    uuid := auth.uid();
  v_c     public.charges%rowtype;
  v_p     public.profiles%rowtype;
  v_role  public.merchant_role;
  v_name  text;
  v_open  boolean;
  v_rate  numeric;
begin
  select * into v_c from public.charges where id = p_charge_id;

  -- El mismo error exista o no: probar ids a ciegas no dice cuáles son de otra
  -- clínica. El gerente ve todos los de su clínica; la secretaria, los suyos.
  if not found or not (
    public.is_platform_admin()
    or exists (
      select 1 from public.merchant_users mu
      where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
        and (mu.role = 'gerente' or v_c.requested_by = v_me)
    )
  ) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select * into v_p from public.profiles where id = v_c.user_id;

  select mu.role into v_role
  from public.merchant_users mu
  where mu.user_id = v_c.requested_by and mu.merchant_id = v_c.merchant_id
  order by mu.is_active desc, (mu.role = 'gerente') desc, mu.created_at desc
  limit 1;

  v_name := public.helios_staff_name(v_c.requested_by);
  v_open := v_c.status in ('pending', 'declined', 'expired');
  -- Bolívares de hoy por unidad de la moneda de la orden, para las cuotas.
  v_rate := public.helios_fx_rate(v_c.currency);

  return jsonb_build_object(
    'id', v_c.id,
    'order_number', v_c.order_number,
    'status', v_c.status::text,
    'channel', v_c.channel,
    'created_at', v_c.created_at,
    'confirmed_at', v_c.confirmed_at,
    'expires_at', case when v_c.status in ('pending', 'expired') then v_c.expires_at end,
    'business_date', v_c.business_date,
    'merchant_id', v_c.merchant_id,
    'merchant_name', (select m.name from public.merchants m where m.id = v_c.merchant_id),
    'branch_id', v_c.branch_id,
    'branch_name', (select b.name from public.merchant_branches b where b.id = v_c.branch_id),
    'currency', v_c.currency,
    -- La base: lo que se le paga a la clínica. Nunca un total con el fee.
    'merchant_sale_usd', public.helios_merchant_sale_usd(v_c.base_usd, v_c.vat_usd, v_c.amount_usd),
    'merchant_sale_cur', coalesce(v_c.base_cur, public.helios_merchant_sale_usd(v_c.base_usd, v_c.vat_usd, v_c.amount_usd)),
    'concept', v_c.concept,
    'beneficiary_name', v_c.beneficiary_name,
    'patient', jsonb_build_object(
      'nombre', coalesce(nullif(btrim(v_p.full_name), ''),
                         nullif(btrim(concat_ws(' ', v_p.first_name, v_p.last_name)), '')),
      'documento_enmascarado', public.helios_mask_document(v_p.document_number),
      'email_enmascarado', public.helios_mask_email(v_p.email)
    ),
    -- Las cuotas llevan el fee dentro: es donde se permite verlo.
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sequence', (x->>'sequence')::integer,
               'due_date', (x->>'due_date')::date,
               'amount_usd', (x->>'amount_usd')::numeric,
               'amount_cur', (x->>'amount_cur')::numeric,
               'amount_ves', case when v_rate is not null
                                  then round((x->>'amount_cur')::numeric * v_rate, 2) end)
             order by (x->>'sequence')::integer)
      from jsonb_array_elements(public.helios_charge_planned_installments(v_c.id)) x
    ), '[]'::jsonb),
    'breakdown', jsonb_build_object(
      'base_usd', v_c.base_usd,
      'consumer_fee_pct', v_c.consumer_fee_pct,
      'consumer_fee_usd', v_c.consumer_fee_usd,
      'consumer_fee_vat_usd', v_c.consumer_fee_vat_usd,
      'base_cur', v_c.base_cur,
      'consumer_fee_cur', v_c.consumer_fee_cur,
      'consumer_fee_vat_cur', v_c.consumer_fee_vat_cur
    ),
    'tasa_bcv', v_rate,
    'receipt', case
      when v_open then jsonb_build_object(
        'status', 'sin_enviar', 'sent_at', null, 'last_event', null,
        'email_enmascarado', public.helios_mask_email(v_p.email))
      else public.helios_charge_receipt(v_c.id)
    end,
    'confirmation', public.helios_charge_confirmation(v_c.id),
    'decline_reason', v_c.decline_reason,
    'decline_message', case v_c.decline_reason
      when 'paciente' then 'El paciente rechazó el pago en cuotas'
      when 'no_disponible' then public.helios_not_available_message()
    end,
    'registered_by', case
      when v_name is null then null
      when v_role is null then v_name
      else v_name || ' (' || case v_role when 'gerente' then 'Administrador' else 'Secretaria' end || ')'
    end,
    'staff_commission_usd', v_c.staff_commission_usd
  );
end;
$$;

-- La lista de la clínica: dos columnas más al final (la moneda y la consulta
-- en esa moneda). Cambia el tipo de retorno: se recrea.
drop function if exists public.merchant_transactions(date, date, integer);

create or replace function public.merchant_transactions(p_from date, p_to date, p_limit integer default 500)
returns table(
  charge_id uuid, order_number bigint, business_date date, confirmed_at timestamptz,
  amount_usd numeric, merchant_sale_usd numeric, customer_name text, staff_name text,
  cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date,
  concept text, beneficiary_name text, receipt_status text, staff_commission_usd numeric,
  registered_by_name text, status text, expires_at timestamptz,
  currency text, merchant_sale_cur numeric)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.created_at as creado,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro,
           c.concept as concepto,
           c.beneficiary_name as atendido,
           c.staff_commission_usd as comision,
           c.status::text as estado,
           c.expires_at as vence,
           c.currency as moneda,
           coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)) as sale_cur
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status in ('confirmed', 'pending', 'declined', 'expired')
      and c.business_date between p_from and p_to
      -- El gerente de ESA clínica ve todos; cualquier otro, solo los suyos.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    order by c.business_date desc, coalesce(c.confirmed_at, c.created_at) desc
    limit v_limit
  ),
  cuotas as (
    select (m.id)                                                  as cid,
           (x->>'sequence')::integer                               as seq,
           (x->>'due_date')::date                                  as due,
           public.helios_settlement_run_for((x->>'due_date')::date) as run
    from mias m
    cross join lateral jsonb_array_elements(public.helios_charge_planned_installments(m.id)) x
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         p.full_name,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         c1.due,
         c1.run,
         c2.due,
         c2.run,
         m.concepto,
         m.atendido,
         case when m.estado = 'confirmed' then public.helios_charge_receipt(m.id) ->> 'status'
              else 'sin_enviar' end,
         m.comision,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         m.estado,
         case when m.estado in ('pending', 'expired') then m.vence end,
         m.moneda,
         m.sale_cur
  from mias m
  left join public.profiles p on p.id = m.quien
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, coalesce(m.conf, m.creado) desc;
end;
$$;

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;

create or replace function public.merchant_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge  public.charges%rowtype;
  v_gerente boolean;
  v_out     jsonb;
begin
  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := coalesce(public.my_merchant_id_as_gerente() = v_charge.merchant_id, false);

  if not v_gerente and v_charge.requested_by is distinct from auth.uid() then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- El nombre del paciente, y nada más de él (ni deuda ni pagos).
    'customer_name', p.full_name,
    'staff_name', public.helios_staff_name(c.requested_by),
    'merchant_sale_usd', public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd),
    'base_usd', c.base_usd,
    'vat_usd', c.vat_usd,
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', case when v_gerente then c.merchant_fee_usd end,
    'merchant_fee_vat_usd', case when v_gerente then c.merchant_fee_vat_usd end,
    'merchant_net_usd', case when v_gerente then c.merchant_net_usd end,
    -- En la moneda en la que cobró la clínica: lo que se le enseña.
    'currency', c.currency,
    'merchant_sale_cur', coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)),
    'base_cur', c.base_cur,
    'consumer_fee_cur', c.consumer_fee_cur,
    'consumer_fee_vat_cur', c.consumer_fee_vat_cur,
    'merchant_net_cur', case when v_gerente then c.merchant_net_cur end,
    'is_gerente', v_gerente,
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission_usd', c.staff_commission_usd,
    'commission_staff_name', case when c.commission_staff_id is not null
                                  then public.helios_staff_name(c.commission_staff_id) end,
    'payer_count', 1
  )
  into v_out
  from public.charges c
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd,
      'line_total_cur', round(ci.line_total_usd * coalesce(v_charge.base_cur, v_charge.base_usd)
                              / nullif(v_charge.base_usd, 0), 2)
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Las cuotas del paciente: SOLO sus fechas y cuándo se le paga a la clínica
  -- la mitad que corresponde. Nunca si el paciente pagó.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'sequence', m.seq,
      'due_date', m.due,
      'run_date', public.helios_settlement_run_for(m.due),
      'paid_to_merchant_on', (
        select max(coalesce(mp.paid_on, mp.business_date))
        from public.settlements s
        join public.merchant_payout_items it on it.settlement_id = s.id
        join public.merchant_payouts mp on mp.id = it.payout_id
        where s.charge_id = p_charge_id
          and s.reason = 'scheduled_installment'
          and s.business_date = m.due
          and s.status = 'paid'
      )
    ) order by m.seq)
    from (
      select i.sequence as seq, min(i.due_date) as due
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.sequence
    ) m
  ), '[]'::jsonb));

  -- Cuándo se le paga a la clínica cada parte: el adelanto (si lo hay), cada
  -- mitad y la comisión del personal. Los montos, solo al gerente. Cada parte
  -- en su moneda (`currency`, `amount_cur`): la consulta en la de la orden y
  -- la comisión en dólares.
  v_out := v_out || jsonb_build_object('payouts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', x.kind,
      'sequence', x.seq,
      'due_date', x.due,
      'run_date', public.helios_settlement_run_for(x.due),
      'amount_usd', case when v_gerente or x.kind = 'staff_commission' then x.amount end,
      'paid_usd', case when v_gerente or x.kind = 'staff_commission' then x.paid end,
      'status', case when v_gerente or x.kind = 'staff_commission' then x.status end,
      'currency', x.moneda,
      'amount_cur', case when v_gerente or x.kind = 'staff_commission' then x.amount_c end,
      'paid_cur', case when v_gerente or x.kind = 'staff_commission' then x.paid_c end
    ) order by x.due, x.seq nulls first)
    from (
      select 'advance'::text    as kind,
             null::smallint     as seq,
             s.due_date         as due,
             s.amount_usd       as amount,
             s.paid_usd         as paid,
             s.status::text     as status,
             s.currency         as moneda,
             s.amount_cur       as amount_c,
             s.paid_cur         as paid_c
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'advance'

      union all

      select 'installment',
             m.seq,
             m.due,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             coalesce(s.currency, v_charge.currency),
             s.amount_cur,
             s.paid_cur
      from (
        select i.sequence as seq, min(i.due_date) as due
        from public.installments i
        where i.charge_id = p_charge_id
        group by i.sequence
      ) m
      left join public.settlements s
        on s.charge_id = p_charge_id
       and s.reason = 'scheduled_installment'
       and s.business_date = m.due

      union all

      select 'staff_commission',
             null::smallint,
             s.due_date,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             s.currency,
             s.amount_cur,
             s.paid_cur
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'staff_commission'
    ) x
  ), '[]'::jsonb));

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. El pago a la clínica: los bolívares, por moneda
-- ---------------------------------------------------------------------------

create or replace function public.admin_report_merchant_payout(
  p_merchant_id    uuid,
  p_settlement_ids uuid[],
  p_method         text,
  p_reference      text default null,
  p_amount_ves     numeric default null,
  p_fx_rate        numeric default null,
  p_note           text default null,
  p_amount_usd     numeric default null,
  p_paid_on        date default null,
  p_receipt_path   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_actor       uuid := auth.uid();
  v_pendiente   numeric(18,4);
  v_total       numeric(18,4);
  v_restante    numeric(18,4);
  v_aplicado    numeric(18,4);
  v_aplicado_c  numeric(18,4);
  v_count       integer;
  v_bdate       date;
  v_paid_on     date;
  v_payout      public.merchant_payouts%rowtype;
  v_tx          uuid;
  v_acct_pay    uuid;
  v_acct_cash   uuid;
  v_fx          numeric;
  v_fx_eur      numeric;
  v_ves         numeric;
  v_fila        record;
  v_consultas   numeric(18,4);
  v_comisiones  numeric(18,4);
  v_parte_usd   numeric(18,4) := 0;
  v_parte_eur   numeric(18,4) := 0;
  v_hay_usd     boolean;
  v_hay_eur     boolean;
  v_note        text := nullif(trim(coalesce(p_note, '')), '');
begin
  perform public.helios_assert_super_admin('registrar pagos a comercios');

  -- PODA (Helios): el método 'boveda' se fue con la bóveda.
  if p_method = 'boveda' then
    raise exception 'Helios no tiene bóveda: registra la transferencia' using errcode = '22023';
  end if;

  if p_settlement_ids is null or array_length(p_settlement_ids, 1) is null then
    raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
  end if;

  perform 1 from public.settlements
  where id = any(p_settlement_ids) for update;

  select coalesce(sum(amount_usd - paid_usd), 0), count(*),
         coalesce(bool_or(currency = 'USD'), false), coalesce(bool_or(currency = 'EUR'), false)
    into v_pendiente, v_count, v_hay_usd, v_hay_eur
  from public.settlements
  where id = any(p_settlement_ids)
    and merchant_id = p_merchant_id
    and status in ('pending', 'partial');

  if v_count <> array_length(p_settlement_ids, 1) then
    raise exception 'Alguna liquidación no es de este comercio o ya está pagada entera'
      using errcode = '22023';
  end if;

  -- Una tasa escrita a mano es la de UNA moneda: con liquidaciones en dólares
  -- y en euros a la vez no se sabría de cuál.
  if p_fx_rate is not null and v_hay_usd and v_hay_eur then
    raise exception 'Hay liquidaciones en dólares y en euros: deja la tasa vacía (se usa la BCV de cada moneda) o escribe solo el total en bolívares'
      using errcode = '22023';
  end if;

  v_total := coalesce(p_amount_usd, v_pendiente);

  if v_total <= 0 then
    raise exception 'El importe tiene que ser mayor que cero' using errcode = '22023';
  end if;

  if v_total > v_pendiente + 0.005 then
    raise exception 'No puedes registrar % cuando lo marcado suma %',
      v_total, v_pendiente using errcode = '22023';
  end if;

  v_bdate   := public.helios_business_date(now());
  v_paid_on := coalesce(p_paid_on, v_bdate);

  if v_paid_on > v_bdate then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;

  insert into public.merchant_payouts
    (merchant_id, amount_usd, amount_ves, fx_rate, method, reference, note,
     paid_by, business_date, paid_on, receipt_path)
  values
    (p_merchant_id, v_total, null, null, p_method, p_reference, v_note,
     v_actor, v_bdate, v_paid_on, nullif(trim(coalesce(p_receipt_path, '')), ''))
  returning * into v_payout;

  -- El reparto: de la más antigua a la más nueva. La última que alcanza queda
  -- parcial con su resto y sigue apareciendo en el cierre. Cada parte lleva
  -- también su monto en la moneda de la liquidación: lo que falta si la salda
  -- entera, la proporción si no.
  v_restante := v_total;

  for v_fila in
    select id, amount_usd, paid_usd, due_date, currency,
           coalesce(amount_cur, amount_usd) as amount_cur, paid_cur
    from public.settlements
    where id = any(p_settlement_ids)
    order by due_date, id
  loop
    exit when v_restante <= 0;

    v_aplicado := least(v_restante, v_fila.amount_usd - v_fila.paid_usd);
    if v_aplicado <= 0 then
      continue;
    end if;

    v_aplicado_c := case
      when v_fila.paid_usd + v_aplicado >= v_fila.amount_usd - 0.005
        then v_fila.amount_cur - v_fila.paid_cur
      else round(v_aplicado * v_fila.amount_cur / v_fila.amount_usd, 2)
    end;

    -- Al quedar 'paid', el trigger `settlements_sync_staff_commission` marca
    -- la comisión como pagada.
    update public.settlements
    set paid_usd = paid_usd + v_aplicado,
        paid_cur = paid_cur + v_aplicado_c,
        status = case
          when paid_usd + v_aplicado >= amount_usd - 0.005 then 'paid'::public.settlement_status
          else 'partial'::public.settlement_status
        end
    where id = v_fila.id;

    insert into public.merchant_payout_items (payout_id, settlement_id, amount_usd, currency, amount_cur)
    values (v_payout.id, v_fila.id, v_aplicado, v_fila.currency, v_aplicado_c);

    if v_fila.currency = 'EUR' then
      v_parte_eur := v_parte_eur + v_aplicado_c;
    else
      v_parte_usd := v_parte_usd + v_aplicado_c;
    end if;

    v_restante := v_restante - v_aplicado;
  end loop;

  -- Los bolívares: cada parte con la tasa BCV de su moneda del día del pago
  -- (o la escrita, si es una sola moneda).
  if p_method in ('pago_movil', 'transferencia') then
    v_fx := case when not v_hay_eur and p_fx_rate is not null then p_fx_rate
                 else public.current_fx_rate('BCV', v_paid_on) end;
    if v_parte_eur > 0 then
      v_fx_eur := case when not v_hay_usd and p_fx_rate is not null then p_fx_rate
                       else public.current_fx_rate('BCV_EUR', v_paid_on) end;
      if v_fx_eur is null then
        raise exception 'No hay tasa BCV del euro de ese día: cárgala en Ajustes › Tasa BCV'
          using errcode = '22023';
      end if;
    end if;
    v_ves := coalesce(p_amount_ves,
                      round(v_parte_usd * coalesce(v_fx, 0), 2) + round(v_parte_eur * coalesce(v_fx_eur, 0), 2));
  else
    v_fx  := p_fx_rate;
    v_ves := p_amount_ves;
  end if;

  -- Helios: la transferencia partida en consultas y comisiones del personal.
  select coalesce(sum(it.amount_usd) filter (where s.reason <> 'staff_commission'), 0),
         coalesce(sum(it.amount_usd) filter (where s.reason = 'staff_commission'), 0)
    into v_consultas, v_comisiones
  from public.merchant_payout_items it
  join public.settlements s on s.id = it.settlement_id
  where it.payout_id = v_payout.id;

  update public.merchant_payouts
     set consultas_usd = v_consultas, comisiones_usd = v_comisiones,
         amount_ves = v_ves, fx_rate = v_fx,
         amount_eur = nullif(v_parte_eur, 0), fx_rate_eur = v_fx_eur
   where id = v_payout.id;

  v_acct_pay  := ledger.get_or_create_account('merchant_payable', p_merchant_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'merchant_settlement', 'payout:' || v_payout.id::text, v_bdate, v_payout.id,
    format('Pago al comercio (%s liquidaciones)', v_count)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, v_total, 0),
    (v_tx, v_acct_cash, 0, v_total);

  perform audit.log(v_actor, 'merchant.payout', p_merchant_id,
    jsonb_build_object(
      'payout_id', v_payout.id, 'amount_usd', v_total,
      'consultas_usd', v_consultas, 'comisiones_usd', v_comisiones,
      'pending_usd', v_pendiente,
      'partial', v_total < v_pendiente - 0.005,
      'settlements', v_count, 'method', p_method, 'reference', p_reference,
      'paid_on', v_paid_on, 'amount_ves', v_ves, 'fx_rate', v_fx,
      'amount_eur', nullif(v_parte_eur, 0), 'fx_rate_eur', v_fx_eur,
      'has_receipt', p_receipt_path is not null,
      'note', v_note
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'pending_usd', v_pendiente, 'settlements', v_count,
    'consultas_usd', v_consultas, 'comisiones_usd', v_comisiones,
    'amount_ves', v_ves, 'fx_rate', v_fx,
    'amount_eur', nullif(v_parte_eur, 0), 'fx_rate_eur', v_fx_eur,
    'paid_on', v_paid_on
  );
end;
$$;

-- Lo que se le debe a una clínica, con la moneda de cada liquidación y lo que
-- son hoy en bolívares.
create or replace function public.admin_merchant_settlements(p_merchant_id uuid, p_run_date date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
  v_hoy  date := public.helios_business_date(now());
  v_usd  numeric := public.current_fx_rate('BCV', v_hoy);
  v_eur  numeric := public.current_fx_rate('BCV_EUR', v_hoy);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date, q.id), '[]'::jsonb)
  into v_rows
  from (
    select
      s.id,
      s.reason,
      s.status,
      s.amount_usd,
      s.paid_usd,
      s.amount_usd - s.paid_usd                          as pending_usd,
      s.currency,
      coalesce(s.amount_cur, s.amount_usd)               as amount_cur,
      s.paid_cur,
      coalesce(s.amount_cur, s.amount_usd) - s.paid_cur  as pending_cur,
      round((coalesce(s.amount_cur, s.amount_usd) - s.paid_cur)
            * case s.currency when 'EUR' then v_eur else v_usd end, 2) as pending_ves_hoy,
      coalesce(s.due_date, s.business_date)              as due_date,
      coalesce(s.due_date, s.business_date)
        <= v_hoy                                         as is_due,
      coalesce(s.due_date, s.business_date)
        < public.helios_next_settlement_run(now())        as in_next_run,
      public.helios_settlement_run_for(
        coalesce(s.due_date, s.business_date)
      )                                                  as run_date,
      c.id                                               as charge_id,
      c.order_number
    from public.settlements s
    left join public.charges c on c.id = s.charge_id
    where s.merchant_id = p_merchant_id
      and (
        case
          -- Un cierre concreto: lo que fue, pagado o no.
          when p_run_date is not null then
            public.helios_settlement_run_for(
              coalesce(s.due_date, s.business_date)
            ) = p_run_date
          -- Sin cierre: lo que se le debe hoy, de cualquier semana.
          else s.status in ('pending', 'partial')
        end
      )
  ) q;

  return v_rows;
end;
$$;

create or replace function public.admin_merchant_payouts(
  p_merchant_id uuid default null,
  p_from        date default null,
  p_to          date default null,
  p_method      text default null,
  p_limit       integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(
           jsonb_agg(to_jsonb(q) order by q.paid_on desc, q.created_at desc),
           '[]'::jsonb
         )
  into v_rows
  from (
    select
      p.id,
      p.merchant_id,
      m.name                             as merchant_name,
      m.is_test,
      coalesce(p.paid_on, p.business_date) as paid_on,
      p.business_date,
      p.created_at,
      p.amount_usd,
      p.consultas_usd,
      p.comisiones_usd,
      p.amount_ves,
      p.fx_rate,
      p.amount_eur,
      p.fx_rate_eur,
      p.method,
      p.reference,
      p.note,
      p.receipt_path is not null         as tiene_comprobante,
      pa.full_name                       as actor_name,
      coalesce(i.lineas, 0)::int         as lineas,
      i.primer_vencimiento,
      i.ultimo_vencimiento
    from public.merchant_payouts p
    join public.merchants m on m.id = p.merchant_id
    left join public.platform_admins pa on pa.user_id = p.paid_by
    left join lateral (
      select
        count(*)                                            as lineas,
        min(coalesce(s.due_date, s.business_date))          as primer_vencimiento,
        max(coalesce(s.due_date, s.business_date))          as ultimo_vencimiento
      from public.merchant_payout_items it
      join public.settlements s on s.id = it.settlement_id
      where it.payout_id = p.id
    ) i on true
    where (p_merchant_id is null or p.merchant_id = p_merchant_id)
      and (p_from is null or coalesce(p.paid_on, p.business_date) >= p_from)
      and (p_to   is null or coalesce(p.paid_on, p.business_date) <= p_to)
      and (p_method is null or p.method = p_method)
    order by coalesce(p.paid_on, p.business_date) desc, p.created_at desc
    limit least(coalesce(p_limit, 200), 500)
  ) q;

  return v_rows;
end;
$$;

create or replace function public.admin_payout_detail(p_payout_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_payout public.merchant_payouts%rowtype;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_payout from public.merchant_payouts where id = p_payout_id;

  if not found then
    raise exception 'No existe esa transferencia' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'id',             v_payout.id,
    'paid_on',        coalesce(v_payout.paid_on, v_payout.business_date),
    'business_date',  v_payout.business_date,
    'created_at',     v_payout.created_at,
    'amount_usd',     v_payout.amount_usd,
    'consultas_usd',  v_payout.consultas_usd,
    'comisiones_usd', v_payout.comisiones_usd,
    'amount_ves',     v_payout.amount_ves,
    'fx_rate',        v_payout.fx_rate,
    'amount_eur',     v_payout.amount_eur,
    'fx_rate_eur',    v_payout.fx_rate_eur,
    'method',         v_payout.method,
    'reference',      v_payout.reference,
    'note',           v_payout.note,
    'receipt_path',   v_payout.receipt_path,
    'actor_name',     (
      select pa.full_name from public.platform_admins pa
      where pa.user_id = v_payout.paid_by
    ),
    'merchant', (
      select jsonb_build_object(
        'id', m.id, 'name', m.name, 'tax_id', m.tax_id, 'is_test', m.is_test,
        'status', m.status::text
      )
      from public.merchants m where m.id = v_payout.merchant_id
    ),
    'items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'settlement_id',   s.id,
          'reason',          s.reason,
          'status',          s.status,
          'applied_usd',     it.amount_usd,
          'settlement_usd',  s.amount_usd,
          'paid_usd',        s.paid_usd,
          'pending_usd',     s.amount_usd - s.paid_usd,
          'currency',        it.currency,
          'applied_cur',     coalesce(it.amount_cur, it.amount_usd),
          'due_date',        coalesce(s.due_date, s.business_date),
          'run_date',        public.helios_settlement_run_for(
                               coalesce(s.due_date, s.business_date)),
          'charge_id',       c.id,
          'order_number',    c.order_number,
          'charge_date',     c.business_date,
          -- Helios: de quién es la comisión.
          'staff_user_id',   sc.staff_user_id,
          'staff_name',      case when sc.staff_user_id is not null
                                  then public.helios_staff_name(sc.staff_user_id) end
        )
        order by coalesce(s.due_date, s.business_date), s.id
      )
      from public.merchant_payout_items it
      join public.settlements s on s.id = it.settlement_id
      left join public.charges c on c.id = s.charge_id
      left join public.staff_commissions sc on sc.settlement_id = s.id
      where it.payout_id = v_payout.id
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. El superadmin: todo en dólares, y aparte en qué moneda se cobró
-- ---------------------------------------------------------------------------

create or replace function public.admin_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today    date := public.helios_business_date(now());
  v_charge   public.charges%rowtype;
  v_financed numeric(18,4);
  v_out      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'amount_usd', c.amount_usd,
    'financed_usd', v_financed,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', c.merchant_fee_usd,
    'merchant_fee_vat_usd', c.merchant_fee_vat_usd,
    'merchant_net_usd', c.merchant_net_usd,
    -- La moneda en la que cobró la clínica y lo cobrado en ella. Todo lo de
    -- arriba son dólares; esto es solo para saberlo.
    'currency', c.currency,
    'fx_usd_per_unit', c.fx_usd_per_unit,
    'amount_cur', c.amount_cur,
    'base_cur', c.base_cur,
    'consumer_fee_cur', c.consumer_fee_cur,
    'consumer_fee_vat_cur', c.consumer_fee_vat_cur,
    'is_group', c.group_id is not null,
    'group_id', c.group_id,
    'is_test', c.is_test,
    'merchant', jsonb_build_object(
      'id', m.id, 'name', m.name, 'legal_name', m.legal_name, 'tax_id', m.tax_id
    ),
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    'user', case when p.id is null then null else jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone_e164', p.phone_e164,
      'document_number', p.document_number, 'email', p.email
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'registered_by', c.requested_by,
    'registered_by_name', public.helios_staff_name(c.requested_by),
    'terms_version', (select t.version from public.terms_versions t where t.id = c.terms_version_id),
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission', (
      select jsonb_build_object(
        'id', sc.id,
        'amount_usd', sc.amount_usd,
        'staff_user_id', sc.staff_user_id,
        'staff_name', public.helios_staff_name(sc.staff_user_id),
        'status', sc.status,
        'settlement_id', sc.settlement_id,
        'created_at', sc.created_at
      )
      from public.staff_commissions sc where sc.charge_id = c.id
    )
  )
  into v_out
  from public.charges c
  join public.merchants m on m.id = c.merchant_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'user_id', i.user_id,
      'full_name', pi.full_name,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'financed_usd', i.financed_usd,
      'amount_cur', i.amount_cur,
      'due_date', i.due_date,
      'status', i.status::text,
      'paid_at', i.paid_at,
      'written_off_at', i.written_off_at,
      'days_overdue', case
        when i.status = 'paid' or i.written_off_at is not null then 0
        else greatest(v_today - i.due_date, 0)
      end
    ) order by pi.full_name nulls last, i.user_id, i.sequence)
    from public.installments i
    left join public.profiles pi on pi.id = i.user_id
    where i.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('split', coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', x.user_id,
      'full_name', pr.full_name,
      'phone_e164', pr.phone_e164,
      'financed_usd', x.financed_usd,
      'payable_usd', x.payable_usd,
      'installments_paid', x.paid,
      'installments_total', x.total,
      'started_it', x.user_id = v_charge.user_id,
      'reason', null
    ) order by x.payable_usd desc nulls last, pr.full_name nulls last)
    from (
      select i.user_id,
             sum(i.financed_usd)                                  as financed_usd,
             sum(i.amount_usd)                                    as payable_usd,
             count(*) filter (where i.status = 'paid')::integer    as paid,
             count(*)::integer                                     as total
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.user_id
    ) x
    join public.profiles pr on pr.id = x.user_id
  ), '[]'::jsonb));

  -- Los mensajes de este financiamiento (comprobante, bienvenida, avisos).
  v_out := v_out || jsonb_build_object('messages', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', o.id, 'channel', o.channel, 'template_key', o.template_key,
      'status', o.status, 'recipient', o.recipient, 'last_event', o.last_event,
      'created_at', o.created_at, 'sent_at', o.sent_at
    ) order by o.created_at)
    from public.outbound_messages o where o.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('group', null::jsonb);

  return v_out;
end;
$$;

-- La ficha del paciente: cada cuota y cada orden dicen además su moneda y su
-- monto en ella, para registrar su pago en bolívares con la tasa que toca. Se
-- añaden sobre la ficha de siempre (que se renombra y queda interna).
alter function public.admin_user_detail(uuid) rename to helios_admin_user_detail_base;
revoke all on function public.helios_admin_user_detail_base(uuid) from public, anon, authenticated;

create or replace function public.admin_user_detail(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_out jsonb := public.helios_admin_user_detail_base(p_user_id);
begin
  v_out := jsonb_set(v_out, '{installments}', coalesce((
    select jsonb_agg(x || jsonb_build_object(
             'currency', c.currency,
             'amount_cur', coalesce(i.amount_cur, i.amount_usd),
             'financed_cur', coalesce(i.financed_cur, i.financed_usd))
           order by o)
    from jsonb_array_elements(v_out->'installments') with ordinality as e(x, o)
    join public.installments i on i.id = (x->>'id')::uuid
    join public.charges c on c.id = i.charge_id
  ), '[]'::jsonb));

  v_out := jsonb_set(v_out, '{charges}', coalesce((
    select jsonb_agg(x || jsonb_build_object(
             'currency', c.currency,
             'amount_cur', c.amount_cur,
             'base_cur', c.base_cur)
           order by o)
    from jsonb_array_elements(v_out->'charges') with ordinality as e(x, o)
    join public.charges c on c.id = (x->>'id')::uuid
  ), '[]'::jsonb));

  return v_out;
end;
$$;

revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. El bot del médico: la moneda también por WhatsApp
-- ---------------------------------------------------------------------------

drop function if exists public.bot_preview_charge(text, text, numeric);

create or replace function public.bot_preview_charge(
  p_phone    text,
  p_document text,
  p_amount   numeric,
  p_currency text default 'USD'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
begin
  perform public.helios_bot_as(v_n.user_id);
  return public.preview_patient_charge(v_n.merchant_id, p_document, p_amount, p_currency);
end;
$$;

drop function if exists public.bot_create_charge(text, text, jsonb, numeric, text, text, text);

create or replace function public.bot_create_charge(
  p_phone            text,
  p_pin              text,
  p_patient          jsonb,
  p_amount           numeric,
  p_concept          text,
  p_beneficiary_name text,
  p_idempotency_key  text,
  p_currency         text default 'USD'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_pin jsonb;
begin
  v_pin := public.helios_bot_check_pin(v_n.user_id, p_pin);
  if not (v_pin->>'ok')::boolean then
    return v_pin;
  end if;

  perform public.helios_bot_as(v_n.user_id);
  return jsonb_build_object('ok', true, 'charge',
    public.create_patient_charge(v_n.merchant_id, null, p_patient, p_amount,
                                 p_concept, p_beneficiary_name, p_idempotency_key, p_currency));
end;
$$;

-- Los `bot_*` los llama solo el webhook, con la clave de servicio.
revoke all on function public.bot_preview_charge(text, text, numeric, text) from public, anon, authenticated;
revoke all on function public.bot_create_charge(text, text, jsonb, numeric, text, text, text, text) from public, anon, authenticated;
grant execute on function public.bot_preview_charge(text, text, numeric, text) to service_role;
grant execute on function public.bot_create_charge(text, text, jsonb, numeric, text, text, text, text) to service_role;
