# Helios — Contrato de las RPC nuevas

> Fuente de verdad entre la base (fase 1) y el panel (fases 2 y 3), para que
> se construyan en paralelo. Si una firma cambia, **se cambia aquí primero**.
>
> Las RPC heredadas de Ronda (`merchant_*`, `admin_*`) conservan su nombre y
> su forma. Solo cambia el prefijo `ronda_` → `helios_`. Este documento cubre
> lo **nuevo** y lo que **cambia de forma**.

## Convenciones (las de Ronda)

- Todas son `security definer`, `set search_path = public, ledger, audit, pg_temp`,
  y tienen `grant execute … to authenticated`. La autorización va dentro de la
  función.
- Los errores se lanzan con **texto en español para mostrar tal cual** y un
  `errcode`. El panel los enseña con `describeError`.

  | errcode | Significado |
  |---|---|
  | `28000` | No autenticado |
  | `42501` | Sin permiso: no es personal de esa clínica, no es admin, o le falta MFA |
  | `22023` | Dato inválido o regla de negocio |
  | `P0002` | No encontrado |
  | `55000` | Estado que no lo permite (mantenimiento, clínica pausada) |

- Dinero en USD como `numeric` y fechas como `date` (`YYYY-MM-DD`, día de
  Caracas). Los timestamps son `timestamptz`.
- Las respuestas `jsonb` usan **claves en snake_case en inglés** cuando son
  columnas del dominio (`amount_usd`, `due_date`), igual que en Ronda.
- **Nunca** se devuelve a la clínica un total que sume el fee: se devuelve el
  desglose y las cuotas.

---

## 1. Panel de la clínica

### 1.1 `helios_patient_eligibility(p_merchant_id uuid, p_document text) → jsonb`

Paso 1 de "Nuevo financiamiento". Puede llamarla el personal activo de la
clínica (`gerente` o `cajero`).

- `p_document`: `"V12345678"` o `"E12345678"`. Si viene `"12345678"` se toma
  como V. Se normaliza con `normalize_document`.
- Límite: `eligibility_lookups_per_staff_day` (60) por usuario y día operativo.
  Pasado el límite lanza `22023` "Llegaste al límite de consultas de hoy.
  Inténtalo mañana." (implementado en 20261003000400).
- Cada llamada que responde queda en `eligibility_lookups` (`result` =
  `nuevo` | `disponible` | `no_disponible`, `document_key` normalizada). La
  rechazada por el límite **no** queda anotada (el error deshace la
  transacción): la alerta `consultas_de_cedula_excesivas` se dispara cuando
  alguien **llega** al límite (`count >= helios_eligibility_lookups_per_staff_day()`).
- Otros errores: `22023` "Cédula inválida" (lo que no sea V/E + 6-9 dígitos);
  `42501` "No tienes permiso para consultar en esta clínica".
- `disponible` exige además que el disponible sea ≥ `min_charge_usd`; si no, es
  `no_disponible` (cupo agotado, sin decirlo). **(2026-10-05)** El disponible
  descuenta también las **órdenes pendientes vigentes** del paciente
  (`helios_credit_reserved_usd`, §5.1 del plan). `no_disponible` trae siempre
  exactamente esas tres claves y el mismo texto, sea cual sea el motivo. Sin
  WhatsApp configurado: "Esta persona no puede pagar en cuotas con Helios. Si
  tiene dudas, puede escribir a Helios." (hasta el 2026-10-05, "No podemos
  financiar a esta persona…") y `whatsapp_helios` null. El error de cupo de
  `create_patient_charge` es exactamente "El monto supera lo disponible ($X)."

```jsonc
// Paciente nuevo
{ "estado": "nuevo", "min_charge_usd": 10, "limite_usd": 150 }

// Paciente conocido, puede financiar
{ "estado": "disponible",
  "disponible_usd": 212.40,
  "min_charge_usd": 10,
  "nombre": "José Pérez",             // (2026-10-21) completos: la secretaria
  "telefono": "0414-1234567",         // se los lee al paciente para confirmar
  "email": "jose@gmail.com",          // que es él. Null si no los tiene.
  // Obsoletas: siguen mientras el panel y el bot desplegados las lean.
  "nombre_enmascarado": "J*** P***",
  "telefono_enmascarado": "0414-***-**67",
  "email_enmascarado": "j***@gmail.com" }

// No puede financiar. NUNCA dice por qué (mora, lista negra, bloqueo, cupo…)
{ "estado": "no_disponible",
  "mensaje": "No podemos financiar a esta persona. Puede escribir a Helios al 0414-…",
  "whatsapp_helios": "+58414…"   // null si aún no está configurado
}
```

Si la plataforma está en **mantenimiento** o la clínica **no está activa**,
lanza `55000` con el texto de `helios_spend_block` ("La clínica está pausada"
/ "La clínica ya no opera con Helios" si está terminada).

### 1.2 `preview_patient_charge(p_merchant_id uuid, p_document text, p_amount numeric, p_currency text default 'USD') → jsonb` (desde el 2026-10-07, ver §7)

Vista previa sin efectos. Valida el monto (≥ `min_charge_usd`, ≤ 2 decimales)
y, si el paciente existe, que quepa en su disponible.

- Anti-enumeración: si viene `p_document`, quien llama tiene que haber
  consultado esa cédula en esa clínica (`helios_patient_eligibility`) en las
  últimas 24 h; si no, `22023` "Primero consulta la cédula del paciente".
  `p_document` null = paciente nuevo.
- Un conocido que no puede financiar devuelve `disponible_usd` 0 y `cabe`
  false (nunca el motivo). Un nuevo trae además `limite_usd`.

```jsonc
{
  "base_usd": 100.00,               // lo que vale la consulta (lo que cobra la clínica)
  "consumer_fee_pct": 20,
  "consumer_fee_usd": 20.00,
  "consumer_fee_vat_usd": 3.20,
  "business_date": "2026-10-01",
  "installments": [
    { "sequence": 1, "due_date": "2026-10-08", "amount_usd": 61.60, "financed_usd": 50.00 },
    { "sequence": 2, "due_date": "2026-10-15", "amount_usd": 61.60, "financed_usd": 50.00 }
  ],
  "late_fee_usd": 2, "late_fee_grace_days": 3,
  "cabe": true,                     // false si no cabe en el disponible del paciente conocido
  "disponible_usd": 212.40          // null si es nuevo (usa limite_usd)
}
```

