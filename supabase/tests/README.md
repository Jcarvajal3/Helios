# Pruebas de humo del esquema

Suites SQL portadas de Ronda (`Ronda-app/supabase/tests`) con
`scripts/portar-de-ronda.mjs` y adaptadas a Helios. Son asserts en PL/pgSQL:
cada fallo es un `RAISE EXCEPTION`. Cada suite abre una transacción y termina
en `rollback`, con `set constraints all immediate` antes para que el cuadre
diferido del ledger llegue a dispararse. **Nunca dejan datos en la base.**

```bash
bash supabase/tests/run.sh                  # todas, contra Helios (remoto)
bash supabase/tests/run.sh ledger_smoke     # solo algunas
HELIOS_PROJECT_REF=<ref> bash supabase/tests/run.sh   # otro proyecto
```

Van por `supabase db query --linked --project-ref …` (Management API), sin
Docker ni contraseña. La API no devuelve los NOTICE: no hay recuento de
asserts, una suite está en verde si no sale ningún `ERROR:`. `run.sh` se niega
a correr una suite que no tenga `begin;` y `rollback;`.

## `_ayudas.sql` y `-- @ayudas`

En Ronda la deuda nacía de `request_charge` + `confirm_charge` (el QR y el
PIN), que la poda quitó. Hasta que exista `create_patient_charge` (H4), las
suites crean deuda con `pg_temp.prueba_cobro(...)`, que hace lo mismo que
`confirm_charge` sin PIN ni reclamo: el mismo desglose, el mismo asiento de
cuatro patas, el mismo devengo y `helios_assign_debt`. `pg_temp.prueba_saldo`
devuelve lo que devolvía `my_available_balance()` (podada) y
`pg_temp.prueba_admin()` crea un super admin (la base nace sin equipo).

`run.sh` pega `_ayudas.sql` donde la suite dice `-- @ayudas` (justo después de
su `begin;`): las funciones viven en `pg_temp` y se van con el rollback.

## Estado (2026-09-30)

| Suite | Estado | Adaptación |
|---|---|---|
| `ledger_smoke` | ✓ | `prueba_cobro`/`prueba_saldo`; nivel 1 fijado a $50 en la prueba |
| `mora_smoke` | ✓ | `prueba_cobro` |
| `payment_smoke` | ✓ | `prueba_cobro`/`prueba_saldo`; siembra una cuenta de cobro; `my_installments_in_review()` → consulta directa; borra de `merchant_terms` (la vista no se puede borrar) |
| `admin_smoke` | ✓ | `prueba_cobro` |
| `admin_merchants_smoke` | ✓ | Era `admin_kyc_merchants_smoke`: sin las 5 pruebas de KYC; `admin_add_merchant_staff` → `merchant_staff_add` |
| `merchant_payout_smoke` | ✓ | `prueba_cobro`; nivel 3 fijado a $200; acción de bitácora `merchant.payout` |
| `statement_smoke` | ✓ | `prueba_cobro` |
| `edit_merchants_smoke` | ✓ | `prueba_cobro`; `admin_remove_merchant_staff` → `merchant_staff_remove` |
| `level_promotion_smoke` | ✓ | — |
| `due_dates_smoke` | ✓ | — |
| `saldo_smoke` | ✓ | `prueba_cobro`/`prueba_saldo` |
| `fx_rate_smoke` | ✓ | — |
| `metricas_cimientos`, `metricas_general`, `metricas_semana`, `metricas_semana_resumen`, `metricas_locales`, `metricas_cobranza` | ✓ | `prueba_admin()`; sin `admin_nights`; las dos primeras envueltas en begin/rollback. Son de «mirar a ojo»: con la base vacía solo prueban que las RPC contestan y los permisos |

Varias suites de Ronda estaban en rojo contra el esquema final de Ronda (se
quedaron atrás de renombres: `admin_add_merchant_staff`,
`admin_remove_merchant_staff`, `merchant.paid`, `merchant_settlement_terms`
como tabla, niveles de $50/$200). Aquí se pusieron al día; conviene llevar los
mismos arreglos a Ronda.

### Pendientes (no están en `run.sh`)

| Suite | Por qué | Cuándo |
|---|---|---|
| `notifications_smoke` | Prueba avisos de grupo, `my_notifications()` y la cola de push | H7 (avisos por WhatsApp/correo en `outbound_messages`) |
| `profile_smoke` | Prueba `my_purchases()` y consumos en grupo: la vista del usuario en la app | H3 (el paciente no tiene cuenta); reescribir sobre las fichas del admin |
| `nivel_cero_smoke` | El primer nivel lo daba el KYC aprobado | H3 (el paciente nace activo con nivel 1) |
| `facturacion.test.mjs` | Node + `pg` con `SUPABASE_DB_URL`, y usa `confirm_charge` | H4 (reescribir contra `create_patient_charge`) |
| `metricas_cohortes` | Necesita cohortes con datos (`'null' - 'cuotas'` revienta con la base vacía) | Con la semilla de métricas (docs/00 §9) |
| `metricas_gente-caja` | Usa `admin_growth_funnel` (el embudo de KYC, podado) y datos | Al rehacer Métricas › Gente (H3) |
| `metricas_coherencia*.sql` | Baterías de coherencia contra datos de dev, no pruebas en begin/rollback. Varias usan `admin_nights` (podada) | Al revisar métricas (H2: el día a medianoche) |

### Borradas (solo probaban la clase B)

`groups_smoke`, `grupos.test.mjs`, `kyc_confirm_smoke`, `kyc_aprobar_sin_datos`,
`push_smoke`, `promo_smoke`, `bits_smoke`, `charge_claim_smoke` (el reclamo del
QR), `metricas_avisos`, `metricas_coherencia_avisos` (push),
`metricas_coherencia_registro` (el registro por KYC),
`metricas_coherencia_prod_antes` (una foto de producción de Ronda).
