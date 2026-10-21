-- ============================================================================
-- Helios — El bot lee los comprobantes (docs/03, decisiones de Javier del
-- 2026-10-21)
--
-- El paciente manda por WhatsApp la captura de su pago (o, sin captura,
-- escribe el banco, el teléfono desde el que pagó y la referencia completa) y
-- el bot crea el `payment_report` que hoy teclea el equipo. Desde ahí nada
-- cambia: el aviso del BNC lo coteja exacto (`helios_bank_sms_evaluate`) y,
-- si no encaja, se queda en la cola del equipo.
--
--  1. El interruptor (`receipt_reader_settings`): apagado → sombra → activo.
--     Arranca APAGADO: con él así, el bot y la base se portan como hasta hoy.
--  2. Las lecturas (`payment_receipt_reads`): una fila por captura o por
--     datos escritos, con lo que se leyó, lo que se decidió y por qué.
--  3. El registro de un pago se parte en dos: `helios_register_payment_core`
--     (cotiza a la tasa del día del pago y crea el reporte) y
--     `admin_register_payment`, que comprueba que es el equipo y firma. El
--     bot usa el núcleo sin firma: `registered_by` queda null, así que el
--     doble control no le impide al equipo aprobarlo.
--  4. Qué cuotas paga un monto: el tramo de cuotas pendientes (lo vencido
--     primero) cuya cotización en bolívares a la tasa del día del pago es
--     IGUAL al céntimo. Si ninguno lo es (un abono, un redondeo, la tasa de
--     otro día), al equipo (D5).
--  5. La captura: el webhook la encola, la Edge Function `lector-comprobantes`
--     la lee con el modelo y la base decide (`helios_receipt_decide`).
--  6. Los datos escritos, sin monto (D9): esperan al aviso del BNC que encaje
--     por referencia, teléfono y día, y el monto del aviso decide las cuotas.
--     Por eso `helios_bank_sms_ingest` mira también esas lecturas.
--  7. Lo que vence: una referencia o un aviso que no llegan en 24 h → al
--     equipo. Y el cron que despierta al lector si quedó algo pendiente.
--  8. El bot del paciente: su estado (`referencia`, `datos_pago`) y el modo
--     del lector en su contexto.
--  9. El panel: el modo (solo el super admin, con motivo), las lecturas y la
--     última de un paciente para rellenar «Registrar pago».
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El interruptor
-- ---------------------------------------------------------------------------

create table if not exists public.receipt_reader_settings (
  id          boolean primary key default true check (id),
  -- apagado: el bot se porta como antes; no se lee nada.
  -- sombra:  se lee cada captura y se anota lo que se habría hecho; el bot
  --          se porta como antes y no se crea ningún pago.
  -- activo:  se crean los pagos.
  mode        text not null default 'apagado'
              check (mode in ('apagado', 'sombra', 'activo')),
  -- Capturas (o datos escritos) por teléfono y día; las de más, al equipo
  -- sin leer (D6).
  daily_cap   integer not null default 10 check (daily_cap between 1 and 100),
  updated_by  uuid references auth.users (id),
  updated_at  timestamptz not null default now()
);

comment on table public.receipt_reader_settings is
  'Una sola fila: en qué modo está el lector de comprobantes por WhatsApp (apagado, sombra o activo) y su tope diario por teléfono.';

insert into public.receipt_reader_settings (id) values (true) on conflict (id) do nothing;

alter table public.receipt_reader_settings enable row level security;
revoke all on public.receipt_reader_settings from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Las lecturas
-- ---------------------------------------------------------------------------

create table if not exists public.payment_receipt_reads (
  id             uuid primary key default gen_random_uuid(),
  -- Un reintento de 360dialog no lee dos veces.
  wa_message_id  text not null unique,
  kind           text not null check (kind in ('captura', 'datos')),
  phone_e164     text not null,
  profile_id     uuid not null references public.profiles (id),
  -- El modo cuando llegó: lo que se hizo con una lectura no cambia al
  -- cambiar el modo.
  mode           text not null check (mode in ('sombra', 'activo')),
  -- Llegó mientras una persona atendía ese chat: el bot no le escribe.
  quiet          boolean not null default false,
  media_id       text,
  mime           text,
  receipt_path   text,
  status         text not null
                 check (status in (
                   'pendiente',            -- captura por leer
                   'leyendo',              -- la tiene el lector
                   'esperando_referencia', -- se pidió la referencia por texto
                   'esperando_aviso',      -- datos escritos: espera el SMS del BNC
                   'registrado',           -- creó el pago (report_id)
                   'duplicado',            -- ese pago ya estaba registrado
                   'para_el_equipo',       -- no se pudo decidir: lo ve el equipo (reason)
                   'descartado',           -- no es un comprobante
                   'sombra'                -- sombra: leída; reason dice lo que habría hecho
                 )),
  -- Lo que devolvió el modelo, tal cual.
  extraction     jsonb,
  model          text,
  usage          jsonb,
  -- Lo que se usó para decidir.
  method         text,
  bank           text,
  reference      text,
  amount_ves     numeric(18,2),
  paid_on        date,
  payer_phone    text,
  reason         text,
  report_id      uuid references public.payment_reports (id),
  notice_id      uuid references public.bank_sms_notices (id),
  attempts       integer not null default 0,
  -- Cuándo la tomó un lector por última vez: a los 10 minutos sin respuesta,
  -- se vuelve a tomar.
  taken_at       timestamptz,
  error          text,
  created_at     timestamptz not null default now(),
  read_at        timestamptz,
  decided_at     timestamptz
);

comment on table public.payment_receipt_reads is
  'Cada comprobante que un paciente mandó por WhatsApp (captura o datos escritos), lo que el lector leyó y lo que se decidió. docs/03.';

create index if not exists payment_receipt_reads_phone_idx
  on public.payment_receipt_reads (phone_e164, created_at desc);
create index if not exists payment_receipt_reads_profile_idx
  on public.payment_receipt_reads (profile_id, created_at desc);
create index if not exists payment_receipt_reads_open_idx
  on public.payment_receipt_reads (status, created_at)
  where status in ('pendiente', 'leyendo', 'esperando_referencia', 'esperando_aviso');

alter table public.payment_receipt_reads enable row level security;
revoke all on public.payment_receipt_reads from public, anon, authenticated;

alter table public.payment_reports
  add column if not exists receipt_read_id uuid references public.payment_receipt_reads (id);

comment on column public.payment_reports.receipt_read_id is
  'La lectura del bot de WhatsApp que creó este pago (docs/03). Null: lo registró el equipo.';

-- ---------------------------------------------------------------------------
-- 3. El registro de un pago: el núcleo y la firma del equipo
-- ---------------------------------------------------------------------------

/**
 * Cotiza unas cuotas en bolívares a las tasas del día del pago y crea el
 * reporte: lo que hacía `admin_register_payment` (20261007000300) sin
 * comprobar quién llama. Con `p_actor` deja la bitácora `payment.registered`;
 * sin él (el bot) no hay persona que firmar y la lectura es el registro.
 */
