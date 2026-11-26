# Helios Lab — muestras y exámenes de laboratorio

Vertical nueva de Helios (brief de producto del 26-11-2026). El médico toma
la muestra en su consulta, el paciente paga en ese momento por Pago Móvil a la
cuenta de Helios, un driver la lleva al laboratorio y Helios le reenvía el
resultado al paciente. **No es pago en cuotas**: no toca `charges`,
`installments`, `settlements` ni el libro contable.

## 1. Decisiones (Javier, 26-11-2026)

| Tema | Decisión |
|---|---|
| Admin | Reusa el panel. Una entrada «Helios Lab» en el menú del superadmin abre `/lab` **en otra pestaña** (`target="_blank"`), con su propio marco. |
| Portal del médico | Dentro de su panel actual (`/_comercio/laboratorio`). |
| Interruptor | `lab_ajustes.modo`: `apagado` / `prueba` (solo clínicas con `merchants.is_test`) / `todos`. Lo cambia el superadmin. Nace `apagado`. |
| Cobro | El médico anota la referencia **y sube la captura** del Pago Móvil. La captura pasa por el **lector de comprobantes** que ya existe; el equipo confirma. |
| Pago al médico y al laboratorio | Solo se registra: la plataforma dice cuánto se debe y el equipo marca «pagado» con su referencia. Sin libro contable en la v1. |
| Laboratorios | **Varios desde ya**: un mismo examen puede tener precio base distinto en cada laboratorio; el médico elige el laboratorio. |
| Driver | Rol interno nuevo `driver` (como `cobranza`). Solo ve la ruta del día en su teléfono y marca paradas. |
| Resultados | El envío al paciente es **manual** (correo o WhatsApp por fuera). En la plataforma solo se marca «resultado entregado» y por qué canal. |
| Cargo de Helios | $15 fijos por examen (`lab_ajustes.cargo_helios_usd`), editable por el superadmin; cada muestra guarda su copia. |
| Moneda | Todo en **dólares**. El paciente paga en **bolívares** a la tasa BCV del día del registro (`tasa_bcv`, `monto_ves` guardados en la muestra). Un médico que factura en euros también ve Lab en dólares. |

**Excepción a la regla de «ningún total incluye la Comisión Helios»**: en Lab
el médico *debe* ver el precio final al paciente (base + cargo Helios + su
comisión) porque es él quien se lo dice. Se nombra «Cargo Helios», nunca
«Comisión Helios» ni «fee».

## 2. La muestra

```
lista_para_retirar → retirada → en_laboratorio → resultado_recibido → resultado_entregado
        └→ anulada (solo desde lista_para_retirar)
```

| Estado | Lo pone | Médico ve |
|---|---|---|
| `lista_para_retirar` | el médico al registrarla | «Lista para retirar» |
| `retirada` | el driver al completar la parada del consultorio | «Retirada» |
| `en_laboratorio` | el driver al completar la parada del laboratorio | «En el laboratorio» |
| `resultado_recibido` | el equipo (llegó el correo del laboratorio) | «Resultado listo» |
| `resultado_entregado` | el equipo (lo reenvió; canal `correo`/`whatsapp`) | «Resultado entregado» |
| `anulada` | médico o equipo, con motivo | «Anulada» |

El equipo puede corregir a mano cualquier paso (auditado).

Pago (`pago_estado`): `por_leer` → (lector) `cuadra` | `para_revisar` →
(equipo) `verificado` | `rechazado`. Sin captura nace `para_revisar`.
`cuadra` = el monto leído cuadra con `monto_ves` (`helios_monto_cuadra`) y la
referencia leída coincide (o termina igual) con la anotada.

## 3. Tablas (todas `public.lab_*`, RLS activa, sin políticas: solo RPC)

Dinero `numeric(18,4)` USD, VES `numeric(18,2)`, tasa `numeric(18,6)`.

- `lab_ajustes` — fila única (`id boolean primary key default true check (id)`):
  `modo text check in ('apagado','prueba','todos') default 'apagado'`,
  `cargo_helios_usd numeric(18,4) not null default 15 check (>= 0)`,
  `updated_at`, `updated_by`.
