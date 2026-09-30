-- ============================================================================
-- Ronda — Motor de subida de nivel
--
-- Ver 20260822170000 para las dos decisiones que faltaban (gastos = pagado, y
-- enfriamiento tras una bajada por mora).
-- ============================================================================

/**
 * Los dos números que deciden el nivel, más el contexto para explicarlo.
 *
 * Se calcula siempre desde la fuente de verdad —cuotas pagadas y fecha de
 * alta— y nunca desde un contador acumulado. Un contador se desincroniza en
 * cuanto algo se anula o se corrige a mano, y entonces el nivel de alguien
 * depende de un número que ya nadie sabe de dónde salió.
 */
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
  select coalesce(sum(amount_usd), 0) into v_paid
  from public.installments
  where user_id = p_user_id and status = 'paid';

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
  select created_at into v_demoted_at
  from public.level_changes
  where user_id = p_user_id and reason = 'mora_15d'
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

/**
 * Sube de nivel si toca. Nunca baja: descender es competencia del motor de
 * mora, que tiene sus propias reglas.
 *
 * Idempotente: llamarla mil veces sobre alguien que ya está en su nivel no
 * hace nada. Por eso puede colgar de un trigger sin miedo.
 */
create or replace function public.evaluate_level(
  p_user_id       uuid,
  p_cooldown_days integer default 60
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_standing jsonb;
  v_current  smallint;
  v_eligible smallint;
  v_new      public.levels%rowtype;
begin
  v_standing := public.level_standing(p_user_id, p_cooldown_days);

  v_current  := (v_standing->>'current_level')::smallint;
  v_eligible := (v_standing->>'eligible_level')::smallint;

  -- Una cuenta congelada, bloqueada o expulsada no sube. Premiar a quien está
  -- en mora contradice para qué existen los niveles.
  if (v_standing->>'account_status') <> 'active' then
    return jsonb_build_object('promoted', false, 'reason', 'cuenta_no_activa');
  end if;

  if (v_standing->>'in_cooldown')::boolean then
    return jsonb_build_object(
      'promoted', false, 'reason', 'enfriamiento',
      'until', v_standing->>'cooldown_until'
    );
  end if;

  if v_eligible <= v_current then
    return jsonb_build_object('promoted', false, 'reason', 'sin_cambio');
  end if;

  select * into v_new from public.levels where level = v_eligible;

  update public.profiles
    set level = v_eligible, updated_at = now()
  where id = p_user_id;

  insert into public.level_changes (user_id, from_level, to_level, reason, detail)
  values (
    p_user_id, v_current, v_eligible, 'promotion',
    jsonb_build_object(
      'paid_usd', v_standing->'paid_usd',
      'months', v_standing->'months',
      'required_spend_usd', v_new.required_spend_usd,
      'required_months', v_new.required_months
    )
  );

  perform public.notify(
    p_user_id, 'level_up',
    format('Subiste al %s', v_new.label),
    format('Tu límite pasa a $%s. Lo lograste pagando $%s a tiempo.',
           trim(to_char(v_new.monthly_limit_usd, 'FM999999990.00')),
           trim(to_char((v_standing->>'paid_usd')::numeric, 'FM999999990.00'))),
    jsonb_build_object('level', v_eligible, 'limit_usd', v_new.monthly_limit_usd)
  );

  return jsonb_build_object(
    'promoted', true,
    'from_level', v_current,
    'to_level', v_eligible,
    'limit_usd', v_new.monthly_limit_usd
  );
end;
$$;

revoke all on function public.evaluate_level(uuid, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Cuándo se evalúa
-- ---------------------------------------------------------------------------

/**
 * Al pagar. Es el momento en que cambia el número que decide el nivel, y
 * enterarse de que subiste justo después de pagar es la mitad del incentivo.
 *
 * Cuelga de `installments` y no de `reconcile_payment` para que valga
 * cualquier camino que marque una cuota como pagada, hoy o mañana.
 */
create or replace function public.evaluate_level_on_payment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'paid' and old.status <> 'paid' then
    perform public.evaluate_level(new.user_id);
  end if;

  return null;
end;
$$;

revoke all on function public.evaluate_level_on_payment() from public, anon, authenticated;

create trigger installments_evaluate_level
  after update on public.installments
  for each row execute function public.evaluate_level_on_payment();

/**
 * Y una vez al día, porque la antigüedad es el otro requisito y esa cambia
 * sola: quien ya tiene los gastos pero le falta un mes sube ese día sin
 * necesidad de pagar nada.
 *
 * Solo mira a quien puede subir: cuenta activa y con algún nivel activo por
 * encima del suyo.
 */
create or replace function public.process_level_promotions()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row     record;
  v_result  jsonb;
  v_count   integer := 0;
  v_top     smallint;
begin
  select max(level) into v_top from public.levels where is_active;

  for v_row in
    select id from public.profiles
    where status = 'active' and level < v_top
  loop
    v_result := public.evaluate_level(v_row.id);
    if (v_result->>'promoted')::boolean then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.process_level_promotions() from public, anon, authenticated;

select cron.schedule(
  'helios_level_promotions',
  -- 10:20 AM Caracas, después de la mora y de los recordatorios: primero se
  -- resuelve quién está al día y luego se premia.
  '20 14 * * *',
  $$ select public.process_level_promotions(); $$
);

-- ---------------------------------------------------------------------------
-- Para la app
-- ---------------------------------------------------------------------------

create or replace function public.my_level_progress()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  return public.level_standing(v_user);
end;
$$;

revoke all on function public.my_level_progress() from public, anon;
grant execute on function public.my_level_progress() to authenticated;
