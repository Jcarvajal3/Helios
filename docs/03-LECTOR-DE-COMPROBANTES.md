# Helios — El lector de comprobantes por WhatsApp

> Diseño del 2026-10-21. **Nada de esto está programado.** Javier decidió
> el 2026-10-21 todo lo de §10 (D1 con Sonnet 5.5, D8 y D9 con sus cambios).

## 1. El problema

En Ronda un pago se aprueba solo cuando **dos fuentes independientes dicen lo
mismo**: lo que reporta el cliente desde la app y el SMS del BNC que reenvía
el Atajo del iPhone (`ronda_bank_sms_ingest`). En Helios la segunda fuente ya
existe —`aviso-bnc` y `helios_bank_sms_evaluate` están en producción desde el
2026-10-15, en modo **sombra**— pero la primera la teclea el equipo a mano
desde la captura (`admin_register_payment`). Mientras alguien no registra el
pago, el SMS se queda `esperando` y el paciente sin respuesta.

El paciente ya hace lo necesario: manda la foto del comprobante por WhatsApp
(es lo que le piden «Pagar mi cuota», «Ya pagué» y los recordatorios). Falta
que esa foto se convierta sola en el reporte.

## 2. La idea en una frase

El bot **lee la captura**, crea el `payment_report` que hoy crea el equipo y
deja que el cotejo con el SMS del BNC —que ya existe, exacto y sin
tolerancias— lo apruebe. Si la foto no deja leer la referencia, **la pide por
texto** (las 6 últimas cifras).

Quien no tenga la captura puede **escribir los datos del pago** en vez de
mandarla (§4.5): banco, teléfono desde el que pagó y referencia completa.
La referencia sola no basta (Javier, 2026-10-21).

La lectura no necesita ser perfecta: el SMS es la verdad. Un dato mal leído
no aprueba nada, porque no encaja al céntimo con ningún aviso; el pago se queda
en la cola del equipo como hoy. El lector solo ahorra trabajo, nunca decide
solo.

## 3. El recorrido

```mermaid
sequenceDiagram
  autonumber
  participant P as Paciente
  participant W as whatsapp-webhook
  participant L as lector-comprobantes
  participant M as Modelo (visión)
  participant DB as Base Helios
  participant B as aviso-bnc (SMS del BNC)

  P->>W: Foto o PDF del comprobante
  W->>DB: payment_receipt_reads (pendiente)
  W-->>P: «📄 Recibimos tu comprobante, lo estamos verificando»
  W->>L: lo despierta (sin esperar); el cron recoge lo que quede
  L->>DB: toma la lectura (for update skip locked)
  L->>L: descarga el adjunto de 360dialog → bucket payment-receipts
  L->>M: imagen + instrucciones + esquema JSON
  M-->>L: datos leídos (o «no es un comprobante»)
  L->>DB: bot_comprobante_registrar(lectura, datos)
  alt falta la referencia
    DB-->>P: «Escríbeme las últimas 6 cifras de la referencia»
    P->>W: 158795645
    W->>DB: bot_comprobante_referencia(…)
  end
  DB->>DB: payment_report (reportado, origen bot) → trigger bank_sms_on_report
  B->>DB: SMS del BNC (antes o después: da igual el orden)
  DB->>DB: helios_bank_sms_evaluate: referencia + monto + día exactos, pareja única
  DB-->>P: «✅ Pago confirmado» (correo, y WhatsApp si se aprueba — §10 D4)
```

El orden entre la foto y el SMS no importa: el trigger del reporte mira los
avisos que esperan, y cada aviso nuevo mira los reportes abiertos. Eso ya
funciona así.

## 4. Las piezas

### 4.1 El bot del paciente (`paciente.ts`)

Hoy, ante una foto o un documento: acuse y **se calla 24 h** para que la vea
una persona. Pasa a ser:

