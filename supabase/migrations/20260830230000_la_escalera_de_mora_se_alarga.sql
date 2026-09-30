-- ============================================================================
-- Ronda — La escalera de mora se alarga: 30 días baja de nivel, 60 expulsan
--
-- Decisión del 2026-08-30. Los tramos se duplican:
--
--   | Retraso            | Antes            | Ahora            |
--   |--------------------|------------------|------------------|
--   | Día 1              | Saldo congelado  | Saldo congelado  |
--   | Pasados 2 días     | $4 de cargo      | $4 de cargo      |
--   | 15 días            | Baja de nivel    | —                |
--   | **30 días**        | Expulsión        | **Baja de nivel**|
--   | **60 días (2 meses)** | —             | **Expulsión**    |
--
-- **La consecuencia dura es el castigo contable.** `charge_off_user_debt` corre
-- con la expulsión, así que la deuda incobrable pasa a reconocerse a los DOS
-- MESES y no al mes. Durante ese mes extra la cartera vencida sigue contando
-- como cobrable en el resumen del super admin, y el P&L la ve más tarde. No es
-- un fallo —dar más margen antes de expulsar es justo lo que se pidió— pero hay
-- que saber que el número de "mora" del panel se vuelve más lento en reaccionar.
--
-- Los umbrales pasan a ser funciones y no números sueltos, por lo mismo que el
-- plazo de las cuotas: son parámetros de negocio y hoy queda demostrado que
-- cambian. Estaban escritos a mano en `recompute_profile_mora_state` y otra vez
-- en los tramos del resumen del super admin, y esos dos ya se habían
-- desincronizado antes.
--
-- ---------------------------------------------------------------------------
-- De paso, dos cosas de `level_standing` que tocan lo mismo
-- ---------------------------------------------------------------------------
-- 1. **El enfriamiento lee los dos motivos.** Las bajadas viejas quedaron con
--    `mora_15d` y las nuevas llevan `mora_demotion` (20260830210000). Leer solo
--    el nuevo habría dejado a quien bajó ayer sin enfriamiento ninguno.
--
-- 2. **El gasto que cuenta para subir es el CONSUMO, no lo pagado con fee.**
--    Se sumaba `installments.amount_usd`, que desde 20260830190000 lleva dentro
--    nuestra comisión: alguien llegaba al requisito de $200 un 11,6% antes
--    gracias a un fee que no es suyo. Ahora suma `financed_usd`.
--
--    ⚠️ Lo que NO hacía falta cambiar: **ya contaba solo tu parte** de un
--    consumo de grupo. Las cuotas son por persona —un cobro de mesa genera N
--    planes independientes (docs/00-BASES §2.7)— así que `where user_id = ...`
--    nunca vio el total del grupo. Se deja dicho aquí porque es justo lo que
--    parecía roto desde fuera.
--
-- ---------------------------------------------------------------------------
-- Cómo se recupera el nivel perdido (decidido el 2026-08-30)
-- ---------------------------------------------------------------------------
-- **Con enfriamiento, y vuelve solo.** Los requisitos son acumulados de por
-- vida, así que quien baja los sigue cumpliendo: no hay nada que volver a
-- ganarse. Lo que frena la vuelta son dos cosas, y las dos ya existían — tener
-- la cuenta al día (`account_status = 'active'`) y el enfriamiento de 60 días
-- desde la bajada. Se mantiene en 60: la bajada ahora cuesta 30 días de mora en
-- vez de 15, así que el castigo ya se endureció por el otro lado.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los umbrales
-- ---------------------------------------------------------------------------

/** Días de retraso a partir de los cuales se baja un nivel. */
create or replace function public.helios_mora_demotion_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 30 $fn$;

comment on function public.helios_mora_demotion_days() is
  'Dias de retraso que cuestan un nivel. Ver docs/00-BASES 2.4.';

revoke all on function public.helios_mora_demotion_days() from public, anon;
grant execute on function public.helios_mora_demotion_days() to authenticated;

/** Días de retraso a partir de los cuales se expulsa y se castiga la deuda. */
create or replace function public.helios_mora_expulsion_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 60 $fn$;

comment on function public.helios_mora_expulsion_days() is
  'Dias de retraso que cuestan la cuenta, y con ella el castigo contable de la deuda. Ver docs/00-BASES 2.4.';

