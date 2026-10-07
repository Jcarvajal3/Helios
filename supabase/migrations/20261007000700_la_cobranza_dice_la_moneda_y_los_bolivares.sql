-- ============================================================================
-- Helios — La cobranza dice la moneda y los bolívares (2026-10-07)
--
-- El mensaje de cobro que el equipo abre por WhatsApp desde la cartera
-- (`mensajeDeCobro` del panel) pedía «$X» y calculaba los bolívares con la
-- tasa del dólar. Con órdenes en euros eso cobra mal: la cuota en euros se
-- paga a la tasa del euro.
--
-- La cartera (`admin_collections`) y la fila de una persona
-- (`admin_collection_case`) traen ahora, además de sus cifras en dólares de
-- siempre:
--
--   overdue_text / upcoming_text      «€56,96 + $2»: la deuda en su moneda
--   overdue_ves_hoy / upcoming_ves_hoy los bolívares de hoy, cada parte a la
--                                      tasa BCV de su moneda (null sin tasa)
--
-- Lo vencido es lo que vence antes de hoy (con sus cargos por atraso, en
-- dólares); lo por vencer, de hoy al horizonte. Lo dado por perdido no se
-- pide.
-- ============================================================================

create or replace function public.helios_collection_amounts(p_user uuid, p_today date, p_horizon integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ov_usd numeric(18,4);
  v_ov_eur numeric(18,4);
  v_up_usd numeric(18,4);
  v_up_eur numeric(18,4);
  v_fee    numeric(18,4);
  v_ov_bs  numeric;
  v_up_bs  numeric;
begin
  select
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date <  p_today and c.currency <> 'EUR'), 0),
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date <  p_today and c.currency =  'EUR'), 0),
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date >= p_today and c.currency <> 'EUR'), 0),
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date >= p_today and c.currency =  'EUR'), 0)
    into v_ov_usd, v_ov_eur, v_up_usd, v_up_eur
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.user_id = p_user
    and i.status = 'pending'
    and not i.is_test
    and i.written_off_at is null
    and i.due_date <= p_today + p_horizon;

  select coalesce(sum(f.amount_usd), 0) into v_fee
  from public.late_fees f
  where f.user_id = p_user and f.status = 'pending';

  v_ov_usd := v_ov_usd + v_fee;

  begin
    v_ov_bs := (public.helios_bolivares(v_ov_usd, v_ov_eur, p_today)->>'amount_ves')::numeric;
  exception when sqlstate 'P0002' then v_ov_bs := null;
  end;
  begin
    v_up_bs := (public.helios_bolivares(v_up_usd, v_up_eur, p_today)->>'amount_ves')::numeric;
  exception when sqlstate 'P0002' then v_up_bs := null;
  end;

  return jsonb_build_object(
    'overdue_text', public.helios_amounts_label(v_ov_usd, v_ov_eur),
    'overdue_ves_hoy', v_ov_bs,
    'upcoming_text', public.helios_amounts_label(v_up_usd, v_up_eur),
    'upcoming_ves_hoy', v_up_bs
  );
end;
$$;

revoke all on function public.helios_collection_amounts(uuid, date, integer) from public, anon, authenticated;

-- La cartera: cada fila con lo suyo. Se toca solo el objeto que se le añade a
-- cada fila; el resto de la función queda como está.
do $$
declare
  v_def text := pg_get_functiondef('public.admin_collections(integer, uuid, date)'::regprocedure);
begin
  if position('helios_collection_amounts' in v_def) = 0 then
    v_def := replace(v_def,
      $r$             f.r || jsonb_build_object($r$,
      $r$             f.r || public.helios_collection_amounts((f.r ->> 'user_id')::uuid, v_today, v_horizon)
                 || jsonb_build_object($r$);
    if position('helios_collection_amounts' in v_def) = 0 then
      raise exception 'admin_collections no tiene la forma esperada';
    end if;
    execute v_def;
  end if;
end
$$;

create or replace function public.admin_collection_case(p_user uuid, p_horizon_days integer default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today   date    := public.helios_business_date(now());
  v_horizon integer := greatest(least(coalesce(p_horizon_days, 3), 30), 0);
  v_row     jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_user is null then
    return null;
  end if;

  v_row := (select r from public.helios_collection_rows(v_today, v_horizon, p_user) r limit 1);
  if v_row is null then
    return null;
  end if;

  return v_row || public.helios_collection_amounts(p_user, v_today, v_horizon);
end;
$$;
