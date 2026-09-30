-- ============================================================================
-- Ronda — Los Bits dejan de ser todo o nada y pasan a ser una ESCALERA
--
-- Decisión de negocio (2026-09-08, docs/00-BASES §2.10): pagar una cuota el
-- mismo día operativo de la compra da **100 Bits**, cada día que pasa vale
-- **10 menos**, y hay un **suelo de 30** — que es justo lo que paga el día del
-- vencimiento. En mora no se gana nada.
--
--   días desde la compra    0    1    2    3    4    5    6    7   8–14  luego
--   cuota 1 (vence +7)     100   90   80   70   60   50   40   30    ·      0
--   cuota 2 (vence +14)    100   90   80   70   60   50   40   30   30      0
--
-- Sustituye a la regla del 2026-08-25: 100 Bits por cuota pagada ANTES de su
-- vencimiento, y cero en cualquier otro caso.
--
-- ---------------------------------------------------------------------------
-- POR QUÉ SE CAMBIA
-- ---------------------------------------------------------------------------
-- El todo o nada solo le hablaba a quien ya iba a adelantar. Al que pagaba el
-- día justo —que es el comportamiento que sostiene el negocio: el punto de
-- equilibrio del impago está en el 16,7%— le decía que su puntualidad no valía
-- nada. Y tenía un escalón absurdo: esperar un día de más costaba 0 Bits seis
-- veces y los 100 de golpe la séptima. Ahora cada día cuesta lo mismo, 10.
--
-- El techo no se mueve (una noche pagada el día de la compra sigue valiendo
-- 200); lo que sube es el suelo, de 0 a 60.
--
-- ---------------------------------------------------------------------------
-- EL RELOJ ARRANCA EN LA COMPRA, NO EN EL VENCIMIENTO
-- ---------------------------------------------------------------------------
-- `charges.business_date` — el día operativo del consumo, el mismo del que ya
-- salen los vencimientos (`helios_installment_due_dates`). Con un solo origen,
-- las dos cuotas de una noche valen lo mismo el mismo día y la escalera se
-- explica sin nombrar ninguna fecha: "hoy cada cuota te da 80". Midiendo
-- contra el vencimiento, la cuota 2 —que nace con una semana más de plazo—
-- pagaría siempre más que la 1 por el mismo dinero y el mismo día.
--
-- La consecuencia, y está asumida (§2.10): la cuota 2 pasa del día 7 al 14 en
-- el suelo. Lo que el negocio compra es el dinero de la PRIMERA semana.
--
-- ---------------------------------------------------------------------------
-- LO QUE NO CAMBIA
-- ---------------------------------------------------------------------------
-- · Se otorgan al CONCILIAR y se miden contra la fecha del REPORTE del
--   usuario, no contra la de la aprobación (20260825190000). Con la escalera
--   eso importa el doble: cada día en la cola no restaría 100, restaría 10, y
--   el premio dependería de lo que tarde un operador.
-- · Un trigger sobre `installments`, no una llamada dentro de
--   `reconcile_payment`: lo que se premia es un cambio de estado, y así lo
--   capta venga el pago de donde venga.
-- · Una cuota premia UNA vez (el índice único sigue ahí).
-- · Un aviso por PAGO, no uno por cuota.
--
-- ---------------------------------------------------------------------------
-- POR QUÉ SE RENOMBRA EL `reason`
-- ---------------------------------------------------------------------------
-- `early_installment` describía la regla vieja: solo el adelanto premiaba.
-- Ahora premia toda cuota que no entra en mora, así que el valor pasa a
-- `installment_paid`. Se reescriben las filas ya otorgadas —el hecho es el
-- mismo, una cuota que se paga y premia— y con ellas el check y el índice
-- único. Dejarlo como estaba habría dejado en la base un nombre que miente
-- sobre la mitad de sus filas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Los tres números
-- ---------------------------------------------------------------------------
-- Funciones y no constantes en línea, como la escalera de mora
-- (`helios_late_fee_usd` y compañía): son parámetros de negocio, la app los LEE
-- en vez de repetirlos en pantalla, y moverlos tiene que ser un
-- `create or replace` de una línea que cambie a la vez el premio y lo que
-- promete la app ya instalada.

