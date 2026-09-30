-- ============================================================================
-- Ronda — Prueba de humo de la subida de nivel
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/level_promotion_smoke.sql
--
-- Las dos que importan de verdad: que cuente lo PAGADO y no lo consumido —si
-- no, sube de límite a quien más debe— y que una bajada por mora no se
-- deshaga sola en cuanto la persona se pone al día.
--
-- Las cuotas se insertan directamente en vez de pasar por el flujo de cobro:
-- aquí se prueba el motor de niveles, y montar ventas reales metería el
-- límite de crédito de por medio, que es otra cosa.
-- ============================================================================

begin;

do $$
declare
  v_nuevo    uuid := gen_random_uuid();
  v_veterano uuid := gen_random_uuid();
  v_moroso   uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_charge   uuid;
  v_standing jsonb;
  v_result   jsonb;
  v_level    smallint;
  v_change   public.level_changes%rowtype;
  v_count    integer;
begin
  -- Helios (H3): el paciente no tiene cuenta en Auth; es solo una fila de `profiles`.
  insert into public.profiles (id, phone_e164) values
    (v_nuevo, '+584140000111'),
    (v_veterano, '+584140000112'),
    (v_moroso, '+584140000113');

  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_cajero,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000114', now(), now(), now());

  update public.profiles set status = 'active', full_name = 'Nueva'    where id = v_nuevo;
  update public.profiles set status = 'active', full_name = 'Veterano' where id = v_veterano;
  update public.profiles set status = 'active', full_name = 'Moroso'   where id = v_moroso;

  -- Helios (H1): solo el nivel 1 está activo; los 2-4 son de ejemplo y están
  -- apagados. Esta suite prueba el MOTOR de niveles, así que los enciende
  -- dentro de la transacción (con los requisitos que ya tienen: $120/1 mes,
  -- $360/2, $800/3). El 5 sigue apagado.
  update public.levels set is_active = true where level between 1 and 4;

  -- El veterano y el moroso llevan más de 3 meses registrados.
  update public.profiles set created_at = now() - interval '95 days'
  where id in (v_veterano, v_moroso);

  insert into public.merchants (name) values ('Bar Niveles') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  -- --- 1. Alguien recién llegado no sube --------------------------------
  v_result := public.evaluate_level(v_nuevo);
  if (v_result->>'promoted')::boolean then
    raise exception 'Sin gastos ni antigüedad no debía subir: %', v_result;
  end if;

  select level into v_level from public.profiles where id = v_nuevo;
  if v_level <> 1 then
    raise exception 'Debía seguir en nivel 1, está en %', v_level;
  end if;
  raise notice 'TEST NIVEL 1 OK — sin gastos ni antigüedad no sube';

  -- --- 2. Lo CONSUMIDO y no pagado no cuenta -----------------------------
  insert into public.charges
    (user_id, merchant_id, branch_id, requested_by, amount_usd, idempotency_key,
     status, business_date, confirmed_at)
  values
    (v_veterano, v_merchant, v_branch, v_cajero, 300.00, 'lvl-1',
     'confirmed', public.helios_business_date(now()), now())
  returning id into v_charge;

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date, status, financed_usd)
  values
    (v_charge, v_veterano, 1, 150.00, public.helios_business_date(now()), 'pending', 150.00),
    (v_charge, v_veterano, 2, 150.00, public.helios_business_date(now()), 'pending', 150.00);

  v_standing := public.level_standing(v_veterano);
  if (v_standing->>'paid_usd')::numeric <> 0 then
    raise exception 'Lo pendiente no debía contar como gasto: %', v_standing;
  end if;

  v_result := public.evaluate_level(v_veterano);
  if (v_result->>'promoted')::boolean then
    raise exception 'Deber $300 sin pagarlos no debía subirlo de nivel: %', v_result;
  end if;
  raise notice 'TEST NIVEL 2 OK — deber $300 sin pagar no sube de nivel';

  -- --- 3. Al pagarlos, sí sube — y solo con marcarlos pagados ------------
  update public.installments set status = 'paid', paid_at = now()
  where charge_id = v_charge;

  select level into v_level from public.profiles where id = v_veterano;
  if v_level <> 2 then
    raise exception 'Con $300 pagados y 3 meses debía estar en nivel 2, está en %', v_level;
  end if;
  raise notice 'TEST NIVEL 3 OK — pagar $300 con 3 meses lo sube a nivel 2, sin llamar a nada';

  -- --- 4. El cambio queda explicado --------------------------------------
  select * into v_change from public.level_changes
  where user_id = v_veterano and reason = 'promotion';

  if not found then
    raise exception 'La subida debía quedar registrada en level_changes';
  end if;
  if (v_change.detail->>'paid_usd')::numeric <> 300.00 then
    raise exception 'El registro debía guardar los números que lo justificaron: %', v_change.detail;
  end if;
  raise notice 'TEST NIVEL 4 OK — registrado: de % a % con $% pagados y % meses',
    v_change.from_level, v_change.to_level,
    v_change.detail->>'paid_usd', v_change.detail->>'months';

  -- --- 5. Y NO va a la bandeja de la app --------------------------------
  -- Helios (H11): los avisos de la app de Ronda están apagados (el paciente no
  -- tiene app). La subida queda en level_changes (test 4), no en notifications.
  select count(*) into v_count from public.notifications
  where user_id = v_veterano and type = 'level_up';
  if v_count <> 0 then
    raise exception 'La bandeja de la app está apagada en Helios, hay % avisos', v_count;
  end if;
  raise notice 'TEST NIVEL 5 OK — la subida no escribe en la bandeja de la app';

  -- --- 6. No se salta a un nivel inactivo --------------------------------
  -- $5.000 pagados: cumpliría de sobra cualquier requisito, pero el 5 está
  -- marcado is_active = false. Hasta el 2026-09-09 el inactivo de esta prueba
  -- era el 4; desde que el 4 abrió ($100, $800 pagados + 3 meses) el que hace
  -- de tope es el 5.
  insert into public.charges
    (user_id, merchant_id, branch_id, requested_by, amount_usd, idempotency_key,
     status, business_date, confirmed_at)
  values
    (v_veterano, v_merchant, v_branch, v_cajero, 5000.00, 'lvl-2',
     'confirmed', public.helios_business_date(now()), now())
  returning id into v_charge;

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date, status, financed_usd)
  values
    (v_charge, v_veterano, 1, 2500.00, public.helios_business_date(now()), 'paid', 2500.00),
    (v_charge, v_veterano, 2, 2500.00, public.helios_business_date(now()), 'paid', 2500.00);

  perform public.evaluate_level(v_veterano);

  select level into v_level from public.profiles where id = v_veterano;
  if v_level <> 4 then
    raise exception 'Debía llegar al 4 y parar (el 5 está inactivo), está en %', v_level;
  end if;
  raise notice 'TEST NIVEL 6 OK — llega al 4 y no salta al 5, que está inactivo';

  -- --- 7. Una cuenta en mora no sube -------------------------------------
  update public.profiles set status = 'frozen' where id = v_moroso;

  insert into public.charges
    (user_id, merchant_id, branch_id, requested_by, amount_usd, idempotency_key,
     status, business_date, confirmed_at)
  values
    (v_moroso, v_merchant, v_branch, v_cajero, 700.00, 'lvl-3',
     'confirmed', public.helios_business_date(now()), now())
  returning id into v_charge;

  insert into public.installments (charge_id, user_id, sequence, amount_usd, due_date, status, financed_usd)
  values
    (v_charge, v_moroso, 1, 350.00, public.helios_business_date(now()), 'paid', 350.00),
    (v_charge, v_moroso, 2, 350.00, public.helios_business_date(now()), 'paid', 350.00);

  v_result := public.evaluate_level(v_moroso);
  if (v_result->>'promoted')::boolean then
    raise exception 'Una cuenta congelada no debía subir: %', v_result;
  end if;
  if (v_result->>'reason') <> 'cuenta_no_activa' then
    raise exception 'El motivo debía ser cuenta_no_activa: %', v_result;
  end if;
  raise notice 'TEST NIVEL 7 OK — una cuenta congelada no sube';

  -- --- 8. Tras una bajada por mora, hay enfriamiento ---------------------
  update public.profiles set status = 'active', level = 1 where id = v_moroso;
  insert into public.level_changes (user_id, from_level, to_level, reason)
  values (v_moroso, 2, 1, 'mora_15d');

  v_result := public.evaluate_level(v_moroso);
  if (v_result->>'promoted')::boolean then
    raise exception 'Recién bajado por mora no debía recuperar el nivel: %', v_result;
  end if;
  if (v_result->>'reason') <> 'enfriamiento' then
    raise exception 'El motivo debía ser enfriamiento: %', v_result;
  end if;
  raise notice 'TEST NIVEL 8 OK — la bajada por mora no se deshace sola';

  -- --- 9. Pasado el enfriamiento, sí recupera ----------------------------
  update public.level_changes
    set created_at = now() - interval '61 days'
  where user_id = v_moroso and reason = 'mora_15d';

  v_result := public.evaluate_level(v_moroso);
  if not (v_result->>'promoted')::boolean then
    raise exception 'Pasados 60 días debía poder recuperar el nivel: %', v_result;
  end if;
  raise notice 'TEST NIVEL 9 OK — pasados 60 días recupera: nivel %', v_result->>'to_level';

  -- --- 10. El progreso dice qué falta ------------------------------------
  v_standing := public.level_standing(v_nuevo);
  if (v_standing->'next_level'->>'missing_spend_usd')::numeric <> 120.00 then
    raise exception 'A la nueva le faltan $120 para el nivel 2: %', v_standing;
  end if;
  if (v_standing->'next_level'->>'missing_months')::int <> 1 then
    raise exception 'A la nueva le falta 1 mes: %', v_standing;
  end if;
  raise notice 'TEST NIVEL 10 OK — progreso: faltan $% y % mes(es) para el %',
    v_standing->'next_level'->>'missing_spend_usd',
    v_standing->'next_level'->>'missing_months',
    v_standing->'next_level'->>'label';

  raise notice '=== TODOS LOS TESTS DE SUBIDA DE NIVEL PASARON ===';
end $$;

set constraints all immediate;

rollback;
