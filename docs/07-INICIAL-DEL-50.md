# La inicial del 50% (2026-11-12)

Toda orden nueva se paga con una **inicial del 50% del total** el mismo día y
el resto en **2 cuotas a los 14 y 28 días**. Lo único que no cambia es
`/consultas` (variante B de la prueba A/B, docs/06): sigue tal cual, con su
«$15 de inicial» y «Consulta a partir de: $30», aunque la cifra no cuadre con
el cobro real (Javier, 2026-11-12: «No tocar /consultas»).

## Decisiones (Javier, 2026-11-12)

| Tema | Decisión |
|---|---|
| Base de la inicial | **50% del total con la comisión** (consulta + Comisión Helios 12% + IVA 16% de la comisión). Consulta de $100 → total $113,92 → **inicial $56,96 hoy + 2 cuotas de $28,48**. La comisión queda repartida en los 3 pagos. |
| Pago al médico | **Sin cambios**: 50% a los 8 días y 50% a los 15, desde la orden. La inicial se queda en Helios. Garantizado desde que la orden queda activa. |
| Si no paga la inicial | La orden solo queda **activa** cuando se aprueba la inicial. Si a las **2 horas** de aceptar (Sí + cédula) no la pagó, **se anula sola** y se avisa al paciente y al médico. Basta con que el pago **llegue dentro del plazo** (captura o datos enviados): si la aprobación tarda, se espera. |
| Límite de $150 | **Toda la consulta**, como hoy (la base sin comisión). La inicial no amplía lo que cabe. |
| Aviso al médico | **Uno, al aprobarse la inicial** («aceptó su pago en cuotas», plantilla `helios_paciente_acepto`). Si se anula, otro aviso de que se anuló. |
| Plantilla de Meta | Hace falta `helios_confirmar_pago_en_cuotas_v3` (la v2 dice «sin inicial»). **No se lanza hasta que Meta la apruebe.** |
| Encendido | **Todo de una vez**: migraciones, webhook y panel salen juntos el día del lanzamiento, con el sí de Javier. |
| Órdenes viejas | Las creadas antes del lanzamiento conservan sus condiciones (2 cuotas, sin inicial), también las que estén pendientes del Sí. Se decide **por orden** (`charges.down_payment_pct`), no por paciente. Excepción: una orden vieja **vencida que se reenvía** (`staff_resend_confirmation`) se reabre con las condiciones vigentes ese día, también la inicial: se vuelve a aceptar como una orden nueva. |
| Aprobación de la inicial | **Igual que las cuotas**: captura por WhatsApp → `lector-comprobantes` → `helios_receipt_decide`, o datos escritos → aviso del BNC (`aviso-bnc` → `helios_bank_sms_ingest`) → `reconcile_payment`. Y el equipo, a mano, desde Caja. |

## Cuentas

Por orden, en cada moneda por separado (como hoy `helios_charge_amounts`),
con `T` = total con comisión y `B` = base (la consulta):

```
inicial  = round(T × pct / 100, 2)            pct = charges.down_payment_pct (50)
cuota 1  = round((T − inicial) / 2, 2)
cuota 2  = T − inicial − cuota 1
financed: lo mismo sobre B (f0, f1, f2), así el límite sigue contando B entero.
```

$100 → 56,96 + 28,48 + 28,48. $30 → T = 34,18 → 17,09 + 8,55 + 8,54.

## Modelo

- **La inicial es una cuota más: `installments.sequence = 0`**, que vence el
  día de la orden. Las cuotas 1 y 2 conservan su número, sus fechas
  (14 y 28 días) y su `settlement_due_date` (8 y 15 días): las métricas que
  miran la cuota 1 y la 2 (impago de la 1.ª cuota, cohortes, cobranza) siguen
  significando lo mismo. Así el lector de comprobantes, el aviso del BNC, la
  cotización en bolívares y `reconcile_payment` cobran la inicial sin código
  nuevo de cobro.
- Parámetro `down_payment_pct` (`business_parameters`, = 50 desde el día del
  lanzamiento) y `helios_down_payment_minutes()` (= 120). `charges.down_payment_pct`
  guarda el de la orden al crearla (null/0 = orden vieja: 2 cuotas, sin inicial).
