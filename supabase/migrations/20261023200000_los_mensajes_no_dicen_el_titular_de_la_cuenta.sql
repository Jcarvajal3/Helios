-- ============================================================================
-- Helios — Los mensajes no dicen el titular de la cuenta de cobro (2026-10-23)
--
-- Pedido por Javier el 2026-10-23: «eliminar el nombre del titular de la
-- cuenta en todos los mensajes». Los datos de pago dicen el banco, el
-- teléfono (o la cuenta) y el RIF; ya no «Titular: …».
--
--   · `helios_payment_accounts_block`: el bloque de pago del texto libre (el
--     bot, la bienvenida, los recordatorios con la ventana abierta y el texto
--     plano de los correos), sin la línea «Titular».
--   · `helios_payment_accounts_text`: la línea de cuentas
--     (`{cuentas_de_cobro}`, `{cuentas_de_cobro_html}`: los correos y el
--     comprobante), sin el titular.
--
-- PENDIENTE: las plantillas de Meta de los recordatorios
-- (`helios_cuota_*_v2`, `helios_cuota_vencida`) traen «Titular: {{10}}» en
-- su texto aprobado y Meta no admite una variable vacía. Siguen diciéndolo
-- hasta que se aprueben y conecten las `_v3` sin esa línea (docs/00 §15.9);
-- por eso `pago_movil_titular` sigue en `helios_message_builtins`.
-- ============================================================================

create or replace function public.helios_payment_accounts_block()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    string_agg(
      case d.method
        when 'pago_movil' then concat_ws(E'\n',
          '🏦 *Pago Móvil*',
          'Banco: ' || nullif(btrim(d.bank_name), ''),
          'Teléfono: ' || coalesce(public.helios_format_ve_phone(d.phone), d.phone),
          'RIF: ' || public.helios_rif_text(nullif(btrim(d.rif), '')))
        when 'transferencia' then concat_ws(E'\n',
          '🏦 *Transferencia*',
          'Banco: ' || nullif(btrim(d.bank_name), ''),
          'Cuenta: ' || nullif(btrim(d.account_number), ''),
          'RIF: ' || public.helios_rif_text(nullif(btrim(d.rif), '')))
      end,
      E'\n\n' order by d.sort_order, d.created_at),
    'Te escribiremos por aquí con los datos para pagar.')
  from public.payment_destinations d
  where d.is_active and d.method in ('pago_movil', 'transferencia');
$$;

create or replace function public.helios_payment_accounts_text()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    string_agg(
      case d.method
        when 'pago_movil' then
          format('• Pago Móvil: %s · %s · %s', d.bank_name, d.rif,
                 coalesce(public.helios_format_ve_phone(d.phone), d.phone))
        when 'transferencia' then
          format('• Transferencia: %s · Cuenta %s · %s', d.bank_name, d.account_number, d.rif)
      end,
      E'\n' order by d.sort_order, d.created_at),
    'Helios te escribirá por WhatsApp con las instrucciones de pago.')
  from public.payment_destinations d
  where d.is_active and d.method in ('pago_movil', 'transferencia');
$$;
