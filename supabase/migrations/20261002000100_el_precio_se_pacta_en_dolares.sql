-- ============================================================================
-- Helios — El precio se pacta en DÓLARES (H1, docs/00 §4.4)
--
-- Ronda pasó del dólar al euro el 2026-09-09
-- (`20260909100000_el_precio_se_pacta_en_euros`). Helios nace anclado al
-- **dólar BCV** (decisión del 2026-09-30, docs/00 §1): precios, límites, deuda
-- y cargos en USD, cobrados en bolívares a la tasa BCV del dólar del día de
-- pago. Esta migración deshace aquella, pieza por pieza, y deja además los
-- números propios de Helios (niveles y parámetros).
--
-- 1. **La serie del euro se archiva y la del dólar vuelve a ser `BCV`.** Es el
--    movimiento inverso del de Ronda: lo que hay bajo `BCV` (euro) pasa a
--    `BCV_EUR` y lo que hay bajo `BCV_USD` (dólar) pasa a `BCV`. Durante la
--    reproducción de la historia de Ronda el cron trajo las dos tasas reales
--    del 2026-09-30 (euro 973,309675 y dólar 859,0629, poda/NOTAS.md): el dólar
--    queda como la tasa vigente y el euro como rastro. El guardarraíl de
--    `sync_fx_rate` (salto > 25 % contra la anterior bajo `BCV`) vuelve así a
--    comparar dólar con dólar.
--
-- 2. **Los espejos vuelven al dólar**: se reactivan `dolarapi`
--    (`/v1/dolares/oficial`) y `er-api` (`/latest/USD`) y se apagan las dos
--    del euro. `fx_rate_rejection` se revisó y no cambia: sus topes (0,01 a
--    100.000.000 Bs y 25 % de salto diario) no dependen de la moneda, y el
--    único que sí dependía —la tasa anterior contra la que se mide el salto—
--    queda arreglado con el punto 1.
--
-- 3. **Las funciones que imprimen dinero en un texto**: las 15 que llevan `€`
--    o «euro» en el cuerpo (mensajes de error, avisos, tramos de métricas y
--    comentarios). Van copiadas tal cual están hoy en la base
--    (`pg_get_functiondef`), con el símbolo y la palabra cambiados y NADA más.
--    Entre ellas `admin_unmatched_deposits` y `admin_discarded_deposits`
--    (Ronda 20260927697200): pasan el abono a la moneda del sistema con la tasa
--    `BCV` de su día; con el punto 1 esa tasa vuelve a ser la del dólar.
--
-- 4. **Las plantillas de avisos y las unidades del catálogo de parámetros**
--    (`€` → `$`). Las tres capas —fábrica, publicado y borrador—, como hizo
--    Ronda al revés.
--
-- 5. **Niveles de Helios**: solo el nivel 1 ($350) está activo; 2-4 son de
--    ejemplo y quedan apagados; el 5 es «Próximamente».
--
-- 6. **Parámetros nuevos** (docs/01 §3), por el camino de siempre: una fila
--    con vigencia en `business_parameters` y su entrada en el catálogo. Cada
--    uno con su lector `helios_*()`, como `helios_late_fee_usd()`.
--    `helios_parameter` protege también las claves `alert_*` (los umbrales de
--    las alertas de H10 no son para la clínica), igual que ya protegía
--    `umbral_*`, `meta_*`, `capital_*` y `alerta_*`.
--
-- 7. **El monto mínimo deja de ser un CHECK rígido.** `charges.amount_usd >=
--    5.00` era el mínimo de Ronda (€5) escrito en la tabla. El mínimo de Helios
--    es un parámetro con vigencia (`min_charge_usd` = 10, D-H7): si mañana baja
--    a 5, un check de 10 no dejaría cobrar; si sube a 15, las filas viejas de
--    10 no lo cumplirían. La tabla se queda con un suelo que nunca bloquea la
--    historia (`amount_usd > 0`) y la regla vive en
--    `helios_assert_charge_amount(base)`, que usará `create_patient_charge`
--    (H4).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La serie del euro se archiva y la del dólar vuelve a ser `BCV`
-- ---------------------------------------------------------------------------
-- Dos UPDATE en este orden: el primero deja libre `BCV`, el segundo lo ocupa.
-- El `unique (source, effective_date)` no choca porque cada serie se mueve
-- entera a una clave vacía.

update public.exchange_rates set source = 'BCV_EUR' where source = 'BCV';
update public.exchange_rates set source = 'BCV'     where source = 'BCV_USD';

comment on table public.exchange_rates is
  'Tasas del BCV. `BCV` es la del DÓLAR, la moneda de Helios. `BCV_EUR` es la serie del euro que heredó de Ronda, archivada. La ingesta es un job diario (sync_fx_rate).';

-- ---------------------------------------------------------------------------
-- 2. Los espejos vuelven al dólar
-- ---------------------------------------------------------------------------

update public.fx_rate_sources
set is_active = true,
    priority  = 1,
    note      = 'DolarAPI Venezuela. Republica la tasa oficial del BCV para el dólar, con su fecha de vigencia.'
where key = 'dolarapi';

update public.fx_rate_sources
set is_active = true,
    priority  = 2,
    note      = 'exchangerate-api con base USD. Segunda opinión: su VES sigue a la oficial. Actualiza una vez al día.'
where key = 'er-api';

update public.fx_rate_sources
set is_active = false,
    note = coalesce(note, '') || ' — Retirada el 2026-09-30: Helios cobra en dólares.'
where key in ('dolarapi-eur', 'er-api-eur');

comment on table public.fx_rate_sources is
  'Espejos JSON de la tasa oficial del BCV para el DÓLAR, por prioridad. Los lee sync_fx_rate().';

comment on function public.sync_fx_rate(date, boolean) is
  'Busca la tasa BCV del dólar en los espejos configurados, la valida y la persiste. La llama el cron a las 10 AM.';

-- Los comentarios de función que hablan de euros (merchant_sales_export,
-- admin_metricas_general): el mismo texto con la moneda cambiada.
do $$
declare
  r record;
begin
  for r in
    select d.objoid::regprocedure as fn, d.description as txt
    from pg_description d
    where d.classoid = 'pg_proc'::regclass
      and (d.description like '%€%' or d.description ~* '\meuros?\M')
  loop
    execute format('comment on function %s is %L', r.fn,
      regexp_replace(regexp_replace(regexp_replace(r.txt,
        '(\d+) €', '$\1', 'g'), '€', '$', 'g'), '\meuros\M', 'dólares', 'g'));
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. Las plantillas de avisos y las unidades del catálogo
-- ---------------------------------------------------------------------------
-- Los avisos ya mandados (`notifications`) no se tocan: son el acta de lo que
-- se dijo ese día. (Helios no tiene ninguno todavía.)

update public.notification_templates
set default_title = replace(default_title, '€', '$'),
    default_body  = replace(default_body,  '€', '$'),
    title         = replace(title,         '€', '$'),
    body          = replace(body,          '€', '$'),
    draft_title   = replace(draft_title,   '€', '$'),
    draft_body    = replace(draft_body,    '€', '$')
where concat(default_title, default_body, title, body, draft_title, draft_body) like '%€%';

update public.business_parameter_catalog set unit = '$' where unit = '€';

-- ---------------------------------------------------------------------------
-- 4. Niveles de Helios
-- ---------------------------------------------------------------------------
-- El nivel 1 no pide nada: es el que recibe todo paciente nuevo al registrarse
-- (H3/H4). Los 2-4 son de ejemplo (docs/00 §4.4): conservan los requisitos de
-- gasto y antigüedad de Ronda y se deciden cuando se abran.

update public.levels set monthly_limit_usd = 0,    is_active = false, label = 'Sin nivel',    updated_at = now() where level = 0;
update public.levels set monthly_limit_usd = 350,  is_active = true,  required_spend_usd = 0, required_months = 0, updated_at = now() where level = 1;
update public.levels set monthly_limit_usd = 500,  is_active = false, updated_at = now() where level = 2;
update public.levels set monthly_limit_usd = 700,  is_active = false, updated_at = now() where level = 3;
update public.levels set monthly_limit_usd = 1000, is_active = false, updated_at = now() where level = 4;
update public.levels set monthly_limit_usd = 0,    is_active = false, label = 'Próximamente', updated_at = now() where level = 5;

-- ---------------------------------------------------------------------------
-- 5. Parámetros nuevos
-- ---------------------------------------------------------------------------
-- Vigentes desde hoy (2026-09-30, el día de la decisión). `late_fee_usd`
-- conserva el valor (2) pero se anota otra fila: la de 2026-08-01 era de
-- Ronda y en euros; esta dice que el cargo de Helios son $2.

