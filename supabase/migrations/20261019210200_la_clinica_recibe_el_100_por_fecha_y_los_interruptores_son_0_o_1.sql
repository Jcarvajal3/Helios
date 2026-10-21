-- ============================================================================
-- Helios — La clínica recibe el 100% por fecha; los interruptores son 0 o 1
--
-- 1. Las condiciones de una clínica traían de Ronda el adelanto, el % por
--    cuota, la comisión de la clínica y la política «por cobranza». En Helios
--    la clínica recibe el 100% de la consulta, la mitad el día siguiente al
--    vencimiento de cada cuota, pague o no el paciente: 0 / 50 / 0 y «por
--    fecha» en las 17 filas de producción. Una comisión de la clínica distinta
--    de 0 le quitaría parte de su 100%, y «por cobranza» le pagaría solo lo que
--    pague el paciente. El servidor ahora solo acepta ese reparto; lo único que
--    se pacta con una clínica es la comisión de su personal. Las columnas se
--    quedan (las leen el cron y las vistas de Ronda).
-- 2. `admin_set_business_parameter` aceptaba 0,5 en un interruptor (unidad
--    `0/1`) y 2,5 en una unidad que cuenta cosas enteras. Ahora no.
-- 3. `helios_installment_due_dates` estaba declarada IMMUTABLE aunque lee un
--    parámetro de una tabla (`installment_interval_days`): pasa a STABLE, que
--    es lo que es.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las condiciones de la clínica
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_settlement_terms(p_merchant_id uuid, p_upfront_pct numeric, p_per_installment_pct numeric, p_commission_pct numeric, p_policy text, p_effective_from date default null::date, p_note text default null::text, p_staff_commission_usd numeric default null::numeric)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'audit', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes public.merchant_terms;
  v_name  text;
begin
  perform public.helios_assert_super_admin('cambiar las condiciones de una clínica');

  select name into v_name from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'No existe esa clínica' using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  if v_desde < v_today then
    raise exception 'Las condiciones no pueden entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  -- Helios: la clínica recibe el 100%, la mitad el día siguiente al
  -- vencimiento de cada cuota, pague o no el paciente.
  if coalesce(p_upfront_pct, -1) <> 0
     or coalesce(p_per_installment_pct, -1) <> 50
     or coalesce(p_commission_pct, -1) <> 0
     or coalesce(p_policy, '') <> 'scheduled' then
    raise exception 'En Helios la clínica recibe el 100%% de la consulta, la mitad a los 8 y la mitad a los 15 días, pague o no el paciente: sin adelanto, sin comisión de la clínica y por fecha. Lo único que se pacta es la comisión de su personal.'
      using errcode = '22023';
  end if;

  -- La comisión del personal pactada con esta clínica. Null = la global.
  if p_staff_commission_usd is not null
     and (p_staff_commission_usd < 0 or p_staff_commission_usd <> round(p_staff_commission_usd, 2)
          or p_staff_commission_usd > 100) then
    raise exception 'La comisión del personal va entre $0 y $100, con 2 decimales como mucho'
      using errcode = '22023';
  end if;

  select * into v_antes from public.helios_terms_at(p_merchant_id, v_today);

  insert into public.merchant_terms
    (merchant_id, upfront_pct, per_installment_pct, commission_pct, policy,
     effective_from, note, created_by, staff_commission_usd)
  values (
    p_merchant_id, p_upfront_pct, p_per_installment_pct, p_commission_pct,
    p_policy::public.settlement_policy, v_desde,
    nullif(trim(coalesce(p_note, '')), ''), v_actor, p_staff_commission_usd
  )
  on conflict (merchant_id, effective_from) do update
    set upfront_pct = excluded.upfront_pct,
        per_installment_pct = excluded.per_installment_pct,
        commission_pct = excluded.commission_pct,
        policy = excluded.policy,
        note = excluded.note,
        created_by = excluded.created_by,
        staff_commission_usd = excluded.staff_commission_usd,
        created_at = now();

  perform audit.log(v_actor, 'merchant.set_terms', p_merchant_id, jsonb_build_object(
    'merchant_name', v_name,
    'effective_from', v_desde,
    'from_upfront_pct', v_antes.upfront_pct,
    'to_upfront_pct', p_upfront_pct,
    'from_per_installment_pct', v_antes.per_installment_pct,
    'to_per_installment_pct', p_per_installment_pct,
    'from_commission_pct', v_antes.commission_pct,
    'to_commission_pct', p_commission_pct,
    'from_policy', v_antes.policy,
    'to_policy', p_policy,
    'from_staff_commission_usd', v_antes.staff_commission_usd,
    'to_staff_commission_usd', p_staff_commission_usd,
    'note', p_note
  ));

  return jsonb_build_object('ok', true, 'effective_from', v_desde,
                            'staff_commission_usd', p_staff_commission_usd);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Los parámetros
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_business_parameter(p_key text, p_value numeric, p_effective_from date default null::date, p_note text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'audit', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes numeric;
  v_unit  text;
begin
  perform public.helios_assert_super_admin('cambiar un parámetro del negocio');

  select c.unit into v_unit
  from public.business_parameter_catalog c where c.key = p_key;

  if v_unit is null
     and not exists (select 1 from public.business_parameters where key = p_key) then
    raise exception 'No existe el parámetro %', p_key using errcode = '22023';
  end if;

  if p_value is null then
    raise exception 'El parámetro necesita un valor' using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  -- Hacia atrás no. Cambiar la vigencia de un parámetro en el pasado no
  -- reescribe lo que ya pasó —el motor aplicó lo que aplicó— pero sí haría
  -- que el histórico mintiera sobre ello.
  if v_desde < v_today then
    raise exception 'Un parámetro no puede entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  if p_value < 0 then
    raise exception 'Un parámetro no puede ser negativo' using errcode = '22023';
  end if;

  if v_unit = '%' and p_value > 100 then
    raise exception 'Un porcentaje no puede pasar de 100' using errcode = '22023';
  end if;

  -- Un interruptor solo se enciende (1) o se apaga (0).
  if v_unit = '0/1' and p_value not in (0, 1) then
    raise exception 'Este parámetro es un interruptor: 1 lo enciende y 0 lo apaga'
      using errcode = '22023';
  end if;

  -- Lo que se cuenta, se cuenta entero: el estado automático cuenta días
  -- enteros y no hay medio reenvío.
  if v_unit in ('días', 'minutos', 'min', 'intentos', 'preguntas', 'reenvíos', 'consultas',
                'casos', 'pacientes', 'financiamientos', 'personas', 'locales', 'clínicas')
     and p_value <> trunc(p_value) then
    raise exception 'Este parámetro se cuenta en % enteros', v_unit using errcode = '22023';
  end if;

  select public.helios_parameter(p_key, null) into v_antes;

  insert into public.business_parameters (key, value, effective_from, note, created_by)
  values (p_key, p_value, v_desde, nullif(trim(coalesce(p_note, '')), ''), v_actor)
  on conflict (key, effective_from) do update
    set value = excluded.value, note = excluded.note,
        created_by = excluded.created_by, created_at = now();

  perform audit.log(v_actor, 'parameter.set', null, jsonb_build_object(
    'key', p_key,
    'from_value', v_antes,
    'to_value', p_value,
    'effective_from', v_desde,
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true, 'key', p_key, 'value', p_value, 'effective_from', v_desde
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Las fechas de las cuotas leen un parámetro: STABLE, no IMMUTABLE
-- ---------------------------------------------------------------------------

alter function public.helios_installment_due_dates(date) stable;
