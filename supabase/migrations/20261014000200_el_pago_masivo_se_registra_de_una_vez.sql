-- ============================================================================
-- Helios — El pago masivo se registra de una vez
--
-- Hasta ahora bajar el archivo del banco no registraba nada y cada
-- transferencia se registraba a mano, clínica por clínica. Ahora (diseño A,
-- Javier, 2026-10-14):
--
-- 1. **Bajar el archivo guarda el lote** (`admin_create_bulk_payout`): la
--    fecha de pago, la cuenta debitada, las tasas y, por clínica, las
--    liquidaciones exactas que iban en su fila, sus dólares, sus bolívares y
--    la referencia del cliente (MMDD + fila). Antes de guardarlo se comprueba
--    que los bolívares que manda el panel son los que la base calcula hoy: si
--    algo cambió desde que se abrió la ventana, no se guarda.
--
-- 2. **Registrar el pago masivo** (`admin_register_bulk_payout`), cuando el
--    banco lo procesó: una transferencia por cada línea marcada, en UNA sola
--    transacción, con `admin_report_merchant_payout` (método
--    `transferencia`, fecha de pago del archivo, los bolívares del archivo y
--    la referencia del cliente o la que dé el banco). Las tasas del pago son
--    las del archivo. Una línea ya registrada no se vuelve a registrar
--    (idempotencia: la línea guarda su `payout_id` y se bloquea al
--    registrarla). Una línea cuyas liquidaciones se pagaron por otro lado
--    desde que se bajó el archivo no se registra: hay que desmarcarla.
--
-- 3. **La lectura** (`admin_bulk_payouts`): los últimos lotes con el estado
--    de cada línea (`pendiente`, `registrada`, `cambio`).
--
-- Las tablas no se leen directamente: solo por estas RPC.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------

create table public.bulk_payouts (
  id             uuid primary key default gen_random_uuid(),
  -- La fecha de pago del archivo (columna A): el día en que el banco paga.
  pay_date       date not null,
  description    text not null check (btrim(description) <> '' and length(description) <= 60),
  debit_account  text not null check (debit_account ~ '^[0-9]{20}$'),
  -- Las tasas BCV del día en que se armó: las de los bolívares del archivo.
  fx_rate_usd    numeric(18,6),
  fx_rate_eur    numeric(18,6),
  business_date  date not null,
  total_usd      numeric(18,4) not null,
  total_ves      numeric(18,2) not null,
  created_by     uuid references auth.users(id),
  created_at     timestamptz not null default now()
);

comment on table public.bulk_payouts is
  'Un archivo de pago masivo del banco, tal como se bajó. Sus líneas en bulk_payout_lines.';

create index bulk_payouts_created_idx on public.bulk_payouts (created_at desc);

create table public.bulk_payout_lines (
  id                  uuid primary key default gen_random_uuid(),
  bulk_payout_id      uuid not null references public.bulk_payouts(id) on delete cascade,
  -- La fila del archivo (1 = la primera transferencia).
  row_number          integer not null check (row_number > 0),
  merchant_id         uuid not null references public.merchants(id),
  -- Las liquidaciones que pagaba la fila, y lo que faltaba de ellas.
  settlement_ids      uuid[] not null check (cardinality(settlement_ids) > 0),
  amount_usd          numeric(18,4) not null check (amount_usd > 0),
  -- De eso, lo de órdenes en dólares y lo de órdenes en euros, cada uno en su moneda.
  amount_usd_part     numeric(18,4) not null default 0,
  amount_eur          numeric(18,4) not null default 0,
  amount_ves          numeric(18,2) not null check (amount_ves > 0),
  -- La referencia del cliente (columna I): MMDD + número de fila.
  reference           text not null check (reference ~ '^[0-9]{1,10}$'),
  beneficiary_account text not null check (beneficiary_account ~ '^[0-9]{20}$'),
  beneficiary_id      text not null,
  beneficiary_name    text not null,
  -- La transferencia registrada. Null = todavía no.
  payout_id           uuid unique references public.merchant_payouts(id),
  registered_at       timestamptz,
  registered_by       uuid references auth.users(id),
  unique (bulk_payout_id, row_number),
  unique (bulk_payout_id, merchant_id),
  unique (bulk_payout_id, reference)
);

comment on table public.bulk_payout_lines is
  'Una fila del archivo de pago masivo: la transferencia a una clínica, con sus liquidaciones exactas. payout_id cuando se registra.';