create or replace function public.helios_bits_same_day()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 100 $fn$;

comment on function public.helios_bits_same_day() is
  'Bits que gana una cuota pagada el mismo día operativo de la compra.';

create or replace function public.helios_bits_daily_step()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 10 $fn$;

comment on function public.helios_bits_daily_step() is
  'Bits que se pierden por cada día que pasa desde la compra.';

create or replace function public.helios_bits_floor()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 30 $fn$;

comment on function public.helios_bits_floor() is
  'Suelo de la escalera: lo que paga como mínimo una cuota pagada a tiempo.';

revoke all on function public.helios_bits_same_day() from public, anon;
revoke all on function public.helios_bits_daily_step() from public, anon;
revoke all on function public.helios_bits_floor() from public, anon;
grant execute on function public.helios_bits_same_day() to authenticated;
grant execute on function public.helios_bits_daily_step() to authenticated;
grant execute on function public.helios_bits_floor() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La fórmula, en UN solo sitio
-- ---------------------------------------------------------------------------
-- La leen el trigger que premia y el acuse que la promete. Si cada uno la
-- escribiera por su lado, el acuse podría volver a prometer lo que el saldo
-- no enseña — que es el bug del 2026-09-02.
--
-- Las tres fechas son días OPERATIVOS (10:00 a 10:00, docs/05 §1): quien
-- compra el martes por la noche y paga a las 3 de la madrugada del miércoles
-- ha pagado el mismo día.

create or replace function public.helios_bits_for_installment(
  p_purchase_date date,
  p_due_date      date,
  p_paid_date     date
)
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$
  select case
    -- Mora: no se gana nada, y es lo único que da cero.
    when p_paid_date > p_due_date then 0
    else greatest(
      public.helios_bits_floor(),
      public.helios_bits_same_day()
        - public.helios_bits_daily_step() * greatest(p_paid_date - p_purchase_date, 0)
    )
  end
$fn$;

comment on function public.helios_bits_for_installment(date, date, date) is
  'Bits que paga una cuota: 100 el día de la compra, -10 por día, suelo 30, y 0 en mora.';

revoke all on function public.helios_bits_for_installment(date, date, date) from public, anon;
grant execute on function public.helios_bits_for_installment(date, date, date) to authenticated;

-- El parámetro de la regla vieja se retira: un solo entero ya no puede
-- describir lo que paga una cuota. Lo que la app leía en su sitio
-- (`my_bits().per_installment`) se explica abajo.
drop function if exists public.helios_bits_per_early_installment();

-- ---------------------------------------------------------------------------
-- 3. El libro: el motivo pasa a llamarse por lo que de verdad premia
-- ---------------------------------------------------------------------------
-- El check se cae antes del UPDATE: si no, la propia reescritura lo violaría.

alter table public.bits_entries drop constraint if exists bits_entries_reason_check;

update public.bits_entries
set reason = 'installment_paid'
where reason = 'early_installment';

alter table public.bits_entries
  add constraint bits_entries_reason_check check (reason in ('installment_paid'));

-- Una cuota premia UNA vez. Igual que antes, pero colgado del motivo nuevo:
-- el índice es parcial y con el valor viejo habría dejado de proteger nada.
drop index if exists public.bits_entries_installment_unique;

create unique index bits_entries_installment_unique
  on public.bits_entries (installment_id)
  where reason = 'installment_paid';

-- ---------------------------------------------------------------------------
-- 4. El premio
-- ---------------------------------------------------------------------------

create or replace function public.award_bits_for_installment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reported_at timestamptz;
  v_paid_on     date;
  v_purchase    date;
  v_amount      integer;
