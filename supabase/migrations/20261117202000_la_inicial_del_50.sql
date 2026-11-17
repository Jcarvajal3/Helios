-- ============================================================================
-- Helios — La inicial del 50% (Javier, 2026-11-12; docs/07-INICIAL-DEL-50.md)
--
-- ⚠️ POR LANZAR. Vive en `supabase/por-lanzar/` hasta el día del lanzamiento
-- (docs/07 «Lanzamiento»): entonces se renombra al timestamp de ese día, se
-- mueve a `migrations/` y se aplica junto con el webhook y el panel. Es UN
-- SOLO fichero a propósito: `aplicar.mjs` corre cada fichero en su propia
-- transacción, y el ciclo, los mensajes, las pantallas y las condiciones
-- dependen unos de otros. O entra todo, o nada. Todas las guardias van al
-- principio. Necesita el valor de enum de 20261112100000 (ya aplicado).
--
-- Toda orden nueva se paga con una inicial del 50% del total (con la
-- comisión) el mismo día y el resto en 2 cuotas a los 14 y 28 días:
--
--   1. Al registrarla, la orden guarda la inicial vigente
--      (`charges.down_payment_pct`, trigger `charges_down_payment`). Null o 0
--      = orden sin inicial: TODO sigue exactamente como hasta hoy.
--   2. «Sí» (+ cédula) → `helios_finalize_charge`: asiento y deuda como
--      siempre, ahora con 3 cuotas (la inicial es la cuota 0, que vence hoy);
--      la orden queda `awaiting_down_payment` con `down_payment_due_at` =
--      ahora + 2 h. Sin adelanto, comisión de la secretaria, comprobante ni
--      aviso al médico todavía. Al paciente, `pagar_inicial`.
--   3. Se aprueba un pago que cubre la cuota 0, por cualquier camino (lector,
--      aviso del BNC, Caja) → trigger `installments_activate_charge` →
--      `helios_activate_charge`: `confirmed`, `activated_at`, y entonces sí el
--      adelanto, la comisión y el aviso al médico; el comprobante, cuando el
--      pago queda aprobado entero (trigger `payment_reports_activated_receipt`).
--   4. Pasa el plazo sin un pago abierto → el cron
--      `helios_revert_unpaid_down_payments` (cada minuto) la anula con la
--      maquinaria de la reversa y avisa al paciente y al médico.
--   5. La inicial nunca está «vencida»: mientras la orden la espera su fecha
--      avanza con el día; no entra en la mora, el cargo por atraso, la
--      cobranza, los recordatorios ni las métricas de cuotas, y no se le paga a
--      la clínica (no tiene `settlement_due_date`).
--
-- Secciones: 0 guardias · 1-8 el ciclo · 9 el reparto de un monto · los
-- parches del ciclo · los mensajes · las pantallas · 10 las condiciones v4.
-- El contrato, campo por campo: docs/01-CONTRATO-RPC.md, «La inicial».
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                 where t.typname = 'charge_status' and e.enumlabel = 'awaiting_down_payment') then
    raise exception 'Falta el valor awaiting_down_payment del enum (20261112100000)';
  end if;
  if not exists (select 1 from public.terms_versions where version = 'v3' and is_current) then
    raise exception 'Las condiciones vigentes no son v3: revisar antes de publicar v4';
  end if;
end $$;

-- 0. Nada cambió desde que se escribió este fichero ────────────────────────
-- Cada función que este fichero reescribe se copió tal como estaba en la base
-- el 2026-11-12. Si otra migración la cambió después, este fichero la pisaría:
-- se para aquí y hay que rehacer el cambio sobre la versión nueva.

do $guardia$
declare
  r record;
begin
  for r in select * from (values
    ('public.helios_installment_currency()', 'ebdff6ff2111931df8f8e5e78ed618b1'),
    ('public.helios_installment_settlement_due_date()', 'c435e35f2ebd4d6351f93e07511c5ed0'),
    ('public.helios_assign_debt(uuid,uuid,numeric,numeric,date,date,text)', '42e8c940e71e337393d9620f1747422c'),
    ('public.helios_charge_planned_installments(uuid)', 'ab2cc4125b8ec94682481c8ff193c79e'),
    ('public.preview_patient_charge(uuid,text,numeric,text)', '9da7e4b029c9e382bf664147450ea5d9'),
    ('public.helios_finalize_charge(uuid,text,text)', '5f161a26775e9d986a7a3b7f1dc2da2e'),
    ('public.helios_patient_decision(uuid,text,text,text)', 'af35068ae5bab275d2aff0212a65ed42'),
    ('public.helios_patient_id_photo(text,text,text,text)', '7f024473581b4b41230cf2cdee0b6da8'),
    ('public.helios_charge_confirmation(uuid)', '9e303c6e9ecbcd282acea34d59d143b5'),
    ('public.staff_resend_confirmation(uuid)', '23590412b088e8faf4ec825b172e5a5a'),
    ('public.helios_charge_reverse_blocker(uuid)', '941e2d3dda25cce6189f1b30292f1dac'),
    ('public.helios_in_arrears(uuid)', '4580eff082c88057f7e886108a201470'),
    ('public.can_take_debt(uuid)', '686fc004845ceb8ddb7ffbd14f122b99'),
    ('public.process_mora_batch(uuid,integer)', '7b9ce147cdf7c539f14f4ba505063801'),
    ('public.recompute_profile_mora_state(uuid)', '7c6322e1a068ce8b1f20a318e87630df'),
    ('public.helios_collection_amounts(uuid,date,integer)', 'e5ba89b9941361c0c1afa777f2e7228f'),
    ('public.helios_collection_rows(date,integer,uuid)', '5e769860316593f67f61abf8a35214c8'),
    ('public.run_scheduled_settlements_batch(date,uuid,integer)', 'cd714c2fc99a8cea26ef5bfe9aeaf962'),
    ('public.helios_settlement_outlook(uuid)', '2387cf912b2bd4d715b190dfeb6af364'),
    ('public.admin_merchant_upcoming_settlements(uuid)', 'f16bf6a33c3a5e1f576b3bbab49c238a'),
    ('metricas.cuotas_al(date)', '503b33076f27764f0a1b10dc00cae999'),
    ('public.helios_receipt_tramo(uuid,date,numeric)', '99f4cd2cf34cb6bd749618cc5c6fd426'),
    ('public.reconcile_payment(uuid,uuid,boolean,text)', '6ebbc22ba1d84c5ac82f0aff4e50b773'),
    ('public.helios_quote_installments(uuid,uuid[],boolean)', 'd85d475c9fe6639416b9786d2d00dc5a'),
    ('public.admin_reverse_charge(uuid,text)', 'd90ff0f3496fe6ce616055dd61d67ad3'),
    ('public.helios_accrue_staff_commission(uuid)', 'fece76052153df06e6fb961fc0a17941'),
    ('public.helios_receipt_decide(uuid)', '75948a821c4f3b9052a34b2602dd3da0'),
    ('public.helios_receipt_pair(uuid,uuid)', '86b049cf85580140ba126e0dbb2be210'),
    ('public.helios_register_payment_core(uuid,uuid[],text,text,text,date,numeric,text,text,uuid,text,uuid)', '47286620efe3e61bf17a439b02710898'),
    ('public.helios_credit_used_usd(uuid)', '7a38deec5934d14a203cf027798b9a8d'),
    ('public.helios_enqueue_reminders(text,date)', '3d59a2bbadb3b676f29a587b85a28c8c'),
    ('public.helios_enqueue_message(text,uuid,uuid,text,jsonb,date,text)', '0971ae1ef3fe6cbe962e2ae8c0485e41'),
    ('public.create_patient_charge(uuid,uuid,jsonb,numeric,text,text,text,text)', '74c67c5d0f70bb9525e3610a8ec883fd'),
    ('public.helios_whatsapp_inbound(text,text,text,jsonb)', 'a837cc02bfb0be43ff1c699b50a5bb64'),
    ('public.admin_set_business_parameter(text,numeric,date,text)', 'b05bfb52e0659d7162d9a5005c7c745d'),
    ('public.admin_risk_alerts(integer,text[],uuid)', 'cf9ca4854d073331c6a2317dbd4cdbba'),
    ('public.admin_review_risk_alert(text,text)', 'ac8bf68a6437f78afb2061b5db67f5e4'),
    ('public.helios_patient_decision_text(uuid,text)', 'c8b743a12a7988b412199645c9513e5c'),
    ('public.helios_notify_staff_of_charge(uuid,text)', '0504be4340125bae22c10befe67275c9'),
    ('public.helios_enqueue_confirmation(uuid)', '3832286b833d80980e16e243677f7332'),
    ('public.helios_payment_result_whatsapp(uuid)', '370df1423ba1c46aa73f714cf6015ec8'),
    ('public.helios_enqueue_charge_receipt(uuid)', '54a480bd6042d6f70ebe92aeb423ba76'),
    ('public.merchant_transactions(date,date,integer)', '59ea5665294628773d1f5d5dbbc0808d'),
    ('public.merchant_charge_detail(uuid)', 'e526f1329d7c72e372076f30a4e26cf8'),
    ('public.helios_charge_for_staff(uuid)', 'a40006792acd8d4095a4b56a3ae6c346'),
    ('public.admin_charge_detail(uuid)', '6c418eec7bc1d2492e7d99639c8163e5'),
    ('public.bot_paciente_resumen(uuid)', '607b40a547a4023ab2ff5f33779b8eed'),
    ('asistente.estado(text,text)', '4f6526a868d71d8ae9b6abf9dbbe0ce2'),
    ('public.merchant_sales_export(date,date)', 'd5f88a00c499ff93c2704e5ba4fa0403'),
    ('public.merchant_sales_export_items(date,date)', '9610d0493f7a6429afa515536d94dac4'),
    ('public.admin_charges(text,uuid,text,date,date,integer)', '224e650a48b7f440b494d48e545127d2'),
    ('public.helios_admin_payment_item(uuid,date)', '73af0f0c8282df17a3c47b97e43f4425'),
    ('public.helios_admin_user_detail_base(uuid)', '65284f97fd8d53342d87442a38f3332d')
  ) v(firma, huella)
  loop
    if (select md5(p.prosrc) from pg_proc p where p.oid = r.firma::regprocedure) is distinct from r.huella then
      raise exception 'La función % cambió desde el 2026-11-12: revisa este fichero antes de lanzarlo', r.firma;
    end if;
  end loop;
end $guardia$;

-- Las vistas tampoco cambiaron desde el 2026-11-12.
do $$
begin
  if md5(pg_get_viewdef('asistente.ordenes'::regclass)) <> '4727379615e357852d82614417ede385'
     or md5(pg_get_viewdef('asistente.cuotas'::regclass)) <> '64668c49eac56dcf579a83789e4171e4' then
    raise exception 'asistente.ordenes o asistente.cuotas cambió desde el 2026-11-12: revisa este fichero antes de lanzarlo';
  end if;
end $$;



-- 1. Los parámetros ─────────────────────────────────────────────────────────
-- `down_payment_pct`: el 50% del total con la comisión, desde el día en que
-- se lanza. Antes de esa fecha la función devuelve 0: las órdenes viejas no
-- tienen inicial. `down_payment_minutes`: el plazo para pagarla desde el «Sí».

insert into public.business_parameters (key, value, effective_from, note)
values
  ('down_payment_pct', 50, public.helios_business_date(now()),
   'Inicial del 50% del total con la comisión, el mismo día del «Sí»; el resto en 2 cuotas (Javier, 2026-11-12; docs/07).'),
  ('down_payment_minutes', 120, public.helios_business_date(now()),
   'Plazo para pagar la inicial desde que el paciente acepta; si no llega, la orden se anula sola (Javier, 2026-11-12).')
on conflict (key, effective_from) do update
  set value = excluded.value,
      note  = excluded.note;

-- El catálogo avisa de que la plantilla de Meta v3 dice «50%» y «2 horas»
-- escritos: cambiar estos valores obliga a mandar otra plantilla.
-- `admin_set_business_parameter` solo admite una inicial de 0 a 90 y un plazo
-- de al menos 1 minuto.
insert into public.business_parameter_catalog (key, label, unit, grupo)
values
  ('down_payment_pct', 'Inicial del paciente (sobre el total con la comisión; de 0 a 90). La plantilla de Meta v3 dice «50%»: si cambia, hay que mandar otra', '%', 'producto'),
  ('down_payment_minutes', 'Plazo para pagar la inicial. La plantilla de Meta v3 dice «2 horas»: si cambia, hay que mandar otra', 'minutos', 'producto'),
  ('alert_down_payment_stuck_hours', 'Alerta: orden esperando la inicial tantas horas después de su plazo (un pago en revisión la sostiene)', 'horas', 'alerta')
on conflict (key) do update set label = excluded.label, unit = excluded.unit, grupo = excluded.grupo;

insert into public.business_parameters (key, value, effective_from, note)
values ('alert_down_payment_stuck_hours', 6, public.helios_business_date(now()),
        'Una orden que sigue esperando la inicial 6 h después de su plazo (con un pago abierto) sale en superadmin › Alertas.')
on conflict (key, effective_from) do update set value = excluded.value, note = excluded.note;

/** La inicial vigente en un día: la de las órdenes registradas ese día. */
create or replace function public.helios_down_payment_pct_at(p_day date)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select p.value
    from public.business_parameters p
    where p.key = 'down_payment_pct'
      and p.effective_from <= p_day
    order by p.effective_from desc
    limit 1
  ), 0);
$$;

/** Minutos que tiene el paciente para pagar la inicial desde el «Sí». */
create or replace function public.helios_down_payment_minutes()
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$ select public.helios_parameter('down_payment_minutes', 120)::integer $$;

-- 2. La orden guarda su inicial ─────────────────────────────────────────────
-- `down_payment_pct`: la de la orden al crearla (null o 0 = orden sin
-- inicial: 2 cuotas, como hasta hoy). `down_payment_due_at`: hasta cuándo
-- puede pagarla (el «Sí» + el plazo). `activated_at`: cuándo se aprobó la
-- inicial y la orden quedó activa. `down_payment_expired_at`: cuándo se anuló
-- sola por no pagarla (el motivo de la reversa; `void_reason` lo dice en
-- palabras).

alter table public.charges
  add column if not exists down_payment_pct numeric(5,2),
  add column if not exists down_payment_due_at timestamptz,
  add column if not exists activated_at timestamptz,
  add column if not exists down_payment_expired_at timestamptz;

alter table public.charges drop constraint if exists charges_down_payment_pct_check;
alter table public.charges add constraint charges_down_payment_pct_check
  check (down_payment_pct is null or (down_payment_pct >= 0 and down_payment_pct < 100));

comment on column public.charges.down_payment_pct is
  'Inicial de la orden, en % del total con la comisión (docs/07). Null o 0: sin inicial (las órdenes de antes del 2026-11-12).';
comment on column public.charges.down_payment_due_at is
  'Hasta cuándo puede pagar la inicial (el «Sí» + helios_down_payment_minutes()). Pasado el plazo sin un pago abierto, la orden se anula sola.';
comment on column public.charges.activated_at is
  'Cuándo se aprobó la inicial y la orden pasó de awaiting_down_payment a confirmed.';
comment on column public.charges.down_payment_expired_at is
  'Cuándo se anuló sola por no pagar la inicial a tiempo (status reverted).';

-- Cada orden nueva toma la inicial vigente el día de su registro, venga del
-- panel, del bot o de donde venga. Quien la fije a mano (una suite) manda.
create or replace function public.helios_charge_down_payment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.down_payment_pct is null then
    new.down_payment_pct := public.helios_down_payment_pct_at(
      coalesce(new.business_date, public.helios_business_date(now())));
  end if;
  return new;
end;
$$;

drop trigger if exists charges_down_payment on public.charges;
create trigger charges_down_payment
  before insert on public.charges
  for each row execute function public.helios_charge_down_payment();

-- 3. La cuota 0 ─────────────────────────────────────────────────────────────
-- La inicial es una cuota más, con `sequence = 0`. Las cuotas 1 y 2 conservan
-- su número, sus fechas y el día en que se le paga a la clínica cada mitad.

alter table public.installments drop constraint if exists installments_sequence_check;
alter table public.installments add constraint installments_sequence_check
  check (sequence = any (array[0, 1, 2]));

-- La inicial no es de la clínica: es la única cuota sin día de pago.
alter table public.installments alter column settlement_due_date drop not null;
alter table public.installments drop constraint if exists installments_settlement_due_date_check;
alter table public.installments add constraint installments_settlement_due_date_check
  check (settlement_due_date is not null or sequence = 0);

/**
 * El reparto de una orden en su inicial y sus 2 cuotas, el ÚNICO sitio que lo
 * decide (docs/07 «Cuentas»). `p_total`: lo que paga el paciente (con la
 * comisión); `p_base`: la consulta. Sin inicial (`p_pct` null o 0) devuelve
 * las 2 mitades de siempre:
 *
 *   inicial = round(T × pct / 100, 2)
 *   cuota 1 = round((T − inicial) / 2, 2)
 *   cuota 2 = T − inicial − cuota 1
 *
 * y lo mismo sobre la consulta (`financed`), para que las tres sumen la
 * consulta entera y el límite la siga contando hasta que se pague todo.
 * $113,92 → 56,96 + 28,48 + 28,48. $34,18 → 17,09 + 8,55 + 8,54.
 */
create or replace function public.helios_installment_split(p_total numeric, p_base numeric, p_pct numeric)
returns table(seq smallint, amount numeric, financed numeric)
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_a0 numeric := 0;
  v_f0 numeric := 0;
  v_a1 numeric;
  v_f1 numeric;
begin
  if coalesce(p_pct, 0) > 0 then
    v_a0 := round(p_total * p_pct / 100, 2);
    v_f0 := round(p_base * p_pct / 100, 2);
    seq := 0; amount := v_a0; financed := v_f0;
    return next;
  end if;

  v_a1 := round((p_total - v_a0) / 2, 2);
  v_f1 := round((p_base - v_f0) / 2, 2);
  seq := 1; amount := v_a1; financed := v_f1;
  return next;
  seq := 2; amount := p_total - v_a0 - v_a1; financed := p_base - v_f0 - v_f1;
  return next;
end;
$$;

-- El trigger de la moneda: la parte en euros de cada cuota sale del mismo
-- reparto, sobre los montos de la orden en euros.
create or replace function public.helios_installment_currency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c public.charges%rowtype;
  v_s record;
begin
  if new.amount_cur is not null then
    return new;
  end if;

  select * into v_c from public.charges where id = new.charge_id;

  if v_c.id is null or v_c.currency = 'USD' or v_c.amount_cur is null then
    new.amount_cur   := new.amount_usd;
    new.financed_cur := new.financed_usd;
    return new;
  end if;

  -- NUEVO (2026-11-12, la inicial): el mismo reparto que en dólares
  -- (`helios_installment_split`), con la inicial de la orden.
  select * into v_s
  from public.helios_installment_split(v_c.amount_cur, coalesce(v_c.base_cur, v_c.amount_cur),
                                       v_c.down_payment_pct) s
  where s.seq = new.sequence;

  new.amount_cur   := v_s.amount;
  new.financed_cur := v_s.financed;
  return new;
end;
$$;

-- El día en que se le paga a la clínica cada mitad. La inicial no es de la
-- clínica: se queda en Helios y no tiene día de pago (null), así que el lote
-- de liquidaciones nunca la mira.
create or replace function public.helios_installment_settlement_due_date()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dia date;
begin
  if new.settlement_due_date is not null then
    return new;
  end if;

  -- NUEVO (2026-11-12, la inicial).
  if new.sequence = 0 then
    return new;
  end if;

  select c.business_date into v_dia from public.charges c where c.id = new.charge_id;

  new.settlement_due_date := coalesce(v_dia, public.helios_business_date(now()))
                             + public.helios_settlement_interval_days() * new.sequence;
  return new;
end;
$$;

-- 4. La deuda ───────────────────────────────────────────────────────────────
-- Sigue siendo la ÚNICA función que crea deuda. Con inicial, inserta 3 cuotas:
-- la 0 vence hoy (el día del «Sí») y la 1 y la 2, en sus fechas de siempre.
create or replace function public.helios_assign_debt(
  p_user uuid, p_charge_id uuid, p_financed_usd numeric, p_payable_usd numeric,
  p_due_1 date, p_due_2 date, p_over_limit_message text)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_limit    numeric(18,4);
  v_block    public.user_credit_blocks%rowtype;
  v_stop     jsonb;
  v_used     numeric(18,4);
  v_pct      numeric;
  v_split    jsonb;
begin
  -- Solo si hay algo que financiar: en un reparto de grupo alguien frenado
  -- tiene capacidad 0 y puede recibir una parte de 0. Eso no es deuda y no
  -- debe tumbar la cuenta de los demás.
  if p_financed_usd > 0 then
    v_stop := public.helios_spend_block(p_user);

    if coalesce((v_stop->>'blocks_balance')::boolean, false) then
      raise exception '%', v_stop->>'message' using errcode = '22023';
    end if;
  end if;

  select monthly_limit_usd into v_limit
  from public.levels l
  join public.profiles p on p.level = l.level
  where p.id = p_user;

  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (p_user)
    returning * into v_block;
  end if;

  v_used := public.helios_credit_used_usd(p_user);

  if v_used + p_financed_usd > v_limit then
    raise exception '%', p_over_limit_message using errcode = '22023';
  end if;

  -- NUEVO (2026-11-12, la inicial): el reparto sale de
  -- `helios_installment_split` con la inicial de la orden. Sin inicial, las 2
  -- mitades de siempre.
  select c.down_payment_pct into v_pct from public.charges c where c.id = p_charge_id;

  insert into public.installments
    (charge_id, user_id, sequence, amount_usd, due_date, financed_usd)
  select p_charge_id, p_user, s.seq, s.amount,
         case s.seq when 0 then public.helios_business_date(now())
                    when 1 then p_due_1
                    else p_due_2 end,
         s.financed
  from public.helios_installment_split(p_payable_usd, p_financed_usd, v_pct) s
  order by s.seq;

  update public.user_credit_blocks
    set charged_usd = charged_usd + p_financed_usd,
        fee_usd     = fee_usd + (p_payable_usd - p_financed_usd)
  where id = v_block.id;

  select jsonb_object_agg('installment_' || s.seq || '_usd', s.amount) into v_split
  from public.helios_installment_split(p_payable_usd, p_financed_usd, v_pct) s;

  return jsonb_build_object(
    'installment_1_usd', (v_split->>'installment_1_usd')::numeric,
    'installment_2_usd', (v_split->>'installment_2_usd')::numeric,
    -- NUEVO: null sin inicial.
    'down_payment_usd', (v_split->>'installment_0_usd')::numeric,
    'financed_usd', p_financed_usd,
    'payable_usd', p_payable_usd
  );
end;
$$;

-- 5. Lo que se le enseña antes de que existan las cuotas ────────────────────
-- Una orden pendiente aún no tiene cuotas: el plan sale del mismo reparto. La
-- inicial va como una fila más, con `sequence` 0, que vence el día de la
-- orden y no tiene día de pago a la clínica.
create or replace function public.helios_charge_planned_installments(p_charge_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_c     public.charges%rowtype;
  v_out   jsonb;
  v_due_1 date;
  v_due_2 date;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'sequence', x.sequence, 'due_date', x.due_date,
           'settlement_due_date', x.settlement_due_date,
           'amount_usd', x.amount_usd, 'financed_usd', x.financed_usd,
           'amount_cur', x.amount_cur, 'financed_cur', x.financed_cur,
           -- NUEVO (2026-11-12, la inicial).
           'status', x.status)
         order by x.sequence), null)
    into v_out
  from (
    select i.sequence, min(i.due_date) as due_date,
           min(i.settlement_due_date) as settlement_due_date,
           sum(i.amount_usd) as amount_usd, sum(i.financed_usd) as financed_usd,
           sum(coalesce(i.amount_cur, i.amount_usd)) as amount_cur,
           sum(coalesce(i.financed_cur, i.financed_usd)) as financed_cur,
           case when bool_and(i.status = 'paid') then 'paid' else 'pending' end as status
    from public.installments i where i.charge_id = p_charge_id group by i.sequence
  ) x;

  if v_out is not null then
    return v_out;
  end if;

  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return '[]'::jsonb;
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_c.business_date);

  select jsonb_agg(jsonb_build_object(
           'sequence', u.seq,
           'due_date', case u.seq when 0 then v_c.business_date when 1 then v_due_1 else v_due_2 end,
           'settlement_due_date', case when u.seq > 0
                                       then v_c.business_date + public.helios_settlement_interval_days() * u.seq end,
           'amount_usd', u.amount, 'financed_usd', u.financed,
           'amount_cur', c.amount, 'financed_cur', c.financed,
           'status', 'pending')
         order by u.seq)
    into v_out
  from public.helios_installment_split(v_c.amount_usd, coalesce(v_c.base_usd, v_c.amount_usd),
                                       v_c.down_payment_pct) u
  join public.helios_installment_split(coalesce(v_c.amount_cur, v_c.amount_usd),
                                       coalesce(v_c.base_cur, v_c.base_usd, v_c.amount_usd),
                                       v_c.down_payment_pct) c on c.seq = u.seq;

  return coalesce(v_out, '[]'::jsonb);
end;
$$;

-- La vista previa del registro (panel y bot, `bot_preview_charge` la envuelve):
-- la inicial de hoy y sus 2 cuotas, con los montos dentro de las cuotas.
create or replace function public.preview_patient_charge(
  p_merchant_id uuid, p_document text, p_amount numeric, p_currency text default 'USD')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_key     text;
  v_p       public.profiles%rowtype;
  v_terms   public.merchant_terms%rowtype;
  v_cur     text := public.helios_charge_currency(p_currency);
  v_bdate   date := public.helios_business_date(now());
  v_fx      numeric;
  v_rate    numeric;
  v_amt     jsonb;
  v_b       jsonb;
  v_bc      jsonb;
  v_due_1   date;
  v_due_2   date;
  v_base    numeric(18,4);
  v_pct     numeric;
  v_cuotas  jsonb;
  v_limit   numeric(18,4);
  v_avail   numeric(18,4);
  v_level1  numeric(18,4) := (select l.monthly_limit_usd from public.levels l where l.level = 1);
  v_min     numeric := public.helios_min_charge_usd();
