# Helios — Plan de implementación

> BNPL para consultas médicas en Venezuela. Solo web, sin app móvil.
> 0% inicial · 2 cuotas semanales (7 y 14 días) · nivel 1 = **$350** · anclado al **dólar BCV**.
> Hermano de Ronda: mismo núcleo (libro contable, mora, liquidaciones, conciliación, paneles), sin nada de la app.

Fecha: 2026-09-30 · Fuente: Ronda-panel @ `f3b5c6a` (2026-09-29) y Ronda-app/supabase @ `20260929140000` (354 migraciones).

---

## 0. Resumen ejecutivo

Helios es **Ronda sin la app**. Se reutiliza tal cual el 70-80% del backend y del panel. Estas son las cuatro cosas que cambian de verdad:

| # | Ronda | Helios |
|---|---|---|
| 1 | El cliente se registra en la app (OTP, PIN, KYC Didit) y "reclama" el cobro escaneando un QR | **La secretaria registra al paciente y la consulta en un solo paso.** No hay QR, ni PIN, ni KYC, ni login del paciente. Al confirmar, al paciente le llega **por correo un comprobante del financiamiento** con sus cuotas, fechas e instrucciones de pago |
| 2 | El cliente reporta sus pagos desde la app | **El paciente paga y manda el comprobante por WhatsApp al equipo Helios**, que lo **registra en el superadmin**. Desde ahí sigue la misma cola de conciliación de Ronda |
| 3 | Avisos por push (Expo) | **Avisos por WhatsApp operados por el equipo**: una cola diaria de mensajes con plantillas y un enlace `wa.me` de un clic. La automatización con WhatsApp Cloud API queda para la fase 2 |
| 4 | — | **Comisión a la secretaria** ($0,50, modificable) por cada financiamiento confirmado. Se devenga al confirmar y **se paga dentro de la liquidación semanal a la clínica** |

Además cambian estas cosas:
- La moneda pasa del euro BCV al **dólar BCV**.
- El día operativo pasa de "10 AM a 10 AM" a **medianoche**.
- Solo está activo el nivel 1 (**$350**).
- Todo el vocabulario de la interfaz cambia (local → clínica, consumo → financiamiento, usuario → paciente, cajero → secretaria).

**Estrategia técnica:**
1. **No se reproducen las 354 migraciones.** Se consolida el estado final de Ronda en una **migración base**, se **podan** con un script los objetos exclusivos de la app y se valida con `plpgsql_check`.
2. Encima de esa base van **migraciones pequeñas y propias de Helios**.
3. El panel se copia de Ronda-panel y se poda con el mismo criterio.
4. Todo vive en **un solo repositorio**, porque ya no hay app que obligue a separarlo.

---

## 1. Decisiones tomadas

| Tema | Decisión | Origen |
|---|---|---|
| Moneda | **Dólar BCV.** Precios, límites, deuda y cargos en USD, cobrados en Bs a la tasa BCV del dólar del día de pago | Javier, 2026-09-30 |
| Aceptación del paciente | **Solo la registra la secretaria.** Sin OTP, sin enlace, sin documento firmado. Al confirmar se envía al **correo del paciente** un comprobante del financiamiento | Javier, 2026-09-30 |
| Pago y reporte del paciente | **Por WhatsApp al equipo Helios**, que registra el pago en el superadmin | Javier, 2026-09-30 |
| Comisión de la secretaria | **Se suma a la liquidación de la clínica**, y la clínica se la entrega a su personal | Javier, 2026-09-30 |
| Antifraude | **Solo alertas automáticas.** Los topes por clínica, la retención de liquidaciones y el expediente con fotos se evaluarán después (§14) | Javier, 2026-09-30 |
| Privacidad entre clínicas | Una clínica que busca una cédula solo ve el nombre enmascarado y "disponible $X" o "no disponible", nunca la deuda ni el motivo | Javier, 2026-09-30 |
| Avisos | **5 momentos** por vencimiento (§7.2), no los 12 de Ronda | Javier, 2026-09-30 |
| Fee | **20% + IVA** al paciente, 0% a la clínica | Javier, 2026-09-30 |
| Liquidación a la clínica | Igual que Ronda **por ahora**: 50% al vencer cada cuota, pagado los lunes, cobre Helios o no | Javier, 2026-09-30 |
| Cuentas de cobro de Helios | **Configurables** desde Ajustes, como en Ronda; se llenan después | Javier, 2026-09-30 |
| WhatsApp de Helios | **Configurable** desde Ajustes | Javier, 2026-09-30 |
| Cuotas | 0% inicial, 2 cuotas a +7 y +14 días desde la fecha del financiamiento | Brief |
| Niveles | Motor de niveles igual que Ronda. Solo el **nivel 1 ($350)** activo; los niveles 2-5 existen con `is_active = false` | Brief |
| Stack | El mismo de Ronda, sin la app: TanStack Start + Supabase + Vercel + Sentry | Brief |

### 1.1 Reglas heredadas de Ronda tal cual (por defecto, salvo que se diga lo contrario)

| Regla | Valor en Helios | Parámetro |
|---|---|---|
| Fee al paciente | **20%** sobre el monto de la consulta, **+ IVA 16%** sobre el fee | `consumer_fee_pct`, `vat_pct` |
| El fee no ocupa cupo | Se financia la consulta, no la comisión de Helios | — |
| Ejemplo con una consulta de $100 | Paciente debe **$123,20** = 2 × $61,60. Clínica recibe **$100**. Ingreso Helios $20. IVA $3,20 | — |
| Liberación de cupo | Por financiamiento: se libera al pagar **ambas** cuotas. Cualquier cuota vencida deja el disponible en $0 | — |
| Mora | Día 1: congelado. **Cargo de $2 por cuota tras 3 días de gracia.** Día 30: suspendido (y baja de nivel, que en nivel 1 no cambia nada). Día 60: expulsado, lista negra de la cédula y castigo contable | `late_fee_usd`, `late_fee_grace_days`, `mora_demotion_days`, `mora_expulsion_days` |
| Liquidación a la clínica | **100% del precio en dos mitades**: el 50% se devenga al vencer cada cuota y se paga en el **cierre de los lunes a las 10:00**, cobre Helios o no | `merchant_terms` (0/50/0, `scheduled`) |
| Monto mínimo | $10 propuesto (en Ronda eran €5; ver D-H7) | nuevo `min_charge_usd` |
| Tasa | BCV del día; fines de semana y feriados usan la última publicada; ingesta a las 10:00 con reintentos | `sync_fx_rate()` |
| Frenos de emergencia | Mantenimiento global y bloqueo manual por paciente | — |
| Bitácora | Toda acción de admin queda en `audit.admin_actions` (append-only) | — |
| Seguridad del equipo | MFA TOTP obligatorio para admins | `platform_security.require_mfa` |

---

## 2. Flujo de uso

```mermaid
sequenceDiagram
  autonumber
  participant P as Paciente
  participant S as Secretaria (panel clínica)
  participant DB as Supabase (RPC)
  participant H as Equipo Helios (superadmin)
  participant C as Clínica

  P->>S: Pide pagar con Helios
  S->>DB: helios_patient_eligibility(cédula)
  DB-->>S: Nuevo / disponible $X / no disponible
  S->>S: Datos del paciente + monto y concepto
  S->>DB: preview_patient_charge(...)
  DB-->>S: Desglose, 2 cuotas con fechas
  S->>P: Le muestra el plan en pantalla y lo confirma de palabra
  S->>DB: create_patient_charge(..., idempotency_key)
  Note over DB: Crea o bloquea al paciente, valida el cupo,<br/>asiento de 4 patas, cuotas, devengo de la<br/>comisión, alertas de riesgo
  DB->>P: Correo con el comprobante del financiamiento
  H->>P: Bienvenida + instrucciones de pago (WhatsApp)
  loop Recordatorios (cola diaria)
    H->>P: Aviso por WhatsApp (wa.me + plantilla)
  end
  P->>H: Paga (Pago Móvil o transferencia) y manda el comprobante por WhatsApp
  H->>DB: Registra el pago (admin_register_payment)
  H->>DB: Concilia contra el extracto (admin_reconcile_payment)
  DB->>DB: 10:10 diario: devenga el 50% de la clínica por cuota vencida
  H->>C: Lunes 10:00: transferencia (consultas + comisiones)
  H->>DB: admin_report_merchant_payout
```