begin
  -- Cuándo pagó el USUARIO, no cuándo lo aprobó el panel. Se descartan los
  -- reportes muertos —`rejected`, `duplicate`—: si la cuota se saldó, fue por
  -- otro. Dentro de `reconcile_payment` el reporte que la está saldando sigue
  -- en `reported` —se marca `reconciled` después del bucle—, así que los tres
  -- estados vivos tienen que entrar.
  select pr.created_at into v_reported_at
  from public.payment_reports pr
  join public.payment_quote_items qi on qi.quote_id = pr.quote_id
  where qi.installment_id = new.id
    and pr.status in ('reported', 'in_review', 'reconciled')
  order by pr.created_at desc
  limit 1;

  v_paid_on := public.helios_business_date(
    coalesce(v_reported_at, new.paid_at, now())
  );

  -- El día operativo de la compra: el origen del reloj.
  select ch.business_date into v_purchase
  from public.charges ch
  where ch.id = new.charge_id;

  v_amount := case
    when v_purchase is not null
      then public.helios_bits_for_installment(v_purchase, new.due_date, v_paid_on)
    -- Una cuota sin compra no debería existir —el día operativo se sella al
    -- confirmar—, pero si aparece no hay reloj que medir: se paga el suelo, y
    -- solo si no es mora. Inventarle un origen la premiaría de más.
    when v_paid_on <= new.due_date then public.helios_bits_floor()
    else 0
  end;

  if v_amount > 0 then
    insert into public.bits_entries (user_id, amount, reason, installment_id)
    values (new.user_id, v_amount, 'installment_paid', new.id)
    on conflict do nothing;
  end if;

  return null;
end;
$$;

comment on function public.award_bits_for_installment() is
  'Otorga los Bits de la escalera al saldarse una cuota que no iba en mora.';

revoke all on function public.award_bits_for_installment()
  from public, anon, authenticated;

drop trigger if exists installments_award_bits on public.installments;

create trigger installments_award_bits
  after update of status on public.installments
  for each row
  when (old.status = 'pending' and new.status = 'paid')
  execute function public.award_bits_for_installment();

drop function if exists public.award_bits_for_early_installment();

-- ---------------------------------------------------------------------------
-- 5. Lo que lee la app
-- ---------------------------------------------------------------------------
-- `scale` en vez de un número: con la escalera, lo que paga una cuota depende
-- de su compra y del día de hoy, así que el servidor manda las TRES cifras y
-- la app las aplica contra `businessToday()` — exactamente como ya hace con la
-- escalera de mora. Calcular aquí "lo que pagaría cada cuota si se pagara hoy"
-- daría una cifra que caduca a las 10:00 en un teléfono que lleve la app
-- abierta desde anoche.
--
-- `per_installment` se queda, y vale el SUELO. Es lo que van a seguir leyendo
-- las apps ya instaladas: 30 es lo mínimo que gana cualquier cuota pagada a
-- tiempo, así que la promesa vieja se queda corta pero nunca miente.

create or replace function public.my_bits()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'balance', coalesce(sum(e.amount), 0),
    -- Cuántos premios formaron el saldo. Cuenta los positivos y no un motivo
    -- concreto: el día que exista el canje, sus filas restan y no son premios.
    'awarded_count', count(*) filter (where e.amount > 0),
    'last_award_at', max(e.created_at) filter (where e.amount > 0),
    'scale', jsonb_build_object(
      'same_day', public.helios_bits_same_day(),
      'step', public.helios_bits_daily_step(),
      'floor', public.helios_bits_floor()
    ),
    'per_installment', public.helios_bits_floor()
  )
  from public.bits_entries e
  where e.user_id = (select auth.uid());
$$;

comment on function public.my_bits() is
  'Saldo de Bits del usuario, cuántos premios lo formaron y la escalera que los paga.';

revoke all on function public.my_bits() from public, anon;
grant execute on function public.my_bits() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. El acuse promete lo que el trigger va a dar
-- ---------------------------------------------------------------------------
-- Cuerpo idéntico al de 20260902140000 salvo el bloque marcado NUEVO.
--
-- `early_count` se queda: sigue decidiendo LA PALABRA "adelanto", que es un
-- hecho concreto y no una forma amable de decir "pagar". Lo que ya no decide
-- es si hubo premio — ahora lo hay salvo en mora—, y por eso viaja al lado
-- `bits_pending`, calculado con la MISMA función y la MISMA fecha que usará el
-- trigger al conciliar.

