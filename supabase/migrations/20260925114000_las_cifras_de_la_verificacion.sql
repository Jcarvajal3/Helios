-- ============================================================================
-- Ronda — Las cifras de la verificación de identidad
--
-- `admin_overview` da el embudo de KYC de toda la historia y la cola manual de
-- ahora. No contesta lo que Riesgo pregunta de un periodo: cuántas se
-- enviaron, cuántas salieron bien, por qué se rechazaron las demás y cuánto
-- esperó la gente hasta saberlo.
--
-- ── El periodo ──────────────────────────────────────────────────────────────
-- Por el día operativo en que se abrió el expediente, con la misma ventana
-- que Crecimiento (`helios_growth_window`: sin fechas, los últimos 30 días;
-- nunca más allá de hoy; como mucho 366). Así «verificadas» cuadra con la
-- pantalla de Crecimiento.
--
-- ── La espera ───────────────────────────────────────────────────────────────
-- La decisión es la última vez que el expediente ENTRÓ en su estado final
-- (`kyc.decision_log`), no la primera: un aprobado que el usuario mandó a
-- revisión y un revisor volvió a aprobar esperó hasta la segunda. Si el log
-- no lo tiene, `reviewed_at`. La espera total cuenta desde que se abre el
-- expediente, así que incluye lo que la persona tarda en hacer la
-- verificación; la de revisión manual cuenta solo desde que entró en la cola.
-- ============================================================================

create or replace function public.admin_kyc_stats(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := public.helios_business_date(now());
  v_from  date;
  v_to    date;
  v_days  integer;
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from public.helios_growth_window(p_from, p_to) w;

  with
  expediente as (
    select
      kv.id,
      kv.user_id,
      kv.status::text                  as status,
      kv.rejection_reason::text        as motivo,
      kv.created_at,
      case when kv.status in ('approved', 'rejected')
        then coalesce(lg.decidida, kv.reviewed_at) end as decided_at,
      lg.a_revision
    from kyc.verifications kv
    join public.profiles p on p.id = kv.user_id and not p.is_test
    left join lateral (
      select
        max(l.created_at) filter (
          where l.to_status = kv.status
            and l.from_status is distinct from l.to_status)       as decidida,
        max(l.created_at) filter (
          where l.to_status = 'manual_review'
            and l.from_status is distinct from l.to_status)       as a_revision
      from kyc.decision_log l
      where l.verification_id = kv.id
    ) lg on true
    where public.helios_business_date(kv.created_at) between v_from and v_to
  ),
  espera as (
    select
      e.*,
      extract(epoch from (e.decided_at - e.created_at))            as total_s,
      case when e.a_revision is not null and e.a_revision <= e.decided_at
        then extract(epoch from (e.decided_at - e.a_revision)) end as manual_s
    from expediente e
  )
  select jsonb_build_object(
    'business_date',     v_today,
    'from',              v_from,
    'to',                v_to,
    'window_days',       v_days,
    'submitted',         count(*),
    'users',             count(distinct s.user_id),
    'approved',          count(*) filter (where s.status = 'approved'),
    'rejected',          count(*) filter (where s.status = 'rejected'),
    'pending',           count(*) filter (where s.status in ('pending', 'processing', 'manual_review')),
    'pending_detail', jsonb_build_object(
      'pending',       count(*) filter (where s.status = 'pending'),
      'processing',    count(*) filter (where s.status = 'processing'),
      'manual_review', count(*) filter (where s.status = 'manual_review')
    ),
    -- Sobre lo decidido: lo que sigue abierto no es ni un sí ni un no.
    'approval_rate_pct', round(100.0 * count(*) filter (where s.status = 'approved')
                               / nullif(count(*) filter (where s.status in ('approved', 'rejected')), 0), 1),
    'rejection_reasons', coalesce((
      select jsonb_agg(jsonb_build_object('reason', r.reason, 'count', r.n) order by r.n desc, r.reason)
      from (
        select coalesce(x.motivo, 'sin_motivo') as reason, count(*) as n
        from espera x
        where x.status = 'rejected'
        group by 1
      ) r
    ), '[]'::jsonb),
    'decision_wait', jsonb_build_object(
      'count',          count(s.total_s),
      'median_seconds', round(percentile_cont(0.5) within group (order by s.total_s)),
      'p90_seconds',    round(percentile_cont(0.9) within group (order by s.total_s))
    ),
    'manual_review_wait', jsonb_build_object(
      'count',          count(s.manual_s),
      'median_seconds', round(percentile_cont(0.5) within group (order by s.manual_s)),
      'p90_seconds',    round(percentile_cont(0.9) within group (order by s.manual_s))
    )
  )
  into v_out
  from espera s;

  return v_out;
end;
$$;

comment on function public.admin_kyc_stats(date, date) is
  'Verificaciones abiertas en un periodo (dia operativo): enviadas, aprobadas, rechazadas, pendientes, tasa de aprobacion, motivos de rechazo y espera hasta la decision (mediana y p90). Sin cuentas de prueba.';

revoke all on function public.admin_kyc_stats(date, date) from public, anon;
grant execute on function public.admin_kyc_stats(date, date) to authenticated;