### 2.1 Paso a paso en la clínica ("Nuevo financiamiento")

1. **Cédula** (V/E + número). La RPC `helios_patient_eligibility` responde una de tres cosas, **sin revelar la deuda ni el motivo**:
   - **Paciente nuevo**: pide todos los datos.
   - **Paciente conocido**: muestra el nombre y el teléfono enmascarados ("J\*\*\* P\*\*\*", "0414-\*\*\*-\*\*67") para confirmarlos, y el **disponible para financiar: $X**.
   - **No disponible**: "No podemos financiar a esta persona. Si tiene dudas, que escriba a Helios al …". Cubre mora, lista negra, bloqueo, mantenimiento y cupo agotado.
2. **Datos del paciente**, todos obligatorios salvo que se indique:
   - Identidad: nombres, apellidos, fecha de nacimiento (calcula la edad y **exige ≥ 18**: si quien se atiende es menor, se registra a su **representante** como titular de la deuda; D-H5) y sexo.
   - Contacto: teléfono móvil con WhatsApp (valida los prefijos 0412/0414/0416/0422/0424/0426) y **email (obligatorio: ahí llega el comprobante)**, escrito dos veces para evitar errores de tipeo.
   - Dirección: estado, ciudad y dirección corta.
   - **Contacto de referencia para cobranza**: nombre, teléfono y parentesco.
   - Opcional: ocupación.
3. **Monto y concepto**: **monto libre** en dólares (≥ `min_charge_usd`, máx. 2 decimales, y dentro del disponible) y un concepto corto opcional ("Consulta", "Consulta + eco"). **No hay catálogo** (D-H4). Opcional: "paciente atendido", si es distinto del titular (el menor que se atendió).
4. **Vista previa** (`preview_patient_charge`): monto de la consulta, 2 cuotas con fechas y el monto de cada una. El fee aparece **solo dentro de las cuotas o como línea aparte**, nunca sumado en un total (regla de Ronda).
5. **Confirmar**: `create_patient_charge`. A partir de aquí la deuda existe.
6. **Comprobante por correo**: se envía solo, en segundos (§7.3). La pantalla de éxito dice "Comprobante enviado a j\*\*\*@gmail.com" y tiene un botón **"Reenviar comprobante"**. Si el correo rebota, Helios recibe una alerta y la clínica ve el aviso "El correo del paciente no es válido" en el detalle del financiamiento.

---

## 3. Arquitectura

### 3.1 Stack (el de Ronda sin la app)

| Capa | Elección |
|---|---|
| Web (clínica + superadmin) | **TanStack Start** (Vite 8, TanStack Router y Query, React 19, Tailwind v4), el mismo kit de UI propio de Ronda |
| Backend | **Supabase Postgres 17**: RLS + RPC `security definer`, `pg_cron`, `http`, Storage y Auth (email + contraseña y MFA TOTP) |
| API | **Ninguna.** Igual que el panel de Ronda: cliente de Supabase con clave publicable, RLS y RPC. No hay Hono ni server functions |
| Deploy | Vercel (panel, preset Nitro) y Supabase (dos proyectos: `Helios` y `Helios-dev`) |
| Observabilidad | Sentry (panel) |
| Asistente IA (fase 5) | Edge Function `admin-asistente` portada de Ronda |

### 3.2 Repositorio: uno solo

Ronda tiene tres repositorios (workspace, app y panel), y sus migraciones viven en el de la app; su propio README pide sacarlas. Helios no tiene app, así que conviene **un repositorio con todo**:

```
Helios/                          ← repo git (GitHub: Helios)
├── docs/                        ← este plan, reglas de negocio, decisiones
├── tokens/                      ← helios.tokens.json + build.mjs (solo genera el panel)
├── brand/                       ← logo e isotipo (SVG)
├── panel/                       ← TanStack Start (fork de Ronda-panel)
│   ├── src/ …
│   ├── scripts/
│   ├── .env.example  .env.dev  .env.prod
│   └── vercel.json
├── supabase/
│   ├── config.toml
│   ├── migrations/              ← 1 base consolidada + migraciones de Helios
│   ├── poda/                    ← scripts reproducibles que generaron la base (trazabilidad)
│   ├── tests/                   ← suites SQL (patrón de Ronda) + run.sh
│   ├── seed.sql                 ← clínica demo, personal, admin local
│   ├── bootstrap_superadmin.sql
│   └── functions/               ← (fase 5) admin-asistente
├── scripts/
│   └── portar-de-ronda.mjs      ← transforma una migración de Ronda al vocabulario de Helios
├── .github/workflows/ci.yml     ← panel (tipos, lint, tests) + BD (supabase start + tests SQL)
└── .claude/launch.json
```

### 3.3 Nombres en la base: mantener los de Ronda

**Decisión recomendada:** la base conserva los nombres de dominio de Ronda (`profiles`, `merchants`, `charges`, `installments`, `settlements`, `*_usd`…). Solo se renombra el prefijo de marca `ronda_` a `helios_`. La interfaz habla en vocabulario médico.

- **Por qué:** así un arreglo hecho en Ronda (mora, conciliación, métricas) se porta a Helios con un script mecánico (`scripts/portar-de-ronda.mjs`: `ronda_` → `helios_`, textos "Ronda" → "Helios"), en lugar de reescribirse. Es lo que pediste: facilitar el mantenimiento.
- **Bonus:** los sufijos `_usd`, que en Ronda son un nombre histórico (hoy guardan euros), en Helios vuelven a ser literalmente ciertos.

| En la base | En la interfaz de Helios |
|---|---|
| `merchants` / `merchant_branches` | Clínica o consultorio / Sede |
| `merchant_users` (`gerente`, `cajero`) | Personal: **Administrador** / **Secretaria (recepción)** |
| `profiles` | Paciente |
| `charges` / `charge_items` | Financiamiento / Servicios |
| `installments` | Cuotas |
| `settlements` / `merchant_payouts` | Devengos / Pagos a la clínica |
| `payment_reports` | Pagos registrados |

---

## 4. Base de datos

### 4.1 Cómo se construye la migración base (fase 0)

Replicar 354 migraciones llenas de `create or replace` sucesivos (`confirm_charge` tiene 16 versiones) y luego borrar la mitad es frágil. En su lugar:

1. **Estado final reproducible de Ronda.** En local, `supabase start` + `supabase db reset` sobre `Ronda-app/supabase`. Se reproducen las 354 migraciones y el resultado es exactamente lo que dice git, sin la deriva que pueda haber en dev.
2. **Volcado de esquema.** `supabase db dump --local --schema public,ledger,audit,metricas,asistente` → `poda/00_ronda_final.sql`. Hay que añadir a mano, porque no salen en ese volcado:
   - los **jobs de `pg_cron`** (se leen de `cron.job` y se reescriben como `cron.schedule(...)`);
   - las **políticas de Storage** (`storage.objects`) y los buckets;
   - el rol `asistente_lector`, solo si se porta el asistente.
3. **Datos de configuración** (volcado de datos): `levels`, `business_parameters`, `business_parameter_catalog`, `notification_templates`, `collection_templates`, `fx_rate_sources`, `holidays`. **Nunca** datos de personas.
4. **Poda (`poda/01_…sql`).** Se hace `DROP` explícito de todo lo clase B (§4.2), **sin `CASCADE`**. Con `RESTRICT`, cualquier vista o función reutilizable que dependa de algo podado **hace fallar la poda** en vez de desaparecer en silencio. Cada fallo es una dependencia que hay que arreglar a conciencia.
5. **Renombrado de marca.** Se aplica `scripts/portar-de-ronda.mjs` al volcado podado.
6. **Validación estática.** Se activa la extensión **`plpgsql_check`** (disponible en Supabase) y se corre sobre todas las funciones. Postgres no valida los cuerpos de PL/pgSQL al crearlos, así que una función que lea `bits_entries` o `group_members` después de la poda **solo fallaría en producción**. Hay que llegar a **cero errores**.
7. **Reglas de mora y dinero.** Se portan y adaptan las suites SQL de Ronda (§9) y deben pasar en verde.
8. El resultado es `supabase/migrations/20261001000000_helios_base.sql`. Los scripts de `poda/` se versionan para poder regenerar la base si hace falta.