create or replace function public.helios_register_payment_core(
  p_user            uuid,
  p_installment_ids uuid[],
  p_method          text,
  p_bank            text,
  p_reference       text,
  p_paid_on         date,
  p_amount_ves      numeric,
  p_receipt_path    text,
  p_note            text,
  p_actor           uuid,
  p_payer_phone     text default null,
  p_receipt_read_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_method text := lower(btrim(coalesce(p_method, '')));
  v_bank   text := nullif(btrim(coalesce(p_bank, '')), '');
  v_ref    text := nullif(btrim(coalesce(p_reference, '')), '');
  v_path   text := nullif(btrim(coalesce(p_receipt_path, '')), '');
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_phone  text := nullif(btrim(coalesce(p_payer_phone, '')), '');
  v_quote  jsonb;
  v_q      public.payment_quotes%rowtype;
  v_dup    boolean;
  v_dest   uuid;
  v_status public.payment_report_status;
  v_row    public.payment_reports%rowtype;
  v_cands  integer;
begin
  -- El paciente solo paga en bolívares (2026-10-07).
  if v_method not in ('pago_movil', 'transferencia') then
    raise exception 'El paciente solo paga en bolívares: Pago Móvil o transferencia'
      using errcode = '22023';
  end if;

  if v_ref is null then
    raise exception 'La referencia es obligatoria para %', replace(v_method, '_', ' ')
      using errcode = '22023';
  end if;

  if v_bank is null then
    raise exception 'Falta el banco del pago' using errcode = '22023';
  end if;

  if p_paid_on is null then
    raise exception 'Falta la fecha del pago' using errcode = '22023';
  end if;
  if p_paid_on > v_today then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;
  if p_paid_on < v_today - 120 then
    raise exception 'La fecha del pago es de hace más de 120 días: revísala' using errcode = '22023';
  end if;

  if p_amount_ves is null then
    raise exception 'Falta el monto en bolívares que dice el comprobante' using errcode = '22023';
  end if;
  if p_amount_ves <= 0 then
    raise exception 'El monto en bolívares tiene que ser mayor que cero' using errcode = '22023';
  end if;
  if p_amount_ves <> round(p_amount_ves, 2) then
    raise exception 'El monto en bolívares admite como mucho 2 decimales' using errcode = '22023';
  end if;

  if v_path is not null and (v_path like '/%' or v_path like '%..%' or length(v_path) > 500) then
    raise exception 'Ruta de la captura no válida' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles where id = p_user) then
    raise exception 'Paciente no encontrado' using errcode = 'P0002';
  end if;

  -- La red de «ya hay un pago abierto» se revisa aquí, con palabras del
  -- equipo; la cotización se pide sin ella.
  if exists (
    select 1
    from public.payment_quote_items i
    join public.payment_reports r on r.quote_id = i.quote_id
    where i.installment_id = any(coalesce(p_installment_ids, '{}'::uuid[]))
      and r.status in ('reported', 'in_review')
  ) then
    raise exception 'Alguna de esas cuotas ya tiene un pago registrado esperando aprobación'
      using errcode = '22023';
  end if;

  v_quote := public.helios_quote_installments(p_user, p_installment_ids, true);

  -- En bolívares a las tasas del día del pago, que son las que usó el
  -- paciente: cada parte con la de su moneda.
  v_q := public.helios_reprice_quote((v_quote ->> 'quote_id')::uuid, p_paid_on);

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_dup := exists (
    select 1 from public.payment_reports
    where reference = v_ref
      and coalesce(bank, '') = coalesce(v_bank, '')
      and status <> 'rejected'
  );
  v_status := case when v_dup then 'in_review' else 'reported' end;

  select id into v_dest
  from public.payment_destinations
  where is_active and method = v_method
  order by sort_order, created_at
  limit 1;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference, receipt_path, status, rejection_note,
    destination_id, registered_by, paid_on, declared_amount_ves, note, payer_phone,
    receipt_read_id
  ) values (
    v_q.id, p_user, v_method, v_bank, v_ref, v_path, v_status,
    case when v_dup then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.' end,
    v_dest, p_actor, p_paid_on, p_amount_ves, v_note, v_phone,
    p_receipt_read_id
  )
  returning * into v_row;

  select count(*)::integer into v_cands
  from public.helios_statement_candidates(v_row.id) c
  where c.used_by_report_id is null and not c.discarded;

  if p_actor is not null then
    perform audit.log(p_actor, 'payment.registered', v_row.id, jsonb_build_object(
      'user_id', p_user,
      'quote_id', v_q.id,
      'installments', to_jsonb(p_installment_ids),
      'method', v_method, 'bank', v_bank, 'reference', v_ref,
      'paid_on', p_paid_on,
      'declared_amount_ves', p_amount_ves,
      'amount_usd', v_q.amount_usd, 'amount_ves', v_q.amount_ves, 'fx_rate', v_q.fx_rate,
      'amount_eur', v_q.amount_eur, 'fx_rate_eur', v_q.fx_rate_eur,
      'receipt_path', v_path,
      'status', v_status,
      'note', v_note
    ));
  end if;

  return jsonb_build_object(
    'report_id', v_row.id,
    'quote_id', v_q.id,
    'amount_usd', v_q.amount_usd,
    'late_fee_usd', v_q.late_fee_usd,
    'installments_usd', v_q.amount_usd - v_q.late_fee_usd,
    'installment_count', v_q.installment_count,
    'fx_rate', v_q.fx_rate,
    'fx_rate_eur', v_q.fx_rate_eur,
    'amount_eur', v_q.amount_eur,
    'amount_ves', v_q.amount_ves,
    'declared_amount_ves', p_amount_ves,
    'diferencia_ves', round(p_amount_ves - v_q.amount_ves, 2),
    'status', v_row.status,
    'candidatos_extracto', v_cands
  );
end;
$$;

revoke all on function public.helios_register_payment_core(uuid, uuid[], text, text, text, date, numeric, text, text, uuid, text, uuid)
  from public, anon, authenticated;

