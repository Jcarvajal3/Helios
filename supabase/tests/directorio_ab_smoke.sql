-- ============================================================================
-- Helios — La prueba A/B del directorio (20261109130000 y 20261109130100)
--
--   bash supabase/tests/run.sh directorio_ab_smoke
--
-- Contrato: docs/06-PRUEBA-AB-DEL-DIRECTORIO.md y docs/01 §2.17.
--
-- Se comprueba que:
--   1. Permisos: la página (anon) apunta clics y visitas y lee
--      `/consultas`; nadie de la API lee `directory_page_views`; el bot sigue
--      siendo solo de service_role; las cifras son solo del equipo (42501);
--      las firmas viejas ya no existen.
--   2. La regla de B: más de $15 y como mucho $60; en euros, por la tasa
--      cruzada BCV de hoy (no la de mañana); sin precio, oculto o sin tasa
--      del euro, fuera. Mismas columnas que `helios_directorio()` más
--      `consultation_price_usd`, en su mismo orden sorteado.
--   3. El clic: con 3 argumentos nombrados (la página de hoy) y con 2 es
--      'a'; con `p_variante` 'b' (o 'B') es 'b'; cualquier otra cosa, 'a'.
--   4. La visita: se apunta con su origen; la misma página del mismo
--      navegador en 30 minutos no; otra página sí; sin navegador siempre;
--      una variante desconocida no; más de 200 al día no; el equipo va como
--      'equipo'.
--   5. El bot: sin `p_variante` (el webhook de hoy) es 'a'; con 'b' guarda
--      'b'; quien ya había escrito conserva la suya. Devuelve `variante`.
--   6. `admin_directorio_ab`: en un rango sin datos reales (2030), cada cifra
--      exacta; los días vacíos salen; los médicos de B y los que tuvieron
--      clics, el de más clics primero; lo del equipo aparte; los rangos
--      malos son 22023.
--
-- No manda nada: no llama a `helios_dispatch_*` (la orden se crea con
-- `pg_temp.prueba_cobro`, que no despacha).
-- ============================================================================

begin;

-- @ayudas

do $$
declare
  v_admin   uuid;
  v_extrano uuid := gen_random_uuid();
  v_staff   uuid := gen_random_uuid();
  v_pac     uuid := gen_random_uuid();
  v_hoy     date := public.helios_business_date(now());
  v_m40     uuid;
  v_m60     uuid;
  v_m6001   uuid;
  v_m15     uuid;
  v_m1501   uuid;
  v_e50     uuid;
  v_e51     uuid;
  v_e1250   uuid;
  v_sin     uuid;
  v_oculto  uuid;
  v_mios    uuid[];
  v_b       uuid[];
  v_orden_a uuid[];
  v_orden_b uuid[];
  v_branch  uuid;
  v_charge  uuid;
  v_cod40   text;
  v_cod60   text;
  v_fila    record;
  v_fila_b  record;
  v_r       jsonb;
  v_j       jsonb;
  v_c       jsonb;
  v_n       integer;
  v_ok      boolean;
  v_fallo   boolean;
  v_d1      timestamptz := '2030-01-01 10:00'::timestamp at time zone 'America/Caracas';
  v_d2      timestamptz := '2030-01-02 10:00'::timestamp at time zone 'America/Caracas';
  v_d3      timestamptz := '2030-01-03 10:00'::timestamp at time zone 'America/Caracas';