| Caso | Hoy | Con el lector |
|---|---|---|
| Foto/PDF de un paciente identificado con cuotas pendientes | acuse + calla 24 h | encola la lectura, acuse «lo estamos verificando», **no** se calla |
| Foto/PDF sin paciente, o de un teléfono con varios pacientes sin elegir | acuse + calla 24 h | igual que hoy |
| Lector apagado o en sombra | — | igual que hoy (en sombra además encola, §7) |
| Texto con 6 a 12 cifras mientras espera una referencia | lo lee el equipo | completa la lectura (§4.4) |
| «Ya pagué» | pide la foto y la referencia | pide la foto **o** los datos del pago escritos (§4.5) |
| Texto mientras espera los datos del pago | lo lee el equipo | lo lee el formulario (§4.5) |
| Llegan más de N capturas del mismo teléfono en el día (§10 D6) | — | igual que hoy: al equipo |

El webhook **no espera** al modelo: 360dialog quiere el 200 enseguida y una
lectura tarda varios segundos. Guarda la lectura y despierta al lector con
`EdgeRuntime.waitUntil`; un `pg_cron` cada minuto recoge lo que quede, con
el mismo patrón que `helios_dispatch_whatsapp_batch`.

### 4.2 La Edge Function `lector-comprobantes`

Nueva, sin JWT, protegida con una clave propia como `aviso-bnc`. Por cada
lectura pendiente:

1. La toma con `for update skip locked` (`leyendo`, `attempts + 1`). Tres
   intentos fallidos → `para_el_equipo`.
2. Descarga el adjunto de 360dialog por su `media id` (imagen jpeg/png/webp
   o PDF, hasta 10 MB) y lo guarda en el bucket privado `payment-receipts`
   (`bot/<profile_id>/<lectura>.<ext>`), el mismo que usa el equipo. La
   captura queda como prueba, igual que hoy.
3. Llama al modelo con la imagen y un esquema de salida estricto (§5).
4. Pasa lo leído a la base (`bot_comprobante_registrar`). **Toda la decisión
   vive en SQL**; la función solo lee y transporta, como `aviso-bnc`.

Secretos nuevos: `ANTHROPIC_API_KEY` y `LECTOR_CLAVE`. Reutiliza la clave de
360dialog que ya usa el despacho.

### 4.3 La base

**`payment_receipt_reads`** — una fila por adjunto recibido:

| Columna | Qué guarda |
|---|---|
| `wa_message_id` | único: un reintento de 360dialog no lee dos veces |
| `kind` | `captura` (foto o PDF) o `datos` (escritos, §4.5) |
| `phone`, `profile_id` | quién lo mandó |
| `media_id`, `mime`, `receipt_path` | el adjunto y dónde quedó |
| `status` | `pendiente` · `leyendo` · `esperando_referencia` · `esperando_aviso` · `registrado` · `duplicado` · `para_el_equipo` · `descartado` · `error` |
| `mode` | el modo del lector cuando se leyó (como `bank_sms_notices.mode`) |
| `extraction` | lo que devolvió el modelo, tal cual |
| `model`, `usage` | el modelo y los tokens (costo real por lectura) |
| `reason` | por qué fue al equipo (`monto_no_cuadra`, `cuenta_ajena`, `fecha_fuera_de_rango`…) |
| `report_id` | el pago que creó |
| `attempts`, `error`, `created_at`, `read_at`, `decided_at` | |

RLS sin acceso: solo las RPC `security definer`, como `bank_sms_notices`.

**`receipt_reader_settings`** — una fila, `mode` (`apagado` · `sombra` ·
`activo`), por defecto `apagado`. Separado de `bank_sms_settings`: son dos
interruptores distintos (quién crea el reporte / quién lo aprueba).

**`payment_reports`** gana `receipt_read_id` (null = lo registró el equipo).
`registered_by` queda null en los del bot, así que el doble control
(`payment_four_eyes`) no impide que el equipo los apruebe.

**`helios_register_payment_core(...)`** — se saca de `admin_register_payment`
el cuerpo que cotiza y crea el reporte, sin la comprobación de admin. La usan
`admin_register_payment` (con `auth.uid()` y bitácora `payment.registered`) y
el bot (sin actor, bitácora `payment.registered` con `via: lector`). Así un
pago del bot y uno del equipo son idénticos para la cola, el cotejo, el
extracto y los avisos de cuota que se cancelan solos.

### 4.4 `bot_comprobante_registrar(lectura, datos)` — qué decide

Con los datos leídos, en este orden; el primer «no» manda la lectura al
equipo con su motivo y el paciente recibe el acuse de siempre:

