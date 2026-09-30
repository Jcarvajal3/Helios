-- ============================================================================
-- Prueba de humo de Métricas › Cobranza y riesgo (COBRANZA)
--
-- Se hace pasar por un admin activo y cambia el rol a `authenticated`, como
-- llega el panel, dentro de begin/rollback. Comprueba:
--   * que las dos RPC nuevas (`admin_metricas_cobranza`,
--     `admin_deudores_por_perfil`) rebotan con 42501 a quien no es del equipo;
--   * que contestan con sus claves, con y sin local;
--   * que todo objeto con `payable_usd` trae `financed_usd` y `fee_usd`, y que
--     fee = payable − financed (la regla del servicio);
--   * que las RPC de siempre siguen contestando llamadas SIN los parámetros
--     nuevos (como Inicio, Por cobrar y el asistente) y CON ellos;
--   * que `authenticated` no ve el esquema `metricas`.
-- Una fila por prueba: prueba, ok, detalle. Solo lectura.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_cobranza.sql
--
-- La coherencia de las cifras está en metricas_coherencia_cobranza.sql.
-- ============================================================================

begin;

-- @ayudas
-- Helios: la base nace sin equipo; la suite crea su propio admin activo.
select pg_temp.prueba_admin() is not null as admin_de_prueba;

-- El local con más consumo y un lunes de hace dos semanas, antes de perder el
-- acceso a `metricas`.
create temp table _datos on commit drop as
select (select k.merchant_id from metricas.consumos k
        group by k.merchant_id order by sum(k.financed_usd) desc limit 1) as local,
       metricas.lunes(metricas.hoy()) - 14                                  as lunes;
grant select on _datos to authenticated;

-- Alguien que no es del equipo: tiene que rebotar con 42501.
create temp table _rebote (rpc text, codigo text) on commit drop;
grant select, insert on _rebote to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
begin
  begin
    perform public.admin_metricas_cobranza(null, null);
    insert into _rebote values ('admin_metricas_cobranza', 'sin error');
  exception when others then
    insert into _rebote values ('admin_metricas_cobranza', sqlstate);
  end;
  begin
    perform public.admin_deudores_por_perfil(null);
    insert into _rebote values ('admin_deudores_por_perfil', 'sin error');
  exception when others then
    insert into _rebote values ('admin_deudores_por_perfil', sqlstate);
  end;
end;
$$;

-- Ahora, un admin activo (con aal2, por si el segundo factor está exigido).
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

create temp table _r on commit drop as
select
  public.admin_metricas_cobranza(null, null)                                         as sem,
  public.admin_metricas_cobranza((select lunes from _datos), (select local from _datos)) as sem_local,
  public.admin_deudores_por_perfil(null)                                             as deud,
  public.admin_deudores_por_perfil((select local from _datos))                       as deud_local,
  public.admin_collections(7)                                                        as cola,
  public.admin_collections(7, (select local from _datos), (select lunes from _datos)) as cola_filtrada,
  public.admin_overview(30)                                                          as ov,
  public.admin_overview(30, (select local from _datos))                              as ov_local,
  public.admin_collection_flow(8)                                                    as flujo,
  public.admin_collection_flow(1, (select local from _datos), metricas_hoy.d)        as flujo_hoy,
  public.admin_first_payment_default(6, 'mes')                                       as fpd,
  public.admin_first_payment_default(3, 'semana', (select local from _datos), (select lunes from _datos) + 6) as fpd_sem,
  public.admin_first_payment_default(3, 'semana', (select local from _datos), (select lunes from _datos) + 6, 2) as fpd_sem_2,
  public.admin_first_payment_default(p_months => 6, p_dim => 'local', p_cuota => 2)  as fpd_local_2,
  public.admin_on_time_collection(30)                                                as ontime,
  public.admin_on_time_collection(7, (select local from _datos), (select lunes from _datos) + 6) as ontime_sem,
  public.admin_credit_utilization()                                                  as cupo,
  public.admin_credit_utilization((select local from _datos))                        as cupo_local,
  public.admin_collection_recovered()                                                as recup,
  public.admin_collection_recovered((select lunes from _datos), (select lunes from _datos) + 6, (select local from _datos)) as recup_local,
  public.admin_contact_effectiveness()                                               as efec,
  public.admin_collection_promises()                                                 as prom,
  public.admin_credit_cohorts(6)                                                     as cosechas,
  public.admin_cohort_curves(6, (select local from _datos))                          as curvas,
  (select count(*) from public.admin_due_vs_collected(30))                           as dias_30,
  (select count(*) from public.admin_due_vs_collected(7, (select local from _datos), (select lunes from _datos) + 6)) as dias_sem,
  (select count(*) from public.admin_merchant_risk(90))                              as locales,
  (select count(*) from public.admin_merchant_risk(90, (select local from _datos)))  as un_local,
  public.admin_weekly_summary(4)                                                     as semanal