/** El equipo registra un pago desde la captura: lo mismo de siempre, firmado. */
create or replace function public.admin_register_payment(
  p_user            uuid,
  p_installment_ids uuid[],
  p_method          text,
  p_bank            text,
  p_reference       text,
  p_paid_on         date,
  p_amount_ves      numeric,
  p_receipt_path    text,
  p_note            text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return public.helios_register_payment_core(
    p_user, p_installment_ids, p_method, p_bank, p_reference, p_paid_on,
    p_amount_ves, p_receipt_path, p_note, auth.uid());
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Qué cuotas paga un monto
-- ---------------------------------------------------------------------------

/**
 * Los bolívares de unas cuotas de un paciente (con los cargos por atraso que
 * viajarían con ellas) a las tasas de un día: la cuenta de
 * `admin_payment_preview`, sin comprobar quién llama. Null si falta la tasa.
 */
create or replace function public.helios_installments_ves(
  p_user            uuid,
  p_installment_ids uuid[],
  p_day             date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_usd     numeric(18,4);
  v_eur     numeric(18,4);
  v_eur_usd numeric(18,4);
  v_fee     numeric(18,4);
begin
  select coalesce(sum(i.amount_usd), 0),
         coalesce(sum(coalesce(i.amount_cur, i.amount_usd)) filter (where c.currency = 'EUR'), 0),
         coalesce(sum(i.amount_usd) filter (where c.currency = 'EUR'), 0)
    into v_usd, v_eur, v_eur_usd
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where i.id = any(coalesce(p_installment_ids, '{}'::uuid[]))
    and i.user_id = p_user
    and i.status = 'pending';

  select coalesce(sum(f.amount_usd), 0) into v_fee
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  where f.user_id = p_user
    and f.status = 'pending'
    and (
      f.installment_id = any(coalesce(p_installment_ids, '{}'::uuid[]))
      or f.installment_id is null
      or i.status <> 'pending'
    );

  begin
    return (public.helios_bolivares(v_usd + v_fee - v_eur_usd, v_eur, p_day) ->> 'amount_ves')::numeric;
  exception when sqlstate 'P0002' then
    return null;
  end;
end;
$$;

revoke all on function public.helios_installments_ves(uuid, uuid[], date) from public, anon, authenticated;

/**
 * Las cuotas que paga exactamente un monto en bolívares, o null.
 *
 * Se toman las cuotas pendientes del paciente sin un pago abierto, en el
 * orden en que se pagan (lo vencido primero: el de `helios_quote_installments`),
 * y se cotiza la primera, las dos primeras, y así. Vale el tramo cuya
 * cotización es IGUAL al céntimo: un monto que no salda cuotas completas no
 * se adivina (D5).
 */
create or replace function public.helios_receipt_tramo(
  p_user       uuid,
  p_paid_on    date,
  p_amount_ves numeric
)
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids uuid[] := '{}'::uuid[];
  v_id  uuid;
  v_bs  numeric;
begin
  if p_amount_ves is null or p_amount_ves <= 0 then
    return null;
  end if;

  for v_id in
    select i.id
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.user_id = p_user
      and i.status = 'pending'
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review')
      )
    order by i.due_date, c.created_at, i.sequence
  loop
    v_ids := v_ids || v_id;
    v_bs := public.helios_installments_ves(p_user, v_ids, p_paid_on);
    if v_bs is null then
      return null;
    end if;
    if v_bs = p_amount_ves then
      return v_ids;
    end if;
    -- Cada cuota suma: pasado el monto, ningún tramo más largo encaja.
    exit when v_bs > p_amount_ves;
  end loop;

  return null;
end;
$$;

revoke all on function public.helios_receipt_tramo(uuid, date, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Ayudantes de la lectura
-- ---------------------------------------------------------------------------

/** ¿Ese teléfono (04141234567) es el que enmascara el SMS (0414***4567)? */
create or replace function public.helios_phone_matches_sms(p_phone text, p_prefix text, p_last4 text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select coalesce(
    length(d) = 11
    and left(d, 4) = p_prefix
    and right(d, 4) = p_last4,
    false)
  from (select regexp_replace(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '^58', '0') as d) x
$fn$;

revoke all on function public.helios_phone_matches_sms(text, text, text) from public, anon, authenticated;

/** Las cifras de un documento o un teléfono, para comparar destinos: «J-50496786-6» → «504967866». */
create or replace function public.helios_digits(p text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select nullif(regexp_replace(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '^58(4[0-9]{9})$', '0\1'), '')
$fn$;

revoke all on function public.helios_digits(text) from public, anon, authenticated;

/** Un mensaje del bot al teléfono de una lectura; si la ventana está cerrada, nada. */
create or replace function public.helios_receipt_tell(p_read public.payment_receipt_reads, p_text text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_read.quiet or p_read.mode <> 'activo' then
    return;
  end if;
  begin
    perform public.helios_whatsapp_patient_text(p_read.phone_e164, p_text, p_read.profile_id, '[]'::jsonb);
  exception when others then
    raise warning 'lector: no se pudo escribir a %: %', p_read.phone_e164, sqlerrm;
  end;
end;
$$;

revoke all on function public.helios_receipt_tell(public.payment_receipt_reads, text) from public, anon, authenticated;

/**
 * Cierra una lectura. Lo que va al equipo deja que una persona atienda ese
 * chat 24 h, como un comprobante de antes (solo en activo: en sombra el
 * webhook ya lo hizo).
 */
create or replace function public.helios_receipt_close(
  p_id     uuid,
  p_status text,
  p_reason text default null,
  p_error  text default null
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.payment_receipt_reads%rowtype;
begin
  update public.payment_receipt_reads
     set status = p_status,
         reason = coalesce(p_reason, reason),
         error = coalesce(p_error, error),
         decided_at = now()
   where id = p_id
  returning * into v_r;

  if p_status in ('para_el_equipo', 'descartado') and v_r.mode = 'activo' then
    perform public.bot_paciente_guardar(v_r.phone_e164, null, 24, '', null);
  end if;

  return p_status;
end;
$$;

revoke all on function public.helios_receipt_close(uuid, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Qué se hace con una captura leída
-- ---------------------------------------------------------------------------

/**
 * Decide una captura con lo que ya tiene la lectura (los campos normalizados
 * y `extraction`). En sombra solo anota en `reason` lo que habría hecho.
 * Ante la duda, al equipo: el bot nunca rechaza un pago.
 */
create or replace function public.helios_receipt_decide(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_r      public.payment_receipt_reads%rowtype;
  v_x      jsonb;
  v_today  date := public.helios_business_date(now());
  v_ids    uuid[];
  v_res    jsonb;
  v_dest   text;
  v_que    text;
  v_sombra boolean;
begin
  select * into v_r from public.payment_receipt_reads where id = p_id for update;
  if not found or v_r.status not in ('leyendo', 'esperando_referencia') then
    return v_r.status;
  end if;

  v_x := coalesce(v_r.extraction, '{}'::jsonb);
  v_sombra := v_r.mode = 'sombra';

  -- 1. ¿Es un comprobante de un pago hecho?
  if coalesce((v_x ->> 'es_comprobante')::boolean, false) is false then
    v_que := 'no_es_comprobante';
  elsif coalesce(v_x ->> 'estado', 'no_se_ve') not in ('exitosa', 'no_se_ve') then
    v_que := 'operacion_no_exitosa';
  elsif v_r.method is null then
    v_que := 'metodo_desconocido';
  end if;

  -- 2. ¿Fue a una cuenta de Helios? Solo si la captura enseña el destino.
  if v_que is null then
    for v_dest in
      select public.helios_digits(x) from (values
        (v_x ->> 'documento_destino'), (v_x ->> 'telefono_destino')) t(x)
      -- Uno enmascarado («0412***4930») no dice de quién es: no se compara.
      where length(public.helios_digits(x)) >= 9 and x !~ '[*xX•]'
    loop
      if not exists (
        select 1 from public.payment_destinations d
        where d.is_active
          and v_dest in (public.helios_digits(d.rif), public.helios_digits(d.phone))
      ) then
        v_que := 'cuenta_ajena';
      end if;
    end loop;
  end if;

  if v_que is null and v_r.amount_ves is null then
    v_que := 'sin_monto';
  end if;

  if v_que is null and v_r.paid_on is not null
     and (v_r.paid_on > v_today or v_r.paid_on < v_today - 5) then
    v_que := 'fecha_fuera_de_rango';
  end if;

  if v_que = 'no_es_comprobante' then
    if v_sombra then
      return public.helios_receipt_close(v_r.id, 'sombra', 'no_es_comprobante');
    end if;
    return public.helios_receipt_close(v_r.id, 'descartado', 'no_es_comprobante');
  end if;
  if v_que is not null then
    return public.helios_receipt_close(v_r.id, case when v_sombra then 'sombra' else 'para_el_equipo' end, v_que);
  end if;

  -- Sin fecha legible, la de hoy.
  if v_r.paid_on is null then
    update public.payment_receipt_reads set paid_on = v_today where id = v_r.id
    returning * into v_r;
  end if;

  -- 3. ¿Ya estaba? La misma referencia y el mismo monto en un pago de ese
  --    paciente. Sin referencia todavía, se mira tras pedirla.
  if length(coalesce(v_r.reference, '')) >= 6 and exists (
    select 1 from public.payment_reports p
    where p.user_id = v_r.profile_id
      and p.status not in ('rejected')
      and public.helios_bank_sms_ref_match(v_r.reference, p.reference)
      and public.helios_bank_sms_ref_match(p.reference, v_r.reference)
      and coalesce(p.declared_amount_ves, v_r.amount_ves) = v_r.amount_ves
  ) then
    if v_sombra then
      return public.helios_receipt_close(v_r.id, 'sombra', 'duplicado');
    end if;
    perform public.helios_receipt_tell(v_r,
      E'Ya teníamos este comprobante 👍\nLo estamos verificando y te avisamos por aquí.');
    return public.helios_receipt_close(v_r.id, 'duplicado');
  end if;

  -- 4. ¿Qué cuotas paga? Exacto al céntimo, a la tasa del día del pago.
  v_ids := public.helios_receipt_tramo(v_r.profile_id, v_r.paid_on, v_r.amount_ves);
  if v_ids is null then
    return public.helios_receipt_close(v_r.id, case when v_sombra then 'sombra' else 'para_el_equipo' end,
                                       'monto_no_cuadra');
  end if;

  -- 5. ¿Hay referencia? Sin ella, se pide por texto (24 h).
  if length(coalesce(v_r.reference, '')) < 6 then
    if v_sombra then
      return public.helios_receipt_close(v_r.id, 'sombra', 'pediria_referencia');
    end if;
    if v_r.quiet then
      return public.helios_receipt_close(v_r.id, 'para_el_equipo', 'sin_referencia');
    end if;
    update public.payment_receipt_reads
       set status = 'esperando_referencia', reason = null
     where id = v_r.id;
    perform public.bot_paciente_guardar(v_r.phone_e164, null, null, 'referencia', null);
    perform public.helios_receipt_tell(v_r,
      E'No logro leer el número de referencia en tu comprobante 🔍\nEscríbeme las *últimas 6 cifras* de la referencia, por favor.');
    return 'esperando_referencia';
  end if;

  if v_sombra then
    return public.helios_receipt_close(v_r.id, 'sombra', 'registraria');
  end if;

  -- 6. Se registra como lo registraría el equipo.
  begin
    v_res := public.helios_register_payment_core(
      v_r.profile_id, v_ids, v_r.method, coalesce(v_r.bank, 'Sin identificar'), v_r.reference,
      v_r.paid_on, v_r.amount_ves, v_r.receipt_path, 'Leído por el bot de WhatsApp',
      null, v_r.payer_phone, v_r.id);
  exception when others then
    return public.helios_receipt_close(v_r.id, 'para_el_equipo', 'no_se_pudo_registrar', sqlerrm);
  end;

  update public.payment_receipt_reads
     set status = 'registrado', reason = null,
         report_id = (v_res ->> 'report_id')::uuid, decided_at = now()
   where id = v_r.id;
  return 'registrado';
end;
$$;

revoke all on function public.helios_receipt_decide(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Los datos escritos y el aviso del BNC
-- ---------------------------------------------------------------------------

/**
 * Empareja datos escritos (sin monto) con su aviso del BNC. Se llama con la
 * lectura (al recibir los datos) o con el aviso (al llegar el SMS); con el
 * otro lado null, se busca. Encajan si la referencia escrita acaba como la
 * del SMS, el teléfono escrito empieza y acaba como el enmascarado y el SMS
 * es del día de los datos o del anterior; y la pareja es ÚNICA en los dos
 * sentidos. Entonces el monto del SMS decide las cuotas y se crea el pago,
 * que el trigger `bank_sms_on_report` coteja con ese mismo aviso.
 */
create or replace function public.helios_receipt_pair(p_read_id uuid, p_notice_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_mode  text;
  v_read  uuid := p_read_id;
  v_note  uuid := p_notice_id;
  v_n     integer;
  v_r     public.payment_receipt_reads%rowtype;
  v_a     public.bank_sms_notices%rowtype;
  v_day   date;
  v_ids   uuid[];
  v_res   jsonb;
begin
  select mode into v_mode from public.receipt_reader_settings where id;
  if coalesce(v_mode, 'apagado') <> 'activo' then
    return null;
  end if;

  if v_note is null then
    select count(*), min(a.id::text)::uuid into v_n, v_note
    from public.payment_receipt_reads r
    join public.bank_sms_notices a
      on a.outcome = 'esperando'
     and a.report_id is null
     and public.helios_bank_sms_ref_match(a.reference, r.reference)
     and public.helios_phone_matches_sms(r.payer_phone, a.payer_phone_prefix, a.payer_phone_last4)
     and public.helios_bank_sms_day_match(a.paid_at, public.helios_business_date(r.created_at), r.created_at)
    where r.id = v_read and r.status = 'esperando_aviso';
  else
    select count(*), min(r.id::text)::uuid into v_n, v_read
    from public.bank_sms_notices a
    join public.payment_receipt_reads r
      on r.kind = 'datos'
     and r.status = 'esperando_aviso'
     and public.helios_bank_sms_ref_match(a.reference, r.reference)
     and public.helios_phone_matches_sms(r.payer_phone, a.payer_phone_prefix, a.payer_phone_last4)
     and public.helios_bank_sms_day_match(a.paid_at, public.helios_business_date(r.created_at), r.created_at)
    where a.id = v_note and a.outcome = 'esperando' and a.report_id is null;
  end if;

  if coalesce(v_n, 0) = 0 then
    return 'esperando';
  end if;

  if v_n > 1 then
    -- Con el aviso en la mano, varias lecturas lo reclaman: todas al equipo.
    if p_read_id is null then
      for v_read in
        select r.id from public.payment_receipt_reads r
        join public.bank_sms_notices a on a.id = v_note
        where r.kind = 'datos' and r.status = 'esperando_aviso'
          and public.helios_bank_sms_ref_match(a.reference, r.reference)
          and public.helios_phone_matches_sms(r.payer_phone, a.payer_phone_prefix, a.payer_phone_last4)
      loop
        update public.payment_receipt_reads set notice_id = v_note where id = v_read;
        perform public.helios_receipt_close(v_read, 'para_el_equipo', 'varios');
      end loop;
    else
      perform public.helios_receipt_close(v_read, 'para_el_equipo', 'varios');
    end if;
    return 'varios';
  end if;

  select * into v_r from public.payment_receipt_reads where id = v_read for update;
  select * into v_a from public.bank_sms_notices where id = v_note;

  -- El otro sentido: otro aviso que encaje con esos datos, u otra lectura
  -- con ese aviso.
  if exists (
    select 1 from public.bank_sms_notices o
    where o.id <> v_a.id
      and o.reference is not null
      and public.helios_bank_sms_ref_match(o.reference, v_r.reference)
      and public.helios_phone_matches_sms(v_r.payer_phone, o.payer_phone_prefix, o.payer_phone_last4)
      and public.helios_bank_sms_day_match(o.paid_at, public.helios_business_date(v_r.created_at), v_r.created_at)
  ) or exists (
    select 1 from public.payment_receipt_reads x
    where x.id <> v_r.id
      and x.kind = 'datos'
      and x.status = 'esperando_aviso'
      and public.helios_bank_sms_ref_match(v_a.reference, x.reference)
      and public.helios_phone_matches_sms(x.payer_phone, v_a.payer_phone_prefix, v_a.payer_phone_last4)
  ) then
    update public.payment_receipt_reads set notice_id = v_a.id where id = v_r.id;
    return public.helios_receipt_close(v_r.id, 'para_el_equipo', 'varios');
  end if;

  v_day := (v_a.paid_at at time zone 'America/Caracas')::date;
  update public.payment_receipt_reads
     set notice_id = v_a.id, amount_ves = v_a.amount_ves, paid_on = v_day
   where id = v_r.id
  returning * into v_r;

  v_ids := public.helios_receipt_tramo(v_r.profile_id, v_day, v_a.amount_ves);
  if v_ids is null then
    return public.helios_receipt_close(v_r.id, 'para_el_equipo', 'monto_no_cuadra');
  end if;

  begin
    v_res := public.helios_register_payment_core(
      v_r.profile_id, v_ids, 'pago_movil', v_r.bank, v_r.reference, v_day, v_a.amount_ves,
      null, 'Datos escritos por el paciente en WhatsApp', null, v_r.payer_phone, v_r.id);
  exception when others then
    return public.helios_receipt_close(v_r.id, 'para_el_equipo', 'no_se_pudo_registrar', sqlerrm);
  end;

  update public.payment_receipt_reads
     set status = 'registrado', reason = null,
         report_id = (v_res ->> 'report_id')::uuid, decided_at = now()
   where id = v_r.id;
  return 'registrado';
end;
$$;

revoke all on function public.helios_receipt_pair(uuid, uuid) from public, anon, authenticated;

/**
 * `helios_bank_sms_ingest` de 20261015100000 con una sola diferencia: un
 * aviso que no encuentra pago mira si unos datos escritos lo esperan.
 */
create or replace function public.helios_bank_sms_ingest(p_body text, p_sender text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_p   record;
  v_id  uuid;
  v_out text;
  v_dat text;
begin
  if p_body is null or length(trim(p_body)) = 0 then
    raise exception 'El aviso viene vacío' using errcode = '22023';
  end if;

  select * into v_p from public.helios_parse_bnc_sms(p_body);

  if v_p.reference is null then
    insert into public.bank_sms_notices (body, sender, outcome, decided_at)
    values (left(p_body, 2000), left(nullif(trim(p_sender), ''), 100), 'ilegible', now())
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'outcome', 'ilegible');
  end if;

  insert into public.bank_sms_notices
    (body, sender, reference, amount_ves, payer_phone_prefix, payer_phone_last4, paid_at, outcome)
  values
    (left(p_body, 2000), left(nullif(trim(p_sender), ''), 100), v_p.reference, v_p.amount_ves, v_p.payer_phone_prefix,
     v_p.payer_phone_last4, v_p.paid_at, 'esperando')
  on conflict (reference, amount_ves) where reference is not null do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'outcome', 'repetido');
  end if;

  v_out := public.helios_bank_sms_evaluate(v_id);

  -- NUEVO (docs/03): sin pago que encaje, unos datos escritos que lo esperan.
  -- El pago que creen lo coteja el trigger al final de la transacción.
  if v_out = 'esperando' then
    begin
      v_dat := public.helios_receipt_pair(null, v_id);
    exception when others then
      raise warning 'lector: no se pudieron emparejar datos con el aviso %: %', v_id, sqlerrm;
    end;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'outcome', v_out, 'datos', v_dat);
end;
$fn$;

revoke all on function public.helios_bank_sms_ingest(text, text) from public, anon, authenticated;
grant execute on function public.helios_bank_sms_ingest(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 8. Lo que llama el webhook (service_role)
-- ---------------------------------------------------------------------------

/** El modo del lector y si un teléfono aún puede mandar comprobantes hoy. */
create or replace function public.helios_receipt_gate(p_phone text, p_profile_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_cfg   public.receipt_reader_settings%rowtype;
  v_hoy   integer;
begin
  select * into v_cfg from public.receipt_reader_settings where id;
  if coalesce(v_cfg.mode, 'apagado') = 'apagado' then
    return jsonb_build_object('ok', false, 'motivo', 'apagado');
  end if;

  select count(*) into v_hoy
  from public.payment_receipt_reads
  where phone_e164 = public.helios_wa_e164(p_phone)
    and public.helios_business_date(created_at) = public.helios_business_date(now());
  if v_hoy >= v_cfg.daily_cap then
    return jsonb_build_object('ok', false, 'motivo', 'tope', 'mode', v_cfg.mode);
  end if;

  if not exists (
    select 1 from public.installments i
    where i.user_id = p_profile_id and i.status = 'pending'
  ) then
    return jsonb_build_object('ok', false, 'motivo', 'sin_cuotas', 'mode', v_cfg.mode);
  end if;

  return jsonb_build_object('ok', true, 'mode', v_cfg.mode);
end;
$$;

revoke all on function public.helios_receipt_gate(text, uuid) from public, anon, authenticated;

/**
 * Una captura (imagen o PDF) de un paciente identificado: se encola para el
 * lector. `{ok: false, motivo}` si el lector está apagado, el teléfono pasó
 * su tope de hoy, el formato no se lee o el paciente no debe nada.
 */
create or replace function public.bot_comprobante_nuevo(
  p_wa_message_id text,
  p_phone         text,
  p_profile_id    uuid,
  p_media_id      text,
  p_mime          text,
  p_quiet         boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gate jsonb := public.helios_receipt_gate(p_phone, p_profile_id);
  v_mime text := lower(split_part(coalesce(p_mime, ''), ';', 1));
  v_id   uuid;
begin
  if not (v_gate ->> 'ok')::boolean then
    return v_gate;
  end if;

  if nullif(btrim(coalesce(p_media_id, '')), '') is null
     or v_mime not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf') then
    return jsonb_build_object('ok', false, 'motivo', 'formato', 'mode', v_gate ->> 'mode');
  end if;

  insert into public.payment_receipt_reads
    (wa_message_id, kind, phone_e164, profile_id, mode, quiet, media_id, mime, status)
  values
    (p_wa_message_id, 'captura', public.helios_wa_e164(p_phone), p_profile_id, v_gate ->> 'mode',
     coalesce(p_quiet, false), btrim(p_media_id), v_mime, 'pendiente')
  on conflict (wa_message_id) do nothing
  returning id into v_id;

  return jsonb_build_object('ok', v_id is not null, 'id', v_id, 'mode', v_gate ->> 'mode',
                            'motivo', case when v_id is null then 'repetido' end);
end;
$$;

revoke all on function public.bot_comprobante_nuevo(text, text, uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.bot_comprobante_nuevo(text, text, uuid, text, text, boolean) to service_role;

/**
 * La referencia que el bot pidió por texto (6 a 20 cifras). Sin una lectura
 * esperándola, `{ok: false}` y el mensaje sigue su camino. Si no son cifras,
 * la lectura va al equipo.
 */
create or replace function public.bot_comprobante_referencia(p_phone text, p_text text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_r   public.payment_receipt_reads%rowtype;
  v_ref text := regexp_replace(coalesce(p_text, ''), '\D', '', 'g');
  v_out text;
begin
  select * into v_r
  from public.payment_receipt_reads
  where phone_e164 = public.helios_wa_e164(p_phone)
    and status = 'esperando_referencia'
    and created_at > now() - interval '24 hours'
  order by created_at desc
  limit 1
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'sin_lectura');
  end if;

  perform public.bot_paciente_guardar(v_r.phone_e164, null, null, '', null);

  -- Solo cifras (con espacios o puntos de por medio): «Ref: 1234 5678» vale,
  -- una frase con un número dentro no.
  if coalesce(p_text, '') !~* '^\s*(ref(erencia)?\.?:?)?\s*[0-9][0-9 .-]*\s*$' or length(v_ref) not between 6 and 20 then
    v_out := public.helios_receipt_close(v_r.id, 'para_el_equipo', 'referencia_ilegible');
    return jsonb_build_object('ok', true, 'outcome', v_out);
  end if;

  update public.payment_receipt_reads set reference = v_ref where id = v_r.id;
  v_out := public.helios_receipt_decide(v_r.id);
  return jsonb_build_object('ok', true, 'outcome', v_out);
end;
$$;

revoke all on function public.bot_comprobante_referencia(text, text) from public, anon, authenticated;
grant execute on function public.bot_comprobante_referencia(text, text) to service_role;

/**
 * Los datos de un Pago Móvil escritos por el paciente, sin captura (D8):
 * banco, teléfono desde el que pagó (04141234567) y referencia completa.
 * Solo con el lector activo. Quedan esperando al aviso del BNC (o se emparejan
 * ya con uno que esperaba).
 */
create or replace function public.bot_comprobante_datos(
  p_wa_message_id text,
  p_phone         text,
  p_profile_id    uuid,
  p_bank          text,
  p_payer_phone   text,
  p_reference     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gate  jsonb := public.helios_receipt_gate(p_phone, p_profile_id);
  v_ref   text := regexp_replace(coalesce(p_reference, ''), '\D', '', 'g');
  v_tel   text := regexp_replace(coalesce(p_payer_phone, ''), '\D', '', 'g');
  v_id    uuid;
  v_out   text;
begin
  if not (v_gate ->> 'ok')::boolean then
    return v_gate;
  end if;
  if v_gate ->> 'mode' <> 'activo' then
    return jsonb_build_object('ok', false, 'motivo', 'sombra');
  end if;

  -- El bot ya los validó (datos_pago.ts). Si aun así llega algo mal, se
  -- devuelve, no se lanza: un error haría que 360dialog reintentara un
  -- mensaje que el webhook ya dio por recibido.
  if nullif(btrim(coalesce(p_bank, '')), '') is null then
    return jsonb_build_object('ok', false, 'motivo', 'datos_invalidos', 'campo', 'banco');
  end if;
  if v_tel !~ '^04(12|14|16|22|24|26)[0-9]{7}$' then
    return jsonb_build_object('ok', false, 'motivo', 'datos_invalidos', 'campo', 'telefono');
  end if;
  if length(v_ref) not between 8 and 20 then
    return jsonb_build_object('ok', false, 'motivo', 'datos_invalidos', 'campo', 'referencia');
  end if;

  -- El mismo pago escrito dos veces.
  if exists (
    select 1 from public.payment_receipt_reads
    where profile_id = p_profile_id and kind = 'datos'
      and reference = v_ref and status in ('esperando_aviso', 'registrado')
  ) then
    return jsonb_build_object('ok', true, 'outcome', 'duplicado');
  end if;

  insert into public.payment_receipt_reads
    (wa_message_id, kind, phone_e164, profile_id, mode, method, bank, reference, payer_phone, status)
  values
    (p_wa_message_id, 'datos', public.helios_wa_e164(p_phone), p_profile_id, 'activo',
     'pago_movil', left(btrim(p_bank), 80), v_ref, v_tel, 'esperando_aviso')
  on conflict (wa_message_id) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', true, 'outcome', 'repetido');
  end if;

  v_out := public.helios_receipt_pair(v_id, null);
  return jsonb_build_object('ok', true, 'id', v_id, 'outcome', v_out);
end;
$$;

revoke all on function public.bot_comprobante_datos(text, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.bot_comprobante_datos(text, text, uuid, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 9. Lo que llama la Edge Function `lector-comprobantes` (service_role)
-- ---------------------------------------------------------------------------

/** La clave y la URL de 360dialog, para bajar el adjunto. Están en el vault. */
create or replace function public.lector_config()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'd360_api_key', public.helios_vault_secret('d360_api_key'),
    'd360_base_url', public.helios_vault_secret('d360_base_url'))
$$;

revoke all on function public.lector_config() from public, anon, authenticated;
grant execute on function public.lector_config() to service_role;

/**
 * Toma hasta `p_limit` capturas por leer (y recupera las que un lector dejó
 * a medias hace más de 10 minutos). Cada toma cuenta un intento.
 */
create or replace function public.lector_tomar(p_limit integer default 3)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id   uuid;
  v_rows jsonb;
begin
  -- Un lector que se cayó a media lectura: se vuelve a intentar, o al
  -- equipo si ya van tres.
  for v_id in
    select id from public.payment_receipt_reads
    where status = 'leyendo' and taken_at < now() - interval '10 minutes'
    for update skip locked
  loop
    perform public.lector_fallo(v_id, 'El lector no respondió en 10 minutos');
  end loop;

  with tomadas as (
    select id from public.payment_receipt_reads
    where status = 'pendiente' and kind = 'captura'
    order by created_at
    limit greatest(1, least(coalesce(p_limit, 3), 10))
    for update skip locked
  ), hechas as (
    update public.payment_receipt_reads r
       set status = 'leyendo', attempts = r.attempts + 1, taken_at = now()
      from tomadas t
     where r.id = t.id
    returning r.id, r.media_id, r.mime, r.profile_id, r.created_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'media_id', media_id, 'mime', mime,
                                               'profile_id', profile_id) order by created_at), '[]'::jsonb)
    into v_rows
  from hechas;

  return v_rows;
end;
$$;

revoke all on function public.lector_tomar(integer) from public, anon, authenticated;
grant execute on function public.lector_tomar(integer) to service_role;

/** No se pudo leer: se reintenta hasta 3 veces; luego, al equipo. */
create or replace function public.lector_fallo(p_id uuid, p_error text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.payment_receipt_reads%rowtype;
begin
  select * into v_r from public.payment_receipt_reads where id = p_id for update;
  if not found or v_r.status <> 'leyendo' then
    return v_r.status;
  end if;

  if v_r.attempts >= 3 then
    return public.helios_receipt_close(v_r.id,
      case when v_r.mode = 'sombra' then 'sombra' else 'para_el_equipo' end,
      'no_se_pudo_leer', left(p_error, 1000));
  end if;

  update public.payment_receipt_reads
     set status = 'pendiente', error = left(p_error, 1000)
   where id = v_r.id;
  return 'pendiente';
end;
$$;

revoke all on function public.lector_fallo(uuid, text) from public, anon, authenticated;
grant execute on function public.lector_fallo(uuid, text) to service_role;

/**
 * Lo que leyó el modelo, ya normalizado por la función (logica.ts): método,
 * banco, referencia (cifras), monto en bolívares, día y teléfono del
 * pagador. Se revalida aquí y se decide.
 */
create or replace function public.lector_leido(
  p_id           uuid,
  p_receipt_path text,
  p_extraction   jsonb,
  p_datos        jsonb,
  p_model        text,
  p_usage        jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_r     public.payment_receipt_reads%rowtype;
  v_met   text := p_datos ->> 'method';
  v_ref   text := regexp_replace(coalesce(p_datos ->> 'reference', ''), '\D', '', 'g');
  v_tel   text := regexp_replace(coalesce(p_datos ->> 'payer_phone', ''), '\D', '', 'g');
  v_monto numeric;
  v_dia   date;
  v_path  text := nullif(btrim(coalesce(p_receipt_path, '')), '');
  v_out   text;
begin
  select * into v_r from public.payment_receipt_reads where id = p_id for update;
  if not found then
    raise exception 'No existe esa lectura' using errcode = 'P0002';
  end if;
  if v_r.status <> 'leyendo' then
    return jsonb_build_object('ok', false, 'status', v_r.status);
  end if;

  if v_path is not null and (v_path like '/%' or v_path like '%..%' or length(v_path) > 500) then
    raise exception 'Ruta de la captura no válida' using errcode = '22023';
  end if;

  begin
    v_monto := round((p_datos ->> 'amount_ves')::numeric, 2);
  exception when others then
    v_monto := null;
  end;
  if v_monto is not null and v_monto <= 0 then
    v_monto := null;
  end if;

  begin
    v_dia := (p_datos ->> 'paid_on')::date;
  exception when others then
    v_dia := null;
  end;

  update public.payment_receipt_reads
     set receipt_path = v_path,
         extraction = p_extraction,
         model = left(p_model, 80),
         usage = p_usage,
         method = case when v_met in ('pago_movil', 'transferencia') then v_met end,
         bank = left(nullif(btrim(coalesce(p_datos ->> 'bank', '')), ''), 80),
         reference = nullif(v_ref, ''),
         amount_ves = v_monto,
         paid_on = v_dia,
         payer_phone = case when v_tel ~ '^04[0-9]{9}$' then v_tel end,
         read_at = now(),
         error = null
   where id = v_r.id;

  v_out := public.helios_receipt_decide(v_r.id);
  return jsonb_build_object('ok', true, 'status', v_out);
end;
$$;

revoke all on function public.lector_leido(uuid, text, jsonb, jsonb, text, jsonb) from public, anon, authenticated;
grant execute on function public.lector_leido(uuid, text, jsonb, jsonb, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 10. Lo que vence y el despertador
-- ---------------------------------------------------------------------------

/** Una referencia o un aviso que no llegaron en 24 h: al equipo. */
create or replace function public.helios_receipt_reads_expire()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_n  integer := 0;
  v_st text;
begin
  for v_id, v_st in
    select id, status from public.payment_receipt_reads
    where status in ('esperando_referencia', 'esperando_aviso')
      and created_at < now() - interval '24 hours'
  loop
    perform public.helios_receipt_close(v_id, 'para_el_equipo',
      case when v_st = 'esperando_referencia' then 'sin_referencia' else 'sin_aviso' end);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.helios_receipt_reads_expire() from public, anon, authenticated;

/**
 * Si quedó alguna captura por leer, despierta a `lector-comprobantes` (que
 * contesta enseguida y lee en segundo plano). La URL y la clave están en el
 * vault (`lector_url`, `lector_clave`); sin ellas, nada.
 */
create or replace function public.helios_lector_despertar()
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_url   text;
  v_clave text;
begin
  if not exists (select 1 from public.payment_receipt_reads where status = 'pendiente') then
    return false;
  end if;

  v_url   := public.helios_vault_secret('lector_url');
  v_clave := public.helios_vault_secret('lector_clave');
  if v_url is null or v_clave is null then
    return false;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '3000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '5000');
    perform extensions.http((
      'POST', v_url,
      array[extensions.http_header('x-helios-clave', v_clave)],
      'application/json', '{}'
    )::extensions.http_request);
  exception when others then
    raise warning 'lector: no se pudo despertar: %', sqlerrm;
    return false;
  end;
  return true;
end;
$$;

revoke all on function public.helios_lector_despertar() from public, anon, authenticated;

select cron.schedule('helios_lector_vencer', '*/10 * * * *', 'select public.helios_receipt_reads_expire();');
select cron.schedule('helios_lector_despertar', '* * * * *', 'select public.helios_lector_despertar();');

-- ---------------------------------------------------------------------------
-- 11. El bot del paciente: su estado
-- ---------------------------------------------------------------------------

alter table public.whatsapp_contacts drop constraint if exists whatsapp_contacts_patient_state_check;
alter table public.whatsapp_contacts
  add constraint whatsapp_contacts_patient_state_check
    check (patient_state is null or patient_state in ('cedula', 'referencia', 'datos_pago')),
  add column if not exists patient_state_at timestamptz,
  add column if not exists patient_draft    jsonb;

comment on column public.whatsapp_contacts.patient_state_at is
  'Cuándo entró en `patient_state`: «referencia» y «datos_pago» valen 24 h.';
comment on column public.whatsapp_contacts.patient_draft is
  'Lo que el paciente ya escribió de los datos de su pago (estado «datos_pago»), y cuántas veces se le pidió.';

/** `bot_paciente_guardar` de 20261006000100, con la hora del estado. */
create or replace function public.bot_paciente_guardar(
  p_phone        text,
  p_menu         boolean default null,
  p_humano_horas integer default null,
  p_estado       text default null,
  p_profile_id   uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := public.helios_wa_e164(p_phone);
begin
  insert into public.whatsapp_contacts (phone_e164, updated_at) values (v_phone, now())
  on conflict (phone_e164) do nothing;

  update public.whatsapp_contacts
     set bot_menu_at = case when p_menu then now() else bot_menu_at end,
         human_until = case when p_humano_horas is null then human_until
                            when p_humano_horas <= 0 then null
                            else now() + make_interval(hours => p_humano_horas) end,
         patient_state = case when p_estado is null then patient_state else nullif(p_estado, '') end,
         patient_state_at = case when p_estado is null then patient_state_at
                                 when nullif(p_estado, '') is null then null
                                 else now() end,
         -- El borrador es del estado «datos_pago»: otro estado lo borra.
         patient_draft = case when p_estado is null or p_estado = 'datos_pago' then patient_draft end,
         patient_profile_id = coalesce(p_profile_id, patient_profile_id),
         updated_at = now()
   where phone_e164 = v_phone;
end;
$$;

/** Lo que el paciente ya escribió de los datos de su pago. */
create or replace function public.bot_paciente_borrador(p_phone text, p_draft jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.whatsapp_contacts
     set patient_draft = p_draft, updated_at = now()
   where phone_e164 = public.helios_wa_e164(p_phone)
$$;

revoke all on function public.bot_paciente_borrador(text, jsonb) from public, anon, authenticated;
grant execute on function public.bot_paciente_borrador(text, jsonb) to service_role;

/**
 * `bot_paciente_contexto` de 20261019000200 con tres cosas más: el modo del
 * lector, el borrador de los datos del pago y que «referencia» y
 * «datos_pago» caducan a las 24 h.
 */
create or replace function public.bot_paciente_contexto(p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_phone text := public.helios_wa_e164(p_phone);
  v_c     public.whatsapp_contacts%rowtype;
  v_perf  jsonb;
  v_est   text;
begin
  select * into v_c from public.whatsapp_contacts where phone_e164 = v_phone;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'nombre', coalesce(nullif(btrim(p.first_name), ''), split_part(btrim(coalesce(p.full_name, '')), ' ', 1)),
           'documento', p.document_key,
           'documento_enmascarado', public.helios_mask_document(p.document_number))
         order by p.created_at), '[]'::jsonb)
    into v_perf
  from public.profiles p
  where regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = regexp_replace(coalesce(v_phone, '-'), '\D', '', 'g');

  v_est := case
    when v_c.patient_state in ('referencia', 'datos_pago')
         and coalesce(v_c.patient_state_at, '-infinity'::timestamptz) < now() - interval '24 hours' then null
    else v_c.patient_state end;

  return jsonb_build_object(
    'perfiles', v_perf,
    'elegido', case when v_c.patient_profile_id is not null
                     and v_perf @> jsonb_build_array(jsonb_build_object('id', v_c.patient_profile_id))
                    then v_c.patient_profile_id end,
    'estado', v_est,
    'borrador', case when v_est = 'datos_pago' then v_c.patient_draft end,
    'humano', coalesce(v_c.human_until > now(), false),
    'menu_reciente', coalesce(v_c.bot_menu_at > now() - interval '2 hours', false),
    'lector', coalesce((select mode from public.receipt_reader_settings where id), 'apagado'),
    -- Si escribe «sí» o «no» y su orden venció sin respuesta en las últimas
    -- 12 h, lo que se le contesta (2026-10-19).
    'vencida_texto', (
      select public.helios_patient_decision_text(c.id, 'vencida')
      from public.charges c
      join public.profiles p on p.id = c.user_id
      where regexp_replace(coalesce(p.phone_e164, ''), '\D', '', 'g') = regexp_replace(coalesce(v_phone, '-'), '\D', '', 'g')
        and (c.status = 'expired' or (c.status = 'pending' and c.expires_at <= now()))
        and c.answered_at is null
        and c.expires_at > now() - interval '12 hours'
      order by c.expires_at desc
      limit 1)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. El panel
-- ---------------------------------------------------------------------------

/** Una lectura para el panel, con el nombre del paciente. */
create or replace function public.helios_admin_receipt_read(p_r public.payment_receipt_reads)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id', p_r.id,
    'kind', p_r.kind,
    'mode', p_r.mode,
    'status', p_r.status,
    'reason', p_r.reason,
    'user_id', p_r.profile_id,
    'user_name', (select full_name from public.profiles where id = p_r.profile_id),
    'phone', p_r.phone_e164,
    'receipt_path', p_r.receipt_path,
    'extraction', p_r.extraction,
    'method', p_r.method,
    'bank', p_r.bank,
    'reference', p_r.reference,
    'amount_ves', p_r.amount_ves,
    'paid_on', p_r.paid_on,
    'payer_phone', p_r.payer_phone,
    'report_id', p_r.report_id,
    'notice_id', p_r.notice_id,
    'model', p_r.model,
    'usage', p_r.usage,
    'error', p_r.error,
    'created_at', p_r.created_at,
    'read_at', p_r.read_at,
    'decided_at', p_r.decided_at
  )
$$;

revoke all on function public.helios_admin_receipt_read(public.payment_receipt_reads) from public, anon, authenticated;

/**
 * Las lecturas de un rango de días (hora de Caracas, por el día en que
 * llegaron), el modo del lector y cuántas esperan al equipo en los últimos
 * 7 días.
 */
create or replace function public.admin_receipt_reads(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_cfg public.receipt_reader_settings%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_cfg from public.receipt_reader_settings where id;

  return jsonb_build_object(
    'mode', v_cfg.mode,
    'daily_cap', v_cfg.daily_cap,
    'mode_updated_at', v_cfg.updated_at,
    'mode_updated_by_name', (select coalesce(pa.full_name, p.full_name)
                             from auth.users u
                             left join public.platform_admins pa on pa.user_id = u.id
                             left join public.profiles p on p.id = u.id
                             where u.id = v_cfg.updated_by),
    -- Las que fueron al equipo y a las que nadie ha registrado un pago desde
    -- entonces.
    'para_revisar', (select count(*) from public.payment_receipt_reads x
                     where x.status = 'para_el_equipo' and x.report_id is null
                       and x.created_at > now() - interval '7 days'
                       and not exists (select 1 from public.payment_reports p
                                       where p.user_id = x.profile_id
                                         and p.created_at > x.created_at)),
    'reads', coalesce((
      select jsonb_agg(public.helios_admin_receipt_read(r) order by r.created_at desc)
      from public.payment_receipt_reads r
      where public.helios_business_date(r.created_at) between p_from and p_to
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.admin_receipt_reads(date, date) from public, anon;
grant execute on function public.admin_receipt_reads(date, date) to authenticated;

/**
 * La última lectura de un paciente sin pago (de los últimos 7 días), para
 * rellenar «Registrar pago». Null si no hay.
 */
create or replace function public.admin_receipt_read_latest(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.payment_receipt_reads%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_r
  from public.payment_receipt_reads
  where profile_id = p_user
    and report_id is null
    and status in ('para_el_equipo', 'sombra', 'esperando_referencia', 'esperando_aviso')
    and created_at > now() - interval '7 days'
  order by created_at desc
  limit 1;

  if not found then
    return null;
  end if;
  return public.helios_admin_receipt_read(v_r);
end;
$$;

revoke all on function public.admin_receipt_read_latest(uuid) from public, anon;
grant execute on function public.admin_receipt_read_latest(uuid) to authenticated;

/** La lectura que creó un pago, para su ficha. Null si lo registró el equipo. */
create or replace function public.admin_receipt_read_for_report(p_report_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.payment_receipt_reads%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select r.* into v_r
  from public.payment_receipt_reads r
  join public.payment_reports p on p.receipt_read_id = r.id
  where p.id = p_report_id;

  if not found then
    return null;
  end if;
  return public.helios_admin_receipt_read(v_r);
end;
$$;

revoke all on function public.admin_receipt_read_for_report(uuid) from public, anon;
grant execute on function public.admin_receipt_read_for_report(uuid) to authenticated;

/** Cambia el modo del lector. Solo el super admin, y con motivo. */
create or replace function public.admin_set_receipt_reader_mode(p_mode text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid;
  v_antes text;
begin
  v_actor := public.helios_assert_super_admin('cambiar el modo del lector de comprobantes');

  if p_mode not in ('apagado', 'sombra', 'activo') then
    raise exception 'Modo desconocido: %', p_mode using errcode = '22023';
  end if;

  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Cambiar el modo del lector requiere motivo' using errcode = '22023';
  end if;

  select mode into v_antes from public.receipt_reader_settings where id for update;

  update public.receipt_reader_settings
     set mode = p_mode, updated_by = v_actor, updated_at = now()
   where id;

  perform audit.log(v_actor, 'receipt_reader.mode_changed', null, jsonb_build_object(
    'from', v_antes, 'to', p_mode, 'note', trim(p_note)
  ));

  return jsonb_build_object('ok', true, 'mode', p_mode);
end;
$$;

revoke all on function public.admin_set_receipt_reader_mode(text, text) from public, anon;
grant execute on function public.admin_set_receipt_reader_mode(text, text) to authenticated;
