-- ============================================================================
-- Ronda — El libro, entero
--
-- El libro del panel enseñaba fecha, tipo, concepto, movimiento y quién. Le
-- faltaban las cuatro cosas que hacen falta para **cuadrar** de verdad:
--
--   1. **El saldo de caja después de cada asiento.** Sin él, "la caja dice
--      €126,55" es un número al final de una lista: no se puede señalar la
--      línea donde dejó de cuadrar. Con él, se baja del saldo al asiento.
--
--   2. **Los bolívares y la tasa.** El banco habla en bolívares. Un asiento en
--      euros no se coteja contra un extracto sin rehacer la conversión a mano,
--      y rehacerla con la tasa de hoy da otro número.
--
--   3. **De quién es.** Las cuentas del libro llevan `owner_id`, pero un uuid
--      no es una persona. El nombre y el enlace convierten el libro en algo
--      que se puede leer.
--
--   4. **Los filtros de verdad**: rango de días operativos, una persona, un
--      comercio. "Enséñame lo de la noche del viernes en Kabal" era una
--      pregunta que no se podía hacer.
--
-- ---------------------------------------------------------------------------
-- El saldo acumulado, y por qué se calcula hacia atrás
-- ---------------------------------------------------------------------------
-- El saldo después de un asiento es la suma de **todos** los movimientos de
-- caja hasta él, no solo de los que caben en la página. Así que no se puede
-- acumular sobre las cien filas que se devuelven: hay que sumar la historia
-- entera y quedarse con el tramo visible.
--
-- Se hace con una ventana sobre todas las transacciones ordenadas por fecha, y
-- después se recorta. Con el volumen del piloto es instantáneo; si algún día
-- deja de serlo, la respuesta es una columna materializada, no aproximar.
--
-- El orden de la ventana es `created_at, id`: dos asientos del mismo instante
-- —un pago que mueve dos cuentas— tienen que acumularse siempre en el mismo
-- orden, o el saldo bailaría entre dos consultas idénticas.
-- ============================================================================

drop function if exists public.admin_ledger_entries(integer, text);

create or replace function public.admin_ledger_entries(
  p_limit       integer default 100,
  p_type        text default null,
  p_from        date default null,
  p_to          date default null,
  p_user_id     uuid default null,
  p_merchant_id uuid default null
)
returns table (
  transaction_id  uuid,
  type            text,
  business_date   date,
  memo            text,
  created_at      timestamptz,
  created_by      uuid,
  actor_name      text,
  amount_ves      numeric,
  fx_rate         numeric,
  cash_balance    numeric,
  counterparty_kind text,
  counterparty_id   uuid,
  counterparty_name text,
  lines           jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  with movimiento as (
    -- Cuánto movió la caja cada transacción. Un asiento que no toca caja
    -- —un consumo, un devengo— no aparece aquí y deja el saldo donde estaba.
    select
      e.transaction_id as id,
      sum(e.debit) - sum(e.credit) as delta
    from ledger.entries e
    join ledger.accounts a on a.id = e.account_id
    where a.account_type = 'cash'
    group by e.transaction_id
  ),
  saldo as (
    -- La historia entera, acumulada. Se recorta después: el saldo tras un
    -- asiento no depende de cuántas filas quepan en la pantalla.
    select
      t.id,
      sum(coalesce(m.delta, 0)) over (
        order by t.created_at, t.id
        rows between unbounded preceding and current row
      ) as balance
    from ledger.transactions t
    left join movimiento m on m.id = t.id
  ),
  -- De quién es el asiento. Se toma el primer dueño que no sea nulo: una
  -- transacción toca varias cuentas pero solo una contraparte de negocio.
  parte as (
    select
      e.transaction_id,
      min(a.owner_id::text) filter (where a.account_type = 'user_receivable')  as user_id,
      min(a.owner_id::text) filter (where a.account_type = 'merchant_payable') as merchant_id
    from ledger.entries e
    join ledger.accounts a on a.id = e.account_id
    where a.owner_id is not null
    group by e.transaction_id
  )
  select
    t.id,
    t.type::text,
    t.business_date,
    t.memo,
    t.created_at,
    t.created_by,
    pa.full_name,
    -- El importe en bolívares a la tasa del día operativo **del asiento**, no
    -- a la de hoy: el movimiento ocurrió con aquella, y reconvertirlo con otra
    -- inventa una diferencia cambiaria que no existió. Se convierte lo que
    -- movió la caja, en valor absoluto: al banco le da igual el signo.
    (
      select round(abs(coalesce(m2.delta, 0)) * r.rate, 2)
      from public.exchange_rates r
      where r.effective_date <= t.business_date
      order by r.effective_date desc
      limit 1
    ),
    (
      select r.rate
      from public.exchange_rates r
      where r.effective_date <= t.business_date
      order by r.effective_date desc
      limit 1
    ),
    s.balance,
    case
      when p.user_id is not null then 'persona'
      when p.merchant_id is not null then 'comercio'
      else null
    end,
    coalesce(p.user_id, p.merchant_id)::uuid,
    coalesce(pr.full_name, me.name),
    (
      select jsonb_agg(
        jsonb_build_object(
          'account', a.account_type::text,
          'owner_id', a.owner_id,
          'debit', e.debit,
          'credit', e.credit
        ) order by e.id
      )
      from ledger.entries e
      join ledger.accounts a on a.id = e.account_id
      where e.transaction_id = t.id
    )
  from ledger.transactions t
  join saldo s on s.id = t.id
  left join movimiento m2 on m2.id = t.id
  left join parte p on p.transaction_id = t.id
  left join public.profiles pr on pr.id = p.user_id::uuid
  left join public.merchants me on me.id = p.merchant_id::uuid
  left join public.platform_admins pa on pa.user_id = t.created_by
  where (p_type is null or t.type::text = p_type)
    and (p_from is null or t.business_date >= p_from)
    and (p_to is null or t.business_date <= p_to)
    and (p_user_id is null or p.user_id::uuid = p_user_id)
    and (p_merchant_id is null or p.merchant_id::uuid = p_merchant_id)
  order by t.created_at desc, t.id desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

comment on function public.admin_ledger_entries(integer, text, date, date, uuid, uuid) is
  'Los asientos del libro con el saldo de caja despues de cada uno, su equivalente en bolivares a la tasa de SU dia operativo, y de quien son. El saldo se acumula sobre la historia entera y se recorta despues: no depende de cuantas filas quepan en pantalla.';

revoke all on function public.admin_ledger_entries(integer, text, date, date, uuid, uuid)
  from public, anon;
grant execute on function public.admin_ledger_entries(integer, text, date, date, uuid, uuid)
  to authenticated;