1. **¿Es un comprobante de un pago hecho?** `es_comprobante` y
   `estado = exitosa`. Una operación rechazada o «en proceso» no se registra.
2. **¿Fue a la cuenta de Helios?** Si la captura enseña el destino (teléfono,
   RIF o cuenta), tiene que ser una de las `payment_destinations` activas.
   Si no lo enseña, se sigue: el SMS solo llega de la cuenta del BNC.
3. **¿Ya existe?** La misma referencia (por el final, `helios_bank_sms_ref_match`)
   y el mismo monto en un reporte del mismo paciente → `duplicado`, sin
   reporte nuevo: «Ya teníamos este comprobante, lo estamos verificando».
   Con otro paciente → al equipo (alerta `referencia_repetida`, que ya existe).
4. **¿Fecha razonable?** Entre 5 días antes y hoy (hora de Caracas). Sin
   fecha legible, se toma la de hoy.
5. **¿Qué cuotas paga?** Se toman las cuotas pendientes en el orden de
   `helios_quote_installments` (lo vencido primero) y se cotizan en bolívares
   **a la tasa del día del pago**: la primera, las dos primeras, y así. Se
   elige el tramo cuya cotización es **igual al céntimo** al monto leído. Si
   ninguno lo es (un abono, un redondeo, pagó con el monto de ayer) → al
   equipo con `monto_no_cuadra` (§10 D5).
6. **¿Hay referencia?** Con 6 cifras o más, se registra. Sin ella →
   `esperando_referencia` y el bot la pide; la respuesta (6 a 12 cifras,
   dentro de 24 h) completa la lectura y vuelve al paso 3. Una respuesta que
   no son cifras, o pasadas 24 h → al equipo.
7. **Se registra** con `helios_register_payment_core`: método (`pago_movil` o
   `transferencia`), banco de origen, referencia, `paid_on`,
   `declared_amount_ves`, la captura y `payer_phone` **solo si la captura lo
   enseña** (el número del WhatsApp no sirve: muchos pagan desde el teléfono
   de un familiar, y el cotejo lo rechazaría).

Desde ahí no cambia nada: el trigger `bank_sms_on_report` busca el SMS, y si
encaja exacto y único (y `bank_sms_settings.mode = 'activo'`) el pago se
aprueba; si no, se queda en «Pagos reportados» para el equipo. **Las
transferencias no generan SMS**: su reporte se crea igual (ahorra el
tecleo) y lo aprueba el equipo o el extracto.

### 4.5 Los datos del pago escritos (sin captura)

Para quien no puede o no sabe sacar la captura (decisión de Javier,
2026-10-21). Solo **Pago Móvil**: es lo único que genera el SMS del BNC; una
transferencia sin captura va al equipo.

- **Cómo se ofrece**: «Ya pagué» y el bloque de pago dicen «envíanos la foto
  del comprobante o escríbenos los datos del pago». Si el paciente escribe
  «datos», «no tengo captura» o pulsa el botón, el bot manda el formulario y
  guarda el estado `datos_pago` en `whatsapp_contacts` (24 h).
- **El formulario** (con etiquetas, como el del bot del médico):

  ```
  Banco desde el que pagaste:
  Teléfono desde el que pagaste:
  Referencia completa:
  ```

  Sin el monto (Javier, 2026-10-21, §10 D9): son menos pasos, y un monto mal
  tecleado estorbaría más de lo que ayuda. **El monto lo pone el aviso del
  BNC.**

- **Se lee con código, sin IA**, con las reglas del bot del médico
  (`datos.ts`): con etiquetas, o solo las respuestas en el orden del
  formulario. Lo que falte o no sirva, el bot lo vuelve a pedir; si no
  cuadra tras dos intentos, al equipo.
  - **Banco**: nombre o código de 4 cifras de la lista de bancos (la de
    `panel/src/features/admin/banks.ts`, compartida con el bot).
  - **Teléfono**: móvil venezolano (0412, 0414, 0416, 0422, 0424, 0426) de 11
    cifras. Puede no ser el del paciente: muchos pagan con el de un familiar.
  - **Referencia completa**: solo cifras, de 8 a 20. Se guarda entera; el
    cotejo la compara por el final con la del SMS, como la de la captura.
  - **Fecha**: la de hoy (el cotejo admite un día de diferencia).
