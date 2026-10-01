-- ============================================================================
-- Dos cabos sueltos de las fases 1B y 1C.
--
-- 1. La alerta `consultas_de_cedula_excesivas` no podía saltar nunca.
--    La consulta que se pasa del límite lanza 22023 y, con el error, se deshace
--    también su propia fila en `eligibility_lookups`. Así que en el registro
--    nunca hay más de `eligibility_lookups_per_staff_day` filas por persona y
--    día, y la condición `count(*) > límite` no se cumplía jamás. Ahora salta
--    al LLEGAR al límite: quien gastó todas sus consultas del día es justo lo
--    que se quiere mirar. Mismo cuerpo que 20261004000400, con esas dos líneas
--    cambiadas (`>=` y el índice de `desde`).
--
-- 2. Revertir un financiamiento dejaba sus avisos en la cola.
--    `admin_reverse_charge` borra las cuotas y marca el cobro como `reverted`,
--    pero el comprobante, la bienvenida y los recordatorios pendientes seguían
--    ahí: el equipo podía escribirle a alguien por una deuda que ya no existe.
--    Un trigger los cancela: los del propio cobro, y los recordatorios de las
--    fechas en las que a esa persona ya no le queda ninguna cuota pendiente
--    (si en esa fecha vence otra compra suya, el aviso sigue siendo cierto).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_risk_alerts(p_limit integer DEFAULT 200, p_kinds text[] DEFAULT NULL::text[], p_subject_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_today   date    := public.helios_business_date(now());
  v_limit   integer := greatest(least(coalesce(p_limit, 200), 1000), 1);
  v_window  constant integer := 90;
  -- Antes de esta fecha los límites cambiaron por migración, sin bitácora.
  c_escalera constant date := date '2026-09-10';
  v_desde   date;
  v_semana  date;
  -- Umbrales (docs/01 §3).
  v_altas     numeric := public.helios_parameter('alert_charges_per_merchant_day', 10);
  v_nuevos    numeric := public.helios_parameter('alert_new_patients_per_merchant_day', 8);
  v_staff_pct numeric := public.helios_parameter('alert_staff_share_pct', 80);
  v_staff_min numeric := public.helios_parameter('alert_staff_share_min_charges', 5);
  v_fpd_pct   numeric := public.helios_parameter('alert_fpd_merchant_pct', 25);
  v_fpd_min   numeric := public.helios_parameter('alert_fpd_min_cases', 5);
  v_expo      numeric := public.helios_parameter('alert_merchant_exposure_usd', 3000);
  v_estreno   numeric := public.helios_parameter('alert_first_charge_limit_pct', 90);
  v_consultas integer := public.helios_eligibility_lookups_per_staff_day();
  v_kinds     text[]  := array[
    'telefono_repetido', 'correo_repetido', 'correo_rebotado',
    'rafaga_de_altas', 'rafaga_de_pacientes_nuevos', 'secretaria_concentrada',
    'impago_primera_cuota_clinica', 'exposicion_clinica',
    'referencia_repetida', 'cupo_al_limite_al_estrenar', 'consultas_de_cedula_excesivas',
    'consumo_sobre_cupo'];
  v_out jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_desde  := v_today - (v_window - 1);
  v_semana := date_trunc('week', v_today::timestamp)::date;

  with
  persona as (
    select p.id,
           coalesce(nullif(btrim(p.full_name), ''), nullif(btrim(concat_ws(' ', p.first_name, p.last_name)), '')) as nombre,
           p.status::text as status, p.created_at, p.is_test, p.level,
           p.phone_e164, lower(btrim(p.email)) as email, p.email_invalid_at
    from public.profiles p
  ),
  clinica as (
    select m.id, m.name, m.is_test from public.merchants m
  ),

  -- ── Paciente: teléfono y correo repetidos ───────────────────────────────
  tel as (
    select p.phone_e164 as valor, count(*) as n,
           (array_agg(p.id order by p.created_at desc, p.id desc))[1] as nuevo,
           max(p.created_at) as desde,
           jsonb_agg(jsonb_build_object('user_id', p.id, 'full_name', p.nombre, 'status', p.status,
                                        'created_at', p.created_at) order by p.created_at, p.id) as pacientes
    from persona p
    where not p.is_test and p.phone_e164 is not null
    group by p.phone_e164
    having count(*) > 1
  ),
  mail as (
    select p.email as valor, count(*) as n,
           (array_agg(p.id order by p.created_at desc, p.id desc))[1] as nuevo,
           max(p.created_at) as desde,
           jsonb_agg(jsonb_build_object('user_id', p.id, 'full_name', p.nombre, 'status', p.status,
                                        'created_at', p.created_at) order by p.created_at, p.id) as pacientes
    from persona p
    where not p.is_test and p.email is not null and p.email <> ''
    group by p.email
    having count(*) > 1
  ),

  -- ── Paciente: el correo rebotó ──────────────────────────────────────────
  rebote as (
    select p.id, p.email, p.email_invalid_at,
           (select jsonb_build_object('event', o.last_event, 'at', o.last_event_at,
                                      'message_id', o.id, 'template_key', o.template_key)
              from public.outbound_messages o
             where o.profile_id = p.id and o.channel = 'email'
               and o.last_event in ('bounced', 'complained')
             order by o.last_event_at desc nulls last, o.created_at desc
             limit 1) as ultimo
    from persona p
    where p.email_invalid_at is not null and not p.is_test
  ),

  -- ── Clínica: ráfagas de un día ──────────────────────────────────────────
  altas as (
    select c.merchant_id, c.business_date as dia, count(*) as n,
           (array_agg(c.confirmed_at order by c.confirmed_at))[v_altas::integer + 1] as desde
    from public.charges c
    where c.confirmed_at is not null and not c.is_test
      and c.business_date >= v_desde
    group by c.merchant_id, c.business_date
    having count(*) > v_altas
  ),
  nuevos as (
    select p.registered_merchant_id as merchant_id,
           public.helios_business_date(p.created_at) as dia, count(*) as n,
           (array_agg(p.created_at order by p.created_at))[v_nuevos::integer + 1] as desde
    from public.profiles p
    where p.registered_merchant_id is not null and not p.is_test
      and public.helios_business_date(p.created_at) >= v_desde
    group by 1, 2
    having count(*) > v_nuevos
  ),

  -- ── Personal: una sola persona hace casi todas las altas de la semana ──
  semana_staff as (
    select c.merchant_id,
           date_trunc('week', c.business_date::timestamp)::date as lunes,
           c.requested_by as staff_id,
           count(*) as n,
           sum(count(*)) over (partition by c.merchant_id, date_trunc('week', c.business_date::timestamp)) as total,
           max(c.confirmed_at) as ultimo
    from public.charges c
    where c.confirmed_at is not null and not c.is_test
      and c.business_date >= v_desde
    group by c.merchant_id, date_trunc('week', c.business_date::timestamp), c.requested_by
  ),
  concentrada as (
    select s.*, round(s.n * 100.0 / s.total, 1) as pct,
           (select count(distinct mu.user_id) from public.merchant_users mu
             where mu.merchant_id = s.merchant_id and mu.is_active) as personal
    from semana_staff s
    where s.total >= v_staff_min
      and s.n * 100.0 / s.total > v_staff_pct
  ),

  -- ── Clínica: sus pacientes no pagan la 1ª cuota ─────────────────────────
  fpd as (
    select c.merchant_id,
           count(*) as casos,
           count(*) filter (where i.status = 'pending') as impagas,
           max(i.due_date) filter (where i.status = 'pending') as ultima_impaga
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.sequence = 1
      and i.due_date < v_today
      and i.due_date >= v_desde
      and c.status = 'confirmed'
      and not c.is_test and not i.is_test
    group by c.merchant_id
    having count(*) >= v_fpd_min
       and count(*) filter (where i.status = 'pending') * 100.0 / count(*) > v_fpd_pct
  ),

  -- ── Clínica: deuda viva originada ───────────────────────────────────────
  expo as (
    select c.merchant_id,
           sum(i.amount_usd) as deuda,
           sum(i.financed_usd) as principal,
           sum(i.amount_usd) filter (where i.due_date < v_today) as vencida,
           count(distinct i.user_id) as pacientes,
           max(c.confirmed_at) as ultimo
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.status = 'pending'
      and i.written_off_at is null
      and c.status = 'confirmed'
      and not c.is_test and not i.is_test
    group by c.merchant_id
    having sum(i.amount_usd) > v_expo
  ),

  -- ── Paciente: la misma referencia de pago en pacientes distintos ────────
  ref_base as (
    select r.id, r.user_id, r.bank, r.reference, r.status::text as status, r.created_at,
           lower(regexp_replace(r.reference, '[^0-9A-Za-z]', '', 'g')) as ref
    from public.payment_reports r
    join persona p on p.id = r.user_id and not p.is_test
    where r.reference is not null
      and r.status <> 'rejected'
  ),
  refs as (
    select b.ref,
           count(distinct b.user_id) as personas,
           count(distinct lower(btrim(coalesce(b.bank, '')))) = 1 as mismo_banco,
           (array_agg(b.user_id order by b.created_at desc, b.id desc))[1] as nuevo,
           max(b.created_at) as desde,
           jsonb_agg(jsonb_build_object('report_id', b.id, 'user_id', b.user_id, 'bank', b.bank,
                                        'reference', b.reference, 'status', b.status,
                                        'created_at', b.created_at) order by b.created_at) as pagos
    from ref_base b
    where length(b.ref) >= 6
    group by b.ref
    having count(distinct b.user_id) > 1
       and max(b.created_at) >= (v_desde::timestamp at time zone 'America/Caracas')
  ),

  -- ── Paciente: estrenó usando casi todo su cupo ──────────────────────────
  primero as (
    select distinct on (c.user_id)
           c.user_id, c.id as charge_id, c.order_number, c.business_date, c.confirmed_at,
           c.merchant_id, coalesce(c.base_usd, c.amount_usd) as base
    from public.charges c
    where c.confirmed_at is not null and c.user_id is not null and not c.is_test
    order by c.user_id, c.confirmed_at, c.id
  ),
  estreno as (
    select x.*, l.monthly_limit_usd as limite,
           round(x.base * 100.0 / nullif(l.monthly_limit_usd, 0), 1) as pct
    from (
      select pr.*, coalesce(public.helios_level_at(pr.user_id, pr.confirmed_at), p.level) as nivel
      from primero pr
      join persona p on p.id = pr.user_id and not p.is_test
      where pr.business_date >= v_desde
    ) x
    join public.levels l on l.level = x.nivel
    where l.monthly_limit_usd > 0
      and x.base * 100.0 / l.monthly_limit_usd > v_estreno
  ),

  -- ── Personal: consultas de cédula por encima del límite ─────────────────
  consultas as (
    select e.staff_user_id,
           public.helios_business_date(e.created_at) as dia,
           count(*) as n,
           count(*) filter (where e.result = 'limite') as bloqueadas,
           min(e.merchant_id::text)::uuid as merchant_id,
           coalesce((array_agg(e.created_at order by e.created_at))[v_consultas],
                    min(e.created_at) filter (where e.result = 'limite')) as desde
    from public.eligibility_lookups e
    where e.created_at >= (v_desde::timestamp at time zone 'America/Caracas')
    group by e.staff_user_id, public.helios_business_date(e.created_at)
    having count(*) >= v_consultas
        or count(*) filter (where e.result = 'limite') > 0
  ),

  -- ── Paciente: financiamiento sobre el cupo (Ronda) ──────────────────────
  deuda as (
    select
      i.user_id, i.charge_id,
      min(i.created_at)                                             as abierta,
      sum(i.financed_usd)                                           as financiado,
      case when bool_and(i.status = 'paid') then max(i.paid_at) end as saldada
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed' and not c.is_test and not i.is_test
    group by i.user_id, i.charge_id
  ),
  sobre as (
    select
      d.*,
      coalesce((
        select sum(o.financiado) from deuda o
         where o.user_id = d.user_id and o.charge_id <> d.charge_id
           and o.abierta < d.abierta
           and (o.saldada is null or o.saldada > d.abierta)
      ), 0) as ocupado,
      exists (
        select 1 from public.installments j
         where j.user_id = d.user_id and j.charge_id <> d.charge_id and not j.is_test
           and j.created_at < d.abierta
           and j.due_date < public.helios_business_date(d.abierta)
           and (j.paid_at is null or j.paid_at > d.abierta)
      ) as en_mora,
      coalesce(public.helios_level_at(d.user_id, d.abierta), p.level) as nivel
    from deuda d
    join public.profiles p on p.id = d.user_id
    where public.helios_business_date(d.abierta) >= greatest(v_desde, c_escalera)
  ),
  sobre_con_limite as (
    select s.*,
      coalesce((
        select (a.detail -> 'before' ->> 'monthly_limit_usd')::numeric
          from audit.admin_actions a
         where a.action = 'level.configure'
           and (a.detail ->> 'level')::smallint = s.nivel
           and a.created_at > s.abierta
         order by a.created_at
         limit 1
      ), l.monthly_limit_usd) as limite
    from sobre s
    join public.levels l on l.level = s.nivel
  ),
  sobre_cupo as (
    select x.*,
      array_remove(array[
        case when x.ocupado + x.financiado > x.limite + 0.01 then 'sobre_cupo' end,
        case when x.en_mora then 'en_mora' end
      ], null) as motivos
    from sobre_con_limite x
    where x.ocupado + x.financiado > x.limite + 0.01 or x.en_mora
  ),

  -- ── Todas, con la misma forma ───────────────────────────────────────────
  alerta (alert_key, kind, severity, subject_type, subject_id, user_id, merchant_id, detected_at, detail) as (
    select 'telefono_repetido:' || t.nuevo || ':' || t.valor, 'telefono_repetido',
           case when t.n >= 3 then 'alta' else 'media' end,
           'paciente', t.nuevo, t.nuevo, null::uuid, t.desde,
           jsonb_build_object('phone_e164', t.valor, 'patient_count', t.n, 'patients', t.pacientes)
    from tel t

    union all
    select 'correo_repetido:' || m.nuevo || ':' || m.valor, 'correo_repetido',
           case when m.n >= 3 then 'alta' else 'media' end,
           'paciente', m.nuevo, m.nuevo, null::uuid, m.desde,
           jsonb_build_object('email', m.valor, 'patient_count', m.n, 'patients', m.pacientes)
    from mail m

    union all
    select 'correo_rebotado:' || r.id || ':' || coalesce(r.email, ''), 'correo_rebotado', 'alta',
           'paciente', r.id, r.id, null::uuid, r.email_invalid_at,
           jsonb_build_object('email', r.email, 'email_invalid_at', r.email_invalid_at,
                              'event', r.ultimo ->> 'event', 'event_at', r.ultimo ->> 'at',
                              'message_id', r.ultimo ->> 'message_id',
                              'template_key', r.ultimo ->> 'template_key')
    from rebote r

    union all
    select 'rafaga_de_altas:' || a.merchant_id || ':' || a.dia, 'rafaga_de_altas',
           case when a.n > 2 * v_altas then 'alta' else 'media' end,
           'clinica', a.merchant_id, null::uuid, a.merchant_id, a.desde,
           jsonb_build_object('business_date', a.dia, 'charge_count', a.n, 'threshold', v_altas,
                              'merchant_id', a.merchant_id, 'merchant_name', k.name)
    from altas a join clinica k on k.id = a.merchant_id and not k.is_test

    union all
    select 'rafaga_de_pacientes_nuevos:' || n.merchant_id || ':' || n.dia, 'rafaga_de_pacientes_nuevos',
           case when n.n > 2 * v_nuevos then 'alta' else 'media' end,
           'clinica', n.merchant_id, null::uuid, n.merchant_id, n.desde,
           jsonb_build_object('business_date', n.dia, 'patient_count', n.n, 'threshold', v_nuevos,
                              'merchant_id', n.merchant_id, 'merchant_name', k.name)
    from nuevos n join clinica k on k.id = n.merchant_id and not k.is_test

    union all
    select 'secretaria_concentrada:' || s.staff_id || ':' || s.merchant_id || ':' || s.lunes,
           'secretaria_concentrada', 'media',
           'personal', s.staff_id, null::uuid, s.merchant_id, s.ultimo,
           jsonb_build_object('week_start', s.lunes, 'charge_count', s.n, 'merchant_charge_count', s.total,
                              'share_pct', s.pct, 'threshold', v_staff_pct,
                              'active_staff', s.personal,
                              'staff_name', public.helios_staff_name(s.staff_id),
                              'merchant_id', s.merchant_id, 'merchant_name', k.name)
    from concentrada s join clinica k on k.id = s.merchant_id and not k.is_test
    where s.personal >= 2

    union all
    select 'impago_primera_cuota_clinica:' || f.merchant_id || ':' || v_semana,
           'impago_primera_cuota_clinica', 'alta',
           'clinica', f.merchant_id, null::uuid, f.merchant_id,
           ((f.ultima_impaga + 1)::timestamp at time zone 'America/Caracas'),
           jsonb_build_object('cases', f.casos, 'unpaid', f.impagas,
                              'fpd_pct', round(f.impagas * 100.0 / f.casos, 1),
                              'threshold', v_fpd_pct, 'min_cases', v_fpd_min,
                              'window_days', v_window,
                              'merchant_id', f.merchant_id, 'merchant_name', k.name)
    from fpd f join clinica k on k.id = f.merchant_id and not k.is_test

    union all
    select 'exposicion_clinica:' || e.merchant_id || ':' || v_semana, 'exposicion_clinica',
           case when e.deuda > 2 * v_expo then 'alta' else 'media' end,
           'clinica', e.merchant_id, null::uuid, e.merchant_id, e.ultimo,
           jsonb_build_object('exposure_usd', e.deuda, 'principal_usd', e.principal,
                              'overdue_usd', coalesce(e.vencida, 0), 'patient_count', e.pacientes,
                              'threshold', v_expo,
                              'merchant_id', e.merchant_id, 'merchant_name', k.name)
    from expo e join clinica k on k.id = e.merchant_id and not k.is_test

    union all
    select 'referencia_repetida:' || r.nuevo || ':' || r.ref, 'referencia_repetida',
           case when r.mismo_banco then 'alta' else 'media' end,
           'paciente', r.nuevo, r.nuevo, null::uuid, r.desde,
           jsonb_build_object('reference', r.ref, 'patient_count', r.personas,
                              'same_bank', r.mismo_banco, 'reports', r.pagos)
    from refs r

    union all
    select 'cupo_al_limite_al_estrenar:' || x.user_id || ':' || x.charge_id, 'cupo_al_limite_al_estrenar',
           'media', 'paciente', x.user_id, x.user_id, x.merchant_id, x.confirmed_at,
           jsonb_build_object('charge_id', x.charge_id, 'order_number', x.order_number,
                              'business_date', x.business_date, 'financed_usd', x.base,
                              'limit_usd', x.limite, 'used_pct', x.pct, 'level', x.nivel,
                              'threshold', v_estreno,
                              'merchant_id', x.merchant_id, 'merchant_name', k.name)
    from estreno x left join clinica k on k.id = x.merchant_id

    union all
    select 'consultas_de_cedula_excesivas:' || q.staff_user_id || ':' || q.dia,
           'consultas_de_cedula_excesivas', 'alta',
           'personal', q.staff_user_id, null::uuid, q.merchant_id, q.desde,
           jsonb_build_object('business_date', q.dia, 'lookups', q.n, 'blocked', q.bloqueadas,
                              'threshold', v_consultas, 'merchant_id', q.merchant_id,
                              'staff_name', public.helios_staff_name(q.staff_user_id),
                              'merchant_name', k.name)
    from consultas q left join clinica k on k.id = q.merchant_id
    where not coalesce(k.is_test, false)

    union all
    select 'sobre_cupo:' || s.user_id || ':' || s.charge_id, 'consumo_sobre_cupo', 'alta',
           'paciente', s.user_id, s.user_id, c.merchant_id, s.abierta,
           jsonb_build_object('charge_id', s.charge_id, 'order_number', c.order_number,
                              'business_date', c.business_date, 'merchant_name', m.name,
                              'financed_usd', s.financiado, 'used_usd', s.ocupado,
                              'limit_usd', s.limite, 'level', s.nivel,
                              'reasons', to_jsonb(s.motivos))
    from sobre_cupo s
    join public.charges   c on c.id = s.charge_id
    join public.merchants m on m.id = c.merchant_id
  ),
  completa as (
    select
      a.alert_key,
      a.kind,
      a.severity,
      a.subject_type,
      a.subject_id,
      case a.subject_type
        when 'paciente' then pe.nombre
        when 'clinica'  then k.name
        when 'personal' then coalesce(public.helios_staff_name(a.subject_id), 'Personal de la clínica')
                             || coalesce(' (' || km.name || ')', '')
      end                              as subject_name,
      a.detected_at                    as first_seen_at,
      a.detail,
      a.user_id,
      pe.nombre                        as full_name,
      pe.status                        as user_status,
      a.merchant_id,
      a.detected_at,
      rv.alert_key is not null         as reviewed,
      rv.reviewed_at,
      rv.reviewed_by,
      pa.full_name                     as reviewed_by_name,
      rv.note                          as review_note
    from alerta a
    left join persona pe on pe.id = a.user_id
    left join clinica k  on k.id = a.subject_id and a.subject_type = 'clinica'
    left join clinica km on km.id = a.merchant_id and a.subject_type = 'personal'
    left join public.risk_alert_reviews rv on rv.alert_key = a.alert_key
    left join public.platform_admins pa    on pa.user_id = rv.reviewed_by
    where a.user_id is null or not pe.is_test
  ),
  pedida as (
    select * from completa c
    where (p_kinds is null or c.kind = any(p_kinds))
      and (p_subject_id is null
           or c.subject_id = p_subject_id
           or c.user_id = p_subject_id
           or c.merchant_id = p_subject_id)
  )
  select jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_window,
    'thresholds', jsonb_build_object(
      'alert_charges_per_merchant_day', v_altas,
      'alert_new_patients_per_merchant_day', v_nuevos,
      'alert_staff_share_pct', v_staff_pct,
      'alert_staff_share_min_charges', v_staff_min,
      'alert_fpd_merchant_pct', v_fpd_pct,
      'alert_fpd_min_cases', v_fpd_min,
      'alert_merchant_exposure_usd', v_expo,
      'alert_first_charge_limit_pct', v_estreno,
      'eligibility_lookups_per_staff_day', v_consultas
    ),
    -- Los tipos siempre, con o sin alertas y sin el filtro de `p_kinds`: son
    -- los contadores de las pestañas (con `p_subject_id`, los de esa ficha).
    'counts', (
      select jsonb_object_agg(x.kind, jsonb_build_object(
        'total',           x.total,
        'unreviewed',      x.unreviewed,
        'unreviewed_high', x.unreviewed_high
      ))
      from (
        select
          k.kind,
          count(c.alert_key)                                                       as total,
          count(c.alert_key) filter (where not c.reviewed)                         as unreviewed,
          count(c.alert_key) filter (where not c.reviewed and c.severity = 'alta') as unreviewed_high
        from unnest(v_kinds) as k(kind)
        left join completa c
          on c.kind = k.kind
         and (p_subject_id is null or c.subject_id = p_subject_id
              or c.user_id = p_subject_id or c.merchant_id = p_subject_id)
        group by k.kind
      ) x
    ),
    'total',     (select count(*) from pedida),
    'truncated', (select count(*) from pedida) > v_limit,
    -- Sin revisar primero, las graves antes, y la más reciente arriba.
    'rows', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.reviewed, s.severity = 'media', s.first_seen_at desc nulls last, s.alert_key)
      from (
        select * from pedida
        order by reviewed, severity = 'media', first_seen_at desc nulls last, alert_key
        limit v_limit
      ) s
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$function$
;

create or replace function public.helios_cancel_messages_of_reverted_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.outbound_messages o
     set status = 'cancelado'
   where o.status = 'pendiente'
     and o.profile_id = new.user_id
     and (
       o.charge_id = new.id
       or (
         o.installment_due_date is not null
         and not exists (
           select 1
             from public.installments i
            where i.user_id = new.user_id
              and i.due_date = o.installment_due_date
              and i.status = 'pending'
         )
       )
     );
  return new;
end;
$$;

revoke all on function public.helios_cancel_messages_of_reverted_charge() from public, anon, authenticated;

drop trigger if exists charges_cancel_messages_on_revert on public.charges;
create trigger charges_cancel_messages_on_revert
  after update of status on public.charges
  for each row
  when (new.status in ('reverted', 'voided') and old.status is distinct from new.status and new.user_id is not null)
  execute function public.helios_cancel_messages_of_reverted_charge();
