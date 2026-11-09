# Prueba A/B del directorio: `/consultas`, con inicial de $15 (2026-11-09)

Dos directorios conviven y se comparan en el superadmin:

| Variante | Ruta | Qué ofrece | Botón de WhatsApp |
|---|---|---|---|
| **A** | `/directorio` (y `/directorio/<especialidad>`, `/medico/<slug>`) | El de siempre: 2 cuotas a los 14 y 28 días, sin inicial. Todos los médicos. | Directo al médico (`INTERESADOS_POR_HELIOS = false`, sin cambios). |
| **B** | `/consultas` | «¡Consultas médicas por solo $15 de inicial!» y el resto en 2 cuotas quincenales. Solo médicos con consulta **de $60 o menos** (o su equivalente en euros). | Al WhatsApp de Helios con el código del médico y la marca de B (`DIR-7K2P-B`): el bot apunta al interesado y le da el contacto del médico, como entre el 2026-10-27 y el 28 (docs/04). |

`/consultas` **no se enlaza** desde ninguna página (portada, menú, pie, guías),
no sale en el sitemap ni en `llms.txt` y lleva `noindex`: se llega solo por la
URL (anuncios, enlaces compartidos).

## Decisiones (Javier, 2026-11-09)

- La inicial es **solo texto** en `/consultas`: el cobro no cambia (sigue sin
  inicial, 2 cuotas a 14 y 28 días). Excepción aprobada a «textos públicos sin
  promesas» para esta prueba.
- Inicial: **$15** (USD). Tope: consulta **≤ $60**; una consulta en euros se
  compara por su equivalente en dólares con la tasa cruzada BCV del día
  (`BCV_EUR / BCV`, la última con `effective_date` ≤ hoy en Caracas). Sin
  precio, o sin tasa del euro, no entra. Además la consulta tiene que valer
  **más de $15** (si no, la inicial no tiene sentido).
- La tarjeta dice el precio («Consulta a partir de: $30») y **«Inicial $15 y
  el resto en 2 cuotas quincenales»**, **sin cifra** de las cuotas.
- El bot, a quien llega desde B, cierra con la frase neutra **«Puedes pagar
  tu consulta con Helios en cuotas.»** (a los de A, como hoy).
- Precios que faltaban (CSV `docs/Precio consulta/`): Dra. Andreina Prieto
  **€30** y Dr. Victor Miguel Gómez Montaño **€120**. Los demás ya coinciden.
  Sin precio a propósito: Risquez (vacunación), Ponte (tratamientos
  estéticos), Hafouri y Gómez Fagundez (no están en el CSV / sin cambio).

## Qué se mide

Solo lo **público** (`origin = 'publico'`; los clics del equipo y de las
clínicas no cuentan, igual que hoy).

- **Visitas** y **visitantes** (distintos, por `visitor_id`, el identificador
  aleatorio que ya usa el directorio). Nuevo: hoy solo se apuntan los clics.
- **Clics** al WhatsApp y **visitantes que tocaron** algún botón.
- **Tasa de clic** = visitantes que tocaron / visitantes. Es la métrica que
  decide la prueba (prueba z de dos proporciones en el panel).
- **Interesados** (los que escribieron al WhatsApp de Helios) y **pacientes**
  (convertidos, con la regla de docs/04): solo existen para B.

Las visitas se empiezan a contar el día que se publica esto: antes no hay
datos de visitas para A.

## El contrato (fijo: los frentes trabajan en paralelo contra esto)

Variante: `text` con `'a'` o `'b'`.

### Base — migraciones nuevas

1. `20261109130000_el_directorio_completa_precios_del_csv.sql`: pone el precio
   de las dos clínicas de arriba (buscadas por su nombre, que falle si no
   encuentra exactamente una cada una).
