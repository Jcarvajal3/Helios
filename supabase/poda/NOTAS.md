# Poda — notas de construcción de la base (fase 0)

Bitácora de cómo se construyó la base de Helios y de **cada desviación** respecto
a las migraciones de Ronda. Fecha: 2026-09-30. Proyecto: `Helios`
(`ahyfbnfsbyzdoyjzjvfb`, Postgres 17.11). Fuente: `Ronda-app/supabase/migrations`
@ `20260929140000` (354 migraciones).

## Cómo se hizo (y por qué no como decía el plan)

El plan (docs/00 §4.1) proponía `supabase start` + `db reset` + `db dump` sobre
Ronda y consolidar una migración base. **Sin Docker eso no es posible**, así que
se hizo lo equivalente contra el remoto vacío:

1. `node scripts/portar-de-ronda.mjs --dir ../Ronda/Ronda-app/supabase/migrations supabase/migrations`
   → las 354 migraciones, con su nombre y timestamp, renombradas (`ronda_` →
   `helios_`, reglas R1–R4 en la cabecera del script).
2. `node supabase/poda/aplicar.mjs` → las reproduce una a una contra el remoto
   (Management API, una transacción por archivo) y registra cada una en
   `supabase_migrations.schema_migrations` con la misma forma que el CLI
   (`version text PK, statements text[], name text`, copiada de Ronda-dev).
3. Poda: `20261001000000_la_poda_de_la_app.sql` + tres arreglos
   (`…000200`, `…000300`, `…000400`) y la extensión (`…000100`).
4. `supabase/poda/verificar.sql` (plpgsql_check + funciones sql + vistas) en
   cero errores, y las suites de `supabase/tests` en verde.

Resultado: la historia de Helios **es** la de Ronda (portable con el script)
más migraciones propias, en vez de una base consolidada. Ventaja: un arreglo
futuro de Ronda se porta como una migración más.

### Comprobación de la réplica

Antes de podar se comparó el catálogo de Helios con el de Ronda-dev
(`edtvhrxewbyrjnrzzkrt`, solo lectura) con el prefijo renombrado: funciones,
tablas, vistas, secuencias, índices, tipos, políticas, triggers y trabajos de
cron **idénticos**, salvo una diferencia:

- `metricas.semana_caja_al(date)` existe en Ronda-dev y **no está en ninguna
  migración** de Ronda: es deriva de dev (se creó a mano o desde una rama). En
  Helios no existe. Conviene avisar en Ronda.

## Desviaciones en la reproducción de Ronda (pasos 1–2)

- **Ninguna migración de Ronda se editó a mano.** Las 354 corrieron tal cual
  salieron del script.
- Una ejecución se cortó en `20260911183000_los_contactos_de_cobranza.sql` por
  un fallo de CONEXIÓN del CLI (`password authentication failed for user
  "cli_login_postgres"`: el rol temporal de login del CLI), no del SQL. Como
  cada archivo va en una transacción, no quedó nada a medias; `aplicar.mjs`
  ahora reintenta esos fallos (hasta 5 veces) y se reanudó desde ahí.
- **Los crons corrieron durante la reproducción** (~30 min, los crea la propia
  migración): `helios_push_dispatch` cada 15 s (sin nada que mandar) y
  `helios_sync_fx_rate` trajo la tasa del día. Quedan en la base 2 filas en
  `exchange_rates` (`BCV` = euro 973,309675 y `BCV_USD` = dólar 859,0629, del
  2026-09-30) y 2 en `fx_rate_syncs`. Son tasas reales del BCV, no datos de
  Ronda: se dejaron. ⚠️ H1 decide si `BCV` pasa a ser el dólar y qué hacer con
  la fila en euros.
- No hizo falta nada especial para: `create index concurrently` (Ronda no lo
  usa en migraciones), `alter type … add value` (Ronda ya los aislaba en su
  propia migración), `commit` (solo dentro de procedimientos), extensiones
  (`pgcrypto`, `pg_cron`, `http`, `vector` —creada y luego borrada por Ronda—
  se crean solas; `pg_net` no se usa), Vault (solo se LEE en tiempo de
  ejecución: `pin_pepper`, `expo_access_token`; ninguna migración escribe
  secretos), URLs (ninguna migración apunta al proyecto ni a Edge Functions de
  Ronda; solo dolarapi, er-api y Expo).

