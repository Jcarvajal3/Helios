-- ============================================================================
-- Ronda — Las alertas de riesgo
--
-- Las señales de fraude ya existen, pero sueltas y solo dentro de una ficha:
-- las cuentas relacionadas salen en la ficha de cada persona, la VPN y el
-- aparato de Didit en su pestaña de identidad. Nadie abre cien fichas para
-- ver si alguna tiene algo. Esta es la lista global, con cinco tipos:
--
--   cuenta_relacionada      mismo aparato o misma cédula que otra persona
--                           (el criterio de `admin_related_accounts`)
--   kyc_red_sospechosa      VPN, Tor o centro de datos en la verificación
--   kyc_sistema_distinto    el sistema que vio Didit no es el de la app
--                           (el mismo aviso que pinta la ficha)
--   varios_consumos_noche   N consumos o más de la misma persona en un día
--                           operativo (N es un parámetro, hoy 3)
--   primer_consumo_al_tope  el primer consumo de la persona se llevó el X %
--                           o más de su límite (X es un parámetro, hoy 95)
--
-- ── Una alerta se calcula, no se guarda ─────────────────────────────────────
-- Cada consulta la deriva de los datos, así que nunca se desincroniza. Lo que
-- sí se guarda es que alguien la revisó: `risk_alert_reviews`, por
-- `alert_key`. La clave es estable y lleva siempre a la persona en segundo
-- lugar (`<tipo>:<persona>:<resto>`), que es lo que deja apuntar la revisión
-- en la bitácora de esa persona.
--
-- Los dos tipos que son sucesos (la noche y el primer consumo) miran los
-- últimos 90 días operativos; los otros tres son estados y no caducan.
-- ============================================================================

insert into public.business_parameter_catalog (key, label, unit, grupo) values
  ('alerta_consumos_por_noche', 'Alerta: consumos de una persona en una noche', 'consumos', 'alerta'),
  ('alerta_primer_consumo_pct', 'Alerta: primer consumo sobre el límite',       '%',        'alerta')
on conflict (key) do nothing;

insert into public.business_parameters (key, value, effective_from, note) values
  ('alerta_consumos_por_noche',  3.00, '2026-08-01', 'Consumos de una misma persona en un día operativo a partir de los cuales sale una alerta.'),
  ('alerta_primer_consumo_pct', 95.00, '2026-08-01', 'Parte del límite que tiene que llevarse el primer consumo de alguien para que salga una alerta.')
on conflict (key, effective_from) do nothing;

-- ---------------------------------------------------------------------------
-- Las revisiones
-- ---------------------------------------------------------------------------

create table if not exists public.risk_alert_reviews (
  alert_key   text primary key,
  reviewed_by uuid,
  reviewed_at timestamptz not null default now(),
  note        text
);

comment on table public.risk_alert_reviews is
  'Que alerta de riesgo reviso quien y cuando. Las alertas no se guardan: se derivan en admin_risk_alerts.';

alter table public.risk_alert_reviews enable row level security;
revoke all on table public.risk_alert_reviews from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- La lista
-- ---------------------------------------------------------------------------