- Estado nuevo de la orden: **`awaiting_down_payment`** («Esperando la
  inicial»), con `charges.down_payment_due_at`. El valor del enum va en su
  propia migración.

### Ciclo de una orden con inicial

1. **Creación** (panel o bot): `pending`, 2 h para el Sí, como hoy. La
   pregunta al paciente ya enseña la inicial y las 2 cuotas.
2. **Sí (+ foto de la cédula si no la tenemos)** → `helios_finalize_charge`:
   asiento del libro y deuda (3 cuotas: 0, 1, 2) como hoy, pero la orden queda
   en **`awaiting_down_payment`** con `down_payment_due_at = now() + 2 h`.
   **No** se causan todavía la comisión de la secretaria, el comprobante por
   correo ni el aviso al médico. Al paciente le llega: «tu orden queda activa
   cuando pagues la inicial de $X hoy» + el bloque de pago de la inicial.
3. **Se aprueba un pago que cubre la cuota 0** (por cualquier camino) →
   `helios_activate_charge`: `confirmed`, `activated_at`; comisión de la
   secretaria, comprobante por correo, aviso al médico; el mensaje de pago
   aprobado al paciente dice que la orden quedó activa y enseña sus 2 cuotas.
4. **Vence el plazo sin pago** (cron cada minuto): si no hay un pago de la
   cuota 0 abierto (captura en lectura, datos esperando el aviso del BNC,
   reporte `reported`/`in_review`), se **revierte** con la maquinaria de
   reversa que ya existe (asiento contrario, cupo, avisos cancelados) con
   motivo «inicial no pagada»; aviso al paciente y al médico. Si había un
   pago abierto y luego se rechaza, se revierte en la siguiente pasada.
5. Mientras espera la inicial, la cuota 0 **no** entra en recordatorios, mora,
   cargos por atraso, tramos de cobranza ni pagos a la clínica (el lote de
   liquidaciones solo mira órdenes `confirmed` y cuotas 1 y 2).

## Plantilla de Meta v3 (la crea Javier)

`helios_confirmar_pago_en_cuotas_v3`, Utility, `es`, botones «Sí, acepto» /
«No». El texto exacto y sus variables los fija el frente A en docs/00 §15.5
(la base ya deja la v3 conectada; hasta el lanzamiento no se usa).

## Lanzamiento

Las migraciones que cambian el comportamiento esperan en
`supabase/por-lanzar/` (fuera de `migrations/`, para que el runner de ninguna
sesión las aplique antes). El día del lanzamiento, con el sí de Javier y la v3
aprobada: se renombran al timestamp del día, se mueven a `migrations/`, se
aplican, se despliega `whatsapp-webhook` y se pushea `main` (Vercel). Ni antes
ni por separado.

## Cómo quedó la base (2026-11-12, frente A)

- **Aplicado en producción**: solo `20261112100000_la_orden_espera_la_inicial_tipos.sql`
  (el valor `awaiting_down_payment` del enum; sin uso hasta el lanzamiento).
- **Por lanzar**: **un solo fichero**, `supabase/por-lanzar/20261112110000_la_inicial_del_50.sql`
  (el ciclo, los mensajes, lo que leen panel, bot y superadmin, y las
  condiciones v4). Uno solo a propósito: `aplicar.mjs` corre cada fichero en
  su transacción, y las partes dependen unas de otras; así entra todo o nada.
  Todas las guardias van al principio: el enum, que las condiciones vigentes
  sean la v3, las vistas del asistente y el md5 de 53 funciones (las que
  redefine y aquellas de las que depende sin redefinirlas: `reconcile_payment`,
  `helios_quote_installments`, `admin_reverse_charge`,
  `helios_accrue_staff_commission`, el lector, `helios_enqueue_message`,
  `create_patient_charge`…). Si alguna cambió desde el 2026-11-12, se para y hay
  que revisar o volver a parchear esa función.
- Los importes salen de una sola función, `helios_installment_split`, en cada
  moneda. Columnas nuevas en `charges`: `down_payment_pct`,
  `down_payment_due_at`, `activated_at`, `down_payment_expired_at`.
- La cuota 0 tiene `settlement_due_date` **null** (la única): la inicial nunca
  genera un pago a la clínica.
