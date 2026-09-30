-- ============================================================================
-- Ronda — El precio se pacta en EUROS
--
-- Hasta hoy la moneda canónica era el dólar (`20260822051000_fx_rates.sql`):
-- la deuda, los límites de nivel y el precio del catálogo vivían en USD, y el
-- bolívar era la capa de presentación a la tasa BCV del dólar.
--
-- **Cambia el ancla, no las cifras.** El cupo del nivel 1 sigue siendo 50, el
-- mínimo por cobro sigue siendo 5, la mora sigue siendo 2 y el fee sigue
-- siendo el 20 %. Lo que cambia es de qué son: antes dólares, ahora euros. Y
-- con ello lo único que de verdad se mueve en la base — la tasa con la que
-- todo eso se convierte a bolívares, que pasa a ser la del **euro** del BCV.
--
-- Cinco cosas, en este orden:
--
-- 1. **La serie del dólar se archiva, no se borra.** Pasa a `source =
--    'BCV_USD'` y `'BCV'` queda libre para el euro. No es cosmética: el
--    guardarraíl de `sync_fx_rate` rechaza una tasa que se despegue más de un
--    25 % de la anterior, y hoy el euro está un 16 % por encima del dólar. Ese
--    salto no significa nada —son dos monedas distintas, no una devaluación—,
--    así que compararlo sería medir con la regla equivocada. Sin fila anterior
--    bajo `'BCV'`, la primera tasa del euro entra sin esa comparación, y de la
--    segunda en adelante el guardarraíl vuelve a proteger de lo que sí
--    importa: un espejo que devuelve basura.
--
--    Lo archivado sigue ahí y sigue siendo consultable (`current_fx_rate(
--    'BCV_USD', …)`). No hace falta para el día a día —cada cotización ya
--    emitida guarda su propia `fx_rate` en `payment_quotes`, así que ninguna
--    deuda viva depende de esta tabla— pero es el rastro de con qué se cobró
--    antes del cambio, y eso no se tira.
--
-- 2. **Los espejos apuntan al euro.** Las dos fuentes viejas se desactivan
--    —quedan como documentación de dónde salía el dólar— y entran dos nuevas
--    con la misma forma y las mismas rutas. Las dos publican la tasa oficial
--    del BCV para el euro y hoy coinciden hasta el sexto decimal, que es
--    exactamente lo que se le pide a una segunda opinión.
--
-- 3. **El catálogo de avisos cambia el símbolo.** Los quince avisos
--    automáticos viven en `notification_templates` desde el 2026-09-02, y seis
--    de ellos llevan el símbolo dentro del texto ("Te tocaron ${monto}…"). Se
--    cambia el de fábrica, el publicado y el borrador: dejar el publicado en
--    dólares sería mandar mil avisos al día contradiciendo a la app.
--
-- 4. **Las catorce funciones que imprimen dinero en un texto.** Un `raise
--    exception 'Saldo insuficiente: disponible $%…'` acaba en un banner de la
--    app igual que cualquier otra cadena, y un `format('Te tocaron $%s…')` en
--    una notificación. Se copian tal cual estaban —mismo cuerpo, mismos
--    grants, `create or replace` conserva los privilegios— con el símbolo
--    cambiado y nada más.
--
-- 5. **La tasa de hoy se trae aquí mismo**, sin esperar al cron de las 10 AM:
--    entre desplegar esto y el primer cron no puede haber ni un minuto sin
--    tasa del euro, porque durante ese rato las cotizaciones saldrían con la
--    del dólar — un 16 % menos de bolívares de los que toca cobrar.
--
-- Lo que NO cambia, y es deliberado: los nombres de las columnas de dinero
-- (`charges.amount_usd`, `installments.financed_usd`, `charges.base_usd` y las
-- cuarenta y pico restantes). Renombrarlas en una base con deuda viva es una
-- migración de otro tamaño y de otro riesgo, y no movería ni un céntimo ni un
-- píxel: el sufijo pasa a ser historia, no unidad. La unidad la dice esta
-- migración, y la dice docs/05 §1.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La serie del dólar se archiva
-- ---------------------------------------------------------------------------
-- El `unique (source, effective_date)` no estorba: se mueve la serie entera de
-- una clave a otra, así que no hay dos filas que puedan chocar.

update public.exchange_rates
set source = 'BCV_USD'
where source = 'BCV';

comment on table public.exchange_rates is
  'Tasas del BCV. `BCV` es la del EURO, que es la moneda del sistema desde el 2026-09-09; `BCV_USD` es la serie del dólar, archivada. La ingesta es un job diario (sync_fx_rate).';

-- ---------------------------------------------------------------------------
-- 2. Los espejos apuntan al euro
-- ---------------------------------------------------------------------------

update public.fx_rate_sources
set is_active = false,
    note = coalesce(note, '') || ' — Retirada el 2026-09-09: publicaba el DÓLAR.'
where key in ('dolarapi', 'er-api');

insert into public.fx_rate_sources (key, url, rate_path, date_path, date_format, priority, note)
values
  ('dolarapi-eur',
   'https://ve.dolarapi.com/v1/euros/oficial',
   '{promedio}', '{fechaActualizacion}', 'timestamptz', 1,
   'DolarAPI Venezuela. Republica la tasa oficial del BCV para el euro, con su fecha de vigencia.'),
  ('er-api-eur',
   'https://open.er-api.com/v6/latest/EUR',
   '{rates,VES}', '{time_last_update_unix}', 'epoch', 2,
   'exchangerate-api con base EUR. Segunda opinión: su VES sigue a la oficial. Actualiza una vez al día.')
on conflict (key) do update
  set url         = excluded.url,
      rate_path   = excluded.rate_path,
      date_path   = excluded.date_path,
      date_format = excluded.date_format,
      priority    = excluded.priority,
      is_active   = true,
      note        = excluded.note;

comment on table public.fx_rate_sources is
  'Espejos JSON de la tasa oficial del BCV para el EURO, por prioridad. Los lee sync_fx_rate().';

comment on function public.sync_fx_rate(date, boolean) is
  'Busca la tasa BCV del euro en los espejos configurados, la valida y la persiste. La llama el cron a las 10 AM.';

-- ---------------------------------------------------------------------------
-- 3. El catálogo de avisos
-- ---------------------------------------------------------------------------
-- El símbolo va pegado a un marcador (`${monto}`) o a una cifra, y en ningún
-- otro sitio: `render_notification_text` solo sustituye `{clave}`, así que el
-- `$` es un carácter suelto del texto y se puede cambiar sin tocar el marcador
-- que va detrás.
--
-- Se tocan las tres capas —fábrica, publicado y borrador— porque las tres se
-- pueden estar mandando o a punto: un texto publicado gana sobre el de
-- fábrica, y dejarlo en dólares sería mandar mil avisos al día diciendo lo
-- contrario que la pantalla a la que llevan.

update public.notification_templates
set default_title = regexp_replace(default_title, '\$(\{|[0-9])', '€\1', 'g'),
    default_body  = regexp_replace(default_body,  '\$(\{|[0-9])', '€\1', 'g'),
    title         = regexp_replace(title,         '\$(\{|[0-9])', '€\1', 'g'),
    body          = regexp_replace(body,          '\$(\{|[0-9])', '€\1', 'g'),
    draft_title   = regexp_replace(draft_title,   '\$(\{|[0-9])', '€\1', 'g'),
    draft_body    = regexp_replace(draft_body,    '\$(\{|[0-9])', '€\1', 'g')
where coalesce(default_title, '') like '%$%'
   or coalesce(default_body,  '') like '%$%'
   or coalesce(title,         '') like '%$%'
   or coalesce(body,          '') like '%$%'
   or coalesce(draft_title,   '') like '%$%'
   or coalesce(draft_body,    '') like '%$%';

-- Los avisos ya mandados NO se tocan. Un aviso es el acta de lo que se dijo
-- ese día, y ese día se dijo en dólares: reescribir la bandeja de todo el
-- mundo para que la historia parezca coherente es falsificarla.