### 4.2 Qué se poda (clase B: exclusivo de la app o de la vida nocturna)

| Área | Tablas / objetos | Funciones (patrones) |
|---|---|---|
| PIN y dispositivos | `user_pins`, `pin_attempts`, `user_devices` | `set_user_pin`, `verify_user_pin`, `has_user_pin`, `pin_pepper`, `register_device`, `check_device_login`, `record_failed_pin_login`, `clear_pin_lockout` |
| KYC Didit | esquema `kyc` completo, buckets `kyc-documents` y `kyc-archive` | `start_kyc_verification`, `confirm_kyc_data`, `kyc_*`, `notify_kyc_rejected`, `admin_kyc_*`, `admin_review_kyc`, `admin_user_verification`, `admin_request_new_verification`; Edge Functions `kyc-*` |
| Push | `push_tokens`, `push_deliveries`, `promo_campaigns` | `register_push_token`, `dispatch_push_queue*`, `check_push_receipts*`, `enqueue_push`, `purge_push_queue`, `promo_audience`, `admin_send_promo`, `admin_promo_*` |
| Grupos / mesas | `groups`, `group_members` | `*group*`, `ronda_group_*`, `ronda_split_shares`, `ronda_payables`, `installment_not_in_a_live_group`, `installment_unlocks_at`, `my_locked_installments`, `realtime_*` |
| QR / reclamo | — | `preview_charge`, `confirm_charge` (su lógica pasa a `create_patient_charge`), `confirm_charge_as_group`, `expire_stale_charges` y su cron |
| Bits | `bits_entries` | `ronda_bits_*`, `award_bits_*`, `my_bits`, `notify_bits_earned`, trigger `installments_award_bits` |
| App | `app_release`, `app_activity`, `avatar_emojis`, `avatar_colors`, `user_payment_methods`, `account_deletion_requests` | `ronda_app_gate`, `ronda_app_releases`, `admin_set_app_release`, `log_app_activity`, `set_my_avatar`, `my_*` (la vista del usuario), `accept_terms`, `ack_level_up`, `my_pending_level_up`, `*deletion*` |
| Piloto La Quinta | `merchant_vaults`, `merchant_vault_topups`, `credit_waitlist`, `qa_case_marks` | `admin_vault_*`, `admin_waitlist*`, `ronda_waitlisted`, `ronda_settle_vaults`, `enroll_in_waitlist_on_activation`. **Ojo:** `ronda_spend_block` y el bucle de liquidaciones llaman a la bóveda y hay que limpiarlos |
| Métricas de noche o grupos | vistas de `metricas` que lean grupos, KYC o push | `admin_group_metrics`, `admin_nights`, `admin_growth_funnel` (el embudo KYC), `admin_metricas_avisos*` |
| Enums | valores `pending_kyc`, `pending_pin`, `group_charge`, `tab_*`, `bits_earned`… | Se quedan (quitar valores de un enum no compensa) pero no se usan |

### 4.3 Qué se reutiliza tal cual (clase A)

- **Libro contable** `ledger.*`:
  - partida doble, append-only;
  - balance verificado por un trigger diferido;
  - idempotencia por `idempotency_key`.
- **Deuda**:
  - `ronda_assign_debt` (el único sitio que crea deuda), `ronda_charge_breakdown`, `user_credit_blocks`;
  - `ronda_credit_used_usd`, `can_take_debt`, `ronda_in_arrears`, `available_usd`.
- **Cobro y mora**:
  - `ronda_quote_installments(p_user, …)`, `reconcile_payment`, `charge_late_fee`;
  - `recompute_profile_mora_state`, `charge_off_user_debt`, `process_mora_loop`.
- **Liquidaciones**:
  - `merchant_terms`, `settlements`, `merchant_payouts` y sus ítems;
  - `run_scheduled_settlements_loop`, `ronda_settlement_run_for`, `ronda_next_settlement_run`, `ronda_settlement_outlook`, `admin_report_merchant_payout` (acepta pagos parciales).
- **Banco**:
  - `bank_statement_lines`, `statement_imports`, `ronda_statement_candidates`;
  - `admin_import_statement`, `admin_unmatched_deposits`, `admin_assign_deposit`, `admin_link_*`, `bank_balance_checks`, `admin_cash_forecast`.
- **Tasa**: `exchange_rates`, `fx_rate_sources`, `fx_rate_syncs`, `sync_fx_rate` (con sus guardas), `admin_set_fx_rate`, `current_fx_rate`.
- **Configuración**: `business_parameters` (con vigencia), `holidays`, `levels`, `level_changes`, `evaluate_level`.
- **Cobranza y riesgo**: `collection_contacts`, `collection_templates` (por tramos), `admin_collections*`, promesas, `risk_alert_reviews`, `admin_risk_alerts`, cohortes, `cash_forecast_snapshots`.
- **Plataforma**: `platform_admins`, `platform_security`, `is_platform_admin()`, `ronda_assert_super_admin()`, `platform_maintenance`, `user_blocks`, `audit.log`.
- **Personal de la clínica**: `merchant_users`, `merchant_staff_*`, `can_manage_merchant_staff`, `admin_create_auth_account`.

### 4.4 Migraciones propias de Helios (después de la base)

Cada una es pequeña, lleva su suite de pruebas y usa nombres en español al estilo de Ronda.

**H1 — `el_precio_se_pacta_en_dolares`**
- `exchange_rates.source = 'BCV'` pasa a ser **USD**. Se reactivan las fuentes `dolarapi` (`/v1/dolares/oficial`) y `er-api` (`/latest/USD`) y se desactivan las de EUR.
- Se revisan los rangos de `fx_rate_rejection()` para el dólar.
- `levels`:

  | Nivel | Límite | Activo | Etiqueta |
  |---|---|---|---|
  | 0 | 0 | no | "Sin nivel" |
  | **1** | **350** | **sí** | — |
  | 2 | 500 | **no** | — |
  | 3 | 700 | **no** | — |
  | 4 | 1.000 | **no** | — |
  | 5 | — | no | "Próximamente" |

  Los niveles 2-4 son de ejemplo y quedan apagados; se deciden cuando se abran.
- `business_parameters`: `late_fee_usd = 2`, `min_charge_usd = 10` (nuevo, D-H7; sustituye el `check (amount_usd >= 5)` rígido).

**H2 — `el_dia_operativo_empieza_a_medianoche`**
- `helios_business_date(ts)` = `(ts at time zone 'America/Caracas')::date`, sin el desfase de −10 h pensado para la noche.
- Se añade el parámetro `business_day_offset_hours = 0` por si hiciera falta.
- Se revisan todas las funciones que llaman al día operativo o a la "noche" (métricas por hora rotadas a las 10 AM).
- La hora de los crons (tasa 10:00 → mora 10:05 → liquidaciones 10:10 → niveles 10:20) **se mantiene**: el BCV publica por la mañana.

**H3 — `el_paciente_no_tiene_cuenta`** (la adaptación más delicada)
- `profiles.id` pierde la FK a `auth.users` y pasa a `default gen_random_uuid()`. Se elimina el trigger `on_auth_user_created → handle_new_user`: ningún `auth.users` vuelve a crear un perfil.
- Las FK a `auth.users` en `charges.user_id`, `installments.user_id`, `user_credit_blocks`, `late_fees`, `payment_quotes`, `payment_reports`, `level_changes`, `notifications` y `user_blocks` se **reapuntan a `profiles(id)`**.
- `phone_e164` sigue siendo obligatorio pero **deja de ser único**: en una familia se comparte el teléfono. Un teléfono repetido dispara una **alerta de riesgo**.
- **La identidad única pasa a ser la cédula** (`document_key`, que ya es único).
- Columnas nuevas:
  - `email`, `sex`, `state`, `city`, `address`, `occupation`;
  - `reference_name`, `reference_phone`, `reference_relationship`;
  - `registered_by` (staff), `registered_merchant_id`.
