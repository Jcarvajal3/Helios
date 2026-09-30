-- ============================================================================
-- Ronda — Los umbrales del panel y las metas del negocio son parámetros
--
-- El panel pinta en ámbar o en rojo la mora, el impago y el cobro a tiempo
-- con números escritos en el código (7/15, 4/8, 90/80). Cambiarlos era un
-- despliegue, y dos pantallas ya discrepaban: la cosecha corta en 7/15 y la
-- ficha del local en 8/15. Aquí pasan a `business_parameters`, con vigencia e
-- histórico como los demás, sembrados con los valores de hoy para que nada
-- cambie al conectarlos. Se elige 7/15 porque es el de Riesgo de crédito.
--
-- Y entran claves que todavía no tienen valor: el capital disponible y las
-- metas (`meta_*`). Javier las pondrá. `business_parameters.value` es
-- `not null` y una fila «vale nulo desde el día X» sería un histórico que
-- miente, así que la clave vive en un catálogo y sin fila en la tabla de
-- valores: **sin fila vigente = sin definir**.
--
-- ── El catálogo ─────────────────────────────────────────────────────────────
-- Hasta hoy, una clave existía si tenía alguna fila; `admin_set_business_parameter`
-- rechazaba cualquier otra. `business_parameter_catalog` es la lista de claves
-- permitidas, con su rótulo, su unidad y su grupo. Las claves viejas también
-- entran, con el rótulo que ya usa el panel, para que el catálogo esté
-- completo; una clave con filas y sin catálogo sigue funcionando igual.
--
-- ── Retrocompatible ─────────────────────────────────────────────────────────
-- `admin_business_parameters()` sin argumentos devuelve lo mismo que antes
-- (solo claves con alguna fila), más tres campos nuevos por fila. Las claves
-- sin valor solo salen con `p_incluir_sin_valor => true`: el panel de `main`
-- las pintaría como un 0, y un cero falso es peor que no enseñarlas.
-- ============================================================================

create table if not exists public.business_parameter_catalog (
  key        text primary key,
  label      text not null,
  unit       text not null,
  grupo      text not null
    check (grupo in ('producto', 'umbral', 'meta', 'capital', 'alerta')),
  created_at timestamptz not null default now()
);

comment on table public.business_parameter_catalog is
  'Las claves de parametro permitidas, con rotulo, unidad y grupo. Una clave sin fila vigente en business_parameters esta sin definir.';

alter table public.business_parameter_catalog enable row level security;
revoke all on table public.business_parameter_catalog from public, anon, authenticated;

insert into public.business_parameter_catalog (key, label, unit, grupo) values
  -- Los de siempre, con el rótulo que ya les pone el panel.
  ('consumer_fee_pct',          'Comisión del usuario',            '%',    'producto'),
  ('vat_pct',                   'IVA',                             '%',    'producto'),
  ('late_fee_usd',              'Cargo por atraso',                '€',    'producto'),
  ('late_fee_grace_days',       'Días antes del cargo',            'días', 'producto'),
  ('installment_interval_days', 'Días entre cuotas',               'días', 'producto'),
  ('mora_demotion_days',        'Días para bloquear',              'días', 'producto'),
  ('mora_expulsion_days',       'Días para expulsar',              'días', 'producto'),
  ('on_time_grace_days',        'Días de reintento',               'días', 'producto'),
  ('min_float_days',            'Mínimo hasta la cuota 1',         'días', 'producto'),
  ('charge_ttl_minutes',        'Expiración de un cobro',          'min',  'producto'),
  -- Los umbrales del panel.
  ('umbral_mora_alerta_pct',           'Mora: umbral de alerta',           '%', 'umbral'),
  ('umbral_mora_critica_pct',          'Mora: umbral crítico',             '%', 'umbral'),
  ('umbral_impago_alerta_pct',         'Impago: umbral de alerta',         '%', 'umbral'),
  ('umbral_impago_critico_pct',        'Impago: umbral crítico',           '%', 'umbral'),
  ('umbral_cobro_a_tiempo_bueno_pct',  'Cobro a tiempo: nivel bueno',      '%', 'umbral'),
  ('umbral_cobro_a_tiempo_alerta_pct', 'Cobro a tiempo: umbral de alerta', '%', 'umbral'),
  -- Sin valor hasta que Javier lo ponga.
  ('capital_disponible_usd',       'Capital disponible',                  '€',        'capital'),
  ('meta_financiado_semana_usd',   'Meta de financiado por semana',       '€',        'meta'),
  ('meta_mora_pct',                'Meta de mora',                        '%',        'meta'),
  ('meta_cobro_a_tiempo_pct',      'Meta de cobro a tiempo',              '%',        'meta'),
  ('meta_personas_activas_semana', 'Meta de personas activas por semana', 'personas', 'meta'),
  ('meta_locales_activos',         'Meta de locales activos',             'locales',  'meta')
