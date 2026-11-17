# Metodologías técnicas para capturar y mantener precios de medicamentos por farmacia

Notas de investigación, fecha de corte 2026-11-04. Lo marcado «estimación propia» es cálculo o juicio mío, no un dato publicado. Muchas cifras de herramientas vienen de páginas de proveedores: se indica cuando es así. Las cuentas usan precios de lista vistos en esta fecha.

## ¿Un bot que entra a las webs de las farmacias es la mejor forma? Veredicto y comparación

### Takeaway
No como vía única. El scraping es la forma más barata de sembrar el catálogo y tener precios de referencia de las cadenas, pero deja fuera a las farmacias sin web y mide el precio de la web, que en farmacias coincide con el del mostrador solo el 38% de las veces en el mejor estudio disponible (no venezolano). La arquitectura recomendada es híbrida: récipe digital, catálogo canónico, scraping de cadenas por API, listas por WhatsApp para independientes, confirmación en vivo por WhatsApp antes de mandar al paciente, y las compras propias como auditoría.

### Cited Findings
- En 56 grandes minoristas de 10 países y más de 24.000 productos, el precio online y el de tienda fue idéntico en el 72% de los casos, pero solo en el **38% en droguerías y farmacias** y en el 42% en Brasil (69% en EE. UU., 91% en Canadá). Cuando difieren, online es cerca de 4% más bajo — [AEA, resumen de Cavallo 2017](https://www.aeaweb.org/research/online-offline-price-differences).
- Los comparadores chilenos más parecidos no describen scraping como su fuente. Búho tiene siete acuerdos comerciales con farmacias que «facilitan los precios y stock de sus sucursales» y cobra comisión por venta, menos del 1% de la boleta al consumidor (2023) — [Diario Financiero](https://www.df.cl/df-lab/innovacion-y-startups/buho-la-startup-que-creo-una-plataforma-que-optimiza-la-compra-y). Yapp dice tener alianzas con más de 30 cadenas; el artículo no explica cómo obtiene los precios — [Forbes Chile, 2022](https://forbes.cl/negocios/2022-10-24/mauricio-ferrari-cofundador-de-yapp-el-romantico-dice-quiero-cambiar-el-sistema-de-salud-chileno-yo-digo-que-se-puede-ahorrar/).
- GoodRx no raspa webs: muestra precios contratados entre farmacias y PBM (administradores de beneficios), además de programas propios de farmacias y fabricantes — [GoodRx, FAQ](https://www.goodrx.com/corporate/news/faqs-from-pharmacy-professionals). El ingreso sale de una comisión por receta que comparte el PBM — [Drug Channels, 2020](https://www.drugchannels.net/2020/08/how-goodrx-profits-from-our-broken.html).
- Instacart combina datos del minorista con señales de sus compradores (escaneos y «no encontrado», millones al día) y da una probabilidad de disponibilidad, no un sí o no — [Instacart Engineering](https://company.instacart.com/tech-innovation/how-instacart-modernized-the-prediction-of-real-time-availability-for-hundreds-of-millions-of-items-while-saving-costs).

### Inferences
Tabla comparativa. **Todas las celdas de costo, cobertura y escala son estimación propia** apoyada en los precios citados en las secciones siguientes; piloto de referencia: 50 a 100 farmacias en una ciudad y 1.000 récipes al mes. Cobertura significa fracción de farmacias de ese piloto, y depende del censo que cubre otro investigador.

| Vía | Construir | Operar al mes | Frescura | Cobertura | Esfuerzo | Riesgo principal | Tiene sentido desde |
|---|---|---|---|---|---|---|---|
| Scraping por API interna o selectores | 2-5 días por sitio | $10-100 de servidor y 2-4 h por sitio | 6-24 h | Solo con web (cadenas) | Medio | Web distinta del mostrador; fallos silenciosos; legal | 1 cadena con catálogo público |
| Extracción con LLM (Firecrawl, Crawl4AI) | 0,5-1 día por sitio | $0,001-0,005 por página | 1-7 días | Igual, más sitios raros | Bajo | Costo si crece; errores no detectados | Sitios sin API, menos de 100.000 páginas/mes |
| Agente de navegador | Horas | $0,03-1,64 por tarea | A demanda | Igual | Bajo | Costo, lentitud | Excepciones, menos de 100 tareas/día |
| Conector en POS/ERP | 4-12 semanas el primero, 1-3 los siguientes | Soporte alto en sitio | 15 min-24 h, con stock por sede | Baja al inicio, muy buena calidad | Alto | Adopción, instalación en PC ajenas | Cadena con ERP central o 50+ farmacias con el mismo sistema |
| CSV o portal | 1-2 semanas sobre el panel | Bajo | Semanal a mensual | 20-50% de las que acuerden | Bajo | Se dejan de subir | Desde el inicio como opción |
| Listas por WhatsApp (Excel, PDF, foto) | 1-3 semanas sobre el bot | $20-150 de LLM y plantillas, más 0,25-0,5 persona | Semanal | Independientes que cooperen | Medio | Datos sucios; abandono | Desde el inicio |
| Cotización en vivo por WhatsApp | 1-3 semanas sobre el bot | ~$0,06 por récipe a 5 farmacias | Minutos a horas | Las que respondan | Medio | Fatiga, demora, precios-gancho | Desde el inicio, 10-30 farmacias por ciudad |
| Facturas de pacientes | 2-4 semanas | $0,001-0,02 de OCR y $0,10-0,50 de incentivo por ticket | Irregular | Solo productos más vendidos | Medio | Densidad insuficiente, fraude | Miles de tickets al mes por ciudad |
| Capturadores de campo | Días | $300-600 por persona (sin verificar) | 2-4 semanas | La que se pague | Medio | Costo por dato | Muestra de auditoría |
| Voz con IA | 1-2 semanas | $0,20-0,62 por llamada más telefonía +58 | Tiempo real | Las que contesten | Medio | Cuelgan, acento, consentimiento | Respaldo puntual |
| Compras propias | Casi nada si ya hay flujo | ~0 | Por compra | Solo lo transado | Bajo | Sesgo: solo ve al ganador | Cuando haya volumen |

- Elegir entre vías es elegir qué mide cada una: el scraping mide «lo que dice la web», las listas «lo que la farmacia dijo la semana pasada», la cotización «lo que dice hoy» y la factura «lo que cobró». Solo las dos últimas sirven para prometerle algo al paciente.
- Chile sugiere que el activo defendible es el acuerdo con la farmacia, no el robot. Es un indicio débil, porque ninguno de los dos artículos describe el sistema por dentro.

### Gaps
- No encontré un estudio de online frente a mostrador en farmacias latinoamericanas ni venezolanas. El 38% es de cadenas grandes multicanal, datos 2014-2016, y puede no trasladarse.

## Scraping de webs y apps: scrapers por sitio, LLM, agentes y anti-bot

### Takeaway
El orden correcto es: API JSON interna o sitemap por HTTP simple, luego selectores deterministas, luego LLM solo para lo que cambió o no se entiende, y agentes solo para escribir o reparar scrapers. Entre un extremo y otro hay una diferencia de tres a cuatro órdenes de magnitud en costo por página; un agente de navegador no es la herramienta para un rastreo recurrente.

### Cited Findings
- **Firecrawl (página oficial, vista hoy):** Free 1.000 créditos; Hobby $19/mes con 5.000; Standard $99 con 100.000; Growth $399 con 500.000; Scale $749 con 1.000.000 (mensual; algo menos en anual). Scrape 1 crédito por página, JSON suma 4 (total 5), navegador 2 créditos por minuto. No lista el costo de proxy reforzado — [Firecrawl Pricing](https://www.firecrawl.dev/pricing).
- **Crawl4AI:** Apache-2.0, autohospedable como librería Python o Docker, basado en Playwright. Trae extracción sin LLM (esquemas CSS, XPath, regex) y un generador de esquemas reutilizables, además de extracción con cualquier proveedor vía LiteLLM. Su nube ofrece 1.000 créditos gratis y planes desde $10 — [GitHub](https://github.com/unclecode/crawl4ai).
- **Browser Use (documentación del proveedor):** mediana por tarea exitosa en producción de $1,64 (V4), $0,87 (V3) y $0,70 (V2), medida con Claude Opus 4.7 en julio de 2026; éxito en tareas difíciles de 76%, 67% y 54%, excluyendo tareas bloqueadas por anti-bot; ~5, ~2 y ~1 min por tarea. Advierte que el costo de V4 no refleja su modelo actual, mucho más barato — [Browser Use Docs](https://docs.browser-use.com/cloud/choosing-an-agent). Su anuncio de V4 afirma ~$0,03 por tarea exitosa y ~88% de éxito — [Runtime Wire](https://runtimewire.com/article/browser-use-cloud-v4-luna-web-agent-cost). Un caso reportado da $0,47 de modelo y cuatro minutos por corrida — [AI Pricing Guru](https://www.aipricing.guru/news/asana-browser-agent-gpt-6-1-sol-cost-october-2026/).
- **Claude computer use:** se cobra como uso de herramientas; ~735 tokens de entrada por definición de herramienta y las capturas de pantalla se facturan como imagen — [Anthropic Pricing](https://platform.claude.com/docs/en/about-claude/pricing).
- **LLM para extraer (por millón de tokens, entrada/salida):** Claude Haiku 5.5 $0,10/$0,50 hasta 100.000 tokens por prompt, $0,50/$2,50 por encima; Claude Sonnet 5 $2/$10; lote con 50% de descuento — [Anthropic Pricing](https://platform.claude.com/docs/en/about-claude/pricing). Gemini 3.1 Flash-Lite $0,25/$1,50; Gemini 3.6 Flash $0,75/$3,75 hasta el 31-12-2026 y $1,50/$7,50 desde enero de 2027; lote 50% menos — [Google AI Studio Pricing](https://aistudio.google.com/docs/pricing).
- **Proxies residenciales:** comparativas de terceros, con conflicto entre sí, dan $3-15/GB; mercado medio (Decodo, SOAX, NetNut) $3-6/GB; Bright Data y Oxylabs $8,50-12/GB, con Bright Data bajando a ~$3,30/GB en 10 TB — [AIMultiple](https://aimultiple.com/proxy-pricing); [Proxidize](https://proxidize.com/blog/residential-proxy-pricing/); [DEV](https://dev.to/ethan_walker995/cheapest-residential-proxy-providers-in-2026-price-per-gb-comparison-38g3). Son páginas con incentivos de afiliación.
- **Mantenimiento (solo fuentes de proveedores, sin estudio independiente):** las cifras van de 1-2% de trabajos rotos por semana a 10-15% de rastreadores con arreglos semanales; ~2,6 cambios de estructura por fuente al año; 2-4 h al mes por sitio. No pude asignar cada cifra a una página concreta sin leerlas todas, y varían un orden de magnitud — [Phyllo](https://www.getphyllo.com/post/why-scrapers-break); [ProWebScraper](https://prowebscraper.com/articles/scraper-breakage); [Taprun](https://taprun.dev/blog/scrapers-break-every-week.html); [DEV](https://dev.to/agenthustler/the-real-cost-of-diy-web-scraping-in-2026-5-hidden-time-sinks-nobody-warns-you-about-260k).
- Las fallas más caras son silenciosas: un selector roto devuelve nulos, no errores; se recomiendan controles de tasa de llenado y URL canario — mismas fuentes. Los «scrapers que se autorreparan» se anuncian sin datos de tasa de reparación — [ScrapeGraphAI](https://scrapegraphai.com/glossary/ai-scraping/self-healing-scrapers).
- **Límite del stack actual:** Supabase Edge Functions tiene 256 MB de memoria, 2 s de CPU por petición y 150 s (Free) o 400 s (pago) de vida, y no admite librerías Node multihilo como `sharp` — [Supabase Limits](https://supabase.com/docs/guides/functions/limits).

### Inferences
Costo real, **estimación propia**, con el supuesto de 5 cadenas × 5.000 productos × actualización diaria = 750.000 productos al mes:

| Método | Costo mensual aproximado | Cálculo |
|---|---|---|
| API JSON interna (50-100 productos por petición) | $10-40 | 250-500 peticiones/día en un servidor pequeño |
| HTML con selectores, sin proxy | $20-80 | Solo servidor |
| Lo anterior con proxy residencial | $450-1.200 | 750.000 × 200 KB = 150 GB × $3-8/GB |
| Playwright sin bloquear recursos, con proxy | $4.500-12.000 | ~2 MB por página: por eso se bloquean imágenes y fuentes |
| Firecrawl solo scrape | ~$749 | 750.000 créditos, plan Scale |
| Firecrawl con JSON | ~$2.800 o empresarial | 3,75 M créditos extrapolados a la tarifa de Scale |
| LLM propio, todas las páginas, Haiku 5.5 | ~$280 ($140 en lote) | ~3.000 tokens entrada + 150 salida = ~$0,0004 por página |
| LLM propio, todas las páginas, Sonnet 5 | ~$5.600 | ~$0,0075 por página |
| LLM solo sobre el 5% que cambió, Haiku 5.5 | ~$14 | Hash del contenido antes de llamar al modelo |
| Agente de navegador | $22.500 a $1,2 M | $0,03-1,64 por tarea |

- Stack recomendado (estimación propia): `fetch` o `httpx` contra la API que ya usa el sitio; Playwright o Crawl4AI con bloqueo de recursos si hace falta renderizar; LLM barato con salida JSON validada; Haiku o Sonnet solo para generar el selector cuando se rompe, con revisión humana del cambio.
- Los scrapers no caben en Edge Functions. Deben correr fuera: un servidor de $5-40/mes o GitHub Actions, escribiendo a Supabase por RPC. Vercel no aporta nada aquí.
- Probar primero sin proxy: los sitios de cadenas regionales suelen ser menos agresivos que Amazon, pero es una hipótesis a medir por sitio. No se debe contratar proxy por adelantado.
- Consumir API de la app móvil (interceptar con mitmproxy) da datos muy limpios pero es la variante más frágil y con más riesgo contractual; el investigador legal debe opinar antes.
- Control mínimo por corrida: conteo de productos frente a ayer, tasa de nulos, distribución de precios, cinco productos canario con precio conocido. Si un control falla, se conserva el dato anterior y baja su confianza; no se publica el nuevo.
- Mantenimiento presupuestado: 2-4 h por sitio al mes parece razonable para 5-10 cadenas. Por encima de 20 sitios ya se necesita alguien dedicado parcialmente.

### Gaps
- Sin datos independientes de tasa de rotura, ni específicos de scrapers generados por LLM.
- No verifiqué qué sitios venezolanos usan Cloudflare u otros anti-bot, ni si bloquean IP extranjeras: corresponde al investigador de farmacias y no se debía raspar en esta tarea.
- Costo de proxy reforzado de Firecrawl: no aparece en su página de precios.

## Integración directa con la farmacia: conector POS/ERP, CSV programado y portal

### Takeaway
Es la fuente de mejor calidad y la única que da stock por sede casi en tiempo real, pero es la más cara de adoptar. Conviene empezar por cadenas con ERP central y por exportaciones simples sin instalar nada. Un conector por sistema solo se justifica cuando varias farmacias comparten el mismo software.

### Cited Findings
- Modelo «la farmacia entrega sus datos por acuerdo»: Búho recibe precios y stock de sucursales mediante siete acuerdos, y paga con comisión por venta — [Diario Financiero](https://www.df.cl/df-lab/innovacion-y-startups/buho-la-startup-que-creo-una-plataforma-que-optimiza-la-compra-y).
- Advertencia de cumplimiento: en Perú, con obligación legal de reportar precios al observatorio DIGEMID, el cumplimiento rondó 71% en droguerías y 43% en laboratorios (diciembre de 2022) — [DIGEMID 2022](https://www.digemid.minsa.gob.pe/Archivos/PortalWeb/Informativo/Acceso/Snippf/InformeCumplimiento/Cumplimiento_Droguerias_Laboratorios_Diciembre-2022.pdf) — y 68,7% y 41,2% (marzo de 2024) — [DIGEMID 2024](https://www.digemid.minsa.gob.pe/Archivos/PortalWeb/Informativo/Acceso/Snippf/InformeCumplimiento/Cumplimiento_Droguerias_Laboratorios_Marzo-2024.pdf). El reporte de farmacias se estancó en el segundo semestre de 2024 — [DIGEMID IR 2024-12](https://www.digemid.minsa.gob.pe/Archivos/PortalWeb/Informativo/Acceso/Snippf/IndicadoresPrecios/IR_2024_12.pdf). La plataforma se reinició en abril de 2023 sin datos de enero a marzo — [DIGEMID 2023](https://www.digemid.minsa.gob.pe/Archivos/PortalWeb/Informativo/Acceso/Snippf/InformeCumplimiento/Cumplimiento_Droguerias_Laboratorios_Ene-Abr-2023.pdf). Son cifras de resumen de búsqueda; no abrí cada PDF.
- En Venezuela, la Providencia SNAT/2024/000121 (Gaceta 43.032, 19-12-2024) reguló a los proveedores de sistemas de facturación, con homologación — [Finanzas Digital](https://finanzasdigital.com/gaceta-oficial-n-43-032-requisitos-proveedores-sistemas-informaticos-emision-facturas-fiscales). Una fuente indica que fue derogada y hay un titular «SENIAT permite el uso de cualquier sistema contable» — [Acceso a la Justicia](https://accesoalajusticia.org/seniat-permite-el-uso-de-cualquier-sistema-contable/). No leí el texto completo: situación vigente sin confirmar.

### Inferences
- Tres escalones, de menos a más fricción (estimación propia):
  1. **Portal en el panel existente:** subir Excel o CSV, mapear columnas una vez y guardar ese mapeo por farmacia. 1-2 semanas sobre TanStack Start.
  2. **Exportación programada sin instalar nada propio:** la farmacia exporta del sistema y envía por correo o WhatsApp a una dirección dedicada; se procesa igual que el portal.
  3. **Agente instalado:** servicio Windows o tarea programada que lee por ODBC, SQL o archivo de exportación, deja cola local y empuja por HTTPS saliente con token por farmacia y `idempotency_key`. Debe tolerar cortes de luz e internet y reanudar sin duplicar.
- Costo del agente: 4-12 semanas el primero por las variantes de cada sistema y versión, y sobre todo soporte en sitio: una visita por instalación y reinstalaciones cuando cambian la PC o el contador. Regla práctica: no construir un conector para menos de 30-50 farmacias con el mismo sistema, salvo una cadena con ERP central, donde una sola integración da cientos de filas por sede.
- Mínimo a exigir: código interno, descripción, código de barras si existe, precio de venta y moneda, existencia, fecha de corte. El código de barras es lo que más valor añade, porque resuelve la identidad de producto.
- Lo de Perú importa como techo: si con obligación legal hay 40-70% y mensual, la adopción voluntaria será menor, salvo que el dato le traiga clientes a la farmacia. El incentivo es comercial (pacientes que llegan), no tecnológico.

### Gaps
- No encontré cuota de mercado de sistemas administrativos en farmacias venezolanas (Saint, A2, Profit Plus u otros) ni documentación pública de sus esquemas o API.
- Falta confirmar si la facturación digital venezolana vigente deja algún camino a datos estructurados por línea.

## Captura por WhatsApp: listas, fotos y PDF con OCR e IA

### Takeaway
Es la vía de mejor relación esfuerzo-cobertura para independientes porque reutiliza el bot y el hábito existente. El costo de IA es despreciable (centavos por lista); lo caro es que la farmacia siga enviando y la revisión humana de líneas dudosas. La extracción de líneas de tabla sigue siendo la parte difícil y no hay un banco de pruebas independiente con números por modelo.

### Cited Findings
- Muchas farmacias ya atienden así de forma informal: el cliente manda la foto de la receta y alguien verifica a mano disponibilidad y total. Es un artículo de proveedor y no da cifras — [Aurora Inbox](https://www.aurorainbox.com/?p=38222).
- OpenMed (Latinoamérica) usó primero grupos de WhatsApp y luego los reemplazó con una plataforma para cotizar, lanzada en enero de 2024; sirve a más de 1.000 pacientes con tres cadenas. Su sistema de IA para leer recetas y cotizar estaba en desarrollo a marzo de 2025 — [Infomercado](https://infomercado.pe/openmed-integra-inteligencia-artificial-y-expande-sus-servicios-con-farmacia-propia/).
- **Costos de WhatsApp:** desde julio de 2025 se cobra por mensaje según categoría y país; lo que envía el usuario es gratis; +58 entra en «Rest of Latin America»; hay 1.000 mensajes de servicio gratis por número al mes, y **las plantillas de utilidad dentro de la ventana de 24 h dejaron de ser gratis el 1 de octubre de 2026** — [Meta](https://developers.facebook.com/docs/whatsapp/pricing).
- Tarifa reportada por terceros para esa región desde octubre de 2026: marketing $0,0740, utilidad $0,0113, autenticación ~$0,0113-0,0116 — [eGrow](https://www.egrow.com/en/blog/whatsapp-template-pricing-explained-2026); [RichAutomate](https://richautomate.in/blog/whatsapp-api-pricing-by-country-2026); [Zernio](https://zernio.com/whatsapp-api-pricing). Conflicto: otra fuente da $0,0851 y $0,0130 con la misma fecha — [Gallabox](https://docs.gallabox.com/pricing-and-billing/whatsapp-pricing/rate-card.md); julio de 2026: $0,0777 y $0,0119 — [HighLevel](https://ideas.gohighlevel.com/changelog/updated-whatsapp-per-message-pricing-effective-july-2026).
- **OCR especializado:** Veryfi $0,08 por recibo y $0,16 por factura, con planes desde ~$500/mes según terceros — [TrustRadius](https://trustradius.com/products/veryfi/reviews). Taggun desde NZ$0,06 por escaneo — [Capterra](https://www.capterra.com/p/163510/Taggun).
- **Precisión:** ReceiptBench (ACL 2026) con 10.000 recibos separa lectura, normalización, razonamiento y estructura de líneas anidadas; su resumen no da cifras por modelo — [arXiv](https://arxiv.org/abs/2605.22413). Claude 3.5 Sonnet logró 97% en pares clave-valor en una prueba de un tercero, métrica que no aísla las líneas — [AIMultiple](https://aimultiple.com/receipt-ocr). Una comparativa débil da ~87% en líneas para Azure Document Intelligence y recoge un 98,7% anunciado por Veryfi — [Parse.gl](https://www.parse.gl/prompts/p/which-ocr-api-is-the-most-accurate-for-extracting-structured-data-from-complex-documents-like-invoices-and-receipts--ea94ef89-6bfa-4383-b8e1-1758bd904537).

### Inferences
- El cambio de Meta de octubre de 2026 también encarece las plantillas de utilidad que el bot actual de Helios envíe dentro de la ventana de 24 h; conviene revisarlo aparte de este proyecto.
- Costo de extraer una página de foto o PDF con ~50 líneas (~3.000 tokens entrada, ~1.500 salida), **estimación propia**: Haiku 5.5 ~$0,001; Flash-Lite ~$0,003; Gemini 3.6 Flash ~$0,008; Sonnet 5 ~$0,021. Lista de 5.000 productos (100 páginas): $0,10 a $2,10. Una API de OCR especializada a $0,08-0,16 por documento no compensa frente a un LLM con esquema, salvo que el piloto muestre lo contrario. Falta probar si Haiku lee bien fotos reales.
- Flujo sobre el stack actual: la Edge Function `whatsapp-webhook` (ver [CLAUDE.md](C:/Users/Javie/Documents/Work/Helios/CLAUDE.md)) identifica el número de la farmacia, guarda el archivo y encola; un trabajador externo extrae, porque el límite de 2 s de CPU y la falta de `sharp` impiden procesar imágenes o PDF grandes allí. Un Excel se analiza sin LLM, salvo el mapeo inicial de columnas.
- Validaciones que convierten una lectura dudosa en dato usable: coincidencia contra el catálogo, banda de precio (mediana del producto ±50% inicialmente), moneda deducida por magnitud y encabezado, número de líneas leídas frente a visibles.
- Cierre con la farmacia: «Recibí 1.240 productos; 37 no los reconozco; precios en dólares BCV, ¿correcto?». Esa confirmación convierte un error de OCR en un error atribuible a la fuente.
- Retención: un recordatorio semanal de utilidad para 100 farmacias cuesta ~$5/mes (430 × $0,0113). Debe aceptar «Sí, sigue igual» y actualizaciones parciales; pedir la lista completa cada semana es lo que mata la adopción (hipótesis, medir). Una plantilla de recordatorio puede ser clasificada como marketing, lo que multiplica el costo por 6,5.
- Revisión humana: al inicio 10-25% de líneas nuevas necesitan mirada (estimación propia); baja rápido porque cada alias confirmado no vuelve a consultarse.

### Gaps
- No hallé una prueba controlada de modelos actuales leyendo listas de precios en español fotografiadas con móvil. Es lo primero a medir en un piloto con 50-100 páginas reales.
- No encontré tasas de adopción o abandono de farmacias que envían listas periódicas.
- No confirmé el recargo de 360dialog sobre Meta ni la tarifa de mensajes de servicio por encima de los 1.000 gratuitos. Falta la tarifa oficial de Meta (CSV).

## Cotización en vivo: el sistema pregunta a varias farmacias por WhatsApp

### Takeaway
Encaja con Venezuela porque no exige catálogo completo ni sistemas en la farmacia y da precio y disponibilidad del momento. Cuesta unos seis centavos por récipe. Su límite es humano: la tasa y velocidad de respuesta, que nadie ha documentado para este canal y que hay que medir. No hallé ningún caso publicado que opere exactamente así solo por WhatsApp.

### Cited Findings
- Existe una patente de «subasta inversa» de recetas no surtidas: un registro de farmacias precalificadas puja por precio o servicios y el cliente elige — [US 8346571](https://patents.justia.com/patent/8346571).
- PriceMyPills presenta un modelo de farmacias miembro que ofrecen su mejor precio — [App Store](https://apps.apple.com/us/app/pricemypills/id1477435731). Un proveedor describe una función de puja en un caso de desarrollo — [Technostacks](https://technostacks.com/?p=5700). No verifiqué uso real ni vigencia.
- En Chile, los socios de Yapp cotizan las recetas que reciben sus pacientes e indican dónde comprar más barato — [Forbes Chile](https://forbes.cl/negocios/2022-10-24/mauricio-ferrari-cofundador-de-yapp-el-romantico-dice-quiero-cambiar-el-sistema-de-salud-chileno-yo-digo-que-se-puede-ahorrar/). Búho usa un algoritmo que arma la cotización óptima repartida entre farmacias — [Diario Financiero](https://www.df.cl/df-lab/innovacion-y-startups/buho-la-startup-que-creo-una-plataforma-que-optimiza-la-compra-y). Comparan datos con algoritmo; no consta que las farmacias respondan a mano.
- En India, modelos de receta por WhatsApp son farmacias directas, no subastas: Digi-Prex — [Yahoo/TechCrunch](https://news.yahoo.com/m/758f5864-9c69-319d-90d6-11e4e3ad711e/an-indian-startup-that-uses.html); LokamHealth — [F4](https://f4.fund/startups/lokamhealth).
- Diferencias de precio que justifican comparar: hasta 30% entre farmacias grandes y pequeñas según Yapp — [Forbes Chile](https://forbes.cl/negocios/2022-10-24/mauricio-ferrari-cofundador-de-yapp-el-romantico-dice-quiero-cambiar-el-sistema-de-salud-chileno-yo-digo-que-se-puede-ahorrar/); hasta 900% según la experiencia de los fundadores de Búho, que no es una medición — [Diario Financiero](https://www.df.cl/df-lab/innovacion-y-startups/buho-la-startup-que-creo-una-plataforma-que-optimiza-la-compra-y).

### Inferences
- Costo, **estimación propia**: 5 farmacias × $0,0113 = **$0,057 por récipe** si la plantilla pasa como utilidad, y $0,37 si como marketing. Las respuestas de la farmacia son gratis y analizarlas con Haiku cuesta menos de un centavo. A 1.000 récipes al mes: ~$60-70 de Meta frente a $1.000-3.100 con voz a 5 llamadas por récipe.
- Flujo propuesto: el récipe queda estructurado; el catálogo elige 5-8 farmacias cercanas por probabilidad de tener el producto; se envía una plantilla con botones por producto («Lo tengo», «No lo tengo»), más campo de precio; plazo de 10-15 min en horario; respuestas tardías se guardan como observación.
- No enviar datos del paciente: solo medicamentos, cantidades y zona.
- Efecto acumulativo: cada respuesta es una observación de precio y disponibilidad con alta confianza. La cotización alimenta el catálogo sin que nadie suba listas, sobre todo para los productos más pedidos. Esa es la razón principal para empezar por aquí.
- Riesgos: fatiga (una farmacia con 50 preguntas al día deja de contestar; limitar por farmacia y agrupar); horario y desconexión; precio-gancho (cotizar bajo y cobrar más: se detecta comparando contra la factura y se refleja en reputación); y respuestas ambiguas en texto libre.
- Umbrales a medir en piloto: al menos 40-50% de respuesta en menos de 15 min y 2-3 precios por récipe. Si no se alcanza, no hay producto. Son hipótesis mías.
- Incentivo: la farmacia recibe clientes con intención de compra. Cobrar comisión o exigir exclusividad al inicio rompe la adopción (juicio propio).

### Gaps
- Ninguna fuente documenta tasas de respuesta, tiempos ni fatiga de farmacias a cotizaciones por WhatsApp. Es el mayor desconocido técnico-operativo de todo el análisis.
- No verifiqué cómo clasificaría Meta esta plantilla ni reglas sobre mensajes iniciados a comercios.
- Si se puede cotizar por este canal un medicamento con récipe obligatorio corresponde al investigador legal.

## Crowdsourcing: fotos de facturas y tickets de pacientes

### Takeaway
Sirve como capa de validación y para productos muy comprados, no para arrancar. GasBuddy funciona con millones de reportes diarios sobre un producto casi único y un precio a la vista; una farmacia tiene miles de productos y compras poco frecuentes. Para Helios, conviene pedir la factura solo cuando el paciente ya usó el sistema.

### Cited Findings
- GasBuddy recibe 2-3 millones de reportes diarios en EE. UU. y Canadá, casi todo de usuarios. Usa puntos convertibles en boletos de rifa, exige estar geolocalizado cerca de la estación y a veces trabaja con las estaciones — [Harvard D3](https://d3.harvard.edu/platform-digit/submission/gasbuddy-a-platform-for-crowdsourced-gas-price-data/).
- Las cifras de precisión de GasBuddy que circulan (1,8% de margen, 49% en zonas rurales) vienen de sitios de baja calidad sin estudio rastreable: no usarlas — [ejemplo](https://www.shop.bottegadelsarto.com/feed/gas-price-comparison-tools-reliability-803044).
- Numbeo: más de 30 filtros automáticos y semiautomáticos; bloquea IP de spam, proxies públicos y Tor; da tres veces más peso a datos recogidos manualmente (dos veces al año); ventana típica de 12 meses, 3 en ciudades populares, hasta 18-24 con condiciones; con más de 153 contribuyentes en 3 meses archiva lo anterior — [Numbeo](https://www.numbeo.com/common/motivation_and_methodology.jsp).
- Costo de OCR de recibos especializado: $0,08 por recibo en Veryfi — [TrustRadius](https://trustradius.com/products/veryfi/reviews).

### Inferences
- **Densidad, estimación propia.** Una ciudad con 100 farmacias × 300 productos principales = 30.000 celdas. Para que el 30% tenga un dato de menos de 30 días hacen falta 9.000 observaciones distintas al mes; con 2,5 líneas por ticket y 1,5 de duplicación son ~5.400 tickets al mes (~180 al día). Con incentivo de $0,25, ~$1.350/mes solo en premios. Si la cadena tiene precio único, las celdas bajan mucho, pero justo ahí el scraping ya da el dato.
- Comparado con GasBuddy: producto homogéneo, precio en un letrero, compra semanal y sin dato sensible. Aquí el ticket revela una condición de salud, así que la privacidad reduce la participación y obliga a eliminar nombre y cédula antes de guardar.
- Antifraude mínimo: farmacia identificada por RIF; fecha reciente; hash perceptual y número de factura para duplicados; banda de precio; tope por usuario; geolocalización opcional; muestra revisada a mano; reputación por contribuyente. Que las facturas venezolanas traen RIF y correlativo es conocimiento general, no verificado aquí.
- Incentivos en dinero atraen fraude en un país con ingresos bajos (juicio propio); preferible un beneficio ligado a la siguiente compra.
- Una vez validado, el dato es muy valioso: es precio cobrado, no anunciado. Sirve para auditar otras fuentes aunque cubra poco.

### Gaps
- No encontré documentación técnica sobre Basket, Receipt Hog ni Premise (validación, incentivos, densidad). La búsqueda no devolvió fuentes útiles.
- No hay un umbral publicado de densidad mínima para que un comparador colaborativo sea útil. La cuenta anterior es mía.

## Equipos de campo y llamadas automatizadas o con IA de voz

### Takeaway
No son escalables como fuente principal pero son el mejor patrón de referencia: una muestra pequeña y constante mide si el resto de las fuentes dice la verdad. La voz con IA cuesta unas 20 a 55 veces más por consulta que WhatsApp y añade fricción; queda como respaldo.

### Cited Findings
- El estudio de Cavallo usó más de 300 trabajadores contratados por Mechanical Turk, Elance y UpWork, con una app para escanear códigos de barras, hasta 50 productos cada uno — [AEA](https://www.aeaweb.org/research/online-offline-price-differences). Buscaban UPC en vez de descripción para lograr coincidencia perfecta — [presentación de Cavallo](https://www.stat.go.jp/english/info/meetings/og2015/pdf/t1s2p8_pre.pdf).
- Numbeo pondera sus datos manuales por 3 frente a los de usuarios — [Numbeo](https://www.numbeo.com/common/motivation_and_methodology.jsp).
- **Voz con IA (sobre todo blogs de proveedores o competidores):** Vapi $0,05/min solo de plataforma, ~$0,13-0,31 todo incluido; Retell $0,07-0,31 con plataforma a $0,055; Bland $0,09/min, ~$0,09-0,14 todo incluido — [Morph](https://www.morphllm.com/comparisons/vapi-vs-retell-vs-bland-vs-synthflow); [Techsy](https://techsy.io/en/blog/retell-ai-vs-vapi-vs-bland); [Bland](https://www.bland.ai/blog/voice-ai-pricing-enterprise). Hay un ejemplo de 10.000 llamadas de 4 min a ~$2.800/mes en Retell — [Speechify](https://speechify.ai/blog/best-voice-agent-platforms-2026). Las cifras varían entre artículos.

### Inferences
- Voz, **estimación propia**: llamada de 2 min a $0,10-0,31/min = $0,20-0,62, frente a $0,0113 de una plantilla: 18 a 55 veces más, sin contar llegada a +58 (a veces cara) ni llamadas no contestadas.
- En una farmacia atendida por una o dos personas, una llamada automatizada interrumpe; el WhatsApp se contesta entre clientes. Una persona llamando desde Venezuela puede salir más barata que la IA de voz.
- Auditoría de campo: 50-200 observaciones semanales de productos muestreados al azar en farmacias al azar. Sirve para calcular el indicador central del sistema: **porcentaje de veces que el precio mostrado está dentro de ±3% del precio en mostrador**, por tipo de fuente. Sin esa medida, la «confianza» es una opinión.
- Costo de un capturador: $300-600/mes (estimación propia, sin fuente de salarios). Reutiliza la lógica de Cavallo: foto del anaquel y código de barras con app sencilla; también sirve para levantar GTIN del catálogo.

### Gaps
- No encontré tarifas de telefonía saliente a Venezuela en estas plataformas ni calidad con español venezolano.
- No hallé salarios documentados para capturadores en Venezuela.
- Consentimiento y grabación de llamadas: lo cubre el investigador legal.

## Aprovechar el flujo de transacciones propias

### Takeaway
Es la fuente más fiable y la más barata por dato, pero solo existe cuando ya hay volumen y solo ve lo que se compra. Su función inicial es auditar a las otras vías; a largo plazo es la ventaja difícil de copiar.

### Cited Findings
- El caso más fuerte: las señales de compradores de Instacart (millones de escaneos al día) alimentan su modelo, pero el catálogo es «cientos de veces» mayor que la base de señales, así que los productos poco frecuentes tienen pocas o ninguna. Los ítems frecuentes reciben señal en 10 horas (~1% de los ítems puntuados), los intermedios en un mes (~85%) — [Instacart Engineering](https://company.instacart.com/tech-innovation/how-instacart-modernized-the-prediction-of-real-time-availability-for-hundreds-of-millions-of-items-while-saving-costs).
- En EE. UU. el flujo de transacción es lo que sustenta el negocio: el PBM cobra a la farmacia por receta y comparte con GoodRx — [Drug Channels](https://www.drugchannels.net/2020/08/how-goodrx-profits-from-our-broken.html). Una fuente secundaria habla de 150.000 millones de puntos de datos de precio, sin verificar — [Substack](https://theinnovationcodex.substack.com/p/goodrx-the-frontdoor-to-healthcare).

### Inferences
- Tres niveles, de menos a más riqueza (estimación propia):
  1. **Pago por Helios en la farmacia:** farmacia, monto, fecha. Sin líneas, sirve para validar el total del récipe.
  2. **Foto de la factura al cerrar la compra:** líneas y precios, mismo extractor que WhatsApp.
  3. **Confirmación de la farmacia con botones:** «surtido completo» o «faltó X». Da disponibilidad, el dato más difícil.
- Sesgo: solo se observan las opciones elegidas, normalmente las más baratas o cercanas; hay que combinar con la muestra aleatoria de campo.
- Bucle: precio mostrado frente a pagado da exactitud por fuente, que recalibra la confianza, y por farmacia, que da reputación.
- Encaje con Helios: ya guarda libro con `idempotency_key` y reportes de pago ([CLAUDE.md](C:/Users/Javie/Documents/Work/Helios/CLAUDE.md)). Para este proyecto faltaría decidir si la compra en farmacia pasa por cuotas, cosa fuera de esta investigación.

### Gaps
- No hay cifras públicas de cuántas transacciones necesita un comparador de medicamentos para sostener precios por transacción sola.

## Modelos híbridos: combinación recomendada y orden

### Takeaway
La mejor combinación asigna una vía por segmento: cadenas por API o scraping, independientes por listas y cotización, productos más pedidos reforzados por transacciones, y una muestra de campo para medir. El orden importa: primero cotización y récipe digital, que no necesitan datos previos.

### Cited Findings
- Instacart usa tres capas con ventanas distintas (general 7-180 días, tendencia 0,5-30 días, tiempo real) y programa por importancia del producto, lo que reduce ~80% el costo de cómputo — [Instacart Engineering](https://company.instacart.com/tech-innovation/how-instacart-modernized-the-prediction-of-real-time-availability-for-hundreds-of-millions-of-items-while-saving-costs).
- Numbeo combina usuarios y recolección manual ponderada — [Numbeo](https://www.numbeo.com/common/motivation_and_methodology.jsp).
- GoodRx mezcla precios PBM con programas propios de farmacias y fabricantes — [GoodRx](https://www.goodrx.com/corporate/news/faqs-from-pharmacy-professionals).

### Inferences
Plan por fases, **estimación propia** (costos sin sueldos):

| Fase | Duración | Qué se construye | Criterio para seguir | Costo mensual |
|---|---|---|---|---|
| 0. Validar | 4-6 semanas | Catálogo de 200-300 moléculas; récipe estructurado en bot del médico; cotización por WhatsApp a 10-30 farmacias de una ciudad; tabla de observaciones | Respuesta 40-50% en <15 min; ahorro real comparado | $50-200 |
| 1. Sembrar | Meses 2-4 | Scrapers de 3-5 cadenas; listas por WhatsApp y portal; revisión de alias; precio mostrado con antigüedad | Exactitud en mostrador ≥85-90% en productos frecuentes | $200-800 |
| 2. Consolidar | Meses 5-12 | Factura al cierre; auditoría de campo; integración con 1-2 cadenas; modelo de disponibilidad simple | Cobertura ≥70% de líneas de récipe en la ciudad | $800-3.000, más 1-2 personas |
| 3. Automatizar | Año 2 | Conectores por sistema si hay concentración; incentivos a facturas; más ciudades | Costo por récipe atendido sostenible | Según volumen |

- Regla por segmento (estimación propia): cadena con web → scraping; cadena sin web o con ERP → acuerdo y exportación; independiente → WhatsApp; zona con pocas farmacias → cotización directa.
- Flujo para el paciente: el catálogo ordena, la cotización confirma. El sistema no le dice «tal precio» sino «las 3 mejores opciones vistas, ya confirmadas por 2 de ellas».
- Empezar por 200-300 moléculas de una sola ciudad: la cola larga es inútil en el arranque y esa concentración es lo que hace viable la revisión humana. Hay que contrastar la lista con recetas reales de los médicos en Helios.

### Gaps
- No hallé un postmortem público de un comparador de medicamentos en un país de alta inflación y baja digitalización. Otro investigador cubre casos internacionales.

## Identidad de producto: cómo emparejar «Losartán Potásico 50mg x 30 tab Calox»

### Takeaway
Se resuelve con un catálogo propio por niveles y una tubería escalonada: código de barras si existe, análisis estructurado, búsqueda de candidatos, LLM como juez y revisión humana para lo que no cuadre. Las tasas publicadas rondan 90-95% entre los 5 primeros candidatos, pero en el primero son bastante menores, por lo que en medicamentos nunca se debe aceptar sin comprobar concentración y forma con reglas.

### Cited Findings
- **Código de barras como llave:** Cavallo buscó por UPC en vez de descripción para lograr coincidencia perfecta — [presentación](https://www.stat.go.jp/english/info/meetings/og2015/pdf/t1s2p8_pre.pdf).
- **Medicamentos, LLM con RAG (Japón→RxNorm):** tasa de acierto entre 5 candidatos de 0,64 para BioBERT, 0,90 para GPT-3.5 y 0,94 para Mixtral 8x7b; R-precisión 0,23 / 0,43 / 0,50; MRR 0,51 frente a 0,67-0,77. Peor en inyectables por fallos de recuperación. Muestra pequeña e inconsistente (100 frente a 200), sin modelos más nuevos, solo nivel clínico y no marca — [Healthc Inform Res 2024](https://synapse.koreamed.org/articles/1516088909).
- **Sin LLM (2011):** emparejamiento aproximado a RxNorm con 67,9-84,8% en el primer candidato y 90-96% en los tres primeros — [PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC3243188).
- **Productos en general:** los mejores LLM necesitan cero o pocos ejemplos para igualar a modelos afinados con miles — [Peeters et al., EDBT 2025](https://arxiv.org/abs/2310.11244). Agregadores atribuyen a GPT-4 sin ejemplos un F1 de 89,61 en WDC Products (80% casos difíciles) y 95,78 en Abt-Buy; no lo verifiqué en las tablas del artículo — [Emergent Mind](https://www.emergentmind.com/papers/2310.11244).
- **Vocabularios:** ninguno, ni RxNorm, cubre todos los alias; las reglas subestiman coincidencias reales — [arXiv 2508.16571](https://arxiv.org/pdf/2508.16571). Comparación suiza de 2026 entre flujo léxico (USAGI) y LLM con resultados mixtos según vocabulario — [medRxiv](https://www.medrxiv.org/highwire/citation/1139351/medlars).
- **Afirmación de proveedor:** 99,2% de ingrediente correcto a gran escala, no revisado por pares — [Atropos Health](https://www.atroposhealth.com/?p=252884).
- **Marca frente a genérico:** LLM con 84-97% en pares de oncología, solo texto — [medRxiv](https://www.medrxiv.org/content/10.1101/2024.11.08.24316949.full.pdf).

### Inferences
Diseño, **estimación propia**:

- **Niveles del catálogo** (al estilo RxNorm):
  1. Ingrediente: DCI y código ATC; `losartán`, con sal como atributo.
  2. Producto clínico: ingrediente(s) + concentración + forma: `losartán 50 mg tableta`.
  3. Producto comercial: marca y laboratorio: `Calox`.
  4. Presentación: `x30`, con GTIN y registro sanitario cuando existan.
- **Tubería:**
  1. Normalizar: minúsculas, sin acentos, expandir abreviaturas (`tab`, `comp`, `cáps`, `amp`, `jbe`, `susp`).
  2. Análisis con regex más LLM a JSON: `{ingrediente:"losartán", sal:"potásico", fuerza:50, unidad:"mg", forma:"tableta", cantidad:30, laboratorio:"Calox"}`.
  3. Búsqueda exacta en la tabla de alias: lo ya confirmado no vuelve al LLM.
  4. GTIN si viene.
  5. Candidatos por ingrediente y fuerza, con `pg_trgm` y `pgvector` (extensiones de Postgres; no verificadas en este proyecto).
  6. LLM juez sobre los 5-20 mejores, con salida restringida a candidatos existentes, como en el estudio japonés (descartaba lo que no estuviera en la base).
  7. Aceptación automática solo si ingrediente, fuerza, unidad y forma coinciden por regla, no solo por opinión del modelo.
  8. El resto va a cola de revisión por farmacéutico.
- Casos que deben quedar como productos distintos: combinaciones (`losartán/hidroclorotiazida 50/12,5`), liberación prolongada (LP, XR, retard), `mg/5 ml` frente a `mg/ml`, sales que cambian la dosis, jarabe frente a suspensión.
- Error asimétrico: confundir 50 mg con 100 mg es un error clínico; no emparejar es solo una línea que falta. El umbral debe favorecer precisión. Meta: ≥99,5% de precisión en auto-aceptación, medida en conjunto de prueba de 500-1.000 pares etiquetados por un farmacéutico; aceptar 70-85% de automatización al inicio.
- Costos: analizar una línea con Haiku cuesta ~$0,0001. Con 50.000 cadenas distintas de alias, $5 en un solo pase. El gasto real es la revisión: 5.000 dudosas × 30 s = ~40 horas, una vez.
- Semilla del catálogo: nombres de la lista de 200-300 moléculas, con ATC, más lo observado en cadenas. RxNorm no incluye marcas venezolanas: sirve para ingredientes, no para productos.
- Comparar por tratamiento y no por caja: 30 tabletas frente a 28 o a 2×14. El récipe indica unidades; se compara precio total de cajas necesarias y precio por unidad.

### Gaps
- No encontré precisión publicada para medicamentos en español con marcas latinoamericanas, ni estudios en ese emparejamiento específico.
- Tampoco confirmé una base abierta y actual del INHRR con productos registrados y GTIN.

## Bioequivalencia y sustitución por genérico: qué se puede mostrar

### Takeaway
Con lo encontrado no se puede afirmar «bioequivalente» ni «intercambiable» para productos venezolanos porque no ubiqué una lista oficial vigente. Lo prudente es mostrar lo recetado primero y, aparte, «misma composición, misma concentración y forma», sin sustituir automáticamente y con la decisión en médico o farmacéutico.

### Cited Findings
- El INHRR es la autoridad reguladora y otorga el registro sanitario, previa evaluación de calidad, seguridad y eficacia — [OPS, documento sobre biotecnológicos](https://paho.org/sites/default/files/VEN-LA-REGULACION-DE-BIOTECNOLOGICOS-EN-VENEZUELA.pdf).
- La Ley de Medicamentos considera genéricos los medicamentos con la Denominación Común Internacional de la droga activa — [Ley de Medicamentos](https://venezuela.justia.com/federales/leyes/ley-de-medicamentos/gdoc).
- Un artículo de opinión de 2022 afirma que una resolución de 2019 (Gaceta 41.610) permitió importar medicamentos con Permiso Sanitario, sin Registro Sanitario obligatorio, hasta por un año, y que la equivalencia de un genérico se demuestra con estudios de bioequivalencia — [La Patilla](https://lapatilla.com/2022/08/24/abraham-sequeda-medicamentos-de-calidad-y-medicamentos-espurios/). Es opinión, sin confirmar en Gaceta.
- Un artículo de 2013 describe normas de receta por principio activo, sin confirmar vigencia — [La Patilla](https://lapatilla.com/2013/04/05/rigoberto-marcano-las-nuevas-normas-para-los-recipes-medicos-otra-tarjeta-de-racionamiento/).

### Inferences
Propuesta por capas (estimación propia, a validar con farmacéutico y abogado):
- **Si el médico recetó por marca:** primero esa marca. Debajo, «Mismo principio activo, concentración y forma: otras opciones», con la leyenda de consultar antes de cambiar.
- **Si recetó por DCI:** comparar todas las marcas de ese producto clínico, ya sin jerarquía.
- **Nunca mezclar:** sales distintas si afectan dosis, liberación modificada frente a inmediata, formas distintas.
- **Exclusiones:** una lista negra de medicamentos de estrecho margen terapéutico (candidatos habituales: levotiroxina, warfarina, antiepilépticos) sin mostrar alternativas por precio. La lista debe definirla un farmacéutico; aquí no se verificó.
- **Campo en el catálogo:** `sustitucion_permitida` y `fuente_equivalencia`, con valor `desconocida` por defecto. El sistema afirma equivalencia solo si hay fuente.
- Los productos con permiso de importación pueden carecer de registro: guardar `registro_tipo` y mostrar el dato si el regulador lo exige.

### Gaps
- No encontré una lista oficial vigente de productos intercambiables o con bioequivalencia demostrada en Venezuela. Un documento antiguo de OPS/OMS, no ubicado con certeza, menciona listas de competidores bajo DCI. Revisar Gaceta e INHRR.
- Normativa vigente sobre receta por DCI y sustitución en farmacia: lo cubre el investigador legal.

## Interpretar el récipe: manuscrito con OCR o visión frente a receta digital estructurada

### Takeaway
La receta digital es la solución: Helios ya tiene al médico en panel y bot, así que elegir del catálogo evita casi todo el problema. La foto manuscrita debe tratarse como ayuda, siempre con confirmación humana: los resultados publicados varían de 5-8% de F1 sin ajuste a 80-91% en sistemas entrenados, y no hallé una prueba rigurosa con los modelos actuales.

### Cited Findings
- **MIRAGE (India):** 743.118 registros manuscritos simulados de 1.133 médicos, prueba con 15.000. Sin ajuste, F1 de **5,53% en Gemini 1.5 Pro** y **7,57% en GPT-4o**, contando error si falla nombre o dosis; afinado, LLaVA 79,8% e Idefics2 82%. No menciona corrección contra base de medicamentos, y los modelos ya son antiguos — [arXiv](https://arxiv.org/html/2410.09729v2).
- **Vietnam:** GPT-3.5 con 90,2% en impresas y solo 25,7% en 11 manuscritas — [HCMIU](https://keep.hcmiu.edu.vn/handle/123456789/6544).
- **Modelos especializados:** RxVLM con 91,43% en un conjunto curado — [Springer](https://link.springer.com/article/10.1007/s00371-026-04420-2); Mask R-CNN + TrOCR con 1,4% de error por carácter en datos propios de Pakistán — [arXiv](https://arxiv.org/html/2412.18199); CRNN con 95% en entradas cortas — [ResearchGate](https://www.researchgate.net/publication/336419684_Medical_Handwritten_Prescription_Recognition_Using_CRNN).
- **Pruebas débiles:** GPT-4o leyó perfecto una sola receta simulada — [CodeSota](https://codesota.com/ocr/best-for-handwriting). En 5.578 imágenes de palabras, PP-OCRv5 y GLM-OCR superaron 20% de coincidencia exacta — [DEV](https://dev.to/kaniel_outis/how-well-can-ocr-read-doctor-handwriting-in-2026-54hn).
- **Receta digital por WhatsApp ya existe:** en Chile, Recemed emite recetas electrónicas por ese canal — [Radio Agricultura](https://www.radioagricultura.cl/tendencias/recetas-medicas-electronicas-disponibles-por-whatsapp_20250911/). Yapp se alió con Recemed para reemplazar papel — [Forbes Chile](https://forbes.cl/negocios/2022-10-24/mauricio-ferrari-cofundador-de-yapp-el-romantico-dice-quiero-cambiar-el-sistema-de-salud-chileno-yo-digo-que-se-puede-ahorrar/).

### Inferences
- **Vía principal:** el médico escribe el récipe en panel o bot; selección con autocompletado del catálogo (`losar…` → `Losartán 50 mg tableta`); dosis, duración, cantidad. Queda estructurado, firmado, con identificador y costo cero de OCR. El incentivo para el médico tendrá que ser rapidez, porque añade fricción frente a un papel.
- **Vía secundaria (foto):** el modelo lee, pero la salida debe restringirse al vocabulario del catálogo: MIRAGE no lo hace, y un vocabulario cerrado debería mejorar los resultados. Se le muestra al paciente lo interpretado («Leí: Losartán 50 mg. ¿Correcto?»). Si la confianza es baja o hay medicamentos parecidos, pasa a un farmacéutico.
- **Regla de seguridad:** un error de lectura no puede quedar en silencio. Dos medicamentos con nombres parecidos pueden tener efectos muy distintos. En el peor caso, el sistema da un precio de otro producto; la farmacia es la última barrera.
- Costo de leer una foto: ~$0,001-0,02. El costo relevante es la revisión humana, unos 30-60 s por récipe dudoso.
- Medir con 200-300 récipes venezolanos reales etiquetados (con consentimiento) antes de decidir el diseño: las cifras indias y vietnamitas no se trasladan a la letra local.

### Gaps
- **No encontré ningún estudio revisado por pares que evalúe GPT, Gemini o Claude actuales en recetas manuscritas reales.** Tampoco ninguno en español ni en Venezuela. Los resultados bajos de MIRAGE son con modelos de 2024 y probablemente subestiman los de hoy, pero no puedo decir cuánto.
- Sin datos sobre qué fracción de médicos venezolanos adoptaría récipe digital.

## Frescura, disponibilidad por sucursal y moneda

### Takeaway
Hay que separar dos usos: para ordenar farmacias sirve un dato de días o semanas si está indexado a dólar o euro BCV; para prometer un precio o decir «lo tienen», hace falta confirmación de horas. La disponibilidad debe tratarse como probabilidad por sede. El precio se guarda en su moneda original con su modo de fijación, y la comparación se hace siempre en bolívares de hoy.

### Cited Findings
- La fuerza de una señal se desvanece con el tiempo, y por eso Instacart limita el modelo de tiempo real a ítems con señales recientes; distingue productos frecuentes de la cola — [Instacart Engineering](https://company.instacart.com/tech-innovation/how-instacart-modernized-the-prediction-of-real-time-availability-for-hundreds-of-millions-of-items-while-saving-costs).
- Numbeo admite datos viejos solo si indicadores de inflación sugieren estabilidad — [Numbeo](https://www.numbeo.com/common/motivation_and_methodology.jsp).
- Tasa BCV: Bs 482,7586 el 22-04-2026 — [Finanzas Digital](https://finanzasdigital.com/tasa-de-cambio-bcv-22-abril-2026/). Bs 814,69 por dólar y Bs 947,29 por euro el 08-09-2026; Binance P2P Bs 968,05, ~18,8% sobre lo oficial — [El Caribe](https://www.elcaribe.com.do/panorama/dolar-venezuela-hoy-8-septiembre-2026-bcv-binance/). Son datos de hace dos meses.
- Helios ya tiene series `BCV` y `BCV_EUR` en `exchange_rates` y reglas de precisión: USD `numeric(18,4)`, VES `numeric(18,2)`, tasa `numeric(18,6)`; zona `America/Caracas` — [CLAUDE.md](C:/Users/Javie/Documents/Work/Helios/CLAUDE.md).

### Inferences
- **Deriva, cálculo propio:** de abril a septiembre de 2026 el dólar BCV subió 68,8% en 139 días, ~0,38% diario: ~2,7% por semana y ~12% en 30 días. Un precio en bolívares fijos de hace un mes puede estar 12% corto solo por tasa. Por eso un precio en Bs sin modo de fijación caduca en días.
- **Un mismo «10» no es lo mismo:** con las tasas del 8 de septiembre, $10 a BCV son Bs 8.146,90 y €10 a BCV euro son Bs 9.472,90, 16,3% más. Una lista que dice «ref. 10» sin aclarar tasa puede mover la clasificación más que la diferencia real entre farmacias. Conviene preguntar la tasa al recibir cada lista.
- **Modo de fijación a guardar:** `fijo_ves`, `indexado_bcv`, `indexado_bcv_eur`, `desconocido`. Para indexados, Bs de hoy = monto × tasa de hoy. Para `fijo_ves`, hay que marcar antigüedad; se puede estimar el precio actual, pero mostrarlo como estimación.
- **Tiempos de vida propuestos (estimación propia, a calibrar):**

| Fuente | Vida media del precio (indexado / Bs fijos) | Vida media de disponibilidad |
|---|---|---|
| Compra propia o factura validada | 21 d / 7 d | 2 d |
| Cotización respondida | 7 d / 3 d | 1 d |
| Conector POS | 14 d / 3 d | 1 d |
| Scraping de cadena | 7 d / 3 d | 1 d si es por sede; de lo contrario sin dato |
| Lista por WhatsApp o portal | 14 d / 5 d | Sin dato |
| Campo o llamada | 14 d / 5 d | 1 d |

- **Reglas de presentación:** menos de 48 h, «confirmado»; hasta 14 días indexado, «visto hace X días», con botón de confirmar; más antiguo, solo para ordenar la lista de a quién preguntar, nunca como precio. Mostrar siempre la fecha y fuente, de forma honesta y simple.
- **Sede:** el stock vale por sede. Si el dato es por cadena (`scope = 'cadena'`), decir «precio de la cadena, confirma existencia en la sede». Muchos precios de cadena son únicos pero la existencia no lo es, cosa a verificar por cadena.
- **Disponibilidad simple para empezar:** una probabilidad a partir de la última señal por sede, con decaimiento, más una tasa histórica por producto y zona. No hace falta un modelo de ML hasta tener señales suficientes; Instacart mismo parte de una línea base estadística y usa XGBoost para los desvíos.
- **Inflación y comparación:** como todas las farmacias derivan a la vez, el error relativo pesa menos que el absoluto. Ordenar con datos semanales indexados debería funcionar; prometer no. Es una hipótesis razonable a medir con datos reales.
- **Canasta completa:** el récipe se compara como total, incluyendo la opción de comprar todo en una o repartir entre dos (Búho reparte entre farmacias en una sola entrega); ir a dos farmacias en Venezuela tiene costo real de transporte, lo que debe pesar.

### Gaps
- No encontré fuentes sobre cómo marcan precios hoy las farmacias venezolanas (BCV, euro, paralelo). La búsqueda solo trajo tasas de cambio. El investigador de farmacias debería confirmarlo.
- No hay datos de la vida real del precio ni del stock en farmacias venezolanas; los valores propuestos deben calibrarse.
- La tasa de noviembre de 2026 no se verificó; las cuentas usan la de septiembre.

## Modelo de datos y arquitectura mínima viable sobre Supabase, TanStack Start, Vercel y 360dialog

### Takeaway
Basta con un catálogo por niveles, una tabla de alias y una tabla de observaciones de solo adición con fuente, marca de tiempo y confianza; el «precio actual» es una proyección. Todo cabe en Postgres. Los scrapers y el procesamiento pesado van en un trabajador externo, y Supabase queda para datos, webhooks y RPC.

### Cited Findings
- Edge Functions: 256 MB, 2 s de CPU por petición, 150 o 400 s de vida; sin librerías multihilo como `sharp` — [Supabase Limits](https://supabase.com/docs/guides/functions/limits).
- Reglas del repo: libro de solo adición, `idempotency_key` en mutaciones de dinero, RLS más RPC `security definer` con `set search_path`, nombres de dominio en inglés y código y comentarios en español, Edge Function `whatsapp-webhook` desplegada aparte, y el único proyecto Supabase **es producción** — [CLAUDE.md](C:/Users/Javie/Documents/Work/Helios/CLAUDE.md).
- Instacart calcula puntajes por adelantado y los guarda, con actualización bajo demanda cuando exceden la edad permitida — [Instacart, arquitectura](https://company.instacart.com/tech-innovation/instacarts-item-availability-architecture-solving-for-scale-and-consistency). Un resumen secundario añade que llamar al modelo durante la búsqueda habría sido demasiado lento — [Byte-Sized Design](https://bytesizeddesign.substack.com/p/how-instacart-scales-real-time-inventory).

### Inferences
Diseño propuesto, **estimación propia**, no implementado:

Entradas, todas terminan en la misma tubería:

- Webs de cadenas: trabajador externo (VPS o GitHub Actions).
- Listas y facturas por WhatsApp: `whatsapp-webhook` guarda el archivo y encola; un extractor LLM externo procesa.
- Excel o CSV del portal: Storage y cola.
- Respuestas de cotización: `whatsapp-webhook` y un analizador de texto corto.

Tubería común: resolver identidad (alias y revisión), escribir en `price_observations`, proyectar a `price_current`, servir por RPC al panel, al bot y al paciente. El precio pagado vuelve como observación y mide la exactitud de lo mostrado.

```sql
-- Catálogo canónico por niveles
create table drug_ingredients (id uuid primary key, dci text not null unique, atc_code text);

create table drug_clinical_products (          -- "losartán 50 mg tableta"
  id uuid primary key,
  label text not null,
  strength_num numeric, strength_unit text,
  dose_form text not null, release_type text default 'inmediata',
  substitution_status text not null default 'desconocida',  -- permitida | no_mostrar | desconocida
  equivalence_source text
);
create table drug_clinical_ingredients (clinical_id uuid, ingredient_id uuid, salt text, primary key (clinical_id, ingredient_id));

create table drug_products (                   -- marca, laboratorio y presentación
  id uuid primary key,
  clinical_id uuid not null references drug_clinical_products,
  brand text, lab text, pack_qty numeric, pack_unit text,
  gtin text unique, registration_type text, registration_code text
);

-- Lo que dice cada fuente, normalizado; evita pagar dos veces al LLM
create table drug_aliases (
  raw_norm text primary key,
  product_id uuid references drug_products,
  parsed jsonb,
  match_method text not null,                  -- gtin | regla | llm | humano
  match_confidence numeric(4,3) not null,
  reviewed_by uuid, reviewed_at timestamptz
);

create table pharmacies (id uuid primary key, name text not null, rif text, chain text);
create table pharmacy_branches (
  id uuid primary key, pharmacy_id uuid references pharmacies,
  state text, municipality text, lat numeric(9,6), lng numeric(9,6),
  whatsapp text, opening_hours jsonb, is_24h boolean default false
);

-- Observaciones: solo adición
create table price_observations (
  id bigint generated always as identity primary key,
  idempotency_key text not null unique,        -- hash de fuente + documento + línea
  product_id uuid references drug_products,    -- nulo mientras se revisa
  raw_text text not null,
  pharmacy_id uuid not null references pharmacies,
  branch_id uuid references pharmacy_branches, -- nulo si scope = 'cadena'
  scope text not null,                         -- sede | cadena
  source_kind text not null,                   -- scrape_api | scrape_html | conector | archivo | whatsapp_lista | cotizacion | factura | campo | voz | compra_propia
  source_ref text,                             -- URL, media_id de WhatsApp, id de archivo
  observed_at timestamptz not null,            -- cuándo era cierto
  captured_at timestamptz not null default now(),
  amount numeric(18,4),
  currency text not null,                      -- VES | USD | EUR
  pricing_mode text not null default 'desconocido', -- fijo_ves | indexado_bcv | indexado_bcv_eur | desconocido
  rate_series text, rate_value numeric(18,6),  -- de exchange_rates, a la fecha de observed_at
  amount_usd numeric(18,4),
  in_stock boolean, stock_qty numeric,
  source_confidence numeric(4,3) not null,
  match_confidence numeric(4,3) not null,
  evidence_path text                           -- Storage; sin datos personales
);
create index on price_observations (product_id, pharmacy_id, observed_at desc);

-- Proyección para leer rápido: una fila por producto y alcance
create table price_current (
  product_id uuid, pharmacy_id uuid, branch_id uuid,
  amount numeric(18,4), currency text, pricing_mode text,
  in_stock_prob numeric(4,3), price_confidence numeric(4,3),
  observed_at timestamptz, source_kind text, last_seen_at timestamptz,
  observation_id bigint references price_observations,
  unique nulls not distinct (product_id, pharmacy_id, branch_id)
);

-- Cotización en vivo
create table rfq_requests (id uuid primary key, prescription_id uuid, created_at timestamptz default now(), deadline_at timestamptz);
create table rfq_recipients (rfq_id uuid, branch_id uuid, sent_at timestamptz, wa_message_id text, responded_at timestamptz, primary key (rfq_id, branch_id));
-- cada línea respondida se guarda como price_observations con source_kind = 'cotizacion'
```

- **Confianza propuesta:** `confianza = fiabilidad_fuente × confianza_identidad × 0,5^(edad / vida_media_fuente)`. La fiabilidad inicial es supuesto, por ejemplo factura 0,98, cotización 0,95, POS 0,95, lista 0,85, scraping 0,80, y se recalibra con el indicador de precio mostrado frente a precio pagado. Con menos de 0,4 no se muestra como precio.
- **Evitar crecimiento innecesario:** si lo observado es igual a lo anterior, solo se actualiza `last_seen_at` en `price_current` y se inserta observación únicamente en cambios o una vez a la semana. A 25.000 productos diarios son 750.000 filas al mes sin esta medida; con ella, quizá 5-10% de eso. Particionar por mes solo cuando pase de decenas de millones.
- **Consulta del paciente:** RPC `helios_prescription_options(prescription_id, lat, lng)` que convierte a Bs de hoy con `exchange_rates`, calcula cajas necesarias y total, y devuelve el orden. Privacidad: el récipe es dato sensible, se separa con RLS y nunca se copia a observaciones.
- **Dónde corre cada cosa:**
  - Vercel y TanStack Start: panel y vista de opciones.
  - Supabase: Postgres, RPC, Storage de evidencias, `whatsapp-webhook` que solo identifica y encola.
  - Trabajador externo: scrapers, extracción, resolución. $5-40/mes en VPS al inicio; Firecrawl o similar solo si un sitio lo exige.
  - Cron para refrescar, marcar datos viejos y detectar rupturas de scrapers.
- **Producción:** como el único proyecto Supabase es producción, hay que aislar este dominio en esquema propio o, mejor, en un proyecto aparte, para que los scrapers y su volumen no afecten al flujo de pagos. Las suites que tocan el envío de WhatsApp deben usar dobles, porque un `rollback` no deshace mensajes.
- **Observabilidad mínima:** por fuente, filas por día, tasa de nulos, antigüedad mediana, porcentaje de líneas de récipe con precio de menos de 14 días, tasa de respuesta a cotización, exactitud en mostrador, cola de alias pendientes.
- **Costo total del arranque:** $50-200/mes sin personal (fase 0 de la tabla híbrida). Lo que consume es tiempo: construir el catálogo de 200-300 moléculas y conseguir las primeras 10-30 farmacias.

### Gaps
- No verifiqué en esta sesión la disponibilidad de `pgvector`, `pg_trgm`, `pg_cron` o colas en este proyecto; son extensiones comunes de Postgres en Supabase. Confirmar antes de implementar.
- El ejemplo SQL es ilustrativo: no se ha probado ni se debe aplicar sin revisión, y la sintaxis `unique nulls not distinct` requiere PostgreSQL 15 o superior.
- No consulté los blogs de ingeniería de Rappi, Skyscanner, Trivago, Idealo ni PriceRunner sugeridos en el encargo, por límite de alcance: de sistemas de precios solo se leyó Instacart. No hay cifras de ellos en estas notas.