- **Espera al aviso.** Como no hay monto, todavía no se puede cotizar ni
  crear el `payment_report`: la lectura queda en `esperando_aviso`. El
  paciente recibe el acuse de siempre.
- **El aviso la completa.** Cuando un SMS del BNC llega (o si ya estaba
  esperando), se busca la lectura que encaja con él:
  - la referencia escrita acaba como la del SMS (`helios_bank_sms_ref_match`,
    al menos 6 cifras);
  - el teléfono escrito empieza y acaba como el enmascarado del SMS
    (`0424***9037`). Sin captura, esta es la comprobación que la reemplaza,
    así que aquí **siempre** se exige;
  - el día del SMS es el de la lectura o el anterior;
  - y la pareja es **única en los dos sentidos**, como en el cotejo de hoy.

  Con eso, el **monto del SMS** decide qué cuotas se pagan (paso 5 de §4.4,
  a la tasa del día del SMS) y se crea el `payment_report` con ese monto como
  `declared_amount_ves`, `payer_phone` el escrito y método `pago_movil`. Desde
  ahí el trigger `bank_sms_on_report` lo coteja con ese mismo aviso y lo
  aprueba si el aviso del BNC está en activo; en sombra queda en «Pagos
  reportados» con el aviso a la vista.
- **Cuando no cuadra**: si el monto del SMS no corresponde a cuotas completas
  (D5), si encaja con más de una lectura o más de un aviso, o si en 24 h no
  llega ningún aviso que encaje → al equipo (`para_el_equipo`), con los datos
  escritos.
- En la base: la evaluación de cada aviso nuevo (`helios_bank_sms_evaluate`),
  cuando no encuentra un reporte, mira también las lecturas `esperando_aviso`;
  y cada lectura nueva de datos mira los avisos que esperan. Las dos
  direcciones, como ya pasa entre avisos y reportes.

### 4.6 El superadmin

Sin pantallas nuevas (poda del 2026-10-19: no se fusionan ni se multiplican):

- **Pagos reportados**: una etiqueta «Leído por el bot» en los que traen
  `receipt_read_id`, y en la ficha lo leído junto a la captura y a los avisos
  del BNC que ya enseña (`admin_bank_sms_for_report`).
- **Registrar pago**: si la conversación tiene una lectura que fue al equipo,
  el formulario llega **relleno** con lo leído; el operador revisa, elige las
  cuotas si hacía falta y guarda. Es lo único que se ve en modo sombra.
- **Inicio**: un contador «Comprobantes para revisar» (lecturas en
  `para_el_equipo` de los últimos 7 días), con su motivo.
- **Ajustes › Parámetros**: el modo del lector, junto al del aviso del BNC.

## 5. La lectura

**Modelo**: `claude-sonnet-5-5` (decisión de Javier, 2026-10-21, §10 D1),
con `output_config.effort: "low"` —es extracción, no razonamiento— y
`fallbacks: "default"` del servidor activado para que un rechazo del
clasificador no deje la lectura colgada. Se llama con el
SDK oficial (`npm:@anthropic-ai/sdk`) y `client.messages.parse` con un
esquema Zod (`zodOutputFormat`): la salida siempre es JSON válido con estos
campos, `null` cuando no se ve:

```ts
const Comprobante = z.object({
  es_comprobante: z.boolean(),
  estado: z.enum(['exitosa', 'rechazada', 'en_proceso', 'no_se_ve']),
  metodo: z.enum(['pago_movil', 'transferencia', 'otro']).nullable(),
  banco_origen: z.string().nullable(),      // nombre o código de 4 cifras
  banco_destino: z.string().nullable(),
  referencia: z.string().nullable(),        // solo cifras, entera como sale
  monto_texto: z.string().nullable(),       // tal cual: «5.442,41»
  fecha: z.string().nullable(),             // AAAA-MM-DD
  hora: z.string().nullable(),              // HH:MM
  telefono_origen: z.string().nullable(),
  documento_origen: z.string().nullable(),  // cédula o RIF del pagador
  telefono_destino: z.string().nullable(),
  documento_destino: z.string().nullable(),
  cuenta_destino_final: z.string().nullable(), // últimas 4 cifras si se ven
})
```

