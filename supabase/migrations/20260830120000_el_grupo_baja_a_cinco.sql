-- ============================================================================
-- Ronda — El grupo baja de 8 a 5 personas
--
-- Decisión de negocio. Lo que cambia con ella, y por eso conviene dejarlo
-- dicho: con el reparto en cascada, el mínimo por persona ($2,50) fija un
-- suelo para la cuenta —entre 8 hacían falta $20 para poder repartir, entre 5
-- bastan $12,50—, así que bajar el tope hace que se pueda dividir cuentas más
-- pequeñas. La otra cara es que en una mesa de seis alguien se queda fuera.
--
-- ── Y por qué el número vive en una función ─────────────────────────────────
--
-- El 8 estaba escrito a mano en DOS sitios —`find_group_by_code` y
-- `join_group`—, y ninguno de los dos sabía del otro. Cambiar uno solo deja el
-- caso peor posible: la pantalla de entrada te dice que cabes y el `join` te
-- rechaza al poner el PIN, o al revés.
--
-- Es el idioma que ya usa el resto del esquema para sus límites —
-- `max_payment_methods()`, `min_share_usd()`, `helios_vat_pct()`— y era el
-- único que faltaba por seguirlo.
-- ============================================================================

/**
 * Cuánta gente cabe en un grupo.
 *
 * `immutable` a propósito: es una constante de negocio, no un dato. Cambiarla
 * es esta migración, no un `update`.
 */
create or replace function public.max_group_members()
returns integer
language sql
immutable
set search_path = public, pg_temp
as $fn$ select 5 $fn$;

comment on function public.max_group_members() is
  'Máximo de integrantes de un grupo. Bajó de 8 a 5 el 2026-08-30.';

revoke all on function public.max_group_members() from public, anon;
grant execute on function public.max_group_members() to authenticated;

-- ---------------------------------------------------------------------------
-- Las dos funciones que lo comprueban, ya sin el número a mano
-- ---------------------------------------------------------------------------
-- Cuerpos idénticos a los de 20260828000000 salvo esa línea.

create or replace function public.find_group_by_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_group public.groups%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_count integer;
  v_avail numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_code)) and business_date = v_bdate;

  if not found then
    -- Un código de anoche y uno inventado dan lo mismo a propósito: decir
    -- "ese grupo era de ayer" obligaría a buscar entre los muertos, y no
    -- cambia nada de lo que la persona puede hacer ahora.
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if exists (
    select 1 from public.group_members
    where group_id = v_group.id and user_id = v_user and left_at is null
  ) then
    return jsonb_build_object('ok', false, 'reason', 'already_in',
      'group_id', v_group.id, 'name', v_group.name, 'member_count', v_count);
  end if;

  if not public.can_take_debt(v_user) then
    return jsonb_build_object('ok', false, 'reason', 'overdue');
  end if;

  if v_count >= public.max_group_members() then
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;

  v_avail := public.available_usd(v_user);

  if v_avail < public.min_share_usd() then
    return jsonb_build_object('ok', false, 'reason', 'no_balance',
      'available_usd', v_avail, 'min_share_usd', public.min_share_usd());
  end if;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'member_count', v_count,
    'closes_at', public.helios_business_day_end(v_group.business_date),
    -- El techo que propone la app: el saldo entero. Es un defecto, no una
    -- obligación; la pantalla deja bajarlo antes de aceptar.
    'suggested_cap_usd', floor(v_avail * 100) / 100,
    'max_cap_usd', floor(v_avail * 100) / 100,
    'min_cap_usd', public.min_share_usd()
  );
end;
$$;

revoke all on function public.find_group_by_code(text) from public, anon;
grant execute on function public.find_group_by_code(text) to authenticated;

create or replace function public.join_group(
  p_invite_code text,
  p_cap_usd     numeric,
  p_pin         text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_pin   jsonb;
  v_group public.groups%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_count integer;
  v_avail numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_group from public.groups
  where invite_code = upper(trim(p_invite_code)) and business_date = v_bdate
  for update;

  if not found then
    raise exception 'Ese código no corresponde a ningún grupo de esta noche'
      using errcode = 'P0002';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes entrar a un grupo' using errcode = '22023';
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if v_count >= public.max_group_members() then
    raise exception 'El grupo ya tiene 8 integrantes' using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de $%', public.min_share_usd() using errcode = '22023';
  end if;

  if p_cap_usd > v_avail then
    raise exception 'Tu techo sería de $% y tienes $% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  /**
   * Volver a entrar después de haber salido empieza de cero: techo nuevo y
   * `spent_usd` a 0. No es un agujero — lo ya gastado siguió siendo deuda suya
   * y sigue descontando de su disponible, así que el saldo real lo acota.
   */
  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, left_at, authorized_at, status)
  values
    (v_group.id, v_user, v_bdate, p_cap_usd, 0, null, now(), 'active')
  on conflict (group_id, user_id) do update
    set cap_usd       = excluded.cap_usd,
        spent_usd     = 0,
        left_at       = null,
        authorized_at = now(),
        status        = 'active';

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_business_day_end(v_group.business_date)
  );
end;
$$;

revoke all on function public.join_group(text, numeric, text) from public, anon;
grant execute on function public.join_group(text, numeric, text) to authenticated;