## La poda (20261001000000_la_poda_de_la_app.sql)

Todo `drop` con RESTRICT. Se probó primero en seco (`begin; … rollback;`) hasta
que corrió entera.

### Lo que se fue (clase B)

- **Cron**: `helios_push_dispatch`, `helios_push_receipts`, `helios_push_purge`,
  `helios_kyc_expire_stuck`, `helios_expire_stale_charges`.
- **Tablas (22 + 2 de kyc)**: `push_deliveries`, `push_tokens`,
  `promo_campaigns`, `group_members`, `groups`, `bits_entries`, `user_pins`,
  `pin_attempts`, `user_devices`, `app_release`, `app_activity`,
  `user_payment_methods`, `account_deletion_requests`, `avatar_emojis`,
  `avatar_colors`, `terms_acceptances`, `merchant_vault_topups`,
  `credit_waitlist`, `merchant_vaults`, `qa_case_marks`, `products`,
  `product_categories`, `kyc.decision_log`, `kyc.verifications`.
- **Vistas (15)**: `helios_group_split_gaps`, `metricas.avisos`,
  `metricas.avisos_peldanos`, `asistente.{aparatos, bits, envios_push, grupos,
  miembros_grupo, lista_de_espera, productos_vendidos, productos,
  verificaciones}`, `kyc.{review_queue, gate_metrics, retention_status}`.
- **Funciones (152 + 11 de kyc)**, por área (lista exacta en la migración):
  PIN y dispositivos (8), KYC (15), push y promociones (16), grupos (41 —
  incluye `realtime_*`, `helios_group_*`, `helios_split_shares`,
  `helios_payables`, `min_share_usd`, `installment_unlocks_at`,
  `confirm_charge_as_group`), cobro por QR (`preview_charge`, `confirm_charge`,
  `request_charge`, `expire_stale_charges`, `cancel_pending_charge`,
  `charge_detail`, `merchant_charge_status`), Bits (7), app (20 — versión,
  actividad, avatar, métodos de pago, `accept_terms`, `admin_user_terms`,
  `ack_level_up`, eliminación de cuenta, `sync_phone_e164`,
  `mark_notifications_read`), `my_*` de la persona (8; se quedan
  `my_merchant_id_as_gerente`, `my_merchant_ids`, `my_merchant_ids_with_role`,
  que son del PERSONAL y los usan las políticas RLS), piloto (18 — bóveda,
  lista de espera, `ledger.record_vault_deposit`,
  `ledger.merchant_prepaid_balance`), métricas (12 — `admin_nights`,
  `admin_growth_funnel`, `admin_metricas_avisos*`, `admin_avisos_*`,
  `admin_user_persona`, `metricas.avisos_*`). Todo el esquema `kyc`.
- **Tipos**: `push_status`, `group_status`, `group_member_status`,
  `account_deletion_status`, `kyc.verification_status`, `kyc.rejection_reason`.
- **Triggers en tablas A**: `charges_notify_group`, `charges_realtime`,
  `installments_award_bits`, `payment_quote_items_live_group`,
  `payment_reports_cancel_pushes`, `payment_reports_notify_bits`,
  `profiles_waitlist_on_activation`, `notifications_enqueue_push`.
- **Políticas**: `charges_read_group_member`, `profiles_read_group_mates`,
  `realtime.messages.helios_cada_quien_escucha_lo_suyo`.
- **FK de tablas A hacia B** (la columna se queda, inerte; regla 4 de la
  migración): `charges.group_id`, `charge_items.product_id`,
  `notifications.campaign_id`, `profiles.avatar_emoji`, `profiles.avatar_color`.