- La pregunta con inicial es una plantilla nueva, `confirmar_pago_con_inicial`
  (v3 de Meta); `confirmar_financiamiento` (v2) queda para las órdenes viejas
  que aún esperan el Sí y sus reenvíos. Tras el Sí sale `pagar_inicial` en vez
  de `bienvenida`.
- **Pago abierto** (frena la anulación): captura en lectura, datos esperando
  el aviso del BNC, reporte `reported`/`in_review` y también una captura que el
  lector pasó al equipo, hasta 24 h después del plazo. Desde la ronda de
  arreglos, además **cualquier imagen o documento** que entró desde el
  teléfono del paciente entre el Sí y el plazo y que el lector no llegó a
  tomar (lector apagado, tope, teléfono de varios pacientes): sale de
  `whatsapp_inbound`, donde el webhook guarda todo antes de atenderlo, así que
  el webhook no cambia. No cuentan la cédula ni lo que el lector ya decidió.
  **Toda lectura y todo adjunto, como mucho 24 h después del plazo** (si el
  lector se cae, la orden no se queda colgada). Un reporte `reported`/`in_review`
  la sostiene sin tope (es dinero declarado), pero a las
  `alert_down_payment_stuck_hours` (6) h pasadas del plazo sale la alerta
  **`inicial_atascada`** en superadmin › Alertas. El cron filtra las abiertas
  antes de limitar a 200.
- **La reversa no compite con un pago**: bloquea primero las cuotas y luego la
  orden (el mismo orden que `reconcile_payment`) y, con los bloqueos puestos,
  vuelve a mirar si hay un pago abierto o cualquier reporte no rechazado de
  sus cuotas; si lo hay, no anula.
- **El monto de un pago no se adivina** (`helios_receipt_tramo`, para el lector
  y para los datos con su aviso del BNC). Opciones: por cada orden en espera,
  su inicial sola y la orden completa (inicial + sus 2 cuotas); y lo de
  siempre, las cuotas de las órdenes activas por fecha. Las de una orden en
  espera son «fuertes»; lo de siempre solo es fuerte si toca una cuota vencida
  o que vence ese día (adelantar cuotas que aún no vencen pierde ante una
  inicial: el paciente recurrente que paga la inicial de su orden nueva).
  Una sola fuerte → esa; más de una (dos iniciales del mismo monto, o una
  inicial y cuotas vencidas que valen igual) → al equipo, y eso sostiene la
  orden; ninguna fuerte → adelantar cuotas si cuadra; si nada, el reparto de
  siempre con las iniciales primero. Pagar una orden en espera entera paga esa
  orden, no su inicial con cuotas de otra. Sin órdenes en espera, lo de antes.
- **Activación tardía**: si la inicial se aprueba pasada la fecha de una mitad
  de la clínica, esa mitad pasa a devengarse hoy (si no, el lote, que mira
  unos días atrás, se la saltaría), y la 2.ª nunca el mismo día que la 1.ª
  (como pronto, el día siguiente): el lote crea una mitad por orden y día. El
  comprobante por correo sale **cuando el pago que activó la orden queda
  aprobado entero** (trigger `payment_reports_activated_receipt`, al pasar el
  reporte a `reconciled`, que `reconcile_payment` hace después de marcar todas
  sus cuotas): una cuota ya pagada sale «pagada el …», sin bolívares. (La
  ronda 3 lo había puesto en un trigger diferido sobre `charges`; con un
  `set constraints all immediate` se disparaba en mitad del bucle de
  `reconcile_payment`, que marca las cuotas sin orden fijo, y el comprobante
  salía con las cuotas 1 y 2 «vence el…» o pagadas según el orden: por eso
  `inicial_smoke` pasaba unas veces y otras no.)
- **Reversa a mano y cron a la vez**: `admin_reverse_charge` bloquea la orden y
  luego las cuotas; la anulación sola, las cuotas y luego la orden pero **sin
  esperar** por la orden (`for update skip locked`): si el equipo la tiene, esa
  pasada la salta. No hay abrazo mortal.
- **Parámetros**: `admin_set_business_parameter` solo admite `down_payment_pct`
  de 0 a 90 y `down_payment_minutes` ≥ 1; el catálogo avisa de que la
  plantilla de Meta v3 dice «50%» y «2 horas».