begin
  if auth.uid() is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if public.helios_staff_role_in(p_merchant_id) is null then
    raise exception 'No tienes permiso para registrar en esta clínica' using errcode = '42501';
  end if;

  perform public.helios_assert_merchant_operating(p_merchant_id);

  v_fx := public.helios_usd_per_unit(v_cur, v_bdate);
  perform public.helios_assert_charge_amount_in(p_amount, v_cur, v_fx);

  if nullif(btrim(coalesce(p_document, '')), '') is not null then
    v_key := public.helios_document_key(p_document);
    perform public.helios_assert_document_looked_up(p_merchant_id, v_key);
    select * into v_p from public.profiles where document_key = v_key;
  end if;

  select * into v_terms from public.helios_terms_at(p_merchant_id, v_bdate);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  v_amt := public.helios_charge_amounts(p_amount, v_cur, v_fx, coalesce(v_terms.commission_pct, 0));
  v_b   := v_amt->'usd';
  v_bc  := v_amt->'cur';
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);
  v_base := (v_b->>'base_usd')::numeric;

  -- Bolívares de hoy por unidad de la moneda de la orden (null sin tasa).
  v_rate := public.helios_fx_rate(v_cur, v_bdate);

  -- NUEVO (2026-11-12, la inicial): el mismo reparto que `helios_assign_debt`
  -- (dólares) y que el trigger de las cuotas (moneda de la orden), con la
  -- inicial vigente hoy. La inicial va primero, con `sequence` 0.
  v_pct := public.helios_down_payment_pct_at(v_bdate);

  select jsonb_agg(jsonb_build_object(
           'sequence', u.seq,
           'due_date', case u.seq when 0 then v_bdate when 1 then v_due_1 else v_due_2 end,
           'amount_usd', u.amount, 'financed_usd', u.financed,
           'amount_cur', c.amount, 'financed_cur', c.financed,
           'amount_ves', case when v_rate is not null then round(c.amount * v_rate, 2) end)
         order by u.seq)
    into v_cuotas
  from public.helios_installment_split((v_b->>'consumer_total_usd')::numeric, v_base, v_pct) u
  join public.helios_installment_split((v_bc->>'consumer_total_usd')::numeric,
                                       (v_bc->>'base_usd')::numeric, v_pct) c on c.seq = u.seq;

  if v_p.id is not null then
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);
    -- Sin decir por qué: si no puede financiar, su disponible es 0.
    if not (v_p.status = 'active' and not v_p.is_blacklisted and public.can_take_debt(v_p.id))
       or v_avail < v_min then
      v_avail := 0;
    end if;
    v_avail := trunc(v_avail, 2);
  end if;

  return jsonb_build_object(
    'currency', v_cur,
    'fx_usd_per_unit', v_fx,
    'tasa_bcv', v_rate,
    -- En dólares, literal: lo del libro.
    'base_usd', v_base,
    'consumer_fee_pct', (v_b->>'consumer_fee_pct')::numeric,
    'consumer_fee_usd', (v_b->>'consumer_fee_usd')::numeric,
    'consumer_fee_vat_usd', (v_b->>'consumer_fee_vat_usd')::numeric,
    -- En la moneda de la orden: lo que se enseña.
    'base_cur', (v_bc->>'base_usd')::numeric,
    'consumer_fee_cur', (v_bc->>'consumer_fee_usd')::numeric,
    'consumer_fee_vat_cur', (v_bc->>'consumer_fee_vat_usd')::numeric,
    'business_date', v_bdate,
    -- Las cuotas llevan la comisión dentro: es donde la clínica puede verla.
    -- NUEVO: con inicial, 3 filas (0, 1 y 2).
    'installments', v_cuotas,
    -- NUEVO (2026-11-12): la inicial de esta orden (0 = sin inicial) y el
    -- plazo para pagarla desde el «Sí».
    'down_payment_pct', v_pct,
    'down_payment_minutes', case when v_pct > 0 then public.helios_down_payment_minutes() end,
    'late_fee_usd', public.helios_late_fee_usd(),
    'late_fee_grace_days', public.helios_late_fee_grace_days(),
    'cabe', case when v_p.id is null then v_base <= v_level1 else v_base <= v_avail end,
    'disponible_usd', case when v_p.id is null then null else v_avail end,
    'limite_usd', case when v_p.id is null then v_level1 end,
    'disponible_cur', case when v_p.id is null then null else trunc(v_avail / v_fx, 2) end,
    'limite_cur', case when v_p.id is null then trunc(v_level1 / v_fx, 2) end
  );
end;
$$;

-- 6. El «Sí» deja la orden esperando la inicial ─────────────────────────────
-- `helios_finalize_charge` hace lo de siempre (asiento de 4 patas y deuda,
-- ahora con la cuota 0) pero, con inicial, la orden queda en
-- `awaiting_down_payment` hasta que se apruebe la inicial y no causa todavía
-- el adelanto, la comisión de la secretaria ni el comprobante: eso lo hace
-- `helios_activate_charge`. Al paciente le llega el mensaje de la inicial con
-- su bloque de pago (`helios_enqueue_down_payment_request`).
create or replace function public.helios_finalize_charge(
  p_charge_id uuid, p_welcome_channel text, p_over_limit_message text default null)
returns void
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_charge   public.charges%rowtype;
  v_terms    public.merchant_terms%rowtype;
  v_due_1    date;
  v_due_2    date;
  v_financed numeric(18,4);
  v_revenue  numeric(18,4);
  v_share    numeric(18,4);
  v_tx       uuid;
  v_cuotas   text;
  v_merchant text;
  v_rate     numeric;
  v_demo     boolean;
  v_first    public.installments%rowtype;
  v_inicial  boolean;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  -- NUEVO (2026-11-12): con inicial, la orden espera el pago. Con el
  -- interruptor de la confirmación en 0, `create_patient_charge` la inserta
  -- ya 'confirmed' y sin cuotas: también pasa a esperar la inicial.
  v_inicial := coalesce(v_charge.down_payment_pct, 0) > 0;

  if v_charge.status = 'pending'
     or (v_inicial and v_charge.status = 'confirmed' and v_charge.activated_at is null
         and not exists (select 1 from public.installments i where i.charge_id = p_charge_id)) then
    if v_inicial then
      update public.charges
         set status = 'awaiting_down_payment', confirmed_at = null,
             down_payment_due_at = now() + make_interval(mins => public.helios_down_payment_minutes())
       where id = p_charge_id
      returning * into v_charge;
    else
      update public.charges
         set status = 'confirmed', confirmed_at = now()
       where id = p_charge_id
      returning * into v_charge;
    end if;
  end if;

  if v_charge.status <> (case when v_inicial then 'awaiting_down_payment' else 'confirmed' end)::public.charge_status
     or v_charge.user_id is null then
    raise exception 'La orden no se puede confirmar' using errcode = '22023';
  end if;

  select * into v_terms from public.helios_terms_at(v_charge.merchant_id, v_charge.business_date);
  if v_terms.id is null then
    raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
      using errcode = '22023';
  end if;

  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_charge.business_date);

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_revenue  := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_share    := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  -- Una orden de capacitación no es dinero y no deja asiento; así se puede
  -- borrar entera a medianoche sin tocar el libro.
  select p.is_demo into v_demo from public.profiles p where p.id = v_charge.user_id;

  if not coalesce(v_demo, false) then
    -- El asiento de cuatro patas, saltándose las que valen cero. En dólares.
    -- Si la inicial no se paga, la reversa lo deshace pata por pata.
    insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
    values ('charge', 'charge:' || v_charge.idempotency_key, v_charge.business_date, v_charge.id,
            'Financiamiento de consulta')
    returning id into v_tx;

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    select v_tx, x.acct, x.debit, x.credit
    from (values
      (ledger.get_or_create_account('user_receivable', v_charge.user_id), v_charge.amount_usd, 0::numeric),
      (ledger.get_or_create_account('merchant_payable', v_charge.merchant_id), 0::numeric, v_share),
      (ledger.get_or_create_account('platform_revenue', null), 0::numeric, v_revenue),
      (ledger.get_or_create_account('vat_payable', null), 0::numeric,
       v_charge.amount_usd - v_share - v_revenue)
    ) as x(acct, debit, credit)
    where x.debit <> 0 or x.credit <> 0;

    -- El adelanto a la clínica (no hace nada con upfront_pct = 0). Con
    -- inicial, al activarse: a la clínica se le garantiza desde entonces.
    if not v_inicial then
      perform ledger.record_advance_settlement(
        v_charge.merchant_id, v_charge.id, round(v_share * v_terms.upfront_pct / 100, 4), v_charge.business_date);
    end if;
  end if;

  -- La deuda: la inicial (si la hay) y las 2 cuotas (a los días del intervalo
  -- vigente en la fecha de la orden, `helios_installment_due_dates`) y el
  -- bloque de crédito. Cada cuota se pone sola su monto en la moneda de la
  -- orden (trigger `installments_currency`) y el día en que se le devenga a la
  -- clínica su mitad (trigger `installments_settlement_due_date`; la inicial,
  -- ninguno).
  perform public.helios_assign_debt(
    v_charge.user_id, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    coalesce(p_over_limit_message, public.helios_not_available_message()));

  if v_inicial then
    -- Al paciente: la inicial, su plazo y cómo pagarla. Lo demás, al activarse.
    perform public.helios_enqueue_down_payment_request(v_charge.id, p_welcome_channel);
    return;
  end if;

  -- La comisión de quien lo registró.
  perform public.helios_accrue_staff_commission(v_charge.id);

  -- Los mensajes: el comprobante (al correo REGISTRADO) y la bienvenida.
  perform public.helios_enqueue_charge_receipt(v_charge.id);

  v_rate := public.helios_fx_rate(v_charge.currency);

  select m.name into v_merchant from public.merchants m where m.id = v_charge.merchant_id;
  -- «1️⃣ $56,96 · lunes 26/10», sin bolívares (van en el bloque de pago).
  select string_agg(format('%s %s · %s',
                           case i.sequence when 1 then '1️⃣' when 2 then '2️⃣' when 3 then '3️⃣'
                                           else i.sequence::text || '.' end,
                           public.helios_money_cur_text(i.amount_cur, v_charge.currency),
                           public.helios_weekday_es(i.due_date) || ' ' || to_char(i.due_date, 'DD/MM')),
                    E'\n' order by i.sequence)
    into v_cuotas
  from public.installments i where i.charge_id = v_charge.id;

  select * into v_first from public.installments i
  where i.charge_id = v_charge.id order by i.sequence limit 1;

  perform public.helios_enqueue_message(
    'bienvenida', v_charge.user_id, v_charge.id, p_welcome_channel,
    jsonb_build_object(
      'clinica', v_merchant,
      'medico', public.helios_doctor_ref(v_charge.merchant_id),
      'orden', v_charge.order_number::text,
      'cuotas', v_cuotas,
      'moneda', public.helios_currency_name(v_charge.currency),
      'bloque_de_pago', public.helios_payment_block(
        case when v_rate is not null then round(v_first.amount_cur * v_rate, 2) end,
        public.helios_money_cur_text(v_first.amount_cur, v_charge.currency),
        public.helios_currency_name(v_charge.currency),
        public.helios_por_whatsapp(p_welcome_channel))),
    null, 'bienvenida:' || v_charge.id::text);
end;
$$;