create or replace function public.admin_risk_alerts(
  p_limit integer default 200,
  p_kinds text[]  default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date    := public.helios_business_date(now());
  v_limit  integer := greatest(least(coalesce(p_limit, 200), 1000), 1);
  v_noche  integer := greatest(public.helios_parameter('alerta_consumos_por_noche', 3)::integer, 2);
  v_tope   numeric := public.helios_parameter('alerta_primer_consumo_pct', 95);
  v_window constant integer := 90;
  v_desde  date;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_desde := v_today - (v_window - 1);

  with
  persona as (
    select p.id, p.full_name, p.status::text as status, p.created_at, p.is_test
    from public.profiles p
  ),

  -- 1. Cuentas relacionadas. Mismos cruces que `admin_related_accounts`,
  --    para todo el mundo a la vez.
  pares as (
    select d1.user_id as a, d2.user_id as b, 'dispositivo'::text as motivo,
           greatest(d1.first_seen_at, d2.first_seen_at) as desde
    from public.user_devices d1
    join public.user_devices d2
      on d2.device_hash = d1.device_hash and d2.user_id <> d1.user_id

    union all
    select p1.id, p2.id, 'cedula', greatest(p1.created_at, p2.created_at)
    from public.profiles p1
    join public.profiles p2
      on p2.document_number = p1.document_number and p2.id <> p1.id
    where p1.document_number is not null

    union all
    select v1.user_id, v2.user_id, 'cedula', greatest(v1.created_at, v2.created_at)
    from kyc.verifications v1
    join kyc.verifications v2
      on v2.extracted_document = v1.extracted_document and v2.user_id <> v1.user_id
    where v1.extracted_document is not null

    union all
    -- El nombre solo cuenta acompañado de otra señal (el `having` de abajo).
    select p1.id, p2.id, 'nombre', greatest(p1.created_at, p2.created_at)
    from public.profiles p1
    join public.profiles p2
      on lower(trim(p2.full_name)) = lower(trim(p1.full_name)) and p2.id <> p1.id
    where p1.full_name is not null
  ),
  -- Una alerta por pareja, a nombre de la cuenta más nueva: es la que llegó a
  -- un sitio donde ya había alguien.
  relacion as (
    select
      pr.a as user_id,
      pr.b as otro_id,
      array_agg(distinct pr.motivo order by pr.motivo)      as motivos,
      min(pr.desde) filter (where pr.motivo <> 'nombre')    as desde
    from pares pr
    join persona pa on pa.id = pr.a and not pa.is_test
    join persona pb on pb.id = pr.b and not pb.is_test
    where (pa.created_at, pa.id) > (pb.created_at, pb.id)
    group by pr.a, pr.b
    having bool_or(pr.motivo <> 'nombre')
  ),

  -- 4. Los consumos de cada persona en la ventana, uno por fila.
  consumo as (
    select
      i.user_id,
      c.id                                    as charge_id,
      c.order_number,
      c.business_date,
      c.merchant_id,
      coalesce(c.confirmed_at, c.created_at)  as consumed_at,
      sum(i.financed_usd)                     as financiado
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
      and c.business_date >= v_desde
    group by i.user_id, c.id
  ),
  noche as (
    select
      co.user_id,
      co.business_date,
      count(*)::integer                                         as consumos,
      sum(co.financiado)                                        as financiado,
      count(distinct co.merchant_id)::integer                   as locales,
      jsonb_agg(co.order_number order by co.consumed_at)        as ordenes,
      -- Cuándo saltó: el consumo que llegó al umbral, no el último.
      (array_agg(co.consumed_at order by co.consumed_at))[v_noche] as detectada
    from consumo co
    group by co.user_id, co.business_date
    having count(*) >= v_noche
  ),

  -- 5. El primer consumo de cada persona (de toda su historia) y su nivel de
  --    entonces. El límite es el de hoy para ese nivel: `levels` no guarda
  --    historia.
  primero as (
    select distinct on (i.user_id)
      i.user_id,
      c.id                                    as charge_id,
      c.order_number,
      c.business_date,
      c.merchant_id,
      coalesce(c.confirmed_at, c.created_at)  as consumed_at
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
    order by i.user_id, c.business_date, c.confirmed_at, c.id
  ),
  tope as (
    select
      pm.*,
      (select sum(j.financed_usd) from public.installments j
        where j.charge_id = pm.charge_id and j.user_id = pm.user_id) as financiado,
      coalesce(lv.historia, p.level)                                  as nivel,
      case when lv.historia is null then 'actual' else 'historial' end as base_nivel
    from primero pm
    join public.profiles p on p.id = pm.user_id
    cross join lateral (
      select public.helios_level_at(pm.user_id, pm.consumed_at) as historia
    ) lv
    where pm.business_date >= v_desde
  ),

  alerta as (
    select
      'relacionada:' || r.user_id || ':' || r.otro_id                  as alert_key,
      'cuenta_relacionada'::text                                       as kind,
      case when 'cedula' = any(r.motivos) or cardinality(r.motivos) > 1
           then 'alta' else 'media' end                                as severity,
      r.user_id,
      r.desde                                                          as detected_at,
      jsonb_build_object(
        'other_user_id', r.otro_id,
        'other_name',    o.full_name,
        'other_status',  o.status,
        'reasons',       to_jsonb(r.motivos)
      )                                                                as detail
    from relacion r
    join persona o on o.id = r.otro_id

    union all
    -- 2. Red sospechosa. Todas las verificaciones, no solo la última: quien
    --    lo intenta con VPN y luego sin ella sigue siendo una señal.
    select
      'kyc_red:' || v.user_id || ':' || v.id,
      'kyc_red_sospechosa',
      case when v.didit_device ->> 'is_vpn_or_tor' = 'true' then 'alta' else 'media' end,
      v.user_id,
      coalesce(v.didit_details_at, v.created_at),
      jsonb_build_object(
        'verification_id',     v.id,
        'verification_status', v.status::text,
        'is_vpn_or_tor',       coalesce(v.didit_device ->> 'is_vpn_or_tor' = 'true', false),
        'is_data_center',      coalesce(v.didit_device ->> 'is_data_center' = 'true', false),
        'ip_country',          v.didit_device ->> 'ip_country',
        'ip_city',             v.didit_device ->> 'ip_city',
        'isp',                 v.didit_device ->> 'isp'
      )
    from kyc.verifications v
    where v.didit_device ->> 'is_vpn_or_tor' = 'true'
       or v.didit_device ->> 'is_data_center' = 'true'

    union all
    -- 3. Sistema distinto. La última verificación y la misma regla que la
    --    ficha (`AparatoSegunDidit`): Didit dice iOS o Android, la persona
    --    tiene algún aparato registrado en la app, y ninguno es de ese sistema.
    select
      'kyc_sistema:' || u.user_id || ':' || u.id,
      'kyc_sistema_distinto',
      'media',
      u.user_id,
      coalesce(u.didit_details_at, u.created_at),
      jsonb_build_object(
        'verification_id', u.id,
        'didit_os',        u.didit_device ->> 'os_family',
        'didit_device',    nullif(concat_ws(' ', u.didit_device ->> 'device_brand',
                                                 u.didit_device ->> 'device_model'), ''),
        'app_platforms',   (select jsonb_agg(distinct lower(d.platform))
                              from public.user_devices d
                             where d.user_id = u.user_id and d.platform is not null)
      )
    from (
      select distinct on (v.user_id) v.id, v.user_id, v.didit_device, v.didit_details_at, v.created_at
      from kyc.verifications v
      order by v.user_id, v.created_at desc
    ) u
    where lower(u.didit_device ->> 'os_family') in ('ios', 'android')
      and exists (select 1 from public.user_devices d
                   where d.user_id = u.user_id and d.platform is not null)
      and not exists (select 1 from public.user_devices d
                       where d.user_id = u.user_id
                         and lower(d.platform) = lower(u.didit_device ->> 'os_family'))

    union all
    select
      'noche:' || n.user_id || ':' || n.business_date,
      'varios_consumos_noche',
      'media',
      n.user_id,
      n.detectada,
      jsonb_build_object(
        'business_date',  n.business_date,
        'charge_count',   n.consumos,
        'financed_usd',   n.financiado,
        'merchant_count', n.locales,
        'order_numbers',  n.ordenes
      )
    from noche n

    union all
    select
      'primer_tope:' || t.user_id || ':' || t.charge_id,
      'primer_consumo_al_tope',
      'alta',
      t.user_id,
      t.consumed_at,
      jsonb_build_object(
        'charge_id',     t.charge_id,
        'order_number',  t.order_number,
        'business_date', t.business_date,
        'merchant_name', m.name,
        'financed_usd',  t.financiado,
        'level',         t.nivel,
        'level_basis',   t.base_nivel,
        'limit_usd',     l.monthly_limit_usd,
        'limit_pct',     round(100 * t.financiado / l.monthly_limit_usd, 1)
      )
    from tope t
    join public.levels l    on l.level = t.nivel
    join public.merchants m on m.id = t.merchant_id
    where l.monthly_limit_usd > 0
      and 100 * t.financiado / l.monthly_limit_usd >= v_tope
  ),

  completa as (
    select
      a.alert_key,
      a.kind,
      a.severity,
      a.user_id,
      pe.full_name,
      pe.status                        as user_status,
      a.detected_at,
      a.detail,
      rv.alert_key is not null         as reviewed,
      rv.reviewed_at,
      rv.reviewed_by,
      pa.full_name                     as reviewed_by_name,
      rv.note                          as review_note
    from alerta a
    join persona pe on pe.id = a.user_id and not pe.is_test
    left join public.risk_alert_reviews rv on rv.alert_key = a.alert_key
    left join public.platform_admins pa    on pa.user_id = rv.reviewed_by
  ),
  pedida as (
    select * from completa
    where p_kinds is null or kind = any(p_kinds)
  )
  select jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_window,
    'params', jsonb_build_object(
      'consumos_por_noche', v_noche,
      'primer_consumo_pct', v_tope
    ),
    -- Los cinco tipos siempre, con o sin alertas, y sin el filtro de
    -- `p_kinds`: son los contadores de las pestañas.
    'counts', (
      select jsonb_object_agg(x.kind, jsonb_build_object(
        'total',           x.total,
        'unreviewed',      x.unreviewed,
        'unreviewed_high', x.unreviewed_high
      ))
      from (
        select
          k.kind,
          count(c.alert_key)                                                    as total,
          count(c.alert_key) filter (where not c.reviewed)                      as unreviewed,
          count(c.alert_key) filter (where not c.reviewed and c.severity = 'alta') as unreviewed_high
        from unnest(array['cuenta_relacionada', 'kyc_red_sospechosa', 'kyc_sistema_distinto',
                          'varios_consumos_noche', 'primer_consumo_al_tope']) as k(kind)
        left join completa c on c.kind = k.kind
        group by k.kind
      ) x
    ),
    'total',     (select count(*) from pedida),
    'truncated', (select count(*) from pedida) > v_limit,
    -- Sin revisar primero, las graves antes, y la más reciente arriba.
    'rows', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.reviewed, s.severity = 'media', s.detected_at desc, s.alert_key)
      from (
        select * from pedida
        order by reviewed, severity = 'media', detected_at desc, alert_key
        limit v_limit
      ) s
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_risk_alerts(integer, text[]) is
  'Alertas de riesgo globales derivadas de los datos (relacionadas, red y sistema de Didit, varios consumos en una noche, primer consumo al tope), con su revision. Sin cuentas de prueba.';