from (select public.helios_business_date(now()) as d) metricas_hoy;

-- Una cuota que no existe rebota con 22023, no con una lista vacía.
do $$
begin
  perform public.admin_first_payment_default(6, 'mes', null, null, 0);
  insert into _rebote values ('admin_first_payment_default cuota 0', 'sin error');
exception when others then
  insert into _rebote values ('admin_first_payment_default cuota 0', sqlstate);
end;
$$;

with
-- Todos los objetos con payable_usd de las respuestas nuevas.
pagables as (
  select o
  from _r, lateral (values (sem), (sem_local), (deud), (deud_local)) v(j),
       lateral jsonb_path_query(v.j, 'strict $.**') o
  where jsonb_typeof(o) = 'object' and o ? 'payable_usd'
),
pruebas(orden, prueba, ok, detalle) as (
  select 1, 'admin_metricas_cobranza rebota con 42501 a quien no es del equipo',
         (select codigo from _rebote where rpc = 'admin_metricas_cobranza') = '42501',
         (select codigo from _rebote where rpc = 'admin_metricas_cobranza')
  union all
  select 2, 'admin_deudores_por_perfil rebota con 42501 a quien no es del equipo',
         (select codigo from _rebote where rpc = 'admin_deudores_por_perfil') = '42501',
         (select codigo from _rebote where rpc = 'admin_deudores_por_perfil')
  union all
  select 3, 'authenticated no ve el esquema metricas',
         not has_schema_privilege('authenticated', 'metricas', 'usage'), current_user::text
  union all
  select 4, 'admin_metricas_cobranza trae todas sus claves',
         (select sem ?& array['semana', 'hoy', 'corte', 'cartera', 'cartera_anterior', 'tramos', 'impago', 'hoy_vencido'] from _r),
         (select array_to_string(array(select jsonb_object_keys(sem)), ',') from _r)
  union all
  select 5, 'con semana pasada, el corte es su domingo',
         (select (sem_local->>'corte')::date = (select lunes from _datos) + 6 from _r),
         (select sem_local->>'corte' from _r)
  union all
  select 6, 'admin_deudores_por_perfil trae los siete perfiles',
         (select jsonb_array_length(deud->'perfiles') = 7 from _r),
         (select string_agg(p->>'perfil' || '=' || (p->>'personas'), ', ')
            from _r, jsonb_array_elements(deud->'perfiles') p)
  union all
  select 7, 'todo payable_usd de las RPC nuevas trae financed_usd y fee_usd',
         (select coalesce(bool_and(o ? 'financed_usd' and o ? 'fee_usd'), true) from pagables),
         (select count(*)::text || ' objetos' from pagables)
  union all
  select 8, 'y fee = payable − financed',
         (select coalesce(bool_and(abs((o->>'payable_usd')::numeric - (o->>'financed_usd')::numeric
                                       - (o->>'fee_usd')::numeric) < 0.005), true) from pagables),
         null
  union all
  select 9, 'admin_collections sin parámetros nuevos: filas con perfil, prioridad, orden y motivo',
         (select coalesce(bool_and(f ?& array['perfil', 'prioridad', 'orden', 'motivo']), true)
            from _r, jsonb_array_elements(cola->'rows') f),
         (select jsonb_array_length(cola->'rows')::text || ' filas' from _r)
  union all
  select 10, 'admin_collections con local y cohorte: una parte de la cola',
         (select jsonb_array_length(cola_filtrada->'rows') <= jsonb_array_length(cola->'rows') from _r),
         (select jsonb_array_length(cola_filtrada->'rows')::text || ' de ' || jsonb_array_length(cola->'rows') from _r)
  union all
  select 11, 'admin_overview sin local: users, kyc y caja; con local, nulos',
         (select jsonb_typeof(ov->'users') = 'object' and jsonb_typeof(ov->'cash') = 'object'
             and ov_local->'users' = 'null'::jsonb and ov_local->'kyc' = 'null'::jsonb
             and ov_local->'cash' = 'null'::jsonb from _r),
         null
  union all
  select 12, 'admin_collection_flow(8) sigue dando 8 semanas de lunes',
         (select jsonb_array_length(flujo->'weeks') = 8
             and bool_and(extract(isodow from (w->>'cut_date')::date) = 1)
            from _r, jsonb_array_elements(flujo->'weeks') w group by flujo),
         (select string_agg(w->>'cut_date', ',') from _r, jsonb_array_elements(flujo->'weeks') w)
  union all
  select 13, 'admin_collection_flow hasta hoy: la última semana es la en curso',
         (select (flujo_hoy->'weeks'->-1->>'cut_date')::date = public.helios_business_date(now()) from _r),
         (select flujo_hoy->'weeks'->-1->>'cut_date' from _r)
  union all
  select 14, 'admin_first_payment_default por mes, como siempre, y por semana',
         (select fpd->>'dim' = 'mes' and fpd_sem->>'dim' = 'semana'
             and coalesce(bool_and(extract(isodow from (r->>'key')::date) = 1), true)
            from _r left join lateral jsonb_array_elements(fpd_sem->'rows') r on true group by fpd, fpd_sem),
         null
  union all
  select 19, 'admin_first_payment_default: sin p_cuota, la cuota 1; con p_cuota 2, la 2 (misma forma)',
         (select fpd->>'cuota' = '1' and fpd_sem_2->>'cuota' = '2' and fpd_local_2->>'cuota' = '2'
             and fpd_sem_2->>'dim' = 'semana' and fpd_local_2->>'dim' = 'local'
             and (select array_agg(k order by k) from jsonb_object_keys(fpd->'total') k)
               = (select array_agg(k order by k) from jsonb_object_keys(fpd_sem_2->'total') k)
            from _r),
         (select format('cuota 2 por semana: %s filas · por local: %s filas',
                        jsonb_array_length(fpd_sem_2->'rows'), jsonb_array_length(fpd_local_2->'rows')) from _r)
  union all
  select 20, 'admin_first_payment_default con una cuota que no existe rebota con 22023',
         (select codigo from _rebote where rpc = 'admin_first_payment_default cuota 0') = '22023',
         (select codigo from _rebote where rpc = 'admin_first_payment_default cuota 0')
  union all
  select 21, 'admin_first_payment_default: previous_paid solo con la cuota 2, con las cifras de siempre',
         (select fpd->'total'->'previous_paid' = 'null'::jsonb
             and fpd_local_2->'total'->'previous_paid' ?& array['matured_count', 'defaulted_count', 'defaulted_pct',
                   'matured_financed_usd', 'defaulted_financed_usd', 'matured_30_count', 'defaulted_30_count', 'defaulted_30_pct']
             and coalesce((select bool_and(jsonb_typeof(r->'previous_paid') = 'object')
                             from jsonb_array_elements(fpd_sem_2->'rows') r), true)
            from _r),
         (select format('cuota 2: %s de %s de quien pagó la 1',
                        fpd_local_2->'total'->'previous_paid'->>'defaulted_count',
                        fpd_local_2->'total'->'previous_paid'->>'matured_count') from _r)
  union all
  select 22, 'admin_weekly_summary: la deuda viva y la vencida traen su desglose',
         (select bool_and(r ?& array['overdue_financed_usd', 'overdue_fee_usd', 'open_financed_usd', 'open_fee_usd']
                          and abs((r->>'overdue_debt_usd')::numeric - (r->>'overdue_financed_usd')::numeric
                                  - (r->>'overdue_fee_usd')::numeric) < 0.005
                          and abs((r->>'open_debt_usd')::numeric - (r->>'open_financed_usd')::numeric
                                  - (r->>'open_fee_usd')::numeric) < 0.005)
            from _r, jsonb_array_elements(semanal->'rows') r),
         (select jsonb_array_length(semanal->'rows')::text || ' semanas' from _r)
  union all
  select 15, 'admin_on_time_collection trae el total y el tramo juzgado',
         (select ontime ? 'total' and ontime ? 'from' and ontime_sem ? 'total' from _r), null
  union all
  select 16, 'admin_credit_utilization con local mira a la gente del local',
         (select cupo->>'poblacion' = 'todos' and cupo_local->>'poblacion' = 'gente_del_local' from _r), null
  union all
  select 17, 'admin_collection_recovered trae el desglose',
         (select recup->'recovered' ?& array['usd', 'financed_usd', 'fee_usd']
             and recup_local->'recovered' ?& array['usd', 'financed_usd', 'fee_usd'] from _r), null
  union all
  select 18, 'las demás contestan sin los parámetros nuevos',
         (select efec ? 'total' and prom ? 'summary' and cosechas ? 'rows' and curvas ? 'rows'
             and dias_30 = 30 and dias_sem = 7 and locales >= un_local and un_local = 1 from _r),
         (select format('días %s/%s · locales %s/%s', dias_30, dias_sem, locales, un_local) from _r)
)
select prueba, ok, detalle
from pruebas
order by orden;

rollback;
