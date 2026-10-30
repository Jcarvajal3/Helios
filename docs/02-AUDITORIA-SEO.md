# Auditoría SEO del sitio público (2026-10-14)

Objetivo: que a Helios lo encuentren quienes **no conocen la marca ni el
dominio** — pacientes que buscan cómo pagar una consulta en cuotas y médicos
que buscan cómo ofrecerlo — en Google, Bing y los buscadores con IA.

## Lo que había

| Área | Estado | Nota |
| --- | --- | --- |
| Renderizado | ✅ | SSR (TanStack Start): el HTML ya trae todo el texto. |
| Canonical, Open Graph, Twitter | ✅ | `cabeceraPublica` en `config/sitio.ts`. |
| `robots.txt`, `sitemap.xml` | ✅ | Sitemap con 5 páginas, sin `lastmod`. |
| `www` → raíz | ✅ | 308 en Vercel. |
| Panel fuera de Google | ✅ | `noindex` en `_comercio`, `admin`, `login`. |
| Título de la portada | ⚠️ | «Tu salud hoy, en dos cuotas \| Helios Venezuela»: el eslogan, no lo que se busca. |
| H1 de la portada | ⚠️ | Solo el eslogan; ninguna palabra clave («consulta médica», «cuotas»…). |
| Páginas por intención de búsqueda | ❌ | Una sola página para dos públicos y tres especialidades: nada que posicione para «odontología en cuotas» o «cobrar consultas en cuotas». |
| Enlazado interno | ⚠️ | El menú eran anclas `#…`; el pie, solo soporte y legales. |
| Datos estructurados | ⚠️ | Solo en la portada. `audience` mal usado (las especialidades como público). Sin `WebPage`, sin miga de pan. |
| Rendimiento (LCP) | ⚠️ | La portada descargaba las fuentes del panel (Outfit, Source Sans) sin usarlas: una hoja que bloquea el primer pintado. |
| Buscadores con IA | ❌ | Sin `llms.txt`. |
| Favicon en resultados | ⚠️ | Solo SVG; sin PNG de respaldo. |
| `/plantillas/pago-masivo.xlsm` | ⚠️ | Rastreable. |

## Lo que se hizo

**Páginas nuevas** (texto en `panel/src/components/portada/guias.ts`, las pinta
`Guia.tsx` con el aspecto de la portada). Cada una con título, H1, descripción,
pasos, ventajas y preguntas propias, miga de pan visible y enlaces cruzados:

| Ruta | Público | Búsquedas a las que apunta |
| --- | --- | --- |
| `/pacientes` | Paciente | pagar consulta médica en cuotas, pagar médico en cuotas sin inicial, cuotas con Pago Móvil |
| `/medicos` | Médico o centro | cobrar consultas en cuotas, ofrecer pago en cuotas en el consultorio, pago garantizado |
| `/consulta-medica-en-cuotas` | Paciente | consulta médica en cuotas, especialista en cuotas |
| `/odontologia-en-cuotas` | Paciente (+ odontólogo) | odontólogo / dentista en cuotas, consulta odontológica en cuotas |
| `/cosmetologia-en-cuotas` | Paciente (+ centro) | tratamientos estéticos en cuotas, cosmetología en cuotas |

**Portada**: título «Consultas médicas en cuotas, sin inicial | Helios
Venezuela»; descripción para los dos públicos; el rótulo «Consultas médicas en
cuotas · Venezuela» entra en el H1; el párrafo de entrada nombra médico,
odontólogo y cosmetólogo; las secciones de médicos y pacientes enlazan a su
página.

**Técnico**:
- `cabeceraPublica` pone en todas las páginas públicas el grafo JSON-LD común
  (`Organization` con `alternateName` «Helios Salud» y «Helios Venezuela»,
  `WebSite`, `WebPage` con `dateModified`) más `BreadcrumbList`, `Service`
  (con `MedicalAudience` Patient o Clinician) y `FAQPage` donde toca.
- `hreflang` es-VE, `geo.region` VE, `<html lang="es-VE">`, robots con
  `max-snippet:-1`.
- Sitemap con las 10 páginas y su `lastmod` (`PAGINAS_PUBLICAS`, se actualiza
  a mano al cambiar el texto de una página).
- `robots.txt` cierra `/plantillas/`.
- `/llms.txt`: Helios en texto plano para ChatGPT, Perplexity y Gemini, armado
  con los mismos datos que la portada.
- Fuentes por ruta (`lib/fuentes.ts`): la portada y las guías ya no bajan las
  del panel.
- Favicon PNG de respaldo (512 px).
- Menú: «Médicos y centros» y «Pacientes» llevan a sus páginas; pie con
  columnas Pacientes / Médicos y centros / Helios / Legal.

**`/directorio` (2026-10-26) va fuera de todo esto a propósito**: el
directorio de médicos se comparte por URL y, desde el 2026-10-30 (Javier), se
llega también por «Directorio» en el menú de la portada (`MENU`). Lleva
`noindex, follow`, no está en `PAGINAS_PUBLICAS`
(ni en el sitemap ni en `llms.txt`) y no usa `cabeceraPublica`; sí lleva sus
etiquetas `og:`/`twitter:` para que la vista previa salga bien al mandarlo
por WhatsApp. Si un día se quiere en Google, se pasa a `cabeceraPublica`, se
añade a `PAGINAS_PUBLICAS` y se enlaza desde el menú o el pie.

Todo respeta las reglas de vocabulario de CLAUDE.md (nada de «préstamo»,
«financiamiento», «crédito» ni «fee») y solo afirma lo que el sistema ya hace
(límite inicial de $150, sin decir que crece; sin mencionar mora).

## Lo que queda fuera del código (lo hace Javier)

1. **Google Search Console**: dar de alta `conhelios.com` como *propiedad de
   dominio* (verificación por registro TXT en el DNS), enviar
   `https://conhelios.com/sitemap.xml` y pedir la indexación de las 5 páginas
   nuevas. Lo mismo en **Bing Webmaster Tools** (puede importar de Search
   Console); Bing alimenta también a ChatGPT y a Copilot.
2. **Perfil de Empresa de Google** (Google Business Profile) a nombre de
   Helios, categoría de servicio de pagos, con el enlace a la web: es lo que
   aparece al buscar «Helios» en Venezuela.
3. **Enlaces entrantes**: el enlace de la bio de Instagram a
   `conhelios.com`; pedir a cada clínica afiliada que enlace a `/pacientes`
   desde su web, su Instagram o su perfil de Google («Aceptamos pagos en
   cuotas con Helios»). Es lo que más sube el posicionamiento a partir de
   aquí.
4. **Contacto público**: cuando exista correo o WhatsApp de atención
   (`RESPONSABLE` en `config/legal.ts`), añadirlo da `contactPoint` al
   JSON-LD y confianza a Google en un sitio de salud y pagos.
5. **Más adelante**: un blog o guías («¿Cuánto cuesta una consulta con el
   odontólogo en Venezuela?», «Cómo pagar al médico con Pago Móvil»)
   captaría búsquedas informativas; y una página por ciudad solo cuando haya
   clínicas afiliadas reales en ella (una página por ciudad sin clínicas sería
   una promesa falsa).

## Cómo comprobarlo

- [Prueba de resultados enriquecidos](https://search.google.com/test/rich-results)
  con cada URL pública.
- [PageSpeed Insights](https://pagespeed.web.dev/) de la portada y de una guía.
- `site:conhelios.com` en Google, unos días después de enviar el sitemap.
