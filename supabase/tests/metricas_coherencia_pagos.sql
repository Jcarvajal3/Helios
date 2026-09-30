-- ============================================================================
-- Batería de coherencia de Pagos (dev) — PAGOS, aplicando AUD-OPERACION
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok.
--   PG1  Pagos reportados: ningún pago da colisiones negativas (antes, los
--        rechazados daban -1) (20260927697000).
--   PG2  Pagos reportados: reference_collisions = recuento independiente de
--        OTROS reportes no rechazados con el mismo banco y referencia.
--   PG3  Cada cuota de un pago: financed_usd + fee_usd = quoted_usd.
--   PG4  Cada pago: installments_financed_usd + installments_fee_usd =
--        installments_usd, y el facturado = Σ facturado de sus cuotas.
--   PG5  Promesas: «Vencido hoy» de cada fila = Σ payable 'vencida' de
--        metricas.cuotas de ese usuario, y fee = vencido − facturado
--        (20260927697100).
--   PG6  Promesas: una cuota vencida que se da por perdida DEJA de contar
--        en «Vencido hoy» (se ensaya dentro de la transacción).
--   PG7  Abonos sin dueño: el euro sale con la tasa BCV del EURO del día;
--        antes de la serie del euro, sin tasa (20260927697200). Se ensaya
--        con tres abonos de mentira dentro de la transacción.
-- Todo dentro de begin … rollback; no deja nada escrito.
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_pagos.sql
-- ============================================================================

begin;

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

-- ── Ensayo PG6: una cuota vencida de un usuario con promesa, dada por perdida.
select set_config('pagos.perdida', coalesce((
  select q.installment_id::text
  from public.collection_contacts c
  join metricas.cuotas q on q.user_id = c.user_id and q.estado_hoy = 'vencida'
  join public.profiles p on p.id = c.user_id and not p.is_test
  where c.promise_date is not null
    and c.promise_date >= metricas.hoy() - 30
  order by q.payable_usd desc
  limit 1), ''), true) is not null as cuota_elegida;

select set_config('pagos.perdida_user', coalesce((
  select user_id::text from public.installments
  where id::text = current_setting('pagos.perdida')), ''), true) is not null as usuario_elegido;

update public.installments
set written_off_at = now()
where id::text = current_setting('pagos.perdida');

-- ── Ensayo PG7: tres abonos sin dueño de mentira.
insert into public.bank_statement_lines (bank, moved_on, reference, amount_ves, fingerprint, imported_by)
select 'PRUEBA-PAGOS', d::date, 'PAGOSPG7' || to_char(d::date, 'MMDD'), 10000,
       'pagos-pg7-' || gen_random_uuid(),
       (select user_id from public.platform_admins where is_active limit 1)
from unnest(array['2026-09-05', '2026-09-09', '2026-09-15']) d;

with
reportes as materialized (
  select r.id, r.status::text as status, public.admin_payment_report(r.id) as item
  from public.payment_reports r
  join public.profiles p on p.id = r.user_id and not p.is_test
),
independiente as materialized (
  select r.id,
         (select count(*) from public.payment_reports r2
          where r2.bank = r.bank and r2.reference = r.reference and r2.reference is not null
            and r2.status <> 'rejected' and r2.id <> r.id) as colisiones
  from public.payment_reports r
),
cuotas as materialized (
  select rp.id, cu
  from reportes rp,
       jsonb_array_elements(rp.item -> 'purchases') pu,
       jsonb_array_elements(pu -> 'installments') cu
),
prom as materialized (select e from jsonb_array_elements(public.admin_collection_promises() -> 'rows') e),
canon as materialized (
  select user_id, sum(payable_usd) as vencido, sum(financed_usd) as facturado
  from metricas.cuotas where estado_hoy = 'vencida' group by 1
),
regla_vieja as materialized (
  -- La suma que hacía la función antes: pendientes con el día pasado, sin
  -- mirar written_off_at.
  select coalesce(sum(i.amount_usd), 0) as vencido
  from public.installments i
  where i.user_id::text = current_setting('pagos.perdida_user')
    and i.status = 'pending' and not i.is_test and i.due_date < metricas.hoy()
),
abonos as materialized (
  select e from jsonb_array_elements(public.admin_unmatched_deposits(500)) e
  where e ->> 'bank' = 'PRUEBA-PAGOS'
),
tasa_euro as materialized (
  select d::date as dia,
         (select rate from public.exchange_rates
          where source = 'BCV' and effective_date <= d::date
          order by effective_date desc limit 1) as rate
  from unnest(array['2026-09-05', '2026-09-09', '2026-09-15']) d
)
select 'PG1' as comprobacion, '0' as esperado,
       (select count(*) from reportes where (item ->> 'reference_collisions')::int < 0)::text as obtenido,
       (select count(*) from reportes where (item ->> 'reference_collisions')::int < 0) = 0 as ok
