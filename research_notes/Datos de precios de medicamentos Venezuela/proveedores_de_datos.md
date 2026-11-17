# Proveedores y fuentes de datos de medicamentos y precios para Venezuela

Revisado el 2026-11-04. Solo lectura de páginas públicas: sin cuentas, sin formularios, sin contactar a nadie.

**Conclusión general:** no encontré ningún proveedor que venda «precio por farmacia» para Venezuela. Las auditorías internacionales miden el mercado para los laboratorios; los catálogos no traen precios; el scraping es barato, pero solo llega a quien publica su catálogo. El hallazgo más útil es gratuito: el INHRR publica su registro sanitario con 22.794 productos en una página pública.

**Cómo leer las evidencias:**
- **[V]**: leí la página o el PDF directamente.
- **[E]**: lo vi solo en el extracto del buscador, porque la página no abrió o no la abrí. Hay que confirmarlo antes de citarlo como hecho firme.

## Proveedores de inteligencia farmacéutica: ¿cubren Venezuela, con qué detalle y a qué costo?

### Takeaway
Close-Up tiene un producto de auditoría de prescripciones para Venezuela, y hay indicios de que IQVIA también mide el mercado. Ninguno de los proveedores revisados ofrece precios al público por farmacia. Casi ninguno publica precios; la excepción son los informes de país, de unos $2.000.

### Cited Findings

