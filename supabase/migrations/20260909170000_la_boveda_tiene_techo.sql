-- ============================================================================
-- Ronda — La bóveda tiene techo, y el umbral deja de moverse
--
-- ⚠️ Sigue siendo parte de la funcionalidad TEMPORAL del piloto (docs/07).
--
-- ---------------------------------------------------------------------------
-- El problema
-- ---------------------------------------------------------------------------
-- El umbral rojo se calculaba sobre **el saldo que dejó la última recarga**.
-- Eso lo dejaba atado al tamaño de cada depósito, y los depósitos no son
-- iguales:
--
--     recarga de 10.000 → el 10 % son 1.000
--     recarga de  2.000 → el 10 % son   200
--     recarga de    500 → el 10 % son    50
--
-- O sea que la línea roja se movía sola cada vez que se recargaba, y con
-- recargas pequeñas se volvía tan baja que la lista de espera no se encendía
-- hasta que la bóveda estaba prácticamente vacía. Nadie podía responder de
-- memoria a "¿cuánto es el 10 %?", que es justo la pregunta que hay que poder
-- contestar sin abrir el panel.
--
-- ---------------------------------------------------------------------------
-- La regla nueva
-- ---------------------------------------------------------------------------
-- La bóveda tiene un **techo pactado** —lo que se acuerda que llegará a tener,
-- 10.000 € por ejemplo— y el porcentaje se mide **siempre sobre ese techo**:
--
--     techo 10.000 · umbral 10 %  →  la lista se enciende al bajar de 1.000
--
-- Y ya no se mueve: da igual que se recargue de 500 en 500 o de 5.000 de
-- golpe. El umbral es una cifra en euros que se puede decir de memoria, que es
-- lo que hace que se pueda planificar cuánta gente entra.
--
-- El techo NO es un límite de depósito: se puede recargar por encima, y el
-- panel lo dice en vez de impedirlo. Es la referencia del cálculo, no una
-- barrera — poner una barrera ahí solo conseguiría que una noche buena
-- terminara con el saldo bloqueado por un tope administrativo.
--
-- Sin techo (`capacity_usd is null`) se mantiene el cálculo viejo, para que
-- una bóveda abierta antes de esto siga funcionando igual hasta que alguien le
-- ponga uno. `threshold_basis` dice cuál de los dos se está usando, para que el
-- panel lo explique en vez de que haya que adivinarlo.
-- ============================================================================

alter table public.merchant_vaults
  add column if not exists capacity_usd numeric(18,4)
  check (capacity_usd is null or capacity_usd > 0);

comment on column public.merchant_vaults.capacity_usd is
  'Techo pactado de la boveda. El umbral rojo se mide sobre esto, no sobre la ultima recarga, para que sea una cifra fija y predecible. Null = calculo viejo.';

-- ---------------------------------------------------------------------------
-- 1. El estado, con el techo dentro
-- ---------------------------------------------------------------------------
/**
 * 🔁 Cuerpo de 20260909151000. Cambia de dónde sale `reference_usd` y se
 * añaden tres campos: `capacity_usd`, `threshold_basis` y `headroom_usd`.
 *
 * `headroom_usd` —lo que le cabe hasta el techo— es la cifra que se mira al
 * decidir cuánto recargar, y con el saldo en negativo es mayor que el propio
 * techo, que es exactamente lo que hay que reponer.
 */