2. `20261109130100_la_prueba_ab_del_directorio.sql`:
   - `directory_contact_clicks.variant text not null default 'a' check (variant
     in ('a','b'))` (las filas que ya existen quedan en `'a'`).
   - `helios_directorio_contacto(p_merchant_id uuid, p_visitante text default
     null, p_origen jsonb default null, p_variante text default 'a') →
     boolean`: lo de hoy más la variante (otra cosa que no sea `'b'` cuenta
     como `'a'`). Se borra la firma de 3 argumentos y se crea la de 4, con los
     mismos permisos (anon, authenticated).
   - Tabla `directory_page_views` (RLS activada y sin políticas: solo por
     RPC): `id uuid pk default gen_random_uuid()`, `variant text not null
     check in ('a','b')`, `visitor_id text`, `origin text not null`
     (`publico`/`equipo`/`clinica`, misma regla que los clics), `source`,
     `referrer_host`, `landing_path`, `page_path`, `utm_source`,
     `utm_medium`, `utm_campaign` (mismas validaciones que los clics),
     `created_at timestamptz not null default now()`. Índices por
     `(variant, created_at)` y `(visitor_id, created_at)`.
   - `helios_directorio_visita(p_variante text, p_visitante text default
     null, p_origen jsonb default null) → boolean` (anon, authenticated):
     apunta una visita. Descarta (devuelve `false`) la misma página del mismo
     visitante en los últimos 30 minutos y más de 200 visitas de un visitante
     al día.
   - `directory_leads.variant text not null default 'a' check in ('a','b')`.
   - `bot_directorio_interesado(p_phone, p_code, p_message_id, p_variante
     text default 'a')`: lo de hoy más la variante, que se guarda al crear el
     interesado (si ya existía, conserva la suya). Devuelve además
     `variante`. El webhook desplegado hoy (sin `p_variante`) sigue
     funcionando.
   - `helios_consultas_tope_usd() → numeric` (= 60) y
     `helios_consultas_inicial_usd() → numeric` (= 15), `immutable`.
   - `helios_directorio_consultas()` (anon, authenticated): **las mismas
     columnas que `helios_directorio()`, en el mismo orden**, más
     `consultation_price_usd numeric` al final; solo los médicos que entran en
     B, **en el orden sorteado de `helios_directorio()`** (se filtra
     conservando el orden).
   - `admin_directorio_ab(p_desde date, p_hasta date) → jsonb`
     (`is_platform_admin()`; días de Caracas, ambos incluidos; máximo 366
     días):
     ```json
     {
       "desde": "2026-11-09", "hasta": "2026-11-15",
       "variantes": [
         { "variante": "a", "ruta": "/directorio", "visitas": 0, "visitantes": 0,
           "clics": 0, "visitantes_con_clic": 0, "interesados": 0, "convertidos": 0 },
         { "variante": "b", "ruta": "/consultas", "...": "lo mismo" }
       ],
       "dias": [ { "dia": "2026-11-09",
                   "a": { "visitantes": 0, "visitantes_con_clic": 0, "clics": 0 },
                   "b": { "visitantes": 0, "visitantes_con_clic": 0, "clics": 0 } } ],
       "medicos": [ { "merchant_id": "…", "medico": "Dra. Ana Lara",
                      "precio_cur": 40, "moneda": "USD", "en_b": true,
                      "clics_a": 0, "clics_b": 0, "interesados_b": 0, "convertidos_b": 0 } ],
       "excluidos": { "visitas_equipo": 0, "clics_equipo": 0 },
       "visitas_desde": "2026-11-09"
     }
     ```
     `visitantes` cuenta `coalesce(visitor_id, id::text)` distintos;
     `visitantes_con_clic`, los visitantes con algún clic de esa variante en
     el rango. `dias` trae **todos** los días del rango, también los vacíos.
     `medicos`: los que entran hoy en B más cualquiera con un clic en el
     rango, el de más clics primero. `interesados` / `convertidos`: los
     interesados de esa variante con `first_at` en el rango, y de esos, los
     convertidos (regla de docs/04). `visitas_desde`: el día de la primera
     visita apuntada (o `null`).
   - Suite `supabase/tests/directorio_ab_smoke.sql` (begin/rollback, sin
     `helios_dispatch_*`) y su línea en `run.sh`. Contrato en docs/01 §2.15.
     El mapa del asistente (`supabase/functions/admin-asistente/mapa.json`)
     conoce la tabla y las columnas nuevas.

### Webhook — `supabase/functions/whatsapp-webhook`

- `logica.ts`: `varianteDelDirectorio(texto): 'a' | 'b'` → `'b'` si el código
  va seguido de `-B` (mayúsculas o minúsculas, con o sin espacios alrededor
  del guion); si no, `'a'`. `codigoDelDirectorio` no cambia (ya reconoce
  `DIR-7K2P` dentro de `DIR-7K2P-B`).
- `directorio.ts`: pasa `p_variante` a `bot_directorio_interesado`.
- `textos_directorio.ts`: `mensajeContactoDelMedico(t, variante = 'a')`; con
  `'b'`, la última línea es «Puedes pagar tu consulta con Helios en cuotas.».
- Pruebas Deno. **No se despliega** hasta el visto bueno de Javier.

### Página — `/consultas` y las de A

- `mensajeAHelios(nombre, codigo, variante)`: con `'b'`, «Hola, quiero agendar
  una consulta con {nombre}. (Código DIR-7K2P-B)».
