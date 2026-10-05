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
  WhatsApp configurado: "No podemos financiar a esta persona. Si tiene dudas,
  puede escribir a Helios." y `whatsapp_helios` null.

```jsonc
// Paciente nuevo
{ "estado": "nuevo", "min_charge_usd": 10, "limite_usd": 350 }

// Paciente conocido, puede financiar
{ "estado": "disponible",
  "disponible_usd": 212.40,
  "min_charge_usd": 10,
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

### 1.2 `preview_patient_charge(p_merchant_id uuid, p_document text, p_amount_usd numeric) → jsonb`

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

Regla de presentación: la clínica muestra `base_usd` y las dos cuotas. El fee
va solo como línea del desglose ("Servicio Helios 20% + IVA").

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
  "occupation": null,                  // opcional
  "reference_name": "María Pérez", "reference_phone": "04241234567", "reference_relationship": "Madre"
}
```

Implementado en 20261003000400 (+ 000500). Precisiones:

- Sede: el `gerente` registra en cualquier sede activa de su clínica (null =
  la principal); el `cajero`, solo en la suya (null = la suya; otra → `42501`
  "No tienes permiso para registrar en esa sede"). Una sede de otra clínica o
  inactiva → `22023`.
- Igual que la vista previa, exige haber consultado la cédula en las últimas
  24 h ("Primero consulta la cédula del paciente").
- `reference_phone` acepta móvil **o fijo** venezolano (02XX…), se guarda en
  E.164 y no puede ser el teléfono del paciente. `sex` admite minúsculas.
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
| "Teléfono móvil inválido" / "Correo inválido" / "Falta el contacto de referencia" | Datos del paciente |
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
  (`[{sequence, due_date, run_date, paid_to_merchant_on}]`: **no** incluye el
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
| pending_usd | numeric | por pagar en el próximo lunes |

El `gerente` ve todas; el `cajero`, solo su fila.

`merchant_commission_items(p_from date, p_to date, p_staff_user_id uuid default null) → table`:
`charge_id, order_number, created_at, amount_usd, status ('devengada'|'pagada'|'revertida'), payout_id, paid_on, staff_user_id, staff_name, business_date`.

Implementado en 20261003000500. El rango es el día operativo del
financiamiento. `merchant_commissions` no cuenta las revertidas; `paid_usd`
cuenta también lo pagado en transferencias parciales. Una comisión pasa a
`pagada` cuando su liquidación queda pagada entera. `paid_on` solo viene si
está `pagada`.

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
- `merchant_staff_add` / `merchant_staff_update`: el rol `inventario` se
  rechaza (`22023`).
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
  has_pin, pin_locked, last_inbound_at, created_at, created_by_name,
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
- `admin_reset_staff_pin(p_user_id uuid, p_reason text) → jsonb`. Borra el PIN
  y el bloqueo; el bot pedirá crear otro en el próximo mensaje. Bitácora
  `staff.pin_reset`.
- Dar de baja a una persona (`merchant_staff_update` → inactiva) revoca su
  número.

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
| `staff_pin_max_attempts` | 5 | intentos de PIN antes del bloqueo |
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
- Avisos al médico que registró por WhatsApp (canal `whatsapp`, plantilla
  interna `bot_respuesta` = `{texto}`, **solo texto libre**: si su ventana de 24 h
  está cerrada se omiten y el resultado queda en el panel): aceptada, rechazada
  y vencida (§5.4).
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
| `whatsapp_inbound` | Cada evento recibido, crudo (`wa_message_id` único). El texto de un PIN se guarda como `[PIN]` |
| `whatsapp_contacts` | Por número: `last_inbound_at` (la ventana de 24 h), `profile_id` / `staff_user_id` si se conoce |
| `whatsapp_sessions` | Estado de la conversación del bot por número (`state`, `data jsonb`, `updated_at`). La Edge Function la lee y la escribe directamente |
| `staff_whatsapp_numbers` | Número → persona y clínica (§2.7) |
| `staff_pins` | `user_id`, `pin_hash` (bcrypt), `failed_attempts`, `locked_at`, `set_at` |

`charges` gana `channel` (`panel` | `whatsapp`), `answered_at` y
`answer_wa_message_id` (la prueba del "Sí").

### 5.2 Del webhook

- `helios_whatsapp_inbound(p_message_id text, p_from text, p_type text, p_payload jsonb) → jsonb`.
  Guarda el evento (si ya estaba: `{duplicate: true}` y no se hace nada más),
  actualiza `whatsapp_contacts` y devuelve lo que hace falta para enrutar:
  `{duplicate, staff: {user_id, staff_name, merchant_id, merchant_name, role, has_pin, pin_locked} | null,
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
| `bot_set_pin(p_phone, p_pin text) → jsonb` | — | Solo si no tiene PIN. 4 dígitos, no triviales (`22023` "Elige un PIN menos obvio") |
| `bot_patient_eligibility(p_phone, p_document)` | `helios_patient_eligibility` | `p_merchant_id` sale del número |
| `bot_preview_charge(p_phone, p_document, p_amount_usd)` | `preview_patient_charge` | |
| `bot_create_charge(p_phone, p_pin, p_patient jsonb, p_amount_usd, p_concept, p_beneficiary_name, p_idempotency_key)` | `create_patient_charge` | Verifica el PIN primero y **no lanza** si está mal (un error desharía el intento contado): devuelve `{ok: false, error: "pin", message, attempts_left, locked}`. Al 5.º fallo se bloquea. Con el PIN bien devuelve `{ok: true, charge}`; los errores de negocio lanzan como en el panel. Sede: la del `cajero` o la principal del `gerente`. `charges.channel = 'whatsapp'` |
| `bot_recent_charges(p_phone, p_limit int default 10)` | `merchant_transactions` | Las de los últimos 30 días con su `status`; el `cajero` ve las suyas |
| `bot_resend_confirmation(p_phone, p_charge_id)` | `staff_resend_confirmation` | |
| `bot_resend_receipt(p_phone, p_charge_id)` | `staff_resend_receipt` | |
| `bot_charge_by_order(p_phone, p_order_number bigint)` | `helios_charge_for_staff` | La orden de esa clínica por su número (para «reenviar 1042»); si no, `P0002` |
| `bot_session(p_phone) → jsonb` / `bot_session_save(p_phone, p_state, p_data)` | — | El paso de la conversación; `{state, data, nueva}`. Pasados `bot_session_minutes` (30) sin actividad, `nueva` |

Las respuestas del bot y los avisos al médico salen con
`helios_whatsapp_text(p_to, p_text, p_staff_user_id, p_buttons jsonb default '[]') → uuid`
(hasta 3 botones `{id, title}`; solo con la ventana de 24 h abierta). El
médico que registró por WhatsApp recibe `✅ … aceptó`, `❌ … no aceptó` o
`⌛ … venció` (`helios_notify_staff_of_charge`); con la ventana cerrada, el
resultado queda en el panel. El webhook llama a
`helios_dispatch_whatsapp_batch` al terminar cada evento para que salga ya.

`p_idempotency_key` del bot = `wa:<id del mensaje que llevó el PIN>`: si
360dialog reintenta el webhook, no se crea otra orden.