begin
  update public.platform_maintenance set is_active = false;
  update public.levels set monthly_limit_usd = 500 where level = 1;
  update public.platform_contact set whatsapp_number = '+584120009700' where id;

  v_admin := pg_temp.prueba_admin();
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_staff, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'u-' || v_staff || '@prueba.helios.test', now(), now(), now());

  -- Tasas de hoy fijas: 400 Bs el dólar y 480 Bs el euro → 1 € = 1,2 $.
  -- Una de mañana, absurda, no debe contar.
  insert into public.exchange_rates (source, rate, effective_date)
  values ('BCV', 400, v_hoy), ('BCV_EUR', 480, v_hoy), ('BCV_EUR', 4800, v_hoy + 1)
  on conflict (source, effective_date) do update set rate = excluded.rate;

  insert into public.merchants (name, owner_name, doctor_title, specialty, phone)
  values ('Consultorio AB 40', 'Ana Prueba', 'Dra.', 'Dermatología', '0414-999.31.01') returning id into v_m40;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB 60', 'Beto Prueba', 'Dr.', '0414-999.31.02') returning id into v_m60;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB 6001', 'Carla Prueba', 'Dra.', '0414-999.31.03') returning id into v_m6001;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB 15', 'Dario Prueba', 'Dr.', '0414-999.31.04') returning id into v_m15;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB 1501', 'Elena Prueba', 'Dra.', '0414-999.31.05') returning id into v_m1501;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB E50', 'Fabio Prueba', 'Dr.', '0414-999.31.06') returning id into v_e50;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB E51', 'Gina Prueba', 'Dra.', '0414-999.31.07') returning id into v_e51;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB E1250', 'Hugo Prueba', 'Dr.', '0414-999.31.08') returning id into v_e1250;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB Sin', 'Ines Prueba', 'Dra.', '0414-999.31.09') returning id into v_sin;
  insert into public.merchants (name, owner_name, doctor_title, phone)
  values ('Consultorio AB Oculto', 'Juan Prueba', 'Dr.', '0414-999.31.10') returning id into v_oculto;

  insert into public.directory_listings
    (merchant_id, is_visible, published_at, consultation_price_cur, consultation_currency)
  values (v_m40,    true,  now(), 40,    'USD'),
         (v_m60,    true,  now(), 60,    'USD'),
         (v_m6001,  true,  now(), 60.01, 'USD'),
         (v_m15,    true,  now(), 15,    'USD'),
         (v_m1501,  true,  now(), 15.01, 'USD'),
         (v_e50,    true,  now(), 50,    'EUR'),
         (v_e51,    true,  now(), 51,    'EUR'),
         (v_e1250,  true,  now(), 12.50, 'EUR'),
         (v_sin,    true,  now(), null,  'USD'),
         (v_oculto, false, null,  40,    'USD');

  v_mios := array[v_m40, v_m60, v_m6001, v_m15, v_m1501, v_e50, v_e51, v_e1250, v_sin, v_oculto];
  select lead_code into v_cod40 from public.directory_listings where merchant_id = v_m40;
  select lead_code into v_cod60 from public.directory_listings where merchant_id = v_m60;

  -- =========================================================================
  -- 1. Permisos
  -- =========================================================================
  if to_regprocedure('public.helios_directorio_contacto(uuid, text, jsonb)') is not null
     or to_regprocedure('public.bot_directorio_interesado(text, text, text)') is not null then
    raise exception '1. quedó una firma vieja (contacto de 3 o bot de 3)';
  end if;
  if not has_function_privilege('anon', 'public.helios_directorio_contacto(uuid, text, jsonb, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.helios_directorio_contacto(uuid, text, jsonb, text)', 'execute')
     or not has_function_privilege('anon', 'public.helios_directorio_visita(text, text, jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.helios_directorio_visita(text, text, jsonb)', 'execute')
     or not has_function_privilege('anon', 'public.helios_directorio_consultas()', 'execute')
     or not has_function_privilege('authenticated', 'public.helios_directorio_consultas()', 'execute') then
    raise exception '1. la página no puede apuntar clics o visitas o leer /consultas';
  end if;
  if has_function_privilege('anon', 'public.bot_directorio_interesado(text, text, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.bot_directorio_interesado(text, text, text, text)', 'execute')
     or not has_function_privilege('service_role', 'public.bot_directorio_interesado(text, text, text, text)', 'execute') then
    raise exception '1. bot_directorio_interesado debía ser solo de service_role';
  end if;
  if has_function_privilege('anon', 'public.admin_directorio_ab(date, date)', 'execute') then
    raise exception '1. anon no debía llamar a admin_directorio_ab';
  end if;
  if has_function_privilege('anon', 'public.helios_directorio_precio_usd(numeric, text)', 'execute')
     or has_function_privilege('authenticated', 'public.helios_directorio_precio_usd(numeric, text)', 'execute') then
    raise exception '1. helios_directorio_precio_usd no se expone';
  end if;
  if has_table_privilege('anon', 'public.directory_page_views', 'select')
     or has_table_privilege('authenticated', 'public.directory_page_views', 'select')
     or has_table_privilege('anon', 'public.directory_page_views', 'insert')
     or has_table_privilege('authenticated', 'public.directory_page_views', 'insert') then
    raise exception '1. la API no debía tocar directory_page_views';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.directory_page_views'::regclass) then
    raise exception '1. directory_page_views sin RLS';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_extrano::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_fallo := false;
  begin
    perform public.admin_directorio_ab(v_hoy - 6, v_hoy);
  exception when sqlstate '42501' then v_fallo := true;
  end;
  if not v_fallo then reset role; raise exception '1. alguien de fuera del equipo leyó la prueba A/B'; end if;
  v_fallo := false;
  begin
    perform count(*) from public.directory_page_views;
  exception when insufficient_privilege then v_fallo := true;
  end;
  reset role;
  if not v_fallo then raise exception '1. alguien con sesión leyó las visitas'; end if;

  -- =========================================================================
  -- 2. La regla de B
  -- =========================================================================
  if public.helios_consultas_tope_usd() <> 60 or public.helios_consultas_inicial_usd() <> 15 then
    raise exception '2. el tope o la inicial no son 60 y 15';
  end if;
  if public.helios_directorio_precio_usd(50, 'EUR') <> 60.00
     or public.helios_directorio_precio_usd(40, 'USD') <> 40.00
     or public.helios_directorio_precio_usd(null, 'USD') is not null
     or public.helios_directorio_precio_usd(40, 'VES') is not null then
    raise exception '2. el precio en dólares no cuadra: %, %',
      public.helios_directorio_precio_usd(50, 'EUR'), public.helios_directorio_precio_usd(40, 'USD');
  end if;

  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  select array_agg(c.merchant_id order by c.merchant_id) into v_b
    from public.helios_directorio_consultas() c
   where c.merchant_id = any (v_mios);
  select * into v_fila from public.helios_directorio_consultas() c where c.merchant_id = v_e50;
  select * into v_fila_b from public.helios_directorio() d where d.merchant_id = v_e50;
  reset role;

  if v_b is distinct from (select array_agg(x order by x) from unnest(array[v_m40, v_m60, v_m1501, v_e50]) x) then
    raise exception '2. /consultas no trae a los que tocan (40, 60, 15,01 y €50): %', v_b;
  end if;
  if v_fila.consultation_price_usd <> 60.00 or v_fila.consultation_price_cur <> 50
     or v_fila.consultation_currency <> 'EUR' then
    raise exception '2. el médico en euros no trae su precio en dólares: %', row_to_json(v_fila);
  end if;
  -- Las mismas columnas, con los mismos valores, que helios_directorio().
  if (to_jsonb(v_fila) - 'consultation_price_usd') <> to_jsonb(v_fila_b) then
    raise exception '2. las columnas no son las de helios_directorio(): % / %', to_jsonb(v_fila), to_jsonb(v_fila_b);
  end if;
  if (select array_agg(a.attname::text order by a.attnum)
        from unnest(array['merchant_id', 'name', 'specialty', 'specialty_key', 'address', 'city', 'whatsapp',
                          'social_network', 'social_user', 'lead_code', 'slug', 'updated_at',
                          'consultation_price_cur', 'consultation_currency', 'consultation_price_usd'])
             with ordinality a(attname, attnum))
     is distinct from
     (select array_agg(n order by i)
        from unnest((select proargnames from pg_proc where oid = 'public.helios_directorio_consultas()'::regprocedure))
             with ordinality u(n, i)) then
    raise exception '2. las columnas de helios_directorio_consultas() no van en el orden del contrato';
  end if;

  -- El mismo orden sorteado: con la misma semilla, la lista de B es la de
  -- helios_directorio() sin los que no entran.
  set local role anon;
  perform setseed(0.42);
  select array_agg(t.merchant_id order by t.n) into v_orden_a
    from public.helios_directorio() with ordinality as t(
           merchant_id, name, specialty, specialty_key, address, city, whatsapp,
           social_network, social_user, lead_code, slug, updated_at,
           consultation_price_cur, consultation_currency, n);
  perform setseed(0.42);
  select array_agg(t.merchant_id order by t.n) into v_orden_b
    from public.helios_directorio_consultas() with ordinality as t(
           merchant_id, name, specialty, specialty_key, address, city, whatsapp,
           social_network, social_user, lead_code, slug, updated_at,
           consultation_price_cur, consultation_currency, consultation_price_usd, n);
  reset role;
  if v_orden_b is distinct from
     array(select x from unnest(v_orden_a) with ordinality u(x, i) where x = any (v_orden_b) order by i) then
    raise exception '2. /consultas no conserva el orden sorteado de helios_directorio()';
  end if;
  if array_length(v_orden_b, 1) < 4 then
    raise exception '2. el orden se comparó con muy pocos médicos: %', v_orden_b;
  end if;

  -- =========================================================================
  -- 3. El clic, con su variante
  -- =========================================================================
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  -- Como la página publicada hoy: 3 argumentos nombrados.
  v_ok := public.helios_directorio_contacto(
    p_merchant_id => v_m40, p_visitante => 'visitante-ab-c1',
    p_origen => '{"fuente": "google", "pagina": "/directorio"}'::jsonb);
  if not v_ok then reset role; raise exception '3. el clic con 3 argumentos nombrados no se apuntó'; end if;
  -- Con 2 (como las suites viejas).
  if not public.helios_directorio_contacto(v_m40, 'visitante-ab-c2') then
    reset role; raise exception '3. el clic con 2 argumentos no se apuntó';
  end if;
  if not public.helios_directorio_contacto(
       p_merchant_id => v_m40, p_visitante => 'visitante-ab-c3',
       p_origen => '{"pagina": "/consultas"}'::jsonb, p_variante => 'b') then
    reset role; raise exception '3. el clic de B no se apuntó';
  end if;
  if not public.helios_directorio_contacto(v_m60, 'visitante-ab-c4', null, 'B') then
    reset role; raise exception '3. el clic de B en mayúscula no se apuntó';
  end if;
  if not public.helios_directorio_contacto(v_m60, 'visitante-ab-c5', null, 'zzz')
     or not public.helios_directorio_contacto(v_m60, 'visitante-ab-c6', null, null) then
    reset role; raise exception '3. un clic con variante rara no se apuntó';
  end if;
  -- El doble toque sigue descartándose.
  if public.helios_directorio_contacto(v_m40, 'visitante-ab-c3', null, 'b') then
    reset role; raise exception '3. el doble toque en 30 s se apuntó';
  end if;
  reset role;

  if (select string_agg(c.visitor_id || '=' || c.variant, ',' order by c.visitor_id)
        from public.directory_contact_clicks c where c.visitor_id like 'visitante-ab-c%')
     <> 'visitante-ab-c1=a,visitante-ab-c2=a,visitante-ab-c3=b,visitante-ab-c4=b,visitante-ab-c5=a,visitante-ab-c6=a' then
    raise exception '3. las variantes de los clics no cuadran: %',
      (select string_agg(c.visitor_id || '=' || c.variant, ',' order by c.visitor_id)
         from public.directory_contact_clicks c where c.visitor_id like 'visitante-ab-c%');
  end if;
  if (select c.source || ' ' || c.page_path || ' ' || c.origin from public.directory_contact_clicks c
       where c.visitor_id = 'visitante-ab-c1') <> 'google /directorio publico' then
    raise exception '3. el clic perdió su origen';
  end if;

  -- =========================================================================
  -- 4. La visita
  -- =========================================================================
  set local role anon;
  perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  if not public.helios_directorio_visita('b', 'visitante-ab-v1',
           '{"fuente": "instagram", "dominio": "l.instagram.com", "entrada": "/consultas", "pagina": "/consultas", "utm_source": "ig", "utm_medium": "ads", "utm_campaign": "inicial15"}') then
    reset role; raise exception '4. la primera visita no se apuntó';
  end if;
  if public.helios_directorio_visita('b', 'visitante-ab-v1', '{"pagina": "/consultas"}') then
    reset role; raise exception '4. la misma página en 30 minutos se apuntó dos veces';
  end if;
  if not public.helios_directorio_visita('a', 'visitante-ab-v1', '{"pagina": "/directorio"}') then
    reset role; raise exception '4. otra página del mismo navegador no se apuntó';
  end if;
  if not public.helios_directorio_visita('A', 'visitante-ab-v1', '{"pagina": "/medico/dra-ana"}') then
    reset role; raise exception '4. la variante en mayúscula no se apuntó';
  end if;
  if public.helios_directorio_visita('c', 'visitante-ab-v2', '{"pagina": "/consultas"}')
     or public.helios_directorio_visita(null, 'visitante-ab-v2', '{"pagina": "/consultas"}') then
    reset role; raise exception '4. una variante desconocida se apuntó';
  end if;
  -- Sin navegador no hay cómo descartar: se apunta.
  if not public.helios_directorio_visita('b') or not public.helios_directorio_visita('b', '<script>') then
    reset role; raise exception '4. una visita sin navegador no se apuntó';
  end if;
  -- Datos malformados: se descartan, la visita no.
  if not public.helios_directorio_visita('a', 'visitante-ab-v3',
           '{"fuente": "GOOGLE!!", "dominio": "ex ample.com", "entrada": "sin-barra", "pagina": "/directorio"}') then
    reset role; raise exception '4. una visita con datos malformados no se apuntó';
  end if;
  reset role;

  select * into v_fila from public.directory_page_views
   where visitor_id = 'visitante-ab-v1' and variant = 'b';
  if v_fila.origin <> 'publico' or v_fila.source <> 'instagram' or v_fila.referrer_host <> 'l.instagram.com'
     or v_fila.landing_path <> '/consultas' or v_fila.page_path <> '/consultas' or v_fila.utm_source <> 'ig'
     or v_fila.utm_medium <> 'ads' or v_fila.utm_campaign <> 'inicial15' then
    raise exception '4. la visita no guardó su origen: %', row_to_json(v_fila);
  end if;
  if (select count(*) from public.directory_page_views where visitor_id = 'visitante-ab-v1') <> 3 then
    raise exception '4. el navegador v1 debía tener 3 visitas';
  end if;
  if (select count(*) from public.directory_page_views where visitor_id is null) < 2 then
    raise exception '4. las visitas sin navegador no se apuntaron';
  end if;
  select * into v_fila from public.directory_page_views where visitor_id = 'visitante-ab-v3';
  if v_fila.source is not null or v_fila.referrer_host is not null or v_fila.landing_path is not null
     or v_fila.page_path <> '/directorio' then
    raise exception '4. no descartó los datos malformados: %', row_to_json(v_fila);
  end if;

  -- Más de 200 al día, no.
  insert into public.directory_page_views (variant, visitor_id, page_path)
  select 'a', 'visitante-ab-lleno', '/medico/m-' || g from generate_series(1, 200) g;
  set local role anon;
  v_ok := public.helios_directorio_visita('a', 'visitante-ab-lleno', '{"pagina": "/directorio"}');
  reset role;
  if v_ok then raise exception '4. la visita 201 del día se apuntó'; end if;

  -- El equipo no cuenta como público.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_ok := public.helios_directorio_visita('b', 'visitante-ab-admin', '{"pagina": "/consultas"}');
  reset role;
  if not v_ok or (select origin from public.directory_page_views where visitor_id = 'visitante-ab-admin') <> 'equipo' then
    raise exception '4. la visita del equipo no quedó como equipo';
  end if;

  -- =========================================================================
  -- 5. El bot
  -- =========================================================================
  set local role service_role;
  -- El webhook de hoy: sin p_variante (nombrados, como supabase-js).
  v_r := public.bot_directorio_interesado(p_phone => '584140009741', p_code => v_cod40, p_message_id => 'wamid.ab.1');
  reset role;
  if not (v_r ->> 'ok')::boolean or not (v_r ->> 'nuevo')::boolean or v_r ->> 'variante' <> 'a'
     or v_r ->> 'merchant_id' <> v_m40::text or v_r ->> 'name' is null then
    raise exception '5. sin p_variante debía crear un interesado de A: %', v_r;
  end if;

  set local role service_role;
  v_r := public.bot_directorio_interesado('584140009742', ' ' || lower(v_cod40) || ' ', 'wamid.ab.2', 'b');
  reset role;
  if not (v_r ->> 'nuevo')::boolean or v_r ->> 'variante' <> 'b'
     or (select variant from public.directory_leads where id = (v_r ->> 'lead_id')::uuid) <> 'b' then
    raise exception '5. con b debía crear un interesado de B: %', v_r;
  end if;

  -- Quien ya escribió desde A y vuelve desde B conserva la suya.
  set local role service_role;
  v_r := public.bot_directorio_interesado('584140009741', v_cod40, 'wamid.ab.3', 'b');
  reset role;
  if (v_r ->> 'nuevo')::boolean or v_r ->> 'variante' <> 'a' or (v_r ->> 'messages')::int <> 2 then
    raise exception '5. el interesado de A cambió de variante o no sumó: %', v_r;
  end if;

  -- Los motivos de siempre siguen igual.
  set local role service_role;
  v_r := public.bot_directorio_interesado('584140009741', 'DIR-0000', 'wamid.ab.4', 'b');
  reset role;
  if v_r <> '{"ok": false, "motivo": "codigo_desconocido"}'::jsonb then
    raise exception '5. un código desconocido debía dar codigo_desconocido: %', v_r;
  end if;

  -- =========================================================================
  -- 6. admin_directorio_ab, en 2030 (sin datos reales)
  -- =========================================================================
  -- Visitas. A: v1 dos páginas el día 1, v2 el día 1, una sin navegador el
  -- día 2 → 4 visitas, 3 visitantes. B: uno cada día → 3 y 3. Una del equipo.
  insert into public.directory_page_views (variant, visitor_id, origin, page_path, created_at)
  values ('a', 'visitante-ab-va1', 'publico', '/directorio', v_d1),
         ('a', 'visitante-ab-va1', 'publico', '/medico/x',   v_d1),
         ('a', 'visitante-ab-va2', 'publico', '/directorio', v_d1),
         ('a', null,     'publico', '/directorio', v_d2),
         ('b', 'visitante-ab-vb1', 'publico', '/consultas',  v_d1),
         ('b', 'visitante-ab-vb2', 'publico', '/consultas',  v_d2),
         ('b', 'visitante-ab-vb3', 'publico', '/consultas',  v_d3),
         ('a', 'visitante-ab-eq1', 'equipo',  '/directorio', v_d1);

  -- Clics. A: va1 a m40 el día 1; uno sin navegador a m6001 el día 3 → 2
  -- clics, 1 visitante que tocó (el clic sin navegador no tiene visita: no cuenta
  -- en la tasa, 20261109140000). B: vb1 a m40 y a m60 el día 1, vb2 a e50 el día 2 →
  -- 3 clics, 2 visitantes. Uno de una clínica.
  insert into public.directory_contact_clicks (merchant_id, visitor_id, origin, variant, created_at)
  values (v_m40,   'visitante-ab-va1', 'publico', 'a', v_d1),
         (v_m6001, null,     'publico', 'a', v_d3),
         (v_m40,   'visitante-ab-vb1', 'publico', 'b', v_d1),
         (v_m60,   'visitante-ab-vb1', 'publico', 'b', v_d1 + interval '1 minute'),
         (v_e50,   'visitante-ab-vb2', 'publico', 'b', v_d2),
         (v_m40,   'visitante-ab-cl1', 'clinica', 'a', v_d2);

  -- Interesados. B: uno de m40 el día 1 (se convierte) y uno de m60 el día 2;
  -- uno de B de antes del rango no cuenta. A: uno de m40 el día 1.
  insert into public.directory_leads (merchant_id, phone_e164, first_message_id, variant, first_at, last_at)
  values (v_m40, '+584140009751', 'wamid.ab.r1', 'b', v_d1, v_d1),
         (v_m60, '+584140009752', 'wamid.ab.r2', 'b', v_d2, v_d2),
         (v_m60, '+584140009753', 'wamid.ab.r3', 'b', v_d1 - interval '2 days', v_d1 - interval '2 days'),
         (v_m40, '+584140009754', 'wamid.ab.r4', 'a', v_d1, v_d1);

  insert into public.profiles (id, phone_e164, first_name, full_name)
  values (v_pac, '+584140009751', 'Paula', 'Paula Prueba AB');
  select id into v_branch from public.merchant_branches where merchant_id = v_m40 and is_default;
  v_charge := (pg_temp.prueba_cobro(v_pac, v_m40, v_branch, v_staff, 40.00, 'dir-ab-conv')->>'charge_id')::uuid;
  update public.charges set created_at = v_d1 + interval '2 hours' where id = v_charge;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_directorio_ab('2030-01-01', '2030-01-03');
  reset role;

  if v_j ->> 'desde' <> '2030-01-01' or v_j ->> 'hasta' <> '2030-01-03' then
    raise exception '6. el rango no vuelve: % / %', v_j ->> 'desde', v_j ->> 'hasta';
  end if;
  if v_j -> 'variantes' -> 0 <> '{"variante": "a", "ruta": "/directorio", "visitas": 4, "visitantes": 3,
                                  "clics": 2, "visitantes_con_clic": 1, "interesados": 1, "convertidos": 0}'::jsonb then
    raise exception '6. las cifras de A no cuadran: %', v_j -> 'variantes' -> 0;
  end if;
  if v_j -> 'variantes' -> 1 <> '{"variante": "b", "ruta": "/consultas", "visitas": 3, "visitantes": 3,
                                  "clics": 3, "visitantes_con_clic": 2, "interesados": 2, "convertidos": 1}'::jsonb then
    raise exception '6. las cifras de B no cuadran: %', v_j -> 'variantes' -> 1;
  end if;
  if v_j -> 'dias' <> '[
        {"dia": "2030-01-01", "a": {"visitantes": 2, "visitantes_con_clic": 1, "clics": 1},
                              "b": {"visitantes": 1, "visitantes_con_clic": 1, "clics": 2}},
        {"dia": "2030-01-02", "a": {"visitantes": 1, "visitantes_con_clic": 0, "clics": 0},
                              "b": {"visitantes": 1, "visitantes_con_clic": 1, "clics": 1}},
        {"dia": "2030-01-03", "a": {"visitantes": 0, "visitantes_con_clic": 0, "clics": 1},
                              "b": {"visitantes": 1, "visitantes_con_clic": 0, "clics": 0}}]'::jsonb then
    raise exception '6. la serie diaria no cuadra: %', v_j -> 'dias';
  end if;
  if v_j -> 'excluidos' <> '{"visitas_equipo": 1, "clics_equipo": 1}'::jsonb then
    raise exception '6. lo excluido no cuadra: %', v_j -> 'excluidos';
  end if;
  -- La primera visita apuntada: hoy, o antes si ya había reales (las de 2030
  -- son posteriores).
  if v_j ->> 'visitas_desde' is null or (v_j ->> 'visitas_desde')::date > v_hoy then
    raise exception '6. visitas_desde debía ser hoy o antes: %', v_j ->> 'visitas_desde';
  end if;

  -- Los médicos: m40 primero (2 clics); los de B aunque no tengan clics; m6001
  -- por su clic aunque no entre en B; m15, e51, e1250, sin precio y oculto no.
  if v_j -> 'medicos' -> 0 ->> 'merchant_id' <> v_m40::text then
    raise exception '6. el de más clics no va primero: %', v_j -> 'medicos' -> 0;
  end if;
  if (v_j -> 'medicos' -> 0) - 'medico' <> jsonb_build_object(
       'merchant_id', v_m40, 'precio_cur', 40, 'moneda', 'USD', 'en_b', true,
       'clics_a', 1, 'clics_b', 1, 'interesados_b', 1, 'convertidos_b', 1)
     or v_j -> 'medicos' -> 0 ->> 'medico' is null then
    raise exception '6. la fila de m40 no cuadra: %', v_j -> 'medicos' -> 0;
  end if;
  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_e50::text;
  if v_c is null or v_c ->> 'moneda' <> 'EUR' or (v_c ->> 'precio_cur')::numeric <> 50
     or not (v_c ->> 'en_b')::boolean or (v_c ->> 'clics_b')::int <> 1 then
    raise exception '6. la fila de e50 no cuadra: %', v_c;
  end if;
  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_m60::text;
  if v_c is null or (v_c ->> 'interesados_b')::int <> 1 or (v_c ->> 'convertidos_b')::int <> 0 then
    raise exception '6. la fila de m60 no cuadra: %', v_c;
  end if;
  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_m6001::text;
  if v_c is null or (v_c ->> 'en_b')::boolean or (v_c ->> 'clics_a')::int <> 1 then
    raise exception '6. m6001 debía salir por su clic, fuera de B: %', v_c;
  end if;
  select e into v_c from jsonb_array_elements(v_j -> 'medicos') e where e ->> 'merchant_id' = v_m1501::text;
  if v_c is null or not (v_c ->> 'en_b')::boolean or (v_c ->> 'clics_a')::int + (v_c ->> 'clics_b')::int <> 0 then
    raise exception '6. m1501 debía salir por estar en B: %', v_c;
  end if;
  if exists (select 1 from jsonb_array_elements(v_j -> 'medicos') e
              where e ->> 'merchant_id' in (v_m15::text, v_e51::text, v_e1250::text, v_sin::text, v_oculto::text)) then
    raise exception '6. salió un médico que no está en B y no tuvo clics';
  end if;

  -- Los rangos.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v_j := public.admin_directorio_ab('2030-01-01', '2031-01-01');
  if jsonb_array_length(v_j -> 'dias') <> 366 then
    reset role; raise exception '6. 366 días debían valer: %', jsonb_array_length(v_j -> 'dias');
  end if;
  v_fallo := false;
  begin
    perform public.admin_directorio_ab('2030-01-01', '2031-01-02');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then reset role; raise exception '6. 367 días no debían valer'; end if;
  v_fallo := false;
  begin
    perform public.admin_directorio_ab('2030-01-02', '2030-01-01');
  exception when sqlstate '22023' then v_fallo := true;
  end;
  if not v_fallo then reset role; raise exception '6. un rango al revés no debía valer'; end if;
  -- Sin fechas: los 7 días que acaban hoy; hoy trae las visitas de arriba.
  v_j := public.admin_directorio_ab(null, null);
  reset role;
  if jsonb_array_length(v_j -> 'dias') <> 7 or v_j ->> 'hasta' <> v_hoy::text then
    raise exception '6. sin fechas debían ser los 7 días hasta hoy: % / %', v_j ->> 'hasta', jsonb_array_length(v_j -> 'dias');
  end if;
  if (v_j -> 'variantes' -> 1 ->> 'visitas')::int < 3 or (v_j -> 'variantes' -> 1 ->> 'clics')::int < 2 then
    raise exception '6. hoy no trae las visitas y los clics de B de arriba: %', v_j -> 'variantes' -> 1;
  end if;

  -- =========================================================================
  -- 2 (bis). Sin tasa del euro, el de euros no entra
  -- =========================================================================
  delete from public.exchange_rates where source = 'BCV_EUR';
  if public.helios_directorio_precio_usd(50, 'EUR') is not null then
    raise exception '2. sin tasa del euro debía no haber precio en dólares';
  end if;
  set local role anon;
  select count(*) into v_n from public.helios_directorio_consultas() c where c.merchant_id = v_e50;
  v_ok := exists (select 1 from public.helios_directorio_consultas() c where c.merchant_id = v_m40);
  reset role;
  if v_n <> 0 or not v_ok then
    raise exception '2. sin tasa del euro, e50 debía salir de /consultas (y m40 quedarse)';
  end if;
end;
$$;

rollback;