-- ---------------------------------------------------------------------------
-- 4. Las funciones que imprimen dinero en un texto
-- ---------------------------------------------------------------------------
-- Copiadas de la migración donde se definieron por última vez, con el símbolo
-- cambiado y NADA más — ni una línea, ni un espacio. `create or replace`
-- conserva dueño y privilegios, así que no hace falta repetir los `grant`.
--
-- Se quedan fuera, a propósito, las que solo llevan el símbolo en un
-- comentario del cuerpo (`my_groups`, `admin_cash_position`, `admin_charges`,
-- `admin_payment_queue`, `helios_split_shares`, `helios_group_join_plan`):
-- redesplegar trescientas líneas para arreglar prosa que no ve nadie es
-- riesgo a cambio de nada.

-- ── public.reconcile_payment/4 ─ copiada de 20260902150000_cada_pago_dice_que_compra_y_que_cuota_salda.sql

create or replace function public.reconcile_payment(
  p_report_id uuid,
  p_actor     uuid,
  p_approve   boolean,
  p_note      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_report    public.payment_reports%rowtype;
  v_quote     public.payment_quotes%rowtype;
  v_item      record;
  v_fee       record;
  v_fee_usd   numeric(18,4) := 0;
  v_fee_count integer := 0;
  v_bdate     date;
  v_tx        uuid;
  v_acct_recv uuid;
  v_acct_cash uuid;
  v_block     public.user_credit_blocks%rowtype;
  v_total     numeric(18,4) := 0;
  v_settled   numeric(18,4);
  v_done      integer := 0;
  v_expected  integer;
begin
  select * into v_report from public.payment_reports where id = p_report_id for update;
  if not found then
    raise exception 'Reporte no encontrado' using errcode = 'P0002';
  end if;

  if v_report.status not in ('reported', 'in_review') then
    raise exception 'Este reporte ya fue resuelto (%)', v_report.status using errcode = '22023';
  end if;

  if not p_approve then
    update public.payment_reports
      set status = 'rejected', reviewed_by = p_actor, reviewed_at = now(),
          rejection_note = p_note
    where id = p_report_id;

    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  select * into v_quote from public.payment_quotes where id = v_report.quote_id;

  select count(*) into v_expected
  from public.payment_quote_items where quote_id = v_quote.id;

  if v_expected = 0 then
    raise exception 'La cotización % no tiene cuotas', v_quote.id using errcode = '22023';
  end if;

  v_bdate := public.helios_business_date(now());
  v_acct_recv := ledger.get_or_create_account('user_receivable', v_report.user_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'installment_payment', 'reconcile:' || p_report_id::text, v_bdate, p_report_id,
    format('Pago conciliado de %s cuota(s)', v_quote.installment_count)
  )
  returning id into v_tx;

  for v_item in
    select i.installment_id, i.amount_usd, c.merchant_id,
           t.policy, t.per_installment_pct,
           ins.due_date,
           -- El importe que tiene la cuota AHORA, para cotejarlo con el que se
           -- congeló al cotizar.
           ins.amount_usd as current_amount_usd
    from public.payment_quote_items i
    join public.installments ins on ins.id = i.installment_id
    join public.charges c on c.id = ins.charge_id
    -- LEFT: la falta de condiciones de liquidación no puede sacar la cuota
    -- del bucle. `ins` sigue en el lado no anulable, así que el `for update`
    -- de abajo es válido.
    left join public.merchant_settlement_terms t on t.merchant_id = c.merchant_id
    where i.quote_id = v_quote.id
    for update of ins
  loop
    if v_item.policy is null then
      raise exception
        'El comercio % no tiene condiciones de liquidación: configúralas antes de conciliar este pago',
        v_item.merchant_id
        using errcode = '22023';
    end if;

    if (select status from public.installments where id = v_item.installment_id) = 'paid' then
      raise exception 'La cuota % ya estaba pagada', v_item.installment_id using errcode = '22023';
    end if;

    if v_item.current_amount_usd is distinct from v_item.amount_usd then
      raise exception
        'La cuota % cambió de importe desde que se cotizó (€% cotizados, €% ahora): no se concilia hasta revisarlo',
        v_item.installment_id, v_item.amount_usd, v_item.current_amount_usd
        using errcode = '22023';
    end if;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- `paid_by_report_id`: con qué pago se saldó, y no solo cuándo.
    update public.installments
      set status = 'paid', paid_at = now(), paid_by_report_id = p_report_id
    where id = v_item.installment_id;
    -- ───────────────────────────────────────────────────────────────────────

    v_total := v_total + v_item.amount_usd;
    v_done  := v_done + 1;

    -- En 'on_collection' la obligación nace al cobrar. Se DEVENGA, igual que
    -- el adelanto: la caja se mueve cuando se reporte la transferencia.
    if v_item.policy = 'on_collection' then
      v_settled := round(v_item.amount_usd * v_item.per_installment_pct * 2 / 100, 4);

      insert into public.settlements
        (merchant_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_item.merchant_id, v_item.installment_id, 'on_collection', v_settled,
         v_bdate, v_bdate, 'pending');
    end if;
  end loop;

  -- La red. Si el bucle no tocó todas las cuotas de la cotización, algo las
  -- descartó: se deshace todo antes de asentar dinero por una cifra que no
  -- corresponde con lo que se acaba de saldar.
  if v_done <> v_expected then
    raise exception
      'Se saldaron % de % cuotas de la cotización %: no se concilia a medias',
      v_done, v_expected, v_quote.id
      using errcode = '22023';
  end if;

  -- Los cargos por mora que viajaban en la cotización, uno a uno.
  for v_fee in
    select l.late_fee_id, l.amount_usd as quoted_usd,
           f.status, f.amount_usd as current_usd
    from public.payment_quote_late_fees l
    join public.late_fees f on f.id = l.late_fee_id
    where l.quote_id = v_quote.id
    for update of f
  loop
    if v_fee.status <> 'pending' then
      raise exception
        'El cargo por mora % de esta cotización ya no está pendiente (%): revísalo antes de conciliar',
        v_fee.late_fee_id, v_fee.status
        using errcode = '22023';
    end if;

    if v_fee.current_usd is distinct from v_fee.quoted_usd then
      raise exception
        'El cargo por mora % cambió de importe desde que se cotizó (€% cotizados, €% ahora): no se concilia hasta revisarlo',
        v_fee.late_fee_id, v_fee.quoted_usd, v_fee.current_usd
        using errcode = '22023';
    end if;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    update public.late_fees
      set status = 'paid', paid_at = now(), paid_by_report_id = p_report_id
    where id = v_fee.late_fee_id;
    -- ───────────────────────────────────────────────────────────────────────

    v_fee_usd   := v_fee_usd + v_fee.quoted_usd;
    v_fee_count := v_fee_count + 1;
  end loop;

  -- La misma red que arriba, en la otra moneda: lo que se salda tiene que sumar
  -- lo que se cotizó, o el asiento de caja no es el dinero que entró.
  if v_fee_usd is distinct from v_quote.late_fee_usd then
    raise exception
      'Los cargos por mora de la cotización % suman €% y se cotizaron €%: no se concilia hasta revisarlo',
      v_quote.id, v_fee_usd, v_quote.late_fee_usd
      using errcode = '22023';
  end if;

  v_total := v_total + v_fee_usd;

  -- Lo único que mueve caja aquí es el dinero que ENTRÓ del usuario.
  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_cash, v_total, 0),
    (v_tx, v_acct_recv, 0, v_total);

  update public.payment_reports
    set status = 'reconciled', reviewed_by = p_actor, reviewed_at = now(),
        rejection_note = coalesce(p_note, rejection_note)
  where id = p_report_id;

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_report.user_id and closed_at is null
  for update;

  if found then
    update public.user_credit_blocks
      set paid_usd = paid_usd + v_total
    where id = v_block.id;

    -- Contra cupo + fee. El fee es deuda: hasta que esté pagado, el bloque
    -- sigue abierto y el límite sigue ocupado.
    if v_block.paid_usd + v_total >= v_block.charged_usd + v_block.fee_usd then
      update public.user_credit_blocks
        set closed_at = now(), close_reason = 'paid'
      where id = v_block.id;
    end if;
  end if;

  perform public.recompute_profile_mora_state(v_report.user_id);

  return jsonb_build_object(
    'ok', true, 'status', 'reconciled',
    'amount_usd', v_total,
    'installments', v_done,
    'late_fee_usd', v_fee_usd,
    'late_fee_count', v_fee_count
  );
end;
$$;

-- ── public.recompute_profile_mora_state/1 ─ copiada de 20260902110000_la_mora_se_cobra_por_cuota.sql

