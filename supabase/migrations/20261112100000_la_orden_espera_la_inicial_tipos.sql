-- ============================================================================
-- Helios — La orden espera la inicial: el estado nuevo (Javier, 2026-11-12;
-- docs/07-INICIAL-DEL-50.md)
--
-- Toda orden nueva se paga con una inicial del 50% del total el mismo día y
-- el resto en 2 cuotas. Tras el «Sí» (y la cédula) la orden ya tiene su
-- asiento y su deuda, pero no queda activa hasta que se aprueba la inicial:
-- mientras tanto está en `awaiting_down_payment` («Esperando la inicial»).
--
-- Solo el valor del enum, en su propia migración: `alter type … add value`
-- no puede usarse en el mismo fichero que lo añade. Añadirlo no cambia nada
-- (ninguna orden lo usa hasta el lanzamiento, que vive en
-- `supabase/por-lanzar/`).
-- ============================================================================

alter type public.charge_status add value if not exists 'awaiting_down_payment';