union all
select 'PG2', '0 diferencias en ' || (select count(*) from reportes),
       (select count(*) from reportes rp join independiente i using (id)
        where (rp.item ->> 'reference_collisions')::int <> i.colisiones)::text || ' diferencias',
       (select count(*) from reportes rp join independiente i using (id)
        where (rp.item ->> 'reference_collisions')::int <> i.colisiones) = 0
union all
select 'PG3', '0 cuotas descuadradas de ' || (select count(*) from cuotas),
       (select count(*) from cuotas
        where (cu ->> 'financed_usd') is null
           or abs((cu ->> 'financed_usd')::numeric + (cu ->> 'fee_usd')::numeric - (cu ->> 'quoted_usd')::numeric) > 0.005)::text,
       (select count(*) from cuotas
        where (cu ->> 'financed_usd') is null
           or abs((cu ->> 'financed_usd')::numeric + (cu ->> 'fee_usd')::numeric - (cu ->> 'quoted_usd')::numeric) > 0.005) = 0
union all
select 'PG4', '0 pagos descuadrados de ' || (select count(*) from reportes),
       (select count(*) from reportes rp
        where abs((item ->> 'installments_financed_usd')::numeric + (item ->> 'installments_fee_usd')::numeric
                  - (item ->> 'installments_usd')::numeric) > 0.005
           or abs((item ->> 'installments_financed_usd')::numeric
                  - coalesce((select sum((c.cu ->> 'financed_usd')::numeric) from cuotas c where c.id = rp.id), 0)) > 0.005)::text,
       (select count(*) from reportes rp
        where abs((item ->> 'installments_financed_usd')::numeric + (item ->> 'installments_fee_usd')::numeric
                  - (item ->> 'installments_usd')::numeric) > 0.005
           or abs((item ->> 'installments_financed_usd')::numeric
                  - coalesce((select sum((c.cu ->> 'financed_usd')::numeric) from cuotas c where c.id = rp.id), 0)) > 0.005) = 0
union all
select 'PG5', '0 filas distintas de ' || (select count(*) from prom),
       (select count(*) from prom p left join canon c on c.user_id = (p.e ->> 'user_id')::uuid
        where abs((p.e ->> 'overdue_usd')::numeric - coalesce(c.vencido, 0)) > 0.005
           or abs((p.e ->> 'overdue_financed_usd')::numeric - coalesce(c.facturado, 0)) > 0.005
           or abs((p.e ->> 'overdue_fee_usd')::numeric
                  - ((p.e ->> 'overdue_usd')::numeric - (p.e ->> 'overdue_financed_usd')::numeric)) > 0.005)::text,
       (select count(*) from prom p left join canon c on c.user_id = (p.e ->> 'user_id')::uuid
        where abs((p.e ->> 'overdue_usd')::numeric - coalesce(c.vencido, 0)) > 0.005
           or abs((p.e ->> 'overdue_financed_usd')::numeric - coalesce(c.facturado, 0)) > 0.005
           or abs((p.e ->> 'overdue_fee_usd')::numeric
                  - ((p.e ->> 'overdue_usd')::numeric - (p.e ->> 'overdue_financed_usd')::numeric)) > 0.005) = 0
union all
select 'PG6',
       'vencido canónico ' || coalesce((select vencido from canon where user_id::text = current_setting('pagos.perdida_user')), 0)::text
         || ' < regla vieja ' || (select vencido from regla_vieja)::text,
       coalesce((select max((e ->> 'overdue_usd')::numeric) from prom
                 where e ->> 'user_id' = current_setting('pagos.perdida_user')), -1)::text,
       current_setting('pagos.perdida') <> ''
       and (select max((e ->> 'overdue_usd')::numeric) from prom
            where e ->> 'user_id' = current_setting('pagos.perdida_user'))
           = coalesce((select vencido from canon where user_id::text = current_setting('pagos.perdida_user')), 0)
       and (select vencido from regla_vieja)
           > coalesce((select vencido from canon where user_id::text = current_setting('pagos.perdida_user')), 0)
union all
select 'PG7',
       string_agg(t.dia || '=' || coalesce(round(10000 / t.rate, 2)::text, 'null'), ' ' order by t.dia),
       string_agg(t.dia || '=' || coalesce(a.e ->> 'amount_usd', 'null'), ' ' order by t.dia),
       bool_and((a.e ->> 'amount_usd')::numeric is not distinct from round(10000 / t.rate, 2))
       and count(a.e) = 3
from tasa_euro t
left join abonos a on (a.e ->> 'moved_on')::date = t.dia;

rollback;
