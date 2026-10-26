#!/usr/bin/env bash
# ============================================================================
# Helios — Corre todas las pruebas de humo del esquema contra el remoto
#
#   bash supabase/tests/run.sh                 # todas las suites
#   bash supabase/tests/run.sh ledger_smoke    # solo las que se nombren
#   HELIOS_PROJECT_REF=<ref> bash supabase/tests/run.sh   # otro proyecto
#
# Sin Docker: cada suite va por `supabase db query --linked --project-ref`,
# que usa la Management API (no hace falta la contraseña de la base). Por
# defecto contra el proyecto Helios (ahyfbnfsbyzdoyjzjvfb).
#
# Cada suite abre una transacción, ejerce el sistema y hace ROLLBACK, así que
# no deja nada escrito. Antes del rollback fuerza `set constraints all
# immediate` para que los constraint triggers DIFERIDOS del ledger (el cuadre
# de partida doble) sí lleguen a dispararse. Este script se NIEGA a correr una
# suite que no empiece con `begin;` y termine con `rollback;`.
#
# Las suites que necesitan crear deuda llevan la línea `-- @ayudas` justo
# después de su `begin;`: aquí se sustituye por `_ayudas.sql`
# (`pg_temp.prueba_cobro`, `pg_temp.prueba_saldo`), que vive en la misma
# transacción y se va con el rollback. Ver tests/README.md.
#
# ⚠️ La Management API devuelve solo el ÚLTIMO resultado y no devuelve los
# NOTICE: no hay recuento de asserts. Una suite está en verde si no hay ningún
# `ERROR:` en la salida (cada assert fallido es un RAISE EXCEPTION).
# ============================================================================
set -uo pipefail

REF="${HELIOS_PROJECT_REF:-ahyfbnfsbyzdoyjzjvfb}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$DIR/../.." && pwd)"

# Las suites de la clase A que corren en Helios. Las que esperan a una fase
# posterior están en tests/README.md («Pendientes»).
SUITES=(
  ledger_smoke
  mora_smoke
  payment_smoke
  admin_smoke
  admin_merchants_smoke
  merchant_payout_smoke
  statement_smoke
  edit_merchants_smoke
  level_promotion_smoke
  due_dates_smoke
  saldo_smoke
  fx_rate_smoke
  helios_cimientos_smoke
  patient_charge_smoke
  patient_confirmation_smoke
  eligibility_smoke
  staff_commission_smoke
  proximos_pagos_smoke
  metricas_cimientos
  metricas_general
  metricas_semana
  metricas_semana_resumen
  metricas_juan_pablo
  metricas_locales
  metricas_cobranza
  email_dispatch_smoke
  whatsapp_dispatch_smoke
  whatsapp_webhook_smoke
  bot_smoke
  paciente_bot_smoke
  reminders_smoke
  register_payment_smoke
  risk_alerts_smoke
  recorrido_completo_smoke
  moneda_smoke
  sin_mora_smoke
  afiliacion_smoke
  bienvenida_personal_smoke
  aviso_transferencia_smoke
  bienvenida_medico_whatsapp_smoke
  pago_masivo_smoke
  registro_pago_masivo_smoke
  bank_sms_smoke
  lector_comprobantes_smoke
  margen_de_pago_smoke
  pago_duplicado_smoke
  datos_de_contrato_smoke
  demo_smoke
  mensajes_paciente_smoke
  seguimiento_smoke
  agenda_smoke
)
if [ "$#" -gt 0 ]; then SUITES=("$@"); fi

run_suite() {
  local archivo="$1" tmp salida intento
  tmp="$(mktemp "${TMPDIR:-/tmp}/helios-suite-XXXXXX.sql")"
  # `-- @ayudas` → contenido de _ayudas.sql
  awk -v ayudas="$DIR/_ayudas.sql" '
    /^-- @ayudas[[:space:]]*$/ { while ((getline l < ayudas) > 0) print l; close(ayudas); next }
    { print }
  ' "$archivo" > "$tmp"

  # Un fallo de CONEXIÓN del CLI (su rol temporal de login a veces no entra)
  # no es un fallo de la suite: se reintenta. Un error del SQL no.
  for intento in 1 2 3; do
    salida="$(cd "$RAIZ" && supabase db query --linked --project-ref "$REF" -f "$tmp" 2>&1)"
    if echo "$salida" | grep -q 'failed to connect' && ! echo "$salida" | grep -q 'Failed to run sql query'; then
      sleep $((intento * 3)); continue
    fi
    break
  done
  rm -f "$tmp"
  echo "$salida"
}

failed=0
for suite in "${SUITES[@]}"; do
  archivo="$DIR/$suite.sql"
  if [ ! -f "$archivo" ]; then
    printf '✗ %-28s no existe\n' "$suite"; failed=1; continue
  fi
  # Nunca dejar datos de prueba: la suite tiene que ir en begin/rollback.
  if ! grep -qx 'begin;' "$archivo" || ! grep -qx 'rollback;' "$archivo"; then
    printf '✗ %-28s no va en begin/rollback: no se corre\n' "$suite"; failed=1; continue
  fi

  output="$(run_suite "$archivo")"
  if echo "$output" | grep -q 'ERROR:\|failed to connect'; then
    failed=1
    printf '✗ %s\n' "$suite"
    echo "$output" | grep 'ERROR:\|failed to connect' | sed 's/^/    /'
  else
    printf '✓ %s\n' "$suite"
  fi
done

echo
if [ "$failed" = "0" ]; then
  echo "TODO VERDE — ${#SUITES[@]} suites contra $REF (sin recuento de asserts: los NOTICE no vuelven por la Management API)"
else
  echo "HAY FALLOS"
fi
exit $failed
