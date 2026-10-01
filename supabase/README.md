# supabase/ — la base de Helios

Postgres 17 en Supabase. Proyecto remoto **Helios** (`ahyfbnfsbyzdoyjzjvfb`).
No hace falta Docker para nada de lo que sigue.

```
config.toml        auth por correo + contraseña, MFA TOTP, sin teléfono ni SMS
migrations/        354 de Ronda (portadas) + las de Helios (20261001…)
poda/aplicar.mjs   aplica las migraciones pendientes al remoto (sustituye a db push)
poda/verificar.sql plpgsql_check + funciones sql + vistas + crons
poda/NOTAS.md      cómo se construyó y cada desviación respecto a Ronda
tests/             suites SQL (run.sh) — ver tests/README.md
```

## Cómo se construyó

Helios es Ronda sin la app. En vez de consolidar un volcado (necesitaba
Docker), la base es **la historia completa de Ronda reproducida** y encima la
poda:

1. `migrations/20260821210000_…` a `…20260929140000_…`: las 354 migraciones de
   `Ronda-app/supabase/migrations`, mismo nombre y timestamp, pasadas por
   `scripts/portar-de-ronda.mjs` (el prefijo `ronda_` → `helios_`; reglas en su
   cabecera). Ninguna editada a mano.
2. `20261001000000_la_poda_de_la_app.sql`: quita todo lo que era de la app o de
   la noche (PIN, KYC, push, grupos, QR, Bits, bóveda, catálogo, `my_*`…) con
   `drop … restrict`, y arregla con `create or replace` lo que se queda y
   dependía de ello.
3. `20261001000100…000400`: plpgsql_check y tres arreglos que encontraron la
   verificación y las suites.

4. Fase 1A, cimientos de Helios (`20261002…`):

   | Migración | Qué hace |
   |---|---|
   | `000100_el_precio_se_pacta_en_dolares` | H1: `BCV` = dólar (el euro de Ronda archivado como `BCV_EUR`), espejos del dólar, `€` → `$` en funciones y plantillas, niveles (solo el 1 = $350), parámetros nuevos y sus lectores, el mínimo por parámetro (`helios_assert_charge_amount`) |
   | `000200_el_dia_operativo_empieza_a_medianoche` | H2: `helios_business_date` = día de Caracas; fuera el desfase de 10 h en todas sus copias |
   | `000300_el_paciente_no_tiene_cuenta` | H3: `profiles` sin Auth, FK del deudor a `profiles`, teléfono no único, datos nuevos del paciente, ayudantes de normalizar/enmascarar, `profile_change_requests`, fuera el acceso `*_read_own` |
   | `000400_las_clinicas_tienen_categoria_medica` | H8: valores nuevos de `merchant_category` (solos, por ser `add value`) |
   | `000500_el_personal_de_una_clinica` | H8: ficha médica de la clínica, `merchant_payout_accounts` y sus RPC, sin rol `inventario` |
   | `000600_el_contacto_de_helios_se_configura` | H11: `platform_contact`, `helios_config_status`, varias cuentas de cobro activas |
   | `000700_los_mensajes_salen_de_una_cola` | H11 + base de H6/H7: canales de plantilla, plantillas de Helios, `outbound_messages`, `helios_enqueue_message`, `helios_enqueue_charge_receipt`; las plantillas de la app, apagadas |

5. Fase 1B, registrar un financiamiento y la comisión (`20261003…`):

   | Migración | Qué hace |
   |---|---|
   | `000100_las_consultas_de_cedula_quedan_anotadas` | `eligibility_lookups` (límite diario y alerta de consultas) |
   | `000200_la_comision_tiene_cuenta_en_el_libro` | Valores de enum `commission_expense`, `staff_commission` (asiento y liquidación) |
   | `000300_el_financiamiento_guarda_sus_terminos_y_su_comision` | H9: `terms_versions.id` + v1; `charges.concept/beneficiary_name/terms_version_id/staff_commission_usd/commission_staff_id`; `merchant_terms.staff_commission_usd`; `staff_commissions` (+ trigger a `pagada`); `merchant_payouts.consultas_usd/comisiones_usd`; `helios_staff_commission_for` |
   | `000400_registrar_un_financiamiento` | H4: `helios_patient_eligibility`, `preview_patient_charge`, `create_patient_charge`, `staff_resend_receipt`, `helios_charge_for_staff` (jsonb), devengo de la comisión |
   | `000500_la_comision_se_liquida_los_lunes` | H5: el techo del cron y de la previsión sin la comisión, previsión y transferencias partidas, reversa de la comisión, `admin_set_settlement_terms(…, p_staff_commission_usd)`, `merchant_commissions`, `merchant_commission_items` |
   | `000600_la_clinica_ve_sus_financiamientos` | `merchant_transactions`, `merchant_charge_detail`, `merchant_sales_by_staff`, exportación en `*_usd`, `admin_charge_detail`, `admin_charges` |
   | `000700_los_datos_del_paciente_se_cuidan_en_helios` | `admin_user_detail.datos`, `admin_update_patient_contact`, `admin_profile_change_requests`, `admin_resolve_profile_change` |
   | `000800_el_superadmin_ve_la_ficha_completa` | `admin_user_directory` (+2 columnas), comisión en `admin_merchant_detail`/`admin_merchant_terms_history`, propuestas con `proposed`/`current` |

