-- ============================================================================
-- Helios — Aviso por correo: una inicial espera su aprobación (2026-11-17)
--
-- Cuando una orden pasa a `awaiting_down_payment` (el paciente dijo «Sí» y
-- queda debiendo la inicial del 50%), se manda un correo interno a quienes
-- estén en `internal_alert_recipients` (tema `inicial_pendiente`): la orden, el
-- médico, el monto de la inicial y hasta cuándo la tiene el paciente.
--
--  · Sale por la cola de correo de siempre (`outbound_messages` →
--    `helios_dispatch_email_batch`, cada minuto, con Resend).
--  · Sin datos del paciente: ni nombre, ni cédula, ni teléfono.
--  · El trigger es DIFERIDO (corre al confirmar la transacción): así la cuota
--    0 ya existe cuando se lee su monto. Y NUNCA hace fallar la orden: si el
--    aviso falla, queda un warning y la orden sigue su curso.
--  · Una orden avisa una sola vez por destinatario (`dedupe_key`).
--  · Se apaga con `notification_templates.enabled = false` en la plantilla
--    `alerta_inicial_pendiente`, o quitando a alguien de la tabla.
-- ============================================================================

-- 1. A quién ─────────────────────────────────────────────────────────────────

create table if not exists public.internal_alert_recipients (
  topic      text not null,
  email      text not null check (email = lower(btrim(email)) and position('@' in email) > 1),
  created_at timestamptz not null default now(),
  primary key (topic, email)
);

comment on table public.internal_alert_recipients is
  'Correos internos que reciben un aviso por tema (p. ej. inicial_pendiente). Solo lo leen las funciones de la base.';

alter table public.internal_alert_recipients enable row level security;
revoke all on public.internal_alert_recipients from public, anon, authenticated;

insert into public.internal_alert_recipients (topic, email) values
  ('inicial_pendiente', 'lis@quartorent.com'),
  ('inicial_pendiente', 'lisblanco97@gmail.com')
on conflict do nothing;

-- 2. La plantilla (la cola exige una; el texto lo arma la función) ──────────

insert into public.notification_templates (
  key, label, trigger_label, help, variables, required_variables,
  default_title, default_body, enabled, editable, can_disable, sort_order, channels
) values (
  'alerta_inicial_pendiente',
  'Aviso interno: inicial pendiente de aprobación',
  'Cuando una orden queda esperando su inicial (el «Sí» del paciente)',
  'Correo interno al equipo (internal_alert_recipients, tema inicial_pendiente). Sin datos del paciente. El texto lo arma la base; aquí solo se puede apagar.',
  array['orden', 'medico', 'inicial', 'plazo'],
  array['orden', 'medico', 'inicial', 'plazo'],
  'Inicial pendiente de aprobación · Orden #{orden}',
  'La orden #{orden} con {medico} espera su inicial de {inicial}. El paciente tiene hasta el {plazo}.',
  true, false, true, 17, array['email']
)
on conflict (key) do nothing;

-- 3. El aviso ────────────────────────────────────────────────────────────────

create or replace function public.helios_alert_inicial_pendiente(p_charge_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c       public.charges%rowtype;
  v_on      boolean;
  v_medico  text;
  v_inicial text;
  v_plazo   text;
  v_subject text;
  v_text    text;
  v_html    text;
  v_url     text;
  v_to      text;
  v_n       integer := 0;
  v_id      uuid;
begin
  select * into v_c from public.charges where id = p_charge_id;
  if not found or v_c.status <> 'awaiting_down_payment' then
    return 0;
  end if;

  select enabled into v_on from public.notification_templates where key = 'alerta_inicial_pendiente';
  if not coalesce(v_on, false) then
    return 0;
  end if;

  v_medico := coalesce(public.helios_doctor_ref(v_c.merchant_id), 'el médico');

  select public.helios_money_cur_text(i.amount_cur, v_c.currency) into v_inicial
  from public.installments i where i.charge_id = v_c.id and i.sequence = 0;

  v_plazo := case when v_c.down_payment_due_at is not null
                  then to_char(v_c.down_payment_due_at at time zone 'America/Caracas', 'DD/MM/YYYY "a las" HH24:MI')
             end;

  v_subject := format('Inicial pendiente de aprobación · Orden #%s', v_c.order_number);
  v_url     := 'https://conhelios.com/admin/financiamientos/' || v_c.id::text;

  v_text := format(E'Una inicial está esperando su aprobación.\n\nOrden: #%s\nMédico: %s\nInicial: %s\nPlazo del paciente: %s\n\nSi no se aprueba a tiempo, la orden se anula sola.\nVer la orden: %s\n',
                   v_c.order_number, v_medico, coalesce(v_inicial, 'ver la orden'),
                   coalesce(v_plazo || ' (hora de Caracas)', 'ver la orden'), v_url);

  v_html := format('<div style="font-family:Arial,sans-serif;font-size:15px;color:#0a1428;max-width:480px">'
                   '<p style="font-size:17px;margin:0 0 12px"><b>Una inicial está esperando su aprobación</b></p>'
                   '<table style="border-collapse:collapse;font-size:15px">'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Orden</td><td><b>#%s</b></td></tr>'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Médico</td><td>%s</td></tr>'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Inicial</td><td><b>%s</b></td></tr>'
                   '<tr><td style="padding:3px 14px 3px 0;color:#5b6478">Plazo del paciente</td><td>%s</td></tr>'
                   '</table>'
                   '<p style="color:#5b6478">Si no se aprueba a tiempo, la orden se anula sola.</p>'
                   '<p><a href="%s" style="color:#1a6dff">Ver la orden</a></p></div>',
                   v_c.order_number, v_medico, coalesce(v_inicial, 'ver la orden'),
                   coalesce(v_plazo || ' (hora de Caracas)', 'ver la orden'), v_url);

  for v_to in
    select r.email from public.internal_alert_recipients r
    where r.topic = 'inicial_pendiente' and public.helios_valid_email(r.email)
    order by r.email
  loop
    insert into public.outbound_messages (
      channel, template_key, profile_id, charge_id, recipient, subject,
      rendered_text, html, status, next_attempt_at, dedupe_key
    ) values (
      'email', 'alerta_inicial_pendiente', v_c.user_id, v_c.id, v_to, v_subject,
      v_text, v_html, 'pendiente', now(),
      'alerta_inicial_pendiente:' || v_c.id::text || ':' || v_to
    )
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    if v_id is not null then
      v_n := v_n + 1;
    end if;
    v_id := null;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.helios_alert_inicial_pendiente(uuid) from public, anon, authenticated;

-- 4. El disparador ───────────────────────────────────────────────────────────
-- Diferido: al confirmar la transacción, con la cuota 0 ya creada. Nunca
-- tumba la orden.

create or replace function public.helios_alert_inicial_pendiente_trg()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' or old.status is distinct from new.status then
    begin
      perform public.helios_alert_inicial_pendiente(new.id);
    exception when others then
      raise warning 'helios_alert_inicial_pendiente (orden %): %', new.id, sqlerrm;
    end;
  end if;
  return null;
end;
$$;

revoke all on function public.helios_alert_inicial_pendiente_trg() from public, anon, authenticated;

drop trigger if exists charges_alert_inicial_pendiente on public.charges;
create constraint trigger charges_alert_inicial_pendiente
  after insert or update of status on public.charges
  deferrable initially deferred
  for each row
  when (new.status = 'awaiting_down_payment')
  execute function public.helios_alert_inicial_pendiente_trg();