on conflict (key) do nothing;

-- Los umbrales, con el valor que tienen hoy escrito en el panel. La fecha es
-- la misma que la de los demás parámetros: han regido desde siempre, y con
-- una fecha fija volver a aplicar esto no pisa lo que se cambie después.
insert into public.business_parameters (key, value, effective_from, note) values
  ('umbral_mora_alerta_pct',            7.00, '2026-08-01', 'Mora de una cosecha o de un local que se pinta en ámbar (cartera.tsx). La ficha del local usaba 8.'),
  ('umbral_mora_critica_pct',          15.00, '2026-08-01', 'Mora de una cosecha o de un local que se pinta en rojo (cartera.tsx).'),
  ('umbral_impago_alerta_pct',          4.00, '2026-08-01', 'Impago de una cosecha que se pinta en ámbar (cartera.tsx).'),
  ('umbral_impago_critico_pct',         8.00, '2026-08-01', 'Impago de una cosecha que se pinta en rojo (cartera.tsx).'),
  ('umbral_cobro_a_tiempo_bueno_pct',  90.00, '2026-08-01', 'Cobro a tiempo que se pinta en verde (definitions.ts).'),
  ('umbral_cobro_a_tiempo_alerta_pct', 80.00, '2026-08-01', 'Cobro a tiempo por debajo del cual se pinta en rojo (definitions.ts).')
on conflict (key, effective_from) do nothing;

-- ---------------------------------------------------------------------------
-- Verlos
-- ---------------------------------------------------------------------------

drop function if exists public.admin_business_parameters();

create or replace function public.admin_business_parameters(
  p_incluir_sin_valor boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_rows  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.key), '[]'::jsonb)
  into v_rows
  from (
    select
      k.key,
      -- El vigente hoy. Null = sin definir.
      vig.value,
      vig.effective_from,
      vig.note,
      -- El programado, si lo hay. Es lo que deja ver "sube a €3 el lunes".
      (select p.value from public.business_parameters p
        where p.key = k.key and p.effective_from > v_today
        order by p.effective_from limit 1) as next_value,
      (select p.effective_from from public.business_parameters p
        where p.key = k.key and p.effective_from > v_today
        order by p.effective_from limit 1) as next_from,
      -- El histórico entero, para poder explicar un consumo viejo.
      (select coalesce(jsonb_agg(jsonb_build_object(
          'value', h.value, 'effective_from', h.effective_from,
          'note', h.note, 'created_at', h.created_at
        ) order by h.effective_from desc), '[]'::jsonb)
       from public.business_parameters h where h.key = k.key) as history,
      cat.label,
      cat.unit,
      cat.grupo,
      vig.value is not null as has_value
    from (
      select key from public.business_parameters
      union
      select key from public.business_parameter_catalog where p_incluir_sin_valor
    ) k
    left join public.business_parameter_catalog cat on cat.key = k.key
    left join lateral (
      select p.value, p.effective_from, p.note
      from public.business_parameters p
      where p.key = k.key and p.effective_from <= v_today
      order by p.effective_from desc
      limit 1
    ) vig on true
  ) q;

  return jsonb_build_object('business_date', v_today, 'rows', v_rows);
end;
$$;

comment on function public.admin_business_parameters(boolean) is
  'Los parametros con su valor vigente, el programado y el historico. Con p_incluir_sin_valor salen tambien las claves del catalogo sin fila vigente (value null, has_value false).';

-- ---------------------------------------------------------------------------
-- Cambiarlos
-- ---------------------------------------------------------------------------
-- Mismo cuerpo que en 20260911202000, con dos cambios: una clave existe si
-- tiene filas O si está en el catálogo, y un porcentaje no pasa de 100.

create or replace function public.admin_set_business_parameter(
  p_key            text,
  p_value          numeric,
  p_effective_from date default null,
  p_note           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes numeric;
  v_unit  text;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar un parámetro del negocio'
      using errcode = '42501';
  end if;

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
$$;

comment on function public.admin_set_business_parameter(text, numeric, date, text) is
  'Cambia un parametro desde una fecha. Acepta las claves con filas y las del catalogo, aunque no tengan valor todavia. No reescribe el pasado.';

revoke all on function public.admin_business_parameters(boolean) from public, anon;
revoke all on function public.admin_set_business_parameter(text, numeric, date, text) from public, anon;
grant execute on function public.admin_business_parameters(boolean) to authenticated;
grant execute on function public.admin_set_business_parameter(text, numeric, date, text) to authenticated;
