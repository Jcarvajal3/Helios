-- ============================================================================
-- Ronda — Prueba de humo de la tasa BCV
--
--   docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f supabase/tests/fx_rate_smoke.sql
--
-- La tasa es el único número de todo el sistema que no lo genera Ronda: entra
-- de fuera, de un servidor de terceros, y multiplica TODO lo que el usuario
-- paga. Por eso lo que se prueba aquí no es que la ingesta funcione —eso
-- depende de la red y de un espejo ajeno— sino lo contrario: que cuando la
-- ingesta falla, o miente, no entre nada.
--
-- Nada de esto sale a internet. El único trozo que habla con la red es el
-- bucle de fuentes de `sync_fx_rate`, y se ejerce con la tabla de fuentes
-- vacía a propósito.
-- ============================================================================

begin;

do $$
declare
  v_bd       date := public.helios_business_date(now());
  v_admin    uuid := gen_random_uuid();
  v_juan     uuid := gen_random_uuid();
  v_rate     numeric;
  v_result   jsonb;
  v_syncs    integer;
  v_syncs_2  integer;
  v_status   record;
  v_failed   boolean;
  v_logged   integer;
begin
  -- --- 1. El guardarraíl ---------------------------------------------------
  -- Lo que decide si una tasa entra. Cada caso de aquí es un incidente real
  -- posible: el espejo que devuelve 0, el que cambia de unidad, el que se
  -- quedó congelado en enero.

  if public.fx_rate_rejection(800.00, 780.00, now(), v_bd) is not null then
    raise exception 'Una subida normal (780 → 800) debía aceptarse, se rechazó: %',
      public.fx_rate_rejection(800.00, 780.00, now(), v_bd);
  end if;

  -- La primera tasa de la historia no tiene contra qué compararse: entra.
  if public.fx_rate_rejection(800.00, null, null, v_bd) is not null then
    raise exception 'Sin tasa anterior no hay salto que medir, debía aceptarse';
  end if;

  if public.fx_rate_rejection(0, 780.00, now(), v_bd) is null then
    raise exception 'Una tasa de 0 debía rechazarse';
  end if;

  if public.fx_rate_rejection(null, 780.00, now(), v_bd) is null then
    raise exception 'Una tasa nula debía rechazarse';
  end if;

  if public.fx_rate_rejection(-5, 780.00, now(), v_bd) is null then
    raise exception 'Una tasa negativa debía rechazarse';
  end if;

  -- El espejo que empieza a devolver la tasa en céntimos, o en miles.
  if public.fx_rate_rejection(78000.00, 780.00, now(), v_bd) is null then
    raise exception 'Un salto de x100 debía rechazarse';
  end if;
  if public.fx_rate_rejection(7.80, 780.00, now(), v_bd) is null then
    raise exception 'Una caída de /100 debía rechazarse';
  end if;

  -- El espejo congelado: la cifra es razonable, la fecha no.
  if public.fx_rate_rejection(800.00, 780.00, now() - interval '30 days', v_bd) is null then
    raise exception 'Un espejo congelado hace 30 días debía rechazarse';
  end if;
  -- Un puente largo sí pasa: el BCV no publica y la última buena tiene días.
  if public.fx_rate_rejection(800.00, 780.00, now() - interval '4 days', v_bd) is not null then
    raise exception 'Un puente de 4 días NO debía rechazarse';
  end if;

  raise notice 'TEST TASA 1 OK — el guardarraíl acepta lo bueno y para el 0, lo negativo, el x100 y el espejo congelado';

  -- --- 2. Fin de semana: vale la última publicada --------------------------
  -- El BCV no publica ni sábado ni domingo. La resolución es "última tasa con
  -- effective_date <= hoy", nunca coincidencia exacta.

  delete from public.exchange_rates where source = 'BCV';
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 777.77, v_bd - 3);

  v_rate := public.current_fx_rate();
  if v_rate is distinct from 777.77 then
    raise exception 'Sin tasa de hoy debía valer la del % (777,77), salió %', v_bd - 3, v_rate;
  end if;
  raise notice 'TEST TASA 2 OK — sin publicación hoy se cotiza con la última (%)', v_rate;

  -- --- 3. Con la tasa del día ya cargada, el job no sale a la red ----------
  -- Es lo que hace que los ocho reintentos horarios no cuesten nada.

  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 800.00, v_bd);

  select count(*) into v_syncs from public.fx_rate_syncs;
  v_result := public.sync_fx_rate();
  select count(*) into v_syncs_2 from public.fx_rate_syncs;

  if (v_result->>'skipped')::boolean is not true then
    raise exception 'Con la tasa del día ya cargada, el job debía saltarse: %', v_result;
  end if;
  if v_syncs_2 <> v_syncs then
    raise exception 'Un job saltado no debía escribir en la bitácora (% → %)', v_syncs, v_syncs_2;
  end if;
  raise notice 'TEST TASA 3 OK — con la tasa del día cargada el job no pide nada (%)', v_result->>'rate';

  -- --- 4. Si no hay de dónde traerla, NO se inventa ------------------------
  -- El caso que de verdad importa: todos los espejos caídos. La tasa de ayer
  -- sigue vigente y el fallo queda apuntado. Lo que no puede pasar nunca es
  -- que se escriba una tasa cualquiera para tapar el hueco.

  delete from public.exchange_rates where source = 'BCV' and effective_date = v_bd;
  update public.fx_rate_sources set is_active = false;

  v_result := public.sync_fx_rate();

  if (v_result->>'ok')::boolean is not false then
    raise exception 'Sin fuentes activas el job no podía decir que fue bien: %', v_result;
  end if;
  if exists (select 1 from public.exchange_rates where source = 'BCV' and effective_date = v_bd) then
    raise exception 'Sin fuente válida NO se puede escribir tasa para hoy';
  end if;
  if not exists (
    select 1 from public.fx_rate_syncs
    where effective_date = v_bd and status = 'no_source'
  ) then
    raise exception 'El fallo debía quedar apuntado en la bitácora';
  end if;
  if public.current_fx_rate() is distinct from 777.77 then
    raise exception 'Tras el fallo debía seguir vigente la última buena (777,77), salió %',
      public.current_fx_rate();
  end if;
  raise notice 'TEST TASA 4 OK — con todos los espejos caídos no se escribe nada y sigue vigente la anterior';

  -- --- 5. Aviso de tasa vieja ----------------------------------------------
  -- docs/05 §1: "alerta obligatoria si la tasa lleva más de 48 h sin
  -- actualizarse". Es el aviso que distingue "el BCV no publicó" de "el job
  -- lleva tres días roto", que desde fuera se ven exactamente igual.

  update public.exchange_rates set fetched_at = now() - interval '4 days'
  where source = 'BCV';

  select * into v_status from public.fx_rate_status();
  if not v_status.is_stale then
    raise exception 'Una tasa traída hace 4 días debía marcarse como vieja';
  end if;
  if v_status.is_current then
    raise exception 'La tasa del % no es la del día operativo %', v_bd - 3, v_bd;
  end if;

  update public.exchange_rates set fetched_at = now() where source = 'BCV';
  select * into v_status from public.fx_rate_status();
  if v_status.is_stale then
    raise exception 'Una tasa recién traída no puede estar vieja (% h)', v_status.age_hours;
  end if;
  raise notice 'TEST TASA 5 OK — el aviso se enciende a las 48 h y se apaga al traer una nueva';

  -- --- 6. Quién puede tocar la tasa ----------------------------------------
  -- Escribir la tasa es decidir cuánto paga todo el mundo ese día: ni la app
  -- ni el panel pueden llamar a lo que escribe.

  if has_function_privilege('authenticated', 'public.record_fx_rate(numeric, date, text)', 'execute') then
    raise exception 'record_fx_rate NO puede ser ejecutable por authenticated';
  end if;
  if has_function_privilege('authenticated', 'public.sync_fx_rate(date, boolean)', 'execute') then
    raise exception 'sync_fx_rate NO puede ser ejecutable por authenticated';
  end if;
  if has_function_privilege('anon', 'public.fx_rate_status(text)', 'execute') then
    raise exception 'fx_rate_status no puede ser ejecutable por anon';
  end if;
  if not has_function_privilege('authenticated', 'public.fx_rate_status(text)', 'execute') then
    raise exception 'La app y el panel sí tienen que poder leer el estado de la tasa';
  end if;
  raise notice 'TEST TASA 6 OK — solo el cron escribe la tasa; el cliente solo la lee';

  -- --- 7. La carga a mano, firmada -----------------------------------------
  update public.fx_rate_sources set is_active = true;

  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000091', now(), now(), now()),
    (v_juan,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000092', now(), now(), now());

  insert into public.platform_admins (user_id, role, full_name)
  values (v_admin, 'super_admin', 'Super Test'),
         (v_juan, 'operador', 'Operador Test');

  set local role authenticated;

  -- El operador concilia pagos, pero no decide la tasa del día.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_juan::text, 'role', 'authenticated')::text, true);
  v_failed := false;
  begin
    perform public.admin_set_fx_rate(999.99);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Un operador NO puede cargar la tasa a mano';
  end if;

  -- El super admin sí, y queda en la bitácora.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  v_result := public.admin_set_fx_rate(820.50, null, 'BCV caído, tasa de la web');

  if public.current_fx_rate() is distinct from 820.50 then
    raise exception 'La carga manual debía quedar vigente, salió %', public.current_fx_rate();
  end if;

  -- Ni el super admin puede cargar la tasa de un día que aún no empezó.
  v_failed := false;
  begin
    perform public.admin_set_fx_rate(830.00, v_bd + 1);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'No se puede cargar la tasa de un día futuro';
  end if;

  -- La bitácora no la puede leer `authenticated` — por eso se vuelve a
  -- postgres para comprobarla, igual que en admin_smoke.
  reset role;

  select count(*) into v_logged
  from audit.admin_actions
  where actor = v_admin and action = 'fx_rate.manual';
  if v_logged <> 1 then
    raise exception 'La carga manual debía dejar 1 línea en la bitácora, dejó %', v_logged;
  end if;

  raise notice 'TEST TASA 7 OK — solo el super admin carga la tasa a mano, firmada y nunca a futuro';

  raise notice '=== TODOS LOS TESTS DE LA TASA BCV PASARON ===';
end $$;

rollback;
