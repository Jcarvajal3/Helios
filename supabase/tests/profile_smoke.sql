-- ============================================================================
-- Ronda — Prueba de humo de la sección de Perfil
--
-- docker exec -i supabase_db_Ronda-app psql -U postgres -d postgres \
--   -v ON_ERROR_STOP=1 -f supabase/tests/profile_smoke.sql
--
-- Lo que de verdad hay que blindar aquí:
--
--   · El historial de un cobro de GRUPO visto por quien NO escaneó. Es el
--     caso que la lectura directa de `charges` no puede resolver —su política
--     filtra por `user_id`, que en un cobro de grupo es el del iniciador— y
--     el motivo de que `my_purchases` exista.
--   · Que el predeterminado de los métodos de pago sea siempre exactamente
--     uno: ni dos (el índice único parcial) ni cero (borrar el que estaba).
-- ============================================================================

begin;

do $$
declare
  v_ana      uuid := gen_random_uuid();
  v_luis     uuid := gen_random_uuid();
  v_cajero   uuid := gen_random_uuid();
  v_merchant uuid;
  v_branch   uuid;
  v_group    uuid;
  v_charge   uuid;
  v_charge2  uuid;
  v_result   jsonb;
  v_rows     jsonb;
  v_row      jsonb;
  /** El importe del cobro de grupo, leído SIN rol de usuario: un cobro
   *  pendiente no tiene dueño y RLS lo esconde de `authenticated`. */
  v_amount2  numeric;
  v_id1      uuid;
  v_id2      uuid;
  v_count    integer;
  v_failed   boolean;
  v_phone    text;
  v_pin_user   uuid;