- Un paciente nuevo nace `active` con `level = 1` **en el INSERT**. Ojo: `grant_first_level_on_activation` solo se dispara en UPDATE.
- Las RPC que usaban `auth.uid()` como deudor (`quote_installments`, `report_payment`, `my_*`) se podan o se sustituyen por sus variantes con `p_user` para uso del admin.

**H4 — `registrar_un_financiamiento`**: `helios_patient_eligibility`, `preview_patient_charge` y `create_patient_charge` (§5).

**H5 — `la_comision_de_la_secretaria`** (§6).

**H6 — `el_comprobante_llega_por_correo`** (§7.3)
- Canal `email` en **`outbound_messages`** (la tabla de H7), con despacho automático desde la base: `pg_cron` cada minuto + `http` hacia la API de **Resend**. Es el mismo patrón que la tasa BCV y que la cola de push de Ronda: sin runtime aparte y la cola se puede consultar y auditar.
- Columnas propias del correo: `email`, `subject`, `html`, `provider_id`, `attempts`, `next_attempt_at` (reintentos con espera creciente), `last_event` (`sent`/`delivered`/`bounced`/`complained`).
- Un cron cada 15 min consulta el estado de los enviados (el equivalente de `check_push_receipts`). Si **rebota**, marca `profiles.email_invalid_at` y crea la alerta `correo_rebotado`.
- Plantilla `comprobante_financiamiento` (HTML), versionada en `terms_versions` (H9). Cada financiamiento guarda el `terms_version_id` con el que se envió y el **HTML exacto enviado**: es la prueba de lo que se le comunicó al paciente.
- RPC `staff_resend_receipt(charge_id)`: la clínica puede reenviar, con límite de 3 al día.
- La clave de Resend vive en **Supabase Vault** (`vault.decrypted_secrets`), nunca en una tabla legible.

**H7 — `los_avisos_los_manda_una_persona`** (§7)
- Canal `whatsapp_manual` en lugar de push.
- `notify_reminder_loop` ya no encola en `push_deliveries`: crea filas en **`outbound_messages`** (`profile_id`, `charge_id`, `channel` `whatsapp_manual`/`email`, `template_key`, `due_date`, `rendered_text`, `phone`, `status` `pendiente`/`enviado`/`omitido`/`fallido`, `sent_by`, `sent_at`).
- Plantillas nuevas: `bienvenida`, `pago_recibido`, `pago_rechazado`, `cuota_manana`, `cuota_hoy`, `cuota_vencida_d1`, `cargo_por_atraso_d4`, `cuenta_congelada`.
- Las plantillas pueden usar las variables `{whatsapp_helios}` y `{cuentas_de_cobro}`, que salen de la configuración (H11).

**H8 — `el_personal_de_una_clinica`**
- `merchant_category`: se añaden `clinica`, `consultorio`, `odontologia`, `laboratorio` e `imagenes` (`otros` se mantiene).
- Columnas en `merchants`: `specialty`, `mpps_number` (opcional, médico independiente), `phone`, `email`, `address`.
- Tabla nueva **`merchant_payout_accounts`**: banco, titular, RIF o cédula, número de cuenta y teléfono de Pago Móvil. Hoy Ronda no guarda a dónde se le paga al local.
- `request_charge` se retira; el rol `inventario` queda sin uso. `products` y `product_categories` se **podan**: sin catálogo (D-H4). `charge_items` se queda con **una línea libre** por financiamiento (`product_id` nulo, `name` = concepto) para no tocar las lecturas de Ronda que la usan.

**H9 — `los_terminos_van_en_el_comprobante`**
- `terms_versions` guarda las **condiciones del financiamiento** que van dentro del comprobante (cuotas, cargo por atraso, qué pasa en mora), con versión y vigencia.
- Cada financiamiento guarda el `terms_version_id` con el que se envió.
- `terms_acceptances` se poda: sin app no hay aceptación del paciente que registrar.

**H10 — `las_alertas_de_las_clinicas`** (solo alertas; no bloquean nada)

Se añaden a `admin_risk_alerts`, que ya las calcula al vuelo y permite marcarlas como revisadas (`risk_alert_reviews`). Cada umbral es un parámetro en `business_parameters`:

| Alerta | Se dispara cuando… | Parámetro (propuesta) |
|---|---|---|
| `telefono_repetido` | un teléfono aparece en más de un paciente | — |
| `correo_repetido` | un email aparece en más de un paciente | — |
| `correo_rebotado` | el comprobante rebota | — |
| `rafaga_de_altas` | una clínica registra más de N financiamientos en un día | `alert_charges_per_merchant_day` = 10 |
| `rafaga_de_pacientes_nuevos` | una clínica da de alta más de N pacientes nuevos en un día | `alert_new_patients_per_merchant_day` = 8 |
| `secretaria_concentrada` | una sola persona registra más del X% de las altas de la semana de una clínica con varias secretarias | `alert_staff_share_pct` = 80 |
| `impago_primera_cuota_clinica` | los pacientes de una clínica no pagan la 1ª cuota por encima del X% (con mínimo de casos) | `alert_fpd_merchant_pct` = 25, `alert_fpd_min_cases` = 5 |
| `exposicion_clinica` | la deuda viva originada por una clínica pasa de $X | `alert_merchant_exposure_usd` = 3.000 |
| `referencia_repetida` | la misma referencia de pago aparece en pagos de pacientes distintos | — |
| `cupo_al_limite_al_estrenar` | un paciente nuevo usa más del X% de su cupo en su primer financiamiento | `alert_first_charge_limit_pct` = 90 |

- Una alerta nueva **aparece en Inicio**, en la lista de "Alertas" y en la ficha de la clínica o del paciente.
- **Ninguna bloquea el registro.** Si más adelante se decide bloquear (§14), el umbral ya existe y solo cambia la acción.

**H11 — `el_contacto_de_helios_se_configura`**
- Tabla de una sola fila **`platform_contact`**: `whatsapp_number`, `support_email`, `support_hours`, `sender_name`, `sender_email`, `updated_by`, `updated_at`. Solo la edita un `super_admin` y queda en la bitácora.
- Las cuentas de cobro siguen en **`payment_destinations`**, igual que en Ronda, pero se permiten **varias activas a la vez** (Pago Móvil, transferencia, Zelle…), cada una con su orden de aparición. Los mensajes y el comprobante las listan todas.
- Mientras el WhatsApp o las cuentas estén vacíos, el comprobante dice "Helios te escribirá por WhatsApp con las instrucciones de pago" y el Inicio del superadmin muestra un aviso de **configuración incompleta**.

### 4.5 Ledger: lo que se añade

- `ledger.account_type` + `commission_expense`.
- `ledger.transaction_type` + `staff_commission`.
- `settlement_reason` + `staff_commission`.

El resto de asientos son los de Ronda:

| Evento | Asiento | Clave de idempotencia |
|---|---|---|
| Financiamiento confirmado (consulta de 100) | Dr `user_receivable` 123,20 / Cr `merchant_payable` 100 / Cr `platform_revenue` 20 / Cr `vat_payable` 3,20 | la del formulario |
| **Comisión de la secretaria** | Dr `commission_expense` 0,50 / Cr `merchant_payable`(clínica) 0,50 | `staff_commission:<charge_id>` |
| Pago del paciente conciliado | Dr `cash` / Cr `user_receivable` | `reconcile:<report_id>` |
| Cargo por atraso | Dr `user_receivable` / Cr `platform_revenue` (sin IVA) | `late_fee:<id>` |
| Pago a la clínica (lunes) | Dr `merchant_payable` / Cr `cash` | `payout:<id>` |
| Castigo a los 60 días | Dr `bad_debt_provision` / Cr `user_receivable` | `charge_off:<block_id>` |
| Reversa (solo admin) | espejo de todos los asientos del financiamiento, **incluida la comisión** | `reverse_charge:<id>` |