create or replace function public.report_payment(
  p_quote_id       uuid,
  p_method         text,
  p_bank           text,
  p_reference      text,
  p_payer_document text default null,
  p_payer_phone    text default null,
  p_receipt_path   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user      uuid := auth.uid();
  v_quote     public.payment_quotes%rowtype;
  v_dest      uuid;
  v_duplicate boolean;
  v_status    public.payment_report_status;
  v_row       public.payment_reports%rowtype;
  v_early     integer;
  v_bits      integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_quote from public.payment_quotes where id = p_quote_id for update;
  if not found or v_quote.user_id <> v_user then
    raise exception 'Cotización no encontrada' using errcode = 'P0002';
  end if;

  if v_quote.valid_until < now() then
    raise exception 'La cotización venció, vuelve a cotizar' using errcode = '22023';
  end if;

  if p_method <> 'efectivo' and (p_reference is null or length(trim(p_reference)) = 0) then
    raise exception 'La referencia es obligatoria para %', p_method using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_reports r
    join public.payment_quote_items i on i.quote_id = r.quote_id
    join public.payment_quote_items j on j.installment_id = i.installment_id
    where j.quote_id = p_quote_id and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  select id into v_dest from public.payment_destinations where is_active limit 1;

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_duplicate := p_reference is not null and exists (
    select 1 from public.payment_reports
    where bank = p_bank and reference = p_reference and status <> 'rejected'
  );

  v_status := case when v_duplicate then 'in_review' else 'reported' end;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference,
    payer_document, payer_phone, destination_id, receipt_path, status,
    rejection_note
  )
  values (
    p_quote_id, v_user, p_method, p_bank, p_reference,
    p_payer_document, p_payer_phone, v_dest, p_receipt_path, v_status,
    case when v_duplicate
      then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.'
      else null end
  )
  returning * into v_row;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Cuántas de las cuotas de este pago son ADELANTO —la palabra— y cuántos
  -- Bits van a pagar —el premio—. Las dos cosas se miden contra
  -- `v_row.created_at`, que es la misma fecha que leerá el trigger al
  -- conciliar: lo que promete el acuse es lo que se va a premiar.
  select
    count(*) filter (where i.due_date > public.helios_business_date(v_row.created_at)),
    coalesce(sum(public.helios_bits_for_installment(
      ch.business_date, i.due_date, public.helios_business_date(v_row.created_at)
    )), 0)
  into v_early, v_bits
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges ch on ch.id = i.charge_id
  where qi.quote_id = p_quote_id;
  -- ─────────────────────────────────────────────────────────────────────────

  return jsonb_build_object(
    'report_id', v_row.id,
    'status', v_row.status,
    'amount_usd', v_quote.amount_usd,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'reported_at', v_row.created_at,
    'early_count', v_early,
    -- NUEVO
    'bits_pending', v_bits
  );
end;
$$;