insert into public.business_parameters (key, value, effective_from, note) values
  ('late_fee_usd',                        2.00, date '2026-09-30', 'Helios: $2 por cuota tras los días de gracia (docs/00 §1.1)'),
  ('min_charge_usd',                     10.00, date '2026-09-30', 'Monto mínimo por financiamiento, sin el fee (D-H7)'),
  ('staff_commission_usd',                0.50, date '2026-09-30', 'Comisión de la secretaria por financiamiento confirmado (docs/00 §6)'),
  ('eligibility_lookups_per_staff_day',  60,    date '2026-09-30', 'Consultas de cédula por persona del personal y día (anti-enumeración)'),
  ('payment_four_eyes',                   0,    date '2026-09-30', '1 = quien registra un pago no puede aprobarlo (salvo super admin)'),
  ('receipt_resends_per_day',             3,    date '2026-09-30', 'Reenvíos del comprobante por financiamiento y día'),
  ('alert_charges_per_merchant_day',     10,    date '2026-09-30', 'Alerta rafaga_de_altas'),
  ('alert_new_patients_per_merchant_day', 8,    date '2026-09-30', 'Alerta rafaga_de_pacientes_nuevos'),
  ('alert_staff_share_pct',              80,    date '2026-09-30', 'Alerta secretaria_concentrada'),
  ('alert_fpd_merchant_pct',             25,    date '2026-09-30', 'Alerta impago_primera_cuota_clinica: porcentaje'),
  ('alert_fpd_min_cases',                 5,    date '2026-09-30', 'Alerta impago_primera_cuota_clinica: casos mínimos'),
  ('alert_merchant_exposure_usd',      3000,    date '2026-09-30', 'Alerta exposicion_clinica'),
  ('alert_first_charge_limit_pct',       90,    date '2026-09-30', 'Alerta cupo_al_limite_al_estrenar')
on conflict (key, effective_from) do update
  set value = excluded.value, note = excluded.note;

insert into public.business_parameter_catalog (key, label, unit, grupo) values
  ('min_charge_usd',                      'Monto mínimo por financiamiento',                 '$',              'producto'),
  ('staff_commission_usd',                'Comisión de la secretaria',                       '$',              'producto'),
  ('eligibility_lookups_per_staff_day',   'Consultas de cédula por persona y día',           'consultas',      'producto'),
  ('payment_four_eyes',                   'Doble control de pagos (1 = sí, 0 = no)',         '0/1',            'producto'),
  ('receipt_resends_per_day',             'Reenvíos del comprobante por día',                'reenvíos',       'producto'),
  ('alert_charges_per_merchant_day',      'Alerta: financiamientos de una clínica en un día', 'financiamientos', 'alerta'),
  ('alert_new_patients_per_merchant_day', 'Alerta: pacientes nuevos de una clínica en un día', 'pacientes',     'alerta'),
  ('alert_staff_share_pct',               'Alerta: altas de la semana en una sola persona',  '%',              'alerta'),
  ('alert_fpd_merchant_pct',              'Alerta: impago de la 1ª cuota por clínica',       '%',              'alerta'),
  ('alert_fpd_min_cases',                 'Alerta: casos mínimos para medir el impago',      'casos',          'alerta'),
  ('alert_merchant_exposure_usd',         'Alerta: deuda viva originada por una clínica',    '$',              'alerta'),
  ('alert_first_charge_limit_pct',        'Alerta: cupo usado en el primer financiamiento',  '%',              'alerta')
on conflict (key) do update
  set label = excluded.label, unit = excluded.unit, grupo = excluded.grupo;

