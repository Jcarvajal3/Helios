# Estado del trabajo — pausado el 2026-09-30

Se pausó a petición del usuario. Retomar desde aquí.

## Hecho y verificado

| Fase | Estado | Dónde |
|---|---|---|
| 0 · BD | ✅ Historia de Ronda portada + poda de la app. `plpgsql_check` 0 errores, suites en verde | `supabase/migrations/2026082*…20261001*` |
| 1A · BD | ✅ H1 dólar y niveles ($350), H2 medianoche, H3 paciente sin cuenta, H8 clínicas médicas + cuenta de pago, H11 contacto, varias cuentas de cobro y `outbound_messages` | `supabase/migrations/20261002*` |
| 0 · Panel | ✅ Fork podado, vocabulario médico, USD, marca y tokens | `panel/`, `tokens/` |
| 2 · Panel clínica | ✅ En `main`: `/registrar`, `/financiamientos`, `/comisiones`, `/pagos`, `/metricas`. Typecheck, lint, build y tests en verde | `panel/src/routes/_comercio*`, `panel/src/features/merchant/` |
| 3 · Superadmin | ✅ En `main`: registrar pago, avisos de hoy y correos, contacto y cuentas, datos del paciente y cambios propuestos, clínicas, alertas, textos | `panel/src/routes/admin*`, `panel/src/components/admin/`, `panel/src/features/admin/` |

## Interrumpido a mitad (hay que terminarlo al retomar)

Ninguna de las dos fases llegó a dar su reporte final, así que **lo aplicado no se ha verificado con `verificar.sql` ni con las suites**.

### 1B · BD (registro del financiamiento y comisiones), prefijo `20261003`
- **Aplicadas en Helios:** `000100` a `000700`:
  - registro de consultas de cédula;
  - comisión en el libro;
  - términos y comisión en el financiamiento;
  - `create_patient_charge`;
  - liquidación de comisiones los lunes;
  - RPC de la clínica;
  - datos del paciente.
- **Quedaba:**
  - registrar sus suites en `supabase/tests/run.sh` (el fichero está modificado y sin probar);
  - correr `verificar.sql` y todas las suites;
  - confirmar lo que pidieron los paneles (ver abajo).

### 1C · BD (correo, avisos, pagos, alertas), prefijo `20261004`
- **Aplicadas en Helios:** `000100` comprobante por correo (Resend), `000200` avisos (5 momentos), `000300` registro de pagos por el equipo.
- **Escritas sin aplicar**, apartadas en `supabase/pendiente/` para que el runner no las aplique: `000400` alertas de las clínicas, `000500` historial de correos con rebotados. El agente estaba reescribiendo las claves de `detail` de las alertas, así que **pueden estar incompletas**: revisar antes de devolverlas a `migrations/`.
- **Suites nuevas sin verificar:** `email_dispatch_smoke`, `reminders_smoke`, `register_payment_smoke`, `risk_alerts_smoke`.

### Lo que los paneles esperan de la BD (y aún no está confirmado)

**Clínica:**
- `p_patient.phone` y `reference_phone` llegan en formato nacional; la referencia admite fijo 02XX.
- `merchant_transactions` mantiene `p_limit`.
- `merchant_commission_items` trae `staff_user_id` y `staff_name`.
- `merchant_settlement_outlook` trae `next_run_consultas_usd` y `next_run_comisiones_usd`.
- Los pagos traen `consultas_usd` y `comisiones_usd`, y la clínica puede leer `settlements(reason)`.
- `merchant_sales_by_staff.commission_usd`.
- `helios_charge_for_staff.breakdown.consumer_fee_pct`.

**Superadmin:**
- `admin_user_detail(p_user_id)` devuelve un objeto `datos`.
- Columnas de `admin_profile_change_requests` (`proposed`, `current`…).
- `admin_user_directory` añade `registered_merchant_name` y `email_invalid_at`.
- `staff_commission_usd` en las condiciones y en su historial.
- `consultas_usd` y `comisiones_usd` en lo pendiente de pago y en las transferencias.
- `admin_payment_queue` añade `registered_by_name` y `receipt_path`.
- `admin_outbound_history` trae `total_count` y acepta el estado `rebotado`.
- El doble control se rechaza con 42501 y el texto "doble control".
- Las claves de `detail` de las alertas.

**Desajustes conocidos entre el panel y la BD:**
- `admin_set_payment_destination` ya acepta `p_id` (1A), pero el panel identifica la cuenta por banco + RIF + teléfono. Hay que pasarlo a `p_id`.
- `admin_set_merchant_profile` ya acepta los datos médicos (1A), pero el panel los muestra solo en lectura. Hay que habilitar su edición.

## Siguiente paso al retomar

1. Terminar 1B: suites en `run.sh`, `verificar.sql`, `run.sh` completo.
2. Terminar 1C: revisar y aplicar `supabase/pendiente/*`, y verificar.
3. Integración: ajustar el panel y la BD a los desajustes de arriba, y probar de punta a punta contra Helios. El recorrido completo es alta en la clínica → comprobante → avisos → registrar pago → conciliar → cierre del lunes con comisión.
4. Fase 4: endurecimiento, textos legales y despliegue en Vercel. Subir a GitHub (`origin` ya configurado, **todavía sin push**).