- `lab_kits` — `tipo text primary key check in ('sangre','orina','biopsia')`,
  `nombre`, `minimo_helios int` (alerta de reponer), `minimo_por_medico int`
  (sugerencia de dejar). Sembrada con los tres.
- `lab_laboratorios` — `id uuid`, `nombre`, `correo`, `telefono`,
  `direccion`, `activo`, `created_at`.
- `lab_examenes` — `id uuid`, `codigo text unique`, `nombre`,
  `kit_tipo references lab_kits`, `indicaciones text`, `activo`.
- `lab_precios` — `(laboratorio_id, examen_id)` pk, `base_usd > 0`, `activo`,
  `updated_at`.
- `lab_comisiones` — `(merchant_id, examen_id)` pk, `comision_usd >= 0`,
  `updated_at`, `updated_by`. La comisión es por examen, igual en todos los
  laboratorios. Sin fila = 0.
- `lab_muestras` — `id uuid`, `codigo text unique` («L-000123», secuencia),
  `merchant_id`, `branch_id null`, `registrada_por`, `paciente_nombre`,
  `paciente_whatsapp` (E.164), `paciente_correo null`, `examen_id`,
  `laboratorio_id`, `kit_tipo` (copia), `base_usd`, `cargo_helios_usd`,
  `comision_usd`, `precio_usd` (check = suma de los tres), `tasa_bcv`,
  `monto_ves`, `pago_referencia`, `pago_banco null`, `comprobante_path null`,
  `pago_estado`, `pago_nota`, `pago_revisado_por`, `pago_revisado_at`,
  `estado`, `parada_retiro_id`, `parada_entrega_id`, `retirada_at`,
  `en_laboratorio_at`, `resultado_recibido_at`, `resultado_entregado_at`,
  `resultado_canal`, `anulada_at`, `anulada_motivo`, `comision_pagada_at`,
  `comision_pago_ref`, `base_pagada_at`, `base_pago_ref`, `idempotency_key
  unique`, `created_at`. Índice único de la referencia normalizada (solo
  dígitos) mientras la muestra no esté anulada: una referencia no paga dos
  muestras.
- `lab_comprobante_lecturas` — cola del lector: `id`, `muestra_id`,
  `storage_path`, `mime`, `status in ('pendiente','leyendo','leida','fallida')`,
  `attempts`, `next_attempt_at`, `lectura jsonb`, `cuadra boolean`, `error`,
  `created_at`, `updated_at`.
- `lab_kit_movimientos` — append-only (trigger que impide update/delete):
  `id bigserial`, `tipo in ('entrada','entrega','uso','ajuste')`, `kit_tipo`,
  `cantidad int` (≠ 0; positiva salvo en `ajuste`), `merchant_id null`,
  `muestra_id null`, `parada_id null`, `nota`, `actor`, `idempotency_key
  unique`, `created_at`.
  - Stock de Helios = Σ entrada + Σ ajuste(sin médico) − Σ entrega.
  - Stock de un médico = Σ entrega − Σ uso + Σ ajuste(con médico).
  - Registrar una muestra escribe un `uso` de su kit (el stock del médico
    puede quedar negativo: se avisa, no se bloquea).
- `lab_kit_pedidos` — el médico pide kits: `id`, `merchant_id`, `kit_tipo`,
  `cantidad > 0`, `nota`, `estado in ('pendiente','en_ruta','entregado','cancelado')`,
  `parada_id`, `pedido_por`, `created_at`, `atendido_at`.
- `lab_rutas` — `id`, `fecha date unique`, `estado in ('borrador','en_curso','cerrada')`,
  `created_by`, `created_at`.
- `lab_paradas` — `id`, `ruta_id`, `orden int`, `tipo in ('consultorio','laboratorio')`,
  `merchant_id null`, `laboratorio_id null` (exactamente uno),
  `estado in ('pendiente','completada','saltada')`, `completada_at`,
  `completada_por`, `nota`.
- `lab_parada_kits` — kits a dejar: `parada_id`, `kit_tipo`, `cantidad > 0`,
  `pedido_id null`.