- **Storage**: buckets `kyc-documents` y `kyc-archive` (vacíos). Ronda decía
  que Storage no deja borrarlos por SQL; sí deja si se abre
  `storage.allow_delete_query` (el trigger `storage.protect_delete` es de
  sentencia). Se abre solo para ese DELETE y solo si no tienen archivos. Sus
  políticas ya las había quitado Ronda (20260923160000). Quedan
  `merchant-logos` (público) y `merchant-receipts` (privado).
- **Datos sembrados por migraciones**: el comercio de prueba `HELIOS DEMO`
  (`RONDA DEMO` en Ronda, `J-000000001`) con su sucursal y condiciones; la
  cuenta de cobro provisional (`PENDIENTE POR CONFIGURAR`); 8 plantillas de
  avisos de funciones podadas (`group_charge*`, `bits_earned`, `kyc_*`,
  `waitlist_*`); el parámetro `charge_ttl_minutes` (plazo de un QR) y su
  entrada del catálogo. Se queda toda la configuración: 6 niveles, 16
  parámetros, 22 entradas del catálogo, 22 plantillas de avisos, 10 de
  cobranza, 4 fuentes de tasa, 14 feriados.

### Lo que se quedó y hubo que tocar (A que dependía de B)

Cada una es la función de Ronda tal cual (`pg_get_functiondef`) con los trozos
marcados `PODA (Helios)`. Las RPC conservan la forma de su respuesta.

| Objeto | Dependía de | Cambio |
|---|---|---|
| `helios_spend_block` | `credit_waitlist`, `helios_waitlisted` | Sin el paso 3 (lista de espera) |
| `run_scheduled_settlements_loop` | `helios_settle_vaults` | Sin el saldo contra la bóveda |
| `admin_report_merchant_payout` | `helios_settle_from_vault`, `ledger.merchant_prepaid_balance` | `p_method = 'boveda'` rechaza; sin el freno de garantía |
| `admin_reverse_charge` | `group_members` | Sin devolver el techo de la mesa |
| `admin_charge_detail` | `groups`, `group_members`, `min_share_usd` | `split` sin miembros sin cuota; `group` = null |
| `helios_quote_installments` | `installment_unlocks_at` | Sin la exclusión de cuotas bloqueadas por mesa |
| `report_payment` | `helios_bits_for_installment` | `bits_pending` = 0 |
| `admin_user_detail` | `avatar_colors`, `kyc.verifications`, `bits_entries`, `user_devices` | `avatar_*` null, `kyc`/`bits` null, `bits_entries`/`devices` [] |
| `admin_overview` | `kyc.verifications` | `kyc` = null |
| `admin_notification_catalog` | `push_envelope`, `push_deliveries` | `channel`/`priority` null; `delivered`/`failed`/`cancelled` 0 |
| `admin_related_accounts` | `user_devices`, `kyc.verifications` | Sin «mismo teléfono» ni cédula del KYC; search_path sin `kyc` |
| `admin_risk_alerts` | `user_devices`, `kyc.verifications` | Sin `kyc_red_sospechosa` ni `kyc_sistema_distinto`; relacionadas solo por cédula y nombre |
| `admin_terms_versions` | `terms_acceptances` | `accepted_count` 0, `first_accepted_at` null, `pending_current` 0 |
| `metricas.perfil_deudor` | `push_tokens` | `push` = false |
| `metricas.rasgos_de_personas` | `kyc.verifications`, `user_devices`, `push_tokens` | Reescrita desde el perfil: edad de `birth_date`, nivel; sexo/ciudad/plataforma null |
| `metricas.senales_deudor` | `push_tokens`, `user_devices`, `app_activity`, `push_deliveries` | Señales de la app en «sin dato» |
| vista `metricas.solicitudes` | `kyc.verifications`, `kyc.decision_log` | «verificado» = salió de `pending_kyc`/`pending_pin`; fecha = `created_at` |
| vista `asistente.personas` | `kyc.verifications`, `user_devices` | `sexo`, `sistema`, `sistema_fuente`, `kyc_estado` null |

## Migraciones propias añadidas (fuera de la poda)

- `20261001000100_plpgsql_check_revisa_las_funciones.sql`: la extensión, en
  `extensions`.
