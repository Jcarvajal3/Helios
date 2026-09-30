-- ============================================================================
-- Ronda — 🐛 Salir de tu propia mesa y volver a abrirla te dejaba fuera
--
-- Reproducción, en la misma noche:
--
--   1. "Compartir gastos"  → nace la mesa y entras
--   2. "Salir de la mesa"  → `left_at` se sella
--   3. "Compartir gastos"  → **la mesa vuelve, tú no**
--
-- A partir de ahí la pantalla decía "Esta noche pagas solo" y el botón no
-- hacía nada: un callejón sin salida hasta el corte de las 10 AM.
--
-- El motivo: `open_my_tab` es idempotente por (persona, noche) en las DOS
-- tablas, pero con el gesto equivocado en la segunda. La fila de `tabs` vuelve
-- con `on conflict ... do update`, y la de `tab_members` con `do nothing` —
-- que es correcto cuando sigues dentro y es exactamente el error cuando
-- saliste, porque la fila existe con `left_at` puesto y `do nothing` la deja
-- así. El `my_open_tab_id()` de la línea siguiente no la encuentra y devuelve
-- null para siempre.
--
-- Volver a entrar empieza de cero —techo nuevo con el saldo de AHORA y
-- `spent_usd` a 0—, igual que `join_tab`. No es un agujero: lo ya gastado
-- sigue siendo deuda suya y sigue descontando de su disponible, así que el
-- saldo real lo acota igual.
-- ============================================================================

create or replace function public.open_my_tab()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_tab   public.tabs%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_avail numeric(18,4);
  v_exist uuid;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_exist := public.my_open_tab_id();
  if v_exist is not null then
    select * into v_tab from public.tabs where id = v_exist;
    return jsonb_build_object('tab_id', v_tab.id, 'token', v_tab.token, 'created', false);
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes compartir gastos' using errcode = '22023';
  end if;

  v_avail := (public.my_available_balance()->>'available_usd')::numeric;

  if v_avail < public.min_share_usd() then
    raise exception 'Te quedan $% y el mínimo por persona es $%',
      v_avail, public.min_share_usd() using errcode = '22023';
  end if;

  -- `on conflict` y no un `if not exists`: dos toques simultáneos desde el
  -- mismo teléfono no pueden acabar en dos mesas.
  insert into public.tabs (opened_by, business_date)
  values (v_user, v_bdate)
  on conflict (opened_by, business_date) do update set opened_by = excluded.opened_by
  returning * into v_tab;

  -- `do update` y no `do nothing`: si esta persona ya había salido de esta
  -- misma mesa, la fila existe con `left_at` puesto y hay que revivirla. Con
  -- `do nothing` la mesa volvía sin su dueño dentro.
  insert into public.tab_members (tab_id, user_id, business_date, cap_usd, spent_usd, left_at)
  values (v_tab.id, v_user, v_bdate, floor(v_avail * 100) / 100, 0, null)
  on conflict (tab_id, user_id) do update
    set cap_usd   = excluded.cap_usd,
        spent_usd = 0,
        left_at   = null,
        joined_at = now();

  return jsonb_build_object('tab_id', v_tab.id, 'token', v_tab.token, 'created', true);
end;
$$;

revoke all on function public.open_my_tab() from public, anon;
grant execute on function public.open_my_tab() to authenticated;