- **Política `on_collection`**: `reconcile_payment` le devengaría a la clínica
  también la cuota 0. Hoy no puede pasar: las 39 condiciones son `scheduled`;
  `merchant_terms` tiene RLS con solo una política de lectura
  (`merchant_terms_read_staff`), así que solo escriben funciones de la base:
  `bootstrap_merchant` (la columna `policy` vale `'scheduled'` por defecto) y
  `admin_set_settlement_terms`, que rechaza cualquier otra con
  `or coalesce(p_policy, '') <> 'scheduled' then raise exception 'En Helios la
  clínica recibe el 100%% …'` (20261019210200; la firma vieja con
  `settlement_policy` la llama). Aun así, el trigger
  `settlements_not_from_down_payment` descarta toda liquidación `on_collection`
  de una cuota 0.
- **La inicial nunca está vencida**: mientras la orden la espera, el cron de
  cada minuto le pasa `due_date` a hoy (si cruza la medianoche con un pago
  abierto), así que ningún listado ni métrica la ve en atraso; además, la
  mora, Cobranza, `metricas.cuotas_al`, `admin_charge_detail`, la Caja y la
  ficha del paciente la excluyen a mano (`days_overdue` = 0).
- Lo que lee el panel: `merchant_transactions` trae `down_payment_due_at` y
  `down_payment_expired_at`, y las fechas de las cuotas solo en órdenes vivas
  (null en anuladas, rechazadas y vencidas). El libro de ventas
  (`merchant_sales_export` y `_items`) **excluye** toda orden con inicial que
  nunca se activó (`down_payment_pct` > 0 y `activated_at` null), se anulara
  sola o la revirtiera el equipo: nunca fueron ventas. `admin_charges` y la Caja (`helios_admin_payment_item`)
  traen `down_payment_pct` para decir «Inicial» y «Cuota N de 2»;
  `installments_total` sigue contando las 3. La ficha del paciente
  (`helios_admin_user_detail_base.consumos`, «Sus financiamientos») trae los
  cuatro campos de la inicial.
- La anulación deja el asiento en cero (asiento contrario), borra las cuotas,
  devuelve el cupo, cancela la cola y avisa a los dos. Un pago que llegue
  después de anulada la orden va al equipo.
- Pruebas: `POR_LANZAR=1 bash supabase/tests/run.sh` corre cada suite con
  `por-lanzar/` dentro de su transacción; suite nueva `inicial_smoke`.

### Huecos conocidos

- El aviso «se anuló» al médico **no sale si su ventana de 24 h está
  cerrada**: no hay plantilla de Meta para eso (lo ve en el panel).
- Las órdenes de capacitación también esperan la inicial y se anulan a las 2 h.
- Si el paciente manda la captura del pago cuando se le pide la cédula, se
  toma como cédula (el lector solo alerta si no coincide).

## Frentes

| Frente | Ficheros (solo esos) |
|---|---|
| A. Base | `supabase/migrations/20261112100000_*` (solo el enum), `supabase/por-lanzar/*`, `supabase/tests/*`, `docs/01-CONTRATO-RPC.md` |
| B. Webhook | `supabase/functions/whatsapp-webhook/*` (salvo el texto de B en `textos_directorio.ts`) |
| C. Panel de la clínica | `panel/src/features/merchant/*`, `panel/src/components/registrar/*`, `panel/src/routes/_comercio/*` |
| D. Páginas públicas | `panel/src/components/portada/*`, `panel/src/routes/index.tsx`, `legal.*`, `llms[.]txt.ts`, `afiliacion.tsx`, `directorio.tsx`, `directorio_.$especialidad.tsx`, `medico.$slug.tsx`, `panel/src/features/directorio/paginas.ts`, `panel/src/components/directorio/*` (solo lo de A), `panel/src/config/sitio.ts`, `panel/src/styles/portada.css` |
| E. Superadmin | `panel/src/features/admin/*`, `panel/src/components/admin/*`, `panel/src/routes/admin/*`, `panel/src/lite/*`, `supabase/functions/admin-asistente/*` |
| Orquestador | `CLAUDE.md`, `docs/00`, `docs/06`, `docs/07`, `docs/ESTADO.md` |

Intocables: `panel/src/routes/consultas.tsx`, `panel/src/features/directorio/consultas.ts`
(y su prueba), y todo lo que solo usa la variante B.
