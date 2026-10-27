# El directorio pasa por el WhatsApp de Helios (2026-10-27)

Hasta hoy, el botón «Escribir por WhatsApp» de cada tarjeta de `/directorio`
abre el chat directo con el médico. Helios cuenta el clic, pero no sabe quién
escribió ni si terminó siendo paciente.

Con este cambio, el botón abre el chat con **el número de Helios**, con un
mensaje ya escrito que lleva el **código del médico**. El bot reconoce el
código, guarda el teléfono de quien escribe (WhatsApp lo da con cada mensaje)
y le contesta con el contacto del médico. Cuando ese teléfono tiene después
una orden confirmada con ese médico, cuenta como **paciente convertido**.

## Decisiones (Javier, 2026-10-27)

- **Solo el contacto.** El bot le da al paciente el WhatsApp del médico. El
  número del paciente **no** se le pasa al médico: Helios lo guarda solo para
  medir. No hace falta ninguna plantilla nueva de Meta (al paciente se le
  contesta dentro de su ventana de 24 h, porque acaba de escribir).
- **Conversión:** el mismo teléfono tiene una orden confirmada con ese médico
  en **cualquier momento después** de su primer mensaje.

## El recorrido

1. El paciente toca «Escribir por WhatsApp» en la tarjeta de la Dra. Ana Pérez.
   La página apunta el clic (como hoy) y abre
   `wa.me/<número de Helios>?text=Hola, quiero agendar una consulta con la Dra. Ana Pérez. (Código DIR-7K2P)`.
2. El paciente envía el mensaje. 360dialog lo manda al webhook.
3. El webhook ve `DIR-7K2P` antes que cualquier otra ruta y llama a
   `bot_directorio_interesado`. La base busca la tarjeta publicada con ese
   código y guarda (o pone al día) el interesado: médico + teléfono.
4. El bot contesta al paciente con el nombre, la especialidad y la dirección
   del médico, el enlace a su WhatsApp (con el mensaje de siempre ya escrito) y
   que puede pagar la consulta con Helios en dos cuotas.
5. Si el código no es de una tarjeta publicada, el bot dice que ese médico ya
   no está en el directorio y enlaza a `conhelios.com/directorio`.
6. Superadmin › Directorio de médicos enseña el embudo: clics → interesados →
   pacientes, por médico y en total, y la lista de interesados con su estado.

Si el número de Helios no está configurado (Ajustes › Contacto), o la tarjeta
no tiene código, la página vuelve al enlace directo con el médico: el botón
nunca se queda sin funcionar.

## El contrato (fijo: los frentes trabajan en paralelo contra esto)

### Base — migración `20261027100000_el_directorio_pasa_por_el_whatsapp_de_helios.sql`