-- `helios_parameter` tal cual, con `alert_` en la lista de claves que solo
-- leen el equipo y las propias funciones.
create or replace function public.helios_parameter(p_key text, p_fallback numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ctx text;
begin
  if p_key ~ '^(capital|meta|umbral|alerta?)_' then
    get diagnostics v_ctx = pg_context;
    if not (
      -- La llamó otra función: la pila tiene más de una línea.
      position(E'\n' in v_ctx) > 0
      -- El propio sistema, fuera de la API.
      or coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon')
      or public.is_platform_admin()
    ) then
      return p_fallback;
    end if;
  end if;

  return coalesce((
    select p.value
    from public.business_parameters p
    where p.key = p_key
      and p.effective_from <= public.helios_business_date(now())
    order by p.effective_from desc
    limit 1
  ), p_fallback);
end;
$$;

create or replace function public.helios_min_charge_usd()
returns numeric language sql stable security definer set search_path = public, pg_temp
as $$ select public.helios_parameter('min_charge_usd', 10.00) $$;

create or replace function public.helios_staff_commission_usd()
returns numeric language sql stable security definer set search_path = public, pg_temp
as $$ select public.helios_parameter('staff_commission_usd', 0.50) $$;

create or replace function public.helios_eligibility_lookups_per_staff_day()
returns integer language sql stable security definer set search_path = public, pg_temp
as $$ select public.helios_parameter('eligibility_lookups_per_staff_day', 60)::integer $$;

create or replace function public.helios_payment_four_eyes()
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select public.helios_parameter('payment_four_eyes', 0) >= 1 $$;

create or replace function public.helios_receipt_resends_per_day()
returns integer language sql stable security definer set search_path = public, pg_temp
as $$ select public.helios_parameter('receipt_resends_per_day', 3)::integer $$;

revoke all on function public.helios_min_charge_usd()                    from public, anon;
revoke all on function public.helios_staff_commission_usd()              from public, anon;
revoke all on function public.helios_eligibility_lookups_per_staff_day() from public, anon;
revoke all on function public.helios_payment_four_eyes()                 from public, anon;
revoke all on function public.helios_receipt_resends_per_day()           from public, anon;
grant execute on function public.helios_min_charge_usd()                    to authenticated;
grant execute on function public.helios_staff_commission_usd()              to authenticated;
grant execute on function public.helios_eligibility_lookups_per_staff_day() to authenticated;
grant execute on function public.helios_payment_four_eyes()                 to authenticated;
grant execute on function public.helios_receipt_resends_per_day()           to authenticated;

-- ---------------------------------------------------------------------------
-- 6. El monto mínimo deja de ser un CHECK rígido
-- ---------------------------------------------------------------------------

alter table public.charges drop constraint charges_amount_usd_check;
alter table public.charges add constraint charges_amount_usd_positive check (amount_usd > 0);

/**
 * La regla del monto de un financiamiento (docs/01 §1.2 y §1.3): libre, con
 * hasta 2 decimales y no menos de `min_charge_usd`. `p_base` es el monto de la
 * consulta, SIN el fee. Lanza 22023 con el texto para mostrar tal cual.
 */
create or replace function public.helios_assert_charge_amount(p_base numeric)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_min numeric := public.helios_min_charge_usd();
begin
  if p_base is null or p_base <= 0 then
    raise exception 'Escribe el monto de la consulta' using errcode = '22023';
  end if;

  if p_base <> round(p_base, 2) then
    raise exception 'El monto admite como mucho 2 decimales' using errcode = '22023';
  end if;

  if p_base < v_min then
    raise exception 'El monto mínimo es $%',
      case when v_min = trunc(v_min) then trunc(v_min)::text
           else to_char(v_min, 'FM999999990.00') end
      using errcode = '22023';
  end if;
end;
$$;

revoke all on function public.helios_assert_charge_amount(numeric) from public, anon;
grant execute on function public.helios_assert_charge_amount(numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Las funciones que imprimen dinero en un texto
-- ---------------------------------------------------------------------------
-- Copiadas de la base tal cual (pg_get_functiondef, 2026-09-30), con `€` →
-- `$` y «euro(s)» → «dólar(es)». `create or replace` conserva dueño y
-- privilegios. Los textos que siguen hablando de la app, de grupos o de
-- «consumo» los reescriben las fases que tocan esas funciones (H3, H7).

-- ── public.admin_business_parameters(p_incluir_sin_valor boolean) — 1 línea(s)
CREATE OR REPLACE FUNCTION public.admin_business_parameters(p_incluir_sin_valor boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
      -- El programado, si lo hay. Es lo que deja ver "sube a $3 el lunes".
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
$function$
;

-- ── public.admin_discarded_deposits(p_limit integer) — 2 línea(s)
CREATE OR REPLACE FUNCTION public.admin_discarded_deposits(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.discarded_at desc nulls last), '[]'::jsonb)
    into v_rows
  from (
    select
      l.id,
      l.bank,
      l.moved_on,
      l.reference,
      l.amount_ves,
      l.description,
      -- En dólares a la tasa de ESE día, como en `admin_unmatched_deposits`.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        -- La del DÓLAR ('BCV'); 'BCV_EUR' es la serie del euro que dejó Ronda, archivada.
        where r.source = 'BCV'
          and r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd,
      l.imported_at,
      coalesce(pi.full_name, 'Alguien del equipo') as imported_by_name,
      l.resolved_at as discarded_at,
      l.resolved_by as discarded_by,
      coalesce(pa.full_name, 'Alguien del equipo') as discarded_by_name,
      l.resolution_note as reason
    from public.bank_statement_lines l
    left join public.platform_admins pa on pa.user_id = l.resolved_by
    left join public.platform_admins pi on pi.user_id = l.imported_by
    where l.status = 'descartado'
    order by l.resolved_at desc nulls last
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ) q;

  return v_rows;
end;
$function$
;

-- ── public.admin_metricas_general(p_merchant_id uuid) — 1 línea(s)
CREATE OR REPLACE FUNCTION public.admin_metricas_general(p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_hoy        date    := metricas.hoy();
  -- «Activos» es haber consumido en los últimos 30 días operativos, hoy
  -- incluido: la misma ventana que `admin_overview(30)`.
  v_ventana    integer := 30;
  v_gracia     integer := public.helios_on_time_grace_days();
  -- Lo que tarda un consumo en tener su impago definitivo: la última cuota
  -- vence y recorre la escalera entera (la «temporada» de las cosechas).
  v_temporada  integer := 2 * public.helios_installment_interval_days()
                        + public.helios_mora_expulsion_days();
  v_todos      boolean := p_merchant_id is null;
  v_desde      date;
  v_k          record;
  v_q          record;
  v_p          record;
  v_s          record;
  v_c          record;
  v_l          record;
  v_cartera    record;
  v_repiten    integer;
  v_caja       numeric;
  v_curva      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- ── Los consumos ──────────────────────────────────────────────────────────
  select
    coalesce(sum(k.financed_usd), 0)                                   as financed,
    count(*)::integer                                                  as consumos,
    coalesce(sum(k.servicio_usd), 0)                                   as servicio,
    coalesce(sum(k.iva_usd), 0)                                        as iva,
    min(k.business_date)                                               as primero,
    count(distinct k.merchant_id)::integer                             as locales,
    (count(distinct k.merchant_id) filter (
       where k.business_date between v_hoy - (v_ventana - 1) and v_hoy))::integer as locales_ventana,
    -- El impago con el que Ronda ni gana ni pierde, como en admin_overview:
    -- servicio ÷ (neto transferido al local + servicio). El IVA no entra.
    case when coalesce(sum(k.neto_local_usd + k.servicio_usd), 0) > 0
         then round(100 * sum(k.servicio_usd) / sum(k.neto_local_usd + k.servicio_usd), 2)
    end                                                                as empate,
    -- El consumo cuya cosecha ya terminó su ciclo de cobro.
    coalesce(sum(k.financed_usd) filter (where k.business_date + v_temporada <= v_hoy), 0) as maduro
  into v_k
  from metricas.consumos k
  where v_todos or k.merchant_id = p_merchant_id;

  -- ── Las cuotas: las personas, lo cobrado, lo perdido y el cobro a tiempo ──
  select
    count(distinct q.user_id)::integer                                 as personas,
    (count(distinct q.user_id) filter (
       where q.business_date between v_hoy - (v_ventana - 1) and v_hoy))::integer as activos,
    coalesce(sum(q.payable_usd)  filter (where q.status = 'paid'), 0)  as cobrado_payable,
    coalesce(sum(q.financed_usd) filter (where q.status = 'paid'), 0)  as cobrado_financed,
    coalesce(sum(q.fee_usd)      filter (where q.status = 'paid'), 0)  as cobrado_fee,
    (count(*) filter (where q.status = 'paid'))::integer               as cobrado_cuotas,
    -- Todo lo movido: todas las cuotas de los consumos confirmados, pagadas,
    -- por pagar o dadas por perdidas. Es lo cobrado + lo por cobrar + lo perdido.
    coalesce(sum(q.payable_usd), 0)                                    as movido_payable,
    coalesce(sum(q.fee_usd), 0)                                        as movido_fee,
    count(*)::integer                                                  as movido_cuotas,
    coalesce(sum(q.financed_usd), 0)                                   as financiado,
    (count(distinct q.user_id) filter (where q.estado_hoy = 'perdida'))::integer as perdido_personas,
    (count(distinct q.user_id) filter (where q.estado_hoy in ('vencida', 'por_vencer')))::integer as deben_personas,
    (count(*) filter (where q.estado_hoy in ('vencida', 'por_vencer')))::integer as vivas_cuotas,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 1))::integer as juzgadas_1,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 1 and q.estado_hoy = 'a_tiempo'))::integer as a_tiempo_1,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 2))::integer as juzgadas_2,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 2 and q.estado_hoy = 'a_tiempo'))::integer as a_tiempo_2
  into v_q
  from metricas.cuotas q
  where v_todos or q.merchant_id = p_merchant_id;

  -- Repiten: personas con cuota en dos noches distintas o más (en ese local,
  -- si hay local: son sus `personas_por_local.noches`).
  select count(*)::integer into v_repiten
  from (
    select q.user_id
    from metricas.cuotas q
    where v_todos or q.merchant_id = p_merchant_id
    group by q.user_id
    having count(distinct q.business_date) >= 2
  ) r;

  -- ── La cartera de hoy: por cobrar, vencido, perdido y la mora ────────────
  select * into v_cartera from metricas.cartera_al(v_hoy, p_merchant_id);

  -- ── Los cargos por atraso: ingreso aparte, sin IVA ────────────────────────
  select
    coalesce(sum(a.amount_usd), 0)                                     as devengado,
    coalesce(sum(a.amount_usd) filter (where a.status = 'paid'), 0)    as cobrado,
    count(*)::integer                                                  as cargos
  into v_c
  from metricas.cargos_por_atraso a
  where v_todos or a.merchant_id = p_merchant_id;

  -- ── Lo que se les debe a los locales, como en Pagos a locales ────────────
  -- La lista de `admin_merchant_payables` y la suma sin los locales de
  -- prueba, que es lo que pinta Caja (`payablesTotals`).
  select
    coalesce(sum((x->>'total_pending_usd')::numeric), 0)               as total,
    coalesce(sum((x->>'overdue_usd')::numeric), 0)                     as atrasado,
    (count(*) filter (where (x->>'total_pending_usd')::numeric > 0))::integer as locales
  into v_l
  from jsonb_array_elements(coalesce(public.admin_merchant_payables(), '[]'::jsonb)) x
  where coalesce((x->>'is_test')::boolean, false) = false
    and (v_todos or (x->>'merchant_id')::uuid = p_merchant_id);

  -- ── Lo que no es de ningún local ──────────────────────────────────────────
  -- Con local la consulta no lee nada (`where v_todos`) y sus cifras salen
  -- como null más abajo; se hace igual para que `v_p` siempre tenga forma.
  select
    count(*)::integer                                                  as registros,
    (count(*) filter (where p.verificado))::integer                    as verificados,
    (count(*) filter (where p.primer_consumo_dia is not null))::integer as han_comprado
  into v_p
  from metricas.personas p
  where v_todos;

  -- Quien pidió el código, se verificara o no (la boca del embudo), y quien
  -- además lo metió. No son registros; tampoco son de ningún local.
  select
    count(*)::integer                                                  as solicitaron,
    (count(*) filter (where s.etapa <> 'solicito_el_codigo'))::integer as telefono_confirmado
  into v_s
  from metricas.solicitudes s
  where v_todos;

  if v_todos then
    -- La caja del libro, la misma que Caja y el Resumen.
    v_caja := (public.admin_cash_position() ->> 'cash')::numeric;
    -- La primera solicitud del código o el primer consumo: el mismo «desde el
    -- inicio» que Métricas › Gente.
    v_desde := metricas.gente_primer_dia();
  else
    v_desde := v_k.primero;
  end if;

  -- ── La curva: semana a semana y su acumulado ─────────────────────────────
  if v_desde is null then
    v_curva := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'semana',            c.semana,
             'registros',         case when v_todos then c.registros end,
             'registros_acum',    case when v_todos then c.registros_acum end,
             'consumos',          c.consumos,
             'financed_usd',      c.financed,
             'financed_acum_usd', c.financed_acum
           ) order by c.semana), '[]'::jsonb)
    into v_curva
    from (
      select
        s.semana,
        coalesce(r.n, 0)                                               as registros,
        sum(coalesce(r.n, 0)) over (order by s.semana)                 as registros_acum,
        coalesce(k.n, 0)                                               as consumos,
        coalesce(k.f, 0)                                               as financed,
        sum(coalesce(k.f, 0)) over (order by s.semana)                 as financed_acum
      from generate_series(metricas.lunes(v_desde), metricas.lunes(v_hoy), interval '7 days') g(d)
      cross join lateral (select g.d::date as semana) s
      left join (
        select p.registro_semana as semana, count(*)::integer as n
        from metricas.personas p
        where v_todos
        group by 1
      ) r on r.semana = s.semana
      left join (
        select k.semana, count(*)::integer as n, sum(k.financed_usd) as f
        from metricas.consumos k
        where v_todos or k.merchant_id = p_merchant_id
        group by 1
      ) k on k.semana = s.semana
    ) c;
  end if;

  return jsonb_build_object(
    'hoy',   v_hoy,
    'desde', v_desde,
    'local', p_merchant_id,
    'ventana_dias',   v_ventana,
    'gracia_dias',    v_gracia,
    'temporada_dias', v_temporada,

    'gente', jsonb_build_object(
      'solicitaron',         case when v_todos then v_s.solicitaron end,
      'telefono_confirmado', case when v_todos then v_s.telefono_confirmado end,
      -- Registros = personas verificadas; `verificados` es la misma cifra.
      'registros',        case when v_todos then v_p.registros end,
      'verificados',      case when v_todos then v_p.verificados end,
      'han_comprado',     case when v_todos then v_p.han_comprado end,
      'han_comprado_pct', case when v_todos and v_p.registros > 0
                               then round(100.0 * v_p.han_comprado / v_p.registros, 1) end,
      'activos',          v_q.activos,
      'repiten',          v_repiten
    ),

    'consumo', jsonb_build_object(
      'financed_usd',    v_k.financed,
      'consumos',        v_k.consumos,
      'ticket_usd',      case when v_k.consumos > 0 then round(v_k.financed / v_k.consumos, 2) end,
      'personas',        v_q.personas,
      'locales',         case when v_todos then v_k.locales end,
      'locales_activos', case when v_todos then v_k.locales_ventana end
    ),

    'dinero', jsonb_build_object(
      'movido', jsonb_build_object(
        'payable_usd',  v_q.movido_payable,
        'financed_usd', v_q.financiado,
        'fee_usd',      v_q.movido_fee,
        'cuotas',       v_q.movido_cuotas,
        'consumos',     v_k.consumos
      ),
      'por_cobrar', jsonb_build_object(
        'payable_usd',  v_cartera.vencido_payable_usd  + v_cartera.por_vencer_payable_usd,
        'financed_usd', v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
        'fee_usd',      v_cartera.vencido_fee_usd      + v_cartera.por_vencer_fee_usd,
        'cuotas',       v_q.vivas_cuotas,
        'personas',     v_q.deben_personas
      ),
      'vencido', jsonb_build_object(
        'payable_usd',  v_cartera.vencido_payable_usd,
        'financed_usd', v_cartera.vencido_financed_usd,
        'fee_usd',      v_cartera.vencido_fee_usd,
        'cuotas',       v_cartera.cuotas_vencidas,
        'personas',     v_cartera.personas_vencidas
      ),
      'cobrado', jsonb_build_object(
        'payable_usd',  v_q.cobrado_payable,
        'financed_usd', v_q.cobrado_financed,
        'fee_usd',      v_q.cobrado_fee,
        'cuotas',       v_q.cobrado_cuotas
      ),
      -- Lo que Ronda ha ganado, cada cosa en su cifra.
      'servicio_usd', v_k.servicio,
      'cargos_por_atraso', jsonb_build_object(
        'devengado_usd', v_c.devengado,
        'cobrado_usd',   v_c.cobrado,
        'cargos',        v_c.cargos
      ),
      'perdido', jsonb_build_object(
        'payable_usd',  v_cartera.perdido_payable_usd,
        'financed_usd', v_cartera.perdido_financed_usd,
        'fee_usd',      v_cartera.perdido_fee_usd,
        'personas',     v_q.perdido_personas
      ),
      'caja_usd', case when v_todos then v_caja end,
      'por_pagar_locales', jsonb_build_object(
        'total_usd',    v_l.total,
        'atrasado_usd', v_l.atrasado,
        'locales',      v_l.locales
      )
    ),

    'riesgo', jsonb_build_object(
      'mora_pct',    v_cartera.mora_pct,
      -- Consumo perdido y sin pagar sobre todo el consumo, como el impago de
      -- admin_overview. Nulo sin consumo.
      'impago_pct',  case when v_q.financiado > 0
                          then round(100 * v_cartera.perdido_financed_usd / v_q.financiado, 2) end,
      'empate_pct',  v_k.empate,
      'a_tiempo', jsonb_build_array(
        jsonb_build_object(
          'cuota', 1, 'juzgadas', v_q.juzgadas_1, 'a_tiempo', v_q.a_tiempo_1,
          'pct', case when v_q.juzgadas_1 > 0 then round(100.0 * v_q.a_tiempo_1 / v_q.juzgadas_1, 1) end
        ),
        jsonb_build_object(
          'cuota', 2, 'juzgadas', v_q.juzgadas_2, 'a_tiempo', v_q.a_tiempo_2,
          'pct', case when v_q.juzgadas_2 > 0 then round(100.0 * v_q.a_tiempo_2 / v_q.juzgadas_2, 1) end
        )
      )
    ),

    -- Por cada $100 de consumo: los tres sumandos del margen, cada uno con
    -- su signo, y el consumo cuya cosecha ya está cerrada.
    'por_cada_100', jsonb_build_object(
      'financed_usd',        v_k.financed,
      'consumos',            v_k.consumos,
      'financed_maduro_usd', v_k.maduro,
      'servicio_usd',        v_k.servicio,
      'cargos_usd',          v_c.devengado,
      'perdido_usd',         v_cartera.perdido_financed_usd,
      'por_100', case when v_k.financed > 0 then jsonb_build_object(
        'servicio_usd', round(100 * v_k.servicio / v_k.financed, 2),
        'cargos_usd',   round(100 * v_c.devengado / v_k.financed, 2),
        'perdido_usd',  round(100 * v_cartera.perdido_financed_usd / v_k.financed, 2),
        'margen_usd',   round(100 * (v_k.servicio + v_c.devengado - v_cartera.perdido_financed_usd)
                              / v_k.financed, 2)
      ) end
    ),

    'curva', v_curva
  );
