-- ============================================================================
-- Ronda — Las alertas miran el cupo, no la costumbre
--
-- Salen dos tipos de `admin_risk_alerts`: «varios consumos en una noche» y
-- «primer consumo al tope». Las dos describen uso normal de la app (salir,
-- pedir tres rondas, estrenar el cupo entero) y llenaban la lista de ruido.
-- Decisión de Javier del 2026-09-25. Con ellas se van sus dos parámetros.
--
-- Entra uno que sí es riesgo: «consumo sobre el cupo». No debería pasar
-- nunca, porque `helios_assign_debt` lo impide bajo el cerrojo del bloque de
-- crédito; si sale, algo se rompió en la app o en la base. Es un chequeo de
-- integridad, no de comportamiento.
--
-- ── La regla ────────────────────────────────────────────────────────────────
-- Una deuda es la pareja (consumo, persona): en un consumo de grupo hay una
-- por integrante. Al abrirse (`installments.created_at`), salta si:
--
--   sobre_cupo  lo que ya ocupaba su cupo + esta deuda > el límite de su nivel
--               EN ESE MOMENTO. Ocupa cupo toda deuda abierta antes y no
--               saldada todavía entonces: un consumo libera su cupo cuando
--               todas sus cuotas están pagadas (`paid_at`, que es el momento
--               de la aprobación, el mismo en que el sistema lo libera).
--   en_mora     tenía una cuota vencida y sin pagar: su disponible era cero.
--
-- Mismas cuentas que `helios_credit_used_usd` y `can_take_debt`, hechas hacia
-- atrás. Se usa `financed_usd`: el fee y los cargos por atraso no ocupan cupo.
--
-- ── El límite de entonces ───────────────────────────────────────────────────
-- `levels` no guarda historia. El nivel de entonces sale de `helios_level_at`;
-- el límite de ese nivel, del primer `level.configure` de la bitácora
-- POSTERIOR a la deuda (su `before`), o del de hoy si no lo hubo. Las
-- migraciones que movieron límites no dejan bitácora; la última fue la
-- escalera del 2026-09-09, así que solo se miran deudas desde el 2026-09-10.
--
-- Lo que puede callar (nunca inventar): un reparto de grupo que baja la parte
-- de los que ya estaban, y un consumo revertido, que borra sus cuotas.
-- ============================================================================

-- Los parámetros de los dos tipos que se van.
delete from public.business_parameters
 where key in ('alerta_consumos_por_noche', 'alerta_primer_consumo_pct');
delete from public.business_parameter_catalog
 where key in ('alerta_consumos_por_noche', 'alerta_primer_consumo_pct');

create or replace function public.admin_risk_alerts(
  p_limit integer default 200,
  p_kinds text[]  default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_today  date    := public.helios_business_date(now());
  v_limit  integer := greatest(least(coalesce(p_limit, 200), 1000), 1);
  v_window constant integer := 90;
  -- Antes de esta fecha los límites cambiaron por migración, sin bitácora.
  c_escalera constant date := date '2026-09-10';
  v_desde  date;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_desde := greatest(v_today - (v_window - 1), c_escalera);

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

  -- 4. Consumo sobre el cupo. Cada deuda con cuándo se abrió y cuándo dejó
  --    de ocupar cupo (null: sigue ocupándolo).
  deuda as (
    select
      i.user_id,
      i.charge_id,
      min(i.created_at)                                          as abierta,
      sum(i.financed_usd)                                        as financiado,
      case when bool_and(i.status = 'paid') then max(i.paid_at) end as saldada
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
    group by i.user_id, i.charge_id
  ),
  sobre as (
    select
      d.*,
      coalesce((
        select sum(o.financiado) from deuda o
         where o.user_id = d.user_id
           and o.charge_id <> d.charge_id
           and o.abierta < d.abierta
           and (o.saldada is null or o.saldada > d.abierta)
      ), 0)                                                      as ocupado,
      exists (
        select 1 from public.installments j
         where j.user_id = d.user_id
           and j.charge_id <> d.charge_id
           and not j.is_test
           and j.created_at < d.abierta
           and j.due_date < public.helios_business_date(d.abierta)
           and (j.paid_at is null or j.paid_at > d.abierta)
      )                                                          as en_mora,
      coalesce(public.helios_level_at(d.user_id, d.abierta), p.level) as nivel
    from deuda d
    join public.profiles p on p.id = d.user_id
    where public.helios_business_date(d.abierta) >= v_desde
  ),
  sobre_con_limite as (
    select
      s.*,
      coalesce((
        -- El primer cambio de ese nivel DESPUÉS de la deuda dice qué límite
        -- había antes de él, que es el que regía al abrirse.
        select (a.detail -> 'before' ->> 'monthly_limit_usd')::numeric
          from audit.admin_actions a
         where a.action = 'level.configure'
           and (a.detail ->> 'level')::smallint = s.nivel
           and a.created_at > s.abierta
         order by a.created_at
         limit 1
      ), l.monthly_limit_usd)                                    as limite
    from sobre s
    join public.levels l on l.level = s.nivel
  ),
  sobre_cupo as (
    select
      x.*,
      array_remove(array[
        case when x.ocupado + x.financiado > x.limite + 0.01 then 'sobre_cupo' end,
        case when x.en_mora then 'en_mora' end
      ], null)                                                   as motivos
    from sobre_con_limite x
    where x.ocupado + x.financiado > x.limite + 0.01
       or x.en_mora
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
    -- 4. Consumo sobre el cupo: siempre alta, porque no debería existir.
    select
      'sobre_cupo:' || s.user_id || ':' || s.charge_id,
      'consumo_sobre_cupo',
      'alta',
      s.user_id,
      s.abierta,
      jsonb_build_object(
        'charge_id',     s.charge_id,
        'order_number',  c.order_number,
        'business_date', c.business_date,
        'merchant_name', m.name,
        'financed_usd',  s.financiado,
        'used_usd',      s.ocupado,
        'limit_usd',     s.limite,
        'level',         s.nivel,
        'reasons',       to_jsonb(s.motivos)
      )
    from sobre_cupo s
    join public.charges   c on c.id = s.charge_id
    join public.merchants m on m.id = c.merchant_id
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
    -- Los cuatro tipos siempre, con o sin alertas, y sin el filtro de
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
                          'consumo_sobre_cupo']) as k(kind)
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
  'Alertas de riesgo globales derivadas de los datos (relacionadas, red y sistema de Didit, consumo sobre el cupo), con su revision. Sin cuentas de prueba.';

-- Las claves de los tipos que ya no existen dejan de aceptarse; sus
-- revisiones se quedan en risk_alert_reviews como constancia.
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

  if v_key !~ '^(relacionada|kyc_red|kyc_sistema|sobre_cupo):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.+$' then
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

revoke all on function public.admin_risk_alerts(integer, text[]) from public, anon;
revoke all on function public.admin_review_risk_alert(text, text) from public, anon;
grant execute on function public.admin_risk_alerts(integer, text[]) to authenticated;
grant execute on function public.admin_review_risk_alert(text, text) to authenticated;