- `helios_directorio_codigo_nuevo() → text`: `DIR-` + 4 caracteres de
  `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (sin 0/O/1/I/L), único en
  `directory_listings`.
- `directory_listings.lead_code text not null unique default
  helios_directorio_codigo_nuevo()`, con relleno para las filas que ya existen.
  No cambia al editar la tarjeta.
- `helios_directorio()` añade la columna `lead_code` al final (se borra y se
  vuelve a crear; mismos permisos: anon y authenticated).
- `helios_directorio_whatsapp() → text` (anon y authenticated): el número de
  Helios (`platform_contact.whatsapp_number`, E.164) o null.
- Tabla `directory_leads` (RLS sin lectura, solo por RPC): `id uuid`,
  `merchant_id uuid` → merchants, `phone_e164 text`, `first_message_id text`,
  `messages int default 1`, `first_at timestamptz`, `last_at timestamptz`.
  Única por `(merchant_id, phone_e164)`: escribir otra vez suma `messages` y
  pone al día `last_at`.
- `bot_directorio_interesado(p_phone text, p_code text, p_message_id text) →
  jsonb` (solo `service_role`, como las demás `bot_*`):
  - Código desconocido o tarjeta que ya no sale: `{ ok: false, motivo:
    'codigo_desconocido' | 'no_publicado' }`, sin guardar nada.
  - Si no: guarda o pone al día el interesado y devuelve `{ ok: true, nuevo,
    lead_id, merchant_id, name, specialty, address, city, whatsapp }` (los
    datos que enseña la tarjeta; `whatsapp` en E.164).
  - `22023` con un teléfono que no es E.164 válido (`helios_wa_e164`).
- Conversión (la misma regla en todas partes): existe una orden de ese médico
  con `status = 'confirmed'`, no de prueba, creada en o después de `first_at`,
  cuyo paciente tiene el mismo teléfono (`phone_national_key`, los 10 últimos
  dígitos).
- `admin_directorio()` añade:
  - en `totales`: `interesados_30d`, `interesados_total`, `convertidos_30d`
    (interesados de los últimos 30 días que ya se convirtieron),
    `convertidos_total`;
  - en cada médico: `interesados: { total, d30, convertidos, ultimo }`.
- `admin_directorio_interesados(p_merchant_id uuid default null, p_limit int
  default 200) → jsonb` (`is_platform_admin()`): un arreglo, el más reciente
  primero, de `{ lead_id, merchant_id, medico, phone, first_at, last_at,
  messages, paciente: { profile_id, nombre } | null, conversion: { charge_id,
  order_number, created_at } | null }`. `paciente` es el perfil con ese
  teléfono, si existe; `conversion`, la primera orden que lo convierte.
- Suite `supabase/tests/directorio_interesados_smoke.sql` (begin/rollback, sin
  llamar a `helios_dispatch_*`) y su línea en `run.sh`.

### Webhook — `supabase/functions/whatsapp-webhook`

- `logica.ts`: `codigoDelDirectorio(texto: string | null): string | null`
  (`DIR-XXXX` en mayúsculas, aunque venga en minúsculas o con espacios
  alrededor).
- `directorio.ts`: `atenderAlInteresado({ rpc, mensaje, codigo })` llama a
  `bot_directorio_interesado` y contesta con `helios_whatsapp_patient_text`.
- `textos_directorio.ts`: los dos mensajes (contacto del médico; médico que ya
  no está). Vocabulario de CLAUDE.md: nada de «crédito», «financiamiento» ni
  «préstamo».
- `index.ts`: la ruta del código va **antes** que la del personal, para que
  un médico pueda probar su propia tarjeta.
- Pruebas Deno de lo nuevo. **No se despliega** hasta el final.

### Página — `/directorio`

- `MedicoDelDirectorio.codigo: string | null`; el loader trae también el número
  de Helios.
- `enlaceDeWhatsApp(medico, whatsappHelios)`: con número de Helios y código, el
  chat de Helios con «Hola, quiero agendar una consulta con {nombre}. (Código
  DIR-XXXX)»; si no, el enlace directo de hoy.
- El clic se sigue apuntando igual.

### Superadmin — Directorio de médicos

- Cifras: clics, interesados y pacientes de los últimos 30 días, con el paso de
  uno a otro.
- Tabla: columnas de interesados (30 días) y pacientes.
- Ficha del médico: sus interesados, con teléfono, fechas, mensajes y si ya se
  hizo paciente (con el número de orden).
- Una vista «Interesados» con todos, el más reciente primero.

## Frentes y orden

| Frente | Qué | Ficheros (solo esos) |
|---|---|---|
| A. Base | Migración, suite, `run.sh`, docs/01 §2.12 | `supabase/migrations/20261027100000_*`, `supabase/tests/directorio_interesados_smoke.sql`, `supabase/tests/run.sh`, `docs/01-CONTRATO-RPC.md` |
| B. Webhook | Ruta, textos y pruebas | `supabase/functions/whatsapp-webhook/*` |
| C. Página | Botón al WhatsApp de Helios | `panel/src/features/directorio/*`, `panel/src/components/directorio/*`, `panel/src/routes/directorio.tsx` |
| D. Superadmin | Embudo, columnas, ficha y vista | `panel/src/features/admin/directorioDeMedicos/*`, `panel/src/components/admin/directorio-de-medicos/*`, `panel/src/routes/admin/directorio.tsx` |

Los cuatro van en paralelo contra el contrato. Al final, el orquestador:
comprueba que todo cuadra junto (tipos, lint, pruebas, suites, contrato de las
RPC, build), hace una prueba de punta a punta sin mandar mensajes reales, y
pide el visto bueno para desplegar el webhook y pushear el panel.

## Lo que queda fuera

- Avisar al médico de cada interesado (descartado: «solo el contacto»).
- Un texto en `/legal/privacidad` sobre el uso del teléfono de quien escribe
  desde el directorio: es texto legal, lo decide Javier.
- El origen de cada clic (Instagram, QR…): se puede añadir después.