---

## 5. El núcleo nuevo: `create_patient_charge`

Sustituye a la pareja `request_charge` (clínica) + `confirm_charge` (app). **Se construye copiando el cuerpo final de `confirm_charge`** (migración `20260923170000`) y quitando el PIN y el reclamo, de modo que conserva cada guarda que Ronda ya aprendió a la fuerza.

```
create_patient_charge(
  p_merchant_id uuid, p_branch_id uuid,
  p_patient jsonb,          -- cédula, nombres, nacimiento, sexo, teléfono, email, dirección, referencia
  p_amount_usd numeric,     -- monto libre de la consulta (sin fee)
  p_concept text,           -- opcional, p. ej. "Consulta"
  p_beneficiary_name text,  -- opcional: paciente atendido si es distinto del titular
  p_idempotency_key text
) returns jsonb             -- helios_charge_for_staff(id): nº de orden, cuotas, fechas, montos
```

Orden, todo en una sola transacción:

1. **Idempotencia**: si ya existe un `charges.idempotency_key` igual, se devuelve el mismo resultado sin tocar nada. Cubre el doble clic y la recarga.
2. **Autorización**: `merchant_users` activo con rol `gerente` o `cajero`; la secretaria solo en su sede. La clínica debe estar `active`. Se comprueba el **mantenimiento global** (`helios_spend_block`).
3. **Monto**: libre, ≤ 2 decimales, ≥ `min_charge_usd`. Se guarda una sola `charge_items` con el concepto. El desglose sale de `helios_charge_breakdown(base, commission_pct)`.
4. **Paciente**: se busca por `normalize_document(cédula)`.
   - Si **no existe**: se validan los datos (edad ≥ 18, teléfono móvil venezolano, email) y se hace `INSERT` en `profiles` como `active` con nivel 1 y `registered_by`.
   - Si **existe**: `SELECT … FOR UPDATE`. Se rechaza si está `expelled`, en lista negra, con bloqueo manual, o si `can_take_debt` es falso (cualquier cuota vencida). Los datos de contacto **no se sobrescriben**: si difieren, se guarda una propuesta de cambio para que la revise Helios (`profile_change_requests`). El comprobante va al correo **ya registrado**, no al que se tecleó.
5. **Cupo**: `helios_credit_used_usd(paciente) + base > levels.monthly_limit_usd`, con la fila bloqueada. Es la misma defensa contra el doble gasto de Ronda (dos sedes a la vez).
6. **Asiento** de cuatro patas (§4.5).
7. **Deuda**: `helios_assign_debt(...)`, que crea las 2 cuotas a +7 y +14 días y mueve el bloque de crédito.
8. **Devengo de la clínica**: `ledger.record_advance_settlement` (que no hace nada con `upfront_pct = 0`).
9. **Comisión** de la secretaria (§6).
10. `INSERT charges` directamente en `status = 'confirmed'`, con `requested_by`, `terms_version_id` y `business_date`.
11. **Mensajes**: `comprobante_financiamiento` (email, sale en el siguiente minuto) y `bienvenida` (WhatsApp manual) en `outbound_messages`.
12. `audit`. Las alertas de H10 se calculan al vuelo; no hace falta dispararlas aquí.

Complementos:
- **`helios_patient_eligibility(cédula, merchant_id)`**: devuelve `{estado: nuevo|disponible|no_disponible, disponible_usd?, nombre_enmascarado?, telefono_enmascarado?}`. **Privacidad entre clínicas (decidido):**
  - Nunca devuelve deuda, cuotas, mora, clínicas anteriores ni el motivo de "no disponible".
  - Límite de consultas por usuario y día (`eligibility_lookups_per_staff_day` = 60) para que una clínica no pueda **enumerar la base de pacientes** de Helios. Pasado el límite, responde "inténtalo mañana" y crea la alerta `consultas_de_cedula_excesivas`.
  - Cada consulta queda registrada en `eligibility_lookups` (quién, cuándo, qué cédula y qué respondió).
  - El personal de la clínica **no tiene lectura directa** sobre `profiles`, `installments` ni `payment_reports` (solo RPC). Del paciente, la clínica ve lo que ella misma registró.
- **`preview_patient_charge(...)`**: solo lectura; el desglose y las fechas que se imprimen.
- **Anulación**: la clínica **no** anula (regla de Ronda). Si la consulta no se prestó, lo pide a Helios y un admin usa `admin_reverse_charge`, que Ronda ya rechaza si hay pagos o liquidaciones pagadas.

---

## 6. Comisión de la secretaria (nuevo)

**Regla:** por cada financiamiento **confirmado**, quien lo registró (`charges.requested_by`) gana **$0,50**. Se devenga en el momento y **se paga a la clínica en el cierre del lunes siguiente**, en la misma transferencia que las consultas. La clínica se la entrega a su personal.

**Modelo:**
- Parámetro global `staff_commission_usd = 0.50` en `business_parameters`, con vigencia (el histórico queda).
- Si una clínica negocia otro monto: columna nullable `merchant_terms.staff_commission_usd`; `null` significa que usa el global.
- **Instantánea en el financiamiento**: `charges.staff_commission_usd` y `charges.commission_staff_id`. Si mañana cambia el parámetro, lo ya devengado no se recalcula (igual que el desglose de Ronda).
- Tabla `staff_commissions`: `charge_id` (única), `merchant_id`, `staff_user_id`, `amount_usd`, `settlement_id`, `status` (`devengada` | `pagada` | `revertida`).
- Al confirmar:
  - asiento Dr `commission_expense` / Cr `merchant_payable`;
  - fila en `settlements` con `reason = 'staff_commission'` y `due_date = business_date`, de modo que entra **en el primer lunes después del alta**, aunque las cuotas de esa consulta vayan más tarde;
  - `run_scheduled_settlements_loop` y `admin_merchant_payables` la recogen sin cambios de lógica, solo reconociendo la nueva `reason`.
- **Reversa** antes de pagarse: el asiento espejo y el settlement se cancelan. Después de pagada, la reversa sigue bloqueada (regla de Ronda) y el ajuste es manual.
- El **impago del paciente no quita la comisión** (se gana al confirmar). Por ahora, la defensa contra altas falsas son las alertas de H10; las medidas que bloquean se evaluarán después (§14).

**Dónde se ve:**
- **Panel de la clínica**:
  - pantalla **"Comisiones"**: la secretaria ve las suyas; el administrador ve las de todos, por persona y por semana, para repartirlas;
  - en **"Pagos"**, cada transferencia se desglosa en *Consultas $X + Comisiones del personal $Y*.
- **Superadmin**: en "Pagos a clínicas" y en la ficha de la clínica. En Contabilidad aparece como gasto (`commission_expense`) en el cierre de mes y en la exportación contable.

⚠️ Hay que preguntar al contador si la comisión pagada a través de la clínica requiere retención de ISLR o factura de la clínica.

---

## 7. Pagos del paciente y avisos, sin app

### 7.1 Registrar un pago (superadmin)

El paciente manda el comprobante al WhatsApp de Helios y el operador:

1. Abre la ficha del paciente y pulsa **"Registrar pago"**.
2. Elige las cuotas. El cálculo reutiliza `helios_quote_installments(p_user, ids, …)`, con las mismas reglas de Ronda:
   - lo vencido va primero;
   - los cargos por atraso viajan con su cuota;
   - la cotización en Bs sale de la tasa del día.