end;
$function$
;

-- ── public.admin_record_bank_balance(p_balance_ves numeric, p_balance_usd numeric, p_checked_on date, p_note text) — 2 línea(s)
CREATE OR REPLACE FUNCTION public.admin_record_bank_balance(p_balance_ves numeric DEFAULT NULL::numeric, p_balance_usd numeric DEFAULT NULL::numeric, p_checked_on date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_day    date;
  v_fx     numeric;
  v_usd    numeric(18,4);
  v_ledger numeric(18,4);
begin
  perform public.helios_assert_super_admin('anotar el saldo del banco');

  if p_balance_ves is null and p_balance_usd is null then
    raise exception 'Escribe el saldo, en bolívares o en dólares' using errcode = '22023';
  end if;

  v_day := coalesce(p_checked_on, public.helios_business_date(now()));

  if v_day > public.helios_business_date(now()) then
    raise exception 'No se puede anotar el saldo de un día que no ha pasado'
      using errcode = '22023';
  end if;

  v_fx := public.current_fx_rate('BCV', v_day);

  if p_balance_usd is not null then
    v_usd := p_balance_usd;
  elsif v_fx is null then
    raise exception 'No hay tasa para ese día: escribe el saldo en dólares'
      using errcode = '22023';
  else
    v_usd := round(p_balance_ves / v_fx, 4);
  end if;

  -- La caja del libro a esa fecha: todo lo que movió caja hasta ese día
  -- operativo, incluido.
  select coalesce(sum(e.debit) - sum(e.credit), 0)
  into v_ledger
  from ledger.entries e
  join ledger.accounts a on a.id = e.account_id
  join ledger.transactions t on t.id = e.transaction_id
  where a.account_type = 'cash'
    and t.business_date <= v_day;

  insert into public.bank_balance_checks
    (checked_on, balance_ves, balance_usd, fx_rate, ledger_usd, note, recorded_by)
  values (v_day, p_balance_ves, v_usd, v_fx, v_ledger,
          nullif(trim(coalesce(p_note, '')), ''), v_actor)
  on conflict (checked_on) do update
    set balance_ves = excluded.balance_ves,
        balance_usd = excluded.balance_usd,
        fx_rate     = excluded.fx_rate,
        ledger_usd  = excluded.ledger_usd,
        note        = excluded.note,
        recorded_by = excluded.recorded_by,
        created_at  = now();

  perform audit.log(v_actor, 'bank_balance.recorded', null, jsonb_build_object(
    'checked_on', v_day,
    'balance_usd', v_usd,
    'ledger_usd', v_ledger,
    'difference_usd', round(v_usd - v_ledger, 4),
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true,
    'checked_on', v_day,
    'balance_usd', v_usd,
    'ledger_usd', v_ledger,
    'difference_usd', round(v_usd - v_ledger, 4)
  );
end;
$function$
;

-- ── public.admin_reverse_charge(p_charge_id uuid, p_reason text) — 3 línea(s)
CREATE OR REPLACE FUNCTION public.admin_reverse_charge(p_charge_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_bdate    date := public.helios_business_date(now());
  v_financed numeric(18,4);
  v_payable  numeric(18,4);
  v_bloqueo  text;
  v_tx       uuid;
  v_origen   record;
  v_name     text;
  v_partes   jsonb;
  v_parte    record;
  v_n        integer;
begin
  -- Revertir mueve el libro hacia atrás: es del super admin.
  perform public.helios_assert_super_admin('revertir un consumo');

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Revertir un consumo requiere motivo' using errcode = '22023';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  -- ── Las redes ───────────────────────────────────────────────────────────
  -- Las mismas que la ficha enseña antes de pulsar, con el mismo texto: las
  -- dos leen `helios_charge_reverse_blocker`. Van después del `for update`,
  -- con el consumo ya bloqueado.
  v_bloqueo := public.helios_charge_reverse_blocker(p_charge_id);
  if v_bloqueo is not null then
    raise exception '%', v_bloqueo using errcode = '22023';
  end if;

select full_name into v_name from public.profiles where id = v_charge.user_id;

  select
    coalesce(sum(financed_usd), 0),
    coalesce(sum(amount_usd), 0)
  into v_financed, v_payable
  from public.installments where charge_id = p_charge_id;

  -- Y las mismas dos cifras POR PERSONA, que es lo que de verdad hace falta
  -- para devolver algo. Se toman AQUÍ, antes de que el borrado de más abajo se
  -- lleve las cuotas por delante: después de él ya no hay dónde mirar quién
  -- puso cuánto.
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',  s.user_id,
           'financed', s.financed,
           'payable',  s.payable
         ) order by s.user_id), '[]'::jsonb)
  into v_partes
  from (
    select i.user_id,
           sum(i.financed_usd) as financed,
           sum(i.amount_usd)   as payable
    from public.installments i
    where i.charge_id = p_charge_id
    group by i.user_id
  ) s;

  v_n := jsonb_array_length(v_partes);

  -- ── 1. El asiento contrario ──────────────────────────────────────────────
  -- Se refleja lo que se escribió, pata por pata, en vez de recalcularlo: si
  -- el consumo se asentó con una comisión o un IVA distintos de los de hoy
  -- —porque los parámetros cambiaron— recalcular dejaría un residuo.

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'manual_adjustment',
    'reverse_charge:' || p_charge_id::text,
    v_bdate,
    p_charge_id,
    format('Consumo revertido: %s', trim(p_reason))
  )
  returning id into v_tx;

  for v_origen in
    select e.account_id, e.debit, e.credit
    from ledger.transactions t
    join ledger.entries e on e.transaction_id = t.id
    where t.reference_id = p_charge_id
      and t.type <> 'manual_adjustment'
  loop
    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, v_origen.account_id, v_origen.credit, v_origen.debit);
  end loop;

  -- ── 2. Las cuotas ────────────────────────────────────────────────────────
  -- Se borran, no se marcan. Sin pagos detrás no dejan nada que auditar —lo
  -- que pasó está en el asiento y en la bitácora— y dejarlas con un estado
  -- nuevo obligaría a que las quince consultas que filtran por 'pending' se
  -- acordaran de excluirlo.

  -- Antes, las cotizaciones caducadas y sin reporte que tocan estas cuotas:
  -- su clave foránea impedía borrarlas. Ya no se pueden reportar
  -- (`report_payment` rechaza una caducada), así que no guardan nada. Se
  -- borran enteras, con sus líneas y cargos en cascada, aunque llevaran también
  -- cuotas de otro consumo: caducada, tampoco servía para pagar esas. Las
  -- vigentes ya frenaron arriba.
  delete from public.payment_quotes q
  where q.valid_until <= now()
    and not exists (select 1 from public.payment_reports r where r.quote_id = q.id)
    and exists (
      select 1
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id and i.charge_id = p_charge_id
    );

  delete from public.installments where charge_id = p_charge_id;

  -- ── 3. Las liquidaciones al local que no se han pagado ───────────────────

  delete from public.settlements
  where charge_id = p_charge_id and status = 'pending';

  -- ── 4. El cupo vuelve, a cada quien lo suyo ──────────────────────────────
  -- Exactamente lo contrario de lo que `helios_assign_debt` sumó al crear las
  -- cuotas: el financiado de esa persona sale de `charged_usd` y su fee —el
  -- pagadero menos el financiado— de `fee_usd`. Persona por persona, porque
  -- persona por persona se sumó.
  --
  -- El techo del grupo va en el mismo viaje. `group_members.spent_usd` es lo
  -- que esta mesa ya le cargó a cada quien esta noche, y nadie lo deshacía: un
  -- $500 tecleado en vez de $50 quemaba el techo de los cuatro y revertirlo no
  -- se lo devolvía, así que la mesa se quedaba sin sitio para el consumo bueno.
  -- Que es el caso para el que existe esta función.

  for v_parte in
    select (e->>'user_id')::uuid     as user_id,
           (e->>'financed')::numeric as financed,
           (e->>'payable')::numeric  as payable
    from jsonb_array_elements(v_partes) e
  loop
    update public.user_credit_blocks
    set charged_usd = greatest(charged_usd - v_parte.financed, 0),
        fee_usd     = greatest(fee_usd - (v_parte.payable - v_parte.financed), 0)
    where user_id = v_parte.user_id and closed_at is null;

    -- PODA (Helios): aquí se devolvía el techo de la mesa (`group_members`).
  end loop;

  -- ── 5. El consumo queda marcado ──────────────────────────────────────────

  update public.charges
  set status      = 'reverted',
      void_reason = trim(p_reason),
      voided_by   = v_actor,
      voided_at   = now()
  where id = p_charge_id;

  -- Cada quien tiene que enterarse: le desapareció una deuda y un cargo de su
  -- historial. Enterarse por sorpresa es peor que el error original.
  --
  -- TODOS los que debían, no solo quien puso la cuenta, y cada uno con SU
  -- parte: mandarle a alguien el total de la mesa es contarle mal lo que le
  -- acaba de pasar.
  for v_parte in
    select (e->>'user_id')::uuid    as user_id,
           (e->>'payable')::numeric as payable
    from jsonb_array_elements(v_partes) e
  loop
    perform public.notify(
      v_parte.user_id,
      'payment_reconciled',
      'Anulamos un consumo',
      case when v_n > 1 then
        format('Anulamos la cuenta del grupo. Tu parte de $%s ya no la debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      else
        format('Anulamos el consumo de $%s. Ya no lo debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      end
    );
  end loop;

  perform audit.log(v_actor, 'charge.reverted', p_charge_id, jsonb_build_object(
    'user_id', v_charge.user_id,
    'full_name', v_name,
    'merchant_id', v_charge.merchant_id,
    'amount_usd', v_charge.amount_usd,
    'financed_usd', v_financed,
    'payable_usd', v_payable,
    -- El reparto entero. Los totales no dicen a quién se le devolvió qué, y esa
    -- es justo la pregunta que se le hace a la bitácora cuando hay que revisar
    -- una reversión de grupo meses después.
    'debtors', v_n,
    'split', v_partes,
    'business_date', v_charge.business_date,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'charge_id', p_charge_id,
    'amount_usd', v_charge.amount_usd,
    -- El total devuelto, y debajo a quién. Con un cargo de grupo el total solo
    -- no dice nada: son varios bloques de crédito los que se movieron.
    'credit_returned_usd', v_financed,
    'debtors', v_n,
    'split', v_partes
  );
end;
$function$
;

-- ── public.admin_set_merchant_status(p_merchant_id uuid, p_status merchant_status, p_note text) — 2 línea(s)
CREATE OR REPLACE FUNCTION public.admin_set_merchant_status(p_merchant_id uuid, p_status merchant_status, p_note text DEFAULT NULL::text)
 RETURNS merchants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_row   public.merchants%rowtype;
  v_owed  numeric(18,4);
begin
  perform public.helios_assert_super_admin('cambiar el estado de un comercio');

  -- Terminar un comercio al que todavía se le debe dinero es casi siempre un
  -- error: lo pendiente hay que pagarlo igual. Se bloquea y se dice cuánto.
  if p_status = 'terminated' then
    -- NUEVO (2026-09-18): las parciales cuentan, y cuenta lo que FALTA.
    --
    -- Sumaba el importe entero de las `pending` y se olvidaba de las
    -- `partial`, que existen desde 20260911191000 y son justo las que llevan
    -- un resto por transferir. Con una liquidación a medias como única deuda,
    -- esto daba cero y dejaba terminar un comercio al que todavía se le debe
    -- dinero —dinero que sigue vivo y sigue saliendo en el cierre del lunes,
    -- porque `helios_settlement_outlook` sí las cuenta—.
    select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
    from public.settlements
    where merchant_id = p_merchant_id and status in ('pending', 'partial');

    if v_owed > 0 then
      -- Con dos decimales y no los cuatro de la columna: este texto se lee tal
      -- cual en el panel, y «le debes $6.0000» parece un error de la pantalla.
      raise exception 'No puedes terminar este comercio: le debes $%. Págale primero.',
        to_char(v_owed, 'FM999999990.00')
        using errcode = '22023';
    end if;
  end if;

  update public.merchants
    set status = p_status, updated_at = now()
  where id = p_merchant_id
  returning * into v_row;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.status_changed', p_merchant_id,
    jsonb_build_object('status', p_status, 'note', p_note));

  return v_row;
end;
$function$
;

-- ── public.admin_unmatched_deposits(p_limit integer) — 2 línea(s)
CREATE OR REPLACE FUNCTION public.admin_unmatched_deposits(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.moved_on desc), '[]'::jsonb)
  into v_rows
  from (
    select
      l.id,
      l.bank,
      l.moved_on,
      l.reference,
      l.amount_ves,
      l.description,
      l.imported_at,
      -- En dólares a la tasa de ESE día, no a la de hoy: el abono entró con la
      -- tasa de su fecha y volver a convertirlo con otra inventa una
      -- diferencia que no existió.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        -- La del DÓLAR ('BCV'); 'BCV_EUR' es la serie del euro que dejó Ronda, archivada.
        where r.source = 'BCV'
          and r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd
    from public.bank_statement_lines l
    where l.status = 'sin_dueno'
      and not exists (
        select 1 from public.payment_reports pr where pr.statement_line_id = l.id
      )
      and not exists (
        select 1
        from public.payment_reports pr
        join public.payment_quotes pq on pq.id = pr.quote_id
        where pr.status = 'reconciled'
          and pr.statement_line_id is null
          and pr.reference is not null
          and l.reference like '%' || pr.reference
          and abs(l.amount_ves - pq.amount_ves) <= 1.00
          and l.moved_on between (pr.created_at::date - 5) and (pr.created_at::date + 5)
      )
    order by l.moved_on desc
    limit least(coalesce(p_limit, 100), 500)
  ) q;

  return v_rows;
end;
$function$
;

-- ── public.admin_user_behavior(p_from date, p_to date, p_merchant_id uuid) — 6 línea(s)
CREATE OR REPLACE FUNCTION public.admin_user_behavior(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := metricas.hoy();
  v_local  boolean := p_merchant_id is not null;
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from metricas.gente_ventana(p_from, p_to) w;

  with
  consumo as (
    select q.user_id, q.charge_id, q.business_date as dia, q.financed_usd as fin
    from metricas.cuotas q
    where q.business_date between v_from and v_to
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ),
  -- Una fila por persona activa en la ventana.
  porpersona as (
    select user_id,
           sum(fin)                          as gasto,
           count(distinct charge_id)::int    as ordenes,
           count(distinct dia)::int          as noches
    from consumo
    group by 1
  ),
  -- Tramos fijos y en dólares, no percentiles.
  tramos(orden, label, lo, hi) as (
    values (1, 'Hasta $25',   0::numeric,   25::numeric),
           (2, '$25 a $50',   25::numeric,  50::numeric),
           (3, '$50 a $100',  50::numeric,  100::numeric),
           (4, '$100 a $200', 100::numeric, 200::numeric),
           (5, 'Más de $200', 200::numeric, 1e9::numeric)
  ),
  -- El decil 1 es el 10 % que más gasta.
  ranking as (
    select user_id, gasto, ntile(10) over (order by gasto desc) as decil
    from porpersona
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   p_merchant_id,
    'active_users',  (select count(*) from porpersona),

    'per_user', jsonb_build_object(
      'avg_financed_usd', (select coalesce(round(avg(gasto), 2), 0) from porpersona),
      'p50_financed_usd', (select coalesce(percentile_cont(0.5) within group (order by gasto), 0)::numeric(18,2) from porpersona),
      'p90_financed_usd', (select coalesce(percentile_cont(0.9) within group (order by gasto), 0)::numeric(18,2) from porpersona),
      'avg_orders',       (select coalesce(round(avg(ordenes), 2), 0) from porpersona),
      'p50_orders',       (select coalesce(percentile_disc(0.5) within group (order by ordenes), 0)::int from porpersona),
      'avg_nights',       (select coalesce(round(avg(noches), 2), 0) from porpersona)
    ),

    'spend_buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',   t.orden,
        'label', t.label,
        'users', (select count(*) from porpersona pp where pp.gasto > t.lo and pp.gasto <= t.hi)
      ) order by t.orden)
      from tramos t
    ), '[]'::jsonb),

    'order_buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',   x.n,
        'label', case when x.n >= 5 then '5 o más' else x.n::text end,
        'users', (select count(*) from porpersona pp
                  where (x.n < 5 and pp.ordenes = x.n) or (x.n = 5 and pp.ordenes >= 5))
      ) order by x.n)
      from generate_series(1, 5) x(n)
    ), '[]'::jsonb),

    'concentration', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key',          b.key,
        'label',        b.label,
        'users',        (select count(*) from ranking r where r.decil between b.lo and b.hi),
        'financed_usd', (select coalesce(sum(r.gasto), 0) from ranking r where r.decil between b.lo and b.hi)
      ) order by b.orden)
      from (values (1, 'top10',  'El 10 % que más gasta', 1, 1),
                   (2, 'next40', 'El 40 % siguiente',     2, 5),
                   (3, 'rest50', 'La mitad de abajo',     6, 10))
           as b(orden, key, label, lo, hi)
    ), '[]'::jsonb),

    -- El padrón por nivel, con lo que movió cada nivel en la ventana. Con
    -- local, cuánta gente hay en cada nivel es del padrón: `users` vale null.
    'levels', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.level)
      from (
        select s.nivel                                                    as level,
               case when v_local then null else count(*)::int end          as users,
               count(*) filter (where pp.user_id is not null)::int         as active_users,
               coalesce(sum(pp.gasto), 0)                                  as financed_usd
        from metricas.personas s
        left join porpersona pp on pp.user_id = s.user_id
        group by s.nivel
      ) q
    ), '[]'::jsonb),

    -- El padrón por estado: no se parte por local.
    'statuses', case when v_local then null else coalesce((
      select jsonb_agg(to_jsonb(q) order by q.users desc)
      from (
        select s.estado as status, count(*)::int as users
        from metricas.personas s
        group by s.estado
      ) q
    ), '[]'::jsonb) end
  )
  into v_result;

  return v_result;