create or replace function public.recompute_profile_mora_state(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
          'Se sumaron €%s a tu deuda por una cuota con más de %s días de retraso. Va incluido en tu próximo pago.',
          trim(to_char(v_fees_usd, 'FM999999990.00')),
          public.helios_late_fee_grace_days()
        )
      else
        format(
          'Se sumaron €%s a tu deuda: €%s por cada una de tus %s cuotas con más de %s días de retraso. Van incluidos en tu próximo pago.',
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
$$;

-- ── public.request_charge/4 ─ copiada de 20260829070000_fix_el_guardia_de_decimales_bloqueaba_todo.sql

create or replace function public.request_charge(
  p_merchant_id     uuid,
  p_branch_id       uuid,
  p_items           jsonb,
  p_idempotency_key text
)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := auth.uid();
  v_row     public.charges%rowtype;
  v_allowed boolean;
  v_item    jsonb;
  v_lines   jsonb := '[]'::jsonb;
  v_qty     integer;
  v_name    text;
  v_price   numeric(18,4);
  v_base    numeric(18,4);
  v_terms   public.merchant_settlement_terms%rowtype;
  v_b       jsonb;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select exists (
    select 1 from public.merchant_users
    where user_id = v_staff
      and merchant_id = p_merchant_id
      and is_active
      and (branch_id is null or branch_id = p_branch_id)
  ) into v_allowed;

  if not v_allowed then
    raise exception 'No autorizado a cobrar en este comercio/sucursal' using errcode = '42501';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'El cobro no tiene productos' using errcode = '22023';
  end if;

  if jsonb_array_length(p_items) > 100 then
    raise exception 'Demasiadas líneas en un mismo cobro' using errcode = '22023';
  end if;

  -- --- Resolver cada línea contra el catálogo ---------------------------
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((v_item->>'quantity')::integer, 1);

    if v_qty < 1 or v_qty > 999 then
      raise exception 'Cantidad no válida: %', v_qty using errcode = '22023';
    end if;

    if nullif(v_item->>'product_id', '') is not null then
      select p.name, p.price_usd into v_name, v_price
      from public.products p
      where p.id = (v_item->>'product_id')::uuid
        and p.merchant_id = p_merchant_id
        and p.is_active;

      if not found then
        raise exception 'Un producto del pedido ya no está en tu carta; quítalo y vuelve a intentar'
          using errcode = '22023';
      end if;
    else
      v_name  := coalesce(nullif(btrim(v_item->>'name'), ''), 'Consumo');
      v_price := (v_item->>'unit_price_usd')::numeric;

      if v_price is null or v_price < 0 then
        raise exception 'Precio no válido en una línea del cobro' using errcode = '22023';
      end if;
    end if;

    /**
     * NUEVO: nada de milésimas, venga de la carta o de una línea libre.
     *
     * `base_usd` nace redondeado a dos decimales pero las líneas se guardan
     * tal cual llegan, así que un precio con tres decimales hace que el
     * comprobante enseñe unas líneas que no suman su propio total. Se corta en
     * la entrada, que es donde se puede decir cuál es la línea mala.
     *
     * Se compara contra el valor redondeado y NO con `scale()`: `v_price` está
     * declarada `numeric(18,4)`, y sobre una variable con typmod `scale()`
     * devuelve siempre el de la DECLARACIÓN (4), no el del valor — así que la
     * comprobación rechazaba absolutamente todos los cobros.
     */
    if v_price <> round(v_price, 2) then
      raise exception 'El precio de "%" tiene más de dos decimales', v_name
        using errcode = '22023';
    end if;

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'product_id',     nullif(v_item->>'product_id', ''),
      'name',           v_name,
      'unit_price_usd', v_price,
      'quantity',       v_qty
    ));
  end loop;

  select sum(round((l->>'unit_price_usd')::numeric * (l->>'quantity')::integer, 4))
  into v_base
  from jsonb_array_elements(v_lines) l;

  -- El mínimo se comprueba sobre la BASE que acaba de calcular la base de
  -- datos, no sobre uno que venga de fuera ni sobre el total con impuestos.
  if v_base < 5.00 then
    raise exception 'El monto mínimo por cobro es €5.00' using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = p_merchant_id;
  v_b := public.helios_charge_breakdown(v_base, coalesce(v_terms.commission_pct, 10));

  -- Idempotente: si ya existe un cobro con esta clave (reintento de red del
  -- cajero), se devuelve el mismo en vez de generar un segundo QR vivo.
  insert into public.charges (
    merchant_id, branch_id, requested_by, idempotency_key,
    amount_usd,
    base_usd, vat_pct, vat_usd,
    consumer_fee_pct, consumer_fee_usd, consumer_fee_vat_usd,
    merchant_fee_pct, merchant_fee_usd, merchant_fee_vat_usd, merchant_net_usd
  )
  values (
    p_merchant_id, p_branch_id, v_staff, p_idempotency_key,
    (v_b->>'consumer_total_usd')::numeric,
    (v_b->>'base_usd')::numeric,
    (v_b->>'vat_pct')::numeric,
    (v_b->>'vat_usd')::numeric,
    (v_b->>'consumer_fee_pct')::numeric,
    (v_b->>'consumer_fee_usd')::numeric,
    (v_b->>'consumer_fee_vat_usd')::numeric,
    (v_b->>'merchant_fee_pct')::numeric,
    (v_b->>'merchant_fee_usd')::numeric,
    (v_b->>'merchant_fee_vat_usd')::numeric,
    (v_b->>'merchant_net_usd')::numeric
  )
  on conflict (idempotency_key) do nothing
  returning * into v_row;

  if v_row.id is null then
    -- Ya existía: NO se vuelven a insertar las líneas, o el reintento
    -- duplicaría el detalle de un cobro que ya está en pantalla.
    select * into v_row from public.charges where idempotency_key = p_idempotency_key;
    return v_row;
  end if;

  insert into public.charge_items
    (charge_id, product_id, name, unit_price_usd, quantity, position)
  select
    v_row.id,
    (l->>'product_id')::uuid,
    l->>'name',
    (l->>'unit_price_usd')::numeric,
    (l->>'quantity')::integer,
    (ord - 1)::smallint
  from jsonb_array_elements(v_lines) with ordinality as t(l, ord);

  return v_row;
end;
$$;

-- ── public.create_group/3 ─ copiada de 20260828000000_volver_a_grupos.sql

create or replace function public.create_group(
  p_name    text,
  p_cap_usd numeric,
  p_pin     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_pin   jsonb;
  v_group public.groups%rowtype;
  v_avail numeric(18,4);
  v_bdate date := public.helios_business_date(now());
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes crear un grupo' using errcode = '22023';
  end if;

  if coalesce(trim(p_name), '') = '' then
    raise exception 'El grupo necesita un nombre' using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de €%', public.min_share_usd() using errcode = '22023';
  end if;

  if p_cap_usd > v_avail then
    raise exception 'Tu techo sería de €% y tienes €% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  insert into public.groups (name, created_by, invite_code, business_date)
  values (trim(p_name), v_user, public.generate_invite_code(), v_bdate)
  returning * into v_group;

  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, authorized_at)
  values (v_group.id, v_user, v_bdate, p_cap_usd, 0, now());

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'invite_code', v_group.invite_code,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_business_day_end(v_bdate)
  );
end;
$$;

-- ── public.admin_set_merchant_status/3 ─ copiada de 20260822150000_edit_merchants.sql

create or replace function public.admin_set_merchant_status(
  p_merchant_id uuid,
  p_status      public.merchant_status,
  p_note        text default null
)
returns public.merchants
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_row   public.merchants%rowtype;
  v_owed  numeric(18,4);
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar el estado de un comercio'
      using errcode = '42501';
  end if;

  -- Terminar un comercio al que todavía se le debe dinero es casi siempre un
  -- error: lo pendiente hay que pagarlo igual. Se bloquea y se dice cuánto.
  if p_status = 'terminated' then
    select coalesce(sum(amount_usd), 0) into v_owed
    from public.settlements
    where merchant_id = p_merchant_id and status = 'pending';

    if v_owed > 0 then
      raise exception 'No puedes terminar este comercio: le debes €%. Págale primero.', v_owed
        using errcode = '22023';
    end if;
  end if;

  update public.merchants
    set status = p_status, updated_at = now()
  where id = p_merchant_id
  returning * into v_row;

  if not found then
    raise exception 'Comercio no encontrado' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.status_changed', p_merchant_id,
    jsonb_build_object('status', p_status, 'note', p_note));

  return v_row;