revoke all on function public.helios_mora_expulsion_days() from public, anon;
grant execute on function public.helios_mora_expulsion_days() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. El motor de mora
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260830170000 salvo los bloques marcados NUEVO.
create or replace function public.recompute_profile_mora_state(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status       public.profile_status;
  v_level        smallint;
  v_new_level    smallint;
  v_max_days_late integer;
begin
  select status, level into v_status, v_level
  from public.profiles where id = p_user_id for update;

  if not found or v_status = 'expelled' then
    -- Terminal: requiere revisión manual del super admin (D-10, sin decidir).
    return;
  end if;

  select coalesce(max(public.helios_business_date(now()) - i.due_date), 0)
    into v_max_days_late
  from public.installments i
  where i.user_id = p_user_id
    and i.status = 'pending'
    and i.due_date < public.helios_business_date(now());

  if v_max_days_late <= 0 then
    -- Sin mora. Si venía bloqueado, se restablece el acceso — pero el nivel
    -- perdido no se recupera solo aquí: eso lo hace `evaluate_level` cuando
    -- pasa el enfriamiento.
    if v_status in ('frozen', 'suspended') then
      update public.profiles set status = 'active', updated_at = now() where id = p_user_id;
    end if;
    return;
  end if;

  -- El cargo por mora, pasada la gracia. No toca el estado ni depende de él:
  -- `charge_late_fee` se encarga de que solo prenda una vez por episodio.
  if v_max_days_late > public.helios_late_fee_grace_days() then
    perform public.charge_late_fee(p_user_id, v_max_days_late);
  end if;

  -- ── NUEVO: los umbrales salen de los parámetros ──────────────────────────
  if v_max_days_late > public.helios_mora_expulsion_days() then
    if v_status <> 'expelled' then
      update public.profiles
        set status = 'expelled', is_blacklisted = true, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_level, 'expelled');

      perform public.charge_off_user_debt(p_user_id);
    end if;
    return;
  end if;

  if v_max_days_late >= public.helios_mora_demotion_days() then
    if v_status <> 'suspended' then
      v_new_level := greatest(1, v_level - 1);

      update public.profiles
        set status = 'suspended', level = v_new_level, updated_at = now()
      where id = p_user_id;

      -- NUEVO: el motivo ya no lleva el umbral en el nombre.
      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_new_level, 'mora_demotion');
    end if;
    return;
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  -- Antes del umbral de bajada: congelado, sin tocar el nivel.
  if v_status = 'active' then
    update public.profiles set status = 'frozen', updated_at = now() where id = p_user_id;
  end if;
end;
$$;