| Proveedor | Qué ofrece | ¿Cubre Venezuela? | Cómo cobra | ¿Resuelve «precio por farmacia»? |
|---|---|---|---|---|
| **Close-Up International** | Auditoría de prescripciones y ventas; CRM y consultoría para laboratorios | **Sí, en prescripciones.** «Close-Up: Retail Pharma (Market Prescription Data National Level for Drugs) (Venezuela)» es el único perfil que figura para el país — [Bridge to Data, lista del 26-ago-2026](https://www.bridgetodata.org/sites/default/files/2026-08/List%20of%20DBs%20by%20country_26Aug2026.pdf) [V] | No público; su [sitio](https://www.close-upinternational.com/) no da precios [V] | No. Mide prescripciones, no precios de góndola |
| **IQVIA** (MIDAS y auditorías nacionales) | Medición de mercado armonizada | **Probable, sin confirmar.** Una publicación de un empleado de «IQVIA Ecuador & Venezuela» da 408 millones de unidades y $2.059 millones en año móvil a junio de 2026 — [LinkedIn](https://ec.linkedin.com/in/leoherdoizach) [E]. `iqvia.com/locations/venezuela` dio 404 [V] | No público — [G2](https://www.g2.com/products/iqvia/pricing) [E] | No. MIDAS usa precio de lista o factura promedio por presentación — [CMAJ](https://cmaj.ca/highwire/filestream/150811/field_highwire_adjunct_files/1/231485-res-2-at.pdf) [E] |
| **GlobalData (informe de país)** | Informe «Venezuela Healthcare» de 2022 | Sí, agregado | **$1.995** un usuario, **$2.992** varios, **$3.990** empresa — [GlobalData](https://www.globaldata.com/store/report/venezuela-healthcare-regulatory-and-reimbursement-market-analysis/) [V] | No |
| **GlobalData POLI** | Precios por presentación en 81 mercados: fabricante, mayorista y minorista, con serie mensual | No confirmado; no publica la lista de mercados | Contacto de ventas; la página muestra £1.000 sin aclarar qué incluye — [GlobalData](https://www.globaldata.com/product/pharma-pharmaceutical-prices-poli-drug-pricing-health-technology-assessment-hta-database/) [V] | No. Da un precio por presentación y país, no por farmacia |
| **Global Pricing Innovations** | Precios de lista y netos visibles en más de 90 mercados | No confirmado — [Datarade](https://datarade.ai/data-providers/global-pricing-innovations-limited/profile) [E] | No público | No |
| **Kairos** | Vademécum de precios; el más consultado en Argentina — [Dinavisa](https://dinavisa.gov.py/wp-content/uploads/2025/06/GUIA_DINAVISA_PARA_BUSQUEDA_DE_PRECIOS_REFERENCIALES.pdf) [E] | No confirmado. `kairosweb.com` tiene el certificado vencido y `ar.kairosweb.com` respondió 403 [V] | No hallado | No. Es un precio de referencia por producto |
| **Alfabeta** | Manual Farmacéutico, precios, vademécum y software WinFarma | Sin mención de Venezuela; su enfoque parece argentino (ANMAT) — [Alfabeta](http://www.alfabeta.net/home/) [V] | Sin precios; atiende por correo | No |

**Cómo mide Close-Up:**
- Usa un panel de farmacias, cadenas o independientes, definido con un modelo estadístico. La muestra cubre el 20–25% de las prescripciones de cada país latinoamericano y alrededor del 90% de los médicos — [Bridge to Data](https://www.bridgetodata.org/node/107435) [V].
- Declara datos de mercado en más de 20 países y tecnología en más de 50, sin publicar la lista — [Close-Up](https://www.close-upinternational.com/) [V].
- Su producto territorial se alimenta de un panel de mayoristas y farmacias — [Bridge to Data](https://www.bridgetodata.org/node/107533) [E]. No aparece un perfil territorial para Venezuela — [lista](https://www.bridgetodata.org/sites/default/files/2026-08/List%20of%20DBs%20by%20country_26Aug2026.pdf) [V], aunque el directorio podría no recoger todos sus productos.

**Datos públicos del mercado venezolano (solo agregados):**
- Faro Farmacéutico, de la Unidad de Inteligencia de Negocios de Grupo LETI: 285,92 millones de unidades entre enero y agosto de 2026 (+12,35%) — [Bloomberg Línea](https://www.bloomberglinea.com/latinoamerica/venezuela/mercado-farmaceutico-venezolano-crece-1235-hasta-agosto-y-supera-los-285-millones-de-unidades/) [V]. No dice de dónde salen los datos — [El Diario](https://eldiario.com/2026/09/02/crecimiento-mercado-farmaceutico-venezuela/) [V].
- Cifar: 28,03 millones de unidades en marzo de 2025 y un precio promedio acumulado de $4,38 — [El Diario](https://eldiario.com/2025/05/03/mercado-farmaceutico-venezuela-crecio-marzo-2025/) [V].
- **Las fuentes no coinciden en el precio promedio:**
  - $3,50, según Faro en [El Diario](https://eldiario.com/2026/09/02/crecimiento-mercado-farmaceutico-venezuela/) [V].
  - $5,23, según Faro en [Bloomberg Línea](https://www.bloomberglinea.com/latinoamerica/venezuela/mercado-farmaceutico-venezolano-crece-1235-hasta-agosto-y-supera-los-285-millones-de-unidades/) [V].
  - $5,57 en febrero de 2026 — [El Diario](https://eldiario.com/2026/03/27/mercado-farmaceutico-venezolano-registro-crecimiento-primer-bimestre-2026/) [E].

**Dato dudoso:** GlobalData cifra el mercado farmacéutico de 2021 en $115.100 millones — [GlobalData](https://www.globaldata.com/store/report/venezuela-healthcare-regulatory-and-reimbursement-market-analysis/) [V]. Es más de 50 veces los $2.059 millones atribuidos a IQVIA.

**Único precio público de IQVIA que hallé:** £70.000 al año por Trial Manager, un software de ensayos clínicos — [G-Cloud UK](https://assets.applytosupply.digitalmarketplace.service.gov.uk/g-cloud-15/documents/717210/251933528185866-pricing-document-2026-01-28-1617.pdf) [E]. Es otro producto y no sirve para estimar MIDAS.

### Inferences
- Estos productos están pensados para que los laboratorios midan su cuota y su fuerza de ventas. Para este sistema servirían, como mucho, para priorizar qué medicamentos cubrir primero, y eso no justifica comprarlos ahora.
- Close-Up ya obtiene datos de un panel de farmacias venezolanas. Es la prueba más clara de que hay farmacias que comparten datos, pero nada indica que venda el detalle por farmacia a terceros.
- $2.059 millones entre 408 millones de unidades dan unos $5,05 por unidad, coherente con los $5,23 de Faro. Por eso tomo como referencia el rango de $5 y trato los $3,50 como atípicos.
- La cifra de $115.100 millones parece un error, así que no conviene citar ese informe sin revisarlo.

### Gaps
- **PharmaSeek y Mediscan:** no encontré ninguna empresa con esos nombres en este sector. Pueden estar mal escritos; Medi-Span, por ejemplo, es un nombre parecido, aunque no lo verifiqué.
- **Clarivate (Cortellis) y NAVLIN:** la búsqueda no devolvió nada sobre Venezuela.
- **Costo de IQVIA y Close-Up:** no hallé una fuente, así que no doy orden de magnitud.
- **Cobertura de Kairos en Venezuela:** queda sin resolver, porque su sitio no abrió.

## Catálogos y maestros de medicamentos: ¿sirven para identificar lo que se vende en Venezuela?

### Takeaway
El registro del INHRR sí está publicado y es la mejor base para el diccionario venezolano, aunque no tiene botón de descarga ni trae códigos ATC, códigos de barras o precios. Las bases internacionales complementan, pero no sustituyen: ninguna confirmó cobertura de marcas venezolanas.

### Cited Findings

**INHRR, SISMED: [Productos farmacéuticos registrados, vigentes y cancelados](https://inhrr.gob.ve/sismed/productos-farma) [V, en navegador]**
- **Tamaño:** la página indica «Productos encontrados: 22794», incluidos los vencidos; por ejemplo, un registro de 1979 aparece como «Vencido (18/10/1986)».
- **Campos visibles:** número de registro (E.F., E.F.G., P.B.), fecha de aprobación, estado y fecha de vigencia, nombre con concentración y forma, representante y su RIF, farmacéutico patrocinante, fabricante y principio activo.
- **Documentos:** cada producto enlaza certificados en PDF de registro, condiciones de comercialización y renovación.
- **Acceso:** no vi botón de exportar, solo «Cargar Más Productos». La página carga los datos en JSON con `POST /sismed/api/productos-farma`. No encontré documentación de esa API ni términos de uso.
- **Calidad:** hay filas con principio activo o fabricante vacíos. No aparecen ATC, GTIN ni precio.
- **Otras secciones:** en proceso de registro, solicitudes rechazadas, fichas farmacológicas, medicamentos de servicio y lotes — [INHRR](https://inhrr.gob.ve/?page_id=3606) [V]. El [buscador antiguo](https://inhrr.gob.ve/fichasfarma/formweb/buscar_enregistro.php) de productos en proceso muestra fechas solo hasta septiembre de 2023 en lo que vi [V].

**Otras fuentes:**

| Fuente | Qué ofrece | Licencia y costo | ¿Sirve para Venezuela? |
|---|---|---|---|
| **Vademecum (Vidal Vademecum)** | Monografías y API clínica (producto sanitario clase IIb) | Sin precio público; «Solicitar especificaciones» — [Vademecum](https://www.vademecum.es/) [V] | **Dudoso.** El buscador indexa páginas `vademecum.es/venezuela/ve/...` con productos, pero las que probé dieron 404 y la portada no menciona Venezuela [V]. La lista de países de un producto tampoco la incluye — [Wolters Kluwer](https://www.wolterskluwer.com/en/solutions/ovid/vidal-vademecum-consult-15465) [E] |
| **PLM** | Información de medicamentos en web y apps; app gratuita para médicos | Sin mención de API ni licencia de datos — [PLM](https://medicamentosplm.com/faq) [V] | No confirmado. Más de 12 países; el menú enlaza México, Colombia, Perú, Ecuador, Centroamérica y Chile, sin Venezuela [V] |
| **DrugBank** | Base farmacológica, API y datos | Académica gratis (CC BY-NC 4.0), no comercial; comercial de pago, sin precio público — [precios](https://go.drugbank.com/pricing/) y [términos](https://trust.drugbank.com/drugbank-trust-center/terms-of-use) [E] | Solo para enriquecer principios activos. No confirmé marcas venezolanas |
| **RxNorm (NLM, EE. UU.)** | Nombres normalizados e identificadores | Identificadores de dominio público; versión completa con licencia UMLS gratuita e individual — [NLM](https://www.nlm.nih.gov/research/umls/rxnorm/docs/termsofservice.html) [E] | Parcial; ver Inferences |
| **ATC/DDD (centro colaborador de la OMS)** | Clasificación por sustancia | Índice electrónico en Excel o XML: **€200 por copia**; papel: €60, o €100 con las guías; guías gratis — [FHI](https://atcddd.fhi.no/atc_ddd_index_and_guidelines/order) [E] | Sí, como clasificación. Hay que mapearla desde el principio activo. El uso comercial no quedó confirmado |
| **GS1 Venezuela** | Emisor único de códigos de barras en el país; prefijo [759](https://en.wikipedia.org/wiki/List_of_GS1_country_codes). Migra a códigos 2D con la expectativa de un estándar global hacia 2027 — [Finanzas Digital](https://finanzasdigital.com/gs1-venezuela-capacitacion-cadena-suministro-nexo-2025/) [E] | No hallado | Identifica presentaciones, pero no encontré una consulta pública de medicamentos |
| **openFDA** | Datos públicos de la FDA | CC0 por defecto; límites de uso sin cifras en los términos — [openFDA](https://open.fda.gov/terms/) [V] | Marginal; ver Inferences |
| **Open Products Facts** | Base colaborativa de 48.546 productos; excluye alimentos, cosméticos y comida para mascotas; tiene datos y API — [sitio](https://world.openproductsfacts.org/) [V] | La página no menciona la licencia | No hay evidencia de que cubra medicamentos venezolanos |

**Referencia regional:** Colombia publica un [listado de registros vigentes con principio activo](https://invima.gov.co/biblioteca/listado-registros-sanitarios-medicamentos-invima-2023) (INVIMA, 2023) [E].

### Inferences
- **Diccionario propuesto:**
  - INHRR como base.
  - ATC mapeado por principio activo, por €200.
  - GTIN tomado de los catálogos de las cadenas, si los publican.
  - Una capa de sinónimos propia para unir el texto del récipe, el registro y el catálogo de cada farmacia.
- El INHRR no da el dato comercial completo: un registro no siempre equivale a una presentación con código de barras, así que habrá unión manual.
- El JSON hace viable una carga completa, pero solo vi lo que la página trae por defecto. No usé el buscador ni llamé a la API. Antes de automatizar conviene revisar la base legal y ser moderado con un servidor público.
- Conviene no copiar el campo de farmacéutico patrocinante, porque es un dato personal y el sistema no lo necesita.
- RxNorm y openFDA describen el mercado de EE. UU., así que sirven de apoyo para sustancias, no para marcas locales. Es una deducción mía; sus términos no lo plantean así.

### Gaps
- Número de productos vigentes hoy: solo vi el total de 22.794.
- Términos de uso o licencia del INHRR, y si permite reutilización comercial.
- Licencia de Open Products Facts. La conozco como ODbL, pero la página que leí no lo confirma.
- Si existe un vademécum venezolano vigente, o una edición de PLM para Venezuela.
- Si GS1 Venezuela vende o comparte su directorio.

## Scraping como servicio y data brokers: precios, proxies en Venezuela y utilidad a pequeña escala

### Takeaway
Es accesible: entre decenas y pocos cientos de dólares al mes para unos pocos sitios, aunque puede pasar de $1.000 si hacen falta navegador y proxies residenciales. Hay proxies venezolanos disponibles. El límite es que solo captura farmacias con catálogo web.

### Cited Findings

| Servicio | Precio público | Venezuela o geolocalización | Encaje |
|---|---|---|---|
| **Bright Data** | Residencial: **$8/GB, $4/GB con promoción**. Planes de $499 (141 GB), $999 (332 GB) y $1.999 (798 GB). Promoción del 50% por 3 meses — [precios](https://brightdata.com/pricing/proxy-network/residential-proxies) [V] | Geolocalización gratis hasta ciudad. Anuncia «100,614 Venezuela IPs»; los metadatos dan otra cifra, 401.690 — [Venezuela](https://brightdata.com/locations/ve) [V] | Proxies; el raspado se construye aparte |
| **Oxylabs** | Desde **$8/GB** — [Venezuela](https://oxylabs.io/location-proxy/venezuela) [V]. Terceros dan tarifas de $2,50 a $6 — [CostBench](https://www.costbench.com/software/web-scraping/oxylabs/) [E] | Anuncia 1.128.687 IP en Venezuela [V] | Igual que Bright Data |
| **Zyte API** | Por cada 1.000 respuestas: $0,13–$1,27 sin plan; con navegador $1,01–$16,08. Planes desde $100/mes — [precios](https://www.zyte.com/pricing/) [V] | Tiene geolocalización; no confirmé Venezuela | Bueno para pequeña escala; paga por respuesta exitosa |
| **ScrapingBee** | $19 (75.000 créditos), $49 (250.000), $99 (1M), $249 (3M), $599 (8M). Proxy premium: 10–25 créditos por petición; JavaScript: 5 — [precios](https://www.scrapingbee.com/pricing/) [V] | Más de 200 países y territorios (más de 40 con proxies clásicos); no confirmé Venezuela | Bueno y simple |
| **Apify** | Gratis ($5 de uso), $19, $199, $999. Residencial $7–$8/GB — [precios](https://apify.com/pricing) [V] | La página de precios no aclara la selección de país | Bueno si se escriben actores propios |
| **Firecrawl** | Gratis (1.000 créditos), $19 (5.000), $99 (100.000), $399 (500.000), $749 (1M) — [precios](https://www.firecrawl.dev/pricing) [V] | La página de precios no menciona proxies por país | Útil para extraer sitios sueltos; riesgo si hace falta IP venezolana |
| **Prisync** | Por URL: $99 (100 productos), $199 (1.000), $399 (5.000); API +20% — [precios](https://prisync.com/pricing/) [V] | «Worldwide Site/Currency Coverage»; sin detalle de países | Mal encaje: pensado para vigilar competidores por producto, se queda corto ante miles de medicamentos |
| **Price2Spy** | Sin cifras visibles; Premium a solicitud — [precios](https://www.price2spy.com/pricing.html) [V] | No lo aclara | Mismo problema que Prisync |
| **Grepsr** (servicio administrado) | Desde $350/mes, según [Capterra](https://www.capterra.com/compare/176555-212653/Grepsr-vs-Scrapfly) [E]; otras fuentes difieren | No hallado | Opción si no se quiere mantener raspadores |
| **ScrapeHero** (administrado) | $199/mes por sitio, según [Prospeo](https://prospeo.io/s/grepsr-alternatives) [E] | No hallado | Igual; cifra de un tercero |

**Otra oferta de proxies:** [Shifter](https://shifter.io/location/venezuela) anuncia más de 1,3 millones de IP residenciales en Venezuela y ciudades como Caracas y Maracaibo [E]. Es publicidad de un competidor, sin verificar.

### Inferences
**Estimación propia, con supuestos míos:** 5 sitios × 10.000 productos × una pasada semanal ≈ 216.500 páginas al mes.

| Vía | Costo mensual estimado |
|---|---|
| Zyte sin navegador | $28–$95 (tiers 1 a 3) |
| Zyte con navegador, tier más bajo | ~$220 |
| Zyte con navegador, tier más alto | ~$3.480 |
| ScrapingBee, premium sin JavaScript | $249 |
| ScrapingBee, premium con JavaScript | $599 |
| Proxy residencial, 100 KB por página | $87–$173 |
| Proxy residencial, 1 MB por página | $866–$1.732 |

- Pasar de semanal a diario multiplica estas cifras por unas 7 veces. Hay que sumar el tiempo de mantener los raspadores, que suele pesar más que la factura.
- La necesidad real de una IP venezolana depende de si cada farmacia bloquea tráfico extranjero. Eso lo cubre el otro investigador.
- Para este caso conviene una herramienta genérica (Zyte o ScrapingBee) antes que Prisync o Price2Spy, cuyo modelo es de minorista que vigila a sus competidores.

### Gaps
- **DataWeave:** no hallé precios ni oferta para farmacias.
- **Condiciones de uso:** no revisé los términos de cada farmacia sobre extracción automatizada, ni el marco legal venezolano.
- **Cobertura real:** las cifras de IP son publicidad de cada proveedor; no medí la calidad ni la tasa de éxito en Venezuela.

## Tecnología farmacéutica en América Latina: agregadores, receta electrónica y posibles socios

### Takeaway
No hallé ninguna plataforma regional de receta electrónica operando en Venezuela. En el país, los dos nombres a seguir son GoPharma, la pista local más real, y LataMed AI, todavía un anuncio. Los comparadores regionales que encontré los suelen operar los gobiernos.

### Cited Findings

| Empresa | Qué hace | ¿Venezuela? | Valor como socio |
|---|---|---|---|
| **GoPharma** (Servicios Gopharma C.A.) | Red de farmacias independientes: buscar medicinas cerca, pagar y recibir a domicilio — [ficha](https://mwm.ai/apps/gopharma/6738582244) [E]. Unas 67.400 instalaciones en Android, actualizada en mayo de 2026 — [AppGoblin](https://appgoblin.info/apps/com.gopharma.gopharma_user) [E] | **Sí** | **El mejor candidato a verificar.** No confirmé si tiene precio y existencias por farmacia, ni API |
| **LataMed AI** (OTC: LMED) | Anuncia «términos comerciales» con 2 operadores de farmacias en Caracas para procesar récipes con IA y verificar inventario. Se describe en etapa de desarrollo y advierte que no hay garantía de plazos — [comunicado, 26-may-2026](https://www.newsworthy.ai/curated/latamed-ai-partners-with-venezuelan-pharmacy-operators-to-deploy/202632570) [V] | Anunciado | Competidor a vigilar. Es un comunicado propio, sin operaciones confirmadas |
| **Prescrypto** | Receta electrónica en México, con API y repositorios abiertos — [Descubre](https://www.descubre.vc/prescrypto), [documentación](https://prescrypto.github.io/prescrypto-docs/docs/tutorial/overview) [E]. Alianza con Doctoralia en México — [TTR](https://www.ttrdata.com/en/radar/aggregated/Doctoralia-partners-with-Prescrypto-to-offer-electronic-prescriptions-in-Mexico/300936) [E] | Sin evidencia; sus ejemplos usan CURP, un identificador mexicano | Referencia técnica |
| **Vitau** | Farmacia digital mexicana para crónicos; se le atribuye una API para prestadores — [Dealroom](https://app.dealroom.co/companies/vitau) [E] | Sin evidencia | Bajo |
| **Medikit** | Receta electrónica en México, con acuerdos con farmacias y laboratorios — [Milenio](https://www.milenio.com/negocios/recetas-electronicas-medikit-busca-evitar-falsificacion) [E] | Sin evidencia | Bajo |
| **Docplanner / Doctoralia** | Citas y receta electrónica en México — [TTR](https://www.ttrdata.com/en/radar/aggregated/Doctoralia-partners-with-Prescrypto-to-offer-electronic-prescriptions-in-Mexico/300936) [E] | Sin evidencia | Bajo |

**Comparadores regionales como referencia:**
- Chile tiene un comparador público de cerca de 12.000 medicamentos — [Minsal](https://www.minsal.cl/gobierno-lanza-comparador-de-precios-con-informacion-de-cerca-de-12-mil-medicamentos/) [E]. Fue denunciado ante Contraloría en 2018 — [Radio Agricultura](https://www.radioagricultura.cl/noticias/nacional/presentan-denuncia-en-contraloria-por-comparador-de-precios-en-farmacias_20180515/) [E].
- Perú tiene una aplicación móvil para ubicar medicamentos a bajo precio — [Andina](https://andina.pe/agencia/noticia-medicamentos-a-bajo-precio-un-clic-aplicativo-movil-727244.aspx) [E].
- De 9 portales de precios revisados en un estudio de 2018, 8 eran gubernamentales — [AMiner](https://aminer.org/pub/5c757ce0f56def9798a82ec7/description-of-drug-pricing-and-procurement-information-web-portals-in-some-latin) [E].

### Inferences
- Los comparadores de Chile y Perú sugieren que este dato suele existir porque un regulador lo recoge, una ventaja que en Venezuela no se observa. Un actor privado tendría que ganárselo farmacia por farmacia.
- Importar una plataforma extranjera aporta poco: su valor está en el marco legal y las farmacias de cada país, no en el software. Helios ya tiene al médico, que es donde nace el récipe.

### Gaps
- **RP Doctor y Nimbo:** no encontré información. Pueden estar mal nombrados o ser muy pequeños.
- **Doctoralia en Venezuela:** no hallé si opera.
- **Marco legal:** no encontré regulación venezolana de receta electrónica; lo más cercano fue la normativa argentina.
- **GoPharma:** no hallé datos de la empresa, fundadores ni número de farmacias.

## Empresas venezolanas con acceso a inventarios de farmacias: distribuidoras, POS, ERP, pagos y fidelización

### Takeaway
No encontré a ninguna empresa venezolana que ofrezca públicamente datos de inventario de farmacias. Cashea llega a muchos comercios, pero no hay evidencia de que vea sus inventarios. Los fabricantes de software de facturación son la pista más lógica, aunque sin confirmar.

### Cited Findings
- **Cashea:**
  - Su «Línea Cotidiana» permite pagar en cuotas en supermercados y farmacias. En junio de 2024 ya se podía usar en Locatel, sin anuncio oficial de Cashea — [La Verdad de Monagas](https://laverdaddemonagas.com/2024/06/27/farmacias-se-une-a-cashea) [V].
  - En julio de 2026 se le atribuían más de 10 millones de cuentas y 40.000 comercios aliados — [Valora Analitik](https://www.valoraanalitik.com/?p=600645) [V].
  - Ninguna de las dos notas menciona inventarios, y no hallé nada sobre esa integración en otras fuentes.
- **Software homologado:**
  - El SENIAT homologa el software de facturación — [Finanzas Digital](https://finanzasdigital.com/facturacion-digital-venezuela-normativa-seniat/) [E], y está reforzando la fiscalización — [Edicom](https://edicomgroup.com/es/factura-electronica/venezuela) [E].
  - La Gaceta 43.032 exige a esos proveedores dar al SENIAT una clave de consulta — [Finanzas Digital](https://finanzasdigital.com/gaceta-oficial-n-43-032-requisitos-proveedores-sistemas-informaticos-emision-facturas-fiscales) [E].
  - Galac apareció en la búsqueda con un [folleto de su sistema administrativo](https://store.galac.com/wp-content/uploads/2020/11/brochure_administrativo.pdf) [E; solo vi el enlace]. No confirmé si está homologado ni si tiene módulo para farmacias.
- **Cadenas con sistema propio:** una cadena con 200 tiendas en Venezuela y Colombia actualizó su POS con Oracle — [Retail Customer Experience](https://www.retailcustomerexperience.com/news/venezuelan-pharmacy-chain-taps-oracle-tools-for-growth-better-customer-service/) [E, nota sin fecha verificada].
- **Sistema público SICM:** creado por la Gaceta 39.971 de 2012 — [TAG Alliances](https://www.tagalliances.com/health-law/3647-single-guide-for-transportation-monitoring-and-control-of-medicines-extension.html) [E]. Desde una resolución de 2018, laboratorios, casas de representación e importadores deben registrarse para reportar unidades comercializadas — [PwC](https://www.pwc.com/ve/es/publicaciones/assets/PublicacionesNew/Boletines/Boletin_SICM_Dic2018.pdf) [E; el PDF me dio 403]. No hallé acceso público ni evidencia de cómo funciona hoy.
- **Peso de las independientes:** el presidente de la Federación Farmacéutica les atribuía el 85% del mercado en una nota actualizada en mayo de 2019 — [RPP](https://rpp.pe/mundo/venezuela/unas-400-farmacias-han-cerrado-en-venezuela-por-la-crisis-economica-noticia-1199639) [V]. El dato tiene más de siete años y puede haber cambiado.

### Inferences
- Si las independientes siguen pesando tanto, el scraping dejaría fuera a gran parte del mercado. Habría que llegar a ellas por el software que ya usan, una red como GoPharma, o una carga directa de precios por la propia farmacia.
- Los fabricantes de software de facturación tendrían precios y existencias de sus clientes en el sistema, pero el dato es de cada farmacia. Cualquier acuerdo necesitaría el permiso de cada una.
- Cashea compite con Helios en pago por cuotas, lo que complica una alianza de datos, además de que no hay indicio de que tenga esos datos. Esto es juicio mío.

### Gaps
- Si Valery, Saint, a2 u otros sistemas tienen módulos de farmacia, cuota de mercado o API. No hallé fuentes; los nombres vienen de mi conocimiento general, no de un documento revisado.
- Lista vigente de software homologado por el SENIAT.
- Si procesadores de pago, Krece, programas de lealtad o plataformas de delivery tienen datos por producto; no los investigué a fondo.

## Droguerías y laboratorios como fuente: ¿venden o comparten listas de precio sugerido?

### Takeaway
No encontré ninguna lista pública vigente de droguerías ni laboratorios. Aunque se consiguieran, darían precio de referencia o de compra de la farmacia, no el precio de cada farmacia al público.

### Cited Findings
- **Droguerías:**
  - Solo hallé directorios: Corporación Drolanca, con ingresos estimados de $5,5 millones — [Clodura](https://www.clodura.ai/directory/company/corporacion-drolanca-ca) [E]. Es una estimación de terceros.
  - Droguería Nena aparece en Caracas o Barquisimeto, según la fuente — [Reevol](https://source.reevol.com/en/suppliers/droguer-a-nena-c-a/ai-card.md) [E].
  - `cobeca.com` no abrió por un error de certificado [V].
- **Modelo en otros países:** en Argentina, las droguerías suelen tener sistemas B2B propios que se conectan con el POS de la farmacia; sin esa conexión la carga es manual — [Yo Facturo](https://yo-facturo.com/blog/pos-farmacia-medicamentos/) [E].
- **Precios regulados:** la Gaceta 41.501 fijó máximos para 56 principios activos y 172 presentaciones, con validez de 90 días — [NTN24](https://www.ntn24.com/noticias-actualidad/publican-en-gaceta-oficial-precios-fijados-de-mas-de-50-medicamentos-99341) [E]. Corresponde a un acuerdo que otra fuente sitúa en 2018, así que no sirve como lista actual.
- **Laboratorios:** Grupo LETI tiene unidad de inteligencia de negocios y publica Faro Farmacéutico, pero solo con cifras agregadas — [El Diario](https://eldiario.com/2026/09/02/crecimiento-mercado-farmaceutico-venezuela/) [V].

### Inferences
- Lo más probable es que estas listas existan y circulen entre clientes, sin publicarse. Una droguería aporta catálogo y disponibilidad en su red, y serviría para detectar precios anómalos, pero no reemplaza el precio final.
- Los laboratorios nacionales podrían tener interés comercial en dar visibilidad a sus genéricos, que son el 45% de las unidades según Faro — [Bloomberg Línea](https://www.bloomberglinea.com/latinoamerica/venezuela/mercado-farmaceutico-venezolano-crece-1235-hasta-agosto-y-supera-los-285-millones-de-unidades/) [V]. También crea un conflicto de neutralidad si el sistema promete el menor costo.

### Gaps
- Si alguna droguería ofrece portal o archivo de precios a terceros. Solo se responde preguntándoles, y eso quedó fuera de este encargo.
- Participación de mercado de cada droguería.
- Si hoy rige alguna regulación de precios de medicamentos en Venezuela.

## Restricciones por sanciones u operatividad: ¿hay proveedores que no atiendan Venezuela?

### Takeaway
No encontré ningún proveedor que excluya expresamente a Venezuela, aunque solo pude comprobarlo en la política de Bright Data. Las sanciones de EE. UU. se dirigen al Gobierno y a personas y sectores concretos, no parecen un embargo total, y se han flexibilizado en 2026, sobre todo en petróleo, gas, electricidad y minería. El riesgo principal es tratar con entes del Estado. Esto no es asesoría legal.

### Cited Findings
- **Bright Data:** su lista de jurisdicciones restringidas no incluye a Venezuela. Sí incluye a Irán, Irak, Líbano, Siria, Corea del Norte, Cuba, Sudán, Rusia y Bielorrusia, entre otras — [Bright Data](https://docs.brightdata.com/general/privacy/restricted-jurisdictions) [V].
- **Forma del programa:** OFAC lo describe con bloqueos del Gobierno de Venezuela y de personas, más determinaciones por sector. Sigue listando la E.O. 13884 y otras. La página no usa el término «embargo integral» y su acción más reciente es del 4 de noviembre de 2026 — [OFAC](https://ofac.treasury.gov/sanctions-programs-and-country-information/venezuela-related-sanctions) [V].
- **Licencias generales relevantes**, según la misma página de [OFAC](https://ofac.treasury.gov/sanctions-programs-and-country-information/venezuela-related-sanctions) [V]:
  - GL 4C: exportación de medicinas y dispositivos médicos.
  - GL 25: servicios, software y tecnología para comunicaciones por internet.
  - GL 26: servicios médicos.
  - GL 61A (27-ago-2026): bienes y servicios de telecomunicaciones.
- **Regla del 50%:** una entidad fuera de la lista SDN puede estar bloqueada si el Gobierno o PDVSA tienen el 50% o más. Por eso se recomienda revisar la propiedad de cada contraparte. La autorización de OFAC tampoco sustituye los controles de exportación — [Leech Tishman](https://www.leechtishman.com/insights/blog/venezuela-is-open-again-ofacs-march-2026-license-expansions-and-what-they-mean-for-u-s-business/) [V].
- **Inestabilidad:** las licencias no tienen vencimiento fijo y OFAC puede modificarlas o revocarlas con poco aviso — [Foley, agosto de 2026](https://www.foley.com/insights/publications/2026/08/ofac-reaffirms-recent-licenses-along-with-new-license-in-response-to-venezuela-earthquakes-2/) [V].
- **Cumplimiento financiero:** un blog de un proveedor de verificación indica que Venezuela entró en la lista de vigilancia del GAFI el 28 de junio de 2024 — [Didit](https://didit.me/pt-BR/blog/identity-verification-kyc-and-aml-compliance-in-venezuela/) [E]. Es una fuente débil.

### Inferences
- Una empresa privada no sancionada como Quarto Latam no parece tener un impedimento general para contratar herramientas de scraping o bases de datos. Es lectura mía y debe confirmarla un abogado de sanciones.
- El riesgo se concentra en contrapartes estatales. Un proveedor de EE. UU. podría no poder participar en un acuerdo formal con el INHRR, el Ministerio o una farmacia pública. Eso importa si el sistema incluye farmacias del Estado.
- Aunque las reglas lo permitan, los grandes proveedores pueden negarse por política interna o exigir revisión de cumplimiento (KYC), y los pagos desde Venezuela pueden ser la traba práctica. Conviene preguntarlo antes de depender de uno.

### Gaps
- Políticas específicas de IQVIA, Close-Up, GlobalData, DrugBank, Zyte, Apify, Firecrawl y ScrapingBee sobre clientes venezolanos.
- Medios de pago que aceptan estos proveedores desde Venezuela, incluido Stripe: no quedó confirmado.
- Si la titularidad de Quarto Latam o de sus contrapartes requiere revisión: no se investigó.