create index bulk_payout_lines_merchant_idx on public.bulk_payout_lines (merchant_id);

alter table public.bulk_payouts enable row level security;
alter table public.bulk_payout_lines enable row level security;
revoke all on public.bulk_payouts, public.bulk_payout_lines from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Lo que sale hoy de una clínica
-- ---------------------------------------------------------------------------
-- Lo mismo que `admin_bulk_payout_sheet` da por clínica, con los ids de las
-- liquidaciones: lo pendiente que vence antes del pago de hoy. Los bolívares,
-- cada moneda a su tasa redondeada al céntimo y sumadas; null si falta una.

create or replace function public.helios_bulk_payout_due(
  p_merchant_id uuid,
  p_corte       date,
  p_usd         numeric,
  p_eur         numeric
)
returns table (
  settlement_ids   uuid[],
  pending_usd      numeric,
  pending_usd_part numeric,
  pending_eur      numeric,
  pending_ves      numeric
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    l.ids,
    l.pending_usd,
    l.pending_usd_part,
    l.pending_eur,
    case
      when (l.pending_usd_part > 0 and p_usd is null)
        or (l.pending_eur > 0 and p_eur is null) then null
      else coalesce(round(l.pending_usd_part * p_usd, 2), 0)
         + coalesce(round(l.pending_eur * p_eur, 2), 0)
    end
  from (
    select
      array_agg(s.id order by coalesce(s.due_date, s.business_date), s.id) as ids,
      coalesce(sum(s.amount_usd - s.paid_usd), 0)                          as pending_usd,
      coalesce(sum(coalesce(s.amount_cur, s.amount_usd) - s.paid_cur)
                 filter (where s.currency is distinct from 'EUR'), 0)      as pending_usd_part,
      coalesce(sum(coalesce(s.amount_cur, s.amount_usd) - s.paid_cur)
                 filter (where s.currency = 'EUR'), 0)                     as pending_eur
    from public.settlements s
    where s.merchant_id = p_merchant_id
      and s.status in ('pending', 'partial')
      and coalesce(s.due_date, s.business_date) < p_corte
  ) l;
$$;

revoke all on function public.helios_bulk_payout_due(uuid, date, numeric, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Bajar el archivo guarda el lote
-- ---------------------------------------------------------------------------
-- `p_lines`: las filas del archivo en orden, cada una
--   { merchant_id, reference, amount_ves,
--     beneficiary_account, beneficiary_id, beneficiary_name }.

create or replace function public.admin_create_bulk_payout(
  p_pay_date      date,
  p_description   text,
  p_debit_account text,
  p_lines         jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid;
  v_hoy    date    := public.helios_business_date(now());
  v_corte  date    := public.helios_next_settlement_run(now());
  v_usd    numeric := public.current_fx_rate('BCV', v_hoy);
  v_eur    numeric := public.current_fx_rate('BCV_EUR', v_hoy);
  v_desc   text    := btrim(coalesce(p_description, ''));
  v_lote   uuid;
  v_linea  record;
  v_clin   record;
  v_due    record;
  v_ves    numeric;
  v_ref    text;
  v_n      integer := 0;
  v_tusd   numeric(18,4) := 0;
  v_tves   numeric(18,2) := 0;
begin
  v_actor := public.helios_assert_super_admin('armar el pago masivo');

  if p_pay_date is null or p_pay_date < v_hoy then
    raise exception 'El banco no acepta una fecha de pago anterior a hoy' using errcode = '22023';
  end if;
  if v_desc = '' or length(v_desc) > 60 then
    raise exception 'La descripción va de 1 a 60 caracteres' using errcode = '22023';
  end if;
  if coalesce(p_debit_account, '') !~ '^[0-9]{20}$' then
    raise exception 'La cuenta a debitar tiene 20 dígitos' using errcode = '22023';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'El archivo no lleva ninguna transferencia' using errcode = '22023';
  end if;

  insert into public.bulk_payouts
    (pay_date, description, debit_account, fx_rate_usd, fx_rate_eur, business_date,
     total_usd, total_ves, created_by)
  values
    (p_pay_date, v_desc, p_debit_account, v_usd, v_eur, v_hoy, 0, 0, v_actor)
  returning id into v_lote;

  for v_linea in
    select e.value as l, e.ordinality::int as fila
    from jsonb_array_elements(p_lines) with ordinality e
  loop
    select m.id, m.name, m.is_test into v_clin
    from public.merchants m
    where m.id = (v_linea.l->>'merchant_id')::uuid;

    if v_clin.id is null then
      raise exception 'La fila % no es de ninguna clínica', v_linea.fila using errcode = '22023';
    end if;
    if v_clin.is_test then
      raise exception '% es de prueba: no se le transfiere', v_clin.name using errcode = '22023';
    end if;

    select * into v_due
    from public.helios_bulk_payout_due(v_clin.id, v_corte, v_usd, v_eur);

    v_ves := nullif(v_linea.l->>'amount_ves', '')::numeric;

    if v_due.settlement_ids is null or v_due.pending_usd <= 0.005 then
      raise exception 'A % ya no se le debe nada hoy: cierra la ventana y vuelve a abrirla', v_clin.name
        using errcode = '22023';
    end if;
    if v_due.pending_ves is null then
      raise exception 'Falta la tasa BCV de hoy para pasar a bolívares lo de %', v_clin.name
        using errcode = '22023';
    end if;
    if v_ves is null or abs(v_ves - v_due.pending_ves) > 0.005 then
      raise exception 'Lo que se le debe a % cambió desde que abriste la ventana (ahora son Bs %): ciérrala y vuelve a abrirla',
        v_clin.name, v_due.pending_ves using errcode = '22023';
    end if;

    v_ref := btrim(coalesce(v_linea.l->>'reference', ''));
    if v_ref !~ '^[0-9]{1,10}$' then
      raise exception 'La referencia de % tiene que ser un número de hasta 10 dígitos', v_clin.name
        using errcode = '22023';
    end if;
    if coalesce(v_linea.l->>'beneficiary_account', '') !~ '^[0-9]{20}$' then
      raise exception 'La cuenta de % no tiene 20 dígitos', v_clin.name using errcode = '22023';
    end if;
    if coalesce(v_linea.l->>'beneficiary_id', '') !~ '^[VEJG][0-9]{1,9}$' then
      raise exception 'El banco no acepta el documento del titular de %', v_clin.name using errcode = '22023';
    end if;
    if btrim(coalesce(v_linea.l->>'beneficiary_name', '')) = '' then
      raise exception 'Falta el titular de la cuenta de %', v_clin.name using errcode = '22023';
    end if;

    begin
      insert into public.bulk_payout_lines
        (bulk_payout_id, row_number, merchant_id, settlement_ids, amount_usd,
         amount_usd_part, amount_eur, amount_ves, reference,
         beneficiary_account, beneficiary_id, beneficiary_name)
      values
        (v_lote, v_linea.fila, v_clin.id, v_due.settlement_ids, v_due.pending_usd,
         v_due.pending_usd_part, v_due.pending_eur, v_due.pending_ves, v_ref,
         v_linea.l->>'beneficiary_account', v_linea.l->>'beneficiary_id',
         left(btrim(v_linea.l->>'beneficiary_name'), 80));
    exception when unique_violation then
      raise exception '% va dos veces en el archivo, o se repite una referencia', v_clin.name
        using errcode = '22023';
    end;

    v_n    := v_n + 1;
    v_tusd := v_tusd + v_due.pending_usd;
    v_tves := v_tves + v_due.pending_ves;
  end loop;

  update public.bulk_payouts set total_usd = v_tusd, total_ves = v_tves where id = v_lote;

  perform audit.log(v_actor, 'merchant.bulk_payout_file', v_lote,
    jsonb_build_object(
      'pay_date', p_pay_date, 'description', v_desc,
      'lines', v_n, 'total_usd', v_tusd, 'total_ves', v_tves,
      'fx_rate_usd', v_usd, 'fx_rate_eur', v_eur
    ));

  return jsonb_build_object(
    'ok', true, 'bulk_payout_id', v_lote,
    'lines', v_n, 'total_usd', v_tusd, 'total_ves', v_tves
  );
end;
$$;

revoke all on function public.admin_create_bulk_payout(date, text, text, jsonb) from public, anon;
grant execute on function public.admin_create_bulk_payout(date, text, text, jsonb) to authenticated;

comment on function public.admin_create_bulk_payout(date, text, text, jsonb) is
  'Guarda el archivo de pago masivo que se baja: sus filas con las liquidaciones exactas y los bolívares. Solo super admin.';

-- ---------------------------------------------------------------------------
-- 4. El estado de una línea
-- ---------------------------------------------------------------------------
-- `registrada`: ya tiene su transferencia. `pendiente`: sus liquidaciones
-- siguen sin pagar y deben lo mismo que cuando se bajó el archivo, así que se
-- puede registrar. `cambio`: algo de ellas se pagó por otro lado.

create or replace function public.helios_bulk_payout_line_state(p_line public.bulk_payout_lines)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when p_line.payout_id is not null then 'registrada'
    when (
      select count(*) = cardinality(p_line.settlement_ids)
         and abs(coalesce(sum(s.amount_usd - s.paid_usd), 0) - p_line.amount_usd) <= 0.005
      from public.settlements s
      where s.id = any(p_line.settlement_ids)
        and s.merchant_id = p_line.merchant_id
        and s.status in ('pending', 'partial')
    ) then 'pendiente'
    else 'cambio'
  end;
$$;

revoke all on function public.helios_bulk_payout_line_state(public.bulk_payout_lines) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Los últimos archivos
-- ---------------------------------------------------------------------------

create or replace function public.admin_bulk_payouts(p_limit integer default 10)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_out jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc), '[]'::jsonb)
  into v_out
  from (
    select
      b.id,
      b.pay_date,
      b.description,
      b.debit_account,
      b.fx_rate_usd,
      b.fx_rate_eur,
      b.business_date,
      b.total_usd,
      b.total_ves,
      b.created_at,
      pa.full_name as created_by_name,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id',                  l.id,
                 'row_number',          l.row_number,
                 'merchant_id',         l.merchant_id,
                 'merchant_name',       m.name,
                 'settlements',         cardinality(l.settlement_ids),
                 'amount_usd',          l.amount_usd,
                 'amount_usd_part',     l.amount_usd_part,
                 'amount_eur',          l.amount_eur,
                 'amount_ves',          l.amount_ves,
                 'reference',           l.reference,
                 'beneficiary_account', l.beneficiary_account,
                 'beneficiary_id',      l.beneficiary_id,
                 'beneficiary_name',    l.beneficiary_name,
                 'state',               public.helios_bulk_payout_line_state(l),
                 'payout_id',           l.payout_id,
                 'payout_reference',    p.reference,
                 'registered_at',       l.registered_at
               ) order by l.row_number), '[]'::jsonb)
        from public.bulk_payout_lines l
        join public.merchants m on m.id = l.merchant_id
        left join public.merchant_payouts p on p.id = l.payout_id
        where l.bulk_payout_id = b.id
      ) as lines
    from public.bulk_payouts b
    left join public.platform_admins pa on pa.user_id = b.created_by
    order by b.created_at desc
    limit greatest(1, least(coalesce(p_limit, 10), 50))
  ) q;

  return v_out;
