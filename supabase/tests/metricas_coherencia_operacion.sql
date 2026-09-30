-- ============================================================================
-- Batería de coherencia de la operación (dev) — AUD-OPERACION
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok.
--   O1  Inicio › Vencido: overdue_users de la semana en curso = usuarios con
--       cuota vencida en metricas.cuotas (20260927690000).
--   O2  Inicio › Vencido: overdue_debt_usd = Σ payable vencido canónico, y
--       su desglose suma.
--   O3  Directorio › Usuarios: vencido, deuda viva, cobrado a tiempo y
--       consumos de cada usuario = metricas.cuotas (20260927691000).
--   O4  Directorio › Usuarios: el desglose suma la deuda en cada fila.
--   O5  Por cobrar: Plazo vigente + Vence hoy + Plazo vencido = Todos.
--   O6  Por cobrar: lo vencido de la cola = vencido canónico + perdido
--       (la cola lleva lo perdido; Inicio y Mora no).
--   O7  Consumos: buscar por el teléfono de quien pagó su parte de un grupo
--       encuentra ese consumo (20260927692000).
-- Solo SELECT; se hace pasar por un admin activo.
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_operacion.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
w as materialized (select public.admin_weekly_summary(2) -> 'rows' -> -1 as s),
d as materialized (select * from public.admin_user_directory(p_limit => 200)),
c as materialized (
  select user_id,
         coalesce(sum(payable_usd) filter (where estado_hoy in ('vencida','por_vencer')), 0) as viva,
         coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0) as vencido,
         count(*) filter (where plazo_cerrado and estado_hoy = 'a_tiempo') as a_tiempo,
         count(*) filter (where plazo_cerrado) as cerradas,
         count(distinct charge_id) as consumos
  from metricas.cuotas group by 1
),
col as materialized (select r from jsonb_array_elements(public.admin_collections(7) -> 'rows') r),
grupo as materialized (
  -- Un usuario con cuota en un consumo de grupo que abrió otro.
  select i.charge_id, p.phone_e164
  from public.installments i
  join public.charges ch on ch.id = i.charge_id and ch.status = 'confirmed' and ch.group_id is not null
  join public.profiles p on p.id = i.user_id and p.phone_e164 is not null
  where i.user_id is distinct from ch.user_id and not i.is_test
  limit 1
)
select 'O1' as comprobacion,
       (select count(distinct user_id) from metricas.cuotas where estado_hoy = 'vencida')::text as esperado,
       (select s ->> 'overdue_users' from w) as obtenido,
       (select count(distinct user_id) from metricas.cuotas where estado_hoy = 'vencida')::text = (select s ->> 'overdue_users' from w) as ok
union all
select 'O2',
       (select coalesce(sum(payable_usd), 0) from metricas.cuotas where estado_hoy = 'vencida')::text,
       (select s ->> 'overdue_debt_usd' from w),
       (select coalesce(sum(payable_usd), 0) from metricas.cuotas where estado_hoy = 'vencida') = (select (s ->> 'overdue_debt_usd')::numeric from w)
       and (select (s ->> 'overdue_financed_usd')::numeric + (s ->> 'overdue_fee_usd')::numeric = (s ->> 'overdue_debt_usd')::numeric from w)
union all
select 'O3', '0 filas que no cuadran',
       (select count(*) from d left join c on c.user_id = d.user_id
         where not d.is_test and (coalesce(c.vencido, 0) <> d.overdue_usd or coalesce(c.viva, 0) <> d.open_debt_usd
            or coalesce(c.a_tiempo, 0) <> d.on_time_paid or coalesce(c.cerradas, 0) <> d.on_time_total
            or coalesce(c.consumos, 0) <> d.charge_count))::text || ' filas',
       (select count(*) from d left join c on c.user_id = d.user_id
         where not d.is_test and (coalesce(c.vencido, 0) <> d.overdue_usd or coalesce(c.viva, 0) <> d.open_debt_usd
            or coalesce(c.a_tiempo, 0) <> d.on_time_paid or coalesce(c.cerradas, 0) <> d.on_time_total
            or coalesce(c.consumos, 0) <> d.charge_count)) = 0
union all
select 'O4', '0 filas', (select count(*) from d where overdue_financed_usd + overdue_fee_usd <> overdue_usd
                                                    or open_debt_financed_usd + open_debt_fee_usd <> open_debt_usd)::text || ' filas',
       (select count(*) from d where overdue_financed_usd + overdue_fee_usd <> overdue_usd
                                   or open_debt_financed_usd + open_debt_fee_usd <> open_debt_usd) = 0
union all
select 'O5', (select count(*) from col)::text,
       (select count(*) filter (where r ->> 'bucket' = 'por_vencer') + count(*) filter (where r ->> 'bucket' = 'vence_hoy')
             + count(*) filter (where (r ->> 'overdue_usd')::numeric > 0) from col)::text,
       (select count(*) from col) = (select count(*) filter (where r ->> 'bucket' = 'por_vencer') + count(*) filter (where r ->> 'bucket' = 'vence_hoy')
             + count(*) filter (where (r ->> 'overdue_usd')::numeric > 0) from col)
union all
select 'O6',
       (select coalesce(sum(payable_usd), 0) from metricas.cuotas where estado_hoy in ('vencida', 'perdida'))::text,
       (select coalesce(sum((r ->> 'overdue_usd')::numeric), 0) from col)::text,
       (select coalesce(sum(payable_usd), 0) from metricas.cuotas where estado_hoy in ('vencida', 'perdida'))
         = (select coalesce(sum((r ->> 'overdue_usd')::numeric), 0) from col)
union all
select 'O7', 'lo encuentra',
       case when exists (select 1 from grupo g, public.admin_charges(g.phone_e164, null, null, null, null, 500) a where a.charge_id = g.charge_id)
            then 'lo encuentra' else 'no' end,
       not exists (select 1 from grupo)
       or exists (select 1 from grupo g, public.admin_charges(g.phone_e164, null, null, null, null, 500) a where a.charge_id = g.charge_id);
