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
- Límite: `eligibility_lookups_per_staff_day` (60) por usuario y día. Pasado
  el límite lanza `22023` "Llegaste al límite de consultas de hoy" y crea la
  alerta `consultas_de_cedula_excesivas`.
- Cada llamada queda en `eligibility_lookups`.

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
lanza `55000` con el texto de `helios_spend_block`.

### 1.2 `preview_patient_charge(p_merchant_id uuid, p_document text, p_amount_usd numeric) → jsonb`

Vista previa sin efectos. Valida el monto (≥ `min_charge_usd`, ≤ 2 decimales)
y, si el paciente existe, que quepa en su disponible.

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

Respuesta: `helios_charge_for_staff(id)`.

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

### 1.4 `staff_resend_receipt(p_charge_id uuid) → jsonb`

Solo personal de esa clínica, 3 veces al día por financiamiento. Encola otro
`comprobante_financiamiento` al correo **registrado** del paciente.

```jsonc
{ "ok": true, "email_enmascarado": "j***@gmail.com", "status": "pendiente" }
```

### 1.5 Cambian de forma (heredadas)

- `merchant_transactions(p_from date, p_to date)`: cada fila añade
  `concept`, `beneficiary_name`, `receipt_status`, `staff_commission_usd` y
  `registered_by_name`. `merchant_sale_usd` sigue siendo la base sin fee.
  Desaparece `payer_count` (era de grupos).
- `merchant_charge_detail(p_charge_id uuid)`: añade `concept`,
  `beneficiary_name`, `receipt` (`{status, sent_at, last_event}`),
  `staff_commission_usd`, `commission_staff_name`. **No** incluye el estado de
  pago de las cuotas del paciente, solo sus fechas y cuándo se paga a la
  clínica (`paid_to_merchant_on`).
- `merchant_settlement_outlook()` y las transferencias recibidas
  (`merchant_payouts`, `merchant_payout_items`): cada ítem trae
  `reason` ∈ {`scheduled_installment`, `staff_commission`}, y la transferencia
  trae `consultas_usd` y `comisiones_usd`.
- `merchant_sales_by_staff(p_from, p_to)`: se mantiene y añade
  `commission_usd`.

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
`charge_id, order_number, created_at, amount_usd, status ('devengada'|'pagada'|'revertida'), payout_id, paid_on`.

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
registró no puede aprobarlo (`42501`), salvo un `super_admin`.

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

`admin_mark_outbound(p_id uuid, p_status text, p_note text default null) → void`.
Operador o super_admin. `enviado` también escribe en `collection_contacts`
(canal whatsapp). `omitido` exige nota.

`admin_outbound_history(p_channel text, p_status text, p_q text, p_limit int, p_offset int) → table`.
Incluye los correos: `email`, `provider_id`, `last_event`, `attempts`.

`admin_resend_receipt(p_charge_id uuid, p_email text default null) → jsonb`.
Si viene `p_email`, además corrige el correo del paciente (queda en la
bitácora).

### 2.3 Contacto de Helios y cuentas de cobro

- `admin_platform_contact() → jsonb`: devuelve `{whatsapp_number, support_email, support_hours, sender_name, sender_email, updated_at, updated_by_name}`.
- `admin_set_platform_contact(p jsonb) → jsonb`. Solo super_admin; queda en la bitácora.
- `admin_payment_destinations() → table` (heredada) y
  `admin_set_payment_destination(...)`: la de Ronda más `p_sort_order int` y
  `p_is_active boolean`. Puede haber **varias activas**.
- `helios_config_status() → jsonb`: `{whatsapp: bool, cuentas_de_cobro: int, resend: bool, remitente: bool}`. La usa el aviso de "configuración incompleta" del Inicio.

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
  y `admin_resolve_profile_change(p_id uuid, p_approve boolean, p_note text)`.

### 2.5 Clínicas

- `admin_create_merchant(...)` (heredada) añade `p_specialty`, `p_mpps_number`,
  `p_phone`, `p_email` y `p_address`. `p_category` usa los valores nuevos
  `clinica | consultorio | odontologia | laboratorio | imagenes | otros`.
- `admin_merchant_payout_account(p_merchant_id) → jsonb` y
  `admin_set_merchant_payout_account(p_merchant_id, p jsonb) → jsonb`
  (`bank`, `account_holder`, `holder_document`, `account_number`, `pago_movil_phone`, `pago_movil_bank`).
- `admin_set_settlement_terms(...)` (heredada) añade
  `p_staff_commission_usd numeric default null`. `null` significa que usa el
  parámetro global.
- `admin_merchant_payables()` / `admin_payout_detail()` (heredadas): cada
  línea trae `reason`, y los totales se separan en `consultas_usd` y
  `comisiones_usd`.

### 2.6 Alertas

`admin_risk_alerts(...)` (heredada) añade estos `kind`:

- `telefono_repetido`, `correo_repetido`, `correo_rebotado`;
- `rafaga_de_altas`, `rafaga_de_pacientes_nuevos`, `secretaria_concentrada`;
- `impago_primera_cuota_clinica`, `exposicion_clinica`;
- `referencia_repetida`, `cupo_al_limite_al_estrenar`, `consultas_de_cedula_excesivas`.

Cada fila trae:
- `kind`, `severity` (`alta`/`media`), `subject_type` (`paciente`/`clinica`/`personal`), `subject_id`, `subject_name`;
- `detail jsonb`, `first_seen_at`;
- `reviewed`: se marca con `admin_review_risk_alert`, que es heredada.

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

## 4. Plantillas de mensajes (`notification_templates`)

| key | canal | cuándo |
|---|---|---|
| `comprobante_financiamiento` | email | al confirmar (y al reenviar) |
| `bienvenida` | whatsapp_manual | al confirmar |
| `cuota_manana` | whatsapp_manual + email | víspera, 19:00 |
| `cuota_hoy` | whatsapp_manual | día del vencimiento, 08:00 |
| `cuota_vencida_d1` | whatsapp_manual | +1 día |
| `cargo_por_atraso_d4` | whatsapp_manual | +4 días |
| `pago_recibido` / `pago_rechazado` | whatsapp_manual | al conciliar o rechazar |
| `cuenta_congelada` | whatsapp_manual | al pasar a `frozen` |

Variables disponibles:
- del paciente: `{nombre}`;
- del financiamiento: `{clinica}`, `{orden}`, `{monto_cuota}`, `{fecha}`, `{cuotas}`;
- de configuración: `{whatsapp_helios}`, `{cuentas_de_cobro}`;
- `{tasa_bcv}` y `{monto_bs}` (a la tasa del día).