begin
  -- --- Fixtures ------------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, phone, phone_confirmed_at, created_at, updated_at)
  values
    (v_ana,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000201', now(), now(), now()),
    (v_luis,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000202', now(), now(), now()),
    (v_cajero, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '584140000203', now(), now(), now());

  update public.profiles set status = 'active', level = 3, full_name = 'Ana'  where id = v_ana;
  update public.profiles set status = 'active', level = 3, full_name = 'Luis' where id = v_luis;

  insert into public.merchants (name) values ('Bar Perfil') returning id into v_merchant;
  select id into v_branch from public.merchant_branches where merchant_id = v_merchant and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_cajero, v_merchant, v_branch, 'cajero');

  -- --- PIN de la prueba --------------------------------------------------
  -- Desde 20260824170000 confirmar un cobro exige PIN, así que toda prueba
  -- que pague necesita uno. Se le pone '7391' a quien no lo tenga, y se pasa
  -- por `set_user_pin` en vez de escribir el hash a mano: el día que cambie
  -- cómo se guarda, esto sigue valiendo.
  --
  -- El pepper de Vault se siembra si falta: una base de desarrollo recién
  -- levantada no lo trae, y sin él no se puede confirmar ni un consumo. Todo
  -- vive dentro de la transacción, que termina en rollback.
  if not exists (select 1 from vault.decrypted_secrets where name = 'pin_pepper') then
    perform vault.create_secret('smoke-pepper-0123456789', 'pin_pepper');
  end if;

  for v_pin_user in
    select p.id from public.profiles p
    where not exists (select 1 from public.user_pins up where up.user_id = p.id)
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_pin_user::text, 'role', 'authenticated')::text, true);
    perform public.set_user_pin('7391');
  end loop;
  perform set_config('request.jwt.claims', '', true);

  -- --- 1. Compra individual en el historial --------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);

  select (public.request_charge(
    v_merchant, v_branch,
    '[{"name": "Botella", "unit_price_usd": 30.00, "quantity": 1},
      {"name": "Hielo",   "unit_price_usd": 2.50,  "quantity": 2}]'::jsonb,
    'perfil-1'
  )).id into v_charge;

  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  perform public.confirm_charge(v_charge, 'perfil-1-confirm', '7391');

  v_rows := public.my_purchases();
  if jsonb_array_length(v_rows) <> 1 then
    raise exception 'Ana debía tener 1 compra, tiene %', jsonb_array_length(v_rows);
  end if;

  v_row := v_rows->0;

  if (v_row->>'is_group')::boolean then
    raise exception 'La compra no era de grupo: %', v_row;
  end if;
  if (v_row->>'split_between')::int <> 1 then
    raise exception 'Una compra individual se reparte entre 1: %', v_row->>'split_between';
  end if;
  -- Contra lo que guardó la base: lo que se cobra lleva IVA y comisión desde
  -- 20260827100000 (ver la nota en `ledger_smoke`). Lo que esta prueba afirma
  -- es que en una compra individual mi parte ES el total, no una cifra fija.
  if (v_row->>'my_usd')::numeric <> (v_row->>'total_usd')::numeric
     or (v_row->>'total_usd')::numeric <> (select amount_usd from public.charges where id = v_charge) then
    raise exception 'En una compra individual mi parte es el total: %', v_row;
  end if;
  if (v_row->>'pending_usd')::numeric <> (v_row->>'total_usd')::numeric
     or (v_row->>'paid_usd')::numeric <> 0 then
    raise exception 'Recién comprada, todo está pendiente: %', v_row;
  end if;
  if jsonb_array_length(v_row->'installments') <> 2 then
    raise exception 'Debían venir las 2 cuotas: %', v_row->'installments';
  end if;
  if jsonb_array_length(v_row->'items') <> 2 then
    raise exception 'Debían venir las 2 líneas del consumo: %', v_row->'items';
  end if;
  if (v_row->>'order_number') is null or (v_row->>'merchant_name') <> 'Bar Perfil' then
    raise exception 'Faltan el número de orden o el comercio: %', v_row;
  end if;

  raise notice 'TEST PERFIL 1 OK — orden #% de % en %, individual',
    v_row->>'order_number', v_row->>'my_usd', v_row->>'merchant_name';

  -- --- 2. Compra de grupo vista por quien NO escaneó ------------------------
  -- Ana crea el grupo, Luis entra, Ana escanea. El historial de LUIS tiene
  -- que enseñar el comercio, la fecha y su parte, aunque el cobro sea de Ana.
  v_result := public.create_group('Perfil Test', 30.00, '7391');
  v_group := (v_result->>'group_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);
  -- Cada quien pone su propio techo al entrar desde 20260828000000: el grupo
  -- ya no tiene una cifra común, así que el código va acompañado del techo
  -- propio y del PIN.
  perform public.join_group(v_result->>'invite_code', 30.00, '7391');

  perform set_config('request.jwt.claims', json_build_object('sub', v_cajero::text, 'role', 'authenticated')::text, true);
  select (public.request_charge(
    v_merchant, v_branch,
    '[{"name": "Mesa", "unit_price_usd": 40.00, "quantity": 1}]'::jsonb,
    'perfil-2'  -- $40 de base: con IVA y comisión sube a ~$51, y los dos techos suman $60
  )).id into v_charge2;

  -- El importe autorizado se lee con el rol RESETEADO: un cobro pendiente
  -- todavía no tiene dueño, así que RLS lo esconde de `authenticated` y la
  -- consulta devolvería null. En la app este dato no sale de la tabla sino de
  -- `preview_group_charge`, que es `security definer`.
  reset role;
  select amount_usd into v_amount2 from public.charges where id = v_charge2;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  perform public.confirm_charge_as_group(v_charge2, v_group, 'perfil-2-grupo', '7391', v_amount2);

  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);
  v_rows := public.my_purchases();

  if jsonb_array_length(v_rows) <> 1 then
    raise exception 'Luis debía tener 1 compra (la del grupo), tiene %', jsonb_array_length(v_rows);
  end if;

  v_row := v_rows->0;

  if not (v_row->>'is_group')::boolean then
    raise exception 'La compra de Luis era de grupo: %', v_row;
  end if;
  if (v_row->>'merchant_name') <> 'Bar Perfil' then
    raise exception 'Luis tiene que ver el comercio aunque el cobro sea de Ana: %', v_row;
  end if;
  -- El total es el importe real del cobro, con IVA y comisión.
  if (v_row->>'total_usd')::numeric <> v_amount2 then
    raise exception 'El total es la cuenta entera (%): %', v_amount2, v_row->>'total_usd';
  end if;
  -- Y la parte de Luis, la mitad exacta: dos techos iguales sobre la misma
  -- cuenta reparten parejo.
  if (v_row->>'my_usd')::numeric <> round(v_amount2 / 2, 2) then
    raise exception 'La parte de Luis era la mitad de % entre 2: %', v_amount2, v_row->>'my_usd';
  end if;
  if (v_row->>'split_between')::int <> 2 then
    raise exception 'Se repartió entre 2: %', v_row->>'split_between';
  end if;
  if (v_row->>'i_started_it')::boolean then
    raise exception 'Luis no escaneó: i_started_it debía ser false';
  end if;
  if (v_row->>'group_name') <> 'Perfil Test' then
    raise exception 'Falta el nombre del grupo: %', v_row;
  end if;

  raise notice 'TEST PERFIL 2 OK — Luis ve su $% de una cuenta de $% entre %, sin haber escaneado',
    v_row->>'my_usd', v_row->>'total_usd', v_row->>'split_between';

  -- --- 3. Cada quien ve solo lo suyo ---------------------------------------
  /**
   * Se separan los dos consumos en el tiempo antes de comprobar el orden.
   *
   * `now()` es constante dentro de una transacción, así que los dos cobros de
   * esta prueba quedaban con el MISMO `confirmed_at` y "la más reciente
   * primero" se resolvía por desempate arbitrario: la comprobación pasaba o
   * fallaba por suerte. Empujando uno un minuto, lo que se comprueba es el
   * orden de verdad.
   */
  reset role;
  update public.charges set confirmed_at = confirmed_at + interval '1 minute'
  where id = v_charge2;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_ana::text, 'role', 'authenticated')::text, true);
  v_rows := public.my_purchases();
  if jsonb_array_length(v_rows) <> 2 then
    raise exception 'Ana tiene 2 compras (la suya y la del grupo), tiene %', jsonb_array_length(v_rows);
  end if;
  -- La más reciente primero.
  if (v_rows->0->>'charge_id')::uuid <> v_charge2 then
    raise exception 'El historial va de lo más reciente a lo más viejo: %', v_rows;
  end if;
  raise notice 'TEST PERFIL 3 OK — Ana ve sus 2 compras, la más reciente primero';

  -- --- 4. Guardar un método de pago ----------------------------------------
  v_id1 := public.save_payment_method('Banesco', 'V-12345678', '04141234567', false);

  select count(*) into v_count
  from public.user_payment_methods where user_id = v_ana and is_default;
  if v_count <> 1 then
    raise exception 'El primer método es el predeterminado aunque se pida que no: % predeterminados', v_count;
  end if;
  raise notice 'TEST PERFIL 4 OK — el primer método guardado queda como predeterminado';

  -- --- 5. Un solo predeterminado -------------------------------------------
  v_id2 := public.save_payment_method('Mercantil', 'V-12345678', '04241234567', true);

  select count(*) into v_count
  from public.user_payment_methods where user_id = v_ana and is_default;
  if v_count <> 1 then
    raise exception 'Solo puede haber un predeterminado, hay %', v_count;
  end if;
  if not exists (
    select 1 from public.user_payment_methods where id = v_id2 and is_default
  ) then
    raise exception 'El predeterminado debía pasar al método nuevo';
  end if;
  raise notice 'TEST PERFIL 5 OK — guardar uno nuevo como predeterminado mueve la marca, no la duplica';

  -- --- 6. Volver a guardar el mismo actualiza, no duplica -------------------
  perform public.save_payment_method('Banesco', 'V-87654321', '04141234567', false);

  select count(*) into v_count
  from public.user_payment_methods where user_id = v_ana;
  if v_count <> 2 then
    raise exception 'Mismo banco y teléfono debía actualizar la fila, hay %', v_count;
  end if;
  if not exists (
    select 1 from public.user_payment_methods
    where id = v_id1 and payer_document = 'V-87654321'
  ) then
    raise exception 'La cédula debía quedar actualizada en la fila existente';
  end if;
  -- Y sin dejar al usuario sin predeterminado por el camino.
  select count(*) into v_count
  from public.user_payment_methods where user_id = v_ana and is_default;
  if v_count <> 1 then
    raise exception 'Actualizar un método no puede dejar % predeterminados', v_count;
  end if;
  raise notice 'TEST PERFIL 6 OK — repetir banco + teléfono actualiza la fila y respeta el predeterminado';

  -- --- 7. Formato inválido rebota en la base -------------------------------
  v_failed := false;
  begin
    perform public.save_payment_method('Provincial', 'V-123', '04141112222', false);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Una cédula de 3 dígitos no debía entrar';
  end if;

  v_failed := false;
  begin
    perform public.save_payment_method('Provincial', 'V-11223344', '02121112222', false);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Un teléfono fijo (0212) no es Pago Móvil: no debía entrar';
  end if;
  raise notice 'TEST PERFIL 7 OK — la base rechaza cédula y teléfono mal formados';

  -- --- 8. Borrar el predeterminado asciende a otro --------------------------
  perform public.delete_payment_method(v_id2);

  select count(*) into v_count
  from public.user_payment_methods where user_id = v_ana;
  if v_count <> 1 then
    raise exception 'Debía quedar 1 método, quedan %', v_count;
  end if;
  if not exists (
    select 1 from public.user_payment_methods where id = v_id1 and is_default
  ) then
    raise exception 'Al borrar el predeterminado, el que queda debía tomar el relevo';
  end if;
  raise notice 'TEST PERFIL 8 OK — borrar el predeterminado asciende al que queda';

  -- --- 9. Los métodos de otro no se ven ni se tocan -------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.user_payment_methods;
  if v_count <> 0 then
    raise exception 'Luis no debía ver ningún método (son de Ana), ve %', v_count;
  end if;

  v_failed := false;
  begin
    perform public.delete_payment_method(v_id1);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'Luis no debía poder borrar el método de Ana';
  end if;
  raise notice 'TEST PERFIL 9 OK — los métodos de pago son privados de cada usuario';

  -- --- 10. Sincronizar el teléfono tras un cambio ---------------------------
  reset role;
  update auth.users set phone = '584149999999' where id = v_luis;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_luis::text, 'role', 'authenticated')::text, true);
  v_phone := public.sync_phone_e164();

  if v_phone <> '+584149999999' then
    raise exception 'El teléfono debía volver en E.164 con el +: %', v_phone;
  end if;

  reset role;
  select phone_e164 into v_phone from public.profiles where id = v_luis;
  if v_phone <> '+584149999999' then
    raise exception 'El perfil se quedó con el teléfono viejo: %', v_phone;
  end if;
  raise notice 'TEST PERFIL 10 OK — el perfil sigue al teléfono que ya validó auth';

  raise notice '=== TODOS LOS TESTS DE PERFIL PASARON ===';
end $$;

set constraints all immediate;

rollback;
