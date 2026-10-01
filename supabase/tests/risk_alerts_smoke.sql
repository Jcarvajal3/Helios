-- ============================================================================
-- Helios — Las alertas de las clínicas (H10, 20261004000400, docs/01 §2.6)
--
--   bash supabase/tests/run.sh risk_alerts_smoke
--
-- Cada alerta nueva se dispara al pasar su umbral y NO antes. Los umbrales se
-- bajan dentro de la prueba (parámetros con vigencia de hoy) para no tener
-- que fabricar cientos de filas. Cada clínica, paciente o persona del
-- personal es propio de una sola alerta, y se cuenta filtrando por sujeto
-- (`p_subject_id`), así que los datos que ya hubiera en la base no estorban.
-- ============================================================================

begin;

-- @ayudas

create function pg_temp.n_alertas(p_kind text, p_subject uuid)
returns integer
language sql
as $$
  select count(*)::integer
  from jsonb_array_elements(public.admin_risk_alerts(1000, array[p_kind], p_subject) -> 'rows') r
  where r->>'kind' = p_kind and r->>'subject_id' = p_subject::text
$$;

create function pg_temp.n_alertas_por(p_kind text, p_key text, p_val text)
returns integer
language sql
as $$
  select count(*)::integer
  from jsonb_array_elements(public.admin_risk_alerts(1000, array[p_kind], null) -> 'rows') r
  where r->>'kind' = p_kind and r->'detail'->>p_key = p_val
$$;

/** Una clínica con su sede por defecto y, si viene, su personal activo. */
create function pg_temp.clinica(p_name text, p_staff uuid[] default '{}')
returns uuid
language plpgsql
as $$
declare
  v_m uuid;
  v_b uuid;
begin
  insert into public.merchants (name) values (p_name) returning id into v_m;
  select id into v_b from public.merchant_branches where merchant_id = v_m and is_default;
  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  select s, v_m, v_b, 'cajero' from unnest(p_staff) s;
  return v_m;
end;
$$;

/** Un financiamiento de `p_base` para un paciente nuevo (o el dado). Devuelve el charge_id. */
create function pg_temp.financiar(p_merchant uuid, p_staff uuid, p_base numeric, p_pac uuid default null)
returns uuid
language plpgsql
as $$
declare
  v_pac uuid := coalesce(p_pac, gen_random_uuid());
  v_b   uuid;
begin
  if p_pac is null then
    insert into public.profiles (id, phone_e164, full_name)
    values (v_pac, '+58414' || lpad((floor(random() * 9999999))::text, 7, '0'), 'Paciente ' || left(v_pac::text, 6));
  end if;
  select id into v_b from public.merchant_branches where merchant_id = p_merchant and is_default;
  return (pg_temp.prueba_cobro(v_pac, p_merchant, v_b, p_staff, p_base, 'alerta-' || gen_random_uuid())->>'charge_id')::uuid;
end;
$$;