3. Llena método (Pago Móvil / transferencia / Zelle / USDT / efectivo), banco, referencia, fecha, monto en Bs y **sube la captura** (bucket privado `payment-receipts`).
4. Se crea `payment_report` en `reported` con `registered_by` (nueva columna). Nueva RPC: **`admin_register_payment`**.
5. El pago cae en la **misma cola de "Pagos reportados"** de Ronda. Allí se aprueba con `admin_reconcile_payment`, que lo **cruza con el extracto importado** (referencia + monto ±1 Bs + ±5 días) y lo liga a la línea del banco.
6. **Doble control** (parámetro `payment_four_eyes`): quien registra no puede aprobar su propio registro, salvo `super_admin`. Recomendado en cuanto haya más de una persona en el equipo.

Hay además un **camino alternativo, que ya existe en Ronda**: si el paciente paga y no avisa, el depósito aparece al importar el extracto como **"Abono sin dueño"**, y el operador lo asigna al paciente con `admin_assign_deposit`.

### 7.2 Avisos: la cola diaria de WhatsApp

- Los crons de Ronda (`notify_reminder_loop` por momentos) **siguen generando los avisos**, pero ahora en `outbound_messages` (H7).
- Pantalla **"Avisos de hoy"** en el superadmin:
  - lista agrupada por tipo;
  - cada fila con el texto ya renderizado, un botón **"Abrir WhatsApp"** (`wa.me/58…?text=…`, como ya hace la cobranza de Ronda) y el botón **"Enviado"**;
  - marcar un aviso como enviado lo registra en `collection_contacts`.
- **Menos momentos que Ronda** (decidido), porque ahora los manda una persona. Ronda tiene 12 por fecha de vencimiento; en Helios son **5**:

  | Momento | Plantilla |
  |---|---|
  | Víspera | `cuota_manana` |
  | Día del vencimiento, por la mañana | `cuota_hoy` |
  | +1 día | `cuota_vencida_d1` |
  | +4 días | `cargo_por_atraso_d4` (ya se cobró el cargo de $2) |
  | +7 días | pasa a la cola de **Cobranza** |

  Los momentos siguen siendo editables en el panel (`lead_days`).
- **Volumen estimado:**
  - Cada financiamiento genera unos 2 vencimientos × 2-3 avisos ≈ **5 mensajes**, más la bienvenida.
  - Con 100 financiamientos por semana son unos **85-90 mensajes al día**: manejable para una persona.
  - A partir de unos **300 por semana** conviene la fase de WhatsApp Cloud API (§11, fase 6). Solo cambia el *transporte* (`outbound_messages` → API) y **se mantienen las plantillas**. Plantillas categoría *utility*; hay que empezar ya la verificación del Business Manager, que tarda semanas.
- **Recordatorio por email** además del WhatsApp (automático, sin trabajo humano): el aviso de la víspera también sale por correo, usando la misma cola que el comprobante (§7.3). Se puede apagar por plantilla.

### 7.3 El comprobante por correo

Es el único documento que recibe el paciente, así que tiene que estar completo y ser inequívoco.

**Contenido:**
- Encabezado: Helios, número de financiamiento y fecha y hora (Caracas).
- Clínica: nombre, RIF, sede y quién registró (solo el nombre de pila).
- Paciente: nombre y cédula enmascarada.
- Servicios financiados, con el total de la consulta.
- **Plan de pagos**: cuota 1 y cuota 2 con fecha y monto en dólares. El fee aparece **solo como línea aparte en el desglose** ("Servicio Helios 20% + IVA"), nunca sumado a la consulta en un total (regla de Ronda).
- Cómo pagar: las cuentas de cobro configuradas (H11), y "se paga en bolívares a la tasa BCV del día del pago".
- Cómo avisar el pago: el WhatsApp de Helios con un enlace `wa.me` que ya trae el número de financiamiento.
- Condiciones (`terms_versions` vigente): cargo de $2 por cuota tras 3 días de gracia, congelamiento desde el día 1, y qué pasa a los 30 y 60 días.
- Pie: "Si no reconoces este financiamiento, escríbenos al …". **Este pie es una alerta temprana gratuita** contra altas falsas: el paciente real que no pidió nada avisa.

**Formalidades:**
- Asunto: "Tu financiamiento en {clínica} — 2 cuotas de ${monto}".
- Remitente: `sender_name <sender_email>` de `platform_contact`, desde un dominio propio con SPF, DKIM y DMARC; si no, cae en spam.
- **No es una factura fiscal.** La facturación por cuenta de terceros sigue pendiente, como en Ronda. El texto dice "comprobante", nunca "factura".
- HTML simple con tablas (compatible con Gmail y Outlook) y versión de texto plano.

---

## 8. Panel web

### 8.1 Fork y poda de Ronda-panel

1. Copiar `Ronda-panel` a `Helios/panel`, **sin** `.git`, `node_modules`, `dist` ni `.env*`. Repositorio nuevo; el README anota "fork de Ronda-panel @ f3b5c6a".
2. **Borrar** (clase B):
   - QR y cobro por la app: `facturar.tsx`, `features/charges/pendingCharge.ts`, `lib/wakeLock.ts`, realtime `charge:<id>`;
   - grupos (`g.$code.tsx`, `CrecimientoGrupos`, `GrupoFrenteAIndividual`, pestaña Gente › Grupos);
   - bits;
   - KYC (`verificaciones/*`, `ColaKyc`, `features/admin/verification.ts`, `ficha-persona/Identidad*`). Su UI de cola con teclado se guarda aparte por si se activa el expediente (§14);
   - push y promociones (`PushComposer`, `Mensajes`, `promos.ts`, `AvisosAutomaticos`, `metricas/avisos/*`);
   - versión de la app (`VersionTab`, `release.ts`);
   - eliminaciones;
   - bóveda (`boveda/*`, `MerchantVaultCard`, `vault.ts`);
   - QA piloto (`qa.ts`, `RutaDeQa`);
   - landing de consumo (`routes/index.tsx` → redirige a `/login`), `portada/*`, `public/laquinta`, `public/pasos`, `.well-known/*`, `config/tiendas.ts`;
   - `/soporte` y `/legal/privacidad` se reescriben para Helios;
   - métricas de "noches" y el perfil horario rotado a las 10 AM.
3. **PWA**: se quitan el service worker, el aviso de instalar y el `panel-tactil`. Una recepción usa PC; se recuperan si alguna clínica trabaja con tablet.
4. **Moneda**: `formatEur` → `formatUsd` ("$", `es-VE`). `formatVes` y la tasa BCV quedan igual. `diaOperativo` pasa a medianoche.
5. **Vocabulario** (§3.3) en menús, catálogo del admin (`features/admin/catalogo/*`), glosario y textos.
6. **Tokens**: `tokens/helios.tokens.json` (§8.4) → `styles/tokens.gen.css` y `theme/tokens.gen.ts`.

### 8.2 Panel de la clínica

| Ruta | Roles | Pantalla | Origen en Ronda |
|---|---|---|---|
| `/registrar` | administrador, secretaria | **Nuevo financiamiento** (§2.1): cédula → datos → servicios → vista previa → confirmar → "comprobante enviado" | nuevo (reemplaza a `/facturar`) |
| `/financiamientos` | administrador, secretaria (solo los suyos) | Historial por día, resumen, "quién registró", estado del comprobante (enviado/rebotado), CSV (administrador) | `/transacciones` |
| `/financiamientos/$id` | administrador, secretaria | Detalle: servicios, cuotas (sin estado de pago del paciente), fechas en que se le paga a la clínica, **reenviar comprobante** | `/transacciones/$id` |
| `/comisiones` | administrador (todas), secretaria (las suyas) | Comisiones por persona y semana; pagadas y por pagar | **nuevo** (base: `merchant_sales_by_staff`) |
| `/metricas` | administrador | KPIs, serie diaria, recurrencia, sin el perfil nocturno | `/metricas` |
| `/pagos` | administrador | Lo devengado, próximo lunes, transferencias recibidas (consultas + comisiones) | `/liquidaciones` |
| `/personal` | administrador | Alta y baja de secretarias, contraseñas | `/personal` |
| `/cuenta` | todos | Rol, cerrar sesión | `/cuenta` |

**Privacidad:** la clínica **no ve** el estado de pago ni la mora del paciente, solo lo que le afecta a ella: cuándo se le paga. La cobranza es de Helios.