revoke all on function public.recompute_profile_mora_state(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Lo que cuenta para subir, y el enfriamiento
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260822171000 salvo los bloques marcados NUEVO.
create or replace function public.level_standing(
  p_user_id       uuid,
  p_cooldown_days integer default 60
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_profile     public.profiles%rowtype;
  v_paid        numeric(18,4);
  v_months      integer;
  v_eligible    smallint;
  v_next        public.levels%rowtype;
  v_demoted_at  timestamptz;
  v_cooldown_until timestamptz;
begin
  select * into v_profile from public.profiles where id = p_user_id;
  if not found then
    raise exception 'Perfil no encontrado' using errcode = 'P0002';
  end if;

  -- Gastos = lo PAGADO (docs/00-BASES §2.6). Lo consumido y no pagado no
  -- cuenta: subir de límite a quien más debe es lo contrario de un modelo de
  -- riesgo.
  --
  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- `financed_usd` y no `amount_usd`: lo que cuenta es lo CONSUMIDO, no lo
  -- consumido más nuestra comisión. Con `amount_usd` se llegaba al requisito un
  -- 11,6 % antes gracias a un fee que no es del usuario.
  --
  -- El `where user_id` ya hacía lo que se pedía en el reparto de grupo: las
  -- cuotas son por persona, así que aquí nunca entró el total de una mesa.
  select coalesce(sum(financed_usd), 0) into v_paid
  from public.installments
  where user_id = p_user_id and status = 'paid';
  -- ─────────────────────────────────────────────────────────────────────────

  -- Meses completos desde el alta.
  v_months := floor(extract(epoch from (now() - v_profile.created_at)) / (30 * 86400))::int;

  -- El nivel más alto ACTIVO cuyos requisitos ya cumple. Los requisitos son
  -- crecientes, así que cumplir el 3 implica cumplir el 2: se puede saltar.
  select coalesce(max(level), 1) into v_eligible
  from public.levels
  where is_active
    and required_spend_usd <= v_paid
    and required_months <= v_months;

  select * into v_next from public.levels
  where is_active and level > v_profile.level
  order by level
  limit 1;

  -- Enfriamiento tras una bajada por mora.
  --
  -- NUEVO: los DOS motivos. Las bajadas anteriores al 2026-08-30 quedaron con
  -- `mora_15d`; leer solo el nombre nuevo dejaría a quien bajó ayer sin
  -- enfriamiento y recuperando el nivel en la siguiente corrida del cron.
  select created_at into v_demoted_at
  from public.level_changes
  where user_id = p_user_id and reason in ('mora_15d', 'mora_demotion')
  order by created_at desc
  limit 1;

  v_cooldown_until := case
    when v_demoted_at is null then null
    else v_demoted_at + make_interval(days => p_cooldown_days)
  end;

  return jsonb_build_object(
    'current_level', v_profile.level,
    'eligible_level', v_eligible,
    'paid_usd', v_paid,
    'months', v_months,
    'account_status', v_profile.status,
    'next_level', case when v_next.level is null then null else
      jsonb_build_object(
        'level', v_next.level,
        'label', v_next.label,
        'limit_usd', v_next.monthly_limit_usd,
        'required_spend_usd', v_next.required_spend_usd,
        'required_months', v_next.required_months,
        'missing_spend_usd', greatest(v_next.required_spend_usd - v_paid, 0),
        'missing_months', greatest(v_next.required_months - v_months, 0)
      )
    end,
    'cooldown_until', v_cooldown_until,
    'in_cooldown', v_cooldown_until is not null and v_cooldown_until > now()
  );
end;
$$;

revoke all on function public.level_standing(uuid, integer) from public, anon;
grant execute on function public.level_standing(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Los tramos del resumen del super admin
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260822200000 salvo el bloque de `arrears`, que ahora
-- corta por donde corta la escalera de verdad y devuelve los umbrales para que
-- el panel se etiquete solo.

create or replace function public.admin_overview(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_from      date;
  v_prev_from date;
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_volume    numeric(18,4);
  v_prev_vol  numeric(18,4);
  v_count     integer;
  v_users     integer;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  -- Volumen financiado de la ventana y de la ventana anterior, para poder
  -- decir "sube o baja" y no solo un número suelto.
  select coalesce(sum(amount_usd), 0), count(*), count(distinct user_id)
    into v_volume, v_count, v_users
  from public.charges
  where status = 'confirmed' and business_date between v_from and v_today;

  select coalesce(sum(amount_usd), 0) into v_prev_vol
  from public.charges
  where status = 'confirmed' and business_date between v_prev_from and v_from - 1;

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days', v_days,
    'volume', jsonb_build_object(
      'financed_usd', v_volume,
      'previous_usd', v_prev_vol,
      'charge_count', v_count,
      'active_users', v_users,
      'avg_ticket_usd', case when v_count > 0 then round(v_volume / v_count, 2) else 0 end
    )
  );

  -- Mora. Es *el* número del negocio: docs/00-BASES §1.2 — "con 10% de mora
  -- $8 de pérdida por cada $100 se lleva el 40% de la comisión".
  -- Se mide sobre la exposición viva, no sobre el volumen histórico: lo que
  -- importa es qué porcentaje de lo que está hoy en la calle no va a volver.
  v_result := v_result || jsonb_build_object('arrears', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd), 0),
      'overdue_usd', coalesce(sum(amount_usd) filter (where due_date < v_today), 0),
      'overdue_users', count(distinct user_id) filter (where due_date < v_today),
      'due_today_usd', coalesce(sum(amount_usd) filter (where due_date = v_today), 0),
      'rate_pct', case
        when coalesce(sum(amount_usd), 0) > 0
        then round(100 * coalesce(sum(amount_usd) filter (where due_date < v_today), 0)
                       / sum(amount_usd), 2)
        else 0 end,
      -- Tramos de la escalera de consecuencias (docs/06 §3), leídos de los
      -- PARÁMETROS y no de números escritos aquí: la escalera ya se alargó una
      -- vez (15/30 → 30/60) y estos tramos se quedaron cortando por donde ya no
      -- pasaba nada. Las claves tampoco llevan el número dentro, por lo mismo.
      'demotion_days', public.helios_mora_demotion_days(),
      'expulsion_days', public.helios_mora_expulsion_days(),
      'bucket_frozen_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today
                  and due_date >= v_today - public.helios_mora_demotion_days()), 0),
      'bucket_demotion_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - public.helios_mora_demotion_days()
                  and due_date >= v_today - public.helios_mora_expulsion_days()), 0),
      'bucket_expulsion_usd', coalesce(sum(amount_usd)
        filter (where due_date < v_today - public.helios_mora_expulsion_days()), 0)
    )
    from public.installments where status = 'pending'
  ));

  -- Cartera de usuarios por estado. `frozen`/`suspended`/`expelled` son la
  -- salida del motor de mora, así que esta línea es su marcador.
  v_result := v_result || jsonb_build_object('users', (
    select jsonb_build_object(
      'total', count(*),
      'pending_kyc', count(*) filter (where status in ('pending_kyc', 'pending_pin')),
      'active', count(*) filter (where status = 'active'),
      'frozen', count(*) filter (where status = 'frozen'),
      'suspended', count(*) filter (where status = 'suspended'),
      'expelled', count(*) filter (where status = 'expelled'),
      'blacklisted', count(*) filter (where is_blacklisted),
      'new_in_window', count(*) filter (where created_at >= v_from)
    )
    from public.profiles
  ));

  -- Embudo de KYC. La tasa de aprobación y el tamaño de la cola manual son
  -- las dos cifras que deciden si hace falta más gente revisando
  -- (docs/00-BASES §3.3: el SLA de revisión manual sigue sin definirse).
  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'pending_review', count(*) filter (where status = 'manual_review'),
      'processing', count(*) filter (where status = 'processing'),
      'approved', count(*) filter (where status = 'approved'),
      'rejected', count(*) filter (where status = 'rejected'),
      'approval_rate_pct', case
        when count(*) filter (where status in ('approved', 'rejected')) > 0
        then round(100.0 * count(*) filter (where status = 'approved')
                        / count(*) filter (where status in ('approved', 'rejected')), 1)
        else null end,
      'oldest_pending_hours', coalesce(round(extract(epoch from
        (now() - min(created_at) filter (where status = 'manual_review'))) / 3600.0, 1), 0)
    )
    from kyc.verifications
  ));

  -- Colas de trabajo. Lo que hay pendiente de que una persona lo toque.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', (
      select count(*) from public.payment_reports
      where status in ('reported', 'in_review')
    ),
    'merchant_payouts_due', (
      select coalesce(sum(amount_usd), 0) from public.settlements
      where status = 'pending' and due_date <= v_today
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(amount_usd), 0) from public.settlements
      where status = 'pending'
    )
  ));

  -- Comercios.
  v_result := v_result || jsonb_build_object('merchants', (
    select jsonb_build_object(
      'total', count(*),
      'active', count(*) filter (where status = 'active'),
      'paused', count(*) filter (where status = 'paused'),
      'terminated', count(*) filter (where status = 'terminated'),
      'selling_in_window', (
        select count(distinct merchant_id) from public.charges
        where status = 'confirmed' and business_date between v_from and v_today
      )
    )
    from public.merchants
  ));

  -- Tasa BCV. docs/05 §1 la exige como alerta: si lleva más de 48 h sin
  -- actualizarse en día hábil, el scraper se rompió y estás cobrando a una
  -- tasa vieja. El aviso vale más aquí que en un log que nadie lee.
  v_result := v_result || jsonb_build_object('fx', (
    select jsonb_build_object(
      'rate', rate,
      'effective_date', effective_date,
      'fetched_at', fetched_at,
      'age_hours', round(extract(epoch from (now() - fetched_at)) / 3600.0, 1),
      'stale', (now() - fetched_at) > interval '48 hours'
    )
    from public.exchange_rates
    order by effective_date desc limit 1
  ));

  v_result := v_result || jsonb_build_object('cash', public.admin_cash_position());

  return v_result;
end;
$$;

revoke all on function public.admin_overview(integer) from public, anon;
grant execute on function public.admin_overview(integer) to authenticated;
