-- ============================================================================
-- Helios — El plazo para pagar la inicial pasa de 2 a 3 horas (2026-11-24)
--
-- `down_payment_minutes` = 180. El plazo corre desde el «Sí» del paciente
-- (`charges.down_payment_due_at` = «Sí» + este parámetro) y, pasado sin un pago
-- abierto, la orden se anula sola. Hoy fue el caso de una orden que venció a
-- las 17:32 y cuyo comprobante llegó a las 17:33.
--
--  · Solo cambia para las órdenes que acepten desde ahora: las que ya esperan
--    su inicial conservan su `down_payment_due_at`.
--  · No cambia el plazo para responder el «Sí» (`patient_confirmation_minutes`,
--    2 horas).
--  · El panel y el bot del médico leen el plazo de la base y dirán «3 horas»
--    solos. El mensaje al paciente usa la variable `plazo_inicial`, también de
--    la base. LO QUE SIGUE DICIENDO «2 horas» porque va escrito: la plantilla de
--    Meta v3, el texto libre `confirmar_pago_con_inicial` y las Condiciones v4.
--    Hay que mandar otra plantilla y publicar otra versión de las condiciones
--    para que digan 3 (docs/00 §15.5.2).
--
-- Un parámetro no se actualiza: se inserta otra fila con otra fecha de
-- vigencia. Se puede volver atrás desde Ajustes › Parámetros.
-- ============================================================================

insert into public.business_parameters (key, value, effective_from, note)
values ('down_payment_minutes', 180, public.helios_business_date(now()),
        '2026-11-24: 3 horas para pagar la inicial (antes 2 h)')
on conflict (key, effective_from) do update
   set value = excluded.value,
       note  = excluded.note;