### 8.3 Superadmin

| Área | Cambios respecto a Ronda |
|---|---|
| **Inicio** | Igual. Las colas pasan a ser: pagos por aprobar, **avisos de hoy**, abonos sin dueño, alertas, **correos rebotados** y el aviso de **configuración incompleta** (H11) |
| **Métricas** | Igual, podando las pestañas de grupos, noches, KYC y push. "Locales" pasa a "Clínicas" y "Gente" a "Pacientes" |
| **Por cobrar (cobranza)** | Igual (cartera por tramos, morosos, semana, calendario, promesas, plantillas de WhatsApp) |
| **Pagos registrados** | Igual + botón **"Registrar pago"** (§7.1) + importar extracto + abonos sin dueño |
| **Avisos de hoy** | **Nuevo** (§7.2); sustituye a "Notificaciones" (push) y conserva el editor de plantillas (WhatsApp y email). Incluye el historial de correos enviados, con su estado |
| **Alertas** | Igual + las nuevas de H10 |
| **Pagos a clínicas** | Igual (cierre de los lunes, histórico, registrar transferencia con comprobante) + **desglose de comisiones** + **cuenta destino de la clínica** |
| **Contabilidad** | Igual (libro, cierre de mes, exportación) + cuenta `commission_expense` |
| **Pacientes** | Ficha con pestañas resumen, **datos y referencia** (en lugar de identidad), financiamientos, pagos, cobranza e historial. Acciones: registrar pago, bloquear, congelar, lista negra, condonar cargo, WhatsApp, **editar datos de contacto** (auditado) y aprobar cambios propuestos por la clínica |
| **Clínicas** | Alta (categoría médica, especialidad, RIF, MPPS), perfil, condiciones (incluida la comisión propia), **cuenta de pago**, personal, estado (activa/pausada/terminada), sus alertas |
| **Financiamientos** | Igual que Consumos: detalle, reversa |
| **Ajustes** | Se quedan: tasa BCV, parámetros (+ comisión, mínimo, umbrales de alertas, doble control), niveles, feriados, **cuentas de cobro** (varias), **condiciones del comprobante** (en lugar de términos), equipo, seguridad MFA, bitácora, mantenimiento. Nuevo: **Contacto** (WhatsApp, email de soporte, horario, remitente de los correos). Se van: versión de la app, eliminaciones, QA |
| **Asistente IA** | Fase 5 (opcional) |

### 8.4 Marca

- Paleta tomada de `Helios Logo.jpeg`:
  - primario, azul intenso ≈ `#1A56DB` / `#0B4FD8` (el del logotipo);
  - acento del degradado ≈ `#60A5FA` → `#BFDBFE`.
  - Se ajustan con el validador de contraste del generador.
- **Tema claro por defecto** (contexto médico y de recepción) y oscuro opcional. Ronda es oscuro con lima.
- Tipografía: una geométrica redondeada cercana al logotipo (p. ej. *Outfit* o *Figtree*) para títulos, y *Source Sans 3* (la de Ronda) para texto.
- **Pendiente:** el logo en **SVG**, porque el JPEG no sirve para la interfaz, y el isotipo aislado para favicon e iconos.

---

## 9. Calidad, pruebas y CI

- **Suites SQL de Ronda portadas** (PL/pgSQL con `RAISE EXCEPTION`, cada una en begin/rollback con `set constraints all immediate`): `ledger`, `mora`, `payment`, `admin`, `merchant_payout`, `statement`, `edit_merchants`, `level_promotion`, `profile`, `due_dates`, `saldo`, `fx_rate`, `notifications`.
- **Suites nuevas:**
  - `patient_charge`: alta nueva y existente, cupo, doble gasto en dos sesiones, idempotencia, edad, lista negra, clínica pausada, mantenimiento;
  - `eligibility`: nunca filtra deuda ni motivo, límite diario, registro de consultas, el personal no lee `profiles` directamente;
  - `staff_commission`: devengo, pago del lunes, reversa y cambio de parámetro con vigencia;
  - `register_payment`: doble control y cruce con el extracto;
  - `outbound_messages`: comprobante encolado al confirmar, reintentos, rebote → alerta, avisos generados por fecha y cancelados al pagar (con el `http` simulado);
  - `risk_alerts`: cada alerta de H10 se dispara en su umbral y no antes.
- **`plpgsql_check`** sobre todas las funciones, con cero errores, como paso de CI.
- **CI** (GitHub Actions), mejorando lo que hoy hace Ronda, que no corre las pruebas de BD en CI:
  1. `panel`: `npm ci` → typecheck → lint → tests (`tsx`).
  2. `db`: `supabase start` → `supabase db reset` → `plpgsql_check` → `bash supabase/tests/run.sh`.
- **Semillas**: `seed.sql` con una clínica demo ("Consultorio Demo"), un administrador y una secretaria, un superadmin local y la tasa del día. Una semilla de métricas sintéticas (patrón de `semilla/metricas_dev.sql`) para probar los tableros.

---

## 10. Infraestructura y entornos

| Recurso | Acción |
|---|---|
| GitHub | Repositorio `Helios` (privado) |
| Supabase | Proyectos **`Helios`** (prod) y **`Helios-dev`**, región más cercana (us-east-1). Extensiones: `pgcrypto`, `pg_cron`, `http`, `plpgsql_check`, `supabase_vault` (clave de Resend) |
| Auth | Email + contraseña, sin registro público, sin confirmación (las cuentas las crea un admin). MFA TOTP activado. **Proveedor de teléfono desactivado** |
| Storage | `payment-receipts` (privado: capturas de pagos de pacientes), `merchant-receipts` (privado: transferencias a clínicas), `merchant-logos` (público) |
| Vercel | Proyecto `helios-panel`; dominio por definir (p. ej. `app.helios.…`); variables `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_ENTORNO`, `VITE_SENTRY_DSN` |
| Sentry | Proyecto `helios-panel` con subida de sourcemaps (como Ronda) |
| WhatsApp | Un número de WhatsApp Business para Helios (fase 1: app de WhatsApp Business; fase 6: Cloud API) |
| Email (**obligatorio**) | **Resend** con dominio propio verificado (SPF, DKIM, DMARC). Dev usa un remitente de pruebas y una lista de destinatarios permitidos, para no escribir nunca a un paciente real desde dev |
| Bootstrap | `bootstrap_superadmin.sql` (patrón de Ronda) para el primer super_admin; el resto desde Ajustes › Equipo |
| Entornos locales | `.env.dev` / `.env.prod` en `panel/` (patrón de Ronda); banner "DEV" cuando no es producción |

---

## 11. Fases y estimación

Estimación para una persona con asistencia de IA, en semanas de trabajo efectivo.

| Fase | Alcance | Entregable verificable | Semanas |
|---|---|---|---|
| **0 — Cimientos** | Repositorio, proyectos de Supabase y Vercel, CI. Base consolidada (§4.1): volcado → poda → renombrado → `plpgsql_check` en verde → suites de Ronda en verde. Fork del panel podado que compila y arranca contra `Helios-dev`. Tokens de marca | `supabase db reset` limpio; el panel abre login, superadmin y panel de clínica (aunque vacíos) | 1,5 |
| **1 — Dominio Helios** | H1 (USD, niveles), H2 (medianoche), H3 (paciente sin cuenta), H4 (`create_patient_charge` + elegibilidad privada + vista previa), H5 (comisión), H6 (comprobante por correo con Resend), H8 (clínicas y cuenta de pago), H9 (condiciones), H11 (contacto y cuentas configurables) + suites nuevas | Un financiamiento creado por SQL produce asientos, cuotas, devengos y comisión correctos, y el comprobante llega a un correo de prueba; la mora corre sobre él | 2 |
| **2 — Panel de la clínica** | `/registrar` completo, `/financiamientos` (con reenviar comprobante), `/comisiones`, `/pagos`, `/personal`, `/metricas` | Una secretaria registra un paciente de principio a fin en dev y el comprobante llega | 1,5 |
| **3 — Superadmin operativo** | Registrar pago (+ doble control), avisos de hoy (H7), alertas H10, pagos a clínicas con comisiones, ficha de paciente y de clínica adaptadas, Ajustes › Contacto y cuentas de cobro, poda de métricas y vocabulario | Ciclo completo en dev: alta → comprobante → avisos → pago por WhatsApp → conciliación → lunes → transferencia | 2 |
| **4 — Endurecimiento y piloto** | Prueba de extremo a extremo con fechas simuladas (mora día 1/4/30/60), revisión de RLS y RPC (la clínica no puede leer a pacientes ajenos ni enumerar cédulas), textos legales, `/soporte` y privacidad, carga inicial en prod, formación del equipo y de 1-2 clínicas piloto | Piloto en producción con límites bajos por clínica | 1 |
| **5 — Asistente IA** (opcional) | Portar `admin-asistente` + vistas `asistente.*` + `mapa.json` | — | 0,5-1 |
| **6 — WhatsApp automático** (cuando el volumen lo pida) | Cloud API: transporte de `outbound_messages`, plantillas *utility* aprobadas, webhooks de entrega | — | 1-1,5 |

