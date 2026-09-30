-- El 0422 es un prefijo móvil (Digitel) y el teléfono de un pago móvil
-- guardado lo rechazaba: el check solo conocía 412, 414, 416, 424 y 426.
--
-- La lista es la misma que `MOBILE_PREFIXES` (src/features/auth/phone.ts) y
-- `PHONE_PREFIXES` (src/features/payments/api.ts): un prefijo que falte en
-- cualquiera de los tres deja fuera a su operadora entera.

alter table public.user_payment_methods
  drop constraint user_payment_methods_payer_phone_check;

alter table public.user_payment_methods
  add constraint user_payment_methods_payer_phone_check
  check (payer_phone ~ '^0(412|414|416|422|424|426)[0-9]{7}$');