-- 7. La inicial aprobada activa la orden ────────────────────────────────────
-- Por cualquier camino (lector de comprobantes, aviso del BNC, Caja): cuando
-- la cuota 0 pasa a pagada, el trigger `installments_activate_charge` llama a
-- `helios_activate_charge`. Corre dentro de la conciliación del pago
-- (`reconcile_payment` marca las cuotas antes que el reporte), así que el
-- aviso de pago aprobado ya ve la orden activa.
create or replace function public.helios_activate_charge(p_charge_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_c       public.charges%rowtype;
  v_terms   public.merchant_terms%rowtype;
  v_demo    boolean;
  v_revenue numeric(18,4);
  v_share   numeric(18,4);
begin
  select * into v_c from public.charges where id = p_charge_id for update;
  if not found or v_c.status <> 'awaiting_down_payment' then
    return false;
  end if;

  update public.charges
     set status = 'confirmed', confirmed_at = now(), activated_at = now()
   where id = p_charge_id
  returning * into v_c;

  -- El adelanto a la clínica, si su acuerdo lo tiene (con upfront_pct = 0 no
  -- hace nada). Desde aquí a la clínica se le paga pague o no el paciente.
  select p.is_demo into v_demo from public.profiles p where p.id = v_c.user_id;
  if not coalesce(v_demo, false) then
    select * into v_terms from public.helios_terms_at(v_c.merchant_id, v_c.business_date);
    if v_terms.id is not null then
      v_revenue := coalesce(v_c.consumer_fee_usd, 0) + coalesce(v_c.merchant_fee_usd, 0);
      v_share   := coalesce(v_c.merchant_net_usd, v_c.amount_usd - v_revenue);
      perform ledger.record_advance_settlement(
        v_c.merchant_id, v_c.id, round(v_share * v_terms.upfront_pct / 100, 4), v_c.business_date);
    end if;
  end if;

  -- Si la inicial se aprobó tarde (un pago que estuvo en revisión), la mitad
  -- de la clínica cuya fecha ya pasó se devenga hoy: el lote de liquidaciones
  -- solo mira hacia atrás unos días y se la saltaría. Nunca las dos el mismo
  -- día (el lote crea una mitad por orden y día): la 2.ª, como pronto, el día
  -- siguiente a la 1.ª.
  update public.installments
     set settlement_due_date = public.helios_business_date(now())
   where charge_id = v_c.id
     and sequence = 1
     and settlement_due_date < public.helios_business_date(now());
  update public.installments i2
     set settlement_due_date = i1.settlement_due_date + 1
    from public.installments i1
   where i1.charge_id = v_c.id and i1.sequence = 1
     and i2.charge_id = v_c.id and i2.sequence = 2
     and i2.settlement_due_date <= i1.settlement_due_date;

  -- La comisión de quien la registró: es dinero, va con la orden. Vence con
  -- la primera mitad (ya corregida arriba).
  perform public.helios_accrue_staff_commission(v_c.id);

  -- El comprobante por correo. Si la inicial la saldó un pago, sale cuando
  -- ese pago queda aprobado entero (trigger `payment_reports_activated_receipt`,
  -- al pasar el reporte a `reconciled`, que `reconcile_payment` hace después
  -- de marcar TODAS sus cuotas): si saldó también las cuotas 1 y 2, las
  -- enseña pagadas. Aquí la cuota 0 puede ser la primera del bucle. Sin un
  -- pago detrás (no hay camino así fuera de las pruebas), sale ya.
  if (select i.paid_by_report_id from public.installments i
      where i.charge_id = v_c.id and i.sequence = 0) is null then
    begin
      perform public.helios_enqueue_charge_receipt(v_c.id);
    exception when others then
      raise warning 'No se encoló el comprobante de la orden % al activarse: %', v_c.id, sqlerrm;
    end;
  end if;

  perform public.helios_notify_staff_of_charge(v_c.id, 'activada');
  return true;
end;
$$;

create or replace function public.helios_installment_activates_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.helios_activate_charge(new.charge_id);
  return null;
end;
$$;

-- El comprobante de las órdenes que activó un pago, cuando ese pago queda
-- aprobado: `reconcile_payment` marca primero todas las cuotas de la
-- cotización (en el orden que sea) y al final pasa el reporte a
-- `reconciled`. Así el comprobante ve el estado final de las cuotas pase lo
-- que pase con los triggers diferidos (un `set constraints all immediate`
-- dispararía uno diferido en mitad del bucle). Un comprobante que no sale no
-- tumba el pago.
create or replace function public.helios_charge_activated_receipt()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  for v_id in
    select i.charge_id
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.sequence = 0
      and i.paid_by_report_id = new.id
      and c.status = 'confirmed'
      and c.activated_at is not null
  loop
    begin
      perform public.helios_enqueue_charge_receipt(v_id);
    exception when others then
      raise warning 'No se encoló el comprobante de la orden % al activarse: %', v_id, sqlerrm;
    end;
  end loop;
  return null;
end;
$$;

drop trigger if exists payment_reports_activated_receipt on public.payment_reports;
create trigger payment_reports_activated_receipt
  after update of status on public.payment_reports
  for each row
  when (new.status = 'reconciled' and old.status is distinct from new.status)
  execute function public.helios_charge_activated_receipt();

-- La inicial nunca va a la clínica, tampoco con la política `on_collection`
-- (que `reconcile_payment` devengaría al cobrar cada cuota). Hoy ninguna
-- clínica la tiene y `admin_set_settlement_terms` la rechaza; esto lo
-- garantiza aunque un día se abra.
create or replace function public.helios_settlement_not_from_down_payment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.reason = 'on_collection'
     and exists (select 1 from public.installments i where i.id = new.installment_id and i.sequence = 0) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists settlements_not_from_down_payment on public.settlements;
create trigger settlements_not_from_down_payment
  before insert on public.settlements
  for each row
  when (new.reason = 'on_collection' and new.installment_id is not null)
  execute function public.helios_settlement_not_from_down_payment();

drop trigger if exists installments_activate_charge on public.installments;
create trigger installments_activate_charge
  after update of status on public.installments
  for each row
  when (new.sequence = 0 and new.status = 'paid' and old.status is distinct from new.status)
  execute function public.helios_installment_activates_charge();

-- 8. Sin inicial a tiempo, la orden se anula sola ───────────────────────────

/**
 * ¿Hay un pago de esta orden que llegó a tiempo y aún no se resolvió? Si lo
 * hay, se espera (docs/07: basta con que el pago llegue dentro del plazo):
 *  · un pago reportado (`reported`, `in_review`) de cualquiera de sus cuotas,
 *    sin tope: es dinero declarado; si tarda, sale la alerta
 *    `inicial_atascada` en superadmin › Alertas;
 *  · una captura o unos datos del paciente, llegados entre el registro de la
 *    orden y el plazo, que el lector aún lee o que esperan la referencia o el
 *    aviso del BNC (como mucho 24 h después del plazo: si el lector se cae,
 *    la orden no se queda colgada);
 *  · lo que el lector le pasó al equipo (`para_el_equipo`, o `sombra` con el
 *    lector a prueba) y no era una imagen cualquiera: se espera a que el
 *    equipo lo registre, como mucho 24 h después del plazo;
 *  · cualquier imagen o documento que mandó desde su teléfono entre el «Sí» y
 *    el plazo y que el lector no llegó a tomar (lector apagado, tope del día,
 *    teléfono de varios pacientes sin uno elegido…): el webhook guarda todo
 *    lo que entra en `whatsapp_inbound` antes de atenderlo. No cuentan la
 *    foto de la cédula ni lo que el lector ya decidió (eso lo dice su
 *    lectura). También como mucho 24 h después del plazo: lo ve el equipo en
 *    el inbox.
 */
create or replace function public.helios_down_payment_open(p_charge_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
           select 1
           from public.payment_reports r
           join public.payment_quote_items qi on qi.quote_id = r.quote_id
           join public.installments i on i.id = qi.installment_id
           where i.charge_id = c.id
             and r.status in ('reported', 'in_review'))
      or exists (
           select 1
           from public.payment_receipt_reads rr
           where rr.profile_id = c.user_id
             and rr.created_at >= c.created_at
             and rr.created_at <= c.down_payment_due_at
             and now() < c.down_payment_due_at + interval '24 hours'
             and (rr.status in ('pendiente', 'leyendo', 'esperando_referencia', 'esperando_aviso')
                  or (rr.status in ('para_el_equipo', 'sombra')
                      and rr.reason is distinct from 'no_es_comprobante')))
      or exists (
           select 1
           from public.whatsapp_inbound w
           join public.profiles p on p.id = c.user_id
           where w.from_phone = p.phone_e164
             and w.type in ('image', 'document')
             and w.received_at >= coalesce(c.answered_at, c.created_at)
             and w.received_at <= c.down_payment_due_at
             and now() < c.down_payment_due_at + interval '24 hours'
             and w.wa_message_id is distinct from c.answer_wa_message_id
             and not exists (select 1 from public.patient_id_photos f where f.wa_message_id = w.wa_message_id)
             and not exists (select 1 from public.payment_receipt_reads x where x.wa_message_id = w.wa_message_id))
  from public.charges c
  where c.id = p_charge_id;
$$;

/**
 * Anula una orden que no pagó su inicial a tiempo, con la misma maquinaria que
 * `admin_reverse_charge`: el asiento contrario pata por pata, las cuotas
 * fuera, el cupo de vuelta y la orden `reverted`, con el motivo en
 * `void_reason` y `down_payment_expired_at`. El trigger
 * `charges_cancel_messages_on_revert` cancela lo que tuviera en la cola. Avisa
 * al paciente y al médico. No toca una orden con algún pago aprobado.
 *
 * Los pagos rechazados de la inicial apuntan a sus cuotas (por su
 * cotización): esas líneas de la cotización se borran para poder borrar las
 * cuotas; el reporte rechazado queda, sin ellas.
 */
create or replace function public.helios_revert_unpaid_down_payment(p_charge_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_c      public.charges%rowtype;
  v_bdate  date := public.helios_business_date(now());
  v_tx     uuid;
  v_origen record;
  v_parte  record;
begin
  -- Los bloqueos en el mismo orden que `reconcile_payment` (las cuotas y,
  -- al activarse, la orden): primero las cuotas, luego la orden. Un pago que
  -- se registra a la vez apunta a estas cuotas y espera, o hace esperar.
  perform 1 from public.installments i where i.charge_id = p_charge_id order by i.id for update;
  -- La orden, sin esperar: si otro la tiene (el equipo revirtiéndola a mano,
  -- `admin_reverse_charge`, que bloquea la orden y luego las cuotas), esta
  -- pasada la salta y la siguiente vuelve a mirar. Así no hay abrazo mortal.
  select * into v_c from public.charges where id = p_charge_id for update skip locked;
  if not found or v_c.status <> 'awaiting_down_payment' then
    return false;
  end if;

  -- Con los bloqueos puestos, otra vez: ¿llegó un pago mientras tanto? Un
  -- pago no rechazado de estas cuotas (abierto o ya aprobado) la sostiene.
  if public.helios_down_payment_open(p_charge_id)
     or exists (select 1
                from public.payment_reports r
                join public.payment_quote_items qi on qi.quote_id = r.quote_id
                join public.installments i on i.id = qi.installment_id
                where i.charge_id = p_charge_id
                  and r.status not in ('rejected', 'duplicate')) then
    return false;
  end if;

  if exists (select 1 from public.installments i where i.charge_id = p_charge_id and i.status = 'paid') then
    raise warning 'La orden % espera la inicial pero ya tiene una cuota pagada: no se anula sola', p_charge_id;
    return false;
  end if;

  -- 1. El asiento contrario (una orden de capacitación no tiene).
  if exists (select 1 from ledger.transactions t
             where t.reference_id = p_charge_id and t.type <> 'manual_adjustment') then
    insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
    values ('manual_adjustment', 'reverse_charge:' || p_charge_id::text, v_bdate, p_charge_id,
            'Orden anulada: la inicial no se pagó a tiempo')
    returning id into v_tx;

    for v_origen in
      select e.account_id, e.debit, e.credit
      from ledger.transactions t
      join ledger.entries e on e.transaction_id = t.id
      where t.reference_id = p_charge_id
        and t.type <> 'manual_adjustment'
    loop
      insert into ledger.entries (transaction_id, account_id, debit, credit)
      values (v_tx, v_origen.account_id, v_origen.credit, v_origen.debit);
    end loop;
  end if;

  -- 2. Las cotizaciones: las que no llegaron a ser un pago, enteras; de las
  --    que sí (rechazadas o duplicadas), solo las líneas de esta orden.
  delete from public.payment_quotes q
  where not exists (select 1 from public.payment_reports r where r.quote_id = q.id)
    and exists (
      select 1
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id and i.charge_id = p_charge_id);

  delete from public.payment_quote_items qi
  using public.installments i
  where i.id = qi.installment_id and i.charge_id = p_charge_id;

  -- 3. Las cuotas y el cupo, a cada quien lo suyo.
  for v_parte in
    select i.user_id, sum(i.financed_usd) as financed, sum(i.amount_usd) as payable
    from public.installments i
    where i.charge_id = p_charge_id
    group by i.user_id
  loop
    update public.user_credit_blocks
       set charged_usd = greatest(charged_usd - v_parte.financed, 0),
           fee_usd     = greatest(fee_usd - (v_parte.payable - v_parte.financed), 0)
     where user_id = v_parte.user_id and closed_at is null;
  end loop;

  delete from public.installments where charge_id = p_charge_id;

  -- 4. Lo que se hubiera devengado a la clínica y no se pagó (no debería
  --    haber nada: se devenga al activarse).
  delete from public.settlements where charge_id = p_charge_id and status = 'pending';

  -- 5. La orden.
  update public.charges
     set status = 'reverted',
         void_reason = 'La inicial no se pagó a tiempo',
         voided_at = now(),
         down_payment_expired_at = now()
   where id = p_charge_id;

  -- 6. Los avisos.
  perform public.helios_tell_patient(v_c.user_id,
    public.helios_patient_decision_text(p_charge_id, 'inicial_vencida'),
    '[{"id":"paciente:ayuda","title":"Hablar con alguien"}]'::jsonb);
  perform public.helios_notify_staff_of_charge(p_charge_id, 'inicial_vencida');

  return true;
end;
$$;

/** El cron de cada minuto: las órdenes cuyo plazo pasó, sin un pago abierto. */
create or replace function public.helios_revert_unpaid_down_payments()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_n  integer := 0;
begin
  -- La inicial vence «hoy» mientras la orden la espera: si un pago abierto la
  -- hace cruzar la medianoche, su fecha avanza con el día. Así nunca sale
  -- vencida ni en atraso en ningún listado ni métrica que mire `due_date`.
  update public.installments i
     set due_date = public.helios_business_date(now())
    from public.charges c
   where c.id = i.charge_id
     and c.status = 'awaiting_down_payment'
     and i.sequence = 0
     and i.status = 'pending'
     and i.due_date < public.helios_business_date(now());

  for v_id in
    select c.id from public.charges c
    where c.status = 'awaiting_down_payment'
      and c.down_payment_due_at <= now()
      and not public.helios_down_payment_open(c.id)
    order by c.down_payment_due_at
    limit 200
  loop
    begin
      if public.helios_revert_unpaid_down_payment(v_id) then
        v_n := v_n + 1;
      end if;
    exception when others then
      raise warning 'No se pudo anular la orden % sin inicial: %', v_id, sqlerrm;
    end;
  end loop;
  return v_n;
end;
$$;

-- Todo lo nuevo es interno: lo llaman funciones `security definer`, triggers
-- y el cron, nunca la API.
revoke all on function public.helios_down_payment_pct_at(date) from public, anon, authenticated;
revoke all on function public.helios_down_payment_minutes() from public, anon, authenticated;
revoke all on function public.helios_charge_down_payment() from public, anon, authenticated;
revoke all on function public.helios_installment_split(numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.helios_activate_charge(uuid) from public, anon, authenticated;
revoke all on function public.helios_installment_activates_charge() from public, anon, authenticated;
revoke all on function public.helios_charge_activated_receipt() from public, anon, authenticated;
revoke all on function public.helios_settlement_not_from_down_payment() from public, anon, authenticated;
revoke all on function public.helios_down_payment_open(uuid) from public, anon, authenticated;
revoke all on function public.helios_revert_unpaid_down_payment(uuid) from public, anon, authenticated;
revoke all on function public.helios_revert_unpaid_down_payments() from public, anon, authenticated;

select cron.schedule('helios_revert_unpaid_down_payments', '* * * * *',
                     $$select public.helios_revert_unpaid_down_payments();$$);


-- 9. Qué cuotas paga un monto: la inicial primero, sin adivinar ────────────
-- `helios_receipt_tramo` (el lector de comprobantes y los datos con su aviso
-- del BNC) repartía el monto entre todas las cuotas pendientes por fecha. Con
-- la inicial eso podía pagar la cuota equivocada y dejar que otra orden se
-- anulara. Ahora el monto se compara con estas opciones:
--   · cada orden que espera la inicial: su inicial sola, y la orden completa
--     (la inicial y sus 2 cuotas);
--   · lo de siempre: las cuotas de las órdenes activas, por fecha.
-- Las opciones de una orden en espera son «fuertes» (tienen plazo). Lo de
-- siempre es fuerte si toca alguna cuota vencida o que vence ese día; si solo
-- adelanta cuotas que aún no vencen, es «débil» y pierde ante una inicial
-- (lo normal es pagar la inicial, no adelantar).
--   1. Una sola opción fuerte cuadra: esa.
--   2. Más de una fuerte: no se adivina. Null, y la lectura va al equipo
--      (`para_el_equipo`, que sostiene la orden como pago abierto).
--   3. Ninguna fuerte y la débil cuadra: la débil (adelantar cuotas).
--   4. Nada: el reparto de siempre con las iniciales primero, luego las
--      cuotas de las órdenes activas y al final las de las que esperan
--      (p. ej. una inicial y una cuota vencida juntas).
-- Sin órdenes esperando la inicial, exactamente lo de antes.

/** El reparto de siempre sobre una lista ordenada: el primer tramo que cuadra. */
create or replace function public.helios_receipt_tramo_en(
  p_user uuid, p_paid_on date, p_amount_ves numeric, p_ids uuid[])
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids   uuid[] := '{}'::uuid[];
  v_id    uuid;
  v_bs    numeric;
  v_menos numeric := public.helios_parameter('payment_margin_under_ves', 10);
begin
  foreach v_id in array coalesce(p_ids, '{}'::uuid[]) loop
    v_ids := v_ids || v_id;
    v_bs := public.helios_installments_ves(p_user, v_ids, p_paid_on);
    if v_bs is null then
      return null;
    end if;
    if public.helios_monto_cuadra(p_amount_ves, v_bs) then
      return v_ids;
    end if;
    -- Cada cuota suma: si lo pagado ya no llega ni con el margen por debajo,
    -- ningún tramo más largo cuadra.
    exit when v_bs - v_menos > p_amount_ves;
  end loop;
  return null;
end;
$$;

/** ¿Este conjunto de cuotas, entero, cuadra con el monto? */
create or replace function public.helios_receipt_cuadra(
  p_user uuid, p_paid_on date, p_amount_ves numeric, p_ids uuid[])
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_bs numeric;
begin
  if coalesce(cardinality(p_ids), 0) = 0 then
    return false;
  end if;
  v_bs := public.helios_installments_ves(p_user, p_ids, p_paid_on);
  return v_bs is not null and public.helios_monto_cuadra(p_amount_ves, v_bs);
end;
$$;

create or replace function public.helios_receipt_tramo(p_user uuid, p_paid_on date, p_amount_ves numeric)
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_dia      date := coalesce(p_paid_on, public.helios_business_date(now()));
  v_ceros    uuid[];
  v_resto    uuid[];
  v_espera   uuid[];
  v_orden    record;
  v_fuertes  integer := 0;
  v_elegida  uuid[];
  v_tramo    uuid[];
begin
  if p_amount_ves is null or p_amount_ves <= 0 then
    return null;
  end if;

  -- Las cuotas sin un pago reportado sin resolver: las iniciales en espera
  -- (de la orden más vieja a la nueva), las cuotas de las órdenes activas (en
  -- el orden de siempre) y las cuotas 1 y 2 de las órdenes en espera.
  select coalesce(array_agg(t.id order by t.creada, t.sequence) filter (where t.espera and t.sequence = 0), '{}'::uuid[]),
         coalesce(array_agg(t.id order by t.due_date, t.creada, t.sequence) filter (where not t.espera), '{}'::uuid[]),
         coalesce(array_agg(t.id order by t.creada, t.sequence) filter (where t.espera and t.sequence > 0), '{}'::uuid[])
    into v_ceros, v_resto, v_espera
  from (
    select i.id, i.charge_id, i.sequence, i.due_date, c.created_at as creada,
           (c.status = 'awaiting_down_payment') as espera
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.user_id = p_user
      and i.status = 'pending'
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review'))
  ) t;

  -- 1. Cada orden en espera: su inicial sola y la orden completa.
  for v_orden in
    select t.charge_id,
           array_agg(t.id order by t.sequence) filter (where t.sequence = 0) as cero,
           array_agg(t.id order by t.sequence) as completa
    from (
    select i.id, i.charge_id, i.sequence, i.due_date, c.created_at as creada,
           (c.status = 'awaiting_down_payment') as espera
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.user_id = p_user
      and i.status = 'pending'
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review'))
  ) t
    where t.espera
    group by t.charge_id
    having bool_or(t.sequence = 0)
  loop
    if public.helios_receipt_cuadra(p_user, p_paid_on, p_amount_ves, v_orden.cero) then
      v_fuertes := v_fuertes + 1;
      v_elegida := v_orden.cero;
    elsif cardinality(v_orden.completa) > 1
          and public.helios_receipt_cuadra(p_user, p_paid_on, p_amount_ves, v_orden.completa) then
      v_fuertes := v_fuertes + 1;
      v_elegida := v_orden.completa;
    end if;
  end loop;

  -- Lo de siempre, con las órdenes activas: fuerte si toca algo vencido o que
  -- vence ese día.
  v_tramo := public.helios_receipt_tramo_en(p_user, p_paid_on, p_amount_ves, v_resto);
  if v_tramo is not null
     and exists (select 1 from public.installments i where i.id = any (v_tramo) and i.due_date <= v_dia) then
    v_fuertes := v_fuertes + 1;
    v_elegida := v_tramo;
    v_tramo := null;
  end if;

  if v_fuertes = 1 then
    return v_elegida;
  elsif v_fuertes > 1 then
    return null;
  end if;

  -- 3. Solo adelantar cuotas que aún no vencen.
  if v_tramo is not null then
    return v_tramo;
  end if;

  -- 4. Nada solo: el reparto de siempre, con las iniciales primero.
  if cardinality(v_ceros) = 0 then
    return null;
  end if;
  return public.helios_receipt_tramo_en(p_user, p_paid_on, p_amount_ves, v_ceros || v_resto || v_espera);
end;
$$;

revoke all on function public.helios_receipt_tramo_en(uuid, date, numeric, uuid[]) from public, anon, authenticated;
revoke all on function public.helios_receipt_cuadra(uuid, date, numeric, uuid[]) from public, anon, authenticated;


-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_patient_decision(uuid,text,text,text)
-- Con inicial, el «Sí» deja la orden esperando la inicial: devuelve el estado nuevo y su
-- plazo, y el aviso al médico sale al activarse (helios_activate_charge).
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_patient_decision(p_charge_id uuid, p_decision text, p_from_phone text, p_wa_message_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_c        public.charges%rowtype;
  v_p        public.profiles%rowtype;
  v_decision text := lower(btrim(coalesce(p_decision, '')));
  v_msg_id   text := nullif(btrim(coalesce(p_wa_message_id, '')), '');
  v_ok       boolean;
  v_limit    numeric(18,4);
begin
  if v_decision not in ('si', 'no') or v_msg_id is null then
    return jsonb_build_object('ok', false, 'reason', 'peticion_invalida');
  end if;

  -- Un reintento del mismo mensaje: lo que ya se decidió.
  select * into v_c from public.charges where answer_wa_message_id = v_msg_id;
  if found then
    return jsonb_build_object('ok', v_c.status in ('confirmed', 'declined', 'awaiting_down_payment'), 'duplicate', true,
                              'charge_id', v_c.id, 'status', v_c.status::text,
                              'order_number', v_c.order_number);
  end if;

  select * into v_c from public.charges where id = p_charge_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_existe');
  end if;

  if v_c.status <> 'pending' then
    -- NUEVO (2026-10-19): pulsó el botón de una orden que ya venció.
    if v_c.status = 'expired' and v_c.answered_at is null then
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'vencida'));
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_pendiente', 'status', v_c.status::text);
  end if;

  if v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'vencida');
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'vencida'));
    return jsonb_build_object('ok', false, 'reason', 'vencida', 'status', 'expired');
  end if;

  select * into v_p from public.profiles where id = v_c.user_id for update;

  if regexp_replace(coalesce(p_from_phone, ''), '\D', '', 'g')
     <> regexp_replace(coalesce(v_p.phone_e164, '-'), '\D', '', 'g') then
    return jsonb_build_object('ok', false, 'reason', 'otro_telefono');
  end if;

  -- NUEVO (2026-11-02): sin foto de su cédula, el «Sí» no confirma: se le
  -- pide la foto y es la foto la que confirma (`helios_patient_id_photo`).
  -- La respuesta no se anota: la orden sigue pendiente, con su plazo.
  if v_decision = 'si' and v_p.id_photo_at is null then
    update public.charges
       set id_photo_requested_at = coalesce(id_photo_requested_at, now())
     where id = v_c.id;
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'pide_cedula'));
    return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'pending',
                              'reason', 'pide_cedula', 'order_number', v_c.order_number);
  end if;

  update public.charges
     set answered_at = now(), answer_wa_message_id = v_msg_id
   where id = v_c.id;

  if v_decision = 'no' then
    update public.charges
       set status = 'declined', decline_reason = 'paciente'
     where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'rechazada');
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'no'));
    return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'declined',
                              'decline_reason', 'paciente', 'order_number', v_c.order_number);
  end if;

  -- «Sí»: revalidar lo que pudo cambiar mientras esperaba.
  v_ok := v_p.status = 'active'
          and not v_p.is_blacklisted
          and not public.helios_spend_blocked(v_p.id)
          and public.can_take_debt(v_p.id);

  if v_ok then
    begin
      perform public.helios_assert_merchant_operating(v_c.merchant_id);
    exception when others then
      v_ok := false;
    end;
  end if;

  if v_ok then
    -- El cupo ocupado incluye ya la reserva de ESTA orden.
    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_ok := public.helios_credit_used_usd(v_p.id) <= coalesce(v_limit, 0);
  end if;

  if v_ok then
    begin
      perform public.helios_finalize_charge(v_c.id, 'whatsapp', null);
    exception when others then
      -- Se deshace todo lo de la confirmación; la orden se rechaza abajo.
      v_ok := false;
    end;
  end if;

  if not v_ok then
    update public.charges
       set status = 'declined', decline_reason = 'no_disponible'
     where id = v_c.id;
    perform public.helios_notify_staff_of_charge(v_c.id, 'rechazada');
    -- Al paciente: si debe una cuota, que la pague; si no, sin detalles.
    if public.helios_available_blocked_reason(v_p.id) = 'cuota_vencida' then
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'cuota_vencida'),
                                         '[{"id":"paciente:pagar","title":"Pagar mi cuota"}]'::jsonb);
    else
      perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'no_disponible'),
                                         '[{"id":"paciente:ayuda","title":"Hablar con alguien"}]'::jsonb);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'no_disponible', 'charge_id', v_c.id,
                              'status', 'declined', 'order_number', v_c.order_number);
  end if;

  -- NUEVO (2026-11-12, la inicial): con inicial, la orden espera el pago y al
  -- médico se le avisa cuando se apruebe (`helios_activate_charge`).
  select * into v_c from public.charges where id = v_c.id;
  if v_c.status = 'awaiting_down_payment' then
    return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'awaiting_down_payment',
                              'down_payment_due_at', v_c.down_payment_due_at,
                              'order_number', v_c.order_number);
  end if;

  perform public.helios_notify_staff_of_charge(v_c.id, 'aceptada');
  return jsonb_build_object('ok', true, 'charge_id', v_c.id, 'status', 'confirmed',
                            'order_number', v_c.order_number);
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_patient_id_photo(text,text,text,text)
-- El acuse de la cédula también sale cuando la orden queda esperando la inicial.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_patient_id_photo(p_from_phone text, p_wa_message_id text, p_media_id text, p_mime text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_msg   text := nullif(btrim(coalesce(p_wa_message_id, '')), '');
  v_media text := nullif(btrim(coalesce(p_media_id, '')), '');
  v_mime  text := lower(btrim(coalesce(p_mime, '')));
  v_tel   text := regexp_replace(coalesce(p_from_phone, ''), '\D', '', 'g');
  v_c     public.charges%rowtype;
  v_foto  public.patient_id_photos%rowtype;
  v_ext   text;
  v_ruta  text;
  v_res   jsonb;
  v_acuse uuid;
begin
  if v_msg is null or v_tel = '' then
    return jsonb_build_object('ok', false, 'handled', false, 'reason', 'peticion_invalida');
  end if;

  -- Un reintento del mismo mensaje.
  select * into v_foto from public.patient_id_photos where wa_message_id = v_msg;
  if found then
    return jsonb_build_object('ok', true, 'handled', true, 'duplicate', true, 'id_photo_id', v_foto.id,
                              'charge_id', v_foto.charge_id);
  end if;

  select c.* into v_c
  from public.charges c
  join public.profiles p on p.id = c.user_id
  where regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = v_tel
    and c.id_photo_requested_at is not null
    and c.answered_at is null
    and (c.status = 'pending' or (c.status = 'expired' and p.id_photo_at is null))
    and c.id_photo_requested_at > now() - interval '24 hours'
  order by c.id_photo_requested_at desc
  limit 1
  for update of c;

  if not found then
    return jsonb_build_object('ok', false, 'handled', false, 'reason', 'no_esperada');
  end if;

  if v_media is null or v_mime not in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf') then
    perform public.helios_tell_patient(v_c.user_id, public.helios_patient_decision_text(v_c.id, 'pide_cedula'));
    return jsonb_build_object('ok', false, 'handled', true, 'reason', 'formato', 'charge_id', v_c.id);
  end if;

  v_ext := case v_mime when 'image/png' then 'png' when 'image/webp' then 'webp'
                       when 'image/heic' then 'heic' when 'application/pdf' then 'pdf' else 'jpg' end;
  v_ruta := v_c.user_id || '/' || regexp_replace(v_msg, '[^A-Za-z0-9._-]', '_', 'g') || '.' || v_ext;

  insert into public.patient_id_photos (profile_id, charge_id, wa_message_id, phone_e164, media_id, mime, storage_path)
  values (v_c.user_id, v_c.id, v_msg, coalesce(public.helios_wa_e164(p_from_phone), p_from_phone), v_media, v_mime, v_ruta)
  returning * into v_foto;

  update public.profiles
     set id_photo_path = v_ruta, id_photo_at = now(), id_photo_wa_message_id = v_msg
   where id = v_c.user_id;

  -- El mismo camino que el «Sí»: con la foto ya guardada, confirma.
  v_res := public.helios_patient_decision(v_c.id, 'si', p_from_phone, v_msg);

  -- El acuse, antes que la bienvenida que encoló la confirmación: salen por
  -- orden de `next_attempt_at` y las dos tienen el mismo now().
  -- NUEVO (2026-11-12, la inicial): también si queda esperando la inicial.
  if v_res ->> 'status' in ('confirmed', 'awaiting_down_payment') and public.helios_whatsapp_window_open(p_from_phone) then
    begin
      v_acuse := public.helios_whatsapp_patient_text(
        p_from_phone, public.helios_patient_decision_text(v_c.id, 'cedula_recibida'), v_c.user_id);
      update public.outbound_messages
         set next_attempt_at = now() - interval '1 second'
       where id = v_acuse;
    exception when others then
      raise warning 'No se encoló el acuse de la cédula de %: %', v_c.user_id, sqlerrm;
    end;
  end if;

  return v_res || jsonb_build_object('handled', true, 'id_photo_id', v_foto.id);
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_charge_confirmation(uuid)
-- La pregunta con inicial es otra plantilla (confirmar_pago_con_inicial); una orden que espera
-- la inicial ya fue aceptada.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_charge_confirmation(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_c      public.charges%rowtype;
  v_m      public.outbound_messages%rowtype;
  v_first  public.outbound_messages%rowtype;
  v_phone  text;
  v_n      integer;
  v_status text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return null;
  end if;

  select * into v_m from public.outbound_messages
  where charge_id = p_charge_id and template_key in ('confirmar_financiamiento', 'confirmar_pago_con_inicial')
  order by created_at desc, id desc limit 1;

  if v_m.id is null and v_c.status not in ('pending', 'declined', 'expired') then
    return null;
  end if;

  select * into v_first from public.outbound_messages
  where charge_id = p_charge_id and template_key in ('confirmar_financiamiento', 'confirmar_pago_con_inicial')
  order by created_at, id limit 1;

  select count(*) into v_n
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key in ('confirmar_financiamiento', 'confirmar_pago_con_inicial')
    and o.created_at >= public.helios_business_day_start()
    and o.id <> v_first.id;

  select p.phone_e164 into v_phone from public.profiles p where p.id = v_c.user_id;

  v_status := case
    when v_c.status in ('confirmed', 'reverted', 'awaiting_down_payment') then 'aceptada'
    when v_c.status = 'declined' then 'rechazada'
    when v_c.status = 'expired' or (v_c.status = 'pending' and v_c.expires_at <= now()) then 'vencida'
    when v_c.status = 'voided' then 'rechazada'
    when v_m.id is null or v_m.status = 'pendiente' then 'por_enviar'
    when v_m.status = 'enviado' then
      case v_m.last_event when 'read' then 'leida' when 'delivered' then 'entregada' else 'enviada' end
    else 'fallida'
  end;

  return jsonb_build_object(
    'status', v_status,
    'telefono_enmascarado', public.helios_mask_phone(coalesce(v_m.recipient, v_phone)),
    'sent_at', v_m.sent_at,
    'answered_at', v_c.answered_at,
    'resends_today', coalesce(v_n, 0)
  );
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.staff_resend_confirmation(uuid)
-- Cuenta los reenvíos de las dos preguntas y, al reabrir una vencida, la orden toma la
-- inicial vigente hoy (como toma la tasa, la comisión y las condiciones de hoy).
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.staff_resend_confirmation(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_me     uuid := auth.uid();
  v_c      public.charges%rowtype;
  v_p      public.profiles%rowtype;
  v_first  uuid;
  v_n      integer;
  v_max    integer := public.helios_confirmation_resends_per_day();
  v_limit  numeric(18,4);
  v_avail  numeric(18,4);
  v_min    numeric := public.helios_min_charge_usd();
  v_terms  public.merchant_terms%rowtype;
  v_amt    jsonb;
  v_b      jsonb;
  v_bc     jsonb;
  v_bdate  date;
  v_comm   numeric(18,4);
  v_fx     numeric;
  v_base_c numeric(18,4);
  v_base   numeric(18,4);
  v_msg    uuid;
  v_reopen boolean := false;
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_c from public.charges where id = p_charge_id for update;

  -- La misma regla que el detalle: el gerente, los de su clínica; la
  -- secretaria, los que registró. El mismo error exista o no.
  if not found or not exists (
    select 1 from public.merchant_users mu
    where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
      and (mu.role = 'gerente' or (mu.role = 'cajero' and v_c.requested_by = v_me))
  ) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  if v_c.status = 'pending' and v_c.expires_at <= now() then
    update public.charges set status = 'expired' where id = v_c.id returning * into v_c;
  end if;

  if v_c.status not in ('pending', 'expired') then
    raise exception 'Esta orden ya no se puede reenviar' using errcode = '22023';
  end if;

  if not public.helios_whatsapp_api_ready() then
    raise exception 'No podemos escribirle a este paciente por WhatsApp. Escribe a Helios'
      using errcode = '22023';
  end if;

  -- Reenvíos de hoy: las preguntas de hoy menos la primera de todas.
  select o.id into v_first
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key in ('confirmar_financiamiento', 'confirmar_pago_con_inicial')
  order by o.created_at, o.id limit 1;

  select count(*) into v_n
  from public.outbound_messages o
  where o.charge_id = p_charge_id and o.template_key in ('confirmar_financiamiento', 'confirmar_pago_con_inicial')
    and o.created_at >= public.helios_business_day_start()
    and o.id is distinct from v_first;

  if v_n >= v_max then
    raise exception 'Ya reenviaste esta solicitud % veces hoy. Inténtalo mañana', v_max
      using errcode = '22023';
  end if;

  if v_c.status = 'expired' then
    v_reopen := true;

    perform public.helios_assert_merchant_operating(v_c.merchant_id);

    select * into v_p from public.profiles where id = v_c.user_id for update;
    if v_p.status <> 'active'
       or v_p.is_blacklisted
       or public.helios_spend_blocked(v_p.id)
       or not public.can_take_debt(v_p.id) then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;

    if exists (
      select 1 from public.charges c
      where c.user_id = v_p.id and c.id <> v_c.id and c.status = 'pending' and c.expires_at > now()
    ) then
      raise exception 'Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza'
        using errcode = '22023';
    end if;

    -- El médico cobró en su moneda y eso no cambia; lo que cambia es la tasa
    -- con la que se pasa a dólares, que es la de hoy.
    v_bdate  := public.helios_business_date(now());
    v_fx     := public.helios_usd_per_unit(v_c.currency, v_bdate);
    v_base_c := coalesce(v_c.base_cur, v_c.base_usd, v_c.amount_usd);
    v_base   := round(v_base_c * v_fx, 2);

    select l.monthly_limit_usd into v_limit from public.levels l where l.level = v_p.level;
    v_avail := greatest(coalesce(v_limit, 0) - public.helios_credit_used_usd(v_p.id), 0);
    if v_avail < v_min then
      raise exception '%', public.helios_not_available_message() using errcode = '22023';
    end if;
    if v_base > v_avail then
      raise exception 'El monto supera lo disponible (%).',
        public.helios_money_cur_text(trunc(v_avail / v_fx, 2), v_c.currency) using errcode = '22023';
    end if;

    select * into v_terms from public.helios_terms_at(v_c.merchant_id, v_bdate);
    if v_terms.id is null then
      raise exception 'La clínica no tiene condiciones de liquidación: pídele a Helios que las configure'
        using errcode = '22023';
    end if;

    v_amt  := public.helios_charge_amounts(v_base_c, v_c.currency, v_fx, coalesce(v_terms.commission_pct, 0));
    v_b    := v_amt->'usd';
    v_bc   := v_amt->'cur';
    v_comm := public.helios_staff_commission_for(v_c.merchant_id, v_bdate);

    update public.charges
       set status = 'pending',
           business_date = v_bdate,
           down_payment_pct = public.helios_down_payment_pct_at(v_bdate),  -- NUEVO (2026-11-12, la inicial)
           expires_at = now() + make_interval(mins => public.helios_patient_confirmation_minutes()),
           amount_usd = (v_b->>'consumer_total_usd')::numeric,
           base_usd = (v_b->>'base_usd')::numeric,
           vat_pct = (v_b->>'vat_pct')::numeric,
           vat_usd = (v_b->>'vat_usd')::numeric,
           consumer_fee_pct = (v_b->>'consumer_fee_pct')::numeric,
           consumer_fee_usd = (v_b->>'consumer_fee_usd')::numeric,
           consumer_fee_vat_usd = (v_b->>'consumer_fee_vat_usd')::numeric,
           merchant_fee_pct = (v_b->>'merchant_fee_pct')::numeric,
           merchant_fee_usd = (v_b->>'merchant_fee_usd')::numeric,
           merchant_fee_vat_usd = (v_b->>'merchant_fee_vat_usd')::numeric,
           merchant_net_usd = (v_b->>'merchant_net_usd')::numeric,
           fx_usd_per_unit = (v_amt->>'fx_usd_per_unit')::numeric,
           amount_cur = (v_bc->>'consumer_total_usd')::numeric,
           base_cur = (v_bc->>'base_usd')::numeric,
           consumer_fee_cur = (v_bc->>'consumer_fee_usd')::numeric,
           consumer_fee_vat_cur = (v_bc->>'consumer_fee_vat_usd')::numeric,
           merchant_net_cur = (v_bc->>'merchant_net_usd')::numeric,
           terms_version_id = (select t.id from public.terms_versions t
                                where t.is_current order by t.published_at desc limit 1),
           staff_commission_usd = nullif(v_comm, 0),
           commission_staff_id = case when v_comm > 0 then v_c.requested_by end
     where id = v_c.id;
  end if;

  v_msg := public.helios_enqueue_confirmation(v_c.id);

  perform audit.log(v_me, 'charge.confirmation_resent', p_charge_id,
    jsonb_build_object('message_id', v_msg, 'merchant_id', v_c.merchant_id, 'reopened', v_reopen));

  return public.helios_charge_for_staff(p_charge_id);
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_charge_reverse_blocker(uuid)
-- El equipo también puede revertir a mano una orden que espera la inicial.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_charge_reverse_blocker(p_charge_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_status   public.charge_status;
  v_deudores integer;
  v_n        integer;
  v_quien    text;
  v_caduca   timestamptz;
begin
  select status into v_status from public.charges where id = p_charge_id;
  if not found then
    return 'No se puede revertir: el consumo no existe.';
  end if;

  -- NUEVO (2026-11-12, la inicial): también una que espera la inicial.
  if v_status not in ('confirmed', 'awaiting_down_payment') then
    return format('No se puede revertir: el consumo está %s y solo se revierte uno confirmado.',
      case v_status
        when 'pending'  then 'pendiente'
        when 'voided'   then 'anulado'
        when 'reverted' then 'revertido'
        else v_status::text
      end);
  end if;

  -- Cuántas personas se reparten el cargo. En un consumo de grupo quien frena
  -- la reversión puede ser cualquiera de ellas, y el super admin está mirando
  -- la ficha de quien puso la cuenta: el texto dice quién es.
  select count(distinct user_id) into v_deudores
  from public.installments where charge_id = p_charge_id;

  -- 1. Cuotas pagadas: revertir sería devolver dinero.
  select count(*), string_agg(distinct pr.full_name, ', ')
  into v_n, v_quien
  from public.installments i
  left join public.profiles pr on pr.id = i.user_id
  where i.charge_id = p_charge_id and i.status = 'paid';

  if v_n > 0 then
    return case when v_deudores > 1 and v_quien is not null then
      format('No se puede revertir: ya hay cuotas pagadas (%s), y revertirlo obligaría a devolver dinero.', v_quien)
    else
      'No se puede revertir: ya hay cuotas pagadas, y revertirlo obligaría a devolver dinero.'
    end;
  end if;

  -- 2. Un pago reportado, en cualquier estado: el reporte apunta a su
  --    cotización y la cotización a las cuotas, así que tampoco se podrían
  --    borrar.
  select count(*), string_agg(distinct pr.full_name, ', ')
  into v_n, v_quien
  from public.payment_reports r
  join public.payment_quote_items qi on qi.quote_id = r.quote_id
  join public.installments i on i.id = qi.installment_id
  left join public.profiles pr on pr.id = i.user_id
  where i.charge_id = p_charge_id;

  if v_n > 0 then
    return case when v_deudores > 1 and v_quien is not null then
      format('No se puede revertir: %s reportó un pago para una de sus cuotas.', v_quien)
    else
      'No se puede revertir: hay un pago reportado para una de sus cuotas.'
    end;
  end if;

  -- 3. Al local ya se le transfirió algo. Decisión de Javier (2026-09-25): no
  --    se revierte; compensarlo con el local es otra operación, a mano.
  if exists (
    select 1 from public.settlements
    where charge_id = p_charge_id and status in ('paid', 'partial')
  ) then
    return 'No se puede revertir: al local ya se le transfirió su parte.';
  end if;

  -- 4. Una cotización vigente y sin reportar: la persona abrió «Pagar» y
  --    puede estar transfiriendo ahora mismo con ella. Borrarla dejaría su
  --    reporte sin cotización. Las caducadas no frenan: el servidor las borra
  --    al revertir, porque `report_payment` ya no las acepta.
  select count(distinct q.id), string_agg(distinct pr.full_name, ', '), max(q.valid_until)
  into v_n, v_quien, v_caduca
  from public.payment_quotes q
  join public.payment_quote_items qi on qi.quote_id = q.id
  join public.installments i on i.id = qi.installment_id
  left join public.profiles pr on pr.id = q.user_id
  where i.charge_id = p_charge_id
    and q.valid_until > now()
    and not exists (select 1 from public.payment_reports r where r.quote_id = q.id);

  if v_n > 0 then
    return format(
      'No se puede revertir: %s tiene un pago abierto sin reportar. Se podrá revertir cuando caduque, a las %s.',
      case when v_deudores > 1 and v_quien is not null then v_quien else 'la persona' end,
      to_char(v_caduca at time zone 'America/Caracas', 'HH24:MI'));
  end if;

  return null;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_in_arrears(uuid)
-- La inicial nunca deja «en mora»: si no se paga, la orden se anula sola.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_in_arrears(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select exists (
    select 1 from public.installments
    where user_id = p_user
      and status = 'pending'
      and due_date < public.helios_business_date(now())
      and sequence > 0  -- NUEVO (2026-11-12, la inicial): la inicial no cuenta
  );
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.can_take_debt(uuid)
-- La inicial nunca deja «en mora»: si no se paga, la orden se anula sola.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.can_take_debt(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    exists (select 1 from public.profiles where id = p_user and status = 'active')
    -- NUEVO: mantenimiento, sanción del equipo o lista de espera.
    and not public.helios_spend_blocked(p_user)
    and not exists (
      select 1 from public.installments
      where user_id = p_user
        and status = 'pending'
        and due_date < public.helios_business_date(now())
        and sequence > 0  -- NUEVO (2026-11-12, la inicial): la inicial no cuenta
    );
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.process_mora_batch(uuid,integer)
-- La inicial no entra en el lote de la mora.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_mora_batch(p_after uuid, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_bd    date := public.helios_business_date(now());
  v_row   record;
  v_last  uuid := p_after;
  v_count integer := 0;
begin
  for v_row in
    select i.user_id
      from public.installments i
     where i.status = 'pending' and i.due_date < v_bd and i.user_id > p_after
       and i.sequence > 0  -- NUEVO (2026-11-12, la inicial)
    union
    select p.id
      from public.profiles p
     where p.status in ('frozen', 'suspended') and p.id > p_after
    order by 1
    limit p_limit
  loop
    perform public.recompute_profile_mora_state(v_row.user_id);
    v_last  := v_row.user_id;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('last', v_last, 'processed', v_count);
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.recompute_profile_mora_state(uuid)
-- Ni los días de atraso ni el cargo por atraso miran la inicial.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.recompute_profile_mora_state(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_status       public.profile_status;
  v_level        smallint;
  v_new_level    smallint;
  v_max_days_late integer;
  v_inst         record;
  v_fee_id       uuid;
  v_fee_amount   numeric(18,4);
  v_fees         integer := 0;
  v_fees_usd     numeric(18,4) := 0;
begin
  select status, level into v_status, v_level
  from public.profiles where id = p_user_id for update;

  if not found or v_status = 'expelled' then
    -- Terminal: requiere revisión manual del super admin (D-10, sin decidir).
    return;
  end if;

  select coalesce(max(public.helios_business_date(now()) - i.due_date), 0)
    into v_max_days_late
  from public.installments i
  where i.user_id = p_user_id
    and i.status = 'pending'
    and i.sequence > 0  -- NUEVO (2026-11-12, la inicial)
    and i.due_date < public.helios_business_date(now());

  if v_max_days_late <= 0 then
    -- Sin mora. Si venía bloqueado, se restablece el acceso — pero el nivel
    -- perdido no se recupera solo aquí: eso lo hace `evaluate_level` cuando
    -- pasa el enfriamiento.
    if v_status in ('frozen', 'suspended') then
      update public.profiles set status = 'active', updated_at = now() where id = p_user_id;
    end if;
    return;
  end if;

  -- ── NUEVO: un cargo por cada cuota pasada de la gracia ───────────────────
  for v_inst in
    select i.id, (public.helios_business_date(now()) - i.due_date) as days_late
    from public.installments i
    where i.user_id = p_user_id
      and i.status = 'pending'
      and i.sequence > 0  -- NUEVO (2026-11-12, la inicial)
      and (public.helios_business_date(now()) - i.due_date) > public.helios_late_fee_grace_days()
    order by i.due_date
  loop
    v_fee_id := public.charge_late_fee(v_inst.id, v_inst.days_late);

    -- Null cuando esa cuota ya lo tenía: el cargo es uno por cuota, corra el
    -- cron las veces que corra.
    if v_fee_id is not null then
      select amount_usd into v_fee_amount from public.late_fees where id = v_fee_id;
      v_fees     := v_fees + 1;
      v_fees_usd := v_fees_usd + v_fee_amount;
    end if;
  end loop;

  -- Un solo aviso por corrida, con el total. La deuda de alguien no puede
  -- crecer en silencio, pero tampoco a base de tres empujones seguidos.
  if v_fees > 0 then
    perform public.notify(
      p_user_id,
      'late_fee_charged',
      'Cargo por mora',
      case when v_fees = 1 then
        format(
          'Se sumaron $%s a tu deuda por una cuota con más de %s días de retraso. Va incluido en tu próximo pago.',
          trim(to_char(v_fees_usd, 'FM999999990.00')),
          public.helios_late_fee_grace_days()
        )
      else
        format(
          'Se sumaron $%s a tu deuda: $%s por cada una de tus %s cuotas con más de %s días de retraso. Van incluidos en tu próximo pago.',
          trim(to_char(v_fees_usd, 'FM999999990.00')),
          trim(to_char(public.helios_late_fee_usd(), 'FM999999990.00')),
          v_fees,
          public.helios_late_fee_grace_days()
        )
      end,
      jsonb_build_object(
        'late_fee_count', v_fees,
        'amount_usd', v_fees_usd,
        'days_late', v_max_days_late
      )
    );
  end if;
  -- ─────────────────────────────────────────────────────────────────────────

  if v_max_days_late > public.helios_mora_expulsion_days() then
    if v_status <> 'expelled' then
      update public.profiles
        set status = 'expelled', is_blacklisted = true, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_level, 'expelled');

      perform public.charge_off_user_debt(p_user_id);
    end if;
    return;
  end if;

  if v_max_days_late >= public.helios_mora_demotion_days() then
    if v_status <> 'suspended' then
      v_new_level := greatest(1, v_level - 1);

      update public.profiles
        set status = 'suspended', level = v_new_level, updated_at = now()
      where id = p_user_id;

      insert into public.level_changes (user_id, from_level, to_level, reason)
      values (p_user_id, v_level, v_new_level, 'mora_demotion');
    end if;
    return;
  end if;

  -- Antes del umbral de bajada: congelado, sin tocar el nivel.
  if v_status = 'active' then
    update public.profiles set status = 'frozen', updated_at = now() where id = p_user_id;
  end if;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_collection_amounts(uuid,date,integer)
-- Cobranza no persigue la inicial de una orden que la espera: se anula sola.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_collection_amounts(p_user uuid, p_today date, p_horizon integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_ov_usd numeric(18,4);
  v_ov_eur numeric(18,4);
  v_up_usd numeric(18,4);
  v_up_eur numeric(18,4);
  v_fee    numeric(18,4);
  v_ov_bs  numeric;
  v_up_bs  numeric;
begin
  select
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date <  p_today and c.currency <> 'EUR'), 0),
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date <  p_today and c.currency =  'EUR'), 0),
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date >= p_today and c.currency <> 'EUR'), 0),
    coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where i.due_date >= p_today and c.currency =  'EUR'), 0)
    into v_ov_usd, v_ov_eur, v_up_usd, v_up_eur
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.user_id = p_user
    and i.status = 'pending'
    and c.status <> 'awaiting_down_payment'  -- NUEVO (2026-11-12, la inicial)
    and not i.is_test
    and i.written_off_at is null
    and i.due_date <= p_today + p_horizon;

  select coalesce(sum(f.amount_usd), 0) into v_fee
  from public.late_fees f
  where f.user_id = p_user and f.status = 'pending';

  v_ov_usd := v_ov_usd + v_fee;

  begin
    v_ov_bs := (public.helios_bolivares(v_ov_usd, v_ov_eur, p_today)->>'amount_ves')::numeric;
  exception when sqlstate 'P0002' then v_ov_bs := null;
  end;
  begin
    v_up_bs := (public.helios_bolivares(v_up_usd, v_up_eur, p_today)->>'amount_ves')::numeric;
  exception when sqlstate 'P0002' then v_up_bs := null;
  end;

  return jsonb_build_object(
    'overdue_text', public.helios_amounts_label(v_ov_usd, v_ov_eur),
    'overdue_ves_hoy', v_ov_bs,
    'upcoming_text', public.helios_amounts_label(v_up_usd, v_up_eur),
    'upcoming_ves_hoy', v_up_bs
  );
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_collection_rows(date,integer,uuid)
-- Cobranza no persigue la inicial de una orden que la espera: se anula sola.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_collection_rows(p_today date, p_horizon integer, p_user uuid DEFAULT NULL::uuid)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
begin
  return query
  select to_jsonb(q)
  from (
    with pending as (
      select
        i.user_id as uid,
        i.amount_usd,
        i.due_date,
        m.name as merchant_name
      from public.installments i
      join public.charges ch on ch.id = i.charge_id
      join public.merchants m on m.id = ch.merchant_id
      where i.status = 'pending'
        and ch.status <> 'awaiting_down_payment'  -- NUEVO (2026-11-12, la inicial)
        and not i.is_test
        and i.due_date <= p_today + p_horizon
        and (p_user is null or i.user_id = p_user)
    ),
    grouped as (
      select
        uid,
        sum(amount_usd) as open_usd,
        sum(amount_usd) filter (where due_date < p_today) as overdue_usd,
        sum(amount_usd) filter (where due_date >= p_today) as upcoming_usd,
        max(p_today - due_date) as days_late,
        min(due_date) as next_due,
        count(*)::integer as cnt,
        array_agg(distinct merchant_name) as merchant_names
      from pending
      group by 1
    ),
    -- Con una persona pedida que no tiene nada pendiente en el horizonte, su
    -- fila sale igual, al día: la ficha la necesita aunque la cartera no.
    base as (
      select * from grouped
      union all
      select p_user, 0::numeric, null::numeric, null::numeric, null::integer,
             null::date, 0::integer, array[]::text[]
      where p_user is not null
        and not exists (select 1 from grouped)
    )
    select
      g.uid as user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as status,
      p.level,
      -- `>= v_demotion` y `> v_expulsion` son los de `recompute_profile_mora_state`.
      case
        when g.cnt = 0 then 'al_dia'
        when g.days_late > v_expulsion then 'expulsion'
        when g.days_late >= v_demotion then 'baja_nivel'
        when g.days_late >= 1 then 'congelado'
        when g.days_late = 0  then 'vence_hoy'
        else 'por_vencer'
      end as bucket,
      g.open_usd::numeric as open_usd,
      coalesce(g.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(g.upcoming_usd, 0)::numeric as upcoming_usd,
      greatest(g.days_late, 0)::integer as days_overdue,
      g.next_due as next_due_date,
      g.cnt as installment_count,
      g.merchant_names as merchants,
      (
        select max(pr.created_at) from public.payment_reports pr
        where pr.user_id = g.uid and pr.status = 'reconciled'
      ) as last_payment_at,
      c.contacted_at as last_contact_at,
      c.channel::text as last_contact_channel,
      c.actor_name as last_contact_by,
      c.note as last_contact_note,
      -- La promesa es la de la última gestión que traía una, no la de la
      -- última gestión a secas: un «no contesta» de hoy no borra lo que la
      -- persona prometió ayer.
      pm.promise_date,
      -- Si se habló con esta persona DESPUÉS de que se le venciera lo más viejo.
      exists (
        select 1 from public.collection_contacts cs
        where cs.user_id = g.uid
          and public.helios_business_date(cs.contacted_at) >= g.next_due
      ) as contacted_since_due,
      -- Resultado y próxima acción de la ÚLTIMA gestión; estado de la promesa
      -- de `promise_date`.
      c.outcome as last_contact_outcome,
      c.next_action_on as last_contact_next_action_on,
      public.helios_promise_status(g.uid, pm.contacted_at, pm.promise_date, p_today)
        as promise_status
    from base g
    join public.profiles p on p.id = g.uid
    left join lateral (
      select cc.contacted_at, cc.channel, cc.note, cc.outcome, cc.next_action_on,
             coalesce(pa.full_name, 'Alguien del equipo') as actor_name
      from public.collection_contacts cc
      left join public.platform_admins pa on pa.user_id = cc.actor
      where cc.user_id = g.uid
      order by cc.contacted_at desc
      limit 1
    ) c on true
    left join lateral (
      select cp.promise_date, cp.contacted_at
      from public.collection_contacts cp
      where cp.user_id = g.uid and cp.promise_date is not null
      order by cp.contacted_at desc
      limit 1
    ) pm on true
    -- La cartera ya sale sin pruebas por sus cuotas; una persona pedida a
    -- mano, también.
    where p_user is null or not p.is_test
  ) q;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.run_scheduled_settlements_batch(date,uuid,integer)
-- A la clínica solo se le devenga lo de una orden activa (la inicial no tiene día de pago).
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.run_scheduled_settlements_batch(p_business_date date, p_after uuid, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_charge  record;
  v_terms   public.merchant_terms;
  v_amount  numeric(18,4);
  v_room    numeric(18,4);
  v_last    uuid := p_after;
  v_seen    integer := 0;
  v_created integer := 0;
begin
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id, c.business_date,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.settlement_due_date = p_business_date
      and c.status = 'confirmed'  -- NUEVO (2026-11-12, la inicial)
      and c.id > p_after
    order by c.id
    limit p_limit
  loop
    v_last := v_charge.charge_id;
    v_seen := v_seen + 1;

    begin
      select * into v_terms
      from public.helios_terms_at(
        v_charge.merchant_id,
        coalesce(v_charge.business_date, p_business_date)
      );

      if coalesce(v_terms.policy::text, '') <> 'scheduled' then
        continue;
      end if;

      if exists (
        select 1 from public.settlements
        where charge_id = v_charge.charge_id
          and reason = 'scheduled_installment'
          and business_date = p_business_date
      ) then
        continue;
      end if;

      v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);

      -- Por un consumo nunca se devenga más que su neto. Helios: la comisión
      -- del personal no es parte del neto de la consulta y no cuenta.
      select v_charge.net_usd - coalesce(sum(s.amount_usd), 0)
        into v_room
      from public.settlements s
      where s.charge_id = v_charge.charge_id
        and s.reason <> 'staff_commission';

      v_amount := least(v_amount, v_room);

      if v_amount <= 0 then
        continue;
      end if;

      insert into public.settlements
        (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
         v_amount, p_business_date, p_business_date, 'pending');

      v_created := v_created + 1;
    exception when others then
      raise warning 'Liquidación programada fallida para el consumo % (comercio %): %',
        v_charge.charge_id, v_charge.merchant_id, sqlerrm;
    end;
  end loop;

  return jsonb_build_object('last', v_last, 'seen', v_seen, 'created', v_created);
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_settlement_outlook(uuid)
-- Los próximos pagos a la clínica: solo de órdenes activas.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_settlement_outlook(p_merchant_id uuid)
 RETURNS TABLE(today_date date, next_run_date date, next_run_usd numeric, accrued_usd numeric, accrued_count integer, overdue_usd numeric, oldest_due_date date, upcoming_usd numeric, total_pending_usd numeric, last_payout_on date, last_payout_usd numeric, accrued_consultas_usd numeric, accrued_comisiones_usd numeric, next_run_consultas_usd numeric, next_run_comisiones_usd numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select
    cal.today,
    cal.next_run,
    a.in_next_run + u.in_next_run,
    a.usd,
    a.n,
    a.overdue,
    a.oldest,
    u.usd,
    a.usd + u.usd,
    p.last_on,
    p.last_usd,
    a.usd - a.com,
    a.com,
    a.in_next_run - a.com_next + u.in_next_run,
    a.com_next
  from (
    select public.helios_business_date(now())      as today,
           public.helios_next_settlement_run(now()) as next_run
  ) cal
  -- 1. Devengado y sin transferir. Lo que falta, no el importe original.
  cross join lateral (
    select
      coalesce(sum(s.amount_usd - s.paid_usd), 0)                              as usd,
      count(s.id)::int                                                         as n,
      min(s.due_date)                                                          as oldest,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where public.helios_settlement_run_for(s.due_date) < cal.next_run
      ), 0)                                                                    as overdue,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.due_date < cal.next_run), 0)                                   as in_next_run,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.reason = 'staff_commission'), 0)                               as com,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.reason = 'staff_commission' and s.due_date < cal.next_run), 0) as com_next
    from public.settlements s
    where s.merchant_id = p_merchant_id
      and s.status in ('pending', 'partial')
  ) a
  -- 2. Lo que el cron encolará y todavía no existe, con las condiciones
  --    vigentes el día de CADA venta. Siempre consultas: la comisión nace
  --    devengada.
  cross join lateral (
    select
      coalesce(sum(f.amount_usd), 0)                                           as usd,
      coalesce(sum(f.amount_usd) filter (where f.due_date < cal.next_run), 0)  as in_next_run
    from (
      select
        d.due_date,
        greatest(0, least(
          d.tranche,
          d.room - coalesce(sum(d.tranche) over (
            partition by d.charge_id order by d.due_date
            rows between unbounded preceding and 1 preceding
          ), 0)
        )) as amount_usd
      from (
        select distinct
          c.id                                                   as charge_id,
          i.settlement_due_date as due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
              and s2.reason <> 'staff_commission'
          ), 0)                                                  as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        cross join lateral public.helios_terms_at(
          c.merchant_id, coalesce(c.business_date, cal.today)
        ) t
        where c.merchant_id = p_merchant_id
          and c.status = 'confirmed'  -- NUEVO (2026-11-12, la inicial)
          and t.policy = 'scheduled'
          and i.settlement_due_date >= cal.today
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.settlement_due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
  ) u
  left join lateral (
    select mp.paid_on as last_on, mp.amount_usd as last_usd
    from public.merchant_payouts mp
    where mp.merchant_id = p_merchant_id
    order by mp.paid_on desc nulls last, mp.created_at desc
    limit 1
  ) p on true;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.admin_merchant_upcoming_settlements(uuid)