end;
$$;

-- ── public.notify_group_charge/0 ─ copiada de 20260902121000_los_avisos_automaticos_se_editan_desde_el_panel.sql

create or replace function public.notify_group_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group    text;
  v_merchant text;
  v_who      text;
  v_count    integer;
  v_even     numeric(18,4);
  v_member   record;
  v_extra    text;
begin
  if new.status <> 'confirmed' or old.status = 'confirmed' or new.group_id is null then
    return null;
  end if;

  select g.name into v_group from public.groups g where g.id = new.group_id;
  select m.name into v_merchant from public.merchants m where m.id = new.merchant_id;
  select coalesce(p.full_name, 'Alguien') into v_who
  from public.profiles p where p.id = new.user_id;

  select count(distinct i.user_id) into v_count
  from public.installments i where i.charge_id = new.id;

  v_even := round(new.amount_usd / greatest(v_count, 1), 2);

  for v_member in
    select i.user_id, sum(i.amount_usd) as total
    from public.installments i
    where i.charge_id = new.id and i.user_id <> new.user_id
    group by i.user_id
  loop
    -- Un céntimo por encima de lo parejo es redondeo, no absorción. El umbral
    -- evita convertir el reparto de céntimos en un aviso alarmante.
    v_extra := case
      when v_member.total > v_even + 0.05
        then format(' Te tocó más de lo parejo (€%s) porque a alguien no le llegaba el techo.',
                    trim(to_char(v_even, 'FM999999990.00')))
      else ''
    end;

    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s pagó en %s', v_who, v_merchant),
      format('Te tocaron €%s de una cuenta de €%s entre %s, en %s.%s Se paga en dos cuotas.',
             trim(to_char(v_member.total, 'FM999999990.00')),
             trim(to_char(new.amount_usd, 'FM999999990.00')),
             v_count, coalesce(v_group, 'tu grupo'), v_extra),
      jsonb_build_object(
        'charge_id', new.id,
        'group_id', new.group_id,
        'amount_usd', v_member.total,
        'initiated_by', new.user_id
      ),
      'group_charge.consumo',
      jsonb_build_object(
        'quien',    v_who,
        'comercio', v_merchant,
        'monto',    trim(to_char(v_member.total, 'FM999999990.00')),
        'total',    trim(to_char(new.amount_usd, 'FM999999990.00')),
        'personas', v_count,
        'grupo',    coalesce(v_group, 'tu grupo'),
        'extra',    v_extra
      )
    );
  end loop;

  return null;
end;
$$;

-- ── public.notify_payment_result/0 ─ copiada de 20260902121000_los_avisos_automaticos_se_editan_desde_el_panel.sql

create or replace function public.notify_payment_result()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_quote  public.payment_quotes%rowtype;
  v_motivo text;
begin
  if new.status = old.status then
    return null;
  end if;

  select * into v_quote from public.payment_quotes where id = new.quote_id;

  if new.status = 'reconciled' then
    perform public.notify(
      new.user_id, 'payment_reconciled',
      'Confirmamos tu pago',
      format('Recibimos €%s. %s cuota(s) quedaron al día.',
             trim(to_char(v_quote.amount_usd, 'FM999999990.00')),
             v_quote.installment_count),
      jsonb_build_object('report_id', new.id, 'amount_usd', v_quote.amount_usd),
      'payment_reconciled',
      jsonb_build_object(
        'monto',  trim(to_char(v_quote.amount_usd, 'FM999999990.00')),
        'cuotas', v_quote.installment_count
      )
    );

  elsif new.status = 'rejected' then
    -- El motivo es el cuerpo entero del aviso de hoy. Se calcula una vez para
    -- que el respaldo y el marcador no puedan decir cosas distintas.
    v_motivo := coalesce(new.rejection_note,
      'No encontramos esa referencia. Revísala y vuelve a reportarla.');

    perform public.notify(
      new.user_id, 'payment_rejected',
      'No pudimos confirmar tu pago',
      v_motivo,
      jsonb_build_object('report_id', new.id),
      'payment_rejected',
      jsonb_build_object('motivo', v_motivo)
    );
  end if;

  return null;
end;
$$;

-- ── public.evaluate_level/2 ─ copiada de 20260822171000_level_promotion_engine.sql