Bucket privado `lab-comprobantes` (10 MB, jpeg/png/webp/pdf). Ruta
`<merchant_id>/<uuid>.<ext>`. Política de insert para `authenticated` cuando
la primera carpeta es una clínica de la que es personal activo y Lab está
habilitado para ella; select para ese mismo personal y para el equipo
(`is_platform_admin()`).

## 4. Ayudas SQL

- `helios_lab_habilitado(p_merchant_id uuid) → boolean`: `modo = 'todos'` o
  (`modo = 'prueba'` y `merchants.is_test`).
- `helios_lab_rol(p_merchant_id uuid) → text`: `helios_staff_role_in` + Lab
  habilitado; si no, `42501`.
- `helios_puede_manejar() → boolean`: `helios_es_del_equipo(array['super_admin','operador','driver'])`.
- `helios_lab_tasa_hoy() → numeric`: `helios_fx_rate('USD', helios_business_date())`.

## 5. Contrato de las RPC

Errores con `raise exception … using errcode` como el resto (`42501` sin
permiso, `22023` dato inválido, `P0002` no existe). Toda escritura del equipo
→ `audit.log`. Las del médico se guardan con `registrada_por`/`updated_by`.

### 5.1 Panel del médico (`authenticated`, personal de la clínica)

| RPC | Parámetros | Devuelve | Quién |
|---|---|---|---|
| `lab_mi_acceso` | `p_merchant_id` | `jsonb {habilitado, modo, rol, cargo_helios_usd}`; nunca falla por no estar habilitado | gerente, cajero |
| `lab_precios` | `p_merchant_id` | filas `examen_id, codigo, nombre, kit_tipo, indicaciones, laboratorio_id, laboratorio_nombre, base_usd, cargo_helios_usd, comision_usd, precio_usd` (solo activos) | gerente, cajero |
| `lab_comision_set` | `p_merchant_id, p_examen_id, p_comision_usd` | `jsonb` fila nueva | gerente |
| `lab_muestra_cotizar` | `p_merchant_id, p_examen_id, p_laboratorio_id` | `jsonb {base_usd, cargo_helios_usd, comision_usd, precio_usd, tasa_bcv, monto_ves, fecha_tasa}` | gerente, cajero |
| `lab_muestra_registrar` | `p_merchant_id, p_examen_id, p_laboratorio_id, p_paciente_nombre, p_paciente_whatsapp, p_paciente_correo, p_pago_referencia, p_pago_banco, p_comprobante_path, p_idempotency_key` | `jsonb {id, codigo, precio_usd, monto_ves, tasa_bcv, pago_estado, kits_restantes}` (idempotente: misma clave → misma muestra) | gerente, cajero |
| `lab_muestra_anular` | `p_merchant_id, p_muestra_id, p_motivo` | `jsonb` | gerente, cajero; solo `lista_para_retirar` |
| `lab_mis_muestras` | `p_merchant_id, p_estado default null, p_busqueda default null, p_limit default 50, p_offset default 0` | filas con `total_count` | gerente, cajero |
| `lab_mis_kits` | `p_merchant_id` | filas `kit_tipo, nombre, en_consultorio, pedidos_pendientes` | gerente, cajero |
| `lab_kits_pedir` | `p_merchant_id, p_kit_tipo, p_cantidad, p_nota default null` | `jsonb` pedido | gerente, cajero |

`lab_muestra_registrar` valida: precio activo, WhatsApp E.164 venezolano,
referencia con 4 a 20 dígitos, ruta del comprobante dentro de la carpeta de la
clínica. Copia base, cargo y comisión del momento. Si hay captura, encola una
lectura y despierta al lector.

### 5.2 Equipo (`admin_lab_*`)

Lecturas y operación: `is_platform_admin()`. Catálogo, ajustes y pagos:
`helios_assert_super_admin()`. Ruta: `helios_puede_manejar()`.

