-- ============================================================================
-- Ronda — La exportación contable mensual
--
-- Lo que el contador pide todos los meses se sacaba del CSV del libro y se
-- reordenaba a mano. El problema no es el trabajo: es que cada mes se
-- reordenaba un poco distinto, y dos cierres del mismo año no se podían
-- comparar.
--
-- Esto devuelve el mes en tres piezas, que son las tres preguntas del contador:
--
--   RESUMEN     lo que entró, lo que salió, lo que se ganó y lo que se perdió.
--   POR CUENTA  el movimiento de cada cuenta del libro. Es el balance de
--               comprobación: la suma de los netos tiene que dar cero.
--   ASIENTOS    el detalle, por si hay que justificar una línea.
--
-- ---------------------------------------------------------------------------
-- Por día operativo, y en las dos monedas
-- ---------------------------------------------------------------------------
-- El mes va de día operativo a día operativo: un consumo del 1 a las 3 a. m.
-- pertenece al 31 del mes anterior, y meterlo en el mes que no es descuadra los
-- dos. Y cada asiento lleva su equivalente en bolívares **a la tasa de su
-- día**, que es con la que ocurrió: el contador declara en bolívares.
--
-- Las cuentas de prueba quedan fuera enteras. Una factura de prueba en una
-- declaración es un problema de verdad.
--
-- ---------------------------------------------------------------------------
-- Una sola consulta, sin tabla temporal
-- ---------------------------------------------------------------------------
-- Las tres piezas salen de la misma lista de transacciones, y la tentación es
-- materializarla en una tabla temporal. No se puede: esto es una función
-- `stable` —solo lee— y crear una tabla es escribir. Así que la lista es una
-- CTE y las tres piezas se agregan en la misma pasada.
-- ============================================================================

create or replace function public.admin_accounting_export(p_month text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_desde date;
  v_hasta date;
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_month !~ '^\d{4}-\d{2}$' then
    raise exception 'El mes se escribe AAAA-MM' using errcode = '22023';
  end if;

  v_desde := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_hasta := (v_desde + interval '1 month' - interval '1 day')::date;

  with tx as (
    -- Las transacciones del mes que no tocan a nadie de prueba, con la tasa
    -- de su día ya resuelta.
    select
      t.id, t.business_date, t.type::text as type, t.memo, t.created_at,
      (select r.rate from public.exchange_rates r
        where r.effective_date <= t.business_date
        order by r.effective_date desc limit 1) as rate
    from ledger.transactions t
    where t.business_date between v_desde and v_hasta
      and not exists (
        select 1
        from ledger.entries e
        join ledger.accounts a on a.id = e.account_id
        where e.transaction_id = t.id
          and a.owner_id is not null
          and (
            public.helios_is_test_user(a.owner_id)
            or public.helios_is_test_merchant(a.owner_id)
          )
      )
  ),
  lineas as (
    select
      tx.id, tx.business_date, tx.created_at, tx.type, tx.memo, tx.rate,
      a.account_type::text as account,
      a.owner_id,
      e.debit, e.credit
    from tx
    join ledger.entries e on e.transaction_id = tx.id
    join ledger.accounts a on a.id = e.account_id
  ),
  resumen as (
    select jsonb_build_object(
      'collected_usd',   coalesce(sum(debit)  filter (where account = 'cash'), 0),
      'paid_out_usd',    coalesce(sum(credit) filter (where account = 'cash'), 0),
      -- La comisión es una cuenta de ingreso: saldo acreedor. El neto del mes
      -- es crédito menos débito, y el `filter` va en los dos o mide otra cosa.
      'revenue_usd',
        coalesce(sum(credit) filter (where account = 'platform_revenue'), 0)
        - coalesce(sum(debit) filter (where account = 'platform_revenue'), 0),
      'vat_usd',
        coalesce(sum(credit) filter (where account = 'vat_payable'), 0)
        - coalesce(sum(debit) filter (where account = 'vat_payable'), 0),
      'written_off_usd', coalesce(sum(debit) filter (where account = 'bad_debt_provision'), 0),
      'transactions',    count(distinct id)::integer
    ) as j
    from lineas
  ),
  por_cuenta as (
    select coalesce(jsonb_agg(to_jsonb(q) order by q.account), '[]'::jsonb) as j
    from (
      select
        account,
        sum(debit)  as debit_usd,
        sum(credit) as credit_usd,
        sum(debit) - sum(credit) as net_usd,
        sum(round(debit  * coalesce(rate, 0), 2)) as debit_ves,
        sum(round(credit * coalesce(rate, 0), 2)) as credit_ves
      from lineas
      group by account
    ) q
  ),
  asientos as (
    select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb) as j
    from (
      select
        l.business_date,
        l.created_at,
        l.type,
        l.memo,
        l.account,
        l.debit  as debit_usd,
        l.credit as credit_usd,
        l.rate   as fx_rate,
        round(l.debit  * coalesce(l.rate, 0), 2) as debit_ves,
        round(l.credit * coalesce(l.rate, 0), 2) as credit_ves,
        coalesce(pr.full_name, me.name) as counterparty
      from lineas l
      left join public.profiles pr on pr.id = l.owner_id
      left join public.merchants me on me.id = l.owner_id
    ) q
  )
  select jsonb_build_object(
    'month', p_month,
    'from', v_desde,
    'to', v_hasta,
    'summary', resumen.j,
    'by_account', por_cuenta.j,
    'entries', asientos.j
  )
  into v_out
  from resumen, por_cuenta, asientos;

  return v_out;
end;
$$;

comment on function public.admin_accounting_export(text) is
  'Un mes en tres piezas: resumen, balance de comprobacion por cuenta y asientos. Por dia operativo y con el equivalente en bolivares a la tasa de cada dia. Sin cuentas de prueba.';

revoke all on function public.admin_accounting_export(text) from public, anon;
grant execute on function public.admin_accounting_export(text) to authenticated;