do $$
declare
  v_admin   uuid := gen_random_uuid();
  v_s1      uuid := gen_random_uuid();
  v_s2      uuid := gen_random_uuid();
  v_s3      uuid := gen_random_uuid();
  v_s4      uuid := gen_random_uuid();
  v_s5      uuid := gen_random_uuid();
  v_today   date := public.helios_business_date(now());
  v_m       uuid;
  v_m2      uuid;
  v_c       uuid;
  v_c2      uuid;
  v_p1      uuid := gen_random_uuid();
  v_p2      uuid := gen_random_uuid();
  v_inst    uuid;
  v_res     jsonb;
  v_key     text;
  i         integer;
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'u-' || u || '@prueba.helios.test', now(), now(), now()
  from unnest(array[v_admin, v_s1, v_s2, v_s3, v_s4, v_s5]) u;
  insert into public.platform_admins (user_id, role, full_name, is_active)
  values (v_admin, 'operador', 'Operadora Riesgo', true);

  update public.levels set monthly_limit_usd = 350 where level = 1;

  insert into public.business_parameters (key, value, effective_from, note)
  values ('alert_charges_per_merchant_day', 2, v_today, 'prueba'),
         ('alert_new_patients_per_merchant_day', 2, v_today, 'prueba'),
         ('alert_staff_share_pct', 80, v_today, 'prueba'),
         ('alert_staff_share_min_charges', 3, v_today, 'prueba'),
         ('alert_fpd_merchant_pct', 50, v_today, 'prueba'),
         ('alert_fpd_min_cases', 2, v_today, 'prueba'),
         ('alert_merchant_exposure_usd', 200, v_today, 'prueba'),
         ('alert_first_charge_limit_pct', 90, v_today, 'prueba'),
         ('eligibility_lookups_per_staff_day', 3, v_today, 'prueba')
  on conflict (key, effective_from) do update set value = excluded.value;

  -- Sin sesión del equipo, nada.
  begin
    perform public.admin_risk_alerts();
    raise exception 'Sin sesión del equipo debía fallar';
  exception when sqlstate '42501' then null;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  -- --- rafaga_de_altas (umbral 2 al día) ------------------------------------
  v_m := pg_temp.clinica('Clínica Ráfaga', array[v_s1]);
  perform pg_temp.financiar(v_m, v_s1, 10);
  perform pg_temp.financiar(v_m, v_s1, 10);
  if pg_temp.n_alertas('rafaga_de_altas', v_m) <> 0 then
    raise exception 'rafaga_de_altas: 2 financiamientos no pasan de 2';
  end if;
  perform pg_temp.financiar(v_m, v_s1, 10);
  if pg_temp.n_alertas('rafaga_de_altas', v_m) <> 1 then
    raise exception 'rafaga_de_altas: 3 financiamientos pasan de 2';
  end if;
  v_res := public.admin_risk_alerts(10, array['rafaga_de_altas'], v_m) -> 'rows' -> 0;
  if v_res->>'subject_type' <> 'clinica' or v_res->>'subject_name' <> 'Clínica Ráfaga'
     or (v_res->'detail'->>'charge_count')::integer <> 3 or v_res->'detail'->>'merchant_id' <> v_m::text or v_res->>'first_seen_at' is null
     or v_res->>'severity' not in ('alta', 'media') or (v_res->>'reviewed')::boolean then
    raise exception 'rafaga_de_altas: la fila no tiene la forma del contrato: %', v_res;
  end if;
  raise notice 'TEST ALERTA rafaga_de_altas OK';

  -- --- rafaga_de_pacientes_nuevos (umbral 2 al día) -------------------------
  v_m := pg_temp.clinica('Clínica Altas Nuevas');
  insert into public.profiles (phone_e164, full_name, registered_merchant_id)
  values ('+584140009501', 'Nuevo Uno', v_m), ('+584140009502', 'Nuevo Dos', v_m);
  if pg_temp.n_alertas('rafaga_de_pacientes_nuevos', v_m) <> 0 then
    raise exception 'rafaga_de_pacientes_nuevos: 2 no pasan de 2';
  end if;
  insert into public.profiles (phone_e164, full_name, registered_merchant_id)
  values ('+584140009503', 'Nuevo Tres', v_m);
  if pg_temp.n_alertas('rafaga_de_pacientes_nuevos', v_m) <> 1 then
    raise exception 'rafaga_de_pacientes_nuevos: 3 pasan de 2';
  end if;
  raise notice 'TEST ALERTA rafaga_de_pacientes_nuevos OK';

  -- --- secretaria_concentrada (> 80 % de la semana, mínimo 3, 2+ personas) ---
  v_m := pg_temp.clinica('Clínica Concentrada', array[v_s2, v_s3]);
  for i in 1..3 loop perform pg_temp.financiar(v_m, v_s2, 10); end loop;
  perform pg_temp.financiar(v_m, v_s3, 10);
  if pg_temp.n_alertas('secretaria_concentrada', v_s2) <> 0 then
    raise exception 'secretaria_concentrada: 3 de 4 (75 %%) no pasa del 80 %%';
  end if;
  perform pg_temp.financiar(v_m, v_s2, 10);
  if pg_temp.n_alertas('secretaria_concentrada', v_s2) <> 0 then
    raise exception 'secretaria_concentrada: 4 de 5 (80 %%) no pasa del 80 %%';
  end if;
  perform pg_temp.financiar(v_m, v_s2, 10);
  if pg_temp.n_alertas('secretaria_concentrada', v_s2) <> 1 then
    raise exception 'secretaria_concentrada: 5 de 6 (83 %%) pasa del 80 %%';
  end if;
  v_res := public.admin_risk_alerts(10, array['secretaria_concentrada'], v_s2) -> 'rows' -> 0;
  if v_res->>'subject_type' <> 'personal' or v_res->>'subject_name' not like '%Clínica Concentrada%'
     or v_res->'detail'->>'merchant_id' <> v_m::text or (v_res->'detail'->>'share_pct')::numeric <= 80 then
    raise exception 'secretaria_concentrada: el sujeto es la persona, con su clínica: %', v_res;
  end if;
  -- Una clínica con una sola persona no cuenta.
  v_m2 := pg_temp.clinica('Clínica Unipersonal', array[v_s5]);
  for i in 1..4 loop perform pg_temp.financiar(v_m2, v_s5, 10); end loop;
  if pg_temp.n_alertas('secretaria_concentrada', v_s5) <> 0 then
    raise exception 'secretaria_concentrada: con una sola persona en la clínica no hay alerta';
  end if;
  raise notice 'TEST ALERTA secretaria_concentrada OK';

  -- --- impago_primera_cuota_clinica (> 50 %, mínimo 2 casos) ----------------
  v_m := pg_temp.clinica('Clínica Impago', array[v_s1]);
  v_c := pg_temp.financiar(v_m, v_s1, 10);
  update public.installments set due_date = v_today - 2 where charge_id = v_c and sequence = 1;
  if pg_temp.n_alertas('impago_primera_cuota_clinica', v_m) <> 0 then
    raise exception 'impago_primera_cuota_clinica: 1 caso no llega al mínimo de 2';
  end if;
  v_c2 := pg_temp.financiar(v_m, v_s1, 10);
  update public.installments set due_date = v_today - 2, status = 'paid', paid_at = now()
   where charge_id = v_c2 and sequence = 1;
  if pg_temp.n_alertas('impago_primera_cuota_clinica', v_m) <> 0 then
    raise exception 'impago_primera_cuota_clinica: 1 de 2 (50 %%) no pasa del 50 %%';
  end if;
  v_c := pg_temp.financiar(v_m, v_s1, 10);
  update public.installments set due_date = v_today - 2 where charge_id = v_c and sequence = 1;
  if pg_temp.n_alertas('impago_primera_cuota_clinica', v_m) <> 1 then
    raise exception 'impago_primera_cuota_clinica: 2 de 3 (67 %%) pasa del 50 %%';
  end if;
  raise notice 'TEST ALERTA impago_primera_cuota_clinica OK';

  -- --- exposicion_clinica (> $200 de deuda viva) -----------------------------
  v_m := pg_temp.clinica('Clínica Expuesta', array[v_s1]);
  perform pg_temp.financiar(v_m, v_s1, 100);     -- 123.20
  if pg_temp.n_alertas('exposicion_clinica', v_m) <> 0 then
    raise exception 'exposicion_clinica: $123.20 no pasa de $200';
  end if;
  perform pg_temp.financiar(v_m, v_s1, 100);     -- 246.40
  if pg_temp.n_alertas('exposicion_clinica', v_m) <> 1 then
    raise exception 'exposicion_clinica: $246.40 pasa de $200';
  end if;
  v_key := public.admin_risk_alerts(10, array['exposicion_clinica'], v_m) -> 'rows' -> 0 ->> 'alert_key';
  raise notice 'TEST ALERTA exposicion_clinica OK';

  -- --- Revisar una alerta ----------------------------------------------------
  v_res := public.admin_review_risk_alert(v_key, 'La clínica es grande, está bien');
  v_res := public.admin_risk_alerts(10, array['exposicion_clinica'], v_m);
  if (v_res->'rows'->0->>'reviewed')::boolean is not true
     or (v_res->'counts'->'exposicion_clinica'->>'unreviewed')::integer <> 0
     or v_res->'rows'->0->>'review_note' <> 'La clínica es grande, está bien' then
    raise exception 'Revisar la alerta no la marcó: %', v_res;
  end if;
  begin
    perform public.admin_review_risk_alert('inventada:123', null);
    raise exception 'Una clave inventada debía rechazarse';
  exception when sqlstate '22023' then null;
  end;
  raise notice 'TEST ALERTA revisar OK';

  -- --- referencia_repetida (misma referencia en pacientes distintos) --------
  v_m := pg_temp.clinica('Clínica Referencias', array[v_s1]);
  insert into public.profiles (id, phone_e164, full_name) values
    (v_p1, '+584140009601', 'Ref Uno'), (v_p2, '+584140009602', 'Ref Dos');
  perform pg_temp.financiar(v_m, v_s1, 10, v_p1);
  perform pg_temp.financiar(v_m, v_s1, 10, v_p2);
  select id into v_inst from public.installments where user_id = v_p1 and sequence = 1;
  perform public.admin_register_payment(v_p1, array[v_inst], 'pago_movil', 'Banesco', '99887766',
                                        v_today, 1000, null, null);
  -- (Todo pasa en la misma transacción: que el primero sea el de antes.)
  update public.payment_reports set created_at = now() - interval '1 minute' where user_id = v_p1;
  -- El mismo paciente con su propia referencia no es alerta.
  if pg_temp.n_alertas_por('referencia_repetida', 'reference', '99887766') <> 0 then
    raise exception 'referencia_repetida: una sola persona no es alerta';
  end if;
  select id into v_inst from public.installments where user_id = v_p2 and sequence = 1;
  perform public.admin_register_payment(v_p2, array[v_inst], 'pago_movil', 'Banesco', '9988-7766',
                                        v_today, 1000, null, null);
  if pg_temp.n_alertas('referencia_repetida', v_p2) <> 1
     or pg_temp.n_alertas_por('referencia_repetida', 'reference', '99887766') <> 1 then
    raise exception 'referencia_repetida: la misma referencia en dos pacientes debía alertar';
  end if;
  if (public.admin_risk_alerts(10, array['referencia_repetida'], v_p2) -> 'rows' -> 0 ->> 'severity') <> 'alta' then
    raise exception 'referencia_repetida: mismo banco es gravedad alta';
  end if;
  raise notice 'TEST ALERTA referencia_repetida OK';

  -- --- cupo_al_limite_al_estrenar (> 90 % del cupo de $350) ----------------
  v_m := pg_temp.clinica('Clínica Estreno', array[v_s1]);
  v_c := pg_temp.financiar(v_m, v_s1, 315);       -- 90 % justo
  if pg_temp.n_alertas('cupo_al_limite_al_estrenar', (select user_id from public.charges where id = v_c)) <> 0 then
    raise exception 'cupo_al_limite_al_estrenar: el 90 %% no pasa del 90 %%';
  end if;
  v_c := pg_temp.financiar(v_m, v_s1, 316);       -- 90.3 %
  if pg_temp.n_alertas('cupo_al_limite_al_estrenar', (select user_id from public.charges where id = v_c)) <> 1 then
    raise exception 'cupo_al_limite_al_estrenar: el 90.3 %% pasa del 90 %%';
  end if;
  raise notice 'TEST ALERTA cupo_al_limite_al_estrenar OK';

  -- --- consultas_de_cedula_excesivas (límite 3 al día) ----------------------
  insert into public.eligibility_lookups (staff_user_id, merchant_id, document_key, result)
  select v_s4, v_m, 'V' || (10000000 + g), 'nuevo' from generate_series(1, 3) g;
  if pg_temp.n_alertas('consultas_de_cedula_excesivas', v_s4) <> 0 then
    raise exception 'consultas_de_cedula_excesivas: 3 consultas no pasan de 3';
  end if;
  insert into public.eligibility_lookups (staff_user_id, merchant_id, document_key, result)
  values (v_s4, v_m, 'V10000004', 'limite');
  if pg_temp.n_alertas('consultas_de_cedula_excesivas', v_s4) <> 1 then
    raise exception 'consultas_de_cedula_excesivas: 4 consultas pasan de 3';
  end if;
  -- Una consulta rechazada por el límite basta.
  insert into public.eligibility_lookups (staff_user_id, merchant_id, document_key, result)
  values (v_s5, v_m, 'V10000005', 'limite');
  if pg_temp.n_alertas('consultas_de_cedula_excesivas', v_s5) <> 1 then
    raise exception 'consultas_de_cedula_excesivas: una consulta en «limite» alerta';
  end if;
  raise notice 'TEST ALERTA consultas_de_cedula_excesivas OK';

  -- --- telefono_repetido y correo_repetido -----------------------------------
  insert into public.profiles (phone_e164, full_name, email)
  values ('+584140009701', 'Tel Uno', 'repetido.correo@prueba.helios.test');
  if pg_temp.n_alertas_por('telefono_repetido', 'phone_e164', '+584140009701') <> 0
     or pg_temp.n_alertas_por('correo_repetido', 'email', 'repetido.correo@prueba.helios.test') <> 0 then
    raise exception 'Un solo paciente con ese teléfono/correo no es alerta';
  end if;
  insert into public.profiles (phone_e164, full_name, email)
  values ('+584140009701', 'Tel Dos', 'repetido.correo@prueba.helios.test');
  if pg_temp.n_alertas_por('telefono_repetido', 'phone_e164', '+584140009701') <> 1 then
    raise exception 'telefono_repetido: dos pacientes con el mismo teléfono';
  end if;
  if pg_temp.n_alertas_por('correo_repetido', 'email', 'repetido.correo@prueba.helios.test') <> 1 then
    raise exception 'correo_repetido: el mismo correo en dos pacientes';
  end if;
  raise notice 'TEST ALERTA telefono_repetido y correo_repetido OK';

  -- --- correo_rebotado -----------------------------------------------------------
  update public.profiles set email = 'rebota@prueba.helios.test' where id = v_p1;
  if pg_temp.n_alertas('correo_rebotado', v_p1) <> 0 then
    raise exception 'correo_rebotado: sin rebote no hay alerta';
  end if;
  update public.profiles set email_invalid_at = now() where id = v_p1;
  if pg_temp.n_alertas('correo_rebotado', v_p1) <> 1 then
    raise exception 'correo_rebotado: con email_invalid_at hay alerta';
  end if;
  raise notice 'TEST ALERTA correo_rebotado OK';

  -- --- Los contadores ----------------------------------------------------------
  v_res := public.admin_risk_alerts(1, null) -> 'counts';
  if (select count(*) from jsonb_object_keys(v_res) k
      where k in ('telefono_repetido', 'correo_repetido', 'correo_rebotado', 'rafaga_de_altas',
                  'rafaga_de_pacientes_nuevos', 'secretaria_concentrada', 'impago_primera_cuota_clinica',
                  'exposicion_clinica', 'referencia_repetida', 'cupo_al_limite_al_estrenar',
                  'consultas_de_cedula_excesivas', 'consumo_sobre_cupo')) <> 12 then
    raise exception 'Los contadores deben traer los 12 tipos: %', v_res;
  end if;
  v_res := public.admin_risk_alert_counts();
  if (v_res->>'pendientes_alta')::integer < 1 or (v_res->>'pendientes_media')::integer < 1
     or (v_res->>'revisadas')::integer < 1 then
    raise exception 'Las cifras de Inicio no cuentan las alertas: %', v_res;
  end if;
  raise notice 'TEST ALERTA contadores OK';
end;
$$;

set constraints all immediate;
rollback;