end;
$$;

revoke all on function public.admin_bulk_payouts(integer) from public, anon;
grant execute on function public.admin_bulk_payouts(integer) to authenticated;

comment on function public.admin_bulk_payouts(integer) is
  'Los últimos archivos de pago masivo con el estado de cada línea (pendiente, registrada, cambio). Solo el equipo.';

-- ---------------------------------------------------------------------------
-- 6. Registrar el pago masivo
-- ---------------------------------------------------------------------------
-- `p_lines`: las líneas que el banco pagó, cada una { line_id, reference? }.
-- Sin `reference` va la del cliente del archivo. Todo o nada: si una línea no
-- se puede registrar, no se registra ninguna.

create or replace function public.admin_register_bulk_payout(
  p_bulk_payout_id uuid,
  p_lines          jsonb,
  p_note           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor     uuid;
  v_hoy       date := public.helios_business_date(now());
  v_lote      public.bulk_payouts%rowtype;
  v_linea     public.bulk_payout_lines%rowtype;
  v_pedida    record;
  v_nombre    text;
  v_ref       text;
  v_estado    text;
  v_res       jsonb;
  v_payout    uuid;
  v_note      text := nullif(btrim(coalesce(p_note, '')), '');
  v_hechas    jsonb := '[]'::jsonb;
  v_ya        integer := 0;
  v_tusd      numeric(18,4) := 0;
  v_tves      numeric(18,2) := 0;
begin
  v_actor := public.helios_assert_super_admin('registrar el pago masivo');

  -- El lote bloqueado: dos registros del mismo archivo a la vez van en fila.
  select * into v_lote from public.bulk_payouts where id = p_bulk_payout_id for update;
  if v_lote.id is null then
    raise exception 'No existe ese archivo de pago masivo' using errcode = '22023';
  end if;

  if v_lote.pay_date > v_hoy then
    raise exception 'El banco paga este archivo el %: regístralo ese día o después', to_char(v_lote.pay_date, 'DD/MM/YYYY')
      using errcode = '22023';
  end if;

  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Marca al menos una transferencia' using errcode = '22023';
  end if;

  -- En el orden del archivo; una marcada que no es de él, la primera.
  for v_pedida in
    select q.id, q.ref
    from (
      select distinct on (l.id) l.id, l.row_number, nullif(btrim(e.value->>'reference'), '') as ref
      from jsonb_array_elements(p_lines) e
      left join public.bulk_payout_lines l
        on l.id = nullif(e.value->>'line_id', '')::uuid and l.bulk_payout_id = v_lote.id
      order by l.id
    ) q
    order by q.row_number nulls first
  loop
    if v_pedida.id is null then
      raise exception 'Alguna transferencia marcada no es de este archivo' using errcode = '22023';
    end if;

    select * into v_linea from public.bulk_payout_lines where id = v_pedida.id for update;
    select name into v_nombre from public.merchants where id = v_linea.merchant_id;

    -- Ya registrada: no se repite.
    if v_linea.payout_id is not null then
      v_ya := v_ya + 1;
      continue;
    end if;

    -- Las liquidaciones, bloqueadas antes de mirar si siguen igual.
    perform 1 from public.settlements where id = any(v_linea.settlement_ids) for update;
    v_estado := public.helios_bulk_payout_line_state(v_linea);
    if v_estado <> 'pendiente' then
      raise exception 'Lo de % se pagó por otro lado desde que se bajó el archivo: desmárcala y revísala en su página',
        v_nombre using errcode = '22023';
    end if;

    v_ref := coalesce(v_pedida.ref, v_linea.reference);
    if length(v_ref) > 64 then
      raise exception 'La referencia de % es demasiado larga', v_nombre using errcode = '22023';
    end if;

    v_res := public.admin_report_merchant_payout(
      p_merchant_id    => v_linea.merchant_id,
      p_settlement_ids => v_linea.settlement_ids,
      p_method         => 'transferencia',
      p_reference      => v_ref,
      p_amount_ves     => v_linea.amount_ves,
      p_fx_rate        => null,
      p_note           => coalesce(v_note, v_lote.description),
      p_amount_usd     => v_linea.amount_usd,
      p_paid_on        => v_lote.pay_date,
      p_receipt_path   => null
    );
    v_payout := (v_res->>'payout_id')::uuid;

    -- Las tasas del pago son las del archivo: con ellas se calcularon sus bolívares.
    update public.merchant_payouts
       set fx_rate     = v_lote.fx_rate_usd,
           fx_rate_eur = case when amount_eur is not null then v_lote.fx_rate_eur end
     where id = v_payout;

    update public.bulk_payout_lines
       set payout_id = v_payout, registered_at = now(), registered_by = v_actor
     where id = v_linea.id;

    v_hechas := v_hechas || jsonb_build_object(
      'line_id', v_linea.id, 'merchant_id', v_linea.merchant_id,
      'payout_id', v_payout, 'reference', v_ref,
      'amount_usd', v_linea.amount_usd, 'amount_ves', v_linea.amount_ves);
    v_tusd := v_tusd + v_linea.amount_usd;
    v_tves := v_tves + v_linea.amount_ves;
  end loop;

  perform audit.log(v_actor, 'merchant.bulk_payout', v_lote.id,
    jsonb_build_object(
      'pay_date', v_lote.pay_date,
      'registered', jsonb_array_length(v_hechas),
      'already_registered', v_ya,
      'total_usd', v_tusd, 'total_ves', v_tves,
      'payouts', v_hechas,
      'note', v_note
    ));

  return jsonb_build_object(
    'ok', true,
    'registered', jsonb_array_length(v_hechas),
    'already_registered', v_ya,
    'total_usd', v_tusd,
    'total_ves', v_tves,
    'payouts', v_hechas
  );
end;
$$;

revoke all on function public.admin_register_bulk_payout(uuid, jsonb, text) from public, anon;
grant execute on function public.admin_register_bulk_payout(uuid, jsonb, text) to authenticated;

comment on function public.admin_register_bulk_payout(uuid, jsonb, text) is
  'Registra de una vez las transferencias de un archivo de pago masivo que el banco procesó, en una transacción. Una línea ya registrada no se repite. Solo super admin.';