**Total hasta el piloto: unas 8 semanas.** Las fases 0-1 son el camino crítico; la 2 y la 3 se pueden solapar.

### 11.1 Primeros pasos concretos (fase 0)

1. `git init` en `Helios/`, estructura de §3.2, `.gitignore` y CI esqueleto.
2. Crear `Helios-dev` en Supabase y el proyecto de Vercel.
3. En `Ronda-app`: `supabase start && supabase db reset`, volcar el esquema y los datos de configuración, y exportar `cron.job` y las políticas de Storage.
4. Escribir `poda/01_…sql` iterando `RESTRICT` → arreglar → repetir hasta que caiga todo lo de la clase B.
5. Aplicar `scripts/portar-de-ronda.mjs` y `plpgsql_check` → cero errores.
6. Portar las suites de Ronda → verde.
7. Copiar y podar el panel → `npm run build` en verde → desplegar en Vercel apuntando a dev.

---

## 12. Riesgos principales y mitigación

| Riesgo | Por qué importa en Helios | Mitigación |
|---|---|---|
| **Clínica o secretaria que da de alta pacientes falsos** | Sin KYC ni consentimiento digital, Helios paga el 100% a la clínica aunque el paciente no pague, y la secretaria cobra comisión por cada alta. Es el fraude #1 que ya identificó Ronda, aquí agravado | **Por ahora (decidido):** las alertas automáticas de H10, el comprobante por correo con "si no reconoces este financiamiento, escríbenos", cédula única y lista negra. Las medidas que bloquean están en §14, listas para activarse si las alertas muestran un patrón |
| **Datos de contacto malos** | La cobranza depende 100% del teléfono, el WhatsApp y el correo, y nadie los verifica | Validación de formato, email escrito dos veces, contacto de referencia obligatorio, alerta por correo rebotado, y bienvenida por WhatsApp el mismo día: si no llega, se marca el teléfono y se avisa a la clínica |
| **Operación manual (pagos y avisos por WhatsApp)** | No escala y se presta a errores | Doble control, cruce con el extracto, cola diaria con estado, y la fase 6 lista para automatizar sin cambiar el modelo |
| **Deriva entre Ronda y Helios** | Los arreglos de un lado no llegan al otro | Mismos nombres en la base + `portar-de-ronda.mjs` + suites compartidas |
| **Datos sensibles de salud** | El nombre del servicio puede revelar un diagnóstico ("consulta oncológica"), y ahora viaja por correo | El concepto es opcional y se recomienda genérico ("Consulta"), no se guarda información clínica y las capturas de pago van en buckets privados con URL firmada. Hay que revisar el hábeas data (art. 28 CRBV) con un abogado |
| **Prueba débil de la deuda** | Sin firma ni aceptación digital, lo único que prueba que el paciente aceptó es que la secretaria lo registró y que el correo le llegó | Se guarda el HTML exacto enviado, la versión de las condiciones y el estado de entrega. Revisar con un abogado si es suficiente para cobrar judicialmente |
| **Regulación del crédito** | Mismo punto que en Ronda (SUDEBAN, protección al consumidor), más la ley de servicios médicos (IVA exento en el precio de la consulta; el fee de Helios sí lleva IVA) | Revisión legal del comprobante, de las condiciones y de la facturación por cuenta de terceros **antes del piloto** |

---

## 13. Decisiones

### 13.1 Resueltas el 2026-09-30

| # | Pregunta | Decisión |
|---|---|---|
| D-H1 | ¿Fee del 20% + IVA al paciente y 0% a la clínica? | **Sí** |
| D-H2 | ¿La clínica cobra como un local de Ronda (50% + 50% al vencer cada cuota, los lunes, cobre Helios o no)? | **Sí, por ahora** |
| D-H3 | ¿Se retiene la liquidación hasta tener la constancia firmada? | **No por ahora.** No hay constancia firmada: se envía un comprobante por correo. Ver §14 |
| D-H6 | ¿Qué ve la clínica de un paciente conocido? | Solo el nombre enmascarado y "disponible $X" o "no disponible" (§5) |
| D-H8 | ¿Cuentas de cobro de Helios y titular? | **Configurables** en Ajustes (`payment_destinations`, varias activas); se llenan después |
| D-H9 | ¿WhatsApp de Helios? | **Configurable** en Ajustes › Contacto (`platform_contact`) |
| D-H4 | ¿Catálogo o monto libre? | **Monto libre**, sin catálogo (2026-09-30) |
| D-H5 | ¿Menores de edad? | **No hay deudores menores.** Se registra al representante (2026-09-30) |
| D-H11 | ¿Topes por clínica? | **Solo alertas** con umbrales configurables (H10); nada bloquea |
| — | ¿Cuántos avisos por vencimiento? | **5** (§7.2) |

### 13.2 Abiertas (con propuesta por defecto)

Ninguna bloquea empezar la fase 0. Se aplica la propuesta mientras no se diga otra cosa.

| # | Pregunta | Propuesta |
|---|---|---|
| D-H7 | ¿Monto mínimo por financiamiento? | Parámetro `min_charge_usd`; arranca en **$10** hasta que se fije |
| D-H10 | ¿Razón social y RIF de Helios (facturación por cuenta de terceros)? | Por definir con el contador; hace falta para el pie del comprobante |
| D-H12 | ¿Se porta el asistente IA en el lanzamiento? | No: fase 5 |
| D-H13 | ¿Dominio para enviar los correos? | **Resend**, se configura después. Mientras tanto la cola funciona y los correos quedan en `pendiente` sin clave |

---

## 14. Aplazado: medidas antifraude que bloquean

Decidido el 2026-09-30: por ahora **solo alertas**. Esto queda diseñado para activarlo si las alertas muestran un patrón, sin rehacer nada, porque las alertas ya miden lo mismo:

| Medida | Qué hace | Coste de activarla |
|---|---|---|
| **Topes por clínica** | Bloquea el registro al pasar las altas por día o la deuda viva originada | Bajo: los umbrales de H10 pasan de alertar a rechazar en `create_patient_charge` |
| **Expediente** | La secretaria sube la foto de la cédula y de una constancia firmada; Helios la revisa en una cola (reciclando la de KYC de Ronda) | Medio: tabla `charge_documents`, bucket privado, cola de revisión |
| **Retención de la liquidación** | No se le paga a la clínica un financiamiento sin expediente aprobado | Bajo, una vez exista el expediente |
| **Clínicas nuevas `on_collection`** | Durante sus primeros meses, a la clínica se le paga solo lo que el paciente ya pagó | Muy bajo: la política ya existe en el esquema de Ronda; es un cambio de condiciones por clínica |
| **Comisión al pagar la 1ª cuota** | La secretaria solo gana si el paciente paga | Bajo: cambia el momento del devengo (§6) |
| **Consentimiento por OTP** | El paciente dicta un código recibido por WhatsApp o SMS | Alto: proveedor de SMS o WhatsApp API |