-- Los próximos pagos a la clínica: solo de órdenes activas.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_merchant_upcoming_settlements(p_merchant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
  v_hoy  date := public.helios_business_date(now());
  v_usd  numeric := public.current_fx_rate('BCV', v_hoy);
  v_eur  numeric := public.current_fx_rate('BCV_EUR', v_hoy);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.due_date, q.order_number), '[]'::jsonb)
  into v_rows
  from (
    select
      'scheduled_installment'                          as reason,
      f.amount_usd,
      f.currency,
      f.amount_cur,
      round(f.amount_cur * case f.currency when 'EUR' then v_eur else v_usd end, 2) as pending_ves_hoy,
      f.due_date,
      public.helios_settlement_run_for(f.due_date)     as run_date,
      f.charge_id,
      f.order_number,
      -- NUEVO: la tasa de hoy de su moneda y, si el paciente ya adelantó su
      -- cuota, a qué tasa la pagó.
      case f.currency when 'EUR' then v_eur else v_usd end as tasa_hoy,
      cp.cuotas,
      cp.cuotas_pagadas,
      cp.paid_on                                       as paciente_pago_el,
      cp.fx_rate                                       as paciente_tasa
    from (
      select
        g.*,
        -- En la moneda de la orden, como `helios_settlement_currency`: la
        -- mitad que completa el neto se lleva lo que falte; las otras, su
        -- parte proporcional.
        case
          when g.currency = 'USD' then g.amount_usd
          when g.prev_usd
               + coalesce(sum(g.amount_usd) over (
                   partition by g.charge_id order by g.due_date
                   rows between unbounded preceding and 1 preceding), 0)
               + g.amount_usd >= g.net_usd - 0.005
            then greatest(g.net_cur - g.prev_cur
                          - coalesce(sum(round(g.net_cur * g.amount_usd / nullif(g.net_usd, 0), 2)) over (
                              partition by g.charge_id order by g.due_date
                              rows between unbounded preceding and 1 preceding), 0), 0)
          else round(g.net_cur * g.amount_usd / nullif(g.net_usd, 0), 2)
        end as amount_cur
      from (
        select
          d.*,
          greatest(0, least(
            d.tranche,
            d.room - coalesce(sum(d.tranche) over (
              partition by d.charge_id order by d.due_date
              rows between unbounded preceding and 1 preceding
            ), 0)
          )) as amount_usd
        from (
          select distinct
            c.id                                                   as charge_id,
            c.order_number,
            c.currency,
            i.settlement_due_date as due_date,
            coalesce(c.merchant_net_usd, c.amount_usd)             as net_usd,
            coalesce(c.merchant_net_cur, c.amount_cur, c.merchant_net_usd, c.amount_usd) as net_cur,
            round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
            coalesce((
              select sum(s2.amount_usd) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as prev_usd,
            coalesce((
              select sum(coalesce(s2.amount_cur, s2.amount_usd)) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as prev_cur,
            coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
              select sum(s2.amount_usd) from public.settlements s2
              where s2.charge_id = c.id and s2.reason <> 'staff_commission'
            ), 0)                                                  as room
          from public.installments i
          join public.charges c on c.id = i.charge_id
          cross join lateral public.helios_terms_at(
            c.merchant_id, coalesce(c.business_date, v_hoy)
          ) t
          where c.merchant_id = p_merchant_id
            and c.status = 'confirmed'  -- NUEVO (2026-11-12, la inicial)
            and t.policy = 'scheduled'
            and i.settlement_due_date >= v_hoy
            and not exists (
              select 1 from public.settlements s3
              where s3.charge_id = c.id
                and s3.reason = 'scheduled_installment'
                and s3.business_date = i.settlement_due_date
            )
            and not public.helios_charge_of_test_patient(c.id, null)
        ) d
      ) g
    ) f
    cross join lateral public.helios_cuota_pagada(f.charge_id, f.due_date) cp
    where f.amount_usd > 0
  ) q;

  return v_rows;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- metricas.cuotas_al(date)
-- Las métricas de cuotas (a tiempo, impago, cohortes, cobranza) miran las cuotas 1 y 2: la
-- inicial se paga el mismo día o la orden se anula, y contarla inflaría el cobro a tiempo.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION metricas.cuotas_al(p_dia date)
 RETURNS TABLE(installment_id uuid, charge_id uuid, user_id uuid, sequence smallint, due_date date, payable_usd numeric, financed_usd numeric, fee_usd numeric, status text, paid_at timestamp with time zone, pagada_dia date, reportada_en timestamp with time zone, written_off_at timestamp with time zone, business_date date, semana date, merchant_id uuid, group_id uuid, estado_hoy text, dias_atraso integer, plazo_cerrado boolean, reportada_dia date, report_id uuid, branch_id uuid, es_grupo boolean, dia_de_referencia date)
 LANGUAGE sql
 STABLE
AS $function$
  with ref as materialized (
    select
      -- El día que hace de «hoy» para decidir si algo está vencido.
      case when p_dia < h.hoy then p_dia + 1 else h.hoy end              as dia,
      -- Hasta qué instante cuenta un pago o una pérdida.
      case when p_dia < h.hoy then public.helios_business_day_end(p_dia)
           else now() end                                                as corte,
      -- Hasta qué día operativo existían los consumos.
      least(p_dia, h.hoy)                                                as hasta,
      public.helios_on_time_grace_days()                                  as gracia
    from (select metricas.hoy() as hoy) h
  ),
  q as (
    select
      i.id, i.charge_id, i.user_id, i.sequence, i.due_date,
      i.amount_usd, i.financed_usd, i.paid_at, i.written_off_at,
      i.paid_by_report_id,
      c.business_date, c.merchant_id, c.branch_id, c.group_id,
      r.dia, r.gracia,
      (i.status = 'paid' and (i.paid_at is null or i.paid_at <= r.corte))  as pagada,
      (i.written_off_at is not null and i.written_off_at <= r.corte)       as perdida,
      -- EL día del pago: el único sitio que lo decide. Es el día en que la
      -- persona REPORTÓ el pago (decisión de Javier, 27-09): lo que tarde el
      -- equipo en aprobarlo no la hace llegar tarde. Sin reporte (un abono
      -- asignado a mano, por ejemplo), el de la aprobación.
      coalesce(metricas.dia_operativo(pr.created_at),
               metricas.dia_operativo(i.paid_at))                      as dia_pago,
      pr.created_at                                                        as reportada_en
    from public.installments i
    join public.charges c on c.id = i.charge_id
    left join public.payment_reports pr on pr.id = i.paid_by_report_id
    cross join ref r
    where c.status = 'confirmed'
      and i.sequence > 0  -- NUEVO (2026-11-12, la inicial)
      and not c.is_test
      and not i.is_test
      and c.business_date is not null
      and c.business_date <= r.hasta
  )
  select
    q.id,
    q.charge_id,
    q.user_id,
    q.sequence,
    q.due_date,
    q.amount_usd::numeric,
    q.financed_usd::numeric,
    (q.amount_usd - q.financed_usd)::numeric,
    case when q.pagada then 'paid' else 'pending' end,
    case when q.pagada then q.paid_at end,
    case when q.pagada then q.dia_pago end,
    case when q.pagada then q.reportada_en end,
    case when q.perdida then q.written_off_at end,
    q.business_date,
    metricas.lunes(q.business_date),
    q.merchant_id,
    q.group_id,
    case
      when q.pagada and metricas.a_tiempo(q.dia_pago, q.due_date, q.gracia)
                              then 'a_tiempo'
      when q.pagada           then 'tarde'
      when q.perdida          then 'perdida'
      when q.due_date < q.dia then 'vencida'
      else                         'por_vencer'
    end,
    case
      when q.pagada           then greatest(q.dia_pago - q.due_date, 0)
      when q.due_date < q.dia then q.dia - q.due_date
      else 0
    end,
    q.due_date + q.gracia < q.dia,
    case when q.pagada then metricas.dia_operativo(q.reportada_en) end,
    case when q.pagada then q.paid_by_report_id end,
    q.branch_id,
    q.group_id is not null,
    q.dia
  from q;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.admin_set_business_parameter(text,numeric,date,text)
-- La inicial solo puede ir de 0 a 90% (un 100% rompería el CHECK de charges) y su plazo, de al
-- menos 1 minuto.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_set_business_parameter(p_key text, p_value numeric, p_effective_from date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes numeric;
  v_unit  text;
begin
  perform public.helios_assert_super_admin('cambiar un parámetro del negocio');

  select c.unit into v_unit
  from public.business_parameter_catalog c where c.key = p_key;

  if v_unit is null
     and not exists (select 1 from public.business_parameters where key = p_key) then
    raise exception 'No existe el parámetro %', p_key using errcode = '22023';
  end if;

  if p_value is null then
    raise exception 'El parámetro necesita un valor' using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  -- Hacia atrás no. Cambiar la vigencia de un parámetro en el pasado no
  -- reescribe lo que ya pasó —el motor aplicó lo que aplicó— pero sí haría
  -- que el histórico mintiera sobre ello.
  if v_desde < v_today then
    raise exception 'Un parámetro no puede entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  if p_value < 0 then
    raise exception 'Un parámetro no puede ser negativo' using errcode = '22023';
  end if;

  if v_unit = '%' and p_value > 100 then
    raise exception 'Un porcentaje no puede pasar de 100' using errcode = '22023';
  end if;

  -- NUEVO (2026-11-12, la inicial).
  if p_key = 'down_payment_pct' and p_value > 90 then
    raise exception 'La inicial va de 0 a 90%%' using errcode = '22023';
  end if;
  if p_key = 'down_payment_minutes' and p_value < 1 then
    raise exception 'El plazo para pagar la inicial es de al menos 1 minuto' using errcode = '22023';
  end if;

  -- Un interruptor solo se enciende (1) o se apaga (0).
  if v_unit = '0/1' and p_value not in (0, 1) then
    raise exception 'Este parámetro es un interruptor: 1 lo enciende y 0 lo apaga'
      using errcode = '22023';
  end if;

  -- Lo que se cuenta, se cuenta entero: el estado automático cuenta días
  -- enteros y no hay medio reenvío.
  if v_unit in ('días', 'minutos', 'min', 'intentos', 'preguntas', 'reenvíos', 'consultas',
                'casos', 'pacientes', 'financiamientos', 'personas', 'locales', 'clínicas')
     and p_value <> trunc(p_value) then
    raise exception 'Este parámetro se cuenta en % enteros', v_unit using errcode = '22023';
  end if;

  select public.helios_parameter(p_key, null) into v_antes;

  insert into public.business_parameters (key, value, effective_from, note, created_by)
  values (p_key, p_value, v_desde, nullif(trim(coalesce(p_note, '')), ''), v_actor)
  on conflict (key, effective_from) do update
    set value = excluded.value, note = excluded.note,
        created_by = excluded.created_by, created_at = now();

  perform audit.log(v_actor, 'parameter.set', null, jsonb_build_object(
    'key', p_key,
    'from_value', v_antes,
    'to_value', p_value,
    'effective_from', v_desde,
    'note', p_note
  ));

  return jsonb_build_object(
    'ok', true, 'key', p_key, 'value', p_value, 'effective_from', v_desde
  );
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.admin_risk_alerts(integer,text[],uuid)
-- Alerta nueva, `inicial_atascada`: una orden que sigue esperando la inicial más de
-- `alert_down_payment_stuck_hours` (6) después de su plazo, porque un pago en revisión la sostiene.
-- ──────────────────────────────────────────────────────────────────────────

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
  v_atascada  numeric := public.helios_parameter('alert_down_payment_stuck_hours', 6);  -- NUEVO (2026-11-12, la inicial)
  v_consultas integer := public.helios_eligibility_lookups_per_staff_day();
  v_kinds     text[]  := array[
    'telefono_repetido', 'correo_repetido', 'correo_rebotado',
    'rafaga_de_altas', 'rafaga_de_pacientes_nuevos', 'secretaria_concentrada',
    'impago_primera_cuota_clinica', 'exposicion_clinica',
    'referencia_repetida', 'cupo_al_limite_al_estrenar', 'consultas_de_cedula_excesivas',
    'consumo_sobre_cupo', 'cedula_no_coincide', 'inicial_atascada'];
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

  -- ── Paciente: la foto de su cédula no cuadra (2026-11-02) ───────────────
  cedula as (
    select f.id, f.profile_id, f.charge_id, f.status, f.reason, f.read_number, f.read_name,
           coalesce(f.reviewed_at, f.created_at) as desde
    from public.patient_id_photos f
    where f.status in ('no_coincide', 'no_es_cedula', 'no_se_pudo_leer', 'no_se_pudo_bajar')
      and f.created_at >= (v_desde::timestamp at time zone 'America/Caracas')
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

    union all
    select 'cedula_no_coincide:' || f.profile_id || ':' || f.id, 'cedula_no_coincide',
           case when f.status in ('no_coincide', 'no_es_cedula') then 'alta' else 'media' end,
           'paciente', f.profile_id, f.profile_id, c.merchant_id, f.desde,
           jsonb_build_object('photo_id', f.id, 'status', f.status, 'reason', f.reason,
                              'read_number', f.read_number, 'read_name', f.read_name,
                              'document', p.document_number, 'charge_id', f.charge_id,
                              'order_number', c.order_number, 'merchant_name', m.name)
    from cedula f
    join public.profiles       p on p.id = f.profile_id
    left join public.charges   c on c.id = f.charge_id
    left join public.merchants m on m.id = c.merchant_id

    -- NUEVO (2026-11-12, la inicial): lleva horas esperando la inicial después de su plazo.
    union all
    select 'inicial_atascada:' || c.user_id || ':' || c.id, 'inicial_atascada', 'alta',
           'paciente', c.user_id, c.user_id, c.merchant_id, c.down_payment_due_at,
           jsonb_build_object('charge_id', c.id, 'order_number', c.order_number,
                              'business_date', c.business_date,
                              'down_payment_due_at', c.down_payment_due_at,
                              'hours_late', floor(extract(epoch from now() - c.down_payment_due_at) / 3600),
                              'threshold', v_atascada,
                              'merchant_id', c.merchant_id, 'merchant_name', m.name)
    from public.charges c
    join public.merchants m on m.id = c.merchant_id
    where c.status = 'awaiting_down_payment'
      and not c.is_test
      and c.down_payment_due_at < now() - make_interval(hours => v_atascada::integer)
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
      'eligibility_lookups_per_staff_day', v_consultas,
      'alert_down_payment_stuck_hours', v_atascada
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
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.admin_review_risk_alert(text,text)
-- Se puede marcar como revisada la alerta nueva `inicial_atascada`.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_review_risk_alert(p_alert_key text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_key   text := trim(coalesce(p_alert_key, ''));
  v_note  text := nullif(trim(coalesce(p_note, '')), '');
  v_at    timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_key !~ ('^(relacionada|sobre_cupo|telefono_repetido|correo_repetido|correo_rebotado'
               '|rafaga_de_altas|rafaga_de_pacientes_nuevos|secretaria_concentrada'
               '|impago_primera_cuota_clinica|exposicion_clinica|referencia_repetida'
               '|cupo_al_limite_al_estrenar|consultas_de_cedula_excesivas|cedula_no_coincide'
               '|inicial_atascada)'
               ':[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:.+$') then
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
$function$;


-- 1. Las plantillas ─────────────────────────────────────────────────────────

-- La pregunta con inicial: otra fila, para que las órdenes viejas pendientes
-- (y sus reenvíos) sigan preguntando con la suya, «2 cuotas, sin inicial»,
-- y su plantilla de Meta v2. Esta sale con la v3 fuera de la ventana de 24 h
-- (docs/00 §15.5.4). Mismos botones Sí/No: el webhook no distingue.
insert into public.notification_templates (
  key, label, trigger_label, help, variables, required_variables,
  default_title, default_body, enabled, editable, can_disable, sort_order, channels,
  wa_template_name, wa_template_lang, wa_template_params, wa_buttons
) values (
  'confirmar_pago_con_inicial',
  'Confirma tu pago en cuotas (con inicial)',
  'Al registrar un pago en cuotas con inicial (y al reenviarlo)',
  'La pregunta al paciente desde la inicial del 50% (2026-11-12): la inicial de hoy y las 2 cuotas. Botones Sí / No. Dentro de la ventana de 24 h sale este texto; fuera, la plantilla aprobada en Meta (helios_confirmar_pago_en_cuotas_v3). Las órdenes de antes, sin inicial, siguen con «Confirma tu pago en cuotas». El texto no se edita aquí.',
  array['cargo_servicio', 'cuotas_detalle', 'cuotas_lista', 'inicial', 'iva_cargo_servicio', 'iva_pct',
        'medico', 'moneda', 'monto_consulta', 'nombre', 'orden', 'plan_lista', 'plazo_inicial',
        'servicio_pct', 'total', 'vence'],
  array['medico', 'monto_consulta', 'servicio_pct', 'cargo_servicio', 'iva_pct', 'iva_cargo_servicio',
        'total', 'inicial', 'cuotas_detalle'],
  'Confirma tu pago en cuotas con {medico}',
  -- El mismo texto que la plantilla de Meta v3 (docs/00 §15.5.4, fijado por
  -- Javier), con «Responde Sí o No.» como en la v2.
  E'👋 ¡Hola, {nombre}! Te damos la bienvenida a Helios 💙\n\n'
  'Tu consulta con {medico} quedó registrada para que la pagues con una *inicial del 50%* y *2 cuotas*.\n\n'
  '*Tu consulta*\n'
  'Consulta: {monto_consulta}\n'
  'Comisión de servicio ({servicio_pct}%): {cargo_servicio}\n'
  'IVA de la comisión ({iva_pct}%): {iva_cargo_servicio}\n'
  '*Total: {total}*\n\n'
  '*Cómo pagas*\n'
  '💳 Inicial, hoy: {inicial}\n'
  '📅 Cuotas: {cuotas_detalle}\n\n'
  'Pagas en bolívares, a la tasa BCV del {moneda} del día en que pagues.\n\n'
  '¿Confirmas tu pago en cuotas? Responde Sí o No. Tienes 2 horas para responder. Al confirmar, paga la inicial en las 2 horas siguientes y tu pago en cuotas quedará activo.',
  true, false, false, 16, array['whatsapp'],
  'helios_confirmar_pago_en_cuotas_v3', 'es',
  array['nombre', 'medico', 'monto_consulta', 'servicio_pct', 'cargo_servicio', 'iva_pct',
        'iva_cargo_servicio', 'total', 'inicial', 'cuotas_detalle', 'moneda'],
  '[{"id": "confirmar:{charge_id}", "title": "Sí"}, {"id": "rechazar:{charge_id}", "title": "No"}]'::jsonb
)
on conflict (key) do update
  set label = excluded.label, trigger_label = excluded.trigger_label, help = excluded.help,
      variables = excluded.variables, required_variables = excluded.required_variables,
      default_title = excluded.default_title, default_body = excluded.default_body,
      channels = excluded.channels, wa_template_name = excluded.wa_template_name,
      wa_template_lang = excluded.wa_template_lang, wa_template_params = excluded.wa_template_params,
      wa_buttons = excluded.wa_buttons;

-- Tras el «Sí» (y la cédula): la inicial, su plazo y cómo pagarla. Ocupa el
-- lugar de la bienvenida en las órdenes con inicial; el bloque de pago es el
-- de la inicial y cierra con la frase de los niveles.
insert into public.notification_templates (
  key, label, trigger_label, help, variables, required_variables,
  default_title, default_body, enabled, editable, can_disable, sort_order, channels,
  wa_template_lang, wa_template_params, wa_buttons
) values (
  'pagar_inicial',
  'Paga tu inicial',
  'Al aceptar un pago en cuotas con inicial (el «Sí» y la cédula)',
  'Le dice al paciente que su pago en cuotas se activa cuando pague la inicial, hasta qué hora tiene y cómo pagarla. Si no la paga a tiempo, la orden se anula sola. Con la confirmación del paciente sale sola por WhatsApp; si no, va a la cola manual.',
  array['bloque_de_pago', 'clinica', 'inicial', 'limite', 'medico', 'moneda', 'nombre', 'orden', 'plan'],
  array['orden', 'inicial', 'limite', 'plan', 'bloque_de_pago'],
  'Paga tu inicial',
  E'✅ ¡Listo, {nombre}! Aceptaste tu pago en cuotas #{orden} con {medico}.\n\n'
  'Para activarlo, paga tu *inicial de {inicial}* antes de {limite} ⏰. Si no la recibimos a tiempo, la orden se anula sola y no debes nada.\n\n'
  '*Tu plan de pagos*\n'
  '{plan}\n\n'
  '{bloque_de_pago}',
  true, true, false, 21, array['whatsapp_manual', 'whatsapp'],
  'es', '{}'::text[], '[]'::jsonb
)
on conflict (key) do update
  set label = excluded.label, trigger_label = excluded.trigger_label, help = excluded.help,
      variables = excluded.variables, required_variables = excluded.required_variables,
      default_title = excluded.default_title, default_body = excluded.default_body,
      channels = excluded.channels;

-- El comprobante por correo: «Tu plan de pagos (sin inicial)» pasa a ser una
-- variable, porque las órdenes viejas lo siguen diciendo y las nuevas no. Si
-- el equipo editó el texto (o tiene un borrador), se cambia también ahí.
update public.notification_templates
   set default_body = replace(default_body, 'TU PLAN DE PAGOS (sin inicial)', 'TU PLAN DE PAGOS{plan_nota}'),
       body         = replace(body, 'TU PLAN DE PAGOS (sin inicial)', 'TU PLAN DE PAGOS{plan_nota}'),
       draft_body   = replace(draft_body, 'TU PLAN DE PAGOS (sin inicial)', 'TU PLAN DE PAGOS{plan_nota}'),
       default_html = replace(default_html, 'Tu plan de pagos &middot; sin inicial', 'Tu plan de pagos{plan_nota_html}'),
       html         = replace(html, 'Tu plan de pagos &middot; sin inicial', 'Tu plan de pagos{plan_nota_html}'),
       variables    = (select array_agg(distinct v order by v)
                         from unnest(variables || array['plan_nota', 'plan_nota_html']) v)
 where key = 'comprobante_financiamiento';

do $$
begin
  if exists (select 1 from public.notification_templates
             where key = 'comprobante_financiamiento'
               and (coalesce(default_body, '') || coalesce(body, '') || coalesce(default_html, '') || coalesce(html, ''))
                   ilike '%sin inicial%') then
    raise exception 'El comprobante aún dice «sin inicial» en algún sitio: revisar su texto a mano';
  end if;
end $$;

-- 2. Los textos al paciente ─────────────────────────────────────────────────
-- NUEVO: 'cedula_recibida' con inicial (ya no «confirmado») e
-- 'inicial_vencida' (la orden se anuló sola).
create or replace function public.helios_patient_decision_text(p_charge_id uuid, p_kind text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      public.charges%rowtype;
  v_nombre text;
  v_med    text;
  v_txt    text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    return null;
  end if;

  select coalesce(nullif(btrim(p.first_name), ''), nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 1), ''))
    into v_nombre
  from public.profiles p where p.id = v_c.user_id;
  v_med := public.helios_doctor_ref(v_c.merchant_id);

  v_txt := case p_kind
    when 'no' then
      format(E'Entendido%s. No se registró ningún pago en cuotas y no debes nada 💙\nSi fue un error, pídele a %s que te lo envíe de nuevo.',
             coalesce(', ' || v_nombre, ''), v_med)
    when 'vencida' then
      coalesce(v_nombre || ', ', '') ||
      format(E'esta solicitud venció porque pasaron más de 2 horas ⌛. No te preocupes: no se registró nada.\nSi aún quieres pagar tu consulta en cuotas, pídele a %s que te la envíe otra vez.',
             v_med)
    when 'cuota_vencida' then
      coalesce(v_nombre || ', ', '') ||
      'no pudimos confirmar este pago en cuotas porque tienes una cuota pendiente. En cuanto la pagues podrás volver a usar Helios 💙'
    when 'no_disponible' then
      coalesce(v_nombre || ', ', '') ||
      'en este momento no pudimos confirmar tu pago en cuotas y no se registró ningún cargo. Si quieres, te ayudamos por aquí.'
    when 'pide_cedula' then
      'Para confirmar tu pago en cuotas necesitamos una foto de tu cédula 🪪. Envíala por aquí.'
    when 'cedula_recibida' then
      -- NUEVO (2026-11-12): con inicial, la orden aún no está activa; el
      -- mensaje de la inicial sale justo después.
      case when v_c.status = 'awaiting_down_payment'
        then format('✅ ¡Gracias%s! Recibimos tu cédula. Ya solo falta tu inicial para activar tu pago en cuotas 👇',
                    coalesce(', ' || v_nombre, ''))
        else format('✅ ¡Gracias%s! Recibimos tu cédula y tu pago en cuotas quedó confirmado.',
                    coalesce(', ' || v_nombre, ''))
      end
    when 'inicial_vencida' then
      -- NUEVO (2026-11-12): pasó el plazo sin la inicial y la orden se anuló.
      coalesce(v_nombre || ', ', '') ||
      format(E'tu pago en cuotas #%s con %s se anuló porque no recibimos tu inicial a tiempo ⌛. No debes nada.\nSi ya la pagaste, envíanos el comprobante por aquí y lo revisamos. Si aún quieres pagar tu consulta en cuotas, pídele a tu médico que te lo registre de nuevo.',
             v_c.order_number, v_med)
  end;

  -- Sin nombre, la frase empieza con mayúscula.
  return upper(left(v_txt, 1)) || substr(v_txt, 2);
end;
$$;

-- 3. Los avisos al médico ───────────────────────────────────────────────────
-- NUEVO: 'activada' (pagó la inicial: es el único «aceptó» de una orden con
-- inicial, y sale también con la plantilla aprobada si la ventana está
-- cerrada) e 'inicial_vencida' (se anuló sola; con la ventana cerrada no hay
-- plantilla aprobada para decirlo, como pasa con 'vencida').
create or replace function public.helios_notify_staff_of_charge(p_charge_id uuid, p_kind text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c         public.charges%rowtype;
  v_phone     text;
  v_quien     text;
  v_consulta  text;
  v_texto     text;
  v_plantilla text;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.requested_by is null then
    return;
  end if;

  -- Del panel o del bot: a quien la registró, si tiene número del bot.
  select n.phone_e164 into v_phone from public.staff_whatsapp_numbers n
  where n.user_id = v_c.requested_by and n.merchant_id = v_c.merchant_id and n.revoked_at is null;
  if v_phone is null then
    return;
  end if;

  select concat_ws(' ', nullif(btrim(p.first_name), ''),
                   case when nullif(btrim(p.last_name), '') is not null then left(btrim(p.last_name), 1) || '.' end)
    into v_quien
  from public.profiles p where p.id = v_c.user_id;
  v_quien := coalesce(nullif(v_quien, ''), 'El paciente');
  -- A la clínica, la consulta sin la comisión.
  v_consulta := public.helios_money_cur_text(coalesce(v_c.base_cur, v_c.amount_cur), v_c.currency);

  v_texto := case p_kind
    when 'aceptada' then format(E'¡Buenas noticias! %s aceptó su pago en cuotas.\n\nLa orden #%s por una consulta de %s ya está confirmada ✅',
                                v_quien, v_c.order_number, v_consulta)
    when 'activada' then format(E'¡Buenas noticias! %s pagó su inicial y su pago en cuotas quedó activo.\n\nLa orden #%s por una consulta de %s ya está confirmada ✅',
                                v_quien, v_c.order_number, v_consulta)
    when 'rechazada' then case v_c.decline_reason
      when 'no_disponible' then format('La orden #%s de %s no se pudo confirmar. %s',
                                       v_c.order_number, v_quien, public.helios_not_available_message())
      else format('❌ %s no aceptó la orden #%s. No se creó ninguna deuda.', v_quien, v_c.order_number) end
    when 'vencida' then format('⌛ La orden #%s de %s venció sin respuesta. Escribe «reenviar %s» para enviársela otra vez.',
                               v_c.order_number, v_quien, v_c.order_number)
    when 'inicial_vencida' then format(E'⌛ La orden #%s de %s se anuló: no pagó la inicial a tiempo. No se creó ninguna deuda.\nSi aún quiere pagar en cuotas, regístrale una orden nueva.',
                                       v_c.order_number, v_quien)
  end;
  if v_texto is null then
    return;
  end if;

  if public.helios_whatsapp_window_open(v_phone) then
    perform public.helios_whatsapp_text(v_phone, v_texto, v_c.requested_by);
    return;
  end if;

  -- Ventana cerrada: solo «aceptó» (o «pagó la inicial»), con la plantilla
  -- aprobada.
  select nullif(btrim(t.wa_template_name), '') into v_plantilla
  from public.notification_templates t where t.key = 'aviso_al_medico' and t.enabled;
  if p_kind not in ('aceptada', 'activada') or v_plantilla is null then
    return;
  end if;

  insert into public.outbound_messages (
    channel, template_key, profile_id, recipient_staff_id, recipient, charge_id,
    subject, rendered_text, status, next_attempt_at, wa_template
  ) values (
    'whatsapp', 'aviso_al_medico', null, v_c.requested_by, v_phone, v_c.id,
    'Helios', v_texto, 'pendiente', now(),
    jsonb_build_object('name', v_plantilla, 'language', 'es',
      'params', jsonb_build_array(v_quien, v_c.order_number::text, v_consulta),
      'buttons', '[]'::jsonb)
  );
exception when others then
  -- Un aviso que no sale no puede tumbar la confirmación del paciente.
  null;
end;
$$;

-- 4. La pregunta ────────────────────────────────────────────────────────────
-- Con inicial, la plantilla `confirmar_pago_con_inicial`: la inicial de hoy y
-- las 2 cuotas. Las variables de las cuotas (`cuotas_*`) son SOLO las 2
-- cuotas; la inicial va en `inicial` y en `plan_lista`. Sin inicial, todo
-- como hasta hoy.
create or replace function public.helios_enqueue_confirmation(p_charge_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c       public.charges%rowtype;
  v_plan    jsonb;
  v_linea   text;
  v_montos  numeric[];
  v_fechas  text;
  v_lista   text;
  v_detalle text;
  v_iva     numeric;
  v_rate    numeric;
  v_inicial numeric;
  v_min     integer;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'pending' then
    raise exception 'La orden no está esperando al paciente' using errcode = '22023';
  end if;

  v_plan := public.helios_charge_planned_installments(p_charge_id);
  v_rate := public.helios_fx_rate(v_c.currency);

  -- En una sola línea: Meta no admite saltos de línea en una variable. Cada
  -- cuota en la moneda de la orden. Solo las cuotas 1 y 2.
  select string_agg(format('%s el %s',
                           public.helios_money_cur_text((x->>'amount_cur')::numeric, v_c.currency),
                           to_char((x->>'due_date')::date, 'DD/MM')),
                    ' y ' order by (x->>'sequence')::integer),
         array_agg((x->>'amount_cur')::numeric order by (x->>'sequence')::integer),
         string_agg(to_char((x->>'due_date')::date, 'DD/MM'), ' y ' order by (x->>'sequence')::integer),
         string_agg(format('📅 %s · %s',
                           public.helios_money_cur_text((x->>'amount_cur')::numeric, v_c.currency),
                           public.helios_weekday_es((x->>'due_date')::date) || ' ' || to_char((x->>'due_date')::date, 'DD/MM')),
                    E'\n' order by (x->>'sequence')::integer),
         string_agg(format('%s el %s',
                           public.helios_money_cur_text((x->>'amount_cur')::numeric, v_c.currency),
                           public.helios_weekday_es((x->>'due_date')::date) || ' ' || to_char((x->>'due_date')::date, 'DD/MM')),
                    ' y ' order by (x->>'sequence')::integer)
    into v_linea, v_montos, v_fechas, v_lista, v_detalle
  from jsonb_array_elements(v_plan) x
  where (x->>'sequence')::integer > 0;

  -- NUEVO (2026-11-12): la inicial, si la orden la tiene.
  select (x->>'amount_cur')::numeric into v_inicial
  from jsonb_array_elements(v_plan) x
  where (x->>'sequence')::integer = 0;

  v_min := public.helios_down_payment_minutes();

  -- El IVA del cargo, como porcentaje del cargo (el que se cobró de verdad).
  v_iva := case when coalesce(v_c.consumer_fee_usd, 0) > 0
                then round(v_c.consumer_fee_vat_usd * 100 / v_c.consumer_fee_usd, 2)
                else public.helios_parameter('vat_pct', 16) end;

  return public.helios_enqueue_message(
    case when v_inicial is not null then 'confirmar_pago_con_inicial' else 'confirmar_financiamiento' end,
    v_c.user_id, p_charge_id, 'whatsapp',
    jsonb_build_object(
      'clinica', (select m.name from public.merchants m where m.id = v_c.merchant_id),
      'medico', public.helios_doctor_ref(v_c.merchant_id),
      'moneda', public.helios_currency_name(v_c.currency),
      'monto_consulta', public.helios_money_cur_text(coalesce(v_c.base_cur, v_c.amount_cur), v_c.currency),
      'servicio_pct', public.helios_pct_text(v_c.consumer_fee_pct),
      'cargo_servicio', public.helios_money_cur_text(coalesce(v_c.consumer_fee_cur, 0), v_c.currency),
      'iva_pct', public.helios_pct_text(v_iva),
      'iva_cargo_servicio', public.helios_money_cur_text(coalesce(v_c.consumer_fee_vat_cur, 0), v_c.currency),
      'total', public.helios_money_cur_text(v_c.amount_cur, v_c.currency),
      'total_bs', case when v_rate is null then 'el equivalente en bolívares'
                       else public.helios_ves_text(round(v_c.amount_cur * v_rate, 2)) end,
      'cuotas_monto', case
        when v_montos[1] = v_montos[array_upper(v_montos, 1)]
          then public.helios_money_cur_text(v_montos[1], v_c.currency)
        else (select string_agg(public.helios_money_cur_text(m, v_c.currency), ' y ') from unnest(v_montos) m) end,
      'cuotas_fechas', v_fechas,
      'cuotas_linea', v_linea,
      'cuotas_lista', v_lista,
      'cuotas_detalle', v_detalle,
      'orden', coalesce(v_c.order_number::text, left(v_c.id::text, 8)),
      'vence', to_char(v_c.expires_at at time zone 'America/Caracas', 'HH24:MI')
    ) || case when v_inicial is null then '{}'::jsonb else jsonb_build_object(
      'inicial', public.helios_money_cur_text(v_inicial, v_c.currency),
      'plan_lista', format(E'💳 Inicial hoy: %s\n', public.helios_money_cur_text(v_inicial, v_c.currency)) || v_lista,
      'plazo_inicial', case when v_min % 60 = 0 and v_min >= 120 then (v_min / 60) || ' horas'
                            when v_min = 60 then '1 hora'
                            else v_min || ' minutos' end)
    end,
    null, null);
end;
$$;

-- 5. Tras el «Sí»: paga tu inicial ──────────────────────────────────────────
create or replace function public.helios_enqueue_down_payment_request(p_charge_id uuid, p_channel text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c      public.charges%rowtype;
  v_cero   public.installments%rowtype;
  v_rate   numeric;
  v_limite text;
  v_plan   text;
  v_hoy    date := public.helios_business_date(now());
  v_dia    date;
begin
  select * into v_c from public.charges where id = p_charge_id;
  select * into v_cero from public.installments i where i.charge_id = p_charge_id and i.sequence = 0;
  if v_c.id is null or v_cero.id is null then
    raise exception 'La orden no tiene inicial' using errcode = '22023';
  end if;

  v_rate := public.helios_fx_rate(v_c.currency);

  -- «las 16:30» o, si el plazo cruza la medianoche, «las 00:30 del viernes 13/11».
  v_dia := public.helios_business_date(v_c.down_payment_due_at);
  v_limite := 'las ' || to_char(v_c.down_payment_due_at at time zone 'America/Caracas', 'HH24:MI')
              || case when v_dia <> v_hoy then ' del ' || public.helios_dia_text(v_dia) else '' end;

  -- «💳 Inicial: $56,96 · hoy», «1️⃣ $28,48 · jueves 26/11», sin bolívares
  -- (van en el bloque de pago).
  select string_agg(case i.sequence
                      when 0 then format('💳 Inicial: %s · hoy',
                                         public.helios_money_cur_text(i.amount_cur, v_c.currency))
                      else format('%s %s · %s',
                                  case i.sequence when 1 then '1️⃣' else '2️⃣' end,
                                  public.helios_money_cur_text(i.amount_cur, v_c.currency),
                                  public.helios_dia_text(i.due_date))
                    end, E'\n' order by i.sequence)
    into v_plan
  from public.installments i where i.charge_id = p_charge_id;

  return public.helios_enqueue_message(
    'pagar_inicial', v_c.user_id, v_c.id, p_channel,
    jsonb_build_object(
      'clinica', (select m.name from public.merchants m where m.id = v_c.merchant_id),
      'medico', public.helios_doctor_ref(v_c.merchant_id),
      'orden', v_c.order_number::text,
      'inicial', public.helios_money_cur_text(v_cero.amount_cur, v_c.currency),
      'limite', v_limite,
      'plan', v_plan,
      'moneda', public.helios_currency_name(v_c.currency),
      'bloque_de_pago', public.helios_payment_block(
        case when v_rate is not null then round(v_cero.amount_cur * v_rate, 2) end,
        public.helios_money_cur_text(v_cero.amount_cur, v_c.currency),
        public.helios_currency_name(v_c.currency),
        public.helios_por_whatsapp(p_channel))),
    null, 'pagar_inicial:' || v_c.id::text);
end;
$$;

revoke all on function public.helios_enqueue_down_payment_request(uuid, text) from public, anon, authenticated;

-- 6. El pago aprobado ───────────────────────────────────────────────────────
-- NUEVO (2026-11-12): si el pago cubrió la inicial de una orden, el aviso dice
-- que quedó activa y enseña sus 2 cuotas. Lo demás, como estaba.
create or replace function public.helios_payment_result_whatsapp(p_report_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r        public.payment_reports%rowtype;
  v_q        public.payment_quotes%rowtype;
  v_nombre   text;
  v_ordenes  text;
  v_n        integer;
  v_meds     text;
  v_eur_usd  numeric(18,4);
  v_txt      text;
  v_resto    text;
  v_sig      record;
  v_pagadas  uuid[];
  v_venc     jsonb;
  v_nv       integer;
  v_completa boolean;
  v_aviso    text;
  v_activas  text;
begin
  select * into v_r from public.payment_reports where id = p_report_id;
  if not found then
    return null;
  end if;
  select * into v_q from public.payment_quotes where id = v_r.quote_id;

  select coalesce(nullif(btrim(p.first_name), ''), nullif(split_part(btrim(coalesce(p.full_name, '')), ' ', 1), ''))
    into v_nombre
  from public.profiles p where p.id = v_r.user_id;

  if v_r.status::text = 'rejected' then
    v_txt := coalesce(v_nombre || ', ', '') ||
             format(E'no pudimos confirmar el pago que nos enviaste 😕\nMotivo: %s\n\nRevisa el comprobante y envíanoslo de nuevo por aquí. Si crees que es un error, lo vemos juntos.',
                    coalesce(nullif(btrim(v_r.rejection_note), ''), 'no encontramos ese pago en nuestra cuenta'));
    return upper(left(v_txt, 1)) || substr(v_txt, 2);
  end if;

  if v_r.status::text <> 'reconciled' then
    return null;
  end if;

  select string_agg(distinct c.order_number::text, ', #'),
         count(distinct c.id),
         string_agg(distinct public.helios_doctor_ref(c.merchant_id), ' y ')
    into v_ordenes, v_n, v_meds
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges c on c.id = i.charge_id
  where qi.quote_id = v_r.quote_id;

  select coalesce(sum(qi.amount_usd), 0) into v_eur_usd
  from public.payment_quote_items qi
  where qi.quote_id = v_r.quote_id and qi.currency = 'EUR';

  -- (2026-10-23): primero las gracias.
  v_txt := format(E'✅ ¡Gracias por tu pago%s! Ya está confirmado 💙\nRecibimos %s de %s #%s con %s.',
                  coalesce(', ' || v_nombre, ''),
                  public.helios_amounts_label(v_q.amount_usd - v_eur_usd, v_q.amount_eur),
                  case when v_n > 1 then 'tus órdenes' else 'tu orden' end,
                  coalesce(v_ordenes, ''), v_meds);

  v_pagadas := array(select qi.installment_id from public.payment_quote_items qi where qi.quote_id = v_r.quote_id);

  -- NUEVO (2026-11-12): las órdenes que este pago activó (pagó su inicial) y
  -- aún tienen cuotas por pagar.
  select string_agg(format(E'🎉 Tu pago en cuotas #%s con %s quedó activo.\n\n*Tus cuotas*\n%s\n\nTe escribiremos antes de cada fecha.',
                           a.order_number, public.helios_doctor_ref(a.merchant_id), a.cuotas),
                    E'\n\n' order by a.order_number)
    into v_activas
  from (
    select c.order_number, c.merchant_id,
           string_agg(format('%s %s · %s',
                             case i.sequence when 1 then '1️⃣' when 2 then '2️⃣' else i.sequence::text || '.' end,
                             public.helios_money_cur_text(coalesce(i.amount_cur, i.amount_usd), c.currency),
                             public.helios_dia_text(i.due_date)),
                      E'\n' order by i.sequence) as cuotas
    from public.charges c
    join public.installments i on i.charge_id = c.id and i.sequence > 0
                              and i.status = 'pending' and i.written_off_at is null
                              and not (i.id = any (v_pagadas))
    where c.status = 'confirmed'
      and c.activated_at is not null
      and c.id in (select i0.charge_id from public.installments i0
                   where i0.id = any (v_pagadas) and i0.sequence = 0)
    group by c.id, c.order_number, c.merchant_id
  ) a;

  -- ¿Terminó de pagar las órdenes de este pago?
  v_completa := not exists (
    select 1 from public.installments i
    where i.charge_id in (select i2.charge_id from public.installments i2 where i2.id = any (v_pagadas))
      and i.status = 'pending' and i.written_off_at is null
      and not (i.id = any (v_pagadas)));

  -- (2026-10-29), caso 4: lo que aún está vencido, de cualquier orden.
  v_venc := public.helios_vencidas_de(v_r.user_id, public.helios_business_date(now()), null, v_pagadas);
  v_nv   := (v_venc->>'n')::integer;

  if v_nv > 0 then
    v_aviso := case when v_nv = 1
      then format('⚠️ Aún tienes 1 cuota vencida: %s (venció el %s). Cuando la pagues, tu cuenta se reactiva.',
                  public.helios_amounts_label((v_venc->>'usd')::numeric, (v_venc->>'eur')::numeric),
                  public.helios_dia_text((v_venc->>'antigua')::date))
      else format('⚠️ Aún tienes %s cuotas vencidas por %s (la más antigua venció el %s). Cuando las pagues, tu cuenta se reactiva.',
                  v_nv, public.helios_amounts_label((v_venc->>'usd')::numeric, (v_venc->>'eur')::numeric),
                  public.helios_dia_text((v_venc->>'antigua')::date)) end;
  end if;

  if v_activas is not null then
    -- NUEVO: la orden activa y sus cuotas; si además debe algo vencido, debajo.
    v_resto := v_activas || coalesce(E'\n\n' || v_aviso, '');
  elsif v_nv > 0 then
    v_resto := v_aviso;
    if v_completa then
      v_resto := format(E'🎉 ¡Terminaste de pagar %s!\n\n',
                        case when v_n > 1 then 'esas consultas' else 'esa consulta' end) || v_resto;
    end if;
  else
    -- Lo que viene, de cualquier orden.
    select i.sequence, i.due_date, coalesce(i.amount_cur, i.amount_usd) as monto, c.currency,
           count(*) over () as quedan
      into v_sig
    from public.installments i
    join public.charges c on c.id = i.charge_id and c.status = 'confirmed'
    where i.user_id = v_r.user_id
      and i.status = 'pending' and i.written_off_at is null
      and not (i.id = any (v_pagadas))
    order by i.due_date, i.sequence
    limit 1;

    if v_sig is null or v_sig.sequence is null then
      v_resto := format('🎉 ¡Terminaste de pagar %s! Gracias por confiar en Helios para cuidar tu salud.',
                        case when v_n > 1 then 'tus consultas' else 'tu consulta' end);
    elsif v_sig.quedan = 1 then
      v_resto := case when v_completa then format(E'🎉 ¡Terminaste de pagar %s!\n\n',
                                                  case when v_n > 1 then 'esas consultas' else 'esa consulta' end) else '' end
                 || format('Te queda: %s.ª cuota de %s · %s', v_sig.sequence,
                           public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                           public.helios_dia_text(v_sig.due_date));
    else
      v_resto := case when v_completa then format(E'🎉 ¡Terminaste de pagar %s!\n\n',
                                                  case when v_n > 1 then 'esas consultas' else 'esa consulta' end) else '' end
                 || format('Tu próxima cuota: %s · %s',
                           public.helios_money_cur_text(v_sig.monto, v_sig.currency),
                           public.helios_dia_text(v_sig.due_date));
    end if;
  end if;

  -- (2026-10-23): cierra con la frase de niveles.
  return v_txt || E'\n\n' || v_resto || E'\n\n' || public.helios_level_up_phrase();
end;
$$;


-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_enqueue_charge_receipt(uuid)
-- Con inicial, el comprobante sale al activarse la orden: «Tu plan de pagos» enseña la inicial
-- pagada y las 2 cuotas, y ya no dice «sin inicial» (`plan_nota`). `n_cuotas` y `monto_cuota`
-- son los de las cuotas 1 y 2.
-- Una cuota ya pagada (el comprobante sale al final de la transacción del pago que activó la
-- orden) sale como «pagada el …», sin bolívares.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_enqueue_charge_receipt(p_charge_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_c        public.charges%rowtype;
  v_p        public.profiles%rowtype;
  v_m        public.merchants%rowtype;
  v_contact  public.platform_contact%rowtype;
  v_sede     text;
  v_staff    text;
  v_concepto text;
  v_cuotas   text;
  v_cuotas_h text;
  v_n        integer;
  v_first    public.installments%rowtype;
  v_orden    text;
  v_wa       text;
  v_wa_txt   text;
  v_link     text;
  v_font     constant text := $f$font-family:'Source Sans 3','Segoe UI',Arial,Helvetica,sans-serif;$f$;
  v_td       constant text := 'padding:14px 0;border-top:1px solid #E3E8F1;';
  v_aviso    text;
  v_aviso_h  text;
  v_noreco   text;
  v_noreco_h text;
  v_iva      numeric;
  v_rate     numeric;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found then
    raise exception 'Orden no encontrada' using errcode = 'P0002';
  end if;

  if v_c.status <> 'confirmed' or v_c.user_id is null then
    raise exception 'La orden no está confirmada' using errcode = '22023';
  end if;

  select * into v_p       from public.profiles  where id = v_c.user_id;
  select * into v_m       from public.merchants where id = v_c.merchant_id;
  select * into v_contact from public.platform_contact where id;
  select name into v_sede from public.merchant_branches where id = v_c.branch_id;

  -- Bolívares de hoy por unidad de la moneda de la orden.
  v_rate := public.helios_fx_rate(v_c.currency);

  -- Solo el nombre de pila de quien registró (docs/00 §7.3).
  v_staff := public.helios_staff_name(v_c.requested_by);
  v_staff := case
    when v_staff is null or position('@' in v_staff) > 0 then 'el personal de la clínica'
    else split_part(btrim(v_staff), ' ', 1)
  end;

  select string_agg(ci.name, ', ' order by ci.position) into v_concepto
  from public.charge_items ci where ci.charge_id = p_charge_id;

  -- Cada cuota en la moneda de la orden y, al lado, sus bolívares de hoy: el
  -- monto es fijo, los bolívares los da la tasa del día en que pague. En el
  -- HTML, dos columnas: «Cuota 1 / vence el…» y el monto con sus bolívares.
  -- NUEVO (2026-11-12, la inicial): la inicial va primero, ya pagada; no
  -- cuenta como cuota.
  select count(*) filter (where i.sequence > 0)::integer,
         string_agg(case when i.sequence = 0 then
                      format('• Inicial: %s, %s', public.helios_money_cur_text(i.amount_cur, v_c.currency),
                             case when i.status = 'paid' and i.paid_at is not null
                                  then 'pagada el ' || public.helios_weekday_es((i.paid_at at time zone 'America/Caracas')::date)
                                       || ' ' || to_char(i.paid_at at time zone 'America/Caracas', 'DD/MM/YYYY')
                                  else 'vence el ' || public.helios_weekday_es(i.due_date) || ' ' || to_char(i.due_date, 'DD/MM/YYYY') end)
                    else format('• Cuota %s: %s%s, %s', i.sequence,
                           public.helios_money_cur_text(i.amount_cur, v_c.currency),
                           -- NUEVO (2026-11-12, la inicial): una cuota ya pagada, sin bolívares.
                           case when v_rate is not null and i.status <> 'paid'
                                then ' (hoy ' || public.helios_ves_text(round(i.amount_cur * v_rate, 2)) || ')'
                                else '' end,
                           x0.cuando) end,
                    E'\n' order by i.sequence),
         string_agg(case when i.sequence = 0 then format(
             '<tr><td style="%s%s">'
             '<span style="font-size:16px;line-height:22px;font-weight:600;color:#050F2C;">Inicial</span><br>'
             '<span style="font-size:14px;line-height:20px;color:#46526F;">%s</span></td>'
             '<td align="right" style="%s%s">'
             '<span style="font-size:18px;line-height:24px;font-weight:700;color:#050F2C;">%s</span></td></tr>',
             v_td, v_font,
             public.helios_html_escape(upper(left(x0.cuando, 1)) || substr(x0.cuando, 2)),
             v_td, v_font,
             public.helios_html_escape(public.helios_money_cur_text(i.amount_cur, v_c.currency)))
           else format(
             '<tr><td style="%s%s">'
             '<span style="font-size:16px;line-height:22px;font-weight:600;color:#050F2C;">Cuota %s</span><br>'
             '<span style="font-size:14px;line-height:20px;color:#46526F;">%s</span></td>'
             '<td align="right" style="%s%s">'
             '<span style="font-size:18px;line-height:24px;font-weight:700;color:#050F2C;">%s</span>%s</td></tr>',
             v_td, v_font, i.sequence,
             -- NUEVO (2026-11-12, la inicial): «Vence el…» o «Pagada el…».
             public.helios_html_escape(upper(left(x0.cuando, 1)) || substr(x0.cuando, 2)),
             v_td, v_font,
             public.helios_html_escape(public.helios_money_cur_text(i.amount_cur, v_c.currency)),
             case when v_rate is not null and i.status <> 'paid'
                  then '<br><span style="font-size:13px;line-height:18px;color:#6B7690;">hoy '
                       || public.helios_html_escape(public.helios_ves_text(round(i.amount_cur * v_rate, 2)))
                       || '</span>'
                  else '' end) end,
           '' order by i.sequence)
    into v_n, v_cuotas, v_cuotas_h
  from public.installments i
  cross join lateral (select case when i.status = 'paid' and i.paid_at is not null
                                  then 'pagada el ' || public.helios_weekday_es((i.paid_at at time zone 'America/Caracas')::date)
                                       || ' ' || to_char(i.paid_at at time zone 'America/Caracas', 'DD/MM/YYYY')
                                  else 'vence el ' || public.helios_weekday_es(i.due_date) || ' ' || to_char(i.due_date, 'DD/MM/YYYY') end as cuando) x0
  where i.charge_id = p_charge_id;

  if coalesce(v_n, 0) = 0 then
    raise exception 'La orden no tiene cuotas' using errcode = '22023';
  end if;

  select * into v_first from public.installments
  where charge_id = p_charge_id and sequence > 0 order by sequence limit 1;  -- NUEVO (2026-11-12, la inicial)

  v_orden := coalesce(v_c.order_number::text, left(v_c.id::text, 8));
  v_wa    := v_contact.whatsapp_number;

  if v_wa is not null then
    v_wa_txt := coalesce(public.helios_format_ve_phone(v_wa), v_wa);
    v_link := 'https://wa.me/' || regexp_replace(v_wa, '\D', '', 'g') || '?text='
              || public.helios_url_encode(format('Hola, quiero avisar un pago de la orden #%s', v_orden));
    v_aviso := format('Cuando pagues, envíanos el comprobante por WhatsApp al %s: %s', v_wa_txt, v_link);
    -- El botón «a prueba de clientes»: la celda lleva el color (Outlook no
    -- pinta el fondo de un <a>) y el enlace, el relleno.
    v_aviso_h := format(
      '<p style="margin:0 0 16px 0;">Cuando pagues, env&iacute;anos el comprobante por WhatsApp al <strong style="color:#050F2C;">%s</strong>, indicando la orden #%s.</p>'
      '<table role="presentation" border="0" cellpadding="0" cellspacing="0"><tr>'
      '<td bgcolor="#045EF3" style="background-color:#045EF3;border-radius:999px;">'
      '<a href="%s" target="_blank" style="display:inline-block;padding:13px 26px;%sfont-size:16px;line-height:20px;font-weight:600;color:#FFFFFF;text-decoration:none;border-radius:999px;">Avisar mi pago por WhatsApp</a>'
      '</td></tr></table>',
      public.helios_html_escape(v_wa_txt), public.helios_html_escape(v_orden),
      public.helios_html_escape(v_link), v_font);
    v_noreco := format('Si no reconoces este pago en cuotas, escríbenos enseguida por WhatsApp al %s%s.',
                       v_wa_txt, coalesce(' o a ' || v_contact.support_email, ''));
  else
    v_link := '';
    v_aviso := 'Helios te escribirá por WhatsApp con las instrucciones para avisar tu pago.';
    v_aviso_h := '<p style="margin:0;">Helios te escribir&aacute; por WhatsApp con las instrucciones para avisar tu pago.</p>';
    v_noreco := case
      when v_contact.support_email is not null then
        format('Si no reconoces este pago en cuotas, escríbenos enseguida a %s.', v_contact.support_email)
      else 'Si no reconoces este pago en cuotas, escríbenos enseguida respondiendo a este correo.'
    end;
  end if;
  v_noreco_h := '<strong>' || public.helios_html_escape(v_noreco) || '</strong>';

  -- El IVA de la comisión, como porcentaje de la comisión (el que se cobró de
  -- verdad), igual que en la pregunta al paciente.
  v_iva := case when coalesce(v_c.consumer_fee_usd, 0) > 0
                then round(v_c.consumer_fee_vat_usd * 100 / v_c.consumer_fee_usd, 2)
                else public.helios_parameter('vat_pct', 16) end;

  return public.helios_enqueue_message(
    'comprobante_financiamiento', v_c.user_id, p_charge_id, 'email',
    jsonb_build_object(
      'nombre_completo', coalesce(nullif(btrim(v_p.full_name), ''),
                                  btrim(concat_ws(' ', v_p.first_name, v_p.last_name))),
      'documento', coalesce(public.helios_mask_document(v_p.document_number), '—'),
      -- Al paciente se le nombra a su médico (20261106233000): «la Dra. Ana
      -- Lara» en las frases, «Dra. Ana Lara» en la fila del detalle.
      'medico', public.helios_doctor_ref(v_m.id),
      'medico_nombre', public.helios_doctor_name(v_m.id),
      'clinica_rif', case when v_m.tax_id is not null then '(RIF ' || v_m.tax_id || ')' else '' end,
      'sede', coalesce(v_sede, '—'),
      'registrado_por', v_staff,
      'orden', v_orden,
      'fecha_hora', to_char(coalesce(v_c.confirmed_at, v_c.created_at) at time zone 'America/Caracas',
                            'DD/MM/YYYY HH24:MI'),
      'concepto', coalesce(v_concepto, 'Consulta'),
      'moneda', public.helios_currency_name(v_c.currency),
      'monto_consulta', public.helios_money_cur_text(coalesce(v_c.base_cur, v_c.amount_cur), v_c.currency),
      'servicio_helios', public.helios_money_cur_text(coalesce(v_c.consumer_fee_cur, 0)
                                                      + coalesce(v_c.consumer_fee_vat_cur, 0), v_c.currency),
      'servicio_helios_pct', rtrim(to_char(coalesce(v_c.consumer_fee_pct, 0), 'FM990.##'), '.'),
      -- Al paciente sí se le enseña la comisión, su IVA y el total (Javier,
      -- 2026-10-06): es lo que paga.
      'comision_servicio', public.helios_money_cur_text(coalesce(v_c.consumer_fee_cur, 0), v_c.currency),
      'iva_pct', public.helios_pct_text(v_iva),
      'iva_comision', public.helios_money_cur_text(coalesce(v_c.consumer_fee_vat_cur, 0), v_c.currency),
      'total', public.helios_money_cur_text(v_c.amount_cur, v_c.currency),
      'total_bs', case when v_rate is null then 'el equivalente en bolívares'
                       else public.helios_ves_text(round(v_c.amount_cur * v_rate, 2)) end,
      'n_cuotas', v_n::text,
      -- NUEVO (2026-11-12, la inicial): «Tu plan de pagos (sin inicial)» solo en las
      -- órdenes de antes.
      'plan_nota', case when coalesce(v_c.down_payment_pct, 0) > 0 then '' else ' (sin inicial)' end,
      'plan_nota_html', case when coalesce(v_c.down_payment_pct, 0) > 0 then '' else ' &middot; sin inicial' end,
      'cuotas', v_cuotas,
      'cuotas_html', v_cuotas_h,
      'monto_cuota', public.helios_money_cur_text(v_first.amount_cur, v_c.currency),
      'fecha', to_char(v_first.due_date, 'DD/MM/YYYY'),
      'whatsapp_link', v_link,
      'aviso_pago', v_aviso,
      'aviso_pago_html', v_aviso_h,
      'no_reconoces', v_noreco,
      'no_reconoces_html', v_noreco_h
    ),
    null, null);
end;
$function$;


-- Las vistas del asistente del superadmin ──────────────────────────────────
-- `asistente.ordenes`: cuatro columnas nuevas al final (la inicial).
-- `asistente.cuotas`: también las cuotas de una orden que espera la inicial
-- (la inicial es la cuota `numero` 0 y nunca sale vencida).

create or replace view asistente.ordenes as
 SELECT ch.id AS orden_id,
    ch.order_number AS numero_orden,
    ch.user_id,
    asistente.nombre_corto(p.first_name, p.last_name, p.full_name) AS paciente,
    ch.merchant_id AS clinica_id,
    m.name AS clinica,
    asistente.medico(m.doctor_title, m.owner_name) AS medico,
    b.name AS sede,
    ch.concept AS concepto,
    asistente.estado('orden'::text, (ch.status)::text) AS estado,
    ch.channel AS canal,
    ch.currency AS moneda,
    ch.business_date AS dia,
    ch.created_at AS creada_at,
    ch.answered_at AS respondida_at,
    ch.confirmed_at AS confirmada_at,
    ch.voided_at AS anulada_at,
    ch.base_usd AS consulta_usd,
    ch.consumer_fee_usd AS comision_usd,
    ch.consumer_fee_vat_usd AS comision_iva_usd,
    ch.amount_usd AS total_a_cobrar_usd,
    ch.merchant_net_usd AS a_la_clinica_usd,
    ch.base_cur AS consulta_en_moneda,
    ch.decline_reason AS motivo_rechazo,
    -- NUEVO (2026-11-12, la inicial).
    ch.down_payment_pct AS inicial_pct,
    ch.down_payment_due_at AS inicial_vence_at,
    ch.activated_at AS activada_at,
    ch.down_payment_expired_at AS anulada_sin_inicial_at
   FROM (((public.charges ch
     LEFT JOIN public.profiles p ON ((p.id = ch.user_id)))
     LEFT JOIN public.merchants m ON ((m.id = ch.merchant_id)))
     LEFT JOIN public.merchant_branches b ON ((b.id = ch.branch_id)))
  WHERE (NOT ch.is_test);

create or replace view asistente.cuotas as
 SELECT i.id AS cuota_id,
    i.charge_id AS orden_id,
    ch.order_number AS numero_orden,
    i.user_id,
    asistente.nombre_corto(p.first_name, p.last_name, p.full_name) AS paciente,
    ch.merchant_id AS clinica_id,
    m.name AS clinica,
    ch.business_date AS dia_de_la_orden,
    ch.currency AS moneda,
    i.sequence AS numero,
    i.due_date AS vence_el,
    asistente.estado('cuota'::text, (i.status)::text) AS estado,
    ((i.status = 'pending'::public.installment_status) AND (i.written_off_at IS NULL) AND (i.due_date < asistente.hoy()) AND (i.sequence > 0)) AS vencida,
        CASE
            WHEN ((i.status = 'pending'::public.installment_status) AND (i.written_off_at IS NULL) AND (i.due_date < asistente.hoy()) AND (i.sequence > 0)) THEN (asistente.hoy() - i.due_date)
            ELSE NULL::integer
        END AS dias_atraso,
    i.amount_usd AS cuota_usd,
    i.financed_usd AS consulta_usd,
    i.amount_cur AS cuota_en_moneda,
    i.paid_at AS pagada_at,
    ((i.paid_at AT TIME ZONE 'America/Caracas'::text))::date AS pagada_dia,
    i.written_off_at AS castigada_at
   FROM (((public.installments i
     JOIN public.charges ch ON (((ch.id = i.charge_id) AND (ch.status = ANY (ARRAY['confirmed'::public.charge_status, 'awaiting_down_payment'::public.charge_status])))))
     LEFT JOIN public.merchants m ON ((m.id = ch.merchant_id)))
     LEFT JOIN public.profiles p ON ((p.id = i.user_id)))
  WHERE ((NOT i.is_test) AND (NOT ch.is_test));


-- ──────────────────────────────────────────────────────────────────────────
-- public.merchant_transactions(date,date,integer)
-- La lista de /financiamientos: también las órdenes que esperan la inicial y las que se anularon
-- solas por no pagarla. Columnas nuevas al final, `down_payment_due_at` y `down_payment_expired_at`
-- (cambia el tipo de retorno: se borra y se crea, con sus permisos de siempre). Las fechas de las
-- cuotas, solo de una orden viva (confirmed, pending, awaiting_down_payment): en las demás no hay
-- cuotas y el plan sería inventado.
-- ──────────────────────────────────────────────────────────────────────────

drop function if exists public.merchant_transactions(date, date, integer);

CREATE OR REPLACE FUNCTION public.merchant_transactions(p_from date, p_to date, p_limit integer DEFAULT 500)
 RETURNS TABLE(charge_id uuid, order_number bigint, business_date date, confirmed_at timestamp with time zone, amount_usd numeric, merchant_sale_usd numeric, customer_name text, staff_name text, cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date, concept text, beneficiary_name text, receipt_status text, staff_commission_usd numeric, registered_by_name text, status text, expires_at timestamp with time zone, currency text, merchant_sale_cur numeric, down_payment_due_at timestamp with time zone, down_payment_expired_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.created_at as creado,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro,
           c.concept as concepto,
           c.beneficiary_name as atendido,
           c.staff_commission_usd as comision,
           c.status::text as estado,
           c.expires_at as vence,
           c.down_payment_due_at as limite_inicial,  -- NUEVO (2026-11-12, la inicial)
           c.down_payment_expired_at as inicial_vencida,
           c.currency as moneda,
           coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)) as sale_cur
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      -- NUEVO (2026-11-12, la inicial): las que esperan la inicial y las que se anularon por no pagarla.
      and (c.status in ('confirmed', 'pending', 'declined', 'expired', 'awaiting_down_payment')
           or (c.status = 'reverted' and c.down_payment_expired_at is not null))
      and c.business_date between p_from and p_to
      -- El gerente de ESA clínica ve todos; cualquier otro, solo los suyos.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    order by c.business_date desc, coalesce(c.confirmed_at, c.created_at) desc
    limit v_limit
  ),
  cuotas as (
    select (m.id)                                                  as cid,
           (x->>'sequence')::integer                               as seq,
           (x->>'due_date')::date                                  as due,
           public.helios_settlement_run_for((x->>'settlement_due_date')::date) as run
    from mias m
    cross join lateral jsonb_array_elements(public.helios_charge_planned_installments(m.id)) x
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         p.full_name,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         -- NUEVO (2026-11-12, la inicial): solo de una orden viva.
         case when m.estado in ('confirmed', 'pending', 'awaiting_down_payment') then c1.due end,
         case when m.estado in ('confirmed', 'pending', 'awaiting_down_payment') then c1.run end,
         case when m.estado in ('confirmed', 'pending', 'awaiting_down_payment') then c2.due end,
         case when m.estado in ('confirmed', 'pending', 'awaiting_down_payment') then c2.run end,
         m.concepto,
         m.atendido,
         case when m.estado = 'confirmed' then public.helios_charge_receipt(m.id) ->> 'status'
              else 'sin_enviar' end,
         m.comision,
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         m.estado,
         case when m.estado in ('pending', 'expired') then m.vence end,
         m.moneda,
         m.sale_cur,
         case when m.estado = 'awaiting_down_payment' then m.limite_inicial end,
         m.inicial_vencida
  from mias m
  left join public.profiles p on p.id = m.quien
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, coalesce(m.conf, m.creado) desc;
end;
$function$;

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated, service_role;

-- ──────────────────────────────────────────────────────────────────────────
-- public.merchant_charge_detail(uuid)
-- El detalle de /financiamientos: los datos de la inicial (sin montos ni pagos del paciente) y
-- solo las cuotas 1 y 2, que son las que tienen un pago a la clínica.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.merchant_charge_detail(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_charge  public.charges%rowtype;
  v_gerente boolean;
  v_out     jsonb;
begin
  -- La secretaria que solo registra no consulta el historial (2026-10-29).
  perform public.helios_assert_ve_el_historial();

  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := coalesce(public.my_merchant_id_as_gerente() = v_charge.merchant_id, false);

  if not v_gerente and v_charge.requested_by is distinct from auth.uid() then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    -- NUEVO (2026-11-12, la inicial): la inicial de la orden (null o 0 = sin
    -- inicial), hasta cuándo puede pagarla, cuándo quedó activa y, si se anuló
    -- sola por no pagarla, cuándo.
    'down_payment_pct', c.down_payment_pct,
    'down_payment_due_at', c.down_payment_due_at,
    'activated_at', c.activated_at,
    'down_payment_expired_at', c.down_payment_expired_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- El nombre del paciente, y nada más de él (ni deuda ni pagos).
    'customer_name', p.full_name,
    'staff_name', public.helios_staff_name(c.requested_by),
    'merchant_sale_usd', public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd),
    'base_usd', c.base_usd,
    'vat_usd', c.vat_usd,
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', case when v_gerente then c.merchant_fee_usd end,
    'merchant_fee_vat_usd', case when v_gerente then c.merchant_fee_vat_usd end,
    'merchant_net_usd', case when v_gerente then c.merchant_net_usd end,
    -- En la moneda en la que cobró la clínica: lo que se le enseña.
    'currency', c.currency,
    'merchant_sale_cur', coalesce(c.base_cur, public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)),
    'base_cur', c.base_cur,
    'consumer_fee_cur', c.consumer_fee_cur,
    'consumer_fee_vat_cur', c.consumer_fee_vat_cur,
    'merchant_net_cur', case when v_gerente then c.merchant_net_cur end,
    'is_gerente', v_gerente,
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission_usd', c.staff_commission_usd,
    'commission_staff_name', case when c.commission_staff_id is not null
                                  then public.helios_staff_name(c.commission_staff_id) end,
    'payer_count', 1
  )
  into v_out
  from public.charges c
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd,
      'line_total_cur', round(ci.line_total_usd * coalesce(v_charge.base_cur, v_charge.base_usd)
                              / nullif(v_charge.base_usd, 0), 2)
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Las cuotas del paciente: SOLO sus fechas (`due_date`) y cuándo se le paga a
  -- la clínica la mitad que corresponde (`run_date`, de su propia fecha). Nunca
  -- si el paciente pagó.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'sequence', m.seq,
      'due_date', m.due,
      'run_date', public.helios_settlement_run_for(m.cobro),
      'paid_to_merchant_on', (
        select max(coalesce(mp.paid_on, mp.business_date))
        from public.settlements s
        join public.merchant_payout_items it on it.settlement_id = s.id
        join public.merchant_payouts mp on mp.id = it.payout_id
        where s.charge_id = p_charge_id
          and s.reason = 'scheduled_installment'
          and s.business_date = m.cobro
          and s.status = 'paid'
      )
    ) order by m.seq)
    from (
      select i.sequence as seq, min(i.due_date) as due, min(i.settlement_due_date) as cobro
      from public.installments i
      where i.charge_id = p_charge_id
        and i.sequence > 0  -- NUEVO (2026-11-12, la inicial): la inicial no es de la clínica
      group by i.sequence
    ) m
  ), '[]'::jsonb));

  -- Cuándo se le paga a la clínica cada parte: el adelanto (si lo hay), cada
  -- mitad y la comisión del personal. Los montos, solo al gerente. Cada parte
  -- en su moneda (`currency`, `amount_cur`): la consulta en la de la orden y
  -- la comisión en dólares.
  v_out := v_out || jsonb_build_object('payouts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', x.kind,
      'sequence', x.seq,
      'due_date', x.due,
      'run_date', public.helios_settlement_run_for(x.due),
      'amount_usd', case when v_gerente or x.kind = 'staff_commission' then x.amount end,
      'paid_usd', case when v_gerente or x.kind = 'staff_commission' then x.paid end,
      'status', case when v_gerente or x.kind = 'staff_commission' then x.status end,
      'currency', x.moneda,
      'amount_cur', case when v_gerente or x.kind = 'staff_commission' then x.amount_c end,
      'paid_cur', case when v_gerente or x.kind = 'staff_commission' then x.paid_c end
    ) order by x.due, x.seq nulls first)
    from (
      select 'advance'::text    as kind,
             null::smallint     as seq,
             s.due_date         as due,
             s.amount_usd       as amount,
             s.paid_usd         as paid,
             s.status::text     as status,
             s.currency         as moneda,
             s.amount_cur       as amount_c,
             s.paid_cur         as paid_c
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'advance'

      union all

      select 'installment',
             m.seq,
             m.cobro,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             coalesce(s.currency, v_charge.currency),
             s.amount_cur,
             s.paid_cur
      from (
        select i.sequence as seq, min(i.settlement_due_date) as cobro
        from public.installments i
        where i.charge_id = p_charge_id
          and i.sequence > 0  -- NUEVO (2026-11-12, la inicial)
        group by i.sequence
      ) m
      left join public.settlements s
        on s.charge_id = p_charge_id
       and s.reason = 'scheduled_installment'
       and s.business_date = m.cobro

      union all

      select 'staff_commission',
             null::smallint,
             s.due_date,
             s.amount_usd,
             s.paid_usd,
             s.status::text,
             s.currency,
             s.amount_cur,
             s.paid_cur
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'staff_commission'
    ) x
  ), '[]'::jsonb));

  return v_out;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_charge_for_staff(uuid)