create or replace function public.evaluate_level(
  p_user_id       uuid,
  p_cooldown_days integer default 60
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_standing jsonb;
  v_current  smallint;
  v_eligible smallint;
  v_new      public.levels%rowtype;
begin
  v_standing := public.level_standing(p_user_id, p_cooldown_days);

  v_current  := (v_standing->>'current_level')::smallint;
  v_eligible := (v_standing->>'eligible_level')::smallint;

  -- Una cuenta congelada, bloqueada o expulsada no sube. Premiar a quien está
  -- en mora contradice para qué existen los niveles.
  if (v_standing->>'account_status') <> 'active' then
    return jsonb_build_object('promoted', false, 'reason', 'cuenta_no_activa');
  end if;

  if (v_standing->>'in_cooldown')::boolean then
    return jsonb_build_object(
      'promoted', false, 'reason', 'enfriamiento',
      'until', v_standing->>'cooldown_until'
    );
  end if;

  if v_eligible <= v_current then
    return jsonb_build_object('promoted', false, 'reason', 'sin_cambio');
  end if;

  select * into v_new from public.levels where level = v_eligible;

  update public.profiles
    set level = v_eligible, updated_at = now()
  where id = p_user_id;

  insert into public.level_changes (user_id, from_level, to_level, reason, detail)
  values (
    p_user_id, v_current, v_eligible, 'promotion',
    jsonb_build_object(
      'paid_usd', v_standing->'paid_usd',
      'months', v_standing->'months',
      'required_spend_usd', v_new.required_spend_usd,
      'required_months', v_new.required_months
    )
  );

  perform public.notify(
    p_user_id, 'level_up',
    format('Subiste al %s', v_new.label),
    format('Tu límite pasa a €%s. Lo lograste pagando €%s a tiempo.',
           trim(to_char(v_new.monthly_limit_usd, 'FM999999990.00')),
           trim(to_char((v_standing->>'paid_usd')::numeric, 'FM999999990.00'))),
    jsonb_build_object('level', v_eligible, 'limit_usd', v_new.monthly_limit_usd)
  );

  return jsonb_build_object(
    'promoted', true,
    'from_level', v_current,
    'to_level', v_eligible,
    'limit_usd', v_new.monthly_limit_usd
  );
end;
$$;

-- ── public.confirm_charge/3 ─ copiada de 20260830240000_el_saldo_se_libera_por_factura.sql

create or replace function public.confirm_charge(p_charge_id uuid, p_idempotency_key text, p_pin text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'ledger', 'pg_temp'
as $function$
declare
  v_user        uuid := auth.uid();
  v_pin       jsonb;
  v_charge      public.charges%rowtype;
  v_profile     public.profiles%rowtype;
  v_limit       numeric(18,4);
  v_open_debt   numeric(18,4);
  v_terms       public.merchant_settlement_terms%rowtype;
  v_bdate       date;
  v_due_1       date;
  v_due_2       date;
  v_tx          uuid;
  v_acct_recv   uuid;
  v_acct_pay    uuid;
  v_acct_rev    uuid;
  v_upfront     numeric(18,4);
  v_revenue     numeric(18,4);
  v_merchant_share numeric(18,4);
  v_financed    numeric(18,4);
  v_split       jsonb;
  v_first       numeric(18,4);
  v_second      numeric(18,4);
  v_confirmed_at timestamptz;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- El PIN, antes de tocar nada. Un PIN incorrecto se DEVUELVE, no se lanza:
  -- un `raise` revertiría el intento fallido recién anotado y convertiría este
  -- cobro en un oráculo para probar PINes sin límite ni rastro.
  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    if v_charge.user_id <> v_user then
      raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
    end if;
    return jsonb_build_object('ok', true, 'charge_id', v_charge.id, 'already_confirmed', true);
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo' using errcode = '22023';
  end if;

  if v_charge.user_id is not null and v_charge.user_id <> v_user then
    raise exception 'Este cobro ya fue tomado por otra persona' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = v_user for update;

  if v_profile.status <> 'active' then
    raise exception 'Tu cuenta no puede consumir en este estado (%)', v_profile.status
      using errcode = '22023';
  end if;

  -- La mora, comprobada AQUÍ y no heredada del cron: `profiles.status` lo mueve
  -- `process_mora` a las 10:05 pero el día operativo cambia a las 10:00.
  if not public.can_take_debt(v_user) then
    raise exception 'Tienes una cuota vencida: págala para volver a consumir'
      using errcode = '22023';
  end if;

  -- Lo que financia Ronda, que es lo único que ocupa cupo. En los cobros
  -- anteriores al desglose la base es nula y el total ERA la base.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  select monthly_limit_usd into v_limit from public.levels where level = v_profile.level;

  -- NUEVO: el cupo ocupado sale de las cuotas, que es de donde sale el
  -- disponible que el usuario tenía delante.
  v_open_debt := public.helios_credit_used_usd(v_user);

  if v_open_debt + v_financed > v_limit then
    raise exception 'Saldo insuficiente: disponible €%, consumo €%',
      (v_limit - v_open_debt), v_financed
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2 from public.helios_installment_due_dates(v_bdate);

  v_acct_recv := ledger.get_or_create_account('user_receivable', v_user);
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev  := ledger.get_or_create_account('platform_revenue', null);

  v_revenue := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_merchant_share := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id, 'Venta en comercio')
  returning id into v_tx;

  -- Las cuatro patas de una vez, saltándose las que valen cero: `entries` tiene
  -- un check que rechaza un asiento con debe y haber en cero.
  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (v_acct_recv, v_charge.amount_usd, 0::numeric),
    (v_acct_pay, 0::numeric, v_merchant_share),
    (v_acct_rev, 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_merchant_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  v_upfront := round(v_merchant_share * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  v_split  := public.helios_assign_debt(
    v_user, v_charge.id, v_financed, v_charge.amount_usd, v_due_1, v_due_2,
    format('Saldo insuficiente para un consumo de €%s',
           trim(to_char(v_financed, 'FM999999990.00')))
  );
  v_first  := (v_split->>'installment_1_usd')::numeric;
  v_second := (v_split->>'installment_2_usd')::numeric;

  update public.charges
    set status = 'confirmed', user_id = v_user, business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id
  returning confirmed_at into v_confirmed_at;

  return jsonb_build_object(
    'ok', true, 'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    'financed_usd', v_financed,
    'due_1', v_due_1, 'due_2', v_due_2,
    'installment_1_usd', v_first,
    'installment_2_usd', v_second,
    'confirmed_at', v_confirmed_at
  );
end;
$function$
;

-- ── public.join_group/3 ─ copiada de 20260903000000_entrar_al_grupo_es_entrar_a_lo_ya_gastado.sql

create or replace function public.join_group(
  p_invite_code text,
  p_cap_usd     numeric,
  p_pin         text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user   uuid := auth.uid();
  v_pin    jsonb;
  v_group  public.groups%rowtype;
  v_bdate  date := public.helios_business_date(now());
  v_count  integer;
  v_avail  numeric(18,4);
  v_plan   jsonb;
  v_retro  numeric(18,4);
  v_owed   numeric(18,4);
  v_row    record;
  v_done   jsonb;
  v_paid   numeric(18,4) := 0;
  v_taken  numeric(18,4) := 0;
  v_charges integer := 0;
  v_skipped integer := 0;
  v_name   text;
  v_member record;
  v_theirs numeric(18,4);
  v_before jsonb;
  v_was    numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  -- El candado del grupo: dos personas entrando a la vez se ponen en fila, y
  -- la segunda ve el reparto que dejó la primera.
  select * into v_group from public.groups
  where invite_code = upper(trim(p_invite_code)) and business_date = v_bdate
  for update;

  if not found then
    raise exception 'Ese código no corresponde a ningún grupo de esta noche'
      using errcode = 'P0002';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes entrar a un grupo' using errcode = '22023';
  end if;

  select count(*) into v_count from public.group_members
  where group_id = v_group.id and left_at is null;

  if v_count >= public.max_group_members() then
    raise exception 'El grupo ya tiene % integrantes', public.max_group_members()
      using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  -- ── Lo que ya lleva el grupo ──────────────────────────────────────────────
  v_plan := public.helios_group_join_plan(v_group.id, v_user);

  -- Solo se bloquea por saldo. Una cuenta demasiado pequeña para uno más no
  -- cierra el grupo: se salta esa y se entra a las demás (ver el plan).
  if not coalesce((v_plan->>'ok')::boolean, false) then
    raise exception
      'No te alcanza el saldo para tomar tu parte de lo que el grupo ya lleva gastado'
      using errcode = '22023';
  end if;

  v_retro := (v_plan->>'financed_usd')::numeric;

  -- REGLA 3: volver a entrar arranca cubriendo lo que este grupo ya me cargó,
  -- no en cero. Lo ya gastado sigue siendo deuda mía y el techo es de la noche
  -- entera, no de cada visita.
  select coalesce(sum(i.financed_usd), 0) into v_owed
  from public.installments i
  join public.charges c on c.id = i.charge_id
  where c.group_id = v_group.id and i.user_id = v_user;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu aporte máximo no puede bajar de €%', public.min_share_usd()
      using errcode = '22023';
  end if;

  -- REGLA 1: el techo es para lo que VIENE. Lo ya gastado no se negocia a la
  -- baja: o lo cubre, o no se entra.
  if p_cap_usd < v_owed + v_retro then
    raise exception
      'Tu aporte máximo tiene que cubrir al menos los €% que ya te tocan de lo que el grupo lleva gastado',
      trim(to_char(v_owed + v_retro, 'FM999999990.00'))
      using errcode = '22023';
  end if;

  if p_cap_usd > v_avail + v_owed then
    raise exception 'Tu aporte máximo sería de €% y tienes €% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  -- La foto de lo que debe cada quien ANTES de tocar nada. Es lo único con lo
  -- que el aviso del final puede saber si a alguien le bajó la parte de verdad.
  select coalesce(jsonb_object_agg(t.user_id::text, t.total), '{}'::jsonb) into v_before
  from (
    select i.user_id, sum(i.amount_usd) as total
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.group_id = v_group.id
    group by i.user_id
  ) t;

  insert into public.group_members
    (group_id, user_id, business_date, cap_usd, spent_usd, left_at, authorized_at, status)
  values
    (v_group.id, v_user, v_bdate, p_cap_usd, v_owed, null, now(), 'active')
  on conflict (group_id, user_id) do update
    set cap_usd       = excluded.cap_usd,
        spent_usd     = excluded.spent_usd,
        left_at       = null,
        authorized_at = now(),
        status        = 'active';

  -- ── El reparto retroactivo, cuenta por cuenta ─────────────────────────────
  -- La capacidad se va gastando en el mismo orden que en el plan, así que sale
  -- exactamente la cifra que se enseñó antes del PIN.
  --
  -- ⬜ Esta lista es la que se queda corta en la carrera conocida: un cobro que
  -- se está confirmando AHORA MISMO en otra transacción no se ve desde aquí, y
  -- esa cuenta acabará sin el que entra. Punto 10 de este archivo, y
  -- `helios_group_split_gaps` para detectarlo.
  for v_row in select * from public.helios_group_open_charges(v_group.id, v_user) loop
    v_done := public.helios_group_resplit_charge(
      v_row.charge_id, v_user, greatest(v_avail - v_taken, 0)
    );

    -- Demasiado pequeña para uno más: queda como estaba y no cuenta como suya.
    if coalesce((v_done->>'skipped')::boolean, false) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_taken   := v_taken + (v_done->>'financed_usd')::numeric;
    v_paid    := v_paid  + (v_done->>'payable_usd')::numeric;
    v_charges := v_charges + 1;
  end loop;

  -- ── El aviso: uno solo, y con la cifra ya cerrada ─────────────────────────
  select coalesce(full_name, 'Alguien') into v_name from public.profiles where id = v_user;

  for v_member in
    select user_id from public.group_members
    where group_id = v_group.id and left_at is null and user_id <> v_user
  loop
    select coalesce(sum(i.amount_usd), 0) into v_theirs
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.group_id = v_group.id and i.user_id = v_member.user_id;

    /**
     * "Tu parte bajó" solo si de verdad bajó.
     *
     * No siempre baja, y el caso no es raro: un grupo de dos con una sola
     * cuenta de €6 no puede repartirla entre tres —no llega a €7,50— así que
     * el tercero entra sin asumir nada y a los dos de antes no les cambia un
     * céntimo. Decirles "bajó a €3,00" cuando siguen debiendo los mismos €3
     * es un aviso que miente sobre dinero, que es la peor clase de aviso.
     */
    v_was := coalesce((v_before->>v_member.user_id::text)::numeric, 0);

    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s entró a %s', v_name, v_group.name),
      case
        when v_theirs < v_was then
          format('Ya son %s y tu parte de la noche bajó a €%s.',
                 v_count + 1, trim(to_char(v_theirs, 'FM999999990.00')))
        else
          format('Ya son %s. Lo que pague cualquiera se reparte entre todos hasta las 10 AM.',
                 v_count + 1)
      end,
      jsonb_build_object('group_id', v_group.id, 'user_id', v_user)
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'group_id', v_group.id,
    'name', v_group.name,
    'cap_usd', p_cap_usd,
    'closes_at', public.helios_business_day_end(v_group.business_date),
    -- Lo que se acaba de asumir al entrar. El acuse lo dice.
    'retro_charge_count', v_charges,
    'retro_financed_usd', v_taken,
    'retro_payable_usd', v_paid,
    -- Y de las que no es parte, por pequeñas.
    'skipped_charge_count', v_skipped
  );
end;
$$;

-- ── public.confirm_charge_as_group/5 ─ copiada de 20260830190000_el_fee_no_come_cupo.sql

CREATE OR REPLACE FUNCTION public.confirm_charge_as_group(
  p_charge_id uuid,
  p_group_id uuid,
  p_idempotency_key text,
  p_pin text,
  p_expected_share_usd numeric
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'pg_temp'
AS $function$
declare
  v_user    uuid := auth.uid();
  v_pin     jsonb;
  v_charge  public.charges%rowtype;
  v_group_id  uuid;
  v_terms   public.merchant_settlement_terms%rowtype;
  v_parts   jsonb := '[]'::jsonb;
  v_split   jsonb;
  v_shares  jsonb;
  v_row     record;
  v_share   numeric(18,4);
  v_my      numeric(18,4) := 0;
  v_count   integer;
  v_bdate   date;
  v_due_1   date;
  v_due_2   date;
  v_tx      uuid;
  v_acct_pay uuid;
  v_acct_rev uuid;
  v_upfront  numeric(18,4);
  v_revenue  numeric(18,4);
  v_merchant_share numeric(18,4);
  v_confirmed_at   timestamptz;
  v_debt     jsonb;
  v_first    numeric(18,4);
  v_second   numeric(18,4);
  v_my_first numeric(18,4);
  v_my_second numeric(18,4);
  -- NUEVO: lo financiado del cobro, el pagadero de cada quien y el acumulado
  -- que hace que la suma cuadre al céntimo con el asiento.
  v_financed  numeric(18,4);
  v_payable   numeric(18,4);
  v_assigned  numeric(18,4) := 0;
  v_i         integer := 0;
  v_my_payable numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Sin importe esperado no se cobra. Es el consentimiento del usuario traído
  -- hasta aquí; dejarlo opcional sería no tenerlo.
  if p_expected_share_usd is null then
    raise exception 'Falta el importe autorizado' using errcode = '22023';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  if v_charge.status = 'confirmed' then
    return jsonb_build_object(
      'ok', true, 'charge_id', v_charge.id, 'already_confirmed', true,
      'confirmed_at', v_charge.confirmed_at
    );
  end if;

  if v_charge.status <> 'pending' then
    raise exception 'Este cobro ya no está disponible (%)', v_charge.status
      using errcode = '22023';
  end if;

  if v_charge.expires_at < now() then
    raise exception 'Este QR caducó, pídele al local que genere uno nuevo'
      using errcode = '22023';
  end if;

  v_group_id := p_group_id;

  if not exists (
    select 1 from public.group_members
    where group_id = v_group_id
      and user_id = v_user
      and left_at is null
      and business_date = public.helios_business_date(now())
  ) then
    raise exception 'No perteneces a este grupo' using errcode = '42501';
  end if;

  -- El que inicia tiene que poder asumir su parte: sin esto, alguien con una
  -- cuota vencida quedaba fuera del reparto y la venta salía repartida solo
  -- entre los demás.
  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes iniciar un cobro del grupo'
      using errcode = '22023';
  end if;

  -- Se bloquean las filas del grupo antes de leer capacidades: dos cobros
  -- simultáneos en el mismo grupo no pueden repartir cada uno sobre el mismo
  -- techo sin verse.
  perform 1 from public.group_members
  where group_id = v_group_id and left_at is null
  order by user_id
  for update;

  for v_row in select * from public.group_participants(v_group_id) loop
    if v_row.can_take_debt then
      v_parts := v_parts || jsonb_build_object(
        'user_id', v_row.user_id, 'capacity_usd', v_row.capacity_usd
      );
    end if;
  end loop;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Se reparte lo FINANCIADO. Las capacidades son de crédito (techo menos
  -- gastado, contra el saldo disponible), así que el total que se reparte tiene
  -- que estar en la misma moneda.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);
  v_split := public.helios_split_shares(v_financed, v_parts);
  -- ─────────────────────────────────────────────────────────────────────────

  if not coalesce((v_split->>'ok')::boolean, false) then
    if v_split->>'reason' = 'too_small' then
      raise exception 'Entre % la cuenta mínima es €% y esta es de €%',
        v_split->>'split_between', v_split->>'min_total_usd', v_financed
        using errcode = '22023';
    else
      raise exception 'El grupo llega a €% y la cuenta es de €%',
        v_split->>'capacity_usd', v_financed
        using errcode = '22023';
    end if;
  end if;

  v_shares := v_split->'shares';
  v_count  := (v_split->>'split_between')::integer;

  -- El iniciador tiene que salir en el reparto: si su techo se agotó o su saldo
  -- no llega al mínimo por persona, la cuenta entera caería sobre los demás.
  select (s->>'share_usd')::numeric into v_my
  from jsonb_array_elements(v_shares) s
  where (s->>'user_id')::uuid = v_user;

  if v_my is null then
    raise exception 'No te alcanza para poner tu parte de esta cuenta'
      using errcode = '22023';
  end if;

  -- Y esa parte no puede pasarse de la que se autorizó con el PIN. Solo hacia
  -- arriba: que baje no perjudica a quien paga. El céntimo de tolerancia es por
  -- el viaje del número en coma flotante desde el teléfono.
  if v_my > p_expected_share_usd + 0.01 then
    raise exception
      'Tu parte cambió a €% mientras confirmabas (habías autorizado €%): vuelve a mirar el reparto',
      trim(to_char(v_my, 'FM999999990.00')),
      trim(to_char(p_expected_share_usd, 'FM999999990.00'))
      using errcode = '22023';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = v_charge.merchant_id;

  v_bdate := public.helios_business_date(now());
  select due_1, due_2 into v_due_1, v_due_2
  from public.helios_installment_due_dates(v_bdate);

  v_acct_pay := ledger.get_or_create_account('merchant_payable', v_charge.merchant_id);
  v_acct_rev := ledger.get_or_create_account('platform_revenue', null);

  v_revenue        := coalesce(v_charge.consumer_fee_usd, 0) + coalesce(v_charge.merchant_fee_usd, 0);
  v_merchant_share := coalesce(v_charge.merchant_net_usd, v_charge.amount_usd - v_revenue);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', p_idempotency_key, v_bdate, v_charge.id,
          format('Venta repartida en grupo entre %s personas', v_count))
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  select v_tx, x.acct, x.debit, x.credit
  from (values
    (v_acct_pay, 0::numeric, v_merchant_share),
    (v_acct_rev, 0::numeric, v_revenue),
    (ledger.get_or_create_account('vat_payable', null), 0::numeric,
     v_charge.amount_usd - v_merchant_share - v_revenue)
  ) as x(acct, debit, credit)
  where x.debit <> 0 or x.credit <> 0;

  -- --- Una deuda por integrante, contra su propio límite -------------------
  for v_row in
    select (s->>'user_id')::uuid as user_id, (s->>'share_usd')::numeric as share
    from jsonb_array_elements(v_shares) s
    order by 1
  loop
    v_share := v_row.share;
    v_i := v_i + 1;

    -- ── NUEVO ──────────────────────────────────────────────────────────────
    -- El fee de cada quien cae sobre su parte. **El residuo de redondeo va al
    -- último** y no se reparte: la suma de los pagaderos tiene que dar EXACTO
    -- el total del cobro, porque es la contrapartida del asiento de arriba y el
    -- libro cuadra al céntimo o no cuadra.
    if v_i = v_count then
      v_payable := v_charge.amount_usd - v_assigned;
    else
      v_payable := public.helios_payable_usd(v_share, v_financed, v_charge.amount_usd);
    end if;
    v_assigned := v_assigned + v_payable;
    -- ───────────────────────────────────────────────────────────────────────

    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), v_payable, 0);

    v_debt   := public.helios_assign_debt(
      v_row.user_id, v_charge.id, v_share, v_payable, v_due_1, v_due_2,
      format('Alguien del grupo ya no tiene límite para €%s',
             trim(to_char(v_share, 'FM999999990.00')))
    );
    v_first  := (v_debt->>'installment_1_usd')::numeric;
    v_second := (v_debt->>'installment_2_usd')::numeric;

    if v_row.user_id = v_user then
      v_my_first   := v_first;
      v_my_second  := v_second;
      v_my_payable := v_payable;
    end if;

    -- El techo es acumulativo por la noche: aquí es donde se gasta. Se gasta lo
    -- FINANCIADO, que es de lo que es techo.
    update public.group_members
      set spent_usd = spent_usd + v_share
    where group_id = v_group_id and user_id = v_row.user_id;
  end loop;

  v_upfront := round(v_merchant_share * v_terms.upfront_pct / 100, 4);
  perform ledger.record_advance_settlement(v_charge.merchant_id, v_charge.id, v_upfront, v_bdate);

  update public.charges
    set status = 'confirmed', user_id = v_user, group_id = v_group_id,
        business_date = v_bdate, confirmed_at = now()
  where id = v_charge.id
  returning confirmed_at into v_confirmed_at;

  return jsonb_build_object(
    'ok', true,
    'charge_id', v_charge.id,
    'amount_usd', v_charge.amount_usd,
    -- NUEVO: lo financiado del cobro entero y lo mío, en las dos monedas.
    'financed_usd', v_financed,
    'split_between', v_count,
    'share_usd', v_my,
    'my_payable_usd', v_my_payable,
    'even_share_usd', round(v_financed / v_count, 2),
    'due_1', v_due_1,
    'due_2', v_due_2,
    'installment_1_usd', v_my_first,
    'installment_2_usd', v_my_second,
    'confirmed_at', v_confirmed_at
  );