- **El monto lo convierte el código, no el modelo**: `monto_texto` se lee con
  las mismas reglas que `helios_parse_bnc_sms` (coma decimal; los puntos son
  de miles). Así una lectura y un SMS del mismo pago dan el mismo número.
- **Sin herramientas y con esquema cerrado**: un texto dentro de la imagen
  que intente dar instrucciones no puede hacer nada más que llenar mal un
  campo, y un campo mal llenado no encaja con ningún SMS.
- **Costo**: una captura de teléfono son unos 1.500 tokens de imagen + ~800
  de instrucciones + ~300 de salida. Con Sonnet 5.5 ($2 / $10 por millón)
  son **≈ $0,008 por captura**: mil comprobantes al mes, unos $8. `usage` en
  cada lectura guarda el costo real.

Las instrucciones del modelo llevan los formatos que ya conocemos (BNC,
Banesco, Mercantil, Venezuela, Provincial, Bancamiga…) y se afinan con las
capturas reales de la fase sombra (§7). Una batería de capturas de prueba
(anonimizadas, en `supabase/functions/lector-comprobantes/ejemplos/`) con su
resultado esperado sirve de prueba de regresión antes de cambiar de modelo o
de instrucciones.

## 6. Los mensajes al paciente

Al estilo de `textos_paciente.ts` (montos con `helios_money_text`, bolívares
solo junto a las cuentas). Borradores:

- **Acuse** (al recibir la foto): «📄 ¡Gracias, María! Recibimos tu
  comprobante. Lo estamos verificando y te avisamos por aquí.»
- **Pide la referencia**: «No logro leer el número de referencia en tu
  comprobante 🔍. Escríbeme las **últimas 6 cifras** de la referencia,
  por favor.»
- **Duplicado**: «Ya teníamos este comprobante 👍. Lo estamos verificando.»
- **Ya pagué**: «¡Gracias, María! Envíanos por aquí la foto del comprobante
  📸. Si no la tienes, escribe *datos* y te pido los datos del pago.»
- **Formulario de datos** (§4.5): «Copia este mensaje, completa cada línea y
  envíamelo: …»; y si falta algo, «Me falta el teléfono desde el que
  pagaste.»
- **Registrado** (opcional, §10 D4): «✅ Listo, María. Registramos tu pago
  de Bs 10.624,18 (ref. …795645). En cuanto lo veamos en el banco te
  confirmamos.»
- **Confirmado**: hoy `pago_recibido` sale solo por correo (decisión del
  2026-10-13, para ahorrar). Dentro de las 24 h desde que el paciente escribió,
  un mensaje libre por WhatsApp no cuesta (ventana de servicio), así que se
  propone mandarlo también por WhatsApp cuando la ventana esté abierta (§10 D4).

Ninguno dice «préstamo», «crédito» ni «financiamiento», y ninguno promete
plazos de confirmación.

## 7. Puesta en marcha

1. **Apagado** (al desplegar). Nada cambia.
2. **Sombra**. Cada foto se lee y se guarda la lectura, pero el bot se porta
   como hoy (acuse y calla 24 h) y no se crea ningún reporte. Lo que sí
   cambia: el formulario del equipo llega relleno. Al cabo de unas semanas
   se compara lo leído con lo que registró el equipo (consulta en
   `supabase/poda/`): aciertos por campo, y cuántos se habrían aprobado solos.
3. **Activo**. El bot crea los reportes. El cotejo del BNC sigue con su propio
   interruptor: puede seguir en sombra un tiempo más, y el equipo aprueba
   con el aviso a la vista, como hoy.

Cada paso es un cambio de parámetro, no un despliegue.

## 8. Riesgos