-- Lo que devuelven /registrar, el reenvío y el bot del médico: los datos de la inicial y su monto
-- (`installments` ya trae la fila de la inicial, `sequence` 0). Una orden que espera la inicial
-- aún no tiene comprobante.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_charge_for_staff(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me    uuid := auth.uid();
  v_c     public.charges%rowtype;
  v_p     public.profiles%rowtype;
  v_role  public.merchant_role;
  v_name  text;
  v_open  boolean;
  v_rate  numeric;
begin
  select * into v_c from public.charges where id = p_charge_id;

  -- El mismo error exista o no: probar ids a ciegas no dice cuáles son de otra
  -- clínica. El gerente ve todos los de su clínica; la secretaria, los suyos.
  if not found or not (
    public.is_platform_admin()
    or exists (
      select 1 from public.merchant_users mu
      where mu.user_id = v_me and mu.merchant_id = v_c.merchant_id and mu.is_active
        and (mu.role = 'gerente' or v_c.requested_by = v_me)
    )
  ) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  select * into v_p from public.profiles where id = v_c.user_id;

  select mu.role into v_role
  from public.merchant_users mu
  where mu.user_id = v_c.requested_by and mu.merchant_id = v_c.merchant_id
  order by mu.is_active desc, (mu.role = 'gerente') desc, mu.created_at desc
  limit 1;

  v_name := public.helios_staff_name(v_c.requested_by);
  v_open := v_c.status in ('pending', 'declined', 'expired', 'awaiting_down_payment');  -- NUEVO (2026-11-12, la inicial)
  -- Bolívares de hoy por unidad de la moneda de la orden, para las cuotas.
  v_rate := public.helios_fx_rate(v_c.currency);

  return jsonb_build_object(
    'id', v_c.id,
    'order_number', v_c.order_number,
    'status', v_c.status::text,
    'channel', v_c.channel,
    'created_at', v_c.created_at,
    'confirmed_at', v_c.confirmed_at,
    -- NUEVO (2026-11-12, la inicial): la inicial de la orden (null o 0 = sin
    -- inicial), hasta cuándo puede pagarla, cuándo quedó activa y, si se anuló
    -- sola por no pagarla, cuándo.
    'down_payment_pct', v_c.down_payment_pct,
    'down_payment_due_at', v_c.down_payment_due_at,
    'activated_at', v_c.activated_at,
    'down_payment_expired_at', v_c.down_payment_expired_at,
    'void_reason', v_c.void_reason,
    'expires_at', case when v_c.status in ('pending', 'expired') then v_c.expires_at end,
    'business_date', v_c.business_date,
    'merchant_id', v_c.merchant_id,
    'merchant_name', (select m.name from public.merchants m where m.id = v_c.merchant_id),
    'branch_id', v_c.branch_id,
    'branch_name', (select b.name from public.merchant_branches b where b.id = v_c.branch_id),
    'currency', v_c.currency,
    -- La base: lo que se le paga a la clínica. Nunca un total con el fee.
    'merchant_sale_usd', public.helios_merchant_sale_usd(v_c.base_usd, v_c.vat_usd, v_c.amount_usd),
    'merchant_sale_cur', coalesce(v_c.base_cur, public.helios_merchant_sale_usd(v_c.base_usd, v_c.vat_usd, v_c.amount_usd)),
    'concept', v_c.concept,
    'beneficiary_name', v_c.beneficiary_name,
    'patient', jsonb_build_object(
      'nombre', coalesce(nullif(btrim(v_p.full_name), ''),
                         nullif(btrim(concat_ws(' ', v_p.first_name, v_p.last_name)), '')),
      'documento_enmascarado', public.helios_mask_document(v_p.document_number),
      'email_enmascarado', public.helios_mask_email(v_p.email)
    ),
    -- Las cuotas llevan el fee dentro: es donde se permite verlo.
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sequence', (x->>'sequence')::integer,
               'due_date', (x->>'due_date')::date,
               'amount_usd', (x->>'amount_usd')::numeric,
               'amount_cur', (x->>'amount_cur')::numeric,
               'amount_ves', case when v_rate is not null
                                  then round((x->>'amount_cur')::numeric * v_rate, 2) end)
             order by (x->>'sequence')::integer)
      from jsonb_array_elements(public.helios_charge_planned_installments(v_c.id)) x
    ), '[]'::jsonb),
    'breakdown', jsonb_build_object(
      'base_usd', v_c.base_usd,
      'consumer_fee_pct', v_c.consumer_fee_pct,
      'consumer_fee_usd', v_c.consumer_fee_usd,
      'consumer_fee_vat_usd', v_c.consumer_fee_vat_usd,
      'base_cur', v_c.base_cur,
      'consumer_fee_cur', v_c.consumer_fee_cur,
      'consumer_fee_vat_cur', v_c.consumer_fee_vat_cur
    ),
    'tasa_bcv', v_rate,
    'receipt', case
      when v_open then jsonb_build_object(
        'status', 'sin_enviar', 'sent_at', null, 'last_event', null,
        'email_enmascarado', public.helios_mask_email(v_p.email))
      else public.helios_charge_receipt(v_c.id)
    end,
    'confirmation', public.helios_charge_confirmation(v_c.id),
    'decline_reason', v_c.decline_reason,
    'decline_message', case v_c.decline_reason
      when 'paciente' then 'El paciente rechazó el pago en cuotas'
      when 'no_disponible' then public.helios_not_available_message()
    end,
    'registered_by', case
      when v_name is null then null
      when v_role is null then v_name
      else v_name || ' (' || case v_role when 'gerente' then 'Administrador' else 'Secretaria' end || ')'
    end,
    'staff_commission_usd', v_c.staff_commission_usd
  );
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.admin_charge_detail(uuid)
-- La ficha de la orden en el superadmin: los datos de la inicial; la inicial nunca tiene días
-- de atraso.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_charge_detail(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today    date := public.helios_business_date(now());
  v_charge   public.charges%rowtype;
  v_financed numeric(18,4);
  v_out      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    -- NUEVO (2026-11-12, la inicial): la inicial de la orden (null o 0 = sin
    -- inicial), hasta cuándo puede pagarla, cuándo quedó activa y, si se anuló
    -- sola por no pagarla, cuándo.
    'down_payment_pct', c.down_payment_pct,
    'down_payment_due_at', c.down_payment_due_at,
    'activated_at', c.activated_at,
    'down_payment_expired_at', c.down_payment_expired_at,
    'void_reason', c.void_reason,
    'amount_usd', c.amount_usd,
    'financed_usd', v_financed,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', c.merchant_fee_usd,
    'merchant_fee_vat_usd', c.merchant_fee_vat_usd,
    'merchant_net_usd', c.merchant_net_usd,
    -- La moneda en la que cobró la clínica y lo cobrado en ella. Todo lo de
    -- arriba son dólares; esto es solo para saberlo.
    'currency', c.currency,
    'fx_usd_per_unit', c.fx_usd_per_unit,
    'amount_cur', c.amount_cur,
    'base_cur', c.base_cur,
    'consumer_fee_cur', c.consumer_fee_cur,
    'consumer_fee_vat_cur', c.consumer_fee_vat_cur,
    'is_group', c.group_id is not null,
    'group_id', c.group_id,
    'is_test', c.is_test,
    'merchant', jsonb_build_object(
      'id', m.id, 'name', m.name, 'legal_name', m.legal_name, 'tax_id', m.tax_id
    ),
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    'user', case when p.id is null then null else jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone_e164', p.phone_e164,
      'document_number', p.document_number, 'email', p.email
    ) end,
    -- Helios
    'concept', c.concept,
    'beneficiary_name', c.beneficiary_name,
    'registered_by', c.requested_by,
    'registered_by_name', public.helios_staff_name(c.requested_by),
    'terms_version', (select t.version from public.terms_versions t where t.id = c.terms_version_id),
    'receipt', public.helios_charge_receipt(c.id),
    'staff_commission', (
      select jsonb_build_object(
        'id', sc.id,
        'amount_usd', sc.amount_usd,
        'staff_user_id', sc.staff_user_id,
        'staff_name', public.helios_staff_name(sc.staff_user_id),
        'status', sc.status,
        'settlement_id', sc.settlement_id,
        'created_at', sc.created_at
      )
      from public.staff_commissions sc where sc.charge_id = c.id
    )
  )
  into v_out
  from public.charges c
  join public.merchants m on m.id = c.merchant_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'user_id', i.user_id,
      'full_name', pi.full_name,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'financed_usd', i.financed_usd,
      'amount_cur', i.amount_cur,
      'due_date', i.due_date,
      'status', i.status::text,
      'paid_at', i.paid_at,
      'written_off_at', i.written_off_at,
      'days_overdue', case
        when i.status = 'paid' or i.written_off_at is not null then 0
        when i.sequence = 0 then 0  -- NUEVO (2026-11-12, la inicial): la inicial nunca está en atraso
        else greatest(v_today - i.due_date, 0)
      end
    ) order by pi.full_name nulls last, i.user_id, i.sequence)
    from public.installments i
    left join public.profiles pi on pi.id = i.user_id
    where i.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('split', coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', x.user_id,
      'full_name', pr.full_name,
      'phone_e164', pr.phone_e164,
      'financed_usd', x.financed_usd,
      'payable_usd', x.payable_usd,
      'installments_paid', x.paid,
      'installments_total', x.total,
      'started_it', x.user_id = v_charge.user_id,
      'reason', null
    ) order by x.payable_usd desc nulls last, pr.full_name nulls last)
    from (
      select i.user_id,
             sum(i.financed_usd)                                  as financed_usd,
             sum(i.amount_usd)                                    as payable_usd,
             count(*) filter (where i.status = 'paid')::integer    as paid,
             count(*)::integer                                     as total
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.user_id
    ) x
    join public.profiles pr on pr.id = x.user_id
  ), '[]'::jsonb));

  -- Los mensajes de este financiamiento (comprobante, bienvenida, avisos).
  v_out := v_out || jsonb_build_object('messages', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', o.id, 'channel', o.channel, 'template_key', o.template_key,
      'status', o.status, 'recipient', o.recipient, 'last_event', o.last_event,
      'created_at', o.created_at, 'sent_at', o.sent_at
    ) order by o.created_at)
    from public.outbound_messages o where o.charge_id = p_charge_id
  ), '[]'::jsonb));

  v_out := v_out || jsonb_build_object('group', null::jsonb);

  return v_out;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.bot_paciente_resumen(uuid)
