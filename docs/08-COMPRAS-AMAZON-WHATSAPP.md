# 08 — Compras Amazon para Médicos (WhatsApp + Superadmin)

> **Estado:** Implementado de punta a punta con proveedor mock (`ProveedorAmazonMock`, 24 productos médicos) y adaptador de producción listo (`ProveedorRainforest`). Solo falta conectar la API key del proveedor de Amazon elegido y desplegar `whatsapp-webhook` cuando se active el flujo en el número de producción.

---

## 1. Resumen del producto

Permite a los médicos y al personal autorizado de clínicas aliadas buscar productos médicos en Amazon EE. UU. directamente desde el bot de WhatsApp de Helios, recibir una cotización todo incluido puesta en Venezuela (producto + impuesto EE. UU. + flete aéreo o marítimo + gestión Helios), pagar **100% de contado en bolívares a tasa BCV del día de pago** (mismo proceso de comprobantes y conciliación que los pacientes) y recibir avisos de seguimiento logístico hasta la entrega.

Todo se administra desde el Superadmin en **`/admin/compras`** (Solicitudes, Pagos por aprobar, Simulador WhatsApp y Ajustes).

---

## 2. Arquitectura implementada

### 2.1 Base de datos (`supabase/migrations/20261124120000_compras_amazon_para_medicos.sql`)
- **100% aditiva:** no altera ninguna tabla ni flujo de pacientes o liquidaciones a clínicas (`charges`, `installments`, `payment_reports`, `ledger`).
- **WhatsApp Cloud API (`360dialog`):**
  - `helios_whatsapp_payload(public.outbound_messages)` extendida de forma retrocompatible para soportar `interactive` tipo `carousel` (2..10 Media Cards) y `list` dentro de la ventana de 24 horas.
  - `helios_whatsapp_carousel(p_to, p_body, p_cards, p_staff_user_id)` para encolar carruseles de resultados.
- **Tablas nuevas (RLS habilitado, sin acceso directo a `anon`/`authenticated`):**
  - `public.purchase_settings`: tarifas configurables (`tax_usa_pct`, `service_fee_pct`, `air_rate_per_lb_usd`, `air_min_usd`, `sea_rate_per_ft3_usd`, `sea_min_usd`, `fallback_weight_lb`, `quote_ttl_hours`, `catalog_provider`, `is_enabled`).
  - `public.amazon_catalog_cache`: caché temporal de búsquedas y fichas ASIN (`cache_key`, `kind`, `provider`, `payload`, `expires_at`).
  - `public.purchase_requests`: solicitudes `#C-1001+` con snapshot del producto, peso real/volumétrico, volumen ft³, bandera aduanal (`restricted_flag`), desglose congelado (`numeric(18,4)` USD, `numeric(18,2)` VES, `numeric(18,6)` tasa BCV), canal (`whatsapp` | `simulador`) y ciclo logístico completo.
  - `public.purchase_payment_reports`: reportes de pago en bolívares (`pago_movil` | `transferencia`), bucket privado `payment-receipts` bajo `compras/<request_id>/<archivo>`, tolerancia de cuadre `helios_monto_cuadra` (−10 / +100 Bs), detección de referencias duplicadas y doble control (`payment_four_eyes`, excepto `super_admin`).
  - `public.purchase_request_events`: línea de tiempo append-only protegida con triggers contra `UPDATE`/`DELETE`.
  - `public.purchase_simulator_messages`: historial del simulador en Superadmin, **totalmente aislado de `outbound_messages`** (nunca envía mensajes reales a 360dialog).