- `apuntarContacto(merchantId, variante = 'a')` manda `p_variante`.
- `apuntarVisita(variante)`: una vez por página montada, `fetch` con
  `keepalive` a `helios_directorio_visita`, con `visitante()` y
  `origenDelClic()`, sin esperar ni avisar de fallos. En `/directorio`,
  `/directorio/<especialidad>` y `/medico/<slug>` con `'a'`; en `/consultas`
  con `'b'`.
- `/consultas`: `helios_directorio_consultas()` + número de Helios (siempre se
  pide). Si no hay número de Helios o la tarjeta no tiene código, el botón va
  directo al médico (nunca se queda sin funcionar). Titular «¡Consultas
  médicas por solo $15 de inicial!», entrada «Paga el resto en 2 cuotas
  quincenales.», cada tarjeta con «Inicial $15 y el resto en 2 cuotas
  quincenales». Nada en la página dice «sin inicial» ni «14 y 28 días». El
  filtro de especialidad se queda en la página (`?especialidad=`), sin llevar
  a `/directorio/<especialidad>`; sin filtro de precio; las tarjetas no
  enlazan a la ficha de A.

### Superadmin

- Pro: Directorio de médicos › vista «Prueba A/B» (`/admin/directorio?vista=ab`):
  rango (7, 14, 30, 90 días), las dos variantes lado a lado (visitantes,
  clics, tasa de clic, interesados, pacientes), el veredicto (prueba z de dos
  proporciones sobre la tasa de clic: quién gana y con qué confianza, o «aún
  no hay datos suficientes»), la serie diaria y la tabla por médico.
- Lite: la misma vista como pestaña «Prueba A/B», junto a «Clics por médico».

## Cómo quedó (2026-11-09)

- Migraciones `20261109130000`, `20261109130100` y `20261109140000`, ya
  aplicadas. El contrato de las RPC quedó en **docs/01 §2.17** (la §2.15 ya
  estaba ocupada).
- **Tasa de clic** (`20261109140000`): `visitantes_con_clic` cuenta solo los
  navegadores que tocaron un botón de esa variante **y la visitaron** en el
  rango (en la serie diaria, ese mismo día). Así los clics de antes de que se
  contaran las visitas, o los de páginas que no apuntan visita (las guías del
  paciente), no inflan la tasa. `clics` sigue contando todos los toques.
- `helios_directorio_visita` rechaza una variante que no sea `a`/`b`; el clic,
  en cambio, toma cualquier otra cosa como `a`.
- `/consultas` va **sin menú, pie ni «Cómo pagas»**: todos llevan a páginas
  que dicen «sin inicial» o «14 y 28 días». Arriba solo el logo (sin enlace)
  y abajo la línea de Quarto Latam con un enlace a `/legal/privacidad`. El
  sello «0% inicial» de A pasa a «$15 inicial» en el mismo sitio, para que
  las dos variantes se parezcan en todo menos en la oferta.
- El panel solo manda `p_variante` cuando es `'b'`: los clics de A no dependen
  de la migración.
- El veredicto exige al menos 100 visitantes por variante y un 95% de
  confianza; si no, «aún no hay diferencia clara».
- Hoy (2026-11-09) `/consultas` enseña **17 médicos**. No salen la Dra.
  Marianghela Martinez (sin WhatsApp, bloqueada) ni la Dra. Israelys Nuñez
  (oculta), aunque su precio entraría.
- Las visitas del equipo **sin sesión iniciada** cuentan como públicas (como
  ya pasaba con los clics): para probar las páginas, mejor con la sesión del
  panel abierta en el navegador.

## Frentes

| Frente | Ficheros (solo esos) |
|---|---|
| A. Base | `supabase/migrations/20261109130000_*`, `supabase/migrations/20261109130100_*`, `supabase/tests/directorio_ab_smoke.sql`, `supabase/tests/run.sh`, `docs/01-CONTRATO-RPC.md`, `supabase/functions/admin-asistente/mapa.json` |
| B. Webhook | `supabase/functions/whatsapp-webhook/*` |
| C. Página | `panel/src/features/directorio/*`, `panel/src/components/directorio/*`, `panel/src/routes/directorio.tsx`, `panel/src/routes/directorio_.$especialidad.tsx`, `panel/src/routes/medico.$slug.tsx`, `panel/src/routes/consultas.tsx` (nuevo), `panel/src/routeTree.gen.ts` |
| D. Superadmin | `panel/src/features/admin/directorioDeMedicos/*`, `panel/src/components/admin/directorio-de-medicos/*`, `panel/src/routes/admin/directorio.tsx`, `panel/src/lite/*` |

Al final, el orquestador comprueba que todo cuadra (tipos, lint, pruebas,
suites, `verificar-contrato`, build), prueba de punta a punta sin mandar
mensajes reales y pide el visto bueno para desplegar el webhook y pushear.