-- «Mi saldo y cuotas» y «Pagar mi cuota» del bot del paciente: también la orden que espera la
-- inicial, con su estado y su plazo. La inicial nunca sale «vencida».
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.bot_paciente_resumen(p_profile_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_hoy date := public.helios_business_date(now());
  v_lvl public.levels%rowtype;
begin
  select l.* into v_lvl
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_profile_id;

  return jsonb_build_object(
    'nombre', (select coalesce(nullif(btrim(p.first_name), ''), split_part(btrim(coalesce(p.full_name, '')), ' ', 1))
               from public.profiles p where p.id = p_profile_id),
    -- Cada orden en su moneda: la consulta y las cuotas en ella; el cargo por
    -- atraso, en dólares. `cuotas`: las pendientes; `pagadas` (2026-10-19):
    -- las ya pagadas de la misma orden.
    'financiamientos', coalesce((
      select jsonb_agg(f order by f->>'primera')
      from (
        select jsonb_build_object(
                 'orden', c.order_number,
                 'clinica', m.name,
                 'medico', public.helios_doctor_name(c.merchant_id),
                 'medico_ref', public.helios_doctor_ref(c.merchant_id),
                 'moneda', c.currency,
                 -- NUEVO (2026-11-12, la inicial): 'confirmed' o 'awaiting_down_payment'.
                 'estado', c.status::text,
                 'inicial_vence_at', c.down_payment_due_at,
                 'consulta', coalesce(c.base_cur, c.base_usd, c.amount_usd),
                 'primera', min(i.due_date),
                 'cuotas', jsonb_agg(jsonb_build_object(
                             'sequence', i.sequence,
                             'due_date', i.due_date,
                             'monto', coalesce(i.amount_cur, i.amount_usd),
                             'cargo_atraso', coalesce((select sum(lf.amount_usd) from public.late_fees lf
                                                       where lf.installment_id = i.id and lf.status = 'pending'), 0),
                             'vencida', i.due_date < v_hoy and i.sequence > 0)
                           order by i.due_date, i.sequence),
                 'pagadas', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'sequence', pi.sequence,
                            'due_date', pi.due_date,
                            'monto', coalesce(pi.amount_cur, pi.amount_usd))
                          order by pi.sequence)
                   from public.installments pi
                   where pi.charge_id = c.id and pi.status = 'paid'), '[]'::jsonb)) as f
        from public.installments i
        join public.charges c on c.id = i.charge_id and c.status in ('confirmed', 'awaiting_down_payment')
        join public.merchants m on m.id = c.merchant_id
        where i.user_id = p_profile_id and i.status = 'pending' and i.written_off_at is null
        group by c.id, c.order_number, m.name, c.merchant_id, c.currency, c.base_cur, c.base_usd, c.amount_usd,
                 c.status, c.down_payment_due_at
      ) x
    ), '[]'::jsonb),
    -- NUEVO (2026-10-23): su nivel y el saldo total que le da.
    'nivel', v_lvl.level,
    'nivel_nombre', v_lvl.label,
    'limite_usd', coalesce(v_lvl.monthly_limit_usd, 0),
    -- Lo que puede usar hoy (la misma cifra que ve el médico) y, si es cero,
    -- por qué ('cuota_vencida', 'estado', 'bloqueo').
    'disponible_usd', public.helios_available_now_usd(p_profile_id),
    'bloqueo', public.helios_available_blocked_reason(p_profile_id),
    'tasa_bcv', public.current_fx_rate('BCV'),
    'tasa_bcv_eur', public.current_fx_rate('BCV_EUR'),
    'cuentas_de_cobro', public.helios_payment_accounts_text(),
    'datos_de_pago', public.helios_payment_accounts_block(),
    'pago_en_revision', exists (select 1 from public.payment_reports r
                                where r.user_id = p_profile_id and r.status in ('reported', 'in_review'))
  );
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- asistente.estado(text,text)
-- El asistente del superadmin nombra el estado nuevo.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION asistente.estado(p_dominio text, p_valor text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select coalesce(case p_dominio || ':' || p_valor
    when 'paciente:pending_kyc'  then 'sin verificar'
    when 'paciente:pending_pin'  then 'sin PIN'
    when 'paciente:active'       then 'activo'
    when 'paciente:frozen'       then 'congelado'
    when 'paciente:suspended'    then 'suspendido'
    when 'paciente:expelled'     then 'cerrado'
    when 'orden:pending'         then 'esperando al paciente'
    when 'orden:confirmed'       then 'confirmada'
    when 'orden:awaiting_down_payment' then 'esperando la inicial'
    when 'orden:voided'          then 'anulada'
    when 'orden:reverted'        then 'revertida'
    when 'orden:declined'        then 'rechazada por el paciente'
    when 'orden:expired'         then 'vencida sin respuesta'
    when 'cuota:pending'         then 'pendiente'
    when 'cuota:paid'            then 'pagada'
    when 'pago:reported'         then 'reportado'
    when 'pago:in_review'        then 'en revisión'
    when 'pago:reconciled'       then 'aprobado'
    when 'pago:rejected'         then 'rechazado'
    when 'pago:duplicate'        then 'duplicado'
    when 'clinica:active'        then 'activa'
    when 'clinica:paused'        then 'pausada'
    when 'clinica:terminated'    then 'cerrada'
    when 'liquidacion:pending'   then 'pendiente'
    when 'liquidacion:partial'   then 'pagada en parte'
    when 'liquidacion:paid'      then 'pagada'
    when 'motivo:advance'               then 'adelanto'
    when 'motivo:scheduled_installment' then 'mitad de la consulta'
    when 'motivo:on_collection'         then 'al cobrar'
    when 'motivo:staff_commission'      then 'comisión del personal'
  end, p_valor)
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.merchant_sales_export(date,date)
-- El libro de ventas de la clínica: una orden con inicial que nunca se activó nunca fue una venta y
-- no sale, se anulara sola o la revirtiera el equipo (las revertidas que sí fueron ventas siguen
-- saliendo).
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.merchant_sales_export(p_from date, p_to date)
 RETURNS TABLE(order_number bigint, charge_id uuid, business_date date, confirmed_at timestamp with time zone, branch_name text, cashier text, status text, void_reason text, group_name text, payer_count integer, item_count integer, base_usd numeric, vat_pct numeric, vat_usd numeric, sale_usd numeric, consumer_fee_pct numeric, consumer_fee_usd numeric, consumer_fee_vat_usd numeric, charged_to_customer_usd numeric, merchant_fee_pct numeric, merchant_fee_usd numeric, merchant_fee_vat_usd numeric, net_to_merchant_usd numeric, fx_rate numeric, sale_ves numeric, charged_to_customer_ves numeric, net_to_merchant_ves numeric, cuota_1_due date, cuota_1_run date, cuota_2_due date, cuota_2_run date, settled_usd numeric, paid_usd numeric, is_test boolean, concept text, beneficiary_name text, staff_commission_usd numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 20000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica puede descargar sus pagos en cuotas'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charges c
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted') and not (coalesce(c.down_payment_pct, 0) > 0 and c.activated_at is null);

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  with ventas as (
    select c.*,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           public.current_fx_rate('BCV', c.business_date) as rate
    from public.charges c
    where c.merchant_id = v_merchant
      and c.business_date between p_from and p_to
      and c.status in ('confirmed', 'reverted') and not (coalesce(c.down_payment_pct, 0) > 0 and c.activated_at is null)
  ),
  cuotas as (
    select i.charge_id as cid,
           i.sequence  as seq,
           min(i.due_date) as due,
           public.helios_settlement_run_for(min(i.settlement_due_date)) as run
    from public.installments i
    join ventas v on v.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  lineas as (
    select ci.charge_id as cid, count(*)::integer as n
    from public.charge_items ci
    join ventas v on v.id = ci.charge_id
    group by ci.charge_id
  ),
  liquidado as (
    -- Lo liquidado por la VENTA: la comisión del personal va en su columna.
    select s.charge_id as cid,
           sum(s.amount_usd) as programado,
           sum(coalesce(s.paid_usd, 0)) as pagado
    from public.settlements s
    join ventas v on v.id = s.charge_id
    where s.reason <> 'staff_commission'
    group by s.charge_id
  )
  select
    v.order_number,
    v.id,
    v.business_date,
    v.confirmed_at,
    b.name,
    public.helios_staff_name(v.requested_by),
    v.status::text,
    v.void_reason,
    v.group_name,
    1,
    coalesce(l.n, 0),
    round(coalesce(v.base_usd, 0), 2),
    coalesce(v.vat_pct, 0),
    round(coalesce(v.vat_usd, 0), 2),
    round(v.sale, 2),
    coalesce(v.consumer_fee_pct, 0),
    round(coalesce(v.consumer_fee_usd, 0), 2),
    round(coalesce(v.consumer_fee_vat_usd, 0), 2),
    round(v.amount_usd, 2),
    coalesce(v.merchant_fee_pct, 0),
    round(coalesce(v.merchant_fee_usd, 0), 2),
    round(coalesce(v.merchant_fee_vat_usd, 0), 2),
    round(coalesce(v.merchant_net_usd, v.sale), 2),
    v.rate,
    round(v.sale * v.rate, 2),
    round(v.amount_usd * v.rate, 2),
    round(coalesce(v.merchant_net_usd, v.sale) * v.rate, 2),
    c1.due, c1.run,
    c2.due, c2.run,
    round(coalesce(s.programado, 0), 2),
    round(coalesce(s.pagado, 0), 2),
    v.is_test,
    v.concept,
    v.beneficiary_name,
    v.staff_commission_usd
  from ventas v
  left join public.merchant_branches b on b.id = v.branch_id
  left join lineas l on l.cid = v.id
  left join liquidado s on s.cid = v.id
  left join cuotas c1 on c1.cid = v.id and c1.seq = 1
  left join cuotas c2 on c2.cid = v.id and c2.seq = 2
  order by v.business_date, v.confirmed_at, v.order_number;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.merchant_sales_export_items(date,date)
-- Las líneas del libro de ventas: lo mismo que merchant_sales_export.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.merchant_sales_export_items(p_from date, p_to date)
 RETURNS TABLE(order_number bigint, charge_id uuid, business_date date, confirmed_at timestamp with time zone, branch_name text, status text, line_no smallint, product_id uuid, product_name text, quantity integer, unit_price_usd numeric, line_total_usd numeric, fx_rate numeric, line_total_ves numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_merchant uuid := public.my_merchant_id_as_gerente();
  v_max      integer := 50000;
  v_count    bigint;
begin
  if v_merchant is null then
    raise exception 'Solo el administrador de la clínica puede descargar sus pagos en cuotas'
      using errcode = '42501';
  end if;

  select count(*) into v_count
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted') and not (coalesce(c.down_payment_pct, 0) > 0 and c.activated_at is null);

  perform public.helios_assert_sales_export(p_from, p_to, v_count, v_max);

  return query
  select
    c.order_number,
    c.id,
    c.business_date,
    c.confirmed_at,
    b.name,
    c.status::text,
    ci.position,
    ci.product_id,
    ci.name,
    ci.quantity,
    round(ci.unit_price_usd, 2),
    round(ci.line_total_usd, 2),
    r.rate,
    round(ci.line_total_usd * r.rate, 2)
  from public.charge_items ci
  join public.charges c on c.id = ci.charge_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join lateral (
    select public.current_fx_rate('BCV', c.business_date) as rate
  ) r on true
  where c.merchant_id = v_merchant
    and c.business_date between p_from and p_to
    and c.status in ('confirmed', 'reverted') and not (coalesce(c.down_payment_pct, 0) > 0 and c.activated_at is null)
  order by c.business_date, c.confirmed_at, c.order_number, ci.position;
end;
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.admin_charges(text,uuid,text,date,date,integer)
-- La lista de órdenes del superadmin: los datos de la inicial, en cuatro columnas nuevas al final
-- (cambia el tipo de retorno: se borra y se crea, con sus permisos de siempre).
-- `installments_total` sigue contando todas las cuotas (con la inicial, 3): con
-- `down_payment_pct` > 0 la cuota 0 es «Inicial» y las demás «Cuota N de 2».
-- ──────────────────────────────────────────────────────────────────────────

drop function if exists public.admin_charges(text, uuid, text, date, date, integer);

CREATE OR REPLACE FUNCTION public.admin_charges(p_search text DEFAULT NULL::text, p_merchant_id uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_limit integer DEFAULT 100)
 RETURNS TABLE(charge_id uuid, order_number bigint, amount_usd numeric, status text, business_date date, created_at timestamp with time zone, confirmed_at timestamp with time zone, void_reason text, user_id uuid, full_name text, phone_e164 text, user_status text, merchant_id uuid, merchant_name text, branch_name text, is_group boolean, is_test boolean, installments_paid integer, installments_total integer, financed_usd numeric, concept text, beneficiary_name text, registered_by_name text, staff_commission_usd numeric, document_number text, doctor_name text, currency text, fx_usd_per_unit numeric, amount_cur numeric, financed_cur numeric, down_payment_pct numeric, down_payment_due_at timestamp with time zone, activated_at timestamp with time zone, down_payment_expired_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_needle text;
  v_order  bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  if v_needle ~ '^#?\d{1,18}$' then
    v_order := replace(v_needle, '#', '')::bigint;
  else
    v_order := null;
  end if;

  return query
  select
    ch.id,
    ch.order_number,
    ch.amount_usd,
    ch.status::text,
    ch.business_date,
    ch.created_at,
    ch.confirmed_at,
    ch.void_reason,
    ch.user_id,
    p.full_name,
    p.phone_e164,
    p.status::text,
    m.id,
    m.name,
    b.name,
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer,
    coalesce(ch.base_usd, ch.amount_usd)::numeric,
    ch.concept,
    ch.beneficiary_name,
    public.helios_staff_name(ch.requested_by),
    ch.staff_commission_usd,
    p.document_number,
    public.helios_doctor_name(m.id),
    -- NUEVO: la moneda en la que se hizo y sus montos en esa moneda.
    ch.currency,
    ch.fx_usd_per_unit,
    coalesce(ch.amount_cur, ch.amount_usd)::numeric,
    coalesce(ch.base_cur, ch.amount_cur, ch.base_usd, ch.amount_usd)::numeric,
    -- NUEVO (2026-11-12, la inicial).
    ch.down_payment_pct::numeric,
    ch.down_payment_due_at,
    ch.activated_at,
    ch.down_payment_expired_at
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    select ins.charge_id as cid,
           count(*) filter (where ins.status = 'paid')::integer as paid,
           count(*)::integer as total
    from public.installments ins group by 1
  ) i on i.cid = ch.id
  where
    (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    and (p_status is null or ch.status::text = p_status)
    and (p_from is null or ch.business_date >= p_from)
    and (p_to is null or ch.business_date <= p_to)
    and (
      v_needle is null
      or (v_order is not null and ch.order_number = v_order)
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or p.email ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
      or m.owner_name ilike '%' || v_needle || '%'
      or ch.concept ilike '%' || v_needle || '%'
      or ch.beneficiary_name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$function$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated, service_role;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_admin_payment_item(uuid,date)
-- La Caja: la inicial de la orden (`down_payment_pct`, para decir «Inicial» y «Cuota N de 2») y
-- la inicial nunca tiene días de atraso.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_admin_payment_item(p_report_id uuid, p_today date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'report_id',      r.id,
    'status',         r.status::text,
    'created_at',     r.created_at,
    'method',         r.method,
    'bank',           r.bank,
    'reference',      r.reference,
    'payer_document', r.payer_document,
    'payer_phone',    r.payer_phone,
    'rejection_note', r.rejection_note,
    'reviewed_at',      r.reviewed_at,
    'reviewed_by',      r.reviewed_by,
    'reviewed_by_name', case when r.reviewed_by is not null
                             then coalesce(pa.full_name, 'Alguien del equipo') end,

    'amount_usd',        q.amount_usd,
    'amount_ves',        q.amount_ves,
    'fx_rate',           q.fx_rate,
    'installment_count', q.installment_count,
    'installments_usd',  q.amount_usd - q.late_fee_usd,
    'late_fee_usd',      q.late_fee_usd,
    'installments_financed_usd', fin.financed_usd,
    'installments_fee_usd',      (q.amount_usd - q.late_fee_usd) - fin.financed_usd,

    -- NUEVO: la moneda y la tasa de cada parte del pago.
    'monedas',      mon.monedas,
    'fx_rate_eur',  q.fx_rate_eur,
    'amount_eur',   q.amount_eur,
    'usd_part_usd', q.amount_usd - mon.eur_usd,
    'eur_part_usd', mon.eur_usd,

    'user', jsonb_build_object(
      'user_id',         p.id,
      'full_name',       p.full_name,
      'phone_e164',      p.phone_e164,
      'document_number', p.document_number,
      'status',          p.status::text,
      'level',           p.level
    ),

    'reference_collisions', (
      select count(*) filter (where r2.id <> r.id) from public.payment_reports r2
      where r2.bank = r.bank and r2.reference = r.reference
        and r2.reference is not null and r2.status <> 'rejected'
    ),
    'statement_matches', (
      select count(*) from public.bank_statement_lines l
      where r.reference is not null
        and l.reference like '%' || r.reference
        and public.helios_monto_cuadra(l.amount_ves, q.amount_ves)
        and l.moved_on between (coalesce(r.paid_on, r.created_at::date) - 5)
                           and (coalesce(r.paid_on, r.created_at::date) + 5)
    ),
    'statement_matches_available', (
      select count(*) from public.helios_statement_candidates(r.id) c
      where c.used_by_report_id is null and not c.discarded
    ),
    'statement_line', (
      select jsonb_build_object(
        'id', sl.id, 'bank', sl.bank, 'moved_on', sl.moved_on,
        'reference', sl.reference, 'amount_ves', sl.amount_ves,
        'description', sl.description
      )
      from public.bank_statement_lines sl
      where sl.id = r.statement_line_id
    ),

    'purchases', coalesce((
      select jsonb_agg(purchase order by business_date nulls last, order_number nulls last)
      from (
        select
          ch.business_date,
          ch.order_number,
          jsonb_build_object(
            'charge_id',         ch.id,
            'order_number',      ch.order_number,
            'merchant_id',       m.id,
            'merchant_name',     m.name,
            'branch_name',       b.name,
            'charge_amount_usd', ch.amount_usd,
            'charge_status',     ch.status::text,
            'business_date',     ch.business_date,
            'confirmed_at',      ch.confirmed_at,
            'is_group',          ch.group_id is not null,
            'group_name',        ch.group_name,
            -- NUEVO
            'currency',          ch.currency,
            'down_payment_pct',  ch.down_payment_pct,  -- NUEVO (2026-11-12, la inicial)
            'installments_total', (
              select count(*) from public.installments t
              where t.charge_id = ch.id and t.user_id = r.user_id
            ),
            'installments', jsonb_agg(jsonb_build_object(
              'installment_id', ins.id,
              'sequence',       ins.sequence,
              'quoted_usd',     qi.amount_usd,
              -- NUEVO
              'quoted_cur',     coalesce(qi.amount_cur, qi.amount_usd),
              'amount_usd',     ins.amount_usd,
              'financed_usd',   ins.financed_usd,
              'fee_usd',        qi.amount_usd - ins.financed_usd,
              'due_date',       ins.due_date,
              'status',         ins.status::text,
              'days_overdue',   case when ins.sequence = 0 then 0 else greatest(p_today - ins.due_date, 0) end,  -- NUEVO (2026-11-12, la inicial)
              'other_reports', (
                select count(*)
                from public.payment_quote_items qi2
                join public.payment_reports r2 on r2.quote_id = qi2.quote_id
                where qi2.installment_id = ins.id and r2.id <> r.id
              )
            ) order by ins.sequence)
          ) as purchase
        from public.payment_quote_items qi
        join public.installments ins on ins.id = qi.installment_id
        join public.charges ch on ch.id = ins.charge_id
        join public.merchants m on m.id = ch.merchant_id
        join public.merchant_branches b on b.id = ch.branch_id
        where qi.quote_id = q.id
        group by ch.id, m.id, b.id
      ) g
    ), '[]'::jsonb),

    'late_fees', coalesce((
      select jsonb_agg(jsonb_build_object(
        'late_fee_id',    f.id,
        'amount_usd',     fl.amount_usd,
        'days_late',      f.days_late,
        'business_date',  f.business_date,
        'installment_id', f.installment_id,
        'sequence',       ins.sequence,
        'order_number',   ch.order_number,
        'merchant_name',  m.name,
        'orphan', f.installment_id is null or not exists (
          select 1 from public.payment_quote_items qi3
          where qi3.quote_id = q.id and qi3.installment_id = f.installment_id
        )
      ) order by f.business_date, f.created_at)
      from public.payment_quote_late_fees fl
      join public.late_fees f on f.id = fl.late_fee_id
      left join public.installments ins on ins.id = f.installment_id
      left join public.charges ch on ch.id = ins.charge_id
      left join public.merchants m on m.id = ch.merchant_id
      where fl.quote_id = q.id
    ), '[]'::jsonb),

    -- ── Helios: el pago lo registró el equipo ────────────────────────────
    'registered_by',       r.registered_by,
    'registered_by_name',  case when r.registered_by is not null
                                then coalesce(ra.full_name, 'Alguien del equipo') end,
    'paid_on',             r.paid_on,
    'declared_amount_ves', r.declared_amount_ves,
    'note',                r.note,
    'receipt_path',        r.receipt_path,
    -- Para pedir la URL firmada: storage.from(bucket).createSignedUrl(path).
    'receipt', case when r.receipt_path is not null then
                 jsonb_build_object('bucket', 'payment-receipts', 'path', r.receipt_path) end,
    'four_eyes',   public.helios_payment_four_eyes(),
    'can_approve', public.helios_can_approve_payment(r.id, auth.uid())
  )
  from public.payment_reports r
  join public.payment_quotes q on q.id = r.quote_id
  join public.profiles p on p.id = r.user_id
  left join public.platform_admins pa on pa.user_id = r.reviewed_by
  left join public.platform_admins ra on ra.user_id = r.registered_by
  cross join lateral (
    select coalesce(sum(i2.financed_usd), 0)::numeric as financed_usd
    from public.payment_quote_items qi4
    join public.installments i2 on i2.id = qi4.installment_id
    where qi4.quote_id = q.id
  ) fin
  -- NUEVO: las monedas del pago (los cargos por atraso, en dólares) y lo que
  -- va a la tasa del euro, en dólares del libro.
  cross join lateral (
    select
      coalesce(
        to_jsonb(array_agg(distinct x.currency order by x.currency desc)),
        '[]'::jsonb
      ) as monedas,
      coalesce(sum(x.usd) filter (where x.currency = 'EUR'), 0)::numeric as eur_usd
    from (
      select coalesce(qi5.currency, 'USD') as currency, qi5.amount_usd as usd
      from public.payment_quote_items qi5
      where qi5.quote_id = q.id
      union all
      select 'USD', q.late_fee_usd where q.late_fee_usd > 0
    ) x
  ) mon
  where r.id = p_report_id
$function$;

-- ──────────────────────────────────────────────────────────────────────────
-- public.helios_admin_user_detail_base(uuid)
-- La ficha del paciente: la inicial nunca está vencida ni en atraso, y «Sus financiamientos»
-- (`consumos`) trae los datos de la inicial.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.helios_admin_user_detail_base(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'is_test', p.is_test,
    'created_at', p.created_at,
    -- PODA (Helios): el avatar lo elegía la persona en la app
    -- (`avatar_colors`, `avatar_emojis`). Las claves quedan en null.
    'avatar_emoji', null::text,
    'avatar_color', null::text
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at,
    -- Lo que puede gastar HOY, con la misma puerta que una compra. Con una
    -- cuota vencida, la cuenta sin activar o un bloqueo, es 0.
    'available_now_usd', public.helios_available_now_usd(p_user_id),
    -- El mismo cupo, sin mirar si hoy puede gastarlo.
    'available_nominal_usd', greatest(v_limit - public.helios_credit_used_usd(p_user_id), 0),
    'available_blocked_reason', public.helios_available_blocked_reason(p_user_id)
  ));

  -- Lo dado por perdido (written_off_at) no es deuda viva: no entra en lo
  -- que debe, ni en lo vencido, ni en los días de atraso, igual que en
  -- metricas.cuotas (estado 'perdida'). Va aparte, en written_off_usd.
  -- (20260927696000; antes sumaba toda cuota 'pending'.)
  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today
                  and sequence > 0), 0),  -- NUEVO (2026-11-12, la inicial)
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      -- FINANCED: el consumo de sus cuotas pagadas, la cifra que mide el
      -- motor de niveles (level_standing). paid_usd lleva el fee dentro.
      'paid_financed_usd', coalesce(sum(financed_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today
                  and sequence > 0), 0),  -- NUEVO (2026-11-12, la inicial)
      -- PAYABLE: las cuotas sin pagar dadas por perdidas, con su consumo.
      'written_off_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is not null), 0),
      'written_off_financed_usd', coalesce(sum(financed_usd)
        filter (where status = 'pending' and written_off_at is not null), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      -- El número de la orden de la que sale esta cuota: es lo que el equipo
      -- teclea en el buscador y lo que el local dicta por teléfono.
      'order_number', ch.order_number,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      -- Lo que esta cuota lleva de consumo, sin el servicio.
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', case when i.sequence = 0 then 0 else greatest(v_today - i.due_date, 0) end,  -- NUEVO (2026-11-12, la inicial)
      -- Dada por perdida: sigue 'pending' pero ya no es deuda viva.
      'written_off_at', i.written_off_at,
      -- El día operativo en que REPORTÓ el pago que la saldó (sin reporte, el
      -- de la aprobación): el mismo que metricas.cuotas.pagada_dia.
      'paid_day', case when i.status = 'paid' then
        coalesce(metricas.dia_operativo(pr.created_at), metricas.dia_operativo(i.paid_at)) end,
      -- Cobrada a tiempo con la regla canónica (metricas.a_tiempo: el día del
      -- reporte, como mucho el vencimiento más los días de gracia).
      'on_time', case when i.status = 'paid' then
        metricas.a_tiempo(coalesce(metricas.dia_operativo(pr.created_at),
                                   metricas.dia_operativo(i.paid_at)), i.due_date) end
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    left join public.payment_reports pr on pr.id = i.paid_by_report_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'order_number', ch.order_number,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason,
      -- El consumo entero, sin el servicio de Ronda (amount_usd lo lleva).
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'merchant_id', ch.merchant_id
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  -- Los consumos en los que ESTÁ: los que puso (charges.user_id) y aquellos en
  -- los que tiene cuotas. En un grupo el cargo es de quien abrió la cuenta y
  -- las cuotas son de cada quien, así que `charges` (arriba) se queda corto.
  -- Todo en financed: la cuenta entera y su parte (la suma de sus cuotas).
  v_result := v_result || jsonb_build_object('consumos', coalesce((
    with mias as (
      select i.charge_id, sum(i.financed_usd) as parte
      from public.installments i
      where i.user_id = p_user_id
      group by i.charge_id
    ),
    ids as (
      select ch.id from public.charges ch where ch.user_id = p_user_id
      union
      select mias.charge_id from mias
    )
    select jsonb_agg(jsonb_build_object(
      'charge_id', ch.id,
      'order_number', ch.order_number,
      'status', ch.status,
      'business_date', ch.business_date,
      'created_at', ch.created_at,
      'confirmed_at', ch.confirmed_at,
      'void_reason', ch.void_reason,
      -- NUEVO (2026-11-12, la inicial).
      'down_payment_pct', ch.down_payment_pct,
      'down_payment_due_at', ch.down_payment_due_at,
      'activated_at', ch.activated_at,
      'down_payment_expired_at', ch.down_payment_expired_at,
      'merchant_id', ch.merchant_id,
      'merchant_name', m.name,
      'group_id', ch.group_id,
      'is_group', ch.group_id is not null,
      'started_it', coalesce(ch.user_id = p_user_id, false),
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'share_financed_usd', mi.parte
    ) order by ch.created_at desc)
    from ids
    join public.charges ch on ch.id = ids.id
    join public.merchants m on m.id = ch.merchant_id
    left join mias mi on mi.charge_id = ch.id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at,
      -- amount_usd = cuotas (consumo + service fee) + cargos por atraso. Sus
      -- sumandos, para no enseñar un total con el fee sin desglose.
      'cuotas_payable_usd', coalesce(it.payable, 0),
      'cuotas_financed_usd', coalesce(it.financed, 0),
      'cuotas_fee_usd', coalesce(it.payable, 0) - coalesce(it.financed, 0),
      'late_fees_usd', coalesce(lf.cargos, 0)
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    left join lateral (
      select sum(qi.amount_usd) as payable, sum(i.financed_usd) as financed
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id
    ) it on true
    left join lateral (
      select sum(qf.amount_usd) as cargos
      from public.payment_quote_late_fees qf
      where qf.quote_id = q.id
    ) lf on true
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  -- PODA (Helios): la verificación de identidad (`kyc.verifications`), los
  -- Bits (`bits_entries`) y los aparatos de la app (`user_devices`) se fueron
  -- con la app. Las claves se quedan vacías para no cambiar la forma.
  v_result := v_result || jsonb_build_object(
    'kyc', null::jsonb,
    'bits', null::jsonb,
    'bits_entries', '[]'::jsonb,
    'devices', '[]'::jsonb
  );

  -- Helios (docs/01 §2.4): la ficha del paciente.
  v_result := v_result || jsonb_build_object('datos', public.helios_patient_datos(p_user_id));

  return v_result;
end;
$function$;


-- 10. Las condiciones v4 ──────────────────────────────────────────────────
-- Se publican como la v3 (20261106220100): se apaga la vigente y entra la
-- nueva. Cada orden guarda las suyas al registrarse (`terms_version_id`): las
-- de antes siguen con la v3 («sin inicial»). Cambian el punto 1 (la inicial,
-- su plazo y la anulación), el 2 (la inicial también lleva su parte de la
-- comisión) y el 4 (el límite se libera al pagar la inicial y las dos cuotas).

update public.terms_versions set is_current = false where version = 'v3';

insert into public.terms_versions (version, body, summary, is_current)
values (
  'v4',
  $terminos$Condiciones del pago en cuotas con Helios

1. Helios te permite pagar tu consulta o tratamiento en la clínica con una inicial del 50% del total el mismo día y 2 cuotas: la primera vence 14 días después de la fecha de la orden y la segunda, 28 días después. Tu pago en cuotas queda activo cuando Helios recibe la inicial. Si no la pagas dentro de las 2 horas siguientes a aceptar, la orden se anula y no debes nada.
2. La inicial y cada cuota incluyen una parte del monto de la consulta y de la comisión de servicio de Helios: 12% sobre el monto de la consulta, más el IVA de la comisión (16%). El comprobante detalla la comisión, su IVA, el total, la inicial y cada cuota.
3. Los montos están en la moneda de tu consulta, dólares o euros. Pagas en bolívares, a la tasa oficial del Banco Central de Venezuela para esa moneda del día en que pagues, por Pago Móvil o transferencia a las cuentas de Helios que aparecen en el comprobante. Después de pagar, envía el comprobante del pago por WhatsApp a Helios.
4. Tu límite inicial es de $150. Lo que pagas en cuotas ocupa ese límite hasta que pagues la inicial y las dos cuotas de la orden; entonces se libera.
5. Desde el día siguiente al vencimiento de una cuota sin pagar no podrás registrar otro pago en cuotas con Helios hasta ponerte al día.
6. A los 30 días de atraso la cuenta se suspende. A los 60 días se cierra, la cédula queda en la lista de personas que no pueden usar Helios y la deuda pasa a cobranza.
7. Helios puede contactarte por WhatsApp, por teléfono o por correo, a ti o al contacto de referencia que diste al registrarte, para recordarte tus pagos.
8. Si no reconoces un pago en cuotas a tu nombre, escríbenos enseguida por WhatsApp.
9. Helios es un servicio operado por Quarto Latam, C.A.$terminos$,
  'Condiciones v4: inicial del 50% el mismo día (si no se paga en 2 horas, la orden se anula) y 2 cuotas a 14 y 28 días, comisión de servicio 12% + IVA, límite inicial $150, suspensión a los 30 días y cierre a los 60. Opera Quarto Latam, C.A.',
  true
);