end;
$function$
;

-- ── public.set_my_group_cap/3 ─ copiada de 20260829040000_centimos_privacidad_y_capacidad.sql

create or replace function public.set_my_group_cap(
  p_group_id uuid,
  p_cap_usd  numeric,
  p_pin      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_mine  public.group_members%rowtype;
  v_avail numeric(18,4);
  v_group public.groups%rowtype;
  v_pin   jsonb;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_mine from public.group_members
  where group_id = p_group_id and user_id = v_user and left_at is null
  for update;

  if not found then
    raise exception 'No estás en este grupo' using errcode = 'P0002';
  end if;

  -- NUEVO: un grupo de anoche no admite cambios. Cobrar ya lo comprobaba;
  -- esto contestaba igual y dejaba mover el techo de algo que ya murió.
  select * into v_group from public.groups where id = p_group_id;

  if v_group.business_date <> public.helios_business_date(now()) then
    raise exception 'Este grupo ya se cerró' using errcode = '22023';
  end if;

  -- NUEVO: subirlo compromete más crédito, así que se firma.
  if p_cap_usd > v_mine.cap_usd then
    v_pin := public.verify_user_pin(p_pin);
    if not coalesce((v_pin->>'ok')::boolean, false) then
      return v_pin;
    end if;
  end if;

  if p_cap_usd < v_mine.spent_usd then
    raise exception 'Ya llevas €% en este grupo, el techo no puede bajar de ahí',
      v_mine.spent_usd using errcode = '22023';
  end if;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de €%', public.min_share_usd()
      using errcode = '22023';
  end if;

  v_avail := public.available_usd(v_user);

  -- El disponible ya tiene descontado lo gastado, así que el techo máximo es
  -- lo gastado más lo que queda.
  if p_cap_usd > v_mine.spent_usd + v_avail then
    raise exception 'Tu techo sería de €% y solo puedes llegar a €%',
      p_cap_usd, v_mine.spent_usd + v_avail using errcode = '22023';
  end if;

  update public.group_members set cap_usd = p_cap_usd
  where group_id = p_group_id and user_id = v_user;

  return jsonb_build_object('ok', true, 'cap_usd', p_cap_usd);
end;
$$;

-- ── public.helios_group_resplit_charge/3 ─ copiada de 20260903000000_entrar_al_grupo_es_entrar_a_lo_ya_gastado.sql

create or replace function public.helios_group_resplit_charge(
  p_charge_id    uuid,
  p_user         uuid,
  p_capacity_usd numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_charge    public.charges%rowtype;
  v_parts     jsonb := '[]'::jsonb;
  v_split     jsonb;
  v_payables  jsonb;
  v_row       record;
  v_financed  numeric(18,4);
  v_new       numeric(18,4);
  v_new_pay   numeric(18,4);
  v_fin_delta numeric(18,4);
  v_delta     numeric(18,4);
  v_fee_delta numeric(18,4);
  v_half      numeric(18,4);
  v_mine      numeric(18,4);
  v_mine_pay  numeric(18,4);
  v_due_1     date;
  v_due_2     date;
  v_tx        uuid;
  v_n         integer;
begin
  select * into v_charge from public.charges where id = p_charge_id for update;
  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  -- Las cuotas de la cuenta, bloqueadas antes de leerlas y en orden fijo: dos
  -- personas entrando a la vez no pueden repartir cada una sobre la foto vieja.
  perform 1 from public.installments
  where charge_id = p_charge_id order by user_id, sequence for update;

  -- Defensivo. Con la regla 2 (punto 2) ninguna cuota de un grupo vivo puede
  -- haberse movido, así que esto no debería dispararse nunca; si se dispara es
  -- que apareció otro camino para pagar y hay que mirarlo, no que el usuario
  -- hizo algo raro.
  if exists (
    select 1 from public.installments
    where charge_id = p_charge_id and status <> 'pending'
  ) then
    raise exception 'Una de las cuentas del grupo ya se está pagando: no se puede repartir ahora'
      using errcode = '22023';
  end if;

  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  for v_row in select * from public.charge_debtors(p_charge_id) loop
    v_parts := v_parts || jsonb_build_object(
      'user_id', v_row.user_id, 'capacity_usd', v_row.financed_usd
    );
  end loop;

  v_parts := v_parts || jsonb_build_object(
    'user_id', p_user, 'capacity_usd', p_capacity_usd
  );

  v_split := public.helios_split_shares(v_financed, v_parts);

  -- Demasiado pequeña para uno más: se deja intacta y se avisa a quien llama,
  -- que la contará como saltada. Mismo criterio que `helios_group_join_plan`, y
  -- por eso sale la misma cifra que se enseñó antes del PIN.
  if v_split->>'reason' = 'too_small' then
    return jsonb_build_object('charge_id', p_charge_id, 'skipped', true);
  end if;

  if not coalesce((v_split->>'ok')::boolean, false) then
    raise exception 'No se pudo repartir una de las cuentas del grupo' using errcode = '22023';
  end if;

  v_n        := (v_split->>'split_between')::integer;
  v_payables := public.helios_payables(v_split->'shares', v_financed, v_charge.amount_usd);

  -- Las fechas del consumo, no las de hoy: quien entra hereda las de la orden.
  -- Calcularlas de nuevo le daría más plazo por llegar más tarde, y dos
  -- personas del mismo ticket acabarían con fechas distintas.
  select due_date into v_due_1 from public.installments
  where charge_id = p_charge_id and sequence = 1 limit 1;
  select due_date into v_due_2 from public.installments
  where charge_id = p_charge_id and sequence = 2 limit 1;

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values ('charge', 'join:' || p_charge_id::text || ':' || p_user::text,
          v_charge.business_date, p_charge_id,
          format('Entra alguien al grupo: esta cuenta pasa a repartirse entre %s', v_n))
  returning id into v_tx;

  -- ── A los que ya debían: se les baja ──────────────────────────────────────
  for v_row in select * from public.charge_debtors(p_charge_id) loop
    select (s->>'share_usd')::numeric into v_new
    from jsonb_array_elements(v_split->'shares') s
    where (s->>'user_id')::uuid = v_row.user_id;

    v_new     := coalesce(v_new, v_row.financed_usd);
    v_new_pay := coalesce((v_payables->>v_row.user_id::text)::numeric, v_row.share_usd);

    -- Dos deltas: el de cupo mueve el bloque y el techo del grupo; el de
    -- pagadero mueve el libro y las cuotas.
    v_fin_delta := v_row.financed_usd - v_new;
    v_delta     := v_row.share_usd - v_new_pay;
    v_fee_delta := v_delta - v_fin_delta;

    continue when v_delta <= 0 and v_fin_delta <= 0;

    v_half := round(v_new_pay / 2, 2);
    update public.installments
      set amount_usd = v_half, financed_usd = round(v_new / 2, 2)
    where charge_id = p_charge_id and user_id = v_row.user_id and sequence = 1;
    update public.installments
      set amount_usd = v_new_pay - v_half, financed_usd = v_new - round(v_new / 2, 2)
    where charge_id = p_charge_id and user_id = v_row.user_id and sequence = 2;

    update public.user_credit_blocks
      set charged_usd = charged_usd - v_fin_delta,
          fee_usd     = greatest(fee_usd - v_fee_delta, 0)
    where user_id = v_row.user_id and closed_at is null;

    -- Se libera CUPO, que es de lo que el techo es techo.
    if v_charge.group_id is not null then
      update public.group_members
        set spent_usd = greatest(spent_usd - v_fin_delta, 0)
      where group_id = v_charge.group_id and user_id = v_row.user_id;
    end if;

    if v_delta > 0 then
      insert into ledger.entries (transaction_id, account_id, debit, credit)
      values (v_tx, ledger.get_or_create_account('user_receivable', v_row.user_id), 0, v_delta);
    end if;
  end loop;

  -- ── Al que entra: su deuda ────────────────────────────────────────────────
  select (s->>'share_usd')::numeric into v_mine
  from jsonb_array_elements(v_split->'shares') s
  where (s->>'user_id')::uuid = p_user;

  if v_mine is null then
    raise exception 'No te alcanza para tomar parte de una de las cuentas del grupo'
      using errcode = '22023';
  end if;

  v_mine_pay := coalesce((v_payables->>p_user::text)::numeric,
                         public.helios_payable_usd(v_mine, v_financed, v_charge.amount_usd));

  perform public.helios_assign_debt(
    p_user, p_charge_id, v_mine, v_mine_pay, v_due_1, v_due_2,
    format('Tu límite no cubre €%s de lo que el grupo ya lleva',
           trim(to_char(v_mine, 'FM999999990.00')))
  );

  if v_charge.group_id is not null then
    update public.group_members
      set spent_usd = spent_usd + v_mine
    where group_id = v_charge.group_id and user_id = p_user and left_at is null;
  end if;

  insert into ledger.entries (transaction_id, account_id, debit, credit)
  values (v_tx, ledger.get_or_create_account('user_receivable', p_user), v_mine_pay, 0);

  return jsonb_build_object(
    'charge_id', p_charge_id,
    'financed_usd', v_mine,
    'payable_usd', v_mine_pay,
    'split_between', v_n
  );
end;
$$;

-- ── public.notify_installment_moment/2 ─ copiada de 20260904100000_el_recordatorio_es_uno_por_fecha_y_son_cuatro.sql

create or replace function public.notify_installment_moment(
  p_offset integer,
  p_key    text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_row     record;
  v_count   integer := 0;
  v_due     date := public.helios_business_date(now()) - p_offset;
  v_tpl     public.notification_templates%rowtype;
  v_fee     numeric := public.helios_late_fee_usd();
  v_dia     text := public.helios_weekday_es(v_due);
  v_fecha   text := to_char(v_due, 'DD/MM');
  v_comercio text;
begin
  select * into v_tpl from public.notification_templates where key = p_key;

  if not found then
    raise exception 'No existe el aviso %', p_key using errcode = '22023';
  end if;

  -- Apagado desde el panel: ni se busca a quién avisar. `notify` lo comprobaría
  -- igual, pero por fila y después de recorrer la tabla entera.
  if not v_tpl.enabled then
    return 0;
  end if;

  for v_row in
    select i.user_id,
           sum(i.amount_usd)        as monto,
           count(*)                 as cuotas,
           min(m.name)              as un_local,
           count(distinct m.id)     as locales
    from public.installments i
    join public.charges c   on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    where i.status = 'pending'
      and i.due_date = v_due
      -- Con un pago reportado esperando conciliación no se avisa: se debe,
      -- pero el usuario ya hizo lo suyo.
      and not exists (
        select 1
        from public.payment_reports r
        join public.payment_quote_items q on q.quote_id = r.quote_id
        where q.installment_id = i.id
          and r.status in ('reported', 'in_review')
      )
    group by i.user_id
  loop
    -- Ya se avisó de esta fecha en este momento.
    if exists (
      select 1 from public.notifications
      where user_id = v_row.user_id
        and template_key = p_key
        and data->>'due_date' = v_due::text
    ) then
      continue;
    end if;

    v_comercio := case
      when v_row.locales = 1 then v_row.un_local
      else format('%s locales', v_row.locales)
    end;

    perform public.notify(
      v_row.user_id,
      'installment_due'::public.notification_type,
      -- El texto de fábrica, por si nadie publicó nada desde el panel. Se
      -- construye igual que el de la plantilla, con los mismos datos.
      case
        when p_offset < 0 then format('Tu cuota del %s', v_dia)
        when p_offset = 0 then format('Hoy pagas €%s',
                                      trim(to_char(v_row.monto, 'FM999999990.00')))
        when p_offset = 1 then 'Tu cuota está vencida'
        else 'Mañana se suma el cargo por mora'
      end,
      case
        when p_offset < 0 then format('€%s el %s %s. Toca para pagarla.',
                                      trim(to_char(v_row.monto, 'FM999999990.00')),
                                      v_dia, v_fecha)
        when p_offset = 0 then format('Tu cuota del %s %s. Hoy es el último día sin bloqueo.',
                                      v_dia, v_fecha)
        when p_offset = 1 then format('€%s del %s %s. Hasta que la pagues no puedes pagar en locales.',
                                      trim(to_char(v_row.monto, 'FM999999990.00')),
                                      v_dia, v_fecha)
        else format('Paga hoy los €%s del %s %s y te ahorras €%s por cuota.',
                    trim(to_char(v_row.monto, 'FM999999990.00')),
                    v_dia, v_fecha,
                    trim(to_char(v_fee, 'FM999999990.00')))
      end,
      -- `due_date` es lo que abre Cuotas con esa fecha ya marcada. Viajaba
      -- desde el primer día y hasta ahora no lo usaba nadie.
      jsonb_build_object('due_date', v_due, 'moment', p_key),
      p_key,
      jsonb_build_object(
        'dia',      v_dia,
        'fecha',    v_fecha,
        'dias',     abs(p_offset),
        'monto',    trim(to_char(v_row.monto, 'FM999999990.00')),
        'cuotas',   v_row.cuotas,
        'comercio', v_comercio,
        'cargo',    trim(to_char(v_fee, 'FM999999990.00'))
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Primera carga
-- ---------------------------------------------------------------------------
-- Sin tasa bajo `'BCV'` la app no puede cotizar un pago: `current_fx_rate()`
-- devuelve null y las pantallas de pago se quedan sin el equivalente en
-- bolívares. Por eso se trae ahora y, si la red falla, se avisa a gritos —
-- pero NO se repone ninguna semilla: una tasa inventada aquí sería una tasa
-- con la que se cobra de verdad, y el operador no tendría forma de notar que
-- lo es. Es preferible que la pantalla diga "sin tasa" a que mienta.

do $boot$
declare
  v_result jsonb;
begin
  v_result := public.sync_fx_rate(null, true);

  if not (v_result->>'ok')::boolean then
    raise warning 'No se pudo traer la tasa BCV del euro al migrar (%). CÁRGALA A MANO en Configuración → Tasa BCV antes de operar: hasta entonces no hay cotización en bolívares.',
      v_result;
  else
    raise notice 'Tasa BCV del euro cargada: % Bs./€ (%)',
      v_result->>'rate', v_result->>'effective_date';
  end if;
end
$boot$;
