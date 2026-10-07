# Estado del trabajo

Actualizado el 2026-10-07.

## 2026-10-07 · La consulta se cobra en dólares o en euros

Plan §1 y contrato §7. El médico elige la moneda en el paso del monto (panel y bot). Una orden en euros queda en euros: el paciente paga en Bs a la tasa BCV del euro del día en que paga y a la clínica se le paga a la del euro. El libro, el límite, la mora y el superadmin siguen en dólares. El paciente solo paga en bolívares (Pago Móvil o transferencia).

- **Base:** migraciones `20261007000100`–`000700` aplicadas: la tasa del euro vuelve a entrar a diario (`BCV_EUR`), columnas `_cur`, cotización y pagos a la clínica por moneda, mensajes con moneda y bolívares, cobranza por moneda, fuera Zelle/USDT/efectivo del paciente. 33/33 suites en verde (nueva: `moneda_smoke`). `plpgsql_check` sin errores nuevos.
- **Panel:** `tsc`, lint, build y 116/116 tests en verde; `verificar-contrato.mjs`: 172 llamadas a 157 RPC, todo cuadra. Sin probar en el navegador (hace falta una sesión de la clínica y del superadmin).
- **Sin cargos por mora** (migración `000800`): `late_fee_usd` = 0 desde el 2026-10-07; el motor sigue en el código y los textos del cargo vuelven solos si el parámetro vuelve a valer algo (los Términos públicos, a mano). Suite nueva `sin_mora_smoke`: 34/34 en verde.
- **Bot:** `whatsapp-webhook` desplegado (v7) el 2026-10-07. Paso nuevo de moneda en el bot del médico y montos por moneda en el del paciente; sus tests en verde con `npx tsx`.
- **Pendiente:**
  - La plantilla v3 de Meta (§15.5.2) cambia: sin «$» delante de las variables y con 13 variables.
  - Los agregados de la clínica (métricas, pagos) siguen en dólares con la nota «equivalente en dólares».

## 2026-10-06 · Las reglas del negocio publicadas

Plan §0.1. Comisión de servicio **12% + IVA**, límite inicial **$150**, a la clínica **a los 8 y 15 días** (a diario, ya no los lunes), cosmetología, operador **Quarto Latam, C.A.**, y vocabulario externo sin «financiamiento» ni «préstamo». Portada nueva con «Quiero afiliarme» y `/legal/terminos`.

- **Base:** migraciones `20261006001000`–`001300` y `002000`–`002100` aplicadas. 32/32 suites en verde; `verificar-contrato.mjs`: 170 llamadas a 155 RPC, todo cuadra.
- **Panel:** `tsc`, lint, build y 116/116 tests en verde.
- **Pendiente:**
  - Desplegar `whatsapp-webhook` (los textos nuevos del bot están en el repo, sin desplegar).
  - Crear y aprobar en Meta la plantilla v3 `helios_confirmar_pago_en_cuotas` (§15.5.2). Hasta entonces, fuera de la ventana de 24 h la pregunta al paciente va a la cola manual.
  - Publicar el WhatsApp de afiliación en `panel/src/config/legal.ts` y el RIF de Quarto Latam.

## Hecho y verificado

| Fase | Estado |
|---|---|
| 0 · BD | ✅ Historia de Ronda portada y poda de la app |
| 1A · BD | ✅ Dólar BCV y nivel 1 = $350, día a medianoche, paciente sin cuenta, clínicas médicas, contacto y cuentas configurables, cola de mensajes |
| 1B · BD | ✅ Elegibilidad privada, `create_patient_charge`, comisión de la secretaria (devengo, lunes, reversa), RPC de clínica y superadmin |
| 1C · BD | ✅ Comprobante por correo (Resend, apagado hasta configurar la clave), 5 avisos por vencimiento, registro de pagos del equipo con doble control, alertas |
| Arreglos de integración | ✅ Alerta de cédulas que sí salta; la reversa cancela sus avisos; cuentas de cobro por id y método; datos médicos editables; referencia con teléfono fijo |
| 0/2/3 · Panel | ✅ Clínica y superadmin |

**Verificación (2026-10-01):**
- **Base:** `plpgsql_check` sin errores (las 14 advertencias aceptadas de siempre) y 26/26 suites SQL en verde contra Helios.
- **Panel:** `tsc`, lint y build en verde, y 116/116 tests.
- **Contrato panel ↔ base:** `node scripts/verificar-contrato.mjs` → las 163 llamadas del panel a 148 RPC cuadran con las firmas reales de Helios.

El código está en GitHub (`origin/main`).

## Prueba de punta a punta

✅ `supabase/tests/recorrido_completo_smoke.sql` sigue un financiamiento entero contra Helios. Paso por paso:

1. Alta en la clínica.
2. Asientos contables.
3. Comprobante enviado (con Resend simulado).
4. Avisos.
5. Pago registrado por el equipo y conciliado contra el extracto.
6. Mora: congelada el día 1 y cargo de $2 el día 4.
7. Segundo pago.
8. Cierre del lunes con 100 + 0,50 de comisión.
9. Transferencia y bitácora.

Al final la caja sube exactamente 24,70 (fee 20 + IVA 3,20 + cargo 2 − comisión 0,50) y el libro cuadra. Con ella son **27/27 suites en verde**.

## Para probar el panel en el navegador

Hace falta que el usuario cree **su** cuenta de super admin (no la crea Claude):

1. Abrir `supabase/bootstrap_superadmin.sql`, poner correo, contraseña y nombre, y ejecutarlo en el SQL Editor del proyecto Helios. **No guardar el fichero con los datos.**
2. Arrancar el panel con `cd panel && npm run dev` (`panel/.env` ya apunta a Helios, con la clave publicable) y entrar en <http://localhost:3000/login>.
3. Desde el superadmin:
   - dar de alta una clínica y su personal (administrador y secretaria);
   - configurar Ajustes › Contacto y Ajustes › Cuentas de cobro.

## Pendiente

- **Resend:** verificar el dominio (SPF, DKIM, DMARC), guardar la clave en Vault con el nombre `resend_api_key` y poner el remitente en Ajustes › Contacto. Los pasos exactos están en `supabase/README.md`.
- **Despliegue en Vercel** del panel: proyecto, variables y dominio.
- **Producción separada:** hoy Helios es el único proyecto de Supabase. Antes de tener pacientes reales hay que crear el de producción.
- **Textos legales:** `/soporte` y `/legal/privacidad`, con la razón social y el RIF de Helios (D-H10).
- **Decisiones abiertas** (§13.2 del plan): monto mínimo (hoy $10, parametrizable) y razón social.