-- ---------------------------------------------------------------------------
-- Marcarla como revisada
-- ---------------------------------------------------------------------------
-- Cualquier admin: revisar no cambia nada de la persona, solo deja constancia
-- de que alguien la miró. Volver a revisarla pisa la nota y la fecha, y cada
-- vez deja su línea en la bitácora.

create or replace function public.admin_review_risk_alert(
  p_alert_key text,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_key   text := trim(coalesce(p_alert_key, ''));
  v_note  text := nullif(trim(coalesce(p_note, '')), '');
  v_at    timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_key !~ '^(relacionada|kyc_red|kyc_sistema|noche|primer_tope):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.+$' then
    raise exception 'No existe la alerta «%»', v_key using errcode = '22023';
  end if;

  insert into public.risk_alert_reviews (alert_key, reviewed_by, reviewed_at, note)
  values (v_key, v_actor, now(), v_note)
  on conflict (alert_key) do update
    set reviewed_by = excluded.reviewed_by,
        reviewed_at = excluded.reviewed_at,
        note        = excluded.note
  returning reviewed_at into v_at;

  perform audit.log(v_actor, 'risk_alert.reviewed', split_part(v_key, ':', 2)::uuid,
    jsonb_build_object(
      'alert_key', v_key,
      'kind',      split_part(v_key, ':', 1),
      'note',      v_note
    ));

  return jsonb_build_object('ok', true, 'alert_key', v_key, 'reviewed_at', v_at);
end;
$$;

comment on function public.admin_review_risk_alert(text, text) is
  'Marca una alerta de riesgo como revisada, con nota opcional. Cualquier admin; deja risk_alert.reviewed en la bitacora de la persona.';

revoke all on function public.admin_risk_alerts(integer, text[]) from public, anon;
revoke all on function public.admin_review_risk_alert(text, text) from public, anon;
grant execute on function public.admin_risk_alerts(integer, text[]) to authenticated;
grant execute on function public.admin_review_risk_alert(text, text) to authenticated;