end;
$function$
;

-- ── public.admin_waive_late_fee(p_fee_id uuid, p_reason text) — 1 línea(s)
CREATE OR REPLACE FUNCTION public.admin_waive_late_fee(p_fee_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor  uuid := auth.uid();
  v_fee    public.late_fees%rowtype;
  v_tx     uuid;
  v_name   text;
begin
  -- Condonar mueve el libro: es del super admin.
  perform public.helios_assert_super_admin('condonar un cargo');

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Condonar un cargo requiere motivo' using errcode = '22023';
  end if;

  select * into v_fee from public.late_fees where id = p_fee_id for update;

  if not found then
    raise exception 'No existe ese cargo' using errcode = 'P0002';
  end if;

  -- Un cargo ya cobrado no se condona: se devuelve, y devolver dinero es otra
  -- operación con otras consecuencias. Uno ya castigado tampoco: ya salió.
  if v_fee.status <> 'pending' then
    raise exception 'Solo se puede condonar un cargo pendiente (este está %)', v_fee.status
      using errcode = '22023';
  end if;

  select full_name into v_name from public.profiles where id = v_fee.user_id;

  update public.late_fees
  set status = 'written_off',
      waived_at = now(),
      waived_by = v_actor,
      waive_reason = trim(p_reason)
  where id = p_fee_id;

  -- El asiento contrario. El original se queda donde está.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'manual_adjustment',
    'late_fee_waived:' || p_fee_id::text,
    public.helios_business_date(now()),
    p_fee_id,
    format('Cargo por atraso condonado: %s', trim(p_reason))
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('platform_revenue', null), v_fee.amount_usd, 0),
    (v_tx, ledger.get_or_create_account('user_receivable', v_fee.user_id), 0, v_fee.amount_usd);

  -- Y fuera del bloque, para que el cupo no se quede cerrado por una deuda que
  -- ya no existe.
  update public.user_credit_blocks
  set charged_usd = greatest(charged_usd - v_fee.amount_usd, 0)
  where id = v_fee.credit_block_id;

  -- La deuda de alguien no baja en silencio, igual que no sube en silencio.
  perform public.notify(
    v_fee.user_id,
    'late_fee_waived',
    'Te quitamos el cargo',
    format('Quitamos el cargo por atraso de $%s de tu deuda. Ya no lo debes.',
           to_char(v_fee.amount_usd, 'FM999999990.00'))
  );

  perform audit.log(v_actor, 'late_fee.waived', p_fee_id, jsonb_build_object(
    'user_id', v_fee.user_id,
    'full_name', v_name,
    'amount_usd', v_fee.amount_usd,
    'days_late', v_fee.days_late,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'amount_usd', v_fee.amount_usd,
    'user_id', v_fee.user_id
  );
end;
$function$
;

-- ── public.evaluate_level(p_user_id uuid, p_cooldown_days integer) — 1 línea(s)
CREATE OR REPLACE FUNCTION public.evaluate_level(p_user_id uuid, p_cooldown_days integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_standing jsonb;
  v_current  smallint;
  v_eligible smallint;
  v_new      public.levels%rowtype;
begin
  v_standing := public.level_standing(p_user_id, p_cooldown_days);

  v_current  := (v_standing->>'current_level')::smallint;
  v_eligible := (v_standing->>'eligible_level')::smallint;

  -- Una cuenta congelada, bloqueada o expulsada no sube. Premiar a quien está
  -- en mora contradice para qué existen los niveles.
  if (v_standing->>'account_status') <> 'active' then
    return jsonb_build_object('promoted', false, 'reason', 'cuenta_no_activa');
  end if;

  if (v_standing->>'in_cooldown')::boolean then
    return jsonb_build_object(
      'promoted', false, 'reason', 'enfriamiento',
      'until', v_standing->>'cooldown_until'
    );
  end if;

  if v_eligible <= v_current then
    return jsonb_build_object('promoted', false, 'reason', 'sin_cambio');
  end if;

  select * into v_new from public.levels where level = v_eligible;

  update public.profiles
    set level = v_eligible, updated_at = now()
  where id = p_user_id;

  insert into public.level_changes (user_id, from_level, to_level, reason, detail)
  values (
    p_user_id, v_current, v_eligible, 'promotion',
    jsonb_build_object(
      'paid_usd', v_standing->'paid_usd',
      'months', v_standing->'months',
      'required_spend_usd', v_new.required_spend_usd,
      'required_months', v_new.required_months
    )
  );

  perform public.notify(
    p_user_id, 'level_up',
    format('Subiste al %s', v_new.label),
    format('Tu límite pasa a $%s. Lo lograste pagando $%s a tiempo.',
           trim(to_char(v_new.monthly_limit_usd, 'FM999999990.00')),
           trim(to_char((v_standing->>'paid_usd')::numeric, 'FM999999990.00'))),
    jsonb_build_object('level', v_eligible, 'limit_usd', v_new.monthly_limit_usd)
  );

  return jsonb_build_object(
    'promoted', true,
    'from_level', v_current,
    'to_level', v_eligible,
    'limit_usd', v_new.monthly_limit_usd
  );
end;
$function$
;

-- ── public.grant_first_level_on_activation() — 2 línea(s)
CREATE OR REPLACE FUNCTION public.grant_first_level_on_activation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_level public.levels%rowtype;
begin
  if new.status <> 'active' or old.status not in ('pending_kyc', 'pending_pin') then
    return new;
  end if;

  if new.level >= 1 then
    return new;
  end if;

  select * into v_level from public.levels where level = 1;

  new.level := 1;
  new.updated_at := now();

  insert into public.level_changes (user_id, from_level, to_level, reason, detail)
  values (
    new.id, coalesce(old.level, 0), 1, 'kyc_approved',
    jsonb_build_object('limit_usd', v_level.monthly_limit_usd)
  );

  -- Aviso propio, sin plantilla: la de `level_up` habla de lo que se pagó
  -- ("Lo lograste pagando $X a tiempo"), y aquí no se pagó nada — se verificó
  -- la identidad. El tipo sí es el mismo, que es lo que hace que caiga en la
  -- misma bandeja.
  perform public.notify(
    new.id, 'level_up',
    format('Llegaste al %s', v_level.label),
    format('Tu identidad está verificada. Tienes $%s de saldo para gastar sin inicial.',
           trim(to_char(v_level.monthly_limit_usd, 'FM999999990.00'))),
    jsonb_build_object('level', 1, 'limit_usd', v_level.monthly_limit_usd)
  );

  return new;
end;
$function$
;

-- ── public.notify_installment_moment_batch(p_offset integer, p_key text, p_due date, p_after uuid, p_limit integer) — 12 línea(s)
CREATE OR REPLACE FUNCTION public.notify_installment_moment_batch(p_offset integer, p_key text, p_due date, p_after uuid, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_row       record;
  v_last      uuid := p_after;
  v_seen      integer := 0;
  v_sent      integer := 0;
  v_fee       numeric := public.helios_late_fee_usd();
  v_grace     integer := public.helios_late_fee_grace_days();
  v_demotion  integer := public.helios_mora_demotion_days();
  v_dia       text := public.helios_weekday_es(p_due);
  v_fecha     text := to_char(p_due, 'DD/MM');
  v_comercio  text;
  v_monto     text;
begin
  for v_row in
    select i.user_id,
           sum(i.amount_usd)        as monto,
           count(*)                 as cuotas,
           min(m.name)              as un_local,
           count(distinct m.id)     as locales
    from public.installments i
    join public.charges c   on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    where i.status = 'pending'
      and i.due_date = p_due
      and i.user_id > p_after
      -- Con un pago reportado esperando conciliación no se avisa: se debe,
      -- pero el usuario ya hizo lo suyo.
      and not exists (
        select 1
        from public.payment_reports r
        join public.payment_quote_items q on q.quote_id = r.quote_id
        where q.installment_id = i.id
          and r.status in ('reported', 'in_review')
      )
    group by i.user_id
    order by i.user_id
    limit p_limit
  loop
    v_last := v_row.user_id;
    v_seen := v_seen + 1;

    -- Ya se avisó de esta fecha en este momento.
    if exists (
      select 1 from public.notifications
      where user_id = v_row.user_id
        and template_key = p_key
        and data->>'due_date' = p_due::text
    ) then
      continue;
    end if;

    v_comercio := case
      when v_row.locales = 1 then v_row.un_local
      else format('%s locales', v_row.locales)
    end;

    v_monto := trim(to_char(v_row.monto, 'FM999999990.00'));

    perform public.notify(
      v_row.user_id,
      'installment_due'::public.notification_type,
      -- El texto de fábrica, por si nadie publicó nada desde el panel.
      case
        when p_offset = -1 then format('Mañana vence tu cuota de $%s', v_monto)
        when p_offset < 0  then format('Tu cuota de $%s vence el %s', v_monto, v_dia)
        when p_offset = 0 and p_key = 'installment_due_today'
                           then format('Hoy vence tu cuota de $%s', v_monto)
        when p_offset = 0  then 'Última oportunidad para pagar tu cuota de hoy'
        when p_offset = 1  then 'Tu cuota venció ayer y tu saldo está bloqueado'
        when p_offset = v_grace
                           then 'Mañana se aplicará el cargo por mora'
        when p_offset < v_grace
                           then format('Tu cuota lleva %s días vencida', p_offset)
        when p_offset >= 7 then 'Una semana de retraso en tu cuota'
        else format('Tu cuota acumula %s días de retraso', p_offset)
      end,
      case
        when p_offset = -1 then
          format('Tu cuota de $%s vence mañana, %s %s. Puedes pagarla ahora desde la aplicación.',
                 v_monto, v_dia, v_fecha)
        when p_offset < 0 then
          format('El %s %s vence una cuota de $%s. Puedes adelantarte y pagarla ahora desde la aplicación.',
                 v_dia, v_fecha, v_monto)
        when p_offset = 0 and p_key = 'installment_due_today' then
          format('Tu cuota de $%s vence hoy, %s %s. Complétala desde la aplicación antes de que finalice el día.',
                 v_monto, v_dia, v_fecha)
        when p_offset = 0 then
          format('Tu cuota de $%s del %s %s continúa pendiente. Si no la registras hoy, mañana tu saldo quedará bloqueado.',
                 v_monto, v_dia, v_fecha)
        when p_offset = 1 then
          format('La cuota de $%s del %s %s está vencida. Regulariza el pago para recuperar tu saldo y volver a consumir en los locales.',
                 v_monto, v_dia, v_fecha)
        when p_offset = v_grace then
          format('Tu cuota de $%s del %s %s acumula %s días de retraso. Si la pagas hoy, evitarás el cargo por mora de $%s por cuota.',
                 v_monto, v_dia, v_fecha, p_offset,
                 trim(to_char(v_fee, 'FM999999990.00')))
        when p_offset < v_grace then
          format('La cuota de $%s del %s %s sigue vencida y tu saldo continúa bloqueado. Regularízala pronto para evitar el cargo por mora de $%s por cuota.',
                 v_monto, v_dia, v_fecha,
                 trim(to_char(v_fee, 'FM999999990.00')))
        when p_offset >= 7 then
          format('La cuota de $%s del %s %s lleva %s días vencida. A los %s días de retraso tu nivel se reduce automáticamente.',
                 v_monto, v_dia, v_fecha, p_offset, v_demotion)
        else
          format('La cuota de $%s del %s %s continúa vencida y ya genera cargos por mora. Regularízala para detener el cargo y recuperar tu saldo.',
                 v_monto, v_dia, v_fecha)
      end,
      -- `due_date` es lo que abre Cuotas con esa fecha ya marcada, y lo que la
      -- cancelación por pago reportado usa para saber a qué aviso apunta.
      jsonb_build_object('due_date', p_due, 'moment', p_key),
      p_key,
      jsonb_build_object(
        'dia',        v_dia,
        'fecha',      v_fecha,
        'dias',       abs(p_offset),
        'monto',      v_monto,
        'cuotas',     v_row.cuotas,
        'comercio',   v_comercio,
        'cargo',      trim(to_char(v_fee, 'FM999999990.00')),
        'dias_nivel', v_demotion
      )
    );

    v_sent := v_sent + 1;
  end loop;

  return jsonb_build_object('last', v_last, 'seen', v_seen, 'sent', v_sent);
end;
$function$
;

-- ── public.notify_payment_result() — 1 línea(s)
CREATE OR REPLACE FUNCTION public.notify_payment_result()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_quote  public.payment_quotes%rowtype;
  v_motivo text;
begin
  if new.status = old.status then
    return null;
  end if;

  select * into v_quote from public.payment_quotes where id = new.quote_id;

  if new.status = 'reconciled' then
    perform public.notify(
      new.user_id, 'payment_reconciled',
      'Confirmamos tu pago',
      format('Recibimos $%s. %s cuota(s) quedaron al día.',
             trim(to_char(v_quote.amount_usd, 'FM999999990.00')),
             v_quote.installment_count),
      jsonb_build_object('report_id', new.id, 'amount_usd', v_quote.amount_usd),
      'payment_reconciled',
      jsonb_build_object(
        'monto',  trim(to_char(v_quote.amount_usd, 'FM999999990.00')),
        'cuotas', v_quote.installment_count
      )
    );

  elsif new.status = 'rejected' then
    -- El motivo es el cuerpo entero del aviso de hoy. Se calcula una vez para
    -- que el respaldo y el marcador no puedan decir cosas distintas.
    v_motivo := coalesce(new.rejection_note,
      'No encontramos esa referencia. Revísala y vuelve a reportarla.');

    perform public.notify(
      new.user_id, 'payment_rejected',
      'No pudimos confirmar tu pago',
      v_motivo,
      jsonb_build_object('report_id', new.id),
      'payment_rejected',
      jsonb_build_object('motivo', v_motivo)
    );
  end if;

  return null;
end;
$function$
;

-- ── public.recompute_profile_mora_state(p_user_id uuid) — 2 línea(s)
CREATE OR REPLACE FUNCTION public.recompute_profile_mora_state(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_status       public.profile_status;
  v_level        smallint;
  v_new_level    smallint;
  v_max_days_late integer;
  v_inst         record;
  v_fee_id       uuid;
  v_fee_amount   numeric(18,4);
  v_fees         integer := 0;
  v_fees_usd     numeric(18,4) := 0;
begin
  select status, level into v_status, v_level
  from public.profiles where id = p_user_id for update;

  if not found or v_status = 'expelled' then
    -- Terminal: requiere revisión manual del super admin (D-10, sin decidir).
    return;
  end if;

  select coalesce(max(public.helios_business_date(now()) - i.due_date), 0)
    into v_max_days_late
  from public.installments i
  where i.user_id = p_user_id
    and i.status = 'pending'
    and i.due_date < public.helios_business_date(now());

  if v_max_days_late <= 0 then
    -- Sin mora. Si venía bloqueado, se restablece el acceso — pero el nivel
    -- perdido no se recupera solo aquí: eso lo hace `evaluate_level` cuando
    -- pasa el enfriamiento.
    if v_status in ('frozen', 'suspended') then
      update public.profiles set status = 'active', updated_at = now() where id = p_user_id;
    end if;
    return;
  end if;

  -- ── NUEVO: un cargo por cada cuota pasada de la gracia ───────────────────
  for v_inst in
    select i.id, (public.helios_business_date(now()) - i.due_date) as days_late
    from public.installments i
    where i.user_id = p_user_id
      and i.status = 'pending'
      and (public.helios_business_date(now()) - i.due_date) > public.helios_late_fee_grace_days()
    order by i.due_date
  loop
    v_fee_id := public.charge_late_fee(v_inst.id, v_inst.days_late);

    -- Null cuando esa cuota ya lo tenía: el cargo es uno por cuota, corra el
    -- cron las veces que corra.
    if v_fee_id is not null then
      select amount_usd into v_fee_amount from public.late_fees where id = v_fee_id;
      v_fees     := v_fees + 1;
      v_fees_usd := v_fees_usd + v_fee_amount;
    end if;
  end loop;

  -- Un solo aviso por corrida, con el total. La deuda de alguien no puede
  -- crecer en silencio, pero tampoco a base de tres empujones seguidos.
  if v_fees > 0 then
    perform public.notify(
      p_user_id,
      'late_fee_charged',
      'Cargo por mora',
      case when v_fees = 1 then
        format(
          'Se sumaron $%s a tu deuda por una cuota con más de %s días de retraso. Va incluido en tu próximo pago.',
          trim(to_char(v_fees_usd, 'FM999999990.00')),
          public.helios_late_fee_grace_days()
        )
      else
        format(
          'Se sumaron $%s a tu deuda: $%s por cada una de tus %s cuotas con más de %s días de retraso. Van incluidos en tu próximo pago.',
          trim(to_char(v_fees_usd, 'FM999999990.00')),
          trim(to_char(public.helios_late_fee_usd(), 'FM999999990.00')),
          v_fees,
          public.helios_late_fee_grace_days()
        )
      end,
      jsonb_build_object(
        'late_fee_count', v_fees,
        'amount_usd', v_fees_usd,
        'days_late', v_max_days_late
      )
    );
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  if v_max_days_late > public.helios_mora_expulsion_days() then
    if v_status <> 'expelled' then
      update public.profiles
        set status = 'expelled', is_blacklisted = true, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_level, 'expelled');

      perform public.charge_off_user_debt(p_user_id);
    end if;
    return;
  end if;

  if v_max_days_late >= public.helios_mora_demotion_days() then
    if v_status <> 'suspended' then
      v_new_level := greatest(1, v_level - 1);

      update public.profiles
        set status = 'suspended', level = v_new_level, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_new_level, 'mora_demotion');
    end if;
    return;
  end if;

  -- Antes del umbral de bajada: congelado, sin tocar el nivel.
  if v_status = 'active' then
    update public.profiles set status = 'frozen', updated_at = now() where id = p_user_id;
  end if;
end;
$function$
;

-- ── public.reconcile_payment(p_report_id uuid, p_actor uuid, p_approve boolean, p_note text) — 3 línea(s)
CREATE OR REPLACE FUNCTION public.reconcile_payment(p_report_id uuid, p_actor uuid, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_report    public.payment_reports%rowtype;
  v_quote     public.payment_quotes%rowtype;
  v_item      record;
  v_fee       record;
  v_fee_usd   numeric(18,4) := 0;
  v_fee_count integer := 0;
  v_bdate     date;
  v_tx        uuid;
  v_acct_recv uuid;
  v_acct_cash uuid;
  v_block     public.user_credit_blocks%rowtype;
  v_total     numeric(18,4) := 0;
  v_settled   numeric(18,4);
  v_done      integer := 0;
  v_expected  integer;
begin
  select * into v_report from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  if v_report.status not in ('reported', 'in_review') then
    raise exception 'Este reporte ya fue resuelto (%)', v_report.status using errcode = '22023';
  end if;

  if not p_approve then
    update public.payment_reports
      set status = 'rejected', reviewed_by = p_actor, reviewed_at = now(),
          rejection_note = p_note
    where id = p_report_id;

    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  select count(*) into v_expected
  from public.payment_quote_items where quote_id = v_quote.id;

  if v_expected = 0 then
    raise exception 'La cotización % no tiene cuotas', v_quote.id using errcode = '22023';
  end if;

  v_bdate := public.helios_business_date(now());
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_report.user_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'installment_payment', 'reconcile:' || p_report_id::text, v_bdate, p_report_id,
    format('Pago conciliado de %s cuota(s)', v_quote.installment_count)
  )
  returning id into v_tx;

  for v_item in
    select i.installment_id, i.amount_usd, c.merchant_id,
           t.policy, t.per_installment_pct,
           ins.due_date,
           -- El importe que tiene la cuota AHORA, para cotejarlo con el que se
           -- congeló al cotizar.
           ins.amount_usd as current_amount_usd
    from public.payment_quote_items i
    join public.installments ins on ins.id = i.installment_id
    join public.charges c on c.id = ins.charge_id
    -- LEFT: la falta de condiciones de liquidación no puede sacar la cuota
    -- del bucle. `ins` sigue en el lado no anulable, así que el `for update`
    -- de abajo es válido.
    left join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
    where i.quote_id = v_quote.id
    for update of ins
  loop
    if v_item.policy is null then
      raise exception
        'El comercio % no tiene condiciones de liquidación: configúralas antes de conciliar este pago',
        v_item.merchant_id
        using errcode = '22023';
    end if;

    if (select status from public.installments where id = v_item.installment_id) = 'paid' then
      raise exception 'La cuota % ya estaba pagada', v_item.installment_id using errcode = '22023';
    end if;

    if v_item.current_amount_usd is distinct from v_item.amount_usd then
      raise exception
        'La cuota % cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_item.installment_id, v_item.amount_usd, v_item.current_amount_usd
        using errcode = '22023';
    end if;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- `paid_by_report_id`: con qué pago se saldó, y no solo cuándo.
    update public.installments
      set status = 'paid', paid_at = now(), paid_by_report_id = p_report_id
    where id = v_item.installment_id;
    -- ───────────────────────────────────────────────────────────────────────

    v_total := v_total + v_item.amount_usd;
    v_done  := v_done + 1;

    -- En 'on_collection' la obligación nace al cobrar. Se DEVENGA, igual que
    -- el adelanto: la caja se mueve cuando se reporte la transferencia.
    if v_item.policy = 'on_collection' then
      v_settled := round(v_item.amount_usd * v_item.per_installment_pct * 2 / 100, 4);

      insert into public.settlements
        (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_item.merchant_id, v_item.installment_id, 'on_collection', v_settled,
         v_bdate, v_bdate, 'pending');
    end if;
  end loop;

  -- La red. Si el bucle no tocó todas las cuotas de la cotización, algo las
  -- descartó: se deshace todo antes de asentar dinero por una cifra que no
  -- corresponde con lo que se acaba de saldar.
  if v_done <> v_expected then
    raise exception
      'Se saldaron % de % cuotas de la cotización %: no se concilia a medias',
      v_done, v_expected, v_quote.id
      using errcode = '22023';
  end if;

  -- Los cargos por mora que viajaban en la cotización, uno a uno.
  for v_fee in
    select l.late_fee_id, l.amount_usd as quoted_usd,
           f.status, f.amount_usd as current_usd
    from public.payment_quote_late_fees l
    join public.late_fees f on f.id = l.late_fee_id
    where l.quote_id = v_quote.id
    for update of f
  loop
    if v_fee.status <> 'pending' then
      raise exception
        'El cargo por mora % de esta cotización ya no está pendiente (%): revísalo antes de conciliar',
        v_fee.late_fee_id, v_fee.status
        using errcode = '22023';
    end if;

    if v_fee.current_usd is distinct from v_fee.quoted_usd then
      raise exception
        'El cargo por mora % cambió de importe desde que se cotizó ($% cotizados, $% ahora): no se concilia hasta revisarlo',
        v_fee.late_fee_id, v_fee.quoted_usd, v_fee.current_usd
        using errcode = '22023';
    end if;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    update public.late_fees
      set status = 'paid', paid_at = now(), paid_by_report_id = p_report_id
    where id = v_fee.late_fee_id;
    -- ───────────────────────────────────────────────────────────────────────

    v_fee_usd   := v_fee_usd + v_fee.quoted_usd;
    v_fee_count := v_fee_count + 1;
  end loop;

  -- La misma red que arriba, en la otra moneda: lo que se salda tiene que sumar
  -- lo que se cotizó, o el asiento de caja no es el dinero que entró.
  if v_fee_usd is distinct from v_quote.late_fee_usd then
    raise exception
      'Los cargos por mora de la cotización % suman $% y se cotizaron $%: no se concilia hasta revisarlo',
      v_quote.id, v_fee_usd, v_quote.late_fee_usd
      using errcode = '22023';
  end if;

  v_total := v_total + v_fee_usd;

  -- Lo único que mueve caja aquí es el dinero que ENTRÓ del usuario.
  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_total, 0),
    (v_tx, v_acct_recv, 0, v_total);

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(),
        rejection_note = coalesce(p_note, rejection_note)
  where id = p_report_id;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_report.user_id and closed_at is null
  for update;

  if found then
    update public.user_credit_blocks
      set paid_usd = paid_usd + v_total
    where id = v_block.id;

    -- Contra cupo + fee. El fee es deuda: hasta que esté pagado, el bloque
    -- sigue abierto y el límite sigue ocupado.
    if v_block.paid_usd + v_total >= v_block.charged_usd + v_block.fee_usd then
      update public.user_credit_blocks
        set closed_at = now(), close_reason = 'paid'
      where id = v_block.id;
    end if;
  end if;

  perform public.recompute_profile_mora_state(v_report.user_id);

  return jsonb_build_object(
    'ok', true, 'status', 'reconciled',
    'amount_usd', v_total,
    'installments', v_done,
    'late_fee_usd', v_fee_usd,
    'late_fee_count', v_fee_count
  );
end;
$function$
;