| Riesgo | Qué lo cubre |
|---|---|
| Lectura equivocada | No aprueba: el SMS tiene que coincidir al céntimo y la pareja ser única. Va al equipo |
| Captura falsificada o editada | El SMS es la verdad, no la imagen. Con la referencia de un pago ajeno, el SMS ya está ligado o encaja con dos reportes → `varios` → equipo |
| SMS falso (cualquiera puede escribir al número) | El riesgo de hoy, aceptado en Ronda: `allowed_sender` (pendiente de fijar) y el extracto como verdad final |
| Datos escritos de un pago ajeno (sin captura ni monto) | Hacen falta la referencia **y** el teléfono del pagador, que encajen con un solo aviso y una sola lectura, y que el monto del aviso salde cuotas completas de ese paciente. Si el verdadero pagador también reporta → dos lecturas para un aviso → equipo |
| Texto malicioso en la imagen | El modelo no tiene herramientas, la salida es un esquema cerrado y la decisión está en SQL |
| La cuenta del BNC es compartida con Ronda | Los SMS de Ronda nunca encajan con un reporte de Helios (no hay cotización igual al céntimo): se quedan `esperando`, como hoy |
| Abuso o costo (muchas fotos) | Tope de capturas por teléfono y día (§10 D6); `usage` guarda el costo real |
| Datos personales a un proveedor | La captura (nombre, cédula, banco) viaja a la API de Anthropic, que no entrena con datos de la API. Se nombra en la política de privacidad (§10 D7) |
| El modelo no responde | Tres intentos; luego al equipo. El paciente ya tiene su acuse |
| 360dialog reintenta el webhook | `wa_message_id` único en `payment_receipt_reads` |

## 9. Pruebas

- `supabase/tests/`: una suite `lector_comprobantes.sql` (begin/rollback, sin
  HTTP real) para `bot_comprobante_registrar`: cada motivo de §4.4, el
  tramo de cuotas, el duplicado, la referencia por texto, y la pareja con un
  SMS en los dos órdenes (foto antes y después del aviso). Y los datos
  escritos: el aviso que pone el monto, el teléfono que no encaja, dos
  lecturas para un aviso y las 24 h sin aviso.
- `functions/whatsapp-webhook/*.test.ts`: los casos nuevos del bot del
  paciente y los textos.
- `functions/lector-comprobantes/logica.test.ts`: lectura del monto,
  normalización de referencia y fecha, y la batería de ejemplos con un doble
  del modelo.
- `node scripts/verificar-contrato.mjs` para las RPC nuevas del panel.

## 10. Decisiones de Javier

| | Pregunta | Decisión |
|---|---|---|
| **D1** | ¿Se usa un modelo de IA (Anthropic) para leer las capturas, y cuál? | ✅ Sí, **`claude-sonnet-5-5`** (Javier, 2026-10-21) |
| **D2** | ¿Después de una foto, el bot sigue atendiendo en vez de callarse 24 h? | ✅ Sí cuando el lector está activo. Si el paciente escribe otra cosa, el equipo lo ve como hoy |
| **D3** | ¿El orden de la puesta en marcha (§7) y cuánto dura la sombra? | ✅ Sombra 2 semanas o 50 comprobantes, lo que llegue antes; luego activo. Fijar `allowed_sender` y quién firma (`actor`) antes de pasar el aviso del BNC a activo |
| **D4** | ¿El «Pago confirmado» vuelve a salir también por WhatsApp? ¿Y el «Registramos tu pago»? | ✅ Confirmado: también por WhatsApp, solo dentro de la ventana de 24 h, además del correo. «Registramos tu pago»: no, el acuse basta |
| **D5** | Si el monto no corresponde a cuotas completas (abono, redondeo, tasa de otro día) | ✅ Al equipo con el formulario relleno; el bot no registra pagos que no saldan cuotas completas |
| **D6** | ¿Tope de capturas por teléfono y día? | ✅ 10. A partir de ahí, al equipo sin leer |
| **D7** | ¿La política de privacidad nombra a Anthropic como proveedor? | ✅ Sí, junto a 360dialog y Resend (cuando el abogado la escriba) |
| **D8** | ¿Vale reportar sin captura? | ✅ Sí, como alternativa a la captura, pero **no la referencia sola**: banco, teléfono desde el que pagó y referencia completa (Javier, 2026-10-21; §4.5) |
| **D9** | En los datos escritos, ¿se pide también el **monto en Bs**? | ✅ No: menos pasos y nada de montos mal tecleados. El monto lo da el aviso del BNC que encaja por referencia, teléfono y día (Javier, 2026-10-21; §4.5) |