create or replace function public.merchant_vault_state(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_vault      public.merchant_vaults%rowtype;
  v_name       text;
  v_funded     numeric(18,4) := 0;
  v_topups     integer := 0;
  v_last_topup timestamptz;
  v_consumed   numeric(18,4) := 0;
  v_charges    integer := 0;
  v_before     numeric(18,4) := 0;
  v_balance    numeric(18,4);
  v_reference  numeric(18,4);
  v_basis      text;
  v_threshold  numeric(18,4);
  v_headroom   numeric(18,4);
  v_waiting    integer := 0;
  v_released   integer := 0;
begin
  select * into v_vault from public.merchant_vaults where merchant_id = p_merchant_id;
  if not found then
    return null;
  end if;

  select name into v_name from public.merchants where id = p_merchant_id;

  select coalesce(sum(amount_usd), 0), count(*), max(created_at)
    into v_funded, v_topups, v_last_topup
  from public.merchant_vault_topups
  where merchant_id = p_merchant_id;

  -- La BASE, no el total: el fee y su IVA no salen de la bóveda del local.
  -- En los cobros anteriores al desglose la base es nula y el total ERA la
  -- base (misma regla que `confirm_charge`).
  select coalesce(sum(coalesce(base_usd, amount_usd)), 0), count(*)
    into v_consumed, v_charges
  from public.charges
  where merchant_id = p_merchant_id
    and status = 'confirmed'
    and confirmed_at >= v_vault.opened_at;

  v_balance := v_funded - v_consumed;

  if v_vault.capacity_usd is not null then
    -- El techo pactado. Fijo: no lo mueve ninguna recarga.
    v_reference := v_vault.capacity_usd;
    v_basis     := 'capacity';
    v_headroom  := v_vault.capacity_usd - v_balance;
  else
    -- Cálculo viejo, para las bóvedas sin techo: lo que dejó la última
    -- recarga. Se conserva para no cambiarle la línea roja a nadie por debajo
    -- sin que alguien lo decida.
    select coalesce(sum(coalesce(base_usd, amount_usd)), 0)
      into v_before
    from public.charges
    where merchant_id = p_merchant_id
      and status = 'confirmed'
      and confirmed_at >= v_vault.opened_at
      and confirmed_at < coalesce(v_last_topup, v_vault.opened_at);

    v_reference := v_funded - v_before;
    v_basis     := 'last_topup';
    v_headroom  := null;
  end if;

  v_threshold := round(greatest(v_reference, 0) * v_vault.threshold_pct / 100, 2);

  select
    count(*) filter (where released_at is null),
    count(*) filter (where released_at is not null)
    into v_waiting, v_released
  from public.credit_waitlist
  where merchant_id = p_merchant_id;

  return jsonb_build_object(
    'merchant_id',             p_merchant_id,
    'merchant_name',           v_name,
    'is_active',               v_vault.is_active,
    'waitlist_auto_enroll',    v_vault.waitlist_auto_enroll,
    'waitlist_blocks_balance', v_vault.waitlist_blocks_balance,
    'threshold_pct',           v_vault.threshold_pct,
    'opened_at',               v_vault.opened_at,
    'note',                    v_vault.note,
    'funded_usd',              v_funded,
    'topup_count',             v_topups,
    'last_topup_at',           v_last_topup,
    'consumed_usd',            v_consumed,
    'charge_count',            v_charges,
    'balance_usd',             v_balance,
    -- NUEVO: el techo, de dónde sale el umbral y lo que cabe hasta llenarlo.
    'capacity_usd',            v_vault.capacity_usd,
    'threshold_basis',         v_basis,
    'headroom_usd',            v_headroom,
    'reference_usd',           v_reference,
    'threshold_usd',           v_threshold,
    -- "Llega al 10 %": en el umbral o por debajo. Sin ninguna recarga todo
    -- vale 0 y esto es cierto: sin garantía no hay saldo que prometer.
    'below_threshold',         (v_balance <= v_threshold),
    'waiting_count',           v_waiting,
    'released_count',          v_released
  );
end;
$$;

revoke all on function public.merchant_vault_state(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El techo se fija desde el panel
-- ---------------------------------------------------------------------------
-- La firma cambia, así que la vieja se tira: si conviven, un panel sin
-- actualizar seguiría llamando a la de cinco argumentos y borraría el techo
-- sin decirlo. Mejor que falle a que mienta.
drop function if exists public.admin_set_vault(uuid, boolean, boolean, boolean, numeric, text);

/**
 * 🔁 Cuerpo de 20260909151000 más `p_capacity_usd`.
 *
 * Null lo BORRA, y es a propósito: quitar el techo es una decisión legítima
 * —volver al cálculo por recarga— y tiene que poder tomarse desde la misma
 * pantalla que lo puso. Queda en la bitácora igual que el resto.
 */
create or replace function public.admin_set_vault(
  p_merchant_id             uuid,
  p_is_active               boolean,
  p_waitlist_auto_enroll    boolean,
  p_waitlist_blocks_balance boolean,
  p_threshold_pct           numeric,
  p_capacity_usd            numeric default null,
  p_note                    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('configurar la bóveda');
  v_before jsonb;
begin
  if not exists (select 1 from public.merchants where id = p_merchant_id) then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  if p_threshold_pct is null or p_threshold_pct < 0 or p_threshold_pct > 100 then
    raise exception 'El umbral es un porcentaje entre 0 y 100' using errcode = '22023';
  end if;

  if p_capacity_usd is not null and p_capacity_usd <= 0 then
    raise exception 'El techo de la bóveda tiene que ser mayor que cero' using errcode = '22023';
  end if;

  v_before := public.merchant_vault_state(p_merchant_id);

  insert into public.merchant_vaults as v
    (merchant_id, is_active, waitlist_auto_enroll, waitlist_blocks_balance,
     threshold_pct, capacity_usd, note)
  values
    (p_merchant_id, p_is_active, p_waitlist_auto_enroll, p_waitlist_blocks_balance,
     p_threshold_pct, round(p_capacity_usd, 2), nullif(trim(coalesce(p_note, '')), ''))
  on conflict (merchant_id) do update set
    is_active               = excluded.is_active,
    waitlist_auto_enroll    = excluded.waitlist_auto_enroll,
    waitlist_blocks_balance = excluded.waitlist_blocks_balance,
    threshold_pct           = excluded.threshold_pct,
    -- Sin `coalesce`: null aquí significa "quítale el techo", no "déjalo como
    -- estaba". Es la única forma de volver al cálculo por recarga.
    capacity_usd            = excluded.capacity_usd,
    note                    = coalesce(excluded.note, v.note),
    updated_at              = now();

  perform audit.log(v_actor, 'vault.configured', p_merchant_id, jsonb_build_object(
    'before', case when v_before is null then null else jsonb_build_object(
      'is_active', v_before->'is_active',
      'waitlist_auto_enroll', v_before->'waitlist_auto_enroll',
      'waitlist_blocks_balance', v_before->'waitlist_blocks_balance',
      'threshold_pct', v_before->'threshold_pct',
      'capacity_usd', v_before->'capacity_usd'
    ) end,
    'after', jsonb_build_object(
      'is_active', p_is_active,
      'waitlist_auto_enroll', p_waitlist_auto_enroll,
      'waitlist_blocks_balance', p_waitlist_blocks_balance,
      'threshold_pct', p_threshold_pct,
      'capacity_usd', round(p_capacity_usd, 2)
    ),
    'note', p_note
  ));

  return public.merchant_vault_state(p_merchant_id);
end;
$$;

revoke all on function
  public.admin_set_vault(uuid, boolean, boolean, boolean, numeric, numeric, text)
  from public, anon;
grant execute on function
  public.admin_set_vault(uuid, boolean, boolean, boolean, numeric, numeric, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que ve el comercio
-- ---------------------------------------------------------------------------
/**
 * 🔁 Cuerpo de 20260909151000 con dos campos más.
 *
 * Al local se le dice el techo y lo que cabe: es lo que hace que su tarjeta
 * responda "¿cuánto va a poner Ronda aquí?" sin tener que preguntarlo. Los
 * interruptores de la lista de espera siguen sin salir — eso es cosa nuestra.
 */
create or replace function public.my_merchant_vault()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_state    jsonb;
  v_topups   jsonb;
begin
  if v_merchant is null then
    return null;
  end if;

  v_state := public.merchant_vault_state(v_merchant);
  if v_state is null or not (v_state->>'is_active')::boolean then
    return null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id,
      'amount_usd', t.amount_usd,
      'note', t.note,
      'created_at', t.created_at
    ) order by t.created_at desc), '[]'::jsonb)
    into v_topups
  from (
    select * from public.merchant_vault_topups
    where merchant_id = v_merchant
    order by created_at desc
    limit 20
  ) t;

  return jsonb_build_object(
    'funded_usd',      v_state->'funded_usd',
    'consumed_usd',    v_state->'consumed_usd',
    'balance_usd',     v_state->'balance_usd',
    'capacity_usd',    v_state->'capacity_usd',
    'headroom_usd',    v_state->'headroom_usd',
    'reference_usd',   v_state->'reference_usd',
    'threshold_pct',   v_state->'threshold_pct',
    'threshold_usd',   v_state->'threshold_usd',
    'below_threshold', v_state->'below_threshold',
    'charge_count',    v_state->'charge_count',
    'opened_at',       v_state->'opened_at',
    'last_topup_at',   v_state->'last_topup_at',
    'topups',          v_topups
  );
end;
$$;

revoke all on function public.my_merchant_vault() from public, anon;
grant execute on function public.my_merchant_vault() to authenticated;
