-- ============================================================================
-- Batería de coherencia de las fichas (dev) — FICHAS (aplicar AUD-OPERACION)
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok.
--   F1  C5 · Ficha de usuario › «Deuda en cuotas»: debt.open_usd = vencido +
--       por vencer de metricas.cuotas, sin lo perdido (20260927696000).
--   F2  C5 · debt.overdue_usd = vencido canónico y debt.days_overdue = el
--       mayor atraso de sus cuotas vencidas.
--   F3  C5 · debt.written_off_usd = lo perdido canónico, y cada cuota perdida
--       trae written_off_at.
--   F4  C2 · debt.paid_financed_usd = consumo (sin fee) de sus cuotas cobradas
--       = level_standing().paid_usd, la cifra del motor de niveles.
--   F5  C3 · installments[].paid_day = metricas.cuotas.pagada_dia, cuota a cuota.
--   F6  C3 · installments[].on_time = (estado_hoy = 'a_tiempo'), cuota a cuota.
--   F7  C8 · payments[]: amount_usd = cuotas_payable_usd + late_fees_usd y
--       cuotas_fee_usd = cuotas_payable_usd − cuotas_financed_usd.
-- Cada comprobación recorre todos los usuarios de dev que no son de prueba y
-- tienen cuotas; «obtenido» es el número de usuarios (o cuotas, o pagos) que
-- no cuadran.
-- Solo SELECT; se hace pasar por un admin activo.
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_fichas.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
u as materialized (
  select p.id as user_id, public.admin_user_detail(p.id) as j
  from public.profiles p
  where not p.is_test
    and exists (select 1 from metricas.cuotas q where q.user_id = p.id)
),
c as materialized (
  select user_id,
         coalesce(sum(payable_usd) filter (where estado_hoy in ('vencida', 'por_vencer')), 0) as viva,
         coalesce(sum(payable_usd) filter (where estado_hoy = 'vencida'), 0) as vencido,
         coalesce(max(dias_atraso) filter (where estado_hoy = 'vencida'), 0) as dias,
         coalesce(sum(payable_usd) filter (where estado_hoy = 'perdida'), 0) as perdido,
         coalesce(sum(financed_usd) filter (where status = 'paid'), 0) as pagado_financed
  from metricas.cuotas group by 1
),
cuotas as materialized (
  select u.user_id, (x ->> 'id')::uuid as installment_id,
         (x ->> 'paid_day')::date as paid_day,
         (x ->> 'on_time')::boolean as on_time,
         x ->> 'written_off_at' as written_off_at
  from u, jsonb_array_elements(u.j -> 'installments') x
),
pagos as materialized (
  select x from u, jsonb_array_elements(u.j -> 'payments') x
),
niveles as materialized (
  select u.user_id, (public.level_standing(u.user_id) ->> 'paid_usd')::numeric as motor
  from u
),
f as (
  select 'F1' as comprobacion,
         '0 usuarios' as esperado,
         (select count(*) from u join c using (user_id) where (u.j -> 'debt' ->> 'open_usd')::numeric <> c.viva) as malos
  union all
  select 'F2', '0 usuarios',
         (select count(*) from u join c using (user_id)
           where (u.j -> 'debt' ->> 'overdue_usd')::numeric <> c.vencido
              or (u.j -> 'debt' ->> 'days_overdue')::int <> c.dias)
  union all
  select 'F3', '0 usuarios y 0 cuotas',
         (select count(*) from u join c using (user_id)
           where coalesce((u.j -> 'debt' ->> 'written_off_usd')::numeric, -1) <> c.perdido)
         + (select count(*) from metricas.cuotas q
             left join cuotas k on k.installment_id = q.installment_id
            where q.estado_hoy = 'perdida' and k.written_off_at is null)
  union all
  select 'F4', '0 usuarios',
         (select count(*) from u join c using (user_id) join niveles n using (user_id)
           where coalesce((u.j -> 'debt' ->> 'paid_financed_usd')::numeric, -1) <> c.pagado_financed
              or coalesce((u.j -> 'debt' ->> 'paid_financed_usd')::numeric, -1) <> n.motor)
  union all
  select 'F5', '0 cuotas',
         (select count(*) from metricas.cuotas q join cuotas k on k.installment_id = q.installment_id
           where q.status = 'paid' and k.paid_day is distinct from q.pagada_dia)
  union all
  select 'F6', '0 cuotas',
         (select count(*) from metricas.cuotas q join cuotas k on k.installment_id = q.installment_id
           where q.status = 'paid' and k.on_time is distinct from (q.estado_hoy = 'a_tiempo'))
  union all
  select 'F7', '0 pagos',
         (select count(*) from pagos
           where (x ->> 'cuotas_payable_usd') is null
              or (x ->> 'amount_usd')::numeric
                 <> (x ->> 'cuotas_payable_usd')::numeric + (x ->> 'late_fees_usd')::numeric
              or (x ->> 'cuotas_fee_usd')::numeric
                 <> (x ->> 'cuotas_payable_usd')::numeric - (x ->> 'cuotas_financed_usd')::numeric)
)
select comprobacion, esperado,
       malos::text || ' que no cuadran (de ' || (select count(*) from u) || ' usuarios)' as obtenido,
       malos = 0 as ok
from f
order by comprobacion;