6. Fase 1C, correo, avisos, pagos y alertas (`20261004…`):

   | Migración | Qué hace |
   |---|---|
   | `000100_el_comprobante_sale_por_correo` | H6: despacho a Resend desde la base (cron cada minuto, reintentos, `Idempotency-Key`), estado cada 15 min (rebote → `email_invalid_at`), el comprobante nuevo, `admin_resend_receipt`. Sin el secreto `resend_api_key` en Vault no hace nada |
   | `000200_los_avisos_los_manda_una_persona` | H7: 5 momentos por vencimiento en `outbound_messages` (crons `helios_aviso_*`; fuera los 12 de Ronda), cancelar al pagar, `pago_recibido`/`pago_rechazado`/`cuenta_congelada`, la cola del equipo |
   | `000300_el_equipo_registra_los_pagos` | `admin_register_payment`, bucket `payment-receipts`, doble control en `admin_reconcile_payment`, cruce con el extracto por la fecha del pago |
   | `000400_las_alertas_de_las_clinicas` | H10: las alertas nuevas de `admin_risk_alerts` |
   | `000500_el_historial_de_correos_dice_los_rebotados` | `admin_outbound_history(p_status => 'rebotado')` y `'entregado'` |

Todo el detalle de la poda —qué se borró, qué se tocó y por qué— está en
`poda/NOTAS.md`; el de cada migración de Helios, en su cabecera.

## Aplicar migraciones nuevas (sin Docker)

```bash
node supabase/poda/aplicar.mjs --pendientes   # qué falta
node supabase/poda/aplicar.mjs                # aplica lo pendiente, en orden
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb \
  -f supabase/poda/verificar.sql              # cero filas «error» (ver abajo)
bash supabase/tests/run.sh                    # suites en verde
```

`aplicar.mjs` usa `supabase db query --linked --project-ref <ref>` (Management
API; solo necesita la sesión del CLI, no la contraseña de la base). Por cada
archivo pendiente manda **en una sola transacción** el SQL y el INSERT en
`supabase_migrations.schema_migrations` (la misma tabla y forma que usa el CLI),
así que: si falla, no queda nada a medias; se para en el primer error; y al
volver a correrlo sigue por la primera que falta. Otro proyecto:
`--project-ref <ref>` o `HELIOS_PROJECT_REF`. `--hasta <version>` para parar
antes; `--marcar <version>` registra una versión sin correrla (solo si se
aplicó a mano).

Como `db push`, una migración no puede llevar `create index concurrently`,
ni usar en el mismo archivo un valor de enum recién añadido, ni
`begin`/`commit` de primer nivel.

Una migración nueva: `supabase/migrations/YYYYMMDDHHMMSS_frase_en_espanol.sql`
(p. ej. `20261002100000_el_paciente_no_tiene_cuenta.sql`), con cabecera que
explique el porqué, como las de Ronda. El timestamp tiene que ser posterior al
último aplicado.

## Verificar

```bash
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb -f supabase/poda/verificar.sql
```

Devuelve una tabla `tipo · nivel · objeto · detalle`. **Cero filas `error`** es
verde. Mira: todas las funciones plpgsql con plpgsql_check (Postgres no valida
sus cuerpos al crearlas), las `language sql` re-ejecutando su definición, que
cada vista planifique, y lista los crons. Va en begin/rollback. Los avisos
aceptados están en `poda/NOTAS.md`.

## Portar una migración futura de Ronda

```bash
node scripts/portar-de-ronda.mjs ../Ronda/Ronda-app/supabase/migrations/<archivo>.sql supabase/migrations/<archivo>.sql
node scripts/portar-de-ronda.mjs --informe supabase/migrations/<archivo>.sql   # los "ronda" que quedan, con contexto
```

1. Revisa el diff contra el original: solo deben cambiar `ronda_` → `helios_`,
   las GUC `ronda.` y la palabra «Ronda» en textos.
2. **¿Toca algo podado?** Si la migración crea o redefine algo de la clase B
   (grupos, push, KYC, `confirm_charge`, bóveda…), o una función A que vuelve
   a leer una tabla podada, quita ese trozo del archivo portado y anótalo en
   `poda/NOTAS.md`. `verificar.sql` lo detecta si se te pasa.
3. **Timestamp**: si el de Ronda es anterior a la última migración de Helios,
   renombra el archivo con un timestamp nuevo (el runner y `db push` aplican en
   orden).
4. `aplicar.mjs` → `verificar.sql` → `tests/run.sh`.

Para una carpeta entera: `node scripts/portar-de-ronda.mjs --dir <entrada> <salida>`.

## Pruebas

```bash
bash supabase/tests/run.sh            # todas contra el remoto
bash supabase/tests/run.sh mora_smoke # una
```

Cada suite va en begin/rollback: no deja datos. Detalle, adaptaciones y
pendientes en `tests/README.md`.

## Local (opcional)

`config.toml` sigue sirviendo para `supabase start` si algún día hay Docker
(`[db.seed]` está apagado hasta que exista `seed.sql`). Nada de lo anterior lo
necesita.
