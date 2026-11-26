# Reglas del negocio, con su historia

El detalle y las fechas de las reglas que `CLAUDE.md` resume. `CLAUDE.md`
dice **qué** se cumple siempre; aquí está **por qué**, desde cuándo y quién lo
decidió. Si una regla cambia, se actualizan los dos: la regla en `CLAUDE.md` y
la historia aquí.

## El paciente

- **Inicial del 50% del total el día del Sí y 2 cuotas a los 14 y 28 días**
  (docs/07, Javier 2026-11-12). Rige desde el lanzamiento, que espera la
  plantilla v3 de Meta: hasta entonces, 2 cuotas sin inicial.
  - La inicial es la cuota `sequence = 0`. La orden queda en
    `awaiting_down_payment` hasta que se aprueba (igual que una cuota) y se
    anula sola a las 3 h sin pago.
  - Se decide por orden (`charges.down_payment_pct`): las viejas conservan
    sus condiciones.
  - `/consultas` (prueba A/B) no se toca: sigue diciendo «$15 de inicial».
- **Comisión Helios del 12% + IVA 16%** sobre la comisión
  (`consumer_fee_pct`, `vat_pct`). Ejemplo: consulta de $100 → $12 + $1,92 →
  total $113,92 → inicial $56,96 + 2 cuotas de $28,48.
- **Límite inicial de $150** (nivel 1). Los demás niveles están apagados, así
  que hacia fuera nunca se dice que el límite «crece».
- **La frase de los niveles** (excepción aprobada por Javier):
  - 2026-10-19: todo bloque de pago al paciente termina con «⭐ Recuerda
    pagar a tiempo para subir de nivel y disponer de mayores beneficios.»
    (`helios_level_reminder()` en la base, `FRASE_NIVEL` en el bot).
  - 2026-10-22: «Mi saldo y cuotas» enseña el nivel y el saldo total y
    cierra con «⭐ Si pagas a tiempo, puedes subir de nivel y aumentar tu
    saldo máximo.» (`FRASE_SUBIR_DE_NIVEL`).
  - 2026-10-23: la misma frase en el aviso de pago confirmado por WhatsApp y
    por correo (`helios_level_up_phrase()`).
  - Lo de los niveles se resuelve después.
- **Solo paga en bolívares** (Pago Móvil o transferencia; nada de Zelle,
  USDT ni efectivo).
- **Sin cargos por mora** (2026-10-07): `late_fee_usd` = 0. El motor sigue
  en el código; para retomarlo basta poner el monto en el parámetro (los
  textos del cargo dependen de él) y reescribir el párrafo de
  `/legal/terminos`.

## El médico o centro

- Recibe el **100%** de la consulta en dos mitades, **a los 8 y 15 días**
  desde la orden, **pague o no el paciente** sus cuotas (desde que la orden
  queda activa; la inicial no le genera pago).
- Su fecha no sale de la cuota: `installments.settlement_due_date` (orden +
  `helios_settlement_interval_days()` × secuencia) y el pago al día
  siguiente (`helios_settlement_run_for(d) = d + 1`). Se paga a diario, ya no
  los lunes.
- `installment_interval_days` mueve solo las cuotas del paciente.
- No le cuesta nada y no hay permanencia (cancela con aviso previo).
- Especialidades: medicina, odontología y cosmetología.

## La moneda de la consulta (2026-10-07)

El médico elige **dólares o euros** en el paso del monto (panel y bot). Una
orden en euros **queda en euros**: el paciente paga cada cuota en bolívares a
la tasa BCV del euro del día en que paga, y a la clínica se le paga en Bs a la
tasa del euro. Detalle en docs/01 §7.

## Lo que ve cada uno

- **A la clínica, ningún total incluye la Comisión Helios.** La comisión
  aparece solo dentro de las cuotas o como línea aparte en un desglose. En
  todo desglose que ve el médico (panel y bot) va seguida de **«(Lo paga el
  paciente)»** (Javier, 2026-10-13; `LO_PAGA_EL_PACIENTE`).
- **Al paciente sí** se le enseña el total con la comisión (Javier,
  2026-10-06: es lo que paga).
- **Al paciente se le nombra a su médico, no a la clínica** («de la consulta
  con la Dra. Nadia Andi Khabbaze Alfaro»): `helios_doctor_ref`, con el
  nombre del titular (`owner_name`) y su título (`merchants.doctor_title`).
- **Los bolívares van solo en el bloque de pago** (`helios_payment_block`),
  junto a las cuentas, como el equivalente de hoy (2026-10-19, docs/00
  §15.8).

## Nombres y vocabulario

- **La clínica se llama como su médico titular** (Javier, 2026-10-29):
  `merchants.name` lo arma un trigger («Dra. Ana Lara», sin «Consultorio»
  delante) y el nombre del consultorio va en `merchants.consultorio`, como un
  dato secundario junto a la dirección. Lo que se escriba en `name` pasa a
  `consultorio`. En tablas y filtros, el médico va primero.
- **Comisión Helios** desde el 2026-10-13. Los mensajes al paciente (la
  pregunta de WhatsApp, su plantilla de Meta y el comprobante) siguen
  diciendo «comisión de servicio».

## Helios Lab (2026-11-26)

- **Decisión de Javier, 2026-11-26.** Vertical de muestras y exámenes de
  laboratorio (docs/09): el médico toma la muestra, el paciente paga **en
  bolívares por Pago Móvil** a la cuenta de Helios a la tasa BCV del día del
  registro, un driver la lleva al laboratorio y Helios reenvía el resultado.
  No es pago en cuotas: no toca `charges`, `installments`, `settlements` ni el
  libro contable.
- **Precio** en dólares = base del laboratorio + **Cargo Helios** (hoy $15 por
  examen, `lab_ajustes.cargo_helios_usd`, editable por el superadmin y copiado
  a cada muestra) + la comisión del médico (por examen, la fija él).
- **Excepción a «a la clínica, ningún total incluye la Comisión Helios»**: en
  Lab el médico ve el precio final al paciente, porque es quien se lo dice. Se
  llama «Cargo Helios», nunca «Comisión Helios» ni «fee».
- **Interruptor** `lab_ajustes.modo`: `apagado` (nace así), `prueba` (solo
  clínicas con `merchants.is_test`) o `todos`.
- **Pagos al médico y al laboratorio**: solo se registran (la plataforma dice
  cuánto se debe y el equipo marca «pagado» con su referencia). Sin libro en
  la v1.
- **Rol interno `driver`**: solo ve la ruta del día y marca paradas.
- El resultado se reenvía a mano (correo o WhatsApp); la plataforma solo
  registra la entrega y el canal.

## Proyecto Supabase y entornos

- Sin Docker (decisión del usuario, 2026-09-30).
- El proyecto `Helios` (`ahyfbnfsbyzdoyjzjvfb`) es **producción** desde el
  2026-10-08 (decisión de Javier) y sigue siendo el único: el de desarrollo
  llegará más adelante.
