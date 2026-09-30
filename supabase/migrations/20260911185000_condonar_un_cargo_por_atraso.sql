-- ============================================================================
-- Ronda — Condonar un cargo por atraso
--
-- El motor pone €2 por cuota retrasada a los tres días y nadie puede quitarlos.
-- Cuando el cargo está mal —el pago se hizo a tiempo y la conciliación tardó,
-- la app falló esa noche, se acordó algo con la persona— la única salida hoy es
-- arreglarlo por fuera del sistema, que es decir: no arreglarlo.
--
-- ---------------------------------------------------------------------------
-- Condonar deshace tres cosas, no una
-- ---------------------------------------------------------------------------
-- El cargo se devengó cuando nació: Dr receivable / Cr comisión. Y además entró
-- en el bloque de crédito, que es lo que hace que el cupo no vuelva hasta
-- pagarlo. Quitarlo solo de la lista dejaría al usuario con el cupo cerrado por
-- una deuda que ya no existe y al libro con un ingreso que nunca se va a
-- cobrar.
--
--   1. El cargo pasa a no cobrable.
--   2. Un asiento contrario, del mismo importe: Dr comisión / Cr receivable.
--      **No se borra el original.** El libro se corrige con otro asiento; eso
--      es lo que lo hace auditable.
--   3. Baja del bloque de crédito, para que el cupo vuelva cuando toque.
--
-- Y la persona se entera: su deuda bajó y tiene derecho a saber por qué.
--
-- ---------------------------------------------------------------------------
-- Por qué reusa `written_off` y no un estado nuevo
-- ---------------------------------------------------------------------------
-- `late_fee_status` tiene pending, paid y written_off, y `written_off` ya
-- significa exactamente lo que hace falta: no se va a cobrar. Todo lo que
-- filtra por `pending` deja de verlo sin tocar una línea.
--
-- Lo que distingue una condonación de un castigo son las tres columnas de
-- abajo —quién, cuándo y por qué—: un castigo no tiene ninguna de las tres.
-- Un valor 'waived' habría dicho lo mismo que ya dicen `written_off` y un
-- `waived_at` relleno, a cambio de una migración aparte.
--
-- El aviso al usuario sí necesitó un valor nuevo de enum —ninguno de los que
-- hay sirve para "te quitamos el cargo"— y por eso va en 20260911184500, en
-- su propia transacción: un valor nuevo no se puede usar en la misma.
-- ============================================================================

alter table public.late_fees
  add column if not exists waived_at timestamptz;

alter table public.late_fees
  add column if not exists waived_by uuid references auth.users (id);

alter table public.late_fees
  add column if not exists waive_reason text;

comment on column public.late_fees.waived_at is
  'Cuando se condono a mano. Un cargo con esto relleno esta en written_off por decision de una persona, no por el castigo de los 60 dias.';

create or replace function public.admin_waive_late_fee(
  p_fee_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_fee    public.late_fees%rowtype;
  v_tx     uuid;
  v_name   text;
begin
  -- Condonar mueve el libro: es del super admin.
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede condonar un cargo'
      using errcode = '42501';
  end if;

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Condonar un cargo requiere motivo' using errcode = '22023';
  end if;

  select * into v_fee from public.late_fees where id = p_fee_id for update;

  if not found then
    raise exception 'No existe ese cargo' using errcode = 'P0002';
  end if;

  -- Un cargo ya cobrado no se condona: se devuelve, y devolver dinero es otra
  -- operación con otras consecuencias. Uno ya castigado tampoco: ya salió.
  if v_fee.status <> 'pending' then
    raise exception 'Solo se puede condonar un cargo pendiente (este está %)', v_fee.status
      using errcode = '22023';
  end if;

  select full_name into v_name from public.profiles where id = v_fee.user_id;

  update public.late_fees
  set status = 'written_off',
      waived_at = now(),
      waived_by = v_actor,
      waive_reason = trim(p_reason)
  where id = p_fee_id;

  -- El asiento contrario. El original se queda donde está.
  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'manual_adjustment',
    'late_fee_waived:' || p_fee_id::text,
    public.helios_business_date(now()),
    p_fee_id,
    format('Cargo por atraso condonado: %s', trim(p_reason))
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, ledger.get_or_create_account('platform_revenue', null), v_fee.amount_usd, 0),
    (v_tx, ledger.get_or_create_account('user_receivable', v_fee.user_id), 0, v_fee.amount_usd);

  -- Y fuera del bloque, para que el cupo no se quede cerrado por una deuda que
  -- ya no existe.
  update public.user_credit_blocks
  set charged_usd = greatest(charged_usd - v_fee.amount_usd, 0)
  where id = v_fee.credit_block_id;

  -- La deuda de alguien no baja en silencio, igual que no sube en silencio.
  perform public.notify(
    v_fee.user_id,
    'late_fee_waived',
    'Te quitamos el cargo',
    format('Quitamos el cargo por atraso de €%s de tu deuda. Ya no lo debes.',
           to_char(v_fee.amount_usd, 'FM999999990.00'))
  );

  perform audit.log(v_actor, 'late_fee.waived', p_fee_id, jsonb_build_object(
    'user_id', v_fee.user_id,
    'full_name', v_name,
    'amount_usd', v_fee.amount_usd,
    'days_late', v_fee.days_late,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'amount_usd', v_fee.amount_usd,
    'user_id', v_fee.user_id
  );
end;
$$;

comment on function public.admin_waive_late_fee(uuid, text) is
  'Condona un cargo por atraso: lo saca de la deuda, escribe el asiento contrario, lo baja del bloque de credito y avisa a la persona. Solo super admin, con motivo.';

revoke all on function public.admin_waive_late_fee(uuid, text) from public, anon;
grant execute on function public.admin_waive_late_fee(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Los cargos vivos de una persona, para poder condonarlos desde su ficha
-- ---------------------------------------------------------------------------

create or replace function public.admin_user_late_fees(p_user uuid)
returns table (
  id            uuid,
  amount_usd    numeric,
  days_late     integer,
  business_date date,
  status        text,
  waived_at     timestamptz,
  waive_reason  text,
  sequence      smallint,
  due_date      date,
  merchant_name text
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
  select
    f.id,
    f.amount_usd,
    f.days_late,
    f.business_date,
    f.status::text,
    f.waived_at,
    f.waive_reason,
    i.sequence,
    i.due_date,
    m.name
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  left join public.charges ch on ch.id = i.charge_id
  left join public.merchants m on m.id = ch.merchant_id
  where f.user_id = p_user
  order by f.created_at desc;
end;
$$;

revoke all on function public.admin_user_late_fees(uuid) from public, anon;
grant execute on function public.admin_user_late_fees(uuid) to authenticated;