| RPC | Parámetros | Devuelve |
|---|---|---|
| `admin_lab_resumen` | — | `jsonb {muestras_por_estado, pagos_por_revisar, kits:[{tipo, stock_helios, minimo, en_medicos}], ganancia_hoy_usd, ganancia_mes_usd, muestras_hoy}` |
| `admin_lab_ajustes_get` | — | `jsonb {modo, cargo_helios_usd, clinicas_de_prueba, updated_at}` |
| `admin_lab_ajustes_set` | `p_modo, p_cargo_helios_usd` | `jsonb` (super_admin) |
| `admin_lab_laboratorios` | — | filas |
| `admin_lab_laboratorio_guardar` | `p_id null, p_nombre, p_correo, p_telefono, p_direccion, p_activo` | `jsonb` (super_admin) |
| `admin_lab_examenes` | — | filas con `precios jsonb[]` por laboratorio |
| `admin_lab_examen_guardar` | `p_id null, p_codigo, p_nombre, p_kit_tipo, p_indicaciones, p_activo` | `jsonb` (super_admin) |
| `admin_lab_precio_guardar` | `p_laboratorio_id, p_examen_id, p_base_usd, p_activo` | `jsonb` (super_admin) |
| `admin_lab_kits` | — | filas `tipo, nombre, stock_helios, en_medicos, minimo_helios, minimo_por_medico, reponer boolean` |
| `admin_lab_kit_minimo_guardar` | `p_tipo, p_minimo_helios, p_minimo_por_medico` | `jsonb` |
| `admin_lab_kit_movimiento` | `p_tipo ('entrada'|'ajuste'), p_kit_tipo, p_cantidad, p_merchant_id default null, p_nota, p_idempotency_key` | `jsonb` |
| `admin_lab_inventario_por_medico` | — | filas `merchant_id, medico, consultorio, sangre, orina, biopsia, entregados_total, usados_total, bajo_minimo boolean` |
| `admin_lab_muestras` | `p_estado, p_pago_estado, p_merchant_id, p_desde, p_hasta, p_busqueda, p_limit, p_offset` | filas con `medico`, `examen`, `laboratorio`, montos, estados y `total_count` |
| `admin_lab_muestra` | `p_id` | `jsonb` detalle + lectura del comprobante + historia de auditoría |
| `admin_lab_muestra_estado` | `p_id, p_estado, p_canal default null, p_nota default null` | `jsonb` |
| `admin_lab_pago_revisar` | `p_id, p_aprobar boolean, p_nota default null` | `jsonb` |
| `admin_lab_pagos_confirmar_cuadrados` | `p_ids uuid[]` | `jsonb {confirmados}` |
| `admin_lab_logistica` | `p_fecha` | `jsonb {por_retirar:[{merchant…, muestras}], pedidos:[…], bajo_minimo:[…]}` |
| `admin_lab_ruta_armar` | `p_fecha` | `jsonb` ruta (arma o rehace el borrador: consultorios con muestras por retirar, pedidos o kits bajo mínimo; al final una parada por cada laboratorio que recibe muestras) |
| `admin_lab_parada_mover` | `p_parada_id, p_orden` | `jsonb` |
| `admin_lab_parada_kits` | `p_parada_id, p_kit_tipo, p_cantidad` | `jsonb` (0 la quita) |
| `admin_lab_ruta_iniciar` | `p_fecha` | `jsonb` (borrador → en_curso) |
| `lab_ruta_del_dia` | `p_fecha default helios_business_date()` | `jsonb {ruta, paradas:[{id, orden, tipo, estado, nombre, direccion, telefono, kits_a_dejar, muestras:[{codigo, examen, kit_tipo}]}]}` — driver y equipo |
| `lab_parada_completar` | `p_parada_id, p_nota default null` | `jsonb` — driver y equipo; idempotente. Consultorio: muestras → `retirada`, kits → `entrega`, pedidos → `entregado`. Laboratorio: sus muestras retiradas → `en_laboratorio`. Última parada → ruta `cerrada`. |
| `admin_lab_ganancia` | `p_desde, p_hasta` | `jsonb {totales:{muestras, cobrado_usd, base_usd, comision_usd, cargo_helios_usd}, filas:[…]}` |
| `admin_lab_por_pagar` | — | `jsonb {medicos:[{merchant_id, medico, comision_usd, muestras}], laboratorios:[{laboratorio_id, nombre, base_usd, muestras}]}` (solo pagos `verificado`, no anuladas) |
| `admin_lab_marcar_pagado` | `p_tipo ('comision'|'base'), p_muestra_ids uuid[], p_referencia` | `jsonb {marcadas}` (super_admin) |