Regla de presentación: la clínica muestra `base_usd` y las dos cuotas. La
comisión de servicio va solo como línea del desglose ("Comisión de servicio
12% + IVA", leyendo `consumer_fee_pct`).

### 1.3 `create_patient_charge(...) → jsonb`

```sql
create_patient_charge(
  p_merchant_id      uuid,
  p_branch_id        uuid,        -- null = sede por defecto (gerente); cajero: la suya
  p_patient          jsonb,       -- ver abajo
  p_amount_usd       numeric,     -- monto de la consulta, sin fee
  p_concept          text,        -- opcional, ≤ 80 caracteres, p. ej. "Consulta"
  p_beneficiary_name text,        -- opcional: quién se atendió, si no es el titular
  p_idempotency_key  text         -- uuid generado al abrir el formulario, estable
)
```

`p_patient`. Si el paciente ya existe (por cédula) **solo se usa `document`**:
el resto se compara, y si difiere se crea una `profile_change_requests`, sin
sobrescribir nada.

```jsonc
{
  "document": "V12345678",
  "first_name": "José", "last_name": "Pérez",
  "birth_date": "1990-04-12",          // ≥ 18 años → si no: 22023 "El titular debe ser mayor de edad…"
  "sex": "M",                          // "F" | "M"
  "phone": "04141234567",              // móvil VE: 0412/0414/0416/0422/0424/0426 → se guarda E.164
  "email": "jose@gmail.com",
  "state": "Miranda", "city": "Caracas", "address": "Los Palos Grandes, …",
  "occupation": null                   // opcional
}
```

Implementado en 20261003000400 (+ 000500). Precisiones:

- Sede: el `gerente` registra en cualquier sede activa de su clínica (null =
  la principal); el `cajero`, solo en la suya (null = la suya; otra → `42501`
  "No tienes permiso para registrar en esa sede"). Una sede de otra clínica o
  inactiva → `22023`.
- Igual que la vista previa, exige haber consultado la cédula en las últimas
  24 h ("Primero consulta la cédula del paciente").
- **Sin contacto de referencia** desde 20261013000100 (Javier, 2026-10-13):
  `reference_name`, `reference_phone` y `reference_relationship` son
  opcionales y ni el panel ni el bot los piden. Si llegan, `reference_phone`
  acepta móvil **o fijo** venezolano (02XX…), se guarda en E.164 y no puede
  ser el teléfono del paciente. `sex` admite minúsculas.
- `p_concept` vacío → se guarda "Consulta" (es también el nombre de la única
  línea de `charge_items`).
- La misma clave usada en otra clínica → `22023`.
- Al crear: comprobante (correo) + `bienvenida` (WhatsApp manual) encolados,
  comisión devengada, bitácora `charge.created`.

Respuesta: `helios_charge_for_staff(id)` (también se puede llamar sola: el
gerente ve los de su clínica, la secretaria los suyos, el equipo todos; si no,
`P0002`). Además de lo de abajo trae `confirmed_at`, `merchant_id`,
`merchant_name`, `branch_id`, `branch_name`, `breakdown.consumer_fee_pct` y
`receipt.{sent_at, last_event, email_enmascarado}`. `receipt.status` añade
`fallido` (el despacho se rindió o se canceló); `rebotado` cubre también «el
paciente no tiene correo» o «su correo ya había rebotado». `registered_by` es
"Nombre (Secretaria)" o "Nombre (Administrador)". `staff_commission_usd` es
null si no hubo comisión.

```jsonc
{
  "id": "uuid", "order_number": 1042, "status": "confirmed",
  "created_at": "…", "business_date": "2026-10-01",
  "merchant_sale_usd": 100.00,         // base: lo que se le paga a la clínica
  "concept": "Consulta", "beneficiary_name": null,
  "patient": { "nombre": "José Pérez", "documento_enmascarado": "V-****5678", "email_enmascarado": "j***@gmail.com" },
  "installments": [ { "sequence": 1, "due_date": "…", "amount_usd": 61.60 }, { "sequence": 2, … } ],
  "breakdown": { "base_usd": 100, "consumer_fee_usd": 20, "consumer_fee_vat_usd": 3.20 },
  "receipt": { "status": "pendiente" }, // pendiente | enviado | entregado | rebotado | sin_configurar
  "registered_by": "Ana (Secretaria)",
  "staff_commission_usd": 0.50
}
```

Errores típicos (`22023` salvo que se indique):

| Mensaje | Cuándo |
|---|---|
| "No podemos financiar a esta persona…" | Paciente con mora, bloqueo, lista negra o expulsado. Mismo texto neutro que la elegibilidad |
| "El monto supera lo disponible para financiar ($X)" | No cabe en el cupo |
| "El monto mínimo es $10" | Por debajo de `min_charge_usd` |
| "El titular debe ser mayor de edad. Si el paciente es menor, registra a su representante" | Menor de 18 |
| "Teléfono móvil inválido" / "Correo inválido" | Datos del paciente |
| `42501` "No tienes permiso para registrar en esta clínica" | Sin permiso |
| `55000` texto de mantenimiento / "La clínica está pausada" | Plataforma o clínica sin poder operar |

Idempotente: la misma `p_idempotency_key` devuelve el mismo financiamiento.

#### 1.3.1 Con la confirmación del paciente (2026-10-05)

Implementado en 20261005000200 (los estados `declined` y `expired`) y
20261005000300. Precisiones de la implementación:

- La reserva de cupo vive en `helios_credit_used_usd`, que ahora suma
  `helios_credit_reserved_usd` (la consulta de las órdenes `pending` con
  `expires_at > now()`). Así la elegibilidad, la vista previa, el alta,
  `available_usd` y `helios_assign_debt` la respetan sin cambios.
- La respuesta añade también `channel` (`panel` | `whatsapp`),
  `decline_reason` (`paciente` | `no_disponible` | null) y `decline_message`
  (el texto para mostrar: «El paciente rechazó el financiamiento» o el texto
  neutro de «no disponible»).
- `charges.channel` sale de la variable de sesión `helios.canal` (la pone el
  bot); por defecto `panel`.
- Lo que creaba la deuda vive ahora en `helios_finalize_charge` (interna) y lo
  usan los dos caminos: el interruptor en 0 y el «Sí».

Con `patient_confirmation_required = 1` (el parámetro arranca en 0 y entonces
todo sigue como arriba). La firma **no cambia**. Lo que cambia:

- Crea la orden en **`status = 'pending'`** con `expires_at` (+120 min) y
  encola la plantilla `confirmar_financiamiento` (canal `whatsapp`). **No**
  crea deuda, comisión, comprobante ni bienvenida: eso pasa con el "Sí" del
  paciente (`helios_patient_decision`, §5).
- El paciente nuevo **sí** se crea aquí. Al conocido se le escribe a su
  teléfono **registrado**.
- La respuesta (`helios_charge_for_staff`) trae `status` = `pending` y añade:

  ```jsonc
  "expires_at": "2026-10-05T16:40:00-04:00",
  "confirmation": {
    "status": "enviada",            // por_enviar | enviada | entregada | leida | fallida | aceptada | rechazada | vencida
    "telefono_enmascarado": "0414-***-**67",
    "sent_at": "…", "answered_at": null,
    "resends_today": 0
  }
  ```
  `installments` ya viene con las fechas y montos que vio el paciente;
  `receipt.status` es `sin_enviar` hasta que acepte.
- Errores nuevos (`22023`):

  | Mensaje | Cuándo |
  |---|---|
  | "Este paciente tiene otra solicitud esperando su respuesta. Inténtalo cuando la responda o venza" | Ya tiene una orden `pending` vigente (en cualquier clínica; no se dice cuál) |
  | "No podemos escribirle a este paciente por WhatsApp. Escribe a Helios" | La API de WhatsApp no está configurada (con el interruptor en 1) |

- **Estados de `charges.status`:** `pending` (esperando al paciente),
  `confirmed`, `declined` (dijo No, o la revalidación al aceptar falló),
  `expired` (venció sin respuesta), `voided`, `reverted`. Se añaden al enum
  `declined` y `expired`.
- `helios_charge_for_staff(id)` se puede llamar sola para refrescar la
  pantalla "Esperando al paciente" (el panel la consulta cada pocos segundos
  mientras esté `pending`).

#### 1.3.2 `staff_resend_confirmation(p_charge_id uuid) → jsonb` (2026-10-05)

Reenvía al paciente la plantilla de confirmación. Mismos permisos que
`staff_resend_receipt` (el gerente, cualquiera de su clínica; la secretaria,
las que registró; si no, `P0002`).

- Orden **`pending`**: solo reenvía el mensaje, **sin** alargar el plazo.
- Orden **`expired`**: revalida elegibilidad y cupo (con el mismo texto neutro
  si ya no se puede), recalcula `business_date` y las fechas de las cuotas,
  pone `expires_at` = ahora + 120 min y vuelve a `pending`.
- Otro estado → `22023` "Este financiamiento ya no se puede reenviar".
- Límite `confirmation_resends_per_day` (3) por orden y día: `22023` "Ya
  reenviaste esta solicitud 3 veces hoy".
- Devuelve `helios_charge_for_staff(id)`. Bitácora `charge.confirmation_resent`.

### 1.4 `staff_resend_receipt(p_charge_id uuid) → jsonb`

Solo personal de esa clínica, 3 veces al día por financiamiento. Encola otro
`comprobante_financiamiento` al correo **registrado** del paciente.

```jsonc
{ "ok": true, "email_enmascarado": "j***@gmail.com", "status": "pendiente" }
```

El gerente reenvía cualquiera de su clínica; la secretaria, los que registró
(si no, `P0002`). Pasado el límite: `22023` "Ya reenviaste este comprobante 3
veces hoy. Inténtalo mañana" (cuentan los reenvíos del día, no el original).
Queda en la bitácora (`charge.receipt_resent`).

### 1.5 Cambian de forma (heredadas)

Implementado en 20261003000500 y 000600.

- `merchant_transactions(p_from date, p_to date, p_limit int default 500)`:
  cada fila añade `concept`, `beneficiary_name`, `receipt_status`,
  `staff_commission_usd` y `registered_by_name`. `merchant_sale_usd` sigue
  siendo la base sin fee. Desaparece `payer_count` (era de grupos).
  **(2026-10-05)** Añade `status` y `expires_at`: el historial muestra también
  las órdenes pendientes, rechazadas y vencidas. Los totales del día, las
  métricas, las comisiones y la exportación cuentan **solo** las confirmadas.
- `merchant_charge_detail(p_charge_id uuid)`: añade `concept`,
  `beneficiary_name`, `receipt` (`{status, sent_at, last_event, email_enmascarado}`),
  `staff_commission_usd`, `commission_staff_name` e `installments`
  (`[{sequence, due_date, run_date, paid_to_merchant_on}]`; **(2026-10-06)**
  `run_date` = `due_date` + 1, los días 8 y 15 de la consulta: **no** incluye el
  estado de pago ni el monto de las cuotas del paciente). `payouts` añade
  `kind` = `staff_commission` (su monto lo ve también la secretaria).
- `merchant_settlement_outlook()` añade `next_run_consultas_usd`,
  `next_run_comisiones_usd`, `consultas_usd` y `comisiones_usd` (lo devengado
  y sin transferir, partido), `last_payout_on`, `last_payout_usd`.
- Las transferencias recibidas se siguen leyendo de las tablas (RLS del
  gerente): `merchant_payouts` gana las columnas `consultas_usd` y
  `comisiones_usd`; cada `merchant_payout_items` → `settlements.reason` ∈
  {`advance`, `scheduled_installment`, `staff_commission`}.
- `merchant_sales_by_staff(p_from, p_to)`: se mantiene y añade
  `commission_usd`.
- `merchant_sales_export` / `merchant_sales_export_items`: las columnas
  `*_eur` pasan a `*_usd` (`base_usd`, `vat_usd`, `sale_usd`,
  `consumer_fee_usd`, `consumer_fee_vat_usd`, `charged_to_customer_usd`,
  `merchant_fee_usd`, `merchant_fee_vat_usd`, `net_to_merchant_usd`,
  `settled_usd`, `paid_usd`; `unit_price_usd`, `line_total_usd`), y el export
  añade al final `concept`, `beneficiary_name`, `staff_commission_usd`.
  `settled_usd`/`paid_usd` no cuentan la comisión.

### 1.6 Comisiones (nuevas)

`merchant_commissions(p_from date, p_to date) → table`

| columna | tipo | nota |
|---|---|---|
| staff_user_id | uuid | |
| staff_name | text | |
| charge_count | int | financiamientos confirmados en el rango |
| amount_usd | numeric | devengado |
| paid_usd | numeric | ya incluido en una transferencia a la clínica |
| pending_usd | numeric | por pagar (se paga el día siguiente a su devengo; hasta el 2026-10-05, el lunes siguiente) |

El `gerente` ve todas; el `cajero`, solo su fila.

`merchant_commission_items(p_from date, p_to date, p_staff_user_id uuid default null) → table`:
`charge_id, order_number, created_at, amount_usd, status ('devengada'|'pagada'|'revertida'), payout_id, paid_on, staff_user_id, staff_name, business_date, confirmed_at, pay_date`.

Implementado en 20261003000500. El rango es el día operativo del
financiamiento. `merchant_commissions` no cuenta las revertidas; `paid_usd`
cuenta también lo pagado en transferencias parciales. Una comisión pasa a
`pagada` cuando su liquidación queda pagada entera. `paid_on` solo viene si
está `pagada`. `pay_date` (20261021190000) es el día del pago que la lleva:
la comisión vence con la primera cuota y sale sumada a la primera mitad de la
consulta (día 8 de la orden); `null` si está revertida.

---

## 2. Superadmin

Todas exigen `is_platform_admin()`. Las que escriben exigen además
`helios_assert_super_admin()`, salvo donde se indica que un `operador` puede.

### 2.1 Registrar un pago recibido por WhatsApp

`admin_register_payment(...) → jsonb`. Operador o super_admin.

```sql
admin_register_payment(
  p_user            uuid,       -- profiles.id del paciente
  p_installment_ids uuid[],     -- mismas reglas que la cotización de Ronda (lo vencido primero)
  p_method          text,       -- pago_movil | transferencia | zelle | usdt | efectivo
  p_bank            text,       -- null si no aplica
  p_reference       text,
  p_paid_on         date,
  p_amount_ves      numeric,    -- lo que dice el comprobante (null si fue en USD)
  p_receipt_path    text,       -- ruta en el bucket payment-receipts (subida previa desde el panel)
  p_note            text
)
```

```jsonc
{ "report_id": "uuid", "quote_id": "uuid",
  "amount_usd": 63.60, "late_fee_usd": 2.00, "fx_rate": 184.52, "amount_ves": 11735.47,
  "status": "reported",
  "candidatos_extracto": 1 }   // cuántas líneas del extracto casan (referencia + monto + fecha)
```

Queda en la cola de "Pagos reportados" y se aprueba con
`admin_reconcile_payment` (heredada). Si `payment_four_eyes = 1`, quien
registró no puede aprobarlo (`42501`, el mensaje dice «doble control»), salvo
un `super_admin`.

Implementado en 20261004000300. Además de lo de arriba devuelve
`installments_usd`, `installment_count`, `declared_amount_ves` (= `p_amount_ves`)
y `diferencia_ves` (declarado − esperado; null sin monto en Bs). La cotización
en Bs va **a la tasa BCV del día `p_paid_on`**, y el cruce con el extracto mira
±5 días alrededor de `p_paid_on`. `p_bank` y `p_amount_ves` son obligatorios
para `pago_movil` y `transferencia`; la referencia, salvo en `efectivo`.
`p_receipt_path` es la ruta dentro del bucket privado `payment-receipts` (solo el
equipo sube y lee). Cada ítem de `admin_payment_queue` / `admin_payment_report`
añade `registered_by`, `registered_by_name`, `paid_on`, `declared_amount_ves`,
`note`, `receipt_path`, `receipt` (`{bucket, path}` para `createSignedUrl`, o
null), `four_eyes` y `can_approve` (si quien mira puede aprobarlo).

### 2.2 Avisos (cola de WhatsApp manual + correos)

`admin_outbound_queue(p_day date default hoy, p_channel text default 'whatsapp_manual') → table`

| columna | nota |
|---|---|
| id, channel, template_key, template_label | |
| profile_id, patient_name, phone_e164 | |
| charge_id, order_number, due_date | |
| rendered_text | texto final para pegar o abrir con `wa.me` |
| status | `pendiente`, `enviado`, `omitido`, `fallido` |
| created_at, sent_at, sent_by_name | |
| whatsapp_url, recipient, last_error | (además) el `wa.me` con el texto, el destinatario al encolar y el motivo de omitido/cancelado |

Con `p_day` null = hoy, y hoy incluye además lo que siga `pendiente` de días
anteriores. `p_channel` null = todos.

`admin_mark_outbound(p_id uuid, p_status text, p_note text default null) → void`.
Operador o super_admin. `enviado` también escribe en `collection_contacts`
(canal whatsapp, `outcome = mensaje_enviado`). `omitido` exige nota. Solo desde
`pendiente` (marcar lo que ya está así no hace nada); `enviado` solo en
WhatsApp (los correos los manda el sistema).

`admin_outbound_history(p_channel text, p_status text, p_q text, p_limit int, p_offset int) → table`.
Incluye los correos: `email`, `provider_id`, `last_event`, `attempts` (y
`subject`, `last_event_at`, `next_attempt_at`, `last_error`), y `total_count` en
cada fila para paginar. Defaults: todo null, `p_limit` 50, `p_offset` 0.
`p_status` acepta además `rebotado` (last_event bounced/complained) y
`entregado` (delivered/opened/clicked).

`admin_resend_receipt(p_charge_id uuid, p_email text default null) → jsonb`.
Si viene `p_email`, además corrige el correo del paciente (queda en la
bitácora) y limpia `email_invalid_at`. Operador o super_admin. Devuelve
`{ok, message_id, status, email_enmascarado, email_changed, last_error}`
(`status` `omitido` si el paciente no tiene correo o el suyo rebotó).

### 2.3 Contacto de Helios y cuentas de cobro

- `admin_platform_contact() → jsonb`: devuelve `{whatsapp_number, support_email, support_hours, sender_name, sender_email, updated_at, updated_by_name}`.
- `admin_set_platform_contact(p jsonb) → jsonb`. Solo super_admin; queda en la bitácora.
  `whatsapp_number` se guarda en E.164 (un móvil VE se normaliza: `0414…` →
  `+58414…`). Solo cambian las claves presentes en `p`; `null` o `''` borra.
- `admin_payment_destinations() → table` (heredada): añade las columnas
  `method`, `account_number`, `email`, `sort_order` al final. Orden:
  activas primero, por `sort_order`.
- `admin_set_payment_destination(...) → uuid` (implementada en 20261002000600).
  La de Ronda más `p_sort_order` y `p_is_active`, y además `p_id` (sin él se
  crea otra cuenta; con él se edita o se apaga esa), `p_method`,
  `p_account_number` y `p_email`. Crear una ya **no** apaga las demás.

  ```sql
  admin_set_payment_destination(
    p_bank_name text, p_rif text, p_phone text,
    p_holder_name text default null, p_note text default null,
    p_sort_order int default null, p_is_active boolean default true,
    p_id uuid default null,
    p_method text default 'pago_movil',   -- pago_movil | transferencia | zelle
    p_account_number text default null,   -- transferencia: 20 dígitos
    p_email text default null             -- zelle
  ) returns uuid
  ```
  Datos obligatorios por método: Pago Móvil banco + RIF/C.I. + teléfono;
  transferencia banco + RIF/C.I. + cuenta + titular; Zelle correo + titular.
- `helios_config_status() → jsonb`: `{whatsapp: bool, cuentas_de_cobro: int, resend: bool, remitente: bool}`. **(2026-10-05)** Añade `whatsapp_api: bool` (existen en Vault `d360_api_key` y `d360_base_url`) y `whatsapp_sandbox: bool` (la URL es la del sandbox). La usa el aviso de "configuración incompleta" del Inicio. Exige `is_platform_admin()`. `resend` = existe en Vault un secreto llamado `resend_api_key` (no lee su valor); `remitente` = hay `sender_name` y `sender_email`.

### 2.4 Pacientes

- `admin_user_detail(p_user)` (heredada): cambia la pestaña "identidad" por
  **`datos`**:
  - `document`, `birth_date`, `age`, `sex`, `phone_e164`, `email`, `email_invalid_at`;
  - `state`, `city`, `address`, `occupation`;
  - `reference_{name,phone,relationship}`;
  - `registered_by_name`, `registered_merchant_name`, `created_at`.
- `admin_update_patient_contact(p_user uuid, p jsonb, p_reason text) → jsonb`.
  Campos editables: phone, email, state, city, address, occupation y
  reference_*. El motivo es obligatorio y queda en la bitácora. Operador o
  super_admin.
- `admin_profile_change_requests(p_status text default 'pendiente') → table`
  y `admin_resolve_profile_change(p_id uuid, p_approve boolean, p_note text default null)`.

Implementado en 20261003000700 y 000800. Precisiones:

- `admin_user_detail(p_user_id)` conserva el nombre heredado del parámetro.
  `datos` es un objeto; además de lo de arriba trae `document_key`,
  `first_name`, `last_name`, `full_name`, `registered_by`,
  `registered_merchant_id` y `pending_change_requests` (int).
- `admin_update_patient_contact`: solo las claves que vienen; `null`/`''`
  borra los opcionales; `phone` y `email` no se borran; la referencia no puede
  ser el teléfono del paciente; un correo nuevo borra `email_invalid_at`.
  Motivo < 3 caracteres → `22023`; clave no editable → `22023`. Devuelve
  `{ok, changes: {campo: {antes, despues}}, datos}`. Bitácora
  `patient.contact_updated`.
- `admin_profile_change_requests` (null = todas): `id, profile_id,
  patient_name, document_number, merchant_id, merchant_name, requested_by,
  requested_by_name, field_changes ({campo: {antes, propuesto}}), proposed
  ({campo: valor}), current ({campo: valor de hoy}), status, reviewed_by,
  reviewed_by_name, reviewed_at, resolved_at, resolved_by_name, note,
  created_at`. Los campos usan las claves de `p_patient` (`phone`, no
  `phone_e164`).
- `admin_resolve_profile_change`: aprobar aplica lo propuesto con las mismas
  validaciones del registro; una ya revisada → `22023`. Devuelve
  `{ok, id, status, changes}`. Bitácora `patient.change_request_approved` /
  `_rejected`.
- `admin_user_directory(...)` (heredada) añade al final
  `registered_merchant_name` y `email_invalid_at`.

### 2.5 Clínicas

**El alta y la solicitud de afiliación (20261009000200).** El alta pide los
datos del médico titular, del consultorio y su Pago Móvil; el médico manda los
mismos desde la portada (`/afiliacion`) y quedan pendientes hasta que un super
admin los aprueba. `p` (jsonb) lleva siempre las mismas claves, validadas por
`helios_datos_de_alta` (errores `22023` legibles para el médico):
`owner_name`, `owner_document` (cédula o pasaporte), `tax_id` (opcional),
`specialty`, `college_number` (opcional), `mpps_number` (opcional),
`clinic_name`, `address`, `phone` (VE, E.164), `email`, `pago_movil_bank`,
`pago_movil_document` (cédula o RIF), `pago_movil_phone` (celular VE).

**Desde 20261009000500** el pago del alta son las claves de
`merchant_payout_accounts`: `account_holder` y `holder_document` (titular,
obligatorios), `bank` + `account_number` (transferencia, 20 dígitos) y/o
`pago_movil_bank` + `pago_movil_phone`; hace falta al menos uno. Ya no existe
`pago_movil_document`. La solicitud de la portada exige la transferencia e
ignora el Pago Móvil. Los documentos pasan por `helios_documento(valor,
letras)`: el panel manda la letra pegada al número (`V12345678`,
`J123456789`, `PAB1234567`) y se guardan como cédula `V12345678` o RIF
`J-123456789`; sin letra válida, `22023`.

**Desde 20261023130000** `p` lleva también la red social, opcional:
`social_network` (`instagram`, `tiktok`, `facebook`, `x`, `linkedin`,
`youtube` u `otra`: `helios_redes_sociales()`) y `social_user` (usuario o
enlace, hasta 150). Van las dos o ninguna (`22023`). Se guardan en
`merchant_applications` y, al crear la clínica, en `merchants`
(`social_network`, `social_user`); `merchants.social_url`, heredada de
Ronda, no se toca.

- **Al aprobar (20261013000400)**, el panel encadena, si se deja marcado:
  `merchant_staff_add` (administrador, con el correo y el nombre de la
  solicitud y una contraseña generada) → `admin_set_staff_whatsapp` (su
  teléfono, si es celular) → `merchant_staff_send_welcome` →
  `admin_send_staff_whatsapp_welcome(p_merchant_id uuid, p_user_id uuid) →
  {status: 'en_cola' | 'sin_numero' | 'sin_plantilla' | 'ya_enviado', via:
  'texto' | 'plantilla', phone}`. Esta última (super admin) encola el
  WhatsApp de bienvenida: texto libre con la ventana de 24 h abierta, o la
  plantilla de Meta de `notification_templates.bienvenida_medico`
  (`helios_cuenta_activa` desde 20261013000500: {{1}} nombre, {{2}} clínica,
  {{3}} correo; el texto libre lleva el botón «Empezar», `menu:empezar`). Sin plantilla
  conectada y con la ventana cerrada no encola nada. Una vez por persona y
  clínica (`dedupe_key`). Bitácora `merchant.staff_whatsapp_welcome`.
  La llaman al aprobar la solicitud y, desde el 2026-10-15, al **añadir
  personal** en la ficha de la clínica (superadmin) cuando se le registra el
  WhatsApp del bot y se deja marcada la bienvenida.
- `admin_create_clinic(p jsonb) → {merchant_id}`: super admin. Crea la
  clínica (categoría sacada de la especialidad: odontología, cosmetología o
  consultorio), su cuenta de Pago Móvil (titular: el médico si va con cédula,
  la clínica si va con RIF) y las dos líneas de bitácora (`merchant.created`,
  `merchant.payout_account_set`). El RIF ya no es obligatorio; si viene, sigue
  siendo único (`23505`).
- `helios_solicitar_afiliacion(p jsonb) → {ok}`: **anon**. `p.sitio_web`
  relleno (campo trampa) contesta ok sin guardar. Frenos: una pendiente por
  cédula, correo o teléfono (`23505`); 5 al día por IP y 60 por hora en total
  (`54000`). Guarda en `merchant_applications` (RLS sin lecturas directas).
- `admin_merchant_applications(p_status text default 'pending') → jsonb[]`
  (equipo; `null` = todas): las claves de `p` más `id`, `status`,
  `created_at`, `merchant_id`, `reviewed_at`, `reviewed_by_name`,
  `reject_reason`.
- `admin_approve_merchant_application(p_id uuid, p jsonb default null) →
  {merchant_id}`: super admin. `p` = lo que el equipo corrigió (se mezcla con
  la solicitud). Bitácora `merchant_application.approved` (target: la clínica).
- `admin_reject_merchant_application(p_id uuid, p_reason text)`: super admin,
  motivo obligatorio. Bitácora `merchant_application.rejected` (target: la
  solicitud). Una solicitud revisada no se vuelve a revisar (`22023`).
- `admin_set_merchant_owner(p_merchant_id uuid, p jsonb)`: super admin;
  `owner_name`, `owner_document`, `college_number` (null = no tocar, '' =
  borrar; el nombre vacío no se toca). Bitácora `merchant.set_owner`.
- `admin_merchant_detail.profile` añade `owner_name`, `owner_document`,
  `college_number`.

- `admin_create_merchant(...)` (heredada) añade `p_specialty`, `p_mpps_number`,
  `p_phone`, `p_email` y `p_address`. `p_category` usa los valores nuevos
  `clinica | consultorio | odontologia | laboratorio | imagenes | otros`
  (`discoteca`/`conciertos` se rechazan con `22023`). Firma final
  (20261002000500), los nuevos al final y con default:

  ```sql
  admin_create_merchant(p_name text, p_legal_name text default null, p_tax_id text default null,
    p_category merchant_category default null, p_city text default null, p_handle text default null,
    p_logo_url text default null, p_social_url text default null,
    p_specialty text default null, p_mpps_number text default null, p_phone text default null,
    p_email text default null, p_address text default null) returns merchants
  ```
- `admin_set_merchant_profile(...)` (heredada) añade al final los mismos cinco
  (`p_specialty`, `p_mpps_number`, `p_phone`, `p_email`, `p_address`, default
  null). Para ellos `null` = no tocar y `''` = borrar.
- `admin_merchant_detail(p_merchant_id)` (heredada): `profile` añade
  `specialty`, `mpps_number`, `phone`, `email`, `address`, y la respuesta
  añade `payout_account` (lo mismo que `admin_merchant_payout_account`, o null).
- `admin_merchant_payout_account(p_merchant_id) → jsonb` y
  `admin_set_merchant_payout_account(p_merchant_id, p jsonb) → jsonb`
  (`bank`, `account_holder`, `holder_document`, `account_number`, `pago_movil_phone`, `pago_movil_bank`).
  Devuelven `{merchant_id, bank, account_holder, holder_document, account_number,
  pago_movil_phone, pago_movil_bank, updated_at, updated_by_name}` (null si no
  hay). Escribir: solo super_admin, con bitácora (`merchant.payout_account_set`).
  Obligatorios titular y documento, y al menos cuenta (20 dígitos) o Pago
  Móvil (móvil VE; se guarda en E.164). El `gerente` de la clínica puede leer
  su fila directamente en `merchant_payout_accounts` (RLS).
- `admin_merchant_contract_data(p_merchant_id uuid default null) → jsonb`
  (20261014000300, 2026-10-14): los datos de alta para redactar el contrato.
  Solo lectura, `is_platform_admin()` (`42501`); un id que no existe, `P0002`.
  Sin argumento (o `null`), todas las clínicas, ordenadas por nombre; con él,
  solo esa. Devuelve un array de `{merchant_id, name, legal_name, tax_id,
  category, specialty, mpps_number, phone, email, address, city, status,
  is_test, created_at, owner_name, owner_document, college_number, bank,
  account_holder, holder_document, account_number, pago_movil_bank,
  pago_movil_phone, applied_at, approved_at}`. Los de la cuenta de pago van en
  null si no tiene; `applied_at`/`approved_at` son los de la solicitud de la
  portada aprobada de la que nació (null si se dio de alta desde el panel).
  El panel la baja en CSV desde la lista de Clínicas (las que se ven, con el
  filtro) y desde el «⋯» de la ficha (una).
- `merchant_directory` (vista, 20261014000300) añade al final `owner_name`: la
  columna «Médico titular» de la lista de Clínicas.
- `merchant_staff_add` / `merchant_staff_update`: el rol `inventario` se
  rechaza (`22023`).
- `merchant_staff_send_welcome(p_merchant_id uuid, p_user_id uuid, p_password text) →
  {status: 'enviado' | 'sin_configurar' | 'fallido', error}` (20261009000300):
  quien gestiona el personal (equipo o gerente), justo después de
  `merchant_staff_add` (y de `admin_set_staff_whatsapp` si lleva bot, para que
  el correo diga su número). Manda al momento por Resend el correo de
  bienvenida (enlace del panel, correo, contraseña y cómo usar el bot), con
  copia oculta a `platform_contact.staff_welcome_copy`
  (`javier@conhelios.com`). La contraseña tiene que ser la de la cuenta
  (`22023` si no) y no se guarda: no pasa por `outbound_messages`. Bitácora
  `merchant.staff_welcome_sent` sin la contraseña. No lanza si el correo no
  sale.
- `admin_set_settlement_terms(...)` (heredada) añade
  `p_staff_commission_usd numeric default null`. `null` significa que usa el
  parámetro global.
- `admin_merchant_payables()` / `admin_payout_detail()` (heredadas): cada
  línea trae `reason`, y los totales se separan en `consultas_usd` y
  `comisiones_usd`.

Implementado en 20261003000500 y 000800. Precisiones:

- Firma final (va al final, con default; la vieja de 7 argumentos se borró, la
  de 5 con `settlement_policy` sigue delegando):
  `admin_set_settlement_terms(p_merchant_id uuid, p_upfront_pct numeric,
  p_per_installment_pct numeric, p_commission_pct numeric, p_policy text,
  p_effective_from date default null, p_note text default null,
  p_staff_commission_usd numeric default null) → jsonb`. Entre $0 y $100,
  como mucho 2 decimales (`22023`); 0 = sin comisión. Como cada fila de
  condiciones es completa, **llamarla sin `p_staff_commission_usd` deja la
  clínica con la comisión global**: el panel tiene que mandar el valor vigente
  si no quiere cambiarlo. Devuelve también `staff_commission_usd`.
- La comisión de un financiamiento: la pactada vigente el día del
  financiamiento (`merchant_terms.staff_commission_usd`) o, si es null, el
  parámetro global vigente ese día. Se guarda como instantánea en
  `charges.staff_commission_usd`.
- `admin_merchant_detail.terms` añade `staff_commission_usd` (pactada, null =
  global) y `staff_commission_effective_usd` (la de hoy).
  `admin_merchant_terms_history` añade `staff_commission_usd` por fila.
- `admin_merchant_payables()`: cada clínica trae `consultas_usd` /
  `comisiones_usd` (devengado sin transferir) y los
  `next_run_consultas_usd` / `next_run_comisiones_usd` de la previsión.
- `admin_payout_detail`: `consultas_usd`, `comisiones_usd`, y en cada ítem
  `reason`, `staff_user_id`, `staff_name` (las de comisión).
  `admin_merchant_payouts`: cada fila trae `consultas_usd`, `comisiones_usd`.
  `admin_report_merchant_payout` los guarda en la transferencia y los devuelve.
- `admin_reverse_charge` revierte también la comisión (asiento espejo,
  `staff_commissions.status = 'revertida'`, se borra su liquidación
  pendiente) y devuelve `staff_commission_reverted_usd`. Si ya se transfirió
  algo a la clínica (consultas o comisión) se sigue bloqueando.
- `admin_charge_detail` añade `concept`, `beneficiary_name`, `registered_by`,
  `registered_by_name`, `terms_version`, `receipt`, `staff_commission`
  (`{id, amount_usd, staff_user_id, staff_name, status, settlement_id, created_at}`
  o null), `messages` (la cola de ese financiamiento) y `user.document_number`
  / `user.email`. `admin_charges` añade al final `concept`,
  `beneficiary_name`, `registered_by_name`, `staff_commission_usd`,
  `document_number`.
- H9: `terms_versions` gana `id uuid` (único; la clave sigue siendo
  `version`); `charges.terms_version_id` apunta a la vigente al registrar. Se
  sembró la v1 (condiciones en USD) porque la tabla estaba vacía.

### 2.6 Alertas

`admin_risk_alerts(p_limit int default 200, p_kinds text[] default null, p_subject_id uuid default null)`
(heredada; `p_subject_id` filtra las de un paciente, clínica o persona del
personal) añade estos `kind` (`consumo_sobre_cupo` sigue; `cuenta_relacionada` se
va: la cédula ya es única):

- `telefono_repetido`, `correo_repetido`, `correo_rebotado`;
- `rafaga_de_altas`, `rafaga_de_pacientes_nuevos`, `secretaria_concentrada`;
- `impago_primera_cuota_clinica`, `exposicion_clinica`;
- `referencia_repetida`, `cupo_al_limite_al_estrenar`, `consultas_de_cedula_excesivas`.

Cada fila trae:
- `kind`, `severity` (`alta`/`media`), `subject_type` (`paciente`/`clinica`/`personal`), `subject_id`, `subject_name`;
- `detail jsonb`, `first_seen_at`;
- `reviewed`: se marca con `admin_review_risk_alert`, que es heredada.
- por compatibilidad: `alert_key` (lo que recibe `admin_review_risk_alert`),
  `user_id`, `full_name`, `user_status`, `detected_at`, `merchant_id`,
  `reviewed_at`, `reviewed_by_name`, `review_note`.

Claves de `detail` (donde aplican): `phone_e164`, `email`, `patient_count`,
`charge_count`, `threshold`, `share_pct`, `merchant_id`, `merchant_name`, `fpd_pct`,
`cases`, `exposure_usd`, `reference`, `used_pct`, `lookups`, `staff_name`. Las de
sujeto `personal` siempre traen `merchant_id`. La respuesta trae además
`thresholds`. Implementado en 20261004000400.

### 2.7 WhatsApp del personal (bot del médico, 2026-10-05)

Las escrituras usan `helios_assert_super_admin(p_what)` (rol y MFA).

Leer: `is_platform_admin()`. Escribir: `helios_assert_super_admin()`, con
bitácora.

- `admin_staff_whatsapp(p_merchant_id uuid default null) → jsonb` (un arreglo; implementado en 20261005000500 con el resto de esta sección):
  `id, phone_e164, user_id, staff_name, role, merchant_id, merchant_name,
  last_inbound_at, created_at, created_by_name,
  revoked_at, revoked_by_name, revoke_reason`. Null = todas las clínicas.
- `admin_set_staff_whatsapp(p_user_id uuid, p_merchant_id uuid, p_phone text) → jsonb`.
  La persona tiene que ser personal activo (`gerente` o `cajero`) de esa
  clínica. El teléfono es un móvil venezolano y se guarda en E.164. Si el
  número ya está activo para otra persona → `22023` "Ese número ya está
  registrado para {nombre}". Una persona con un número activo que recibe otro:
  el anterior se revoca solo ("cambio de número"). Bitácora
  `staff.whatsapp_set`.
- `admin_revoke_staff_whatsapp(p_id uuid, p_reason text) → jsonb`. Motivo
  obligatorio. Borra la sesión del bot de ese número. Bitácora
  `staff.whatsapp_revoked`.
- ~~`admin_reset_staff_pin`~~: eliminada con el PIN (20261013000200). Las
  líneas viejas `staff.pin_reset` de la bitácora quedan.
- Dar de baja a una persona (`merchant_staff_update` → inactiva) revoca su
  número.

### 2.8 Seguimiento de las clínicas (2026-10-21, 20261021100000)

Superadmin › Seguimiento: el contacto del equipo con los médicos y su
personal. Leer y anotar: `is_platform_admin()` (los dos roles, como una
gestión de cobranza), con bitácora al anotar.

Tabla `merchant_followups` (solo se añade, sin RLS de lectura: solo por estas
RPC): `merchant_id, contact_user_id` (null = el consultorio), `channel`
(`llamada | whatsapp | visita | correo`), `topic` (`seguimiento | opinion |
soporte | capacitacion`), `note` (3–2000), `next_contact_on`, `actor`.

- `admin_followups_board() → jsonb` (un arreglo, una fila por clínica):
  `merchant_id, name, status, is_test, city, specialty, phone, email,
  owner_name, doctor_name, created_at, orders_confirmed, orders_30d,
  last_order_at, staff[], followups_count, last_followup, next_contact_on`.
  `staff[]` es el personal activo, quien más órdenes confirmadas tiene
  primero: `user_id, name, email, phone` (el número activo del bot; si no,
  el de auth), `role, branch, joined_at, last_sign_in_at, last_panel_at,
  last_bot_at, active_days_30d, orders_registered, orders_confirmed,
  orders_30d, orders_whatsapp, last_order_at`. `last_panel_at`,
  `last_bot_at` y `active_days_30d` (días con uso de cualquiera de los dos)
  salen de `staff_activity_days` (2026-10-26, ver abajo);
  `last_sign_in_at` solo cambia al iniciar sesión y ya no se enseña. Las
  órdenes son las de `charges.requested_by`, sin las de
  pacientes de prueba; 30 días = días operativos con hoy. `last_followup`:
  `created_at, channel, topic, note, actor_name, contact_name` o null.
  `next_contact_on` es la del último contacto (una nota nueva sin fecha la
  quita).
- `admin_merchant_followups(p_merchant_id uuid, p_limit int default 50) →
  table(id, created_at, channel, topic, note, next_contact_on,
  contact_user_id, contact_name, actor_name)`, el último primero (tope 200).
- `admin_log_merchant_followup(p_merchant_id uuid, p_channel text, p_topic
  text, p_note text, p_contact_user_id uuid default null, p_next_contact_on
  date default null) → uuid`. `P0002` si la clínica no existe; `22023` con
  canal o motivo desconocido, nota de menos de 3 o más de 2000 caracteres,
  una persona que nunca fue de esa clínica o una fecha anterior al día
  operativo. Bitácora `merchant.followup` (target: la clínica).

**El uso del panel y del bot** (2026-10-26, 20261026200000). Tabla
`staff_activity_days` (sin RLS de lectura): una fila por `user_id,
merchant_id, channel` (`panel | bot`) y `business_date`, con `first_at,
last_at, hits`. La historia anterior se rellenó con `auth.sessions`,
`auth.refresh_tokens`, `last_sign_in_at`, las órdenes con `channel = 'panel'`
y los mensajes del personal en `whatsapp_inbound`.

- `helios_staff_seen_in_panel(p_merchant_id uuid) → boolean` (authenticated):
  anota un uso del panel. `false`, sin error, si quien llama no es personal
  activo (`gerente | cajero`) de esa clínica. El panel la llama desde
  `_comercio` al abrirse, al navegar, al volver a la pestaña y al tocar o
  escribir, como mucho una vez cada 5 min (`features/auth/usoDelPanel.ts`).
- `helios_whatsapp_inbound` anota `bot` por cada mensaje nuevo de un número
  del personal (un reintento con el mismo wamid no cuenta).
- `helios_note_staff_activity(user, merchant, channel, at)`: interna, sin
  `grant`.

La prioridad de contacto (el semáforo de Seguimiento › Por persona) se
calcula en el panel (`prioridadDeContacto` en
`features/admin/seguimiento/seguimiento.ts`): órdenes confirmadas en 30 días
× días sin usar el panel ni el bot (≤ 7, 8–14, > 14 o nunca).

### 2.9 Agenda de médicos por afiliar (2026-10-22, 20261022200000)

Superadmin › Agenda: los médicos que el equipo quiere afiliar, sus gestiones y
sus reuniones. Todo con `is_platform_admin()` (los dos roles, como el
seguimiento) y bitácora en cada escritura.

Tablas (sin RLS de lectura: solo por estas RPC):

- `doctor_leads`: `name` (3–120; `name_key` generada para comparar), `clinic_name,
  specialty, phone` (E.164 venezolano), `email, address, city, source`
  (`referido | redes | visita | evento | base_de_datos | otro`), `notes`,
  `status` (`nuevo | contactado | respondio | no_respondio | reunion |
  convertido | descartado`), `meeting_at, meeting_mode` (`presencial |
  videollamada | llamada`), `meeting_place, next_contact_on, assigned_to`
  (alguien del equipo), y la afiliación: `merchant_application_id,
  merchant_id, converted_at, converted_via` (`formulario | alta | agenda |
  manual`), `match_reason` (`telefono | correo | nombre`).
- `doctor_lead_activities` (solo se añade; se borra con su lead): `kind`
  (`creado | gestion | conversion`), `channel` (`llamada | whatsapp | visita |
  correo | redes`), `status_from, status_to, meeting_at, note, actor` (null =
  el sistema).

El cruce con la afiliación (disparadores, nunca tumban la afiliación: si fallan
dejan un `warning`):

- Al insertar en `merchant_applications`, y al insertar una clínica que no es
  de prueba en `merchants`, los leads con el mismo teléfono, el mismo correo o
  el mismo nombre (`helios_lead_name_key`: sin tildes ni «Dr./Dra.», de al
  menos dos palabras) pasan a `convertido` y se enlazan con la solicitud o la
  clínica. Un lead ya enlazado con otra clínica no se toca.
- Al ponerle `merchant_id` a una solicitud (aprobación), sus leads quedan con
  esa clínica.
- Al apuntar o corregir un lead, si ya hay una clínica real o una solicitud no
  rechazada que coincide, sale afiliado (`converted_via = 'agenda'`).

**Desde 20261023140000** (la capacitación y los accesos):

- `helios_solicitar_afiliacion` acepta `p.training_at` (opcional): el día y
  la hora de la capacitación presencial con su desfase
  (`2026-10-30T10:00:00-04:00`), de mañana a 90 días (`22023`). Se guarda en
  `merchant_applications.training_at` y `admin_merchant_applications` lo
  devuelve.
- Toda solicitud entra a la agenda: los leads que coinciden se enlazan (la
  solicitud enlazada solo se cambia si la de antes se rechazó); si no hay
  ninguno, nace uno con `source = 'formulario'` (valor nuevo). Con
  capacitación, el lead queda `reunion` con `meeting_at = training_at`,
  presencial, en la dirección del consultorio; sin ella, queda `respondio`
  («Interesado»): el lead nuevo nace así (20261023150000) y uno que ya estaba
  pasa a ese estado si no estaba en una visita.
- **«Afiliado» (`convertido`) es que la clínica del lead tenga sus accesos**
  (`helios_clinica_tiene_accesos`: alguien activo en `merchant_users`). Llegar
  la solicitud, aprobarla o nacer la clínica solo enlazan (la historia dice
  «Falta darle sus accesos»); el disparador de `merchant_users` (alta o
  reactivación) lo pasa a afiliado con `converted_via` `formulario` (si tiene
  solicitud) o `alta`. Marcarlo a mano (`afiliado`) sigue igual.
- `admin_doctor_leads()` añade `application_training_at` y
  `merchant_has_access`.

RPC:

- `admin_doctor_leads() → jsonb` (un arreglo, el más nuevo primero): `id, name,
  clinic_name, specialty, phone, email, address, city, source, notes, status,
  meeting_at, meeting_mode, meeting_place, next_contact_on, assigned_to,
  assigned_name, converted_at, converted_via, match_reason, application_id,
  application_status, merchant_id, merchant_name, created_at, updated_at,
  activities_count, last_activity` (`created_at, kind, channel, status_to,
  note, actor_name` o null).
- `admin_doctor_lead_activities(p_lead_id uuid) → table(id, created_at, kind,
  channel, status_from, status_to, meeting_at, note, actor_name)`, la última
  primero (tope 200).
- `admin_save_doctor_lead(p_lead_id uuid, p jsonb) → jsonb {id, status,
  merchant_name}`. `p_lead_id` null crea; si no, reemplaza los datos (`name,
  clinic_name, specialty, phone, email, address, city, source, notes,
  assigned_to`). `22023` con un dato que no vale; `23505` si otro lead tiene
  ese teléfono o ese correo; `P0002` si el lead ya no existe. Bitácora
  `doctor_lead.created` / `doctor_lead.updated` (target: el lead).
- `admin_log_doctor_lead_contact(p_lead_id uuid, p_result text, p_channel text
  default null, p_note text default null, p_meeting_at timestamptz default
  null, p_meeting_mode text default null, p_meeting_place text default null,
  p_next_contact_on date default null) → uuid` (desde 20261022210000: recibe el
  resultado, no el estado). El árbol del equipo: mensaje (`mensaje_enviado`,
  contestó `interesado` / `no_interesado`, `no_contesto`), llamada
  (`interesado` / `no_interesado`, `no_contesto`, `ocupado`) y visita
  (`visita_agendada`, y con una agendada `visita_realizada`,
  `visita_pospuesta`, `visita_cancelada`); además `afiliado` y `nota`. El estado
  sale del resultado: `mensaje_enviado → contactado`, `interesado → respondio`,
  `no_interesado → descartado`, `no_contesto | ocupado → no_respondio`,
  `visita_agendada | visita_pospuesta → reunion`, `visita_realizada →
  visitado`, `visita_cancelada → respondio` (sin visita), `afiliado →
  convertido`, `nota` → el que tenía. `p_channel`: `mensaje | llamada | visita`
  (y los de antes). `visita_agendada` y `visita_pospuesta` piden `p_meeting_at`
  (de hoy en adelante; la pospuesta, distinta de la que había); realizada,
  pospuesta y cancelada piden una visita agendada; `nota` pide la nota; una
  fecha de visita con otro resultado, o volver a llamar antes de hoy, dan
  `22023`. Volver a un estado de antes de la visita mientras hay una por venir
  la anula (lo dice la nota). `next_contact_on` se reemplaza en cada gestión
  (y se borra al afiliar o con `no_interesado`). Bitácora `doctor_lead.contact`
  con `result`. Las líneas guardan `result`; el tablero lo devuelve en
  `last_activity.result` y la historia en su columna `result`. Estado nuevo
  `visitado` (visita realizada).
- El panel ya no pide el correo ni la ciudad (las columnas siguen; al
  corregir un lead desde el panel quedan vacías).
- `admin_delete_doctor_lead(p_lead_id uuid) → void`. Borra el lead y su
  historia; la bitácora `doctor_lead.deleted` guarda sus datos. `P0002` si ya
  no existe.

**El rol de la agenda** (2026-10-22, 20261022220000 y 20261022220100).
`platform_role` gana `agenda`: una cuenta del equipo que solo entra a
superadmin › Agenda.

- `is_platform_admin()` ahora es `helios_es_del_equipo(['super_admin',
  'operador'])`: el rol `agenda` no pasa ninguna RPC ni RLS del superadmin.
- `helios_puede_usar_la_agenda()` = `helios_es_del_equipo` con los tres roles
  (cuenta activa y, si se exige, sesión `aal2`). Es la guardia de las cinco
  RPC de la agenda y de `admin_agenda_team()`.
- `admin_agenda_team() → table(user_id, name, role)`: el equipo activo, para
  «Gestionado por» (`admin_platform_team` sigue siendo del superadmin).
- Se da desde Ajustes › Equipo (`admin_set_platform_admin` con `p_role =
  'agenda'`, super admin). En el panel, ese rol ve un menú con la Agenda sola;
  cualquier otra ruta de `/admin` lo lleva a ella, y la Agenda le esconde los
  enlaces al inbox y a la ficha de la clínica.

### 2.10 Métricas › Juan Pablo (2026-10-23, 20261023160000)

La primera pestaña de Métricas (y la de por defecto): las cifras que mira Juan
Pablo para un periodo propio (un día, una semana, un mes o un rango; por
defecto, hoy). No se parte por clínica. Guardia: `is_platform_admin()`.

`admin_metricas_juan_pablo(p_desde date default null, p_hasta date default null) → jsonb`

- Sin fechas, hoy (`metricas.hoy()`). El `hasta` no pasa de hoy y el `desde`
  no pasa del `hasta`.
- `{ hoy, desde, hasta, dias, ordenes, gtv_usd, revenue_usd, revenue_pct,
  ticket_medio_usd, medicos: { afiliados, con_ordenes, con_ordenes_pct,
  ordenes_por_medico }, por_medico: [{ merchant_id, medico, clinica, ordenes,
  pct, gtv_usd, revenue_usd }] }`.
- Las órdenes son las de `metricas.consumos` (confirmadas, sin las de prueba,
  por su día operativo), las mismas que cuenta Semana. `gtv_usd` es lo que
  suman sus consultas sin la comisión (`financed_usd`); `revenue_usd` es la
  Comisión Helios sin IVA (`consumer_fee_usd`).
- Un médico es una clínica (`helios_doctor_name`). `afiliados`: activas, no de
  prueba, dadas de alta antes del cierre y con sus accesos
  (`helios_clinica_tiene_accesos`), más cualquiera con órdenes en el periodo.
  `con_ordenes_pct` = con órdenes ÷ afiliados; `ordenes_por_medico` = órdenes
  ÷ médicos con órdenes; cada `pct` de `por_medico` = sus órdenes ÷ las del
  periodo. Orden: más órdenes primero.
- En el panel: `?vista` se omite (es la de por defecto) y el periodo va en
  `?desde=…&hasta=…` (hoy no se escribe). Suite:
  `supabase/tests/metricas_juan_pablo.sql`.

---

## 3. Parámetros nuevos (`business_parameters`)

| key | valor inicial | uso |
|---|---|---|
| `min_charge_usd` | 10 | monto mínimo por financiamiento |
| `staff_commission_usd` | 0.50 | comisión por financiamiento confirmado |
| `eligibility_lookups_per_staff_day` | 60 | consultas de cédula por usuario y día |
| `payment_four_eyes` | 0 | 1 = quien registra un pago no lo aprueba |
| `receipt_resends_per_day` | 3 | reenvíos del comprobante por día |
| `alert_charges_per_merchant_day` | 10 | alerta `rafaga_de_altas` |
| `alert_new_patients_per_merchant_day` | 8 | alerta `rafaga_de_pacientes_nuevos` |
| `alert_staff_share_pct` | 80 | alerta `secretaria_concentrada` |
| `alert_fpd_merchant_pct` / `alert_fpd_min_cases` | 25 / 5 | alerta `impago_primera_cuota_clinica` |
| `alert_merchant_exposure_usd` | 3000 | alerta `exposicion_clinica` |
| `alert_first_charge_limit_pct` | 90 | alerta `cupo_al_limite_al_estrenar` |
| `alert_staff_share_min_charges` | 5 | mínimo de la semana para `secretaria_concentrada` (20261004000400) |
| `patient_confirmation_required` | 0 | 1 = la orden espera el "Sí" del paciente (§1.3.1). Se pasa a 1 cuando Meta apruebe la plantilla |
| `patient_confirmation_minutes` | 120 | plazo de la orden pendiente |
| `confirmation_resends_per_day` | 3 | reenvíos de la confirmación por orden y día |
| `staff_pin_max_attempts` | 5 | sin uso desde 20261013000200 (el bot ya no pide PIN) |
| `bot_session_minutes` | 30 | inactividad que reinicia la conversación del bot |

Sembrados en 20261002000100 con vigencia desde 2026-09-30 (más una fila de
`late_fee_usd` = 2 en dólares). Lectores (`stable security definer`, para
`authenticated`): `helios_min_charge_usd()`, `helios_staff_commission_usd()`,
`helios_eligibility_lookups_per_staff_day()`, `helios_payment_four_eyes()`
(boolean), `helios_receipt_resends_per_day()`. Los `alert_*` se leen con
`helios_parameter('alert_…', fallback)`, que los oculta a quien no es del
equipo si se llaman directo desde la API. La regla del monto vive en
`helios_assert_charge_amount(p_base numeric)` (22023 «El monto mínimo es $10»,
«El monto admite como mucho 2 decimales»).

## 4. Plantillas de mensajes (`notification_templates`)

| key | canal | cuándo |
|---|---|---|
| `confirmar_financiamiento` | whatsapp (plantilla de Meta `helios_confirmar_financiamiento`) | al crear la orden pendiente y al reenviarla (2026-10-05) |
| `comprobante_financiamiento` | email | al confirmar (y al reenviar) |
| `bienvenida` | whatsapp_manual → **whatsapp** (2026-10-05) | al confirmar; con la confirmación del paciente sale sola como texto libre y solo cae a la cola manual si la API falla |
| `cuota_manana` | whatsapp_manual + email | víspera, 19:00 |
| `cuota_hoy` | whatsapp_manual | día del vencimiento, 08:00 |
| `cuota_vencida_d1` | whatsapp_manual | +1 día |
| `cargo_por_atraso_d4` | whatsapp_manual | +4 días |
| `pago_recibido` / `pago_rechazado` | whatsapp_manual | al conciliar o rechazar |
| `cuenta_congelada` | whatsapp_manual | al pasar a `frozen` |

Despacho (20261004000100/000200): crons `helios_aviso_cuota_manana` (19:00),
`helios_aviso_cuota_hoy` (08:00), `helios_aviso_cuota_vencida_d1` (08:05) y
`helios_aviso_cargo_por_atraso_d4` (10:30, detrás de la mora y solo con el cargo
ya cobrado), hora de Caracas, editables con `admin_set_notification_schedule`;
+7 días = Cobranza, sin mensaje. Un aviso por paciente y fecha de vencimiento;
un pago registrado o conciliado cancela los pendientes de esa fecha. Correo:
`helios_email_dispatch` (cada minuto) y `helios_email_status` (cada 15 min).

Variables disponibles:
- del paciente: `{nombre}`;
- del financiamiento: `{clinica}`, `{orden}`, `{monto_cuota}`, `{fecha}`, `{cuotas}`;
- de configuración: `{whatsapp_helios}`, `{cuentas_de_cobro}`;
- `{tasa_bcv}` y `{monto_bs}` (a la tasa del día).

Implementado en 20261002000700 (cimientos; el despacho es de H6/H7):

- `notification_templates.channels text[]` (`email`, `whatsapp_manual`; `app`
  = las de Ronda, **apagadas**), `default_html`/`html` para el correo y `type`
  opcional. Las nueve claves de arriba ya están sembradas con texto por
  defecto.
- Cola `outbound_messages` (lectura: solo el equipo). Se llena con
  `helios_enqueue_message(p_template_key, p_profile_id, p_charge_id, p_channel,
  p_vars jsonb default '{}', p_due_date date default null, p_dedupe_key text
  default null) → uuid` y `helios_enqueue_charge_receipt(p_charge_id) → uuid`.
  **Internas** (sin permiso para la API): las llaman `create_patient_charge`,
  `staff_resend_receipt`, `admin_resend_receipt` y los avisos.
- Variables que siempre están (las pone la base, el llamador puede pisarlas):
  `{nombre}`, `{whatsapp_helios}`, `{whatsapp_link}`, `{cuentas_de_cobro}`,
  `{cuentas_de_cobro_html}`, `{soporte_email}`, `{soporte_horario}`,
  `{tasa_bcv}`, `{cargo_atraso}`, `{dias_gracia}`, `{dias_suspension}`,
  `{dias_expulsion}`. Sin WhatsApp o sin cuentas configurados llevan un texto
  de reserva. Las demás las pasa el llamador (`{clinica}`, `{orden}`,
  `{cuotas}`, `{monto_cuota}`, `{fecha}`, `{monto}`, `{motivo}`…; la lista
  exacta por plantilla está en `notification_templates.variables`). Si falta
  una, `22023` y no se encola.

### 4.1 Cambios del 2026-10-05

Implementado en 20261005000300 (canal, plantillas, bienvenida) y
20261005000400 (despacho) y 20261005000600 (bot: avisos al médico y
`recipient_staff_id`).

- `notification_templates.channels` admite `whatsapp` (automático por la
  API). Columnas nuevas: `wa_template_name` (nombre aprobado en Meta; null =
  solo texto libre), `wa_template_lang` (`es`), `wa_template_params text[]`
  (las variables de `{{1}}`, `{{2}}`… en orden) y `wa_buttons jsonb`
  (`[{id, title}]`, botones de respuesta rápida; el `id` admite variables,
  p. ej. `confirmar:{charge_id}`, y es lo que vuelve en el webhook).
- Al encolar un mensaje `whatsapp`, `outbound_messages.wa_template` guarda la
  plantilla ya resuelta (`{name, language, params[], buttons[{id, title}]}`),
  con las variables aplanadas a una línea. Toda plantilla recibe además la
  variable `{charge_id}`.
- `confirmar_financiamiento`: `wa_template_name = 'helios_confirmar_financiamiento'`,
  `wa_template_params = {nombre, clinica, monto_consulta, cargo_servicio, iva_cargo_servicio, cuotas_linea}`
  (`{cargo_servicio}` = `consumer_fee_usd`, `{iva_cargo_servicio}` = `consumer_fee_vat_usd`).
  `{cuotas_linea}` es el plan en una sola línea («$61.60 el 12/10 y $61.60 el
  19/10»), porque Meta no admite saltos de línea en una variable. El texto
  completo está en docs/00 §15.5.
- `bienvenida` pasa a `{whatsapp}` y se encola al **confirmar** (el "Sí"). Va
  como texto libre: la respuesta del paciente abrió la ventana de 24 h. Texto
  nuevo por defecto:

  ```text
  ¡Listo, {nombre}! Tu financiamiento #{orden} en {clinica} está confirmado.

  Tus cuotas:
  {cuotas}

  Para pagar (en bolívares, a la tasa BCV del día del pago):
  {cuentas_de_cobro}

  Cuando pagues, envíanos el comprobante por este chat. También te mandamos todos los detalles a tu correo.
  ```
- Avisos a quien registró la orden, **desde el panel o desde el bot**, si
  tiene número del bot (20261013000300; antes solo las del bot): aceptada,
  rechazada y vencida (§5.4). Con su ventana de 24 h abierta, texto libre
  (plantilla interna `bot_respuesta` = `{texto}`). Con la ventana cerrada,
  solo «aceptó», con la plantilla de Meta de `aviso_al_medico` ({{1}}
  paciente, {{2}} orden, {{3}} consulta) cuando tenga `wa_template_name`; si
  no, se omite y el resultado queda en el panel.
- En WhatsApp, `outbound_messages` usa las columnas del correo: `provider_id`
  = el id del mensaje (wamid), `last_event` = `sent` | `delivered` | `read` |
  `failed` y `last_error`. Un mensaje que la API no puede mandar pero una
  persona sí pasa a `channel = 'whatsapp_manual'` («Avisos de hoy») con el
  motivo en `last_error`. `recipient_staff_id` (y `profile_id` null) cuando el
  destinatario es una persona del personal en lugar de un paciente; las
  lecturas de «Avisos de hoy» no los muestran.

---

## 5. WhatsApp: webhook y bot (2026-10-05)

Todas son **solo para `service_role`** (`revoke … from public, anon,
authenticated`): las llama la Edge Function `whatsapp-webhook` o `pg_cron`,
nunca el panel. Son `security definer` con `set search_path` como el resto.
Las del webhook **no lanzan** errores de negocio: devuelven
`{ok: false, reason}` para que un reintento de 360dialog no se repita en bucle.

### 5.1 Tablas nuevas

| Tabla | Para qué |
|---|---|
| `whatsapp_inbound` | Cada evento recibido, crudo (`wa_message_id` único) |
| `whatsapp_contacts` | Por número: `last_inbound_at` (la ventana de 24 h), `profile_id` / `staff_user_id` si se conoce |
| `whatsapp_sessions` | Estado de la conversación del bot por número (`state`, `data jsonb`, `updated_at`). La Edge Function la lee y la escribe directamente |
| `staff_whatsapp_numbers` | Número → persona y clínica (§2.7) |

`charges` gana `channel` (`panel` | `whatsapp`), `answered_at` y
`answer_wa_message_id` (la prueba del "Sí").

### 5.2 Del webhook

- `helios_whatsapp_inbound(p_message_id text, p_from text, p_type text, p_payload jsonb) → jsonb`.
  Guarda el evento (si ya estaba: `{duplicate: true}` y no se hace nada más),
  actualiza `whatsapp_contacts` y devuelve lo que hace falta para enrutar:
  `{duplicate, staff: {user_id, staff_name, merchant_id, merchant_name, role} | null,
  pending_charge_id: uuid | null}` (la única orden `pending` vigente cuyo
  paciente tiene ese teléfono registrado).
- `helios_patient_decision(p_charge_id uuid, p_decision text, p_from_phone text, p_wa_message_id text) → jsonb`.
  `p_decision` ∈ `si` | `no`. Comprueba que `p_from_phone` sea el teléfono
  registrado del paciente y que la orden siga `pending` y sin vencer. **Sí**:
  revalida y confirma (§5.1 del plan): asiento, cuotas, comisión, comprobante,
  bienvenida y aviso al médico. **No**: `declined`. Idempotente por
  `p_wa_message_id`. Devuelve
  `{ok, status: confirmed|declined, order_number}` o
  `{ok: false, reason: no_pendiente|vencida|otro_telefono|no_disponible}`. En
  `no_disponible` (la revalidación falló) la orden queda `declined`, al paciente
  no se le dice el motivo y la clínica ve el texto neutro de siempre.
- `helios_whatsapp_status(p_wa_message_id text, p_status text, p_error jsonb default null, p_at timestamptz default null) → boolean`
  (implementado en 20261005000400). Solo avanza (sent < delivered < read); un
  `failed` deja el mensaje `fallido` con el motivo. Devuelve si encontró el
  mensaje.
- `helios_whatsapp_text(p_to text, p_text text, p_staff_user_id uuid default null) → uuid`.
  Encola un texto libre para la conversación del bot y lo despacha al momento.
  Si la ventana del número está cerrada, `22023`.

### 5.3 Crons

Implementados en 20261005000300 (vencer) y 20261005000400 (despacho, con
`helios_dispatch_whatsapp_batch(p_limit)` y la costura de red
`helios_d360_request`). Un teléfono sin WhatsApp (131026) deja el mensaje
`fallido`; lo demás que la API no puede mandar va a la cola manual.

- `helios_whatsapp_dispatch()`: cada 10 s. Ventana abierta → texto; cerrada →
  plantilla; sin plantilla o tras 3 fallos → `whatsapp_manual`. Sin
  `d360_api_key` en Vault no llama a nadie y todo cae a la cola manual.
- `helios_expire_pending_charges()`: cada minuto. `pending` con
  `expires_at < now()` → `expired`, libera la reserva, cancela la plantilla si
  aún no salió y encola `orden_vencida` al médico si la registró por WhatsApp.

### 5.4 Del bot

Implementado en 20261005000600; la conversación vive en
`supabase/functions/whatsapp-webhook/bot.ts`.

Cada `bot_*` resuelve `p_phone` en `staff_whatsapp_numbers` (activo y con
la persona aún activa en esa clínica; si no, `42501` "Este número no está
registrado en Helios"). Después fija `request.jwt.claims` y
`request.jwt.claim.sub` en la transacción (`sub` = la persona, `role` =
`authenticated`) y `helios.canal` = `whatsapp`, y llama a la RPC del panel, así
que **devuelven y fallan exactamente igual que en el panel** (mismos errcode y
textos). Bitácora con `canal = whatsapp`.

| RPC | Equivale a | Nota |
|---|---|---|
| `bot_patient_eligibility(p_phone, p_document)` | `helios_patient_eligibility` | `p_merchant_id` sale del número |
| `bot_check_patient(p_phone, p_patient jsonb) → jsonb` | `helios_patient_field`, campo por campo | (20261016000100) Lo que la base rechazaría, `{campo: motivo}`; vacío si todo vale. No escribe. El bot la llama al recibir los datos y otra vez si el registro falla, y pide solo lo que esté mal |
| `bot_preview_charge(p_phone, p_document, p_amount_usd)` | `preview_patient_charge` | |
| `bot_create_charge(p_phone, p_patient jsonb, p_amount, p_concept, p_beneficiary_name, p_idempotency_key, p_currency default 'USD')` | `create_patient_charge` | **Sin PIN** desde 20261013000200 (Javier, 2026-10-13): basta el número registrado; la orden no es deuda hasta el "Sí" del paciente. Devuelve `{ok: true, charge}`; los errores de negocio lanzan como en el panel. Sede: la del `cajero` o la principal del `gerente`. `charges.channel = 'whatsapp'` |
| `bot_recent_charges(p_phone, p_limit int default 10)` | `merchant_transactions` | Las de los últimos 30 días con su `status`; el `cajero` ve las suyas |
| `bot_resend_confirmation(p_phone, p_charge_id)` | `staff_resend_confirmation` | |
| `bot_resend_receipt(p_phone, p_charge_id)` | `staff_resend_receipt` | |
| `bot_charge_by_order(p_phone, p_order_number bigint)` | `helios_charge_for_staff` | La orden de esa clínica por su número (para «reenviar 1042»); si no, `P0002` |
| `bot_session(p_phone) → jsonb` / `bot_session_save(p_phone, p_state, p_data)` | — | El paso de la conversación; `{state, data, nueva}`. Pasados `bot_session_minutes` (30) sin actividad, `nueva` |

Las respuestas del bot y los avisos al médico salen con
`helios_whatsapp_text(p_to, p_text, p_staff_user_id, p_buttons jsonb default '[]') → uuid`
(hasta 3 botones `{id, title}`; solo con la ventana de 24 h abierta). El
médico que registró la orden (por WhatsApp o en el panel, si tiene número del
bot) recibe `✅ … aceptó`, `❌ … no aceptó` o `⌛ … venció`
(`helios_notify_staff_of_charge`); con la ventana cerrada, solo «aceptó» y
con la plantilla `aviso_al_medico` (§4.1). El webhook llama a
`helios_dispatch_whatsapp_batch` al terminar cada evento para que salga ya.

`p_idempotency_key` del bot = `wa:<id del mensaje que confirmó la orden>`: si
360dialog reintenta el webhook, no se crea otra orden.

### 5.5 El bot del paciente (2026-10-06)

Implementado en 20261006000100; la conversación vive en
`supabase/functions/whatsapp-webhook/paciente.ts` (docs/00 §15.6). Solo para
`service_role`.

| RPC | Para qué |
|---|---|
| `bot_paciente_contexto(p_phone) → jsonb` | `{perfiles: [{id, nombre, documento, documento_enmascarado}], elegido, estado, humano, menu_reciente}`: los pacientes con ese teléfono, a quién identificó por su cédula, si espera la cédula, si lo atiende una persona y si vio el menú en las últimas 2 h |
| `bot_paciente_guardar(p_phone, p_menu, p_humano_horas, p_estado, p_profile_id) → void` | Solo cambia lo que viene. `p_humano_horas` 0 despierta al bot; `p_estado` '' lo limpia |
| `bot_paciente_resumen(p_profile_id) → jsonb` | `{nombre, financiamientos: [{orden, clinica, consulta, cuotas: [{sequence, due_date, monto, cargo_atraso, vencida}]}], tasa_bcv, cuentas_de_cobro, pago_en_revision}`. Montos con el cargo por servicio: es para el paciente |
| `helios_whatsapp_patient_text(p_to, p_text, p_profile_id default null, p_buttons default '[]') → uuid` | Encola la respuesta (plantilla interna `bot_paciente`); `p_profile_id` null para quien escribe sin ser paciente. Solo con la ventana de 24 h abierta |

`whatsapp_contacts` gana `bot_menu_at`, `human_until`, `patient_profile_id`
y `patient_state`.

### 5.6 Los mensajes y los montos (2026-10-06, completa §4)

- `helios_money_text` escribe al estilo venezolano: «100», «1,92»,
  «1.250,50» (sin «,00» si es entero). Lo usan WhatsApp, el correo y los
  textos de error. `helios_pct_text(numeric)`: «20», «12,5».
- `confirmar_financiamiento`: texto nuevo con el **total con el cargo por
  servicio** (al paciente sí, decisión del 2026-10-06; a la clínica nunca).
  Variables nuevas: `servicio_pct`, `iva_pct`, `total`, `cuotas_monto`
  («$56,96», o «$56,97 y $56,96» si difieren en un céntimo) y
  `cuotas_fechas` («12/10 y 19/10»). Botones «Sí» / «No». La plantilla de
  Meta sigue siendo la v1 (6 variables) hasta que se apruebe la v2 (docs/00
  §15.5.1).
- `bienvenida`: texto nuevo («🩺 ¡Listo, {nombre}! Tu financiamiento #{orden}
  ya está activo…»); `{cuotas}` llega como «* $56,96 — 12/10/2026», una línea
  por cuota.

## 7. La consulta se cobra en dólares o en euros (2026-10-07)

Migraciones `20261007000100`–`000600`. Decisión de Javier: el médico elige la
moneda en el paso del monto; **una orden en euros queda en euros** (el
paciente paga cada cuota en Bs a la tasa BCV del euro del día en que paga; a
la clínica se le paga en Bs a la tasa del euro). El libro, el límite, el
mínimo, la mora, las métricas y el superadmin siguen en **dólares**: las
columnas `_usd` son dólares, literalmente; los montos en la moneda de la orden
van en columnas `_cur`.

### 7.1 Tasas

- `exchange_rates`: serie `BCV` (dólar) y `BCV_EUR` (euro). `fx_rate_sources.series`
  y `fx_rate_syncs.series` dicen de cuál es cada espejo e intento.
- `sync_fx_rate(p_effective_date, p_force)` trae las dos; devuelve la del dólar
  con la del euro en `eur`. El cuerpo vive en `helios_sync_fx_series(serie, …)`.
- `fx_rate_status(p_source)` acepta `BCV` o `BCV_EUR`.
- `admin_set_fx_rate(p_rate, p_effective_date, p_note, p_currency default 'USD')`.
- `admin_fx_rate_history(p_limit, p_currency default 'USD')`.
- `helios_fx_today() → { business_date, usd: {rate, effective_date}, eur: {…}, usd_per_eur }`
  (cualquiera con sesión).
- Internas: `helios_fx_series`, `helios_fx_rate(moneda, día)` (Bs por unidad),
  `helios_usd_per_unit(moneda, día)` (tasa cruzada, 6 decimales).

### 7.2 Registrar

- `preview_patient_charge(p_merchant_id, p_document, p_amount, p_currency)` y
  `create_patient_charge(p_merchant_id, p_branch_id, p_patient, p_amount, p_concept,
  p_beneficiary_name, p_idempotency_key, p_currency)`: `p_amount` en la moneda
  elegida (antes `p_amount_usd`). El mínimo (`min_charge_usd`) y el cupo se
  miden en dólares con la tasa cruzada de hoy y se dicen en la moneda
  («El monto mínimo es €8,89», «El monto supera lo disponible (€133,33).»).
- La vista previa añade `currency`, `fx_usd_per_unit`, `tasa_bcv` (Bs por unidad),
  `base_cur`, `consumer_fee_cur`, `consumer_fee_vat_cur`, `disponible_cur`,
  `limite_cur` e `installments[].{amount_cur, financed_cur, amount_ves}`. Sigue
  sin ningún total con la comisión.
- `helios_charge_for_staff` añade `currency`, `merchant_sale_cur`, `tasa_bcv`,
  `breakdown.{base_cur, consumer_fee_cur, consumer_fee_vat_cur}` e
  `installments[].{amount_cur, amount_ves}`.
- `bot_preview_charge(p_phone, p_document, p_amount, p_currency)` y
  `bot_create_charge(…, p_amount, …, p_currency)`; `bot_patient_eligibility`
  añade `usd_per_eur`.
- `staff_resend_confirmation` al reabrir una orden vencida la vuelve a pasar a
  dólares con la tasa de ese día (los euros no cambian).

### 7.3 Columnas

- `charges`: `currency` ('USD'|'EUR'), `fx_usd_per_unit` (1 en dólares),
  `base_cur`, `consumer_fee_cur`, `consumer_fee_vat_cur`, `amount_cur`,
  `merchant_net_cur`. En una orden en dólares un trigger copia `_usd` → `_cur`.
- `installments`: `amount_cur`, `financed_cur` (trigger al insertar: la mitad de
  `amount_cur` en la primera, el resto en la segunda).
- `settlements`: `currency`, `amount_cur`, `paid_cur` (trigger al insertar: la
  consulta en la moneda de la orden; la comisión del personal en dólares).
- `merchant_payout_items`: `currency`, `amount_cur`. `merchant_payouts`:
  `amount_eur`, `fx_rate_eur`.
- `payment_quotes`: `amount_eur`, `fx_rate_eur`. `payment_quote_items`:
  `currency`, `amount_cur`.

### 7.4 Pagos

- El paciente **solo paga en bolívares**: `admin_register_payment` y
  `report_payment` aceptan `pago_movil` | `transferencia` (banco, referencia y
  Bs obligatorios); `admin_set_payment_destination` ya no acepta Zelle (las de
  Zelle se apagaron); `helios_payment_accounts_text` solo lista las de bolívares.
- `helios_quote_installments`: lo de dólares (cuotas en dólares + cargos por
  atraso) a la tasa del dólar y lo de euros a la del euro. `admin_register_payment`
  recotiza con las tasas del día del pago (`helios_reprice_quote`).
- `admin_payment_preview(p_user, p_installment_ids, p_paid_on) → { paid_on,
  installments_usd, late_fee_usd, amount_usd, amount_eur, amount_usd_part,
  fx_rate, fx_rate_eur, amount_ves }` (solo el equipo).
- `admin_report_merchant_payout`: sin Bs ni tasa, los calcula por moneda con la
  tasa BCV de cada una del día del pago; una tasa escrita vale solo si lo
  marcado es de una sola moneda. Devuelve `amount_eur`, `fx_rate_eur`.
- Lecturas con moneda: `admin_merchant_settlements` (`currency`, `amount_cur`,
  `paid_cur`, `pending_cur`, `pending_ves_hoy`), `admin_merchant_payouts` y
  `admin_payout_detail` (`amount_eur`, `fx_rate_eur`, items `currency`,
  `applied_cur`), `admin_charge_detail` (`currency`, `fx_usd_per_unit`, `*_cur`),
  `admin_user_detail` (cuotas y órdenes con `currency` y `*_cur`),
  `merchant_transactions` (+ `currency`, `merchant_sale_cur`),
  `merchant_charge_detail` (`currency`, `*_cur`, payouts por moneda).

### 7.5 Mensajes

- Las variables de dinero traen su símbolo («€56,96», «$2»); las plantillas
  ya no llevan «$» delante. `monto_cuota` de los avisos y `monto` de
  `pago_recibido` llevan además los Bs: «€56,96 (Bs 51.264,00)». Variables
  nuevas: `total_bs`, `moneda` («dólar» | «euro», por defecto «dólar»).
- `bot_paciente_resumen`: cada orden con `moneda`, la consulta y las cuotas en
  ella (el cargo por atraso en dólares), y `tasa_bcv` + `tasa_bcv_eur`.

## 8. El archivo de pago masivo del banco (2026-10-14)

A las clínicas se les paga con el «pago masivo a proveedores» del banco: un
.xlsm (la plantilla del banco, con su macro, en
`panel/public/plantillas/pago-masivo.xlsm`) con una transferencia
por fila en la hoja «Validar Datos». Lo arma el superadmin desde «Pagos a
clínicas» → «Por pagar» → «Archivo del banco», que sustituye al CSV.

- `admin_bulk_payout_sheet() → jsonb` (solo el equipo, solo lee):
  `{ today_date, fx_rate_usd, fx_rate_eur, debit_account, merchants[] }`.
  `debit_account` es la primera cuenta de cobro activa de transferencia
  (`{bank_name, holder_name, rif, account_number}` o null), como sugerencia de
  la cuenta a debitar. Cada clínica con algo en el pago de hoy trae
  `merchant_id, merchant_name, is_test, email, has_payout_account, bank,
  account_holder, holder_document, account_number, pago_movil_phone, lineas,
  pending_usd, pending_usd_part, pending_eur, pending_ves`. Las líneas son las
  de `in_next_run` (lo pendiente que vence antes del pago de hoy: lo mismo que
  «Sale hoy»); `pending_ves` va como `admin_report_merchant_payout` sin tasa
  escrita (cada moneda a su BCV de hoy, redondeada y sumada), null si falta
  una tasa.
- Solo transferencia: una clínica sin cuenta de 20 dígitos (solo Pago Móvil o
  sin cuenta), con un documento que no sea V/E/J/G de hasta 10 caracteres o
  sin tasa queda fuera, dicha, y se le paga a mano. Las de prueba no entran.
- Las columnas: fecha de pago (≥ hoy), cuenta a debitar, cuenta del
  beneficiario, monto en Bs, descripción (≤ 60, «Pago Helios 14/10/2026»),
  ID (`J123456789`), titular (≤ 80), correo de la clínica (si es válido) y
  referencia del cliente (`MMDD` + número de fila: `10140001`).
- Bajar el archivo guarda el lote pero no registra ninguna transferencia.
  Cuando el banco lo procesa, se registra de una vez desde «Por pagar» →
  «Registrar el pago masivo» (2026-10-14, diseño A de Javier). Lo que no va
  en el archivo se sigue registrando en la página de su clínica
  (`admin_report_merchant_payout`).

### El lote del archivo y su registro

Tablas `bulk_payouts` (el archivo: `pay_date`, `description`,
`debit_account`, `fx_rate_usd`, `fx_rate_eur`, `business_date`, totales,
`created_by`) y `bulk_payout_lines` (una fila: `row_number`, `merchant_id`,
`settlement_ids` exactas, `amount_usd`, `amount_usd_part`, `amount_eur`,
`amount_ves`, `reference`, los datos del beneficiario y `payout_id` cuando se
registra). Con RLS y sin políticas: solo se leen y escriben por estas RPC.

- `admin_create_bulk_payout(p_pay_date date, p_description text,
  p_debit_account text, p_lines jsonb) → jsonb` (super admin, MFA). Lo llama
  «Bajar el archivo» antes de bajarlo. `p_lines`: las filas en orden,
  `{ merchant_id, reference, amount_ves, beneficiary_account, beneficiary_id,
  beneficiary_name }`. Por cada una la base vuelve a calcular lo que sale hoy
  (las mismas líneas y bolívares que `admin_bulk_payout_sheet`) y guarda los
  ids de esas liquidaciones; si los bolívares no son los que manda el panel
  («Lo que se le debe a … cambió desde que abriste la ventana»), no se guarda
  nada. Rechaza fecha de pago anterior a hoy, descripción vacía o de más de
  60, cuenta a debitar que no sea de 20 dígitos, clínicas de prueba, una
  clínica dos veces, referencias que no sean números de hasta 10 dígitos o
  repetidas y beneficiarios que el banco no acepta. Bitácora
  `merchant.bulk_payout_file`. Devuelve `{ ok, bulk_payout_id, lines,
  total_usd, total_ves }`.
- `admin_bulk_payouts(p_limit int default 10) → jsonb` (solo el equipo, solo
  lee): los últimos archivos, del más nuevo al más viejo, `{ id, pay_date,
  description, debit_account, fx_rate_usd, fx_rate_eur, business_date,
  total_usd, total_ves, created_at, created_by_name, lines[] }`, cada línea
  `{ id, row_number, merchant_id, merchant_name, settlements, amount_usd,
  amount_usd_part, amount_eur, amount_ves, reference, beneficiary_account,
  beneficiary_id, beneficiary_name, state, payout_id, payout_reference,
  registered_at }`. `state`: `registrada` (tiene su transferencia),
  `pendiente` (sus liquidaciones siguen sin pagar y deben lo mismo: se puede
  registrar) o `cambio` (algo de ellas se pagó por otro lado: se revisa a
  mano).
- `admin_register_bulk_payout(p_bulk_payout_id uuid, p_lines jsonb, p_note
  text default null) → jsonb` (super admin, MFA). `p_lines`: las líneas que
  el banco pagó, `{ line_id, reference? }`; sin `reference` va la del
  cliente del archivo. En UNA transacción, por cada línea en el orden del
  archivo llama a `admin_report_merchant_payout` con método
  `transferencia`, sus liquidaciones, sus dólares, sus bolívares, la fecha de
  pago del archivo y la nota (`p_note` o la descripción), y deja en la
  transferencia las tasas del archivo. Todo o nada: una línea en `cambio` o
  que no es del archivo hace fallar el registro entero, y un archivo cuya
  fecha de pago aún no llegó no se registra. Idempotente: el lote y cada
  línea se bloquean al registrar, y una línea que ya tiene `payout_id` se
  salta (cuenta en `already_registered`). Bitácora `merchant.bulk_payout`
  (más la `merchant.payout` de cada transferencia). Devuelve `{ ok,
  registered, already_registered, total_usd, total_ves, payouts[] }`, cada
  una `{ line_id, merchant_id, payout_id, reference, amount_usd,
  amount_ves }`.

## 9. Capacitaciones: números de WhatsApp de prueba (2026-10-14)

Migraciones `20261014100000_la_orden_de_un_paciente_de_prueba_no_se_liquida`,
`20261014100200_los_numeros_de_capacitacion` (que sustituye a los
pacientes demo fijos de `20261014100100`) y
`20261014100300_lo_de_capacitacion_se_borra_a_medianoche`. Pantalla: Ajustes ›
Capacitaciones › Números de capacitación (`?tab=demo`).

En la capacitación el médico hace el proceso entero en su propia clínica, con
su panel o su bot: registra un **paciente nuevo** con datos inventados y,
como teléfono, el WhatsApp de quien capacita. Ese paciente nace de prueba y
la pregunta le llega a quien capacita.

- **Las órdenes de un paciente de prueba no se liquidan**: el trigger
  `settlements_aa_paciente_de_prueba` descarta toda fila de `settlements`
  cuya orden (o cuota) sea de un paciente `is_test`, y
  `helios_accrue_staff_commission` no devenga la comisión del personal. Una
  clínica de prueba con un paciente real sigue como antes.
- `demo_phones (phone_e164 pk, label, created_at, created_by)`. El trigger
  `profiles_demo_por_telefono` (BEFORE INSERT) marca `is_test` e `is_demo`
  a todo paciente que nazca con uno de esos números. Nivel 1, límite real.
  Varios pacientes pueden compartir el número.
- **Lo de capacitación no entra al libro**: `helios_finalize_charge` no
  escribe el asiento ni el adelanto de una orden de un paciente `is_demo`
  (sí sus cuotas, el comprobante, la bienvenida y el aviso al médico).
- Reinicio: `helios_demo_reset(p_phone text default null, p_actor uuid
  default null) → { anuladas, revertidas, borrados, ordenes_borradas,
  retirados, sin_reiniciar[{ charge_id, order_number, motivo }] }`
  (interna). En orden: anula las órdenes demo `pending`; revierte con
  `helios_demo_reverse_charge` las `confirmed` que sí tienen asiento (las de
  antes de 20261014100300); **borra** con `helios_demo_purge(p_phone)` a
  todo paciente demo sin rastro en el libro, sin cuotas pagadas, sin pagos
  reportados y sin liquidaciones, con todo lo suyo (cotizaciones, cuotas,
  mensajes, órdenes, notificaciones, límite, consultas de cédula; las
  sesiones del bot que lo recordaban vuelven al menú y los contactos de
  WhatsApp se quedan sin paciente); y **retira** (sin cédula,
  `profiles.demo_retired_at`) a los que quedan por tener historia en el
  libro. La cédula vuelve a ser «nuevo». Nunca toca el libro ni la
  bitácora. Cada reinicio deja fila en `demo_resets`; el manual, además,
  `demo.reset` en la bitácora. Cron `helios_demo_reset` a medianoche de
  Caracas (`0 4 * * *` UTC).
- `admin_demo_phones() → { phones[{ phone_e164, label, created_at, patients,
  open_orders, pending_orders }], last_reset{ at, automatic, detail } | null }`
  (personal de Helios). `patients` cuenta los no retirados.
- `admin_add_demo_phone(p_phone text, p_label text) → { phone_e164, label }`
  (super admin). Rechaza un número repetido o el de un paciente real.
  Bitácora `demo.phone_added`.
- `admin_remove_demo_phone(p_phone text) → void` (super admin). Lo ya creado
  sigue siendo demo y se borra a medianoche. Bitácora `demo.phone_removed`.
- `admin_reset_demo(p_phone text default null) → jsonb` (super admin; null =
  todos). Devuelve lo mismo que `helios_demo_reset`.

## Los mensajes al paciente, más cercanos (20261019000100 a 20261019000300)

- `merchants.doctor_title` ('Dr.', 'Dra.', 'Lcdo.', 'Lcda.' o null): el
  título delante del nombre del titular en los mensajes a sus pacientes
  (20261019000300 sustituye a `doctor_display_name`, que se borró).
  `admin_merchant_detail.profile` añade `doctor_title` y `doctor_name` (cómo
  lo leen sus pacientes); `admin_set_merchant_owner(p_merchant_id, p)`
  acepta la clave `doctor_title` (null = no tocar, '' = borrar; otro valor,
  `22023`). Internas: `helios_person_name_text(text)` (mayúsculas
  arregladas, sin un «Dr.» escrito delante), `helios_doctor_name(merchant)
  → text` («Dra. Nadia Andi Khabbaze Alfaro»; sin titular, el nombre de la
  clínica) y `helios_doctor_ref(merchant) → text` («la Dra. …», «el Dr. …»).
- Internas del bloque de pago: `helios_rif_text(text)`,
  `helios_level_reminder()`, `helios_payment_accounts_block()` y
  `helios_payment_block(p_ves, p_equivalente, p_moneda, p_por)`.
  `helios_message_builtins` añade `datos_de_pago`, `pago_movil_banco`,
  `pago_movil_telefono`, `pago_movil_rif` y `pago_movil_titular`.
- Variables nuevas: `confirmar_financiamiento` (`medico`, `cuotas_lista`,
  `cuotas_detalle`), `bienvenida` (`medico`, `bloque_de_pago`) y los avisos
  de cuota (`medico`, `monto`, `monto_bs`, `bloque_de_pago`). Las de antes
  siguen: las usan las plantillas de Meta conectadas.
- `bot_paciente_resumen(p_profile_id)`: cada orden añade `medico`,
  `medico_ref` y `pagadas[{sequence, due_date, monto}]`; arriba,
  `disponible_usd`, `bloqueo` y `datos_de_pago`. 20261023000100 añade
  `nivel`, `nivel_nombre` («Nivel 1») y `limite_usd` (el tope mensual de su
  nivel, de `levels`: el «saldo total») y quita `terminados`.
- `bot_paciente_contexto(p_phone)` añade `vencida_texto`: la respuesta a un
  «sí»/«no» escrito si su orden venció sin respuesta en las últimas 12 h.
- `helios_patient_decision` contesta al paciente (si su ventana está
  abierta) al decir «No», al contestar tarde y si la orden no se confirma;
  `notify_payment_result`, además del correo, le escribe con la ventana
  abierta (`helios_payment_result_whatsapp`). Ambos por `helios_tell_patient`,
  que nunca tumba lo que lo llamó.
- 20261023200000: `helios_payment_accounts_block()` y
  `helios_payment_accounts_text()` ya no dicen el titular de la cuenta.
  `pago_movil_titular` sigue en `helios_message_builtins` solo para las
  plantillas `_v2` de Meta conectadas (docs/00 §15.9).
