-- ============================================================================
-- Helios — El bot se calla 8 horas, no 24 (Javier, 2026-10-22)
--
-- Cuando una persona atiende un chat (Hablar con alguien, un comprobante que
-- revisa el equipo, alguien sin pagos en cuotas), el bot del paciente se
-- callaba 24 h. Era excesivo: pasa a 8 h. En la Edge Function es
-- `HORAS_DE_PERSONA` (paciente.ts); aquí, el cierre de una lectura del lector
-- de comprobantes que va al equipo (`helios_receipt_close`, de
-- 20261021200000, idéntica salvo las horas).
--
-- Los chats que ya estaban callados siguen hasta su hora: no se toca
-- `human_until`.
-- ============================================================================

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
    perform public.bot_paciente_guardar(v_r.phone_e164, null, 8, '', null);
  end if;

  return p_status;
end;
$$;

revoke all on function public.helios_receipt_close(uuid, text, text, text) from public, anon, authenticated;

comment on column public.whatsapp_contacts.human_until is
  'Hasta cuándo el bot del paciente se calla con ese número: lo atiende una persona (Ayuda, un comprobante, alguien sin pagos en cuotas). 8 h desde el 2026-10-22 (antes 24 h).';