- `20261001000200_las_condiciones_viejas_pasan_por_las_nuevas.sql` —
  **error heredado de Ronda** (plpgsql_check: `cannot update view
  "merchant_settlement_terms"`). La firma vieja
  `admin_set_settlement_terms(uuid, numeric, numeric, numeric, settlement_policy)`
  hacía UPDATE sobre una vista (desde 20260911206000) y revienta siempre;
  20260925131000 la volvió a crear copiando producción. Ahora delega en la
  firma nueva (la del panel). Esto también está roto en Ronda.
- `20261001000300_el_desglose_lee_parametros_y_no_es_inmutable.sql` — aviso de
  plpgsql_check: `helios_charge_breakdown` era IMMUTABLE y lee parámetros
  (STABLE). Pasa a STABLE. También en Ronda.
- `20261001000400_la_linea_del_financiamiento_es_libre.sql` — lo encontraron las
  suites: `charge_items_product_required` (`check (product_id is not null) not
  valid`, de 20260918190000) impedía la línea libre sin catálogo que pide D-H4.
  Complemento de la poda en archivo aparte porque la poda ya estaba aplicada.

## Verificación (supabase/poda/verificar.sql)

- **plpgsql_check: 0 errores** sobre todas las funciones y procedimientos
  plpgsql de public, ledger, audit, metricas y asistente (las de trigger contra
  su tabla). Ningún trigger huérfano.
- **Funciones `language sql`: 0 errores** (se re-ejecuta su definición con
  `check_function_bodies` y se deshace).
- **Vistas: 0 rotas.**
- **Avisos que quedan (14), revisados y aceptados**:
  - `asistente.ejecutar` (6): STABLE pero ejecuta SQL dinámico. Es el asistente
    (fase 5); se revisa al portarlo.
  - «target type is different type than source type» (8): asignaciones con
    conversión implícita (texto → uuid/enum en `process_mora`,
    `run_scheduled_settlements`, `notify_reminder_loop`, `report_payment`…).
    Inofensivas.
- **Cron que queda (18)**: `helios_sync_fx_rate` (14:00 UTC = 10:00 Caracas) y
  su reintento, `helios_process_mora` (10:05), `helios_scheduled_settlements`
  (10:10), `helios_cash_forecast_snapshot` (lunes), `helios_cron_log_purge` y
  los 12 avisos de cuota (`helios_installment_*`, `notify_reminder_loop`).

## Lo que la poda NO tocó a propósito (para las fases siguientes)

- `auth.users` → `on_auth_user_created` → `handle_new_user` y las FK de
  `profiles`, `charges`, `installments`… a `auth.users`: **H3**.
- RPC con `auth.uid()` como deudor: `quote_installments(uuid[])` y
  `report_payment(...)` (las usan las suites de pago). Políticas RLS
  `*_read_own` de la persona (`profiles`, `charges`, `charge_items`,
  `installments`, `payment_quotes`, `payment_quote_items`,
  `payment_quote_late_fees`, `payment_reports`, `late_fees`, `level_changes`,
  `user_credit_blocks`, `notifications`): **H3**.
- `notifications` + `notify()` + `notify_reminder_loop` y los 12 crons de
  avisos: siguen generando filas en `notifications` (la bandeja de la app), ya
  sin push. **H7** las lleva a `outbound_messages` y reduce los momentos a 5.
- `charges.status = 'pending'`, `charges.expires_at`, `void_charge` /
  `admin_void_charge` (anulan un cobro pendiente de QR): sin uso en Helios,
  inofensivos. `merchant_directory` (el buscador de locales de la app): sin
  uso.
- Columnas inertes: `profiles.avatar_emoji`, `profiles.avatar_color` (con su
  check `profiles_avatar_completo`), `charges.group_id`, `charges.group_name`,
  `charge_items.product_id`, `notifications.campaign_id`.
- Valores de enum de la app (`pending_kyc`, `pending_pin`, `group_charge`,
  `tab_*`, `bits_earned`, `kyc_*`, `waitlist_*`, `merchant_prepaid`,
  `vault_*`…).