### 2.2 Bot de WhatsApp y Catálogo desacoplado (`supabase/functions/whatsapp-webhook/`)
- `compras/tipos.ts`: interfaz `ProveedorCatalogo` (`buscar`, `detalle`) y tipos normalizados.
- `compras/amazon_parser.ts`: extractor de ASIN/URLs de Amazon, traductor médico ES→EN y clasificador de restricciones sanitarias/aduanales.
- `compras/cotizador.ts`: cálculo exacto en centavos (espejo de `helios_purchase_calculate`).
- `compras/catalogo_mock.ts`: `ProveedorAmazonMock` con 24 productos médicos (incluyendo equipos pesados para marítimo, producto sin peso listado y artículos restringidos en aduana).
- `compras/catalogo_rainforest.ts`: `ProveedorRainforest` listo para `https://api.rainforestapi.com/request` y fábrica `crearProveedorCatalogo(provider, apiKey)`.
- `compras/flujo.ts`: máquina de estados (`compra_buscar`, `compra_resultados`, `compra_envio`, `compra_confirmar`, `compra_pago`, `compra_pago_datos`) reutilizando `datos_pago.ts`.
- `bot.ts`: agrega «Comprar en Amazon» (`menu:comprar`) al menú de 3 botones de médicos y delega los estados/atajos de compra sin afectar el flujo de pagos en cuotas de pacientes.

### 2.3 Superadmin y Simulador (`panel/`)
- `/admin/compras` (`panel/src/routes/admin/compras.tsx`):
  - **Solicitudes:** KPIs, filtros por estado/canal/búsqueda, exportación CSV y acceso a fichas.
  - **Pagos por aprobar:** cola de `purchase_payment_reports` con verificación BCV, margen de cuadre y `VerCaptura`.
  - **Simulador WhatsApp:** pruebas end-to-end sin Telegram ni 360dialog (selector de médico real, carrusel horizontal de Media Cards, botones interactivos, subida real de captura a `payment-receipts` o PNG de prueba, recepción en vivo de avisos al conciliar desde el panel).
  - **Ajustes:** edición de tarifas por `super_admin` con registro en `audit.admin_actions`.
- `/admin/compras/$id` (`panel/src/routes/admin/compras_.$id.tsx`): ficha operativa (`MarcoDeFicha carrilFijo`) con revisión aduanal, registro manual de pago con preview BCV, conciliación (`Aprobar` / `Rechazar` / `En revisión` / `Duplicado`), avance logístico (`comprado_amazon` → `en_almacen_usa` → `en_transito` → `en_aduana` → `listo_entrega` → `entregado`) y timeline.

---

## 3. Cómo activar la API real de Amazon (3 pasos)

Cuando contraten el proveedor (por ejemplo, **Rainforest API**):

1. **Configurar secretos de la Edge Function en Supabase:**
   ```bash
   supabase secrets set AMAZON_PROVIDER=rainforest AMAZON_API_KEY=<TU_API_KEY> --project-ref ahyfbnfsbyzdoyjzjvfb
   ```
2. **Cambiar el proveedor en Superadmin › Compras Amazon › Ajustes:**
   - Seleccionar `Rainforest API` y guardar (requiere rol `super_admin`).
3. **Desplegar `whatsapp-webhook`:**
   ```bash
   supabase functions deploy whatsapp-webhook --no-verify-jwt --use-api --project-ref ahyfbnfsbyzdoyjzjvfb
   ```

*(Si eligen otro proveedor como Oxylabs o Decodo, basta crear `compras/catalogo_<proveedor>.ts` implementando `ProveedorCatalogo` y registrarlo en `crearProveedorCatalogo` dentro de `catalogo_rainforest.ts`.)*

---

## 4. Comandos de verificación

```bash
# Pruebas SQL (en transacción con rollback)
bash supabase/tests/run.sh compras_amazon_smoke

# Pruebas del bot y catálogo Amazon
npx tsx supabase/functions/whatsapp-webhook/compras/compras.test.ts
npx tsx supabase/functions/whatsapp-webhook/bot.test.ts

# Contrato RPC entre panel y Postgres
node scripts/verificar-contrato.mjs

# Panel Superadmin
cd panel && npm run generate-routes && npx tsc --noEmit && npm run lint && npm run build
```