### 5.3 Lector (`service_role`)

- `lector_lab_tomar(p_limit int default 3)` → filas `id, muestra_id, storage_path, mime`
  (`for update skip locked`, `leyendo`, `attempts + 1`).
- `lector_lab_leido(p_id, p_lectura jsonb)` — misma forma de salida que el
  lector de comprobantes; guarda la lectura, decide `cuadra` y mueve
  `pago_estado` a `cuadra` o `para_revisar`.
- `lector_lab_fallo(p_id, p_error)` — tres intentos, dos minutos entre ellos;
  después `fallida` y el pago a `para_revisar`.
- `helios_lector_despertar` cuenta también las lecturas de Lab pendientes.
- La Edge Function `lector-comprobantes` agrega una pasada que **baja la
  captura de Storage** (`lab-comprobantes`) en lugar de 360dialog y reusa
  `ESQUEMA`/`INSTRUCCIONES` de `logica.ts`.

## 6. Pantallas

### 6.1 Médico — `/_comercio/laboratorio` (sección `laboratorio`)

Solo aparece en el menú si `lab_mi_acceso().habilitado`. Pestañas por `?tab=`:

1. **Precios** — buscador; por examen y laboratorio: base del laboratorio,
   cargo Helios, *tu comisión* (editable por el gerente), **precio al
   paciente** grande. Botón «Registrar muestra» con ese examen.
2. **Registrar** — examen + laboratorio → cotización (USD y Bs a tasa BCV de
   hoy, para dictarle al paciente) → paciente, WhatsApp, correo opcional,
   referencia, banco, captura del pago (opcional pero recomendada). Al
   guardar: «Listo. Helios ya sabe que hay una muestra para retirar.»
3. **Muestras** — lista con estado y código; filtro por estado.
4. **Kits** — kits en el consultorio por tipo y botón «Pedir kits» por tipo.

Pensada primero para el teléfono.

### 6.2 Helios Lab — `/lab` (otra pestaña)

Marco propio («Helios Lab»), guardado por `PlatformGate`. Secciones:
Resumen, Muestras, Cobros, Inventario, Logística, Ruta, Ganancia, Catálogo,
Ajustes. El rol `driver` solo entra a `/lab/ruta` (pantalla de teléfono:
paradas en orden, dirección, qué dejar, qué retirar, botón «Completar»).
Al entrar al panel, un `driver` va directo a `/lab/ruta`.

## 7. Archivos

- `supabase/migrations/20261126120000_el_rol_driver.sql` (enum, solo).
- `supabase/migrations/20261126120100_helios_lab.sql` (tablas, ayudas, RPC, bucket, lector).
- `supabase/tests/lab_smoke.sql` (+ `run.sh`).
- `supabase/functions/lector-comprobantes/` (pasada de Lab).
- `panel/src/features/lab/` (api, consultas, tipos compartidos).
- `panel/src/routes/_comercio/laboratorio.tsx`, `panel/src/components/lab/medico/*`.
- `panel/src/routes/lab.tsx`, `panel/src/routes/lab/*.tsx`, `panel/src/components/lab/admin/*`.
- Menú del superadmin (Pro y Lite) con enlace en otra pestaña; rol `driver` en
  `Equipo.tsx`, `api.ts`, `ops.ts`, `admin.tsx`.
- `docs/01-CONTRATO-RPC.md` §10, `docs/REGLAS-DEL-NEGOCIO.md`, `docs/ESTADO.md`.

## 8. Pendiente fuera de la v1

- Desplegar la Edge Function con la pasada de Lab (necesita el OK de Javier).
- Envío automático del resultado (PDF por WhatsApp/correo): hoy no existe
  envío de documentos.
- Asentar Lab en el libro contable y pagar comisiones con las liquidaciones.
- Cruce automático con los SMS del BNC.
