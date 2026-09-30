-- ============================================================================
-- Ronda — Prueba de humo del nivel 0 y de la pantalla de subida
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/nivel_cero_smoke.sql
--
-- Las tres que importan:
--
--   · Se NACE sin nivel y con límite 0. Es lo que impide que alguien sin
--     verificar tenga saldo, y es la mitad de la prueba que se olvidaría.
--   · Activarse da el nivel 1 por los DOS caminos —el PIN antes del KYC y el
--     KYC antes del PIN—, porque los dos acaban en el mismo UPDATE de estado y
--     una línea metida dentro de uno solo dejaría al otro fuera.
--   · Lo pendiente SOBREVIVE a no abrir la app: `my_pending_level_up` sigue
--     contestando días después, y solo se calla cuando se acusa recibo.
-- ============================================================================

begin;

do $$
declare
  v_kyc_primero uuid := gen_random_uuid();
  v_pin_primero uuid := gen_random_uuid();
  v_vuelve      uuid := gen_random_uuid();
  v_level       smallint;
  v_limit       numeric;
  v_change      public.level_changes%rowtype;
  v_pending     jsonb;
  v_count       integer;
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'pin_pepper') then
    perform vault.create_secret('smoke-pepper-0123456789', 'pin_pepper');
  end if;

  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_kyc_primero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000901', now(), now(), now()),
    (v_pin_primero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000902', now(), now(), now()),
    (v_vuelve,      '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000903', now(), now(), now());

  -- --- 1. Se nace sin nivel y sin saldo ------------------------------------
  select level into v_level from public.profiles where id = v_kyc_primero;
  if v_level <> 0 then
    raise exception 'Un perfil recién creado debía nacer sin nivel, y nació en %', v_level;
  end if;

  select monthly_limit_usd into v_limit from public.levels l
  join public.profiles p on p.level = l.level
  where p.id = v_kyc_primero;
  if v_limit <> 0 then
    raise exception 'Sin verificar, el límite debía ser 0 y es %', v_limit;
  end if;

  -- Y la fila del 0 existe, que es lo que hace que la consulta de arriba
  -- devuelva algo en vez de nada. Es el detalle del que cuelga que las treinta
  -- funciones que leen el límite sigan funcionando sin tocarlas.
  if not exists (select 1 from public.levels where level = 0 and not is_active) then
    raise exception 'El peldaño 0 debía existir y estar inactivo';
  end if;
  raise notice 'TEST NIVEL0 1 OK — se nace sin nivel y con límite 0';

  -- --- 2. El 0 no es un destino -------------------------------------------
  -- `evaluate_level` solo mira los activos, así que nadie puede ser
  -- promocionado al 0 ni el techo puede caer ahí.
  if (select max(level) from public.levels where is_active) < 1 then
    raise exception 'El techo de la escalera no puede salir del peldaño 0';
  end if;
  raise notice 'TEST NIVEL0 2 OK — el 0 está fuera de la escalera';

  -- --- 3. Camino A: el PIN ya estaba, llega el KYC -------------------------
  -- Es lo que hace `kyc.advance_profile` cuando encuentra PIN: pasa el perfil
  -- de `pending_kyc` a `active` directamente.
  update public.profiles set status = 'active', full_name = 'Vino del KYC'
  where id = v_kyc_primero;

  select level into v_level from public.profiles where id = v_kyc_primero;
  if v_level <> 1 then
    raise exception 'Verificarse debía dar el nivel 1, y está en %', v_level;
  end if;

  select * into v_change from public.level_changes
  where user_id = v_kyc_primero and reason = 'kyc_approved';
  if not found then
    raise exception 'La subida al 1 debía quedar registrada con motivo kyc_approved';
  end if;
  if v_change.from_level <> 0 or v_change.to_level <> 1 then
    raise exception 'El registro debía decir de 0 a 1, y dice de % a %',
      v_change.from_level, v_change.to_level;
  end if;
  if v_change.celebrated_at is not null then
    raise exception 'Una subida recién nacida no puede estar ya celebrada';
  end if;

  select count(*) into v_count from public.notifications
  where user_id = v_kyc_primero and type = 'level_up';
  if v_count <> 1 then
    raise exception 'Debía avisarse la llegada al nivel 1, hay % avisos', v_count;
  end if;
  raise notice 'TEST NIVEL0 3 OK — verificarse da el nivel 1, con rastro y aviso';

  -- --- 4. Camino B: el KYC ya estaba, llega el PIN -------------------------
  -- El otro orden: `advance_profile` deja el perfil en `pending_pin` y es
  -- `set_user_pin` quien lo activa. Si la subida viviera dentro del KYC, a
  -- esta persona no le habría llegado nunca.
  update public.profiles set status = 'pending_pin' where id = v_pin_primero;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_pin_primero::text, 'role', 'authenticated')::text, true);
  perform public.set_user_pin('7391');
  reset role;

  select level into v_level from public.profiles where id = v_pin_primero;
  if v_level <> 1 then
    raise exception 'Poner el PIN con el KYC hecho debía dar el nivel 1, y está en %', v_level;
  end if;
  raise notice 'TEST NIVEL0 4 OK — el nivel llega también por el camino del PIN';

  -- --- 5. Volver de una mora NO regala nivel -------------------------------
  -- Quien vuelve de `frozen` recupera el nivel por el motor y su enfriamiento,
  -- no por aquí. Sin esta guarda, una cuenta descongelada saltaría al 1 desde
  -- donde estuviera y se saltaría los 60 días.
  update public.profiles set status = 'active', level = 3 where id = v_vuelve;
  update public.profiles set status = 'frozen' where id = v_vuelve;
  update public.profiles set status = 'active' where id = v_vuelve;

  select level into v_level from public.profiles where id = v_vuelve;
  if v_level <> 3 then
    raise exception 'Descongelar no debía tocar el nivel, y lo dejó en %', v_level;
  end if;

  select count(*) into v_count from public.level_changes
  where user_id = v_vuelve and reason = 'kyc_approved';
  if v_count <> 0 then
    raise exception 'Descongelar no es verificarse: no debía registrar nada';
  end if;
  raise notice 'TEST NIVEL0 5 OK — volver de una mora no regala el primer nivel';

  -- --- 6. La pantalla espera al usuario -----------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_kyc_primero::text, 'role', 'authenticated')::text, true);

  v_pending := public.my_pending_level_up();
  if v_pending is null then
    raise exception 'La subida al 1 debía estar esperando a que abra la app';
  end if;
  if (v_pending->>'to_level')::int <> 1 or v_pending->>'reason' <> 'kyc_approved' then
    raise exception 'Lo pendiente debía ser la llegada al 1: %', v_pending;
  end if;
  if (v_pending->>'limit_usd')::numeric <= 0 then
    raise exception 'La pantalla necesita el límite del nivel nuevo: %', v_pending;
  end if;
  -- El siguiente peldaño viaja con lo que cuesta: es la única línea de la
  -- pantalla que mira hacia adelante.
  if v_pending->'next_level'->>'level' is null then
    raise exception 'Debía venir el siguiente nivel con su requisito: %', v_pending;
  end if;
  -- Y sobre cuántos peldaños se mide el corazón, para que el primer fotograma
  -- ya sea el bueno.
  if (v_pending->>'active_levels')::int < 1 then
    raise exception 'Debía venir cuántos niveles activos hay: %', v_pending;
  end if;
  raise notice 'TEST NIVEL0 6 OK — lo pendiente se puede leer, con todo lo que se pinta';

  -- --- 7. Se cuenta una vez ------------------------------------------------
  if public.ack_level_up() <> 1 then
    raise exception 'Acusar recibo debía cerrar exactamente una subida';
  end if;

  if public.my_pending_level_up() is not null then
    raise exception 'Ya contada, no debía volver a salir';
  end if;

  -- Idempotente: un doble toque o un reintento de red no puede fallar.
  if public.ack_level_up() <> 0 then
    raise exception 'Acusar recibo dos veces debía cerrar cero la segunda';
  end if;
  reset role;
  raise notice 'TEST NIVEL0 7 OK — se cuenta una vez y acusar recibo es idempotente';

  -- --- 8. Una BAJADA no se celebra -----------------------------------------
  -- `celebrated_at` se queda en null para siempre en las bajadas: nadie va a
  -- acusar recibo de una. Lo que impide que salgan por la pantalla es el
  -- filtro `to_level > from_level`, y esto es lo que lo sujeta — sin él, bajar
  -- de nivel por mora abriría una felicitación.
  insert into public.level_changes (user_id, from_level, to_level, reason)
  values (v_vuelve, 3, 1, 'mora_demotion');

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_vuelve::text, 'role', 'authenticated')::text, true);

  if public.my_pending_level_up() is not null then
    raise exception 'Una bajada por mora no puede salir como subida pendiente';
  end if;
  reset role;
  raise notice 'TEST NIVEL0 8 OK — una bajada por mora no abre ninguna pantalla';

  raise notice '=== TODOS LOS TESTS DEL NIVEL 0 PASARON ===';
end $$;

set constraints all immediate;
rollback;