revoke all on function public.report_payment(uuid, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.report_payment(uuid, text, text, text, text, text, text)
  to authenticated;

comment on function public.report_payment(uuid, text, text, text, text, text, text) is
  'Registra el reporte de una transferencia. Devuelve `early_count` (la palabra "adelanto") y `bits_pending` (el premio), con la misma regla y la misma fecha que usa el trigger de Bits.';

-- ---------------------------------------------------------------------------
-- 7. El aviso deja de dar las gracias solo por adelantar
-- ---------------------------------------------------------------------------
-- Mismo disparador y mismo "un pago, un aviso" de 20260825210000. Lo que
-- cambia es el motivo que suma y el texto: ahora el premio también le llega a
-- quien pagó el día justo, y felicitarle "por adelantar" sería el bug del
-- 2026-09-02 al revés.

create or replace function public.notify_bits_earned()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bits   integer;
  v_count  integer;
  v_cuotas text;
begin
  if new.status <> 'reconciled' or old.status = 'reconciled' then
    return null;
  end if;

  -- Lo ganado por las cuotas de ESTA cotización. Una cuota se salda una sola
  -- vez, así que su movimiento no puede venir de un pago anterior.
  select coalesce(sum(e.amount), 0), count(*)
    into v_bits, v_count
  from public.bits_entries e
  join public.payment_quote_items qi on qi.installment_id = e.installment_id
  where qi.quote_id = new.quote_id
    and e.reason = 'installment_paid';

  -- Sin Bits no hay aviso. Con la escalera eso solo pasa cuando TODO el pago
  -- era mora — y ese caso ya tiene el suyo, "Confirmamos tu pago".
  if coalesce(v_bits, 0) <= 0 then
    return null;
  end if;

  v_cuotas := case when v_count = 1 then 'tu cuota' else v_count || ' cuotas' end;

  perform public.notify(
    new.user_id, 'bits_earned',
    format('¡Ganaste %s Bits!', v_bits),
    format('Por pagar %s a tiempo. Pronto vas a poder canjearlos por premios.', v_cuotas),
    jsonb_build_object('report_id', new.id, 'bits', v_bits, 'installments', v_count),
    'bits_earned',
    jsonb_build_object('bits', v_bits, 'cuotas', v_cuotas)
  );

  return null;
end;
$$;

comment on function public.notify_bits_earned() is
  'Avisa una sola vez, al confirmarse el pago, de los Bits que ganaron sus cuotas.';

revoke all on function public.notify_bits_earned() from public, anon, authenticated;

-- El texto de fábrica del catálogo (20260902121000). Si el equipo publicó uno
-- propio, ese manda y se queda: aquí solo se corrige el respaldo, que es el
-- que sale si el publicado no se puede renderizar.
update public.notification_templates set
  trigger_label = 'Al conciliarse un pago con cuotas que no iban en mora.',
  help = 'Lo pagan todas las cuotas menos las que van en mora: 100 Bits el día de la compra, 10 menos cada día y 30 como suelo. Llega pegado al de "Confirmamos tu pago", y en ese orden.',
  default_body = 'Por pagar {cuotas} a tiempo. Pronto vas a poder canjearlos por premios.'
where key = 'bits_earned';

-- ---------------------------------------------------------------------------
-- 8. La ficha del super admin: un premio hay que poder comprobarlo
-- ---------------------------------------------------------------------------
-- Con un premio fijo bastaba con el vencimiento. Con la escalera, la pregunta
-- que llega a soporte es "¿por qué 70 y no 100?", y para contestarla hace
-- falta el DÍA DE LA COMPRA: los Bits son la distancia entre esa fecha y el
-- día en que se pagó. Sin ella, la cifra no es verificable desde el panel.
--
-- Cuerpo idéntico al de 20260825190000 salvo el bloque `bits` / `bits_entries`
-- del final.
-- ---------------------------------------------------------------------------

create or replace function public.admin_user_detail(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
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
    'created_at', p.created_at
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
    'block_opened_at', v_block.opened_at
  ));

  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd) filter (where status = 'pending'), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and due_date < v_today), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0)
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
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
      'created_at', pr.created_at
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
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

  v_result := v_result || jsonb_build_object('kyc', (
    select jsonb_build_object(
      'status', v.status,
      'rejection_reason', v.rejection_reason,
      'rejection_detail', v.rejection_detail,
      'reviewed_at', v.reviewed_at,
      'created_at', v.created_at
    )
    from kyc.verifications v
    where v.user_id = p_user_id
    order by v.created_at desc limit 1
  ));

  -- Bits. El saldo va con SUS MOVIMIENTOS y no solo con la cifra: la pregunta
  -- que llega a soporte no es cuántos tiene, es de dónde salieron.
  v_result := v_result || jsonb_build_object('bits', (
    select jsonb_build_object(
      'balance', coalesce(sum(amount), 0),
      'awarded_count', count(*) filter (where amount > 0),
      'last_award_at', max(created_at) filter (where amount > 0)
    )
    from public.bits_entries where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('bits_entries', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id,
      'amount', e.amount,
      'reason', e.reason,
      'created_at', e.created_at,
      -- De qué cuota salió. `business_date` es el día de la COMPRA, que con la
      -- escalera es la mitad de la explicación: los Bits son la distancia
      -- entre esa fecha y el día en que se pagó.
      'business_date', ch.business_date,
      'due_date', i.due_date,
      'paid_at', i.paid_at,
      'merchant_name', m.name
    ) order by e.created_at desc)
    from public.bits_entries e
    left join public.installments i on i.id = e.installment_id
    left join public.charges ch on ch.id = i.charge_id
    left join public.merchants m on m.id = ch.merchant_id
    where e.user_id = p_user_id
  ), '[]'::jsonb));

  return v_result;
end;
$$;

revoke all on function public.admin_user_detail(uuid) from public, anon;
grant execute on function public.admin_user_detail(uuid) to authenticated;
