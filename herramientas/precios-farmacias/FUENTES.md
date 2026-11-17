# Qué permite cada fuente

Revisado el **2026-11-06**, leyendo términos y `robots.txt` de cada sitio. Es una
lectura técnica, no asesoría legal. `robots.txt` dice qué rutas se pueden pedir;
los términos dicen qué se puede hacer con el contenido. Por eso un `robots.txt`
abierto no da permiso.

**Conclusión: ninguna fuente de Caracas con precios vigentes permite hoy esta
recolección sin una licencia o un permiso, así que todas están en pausa** y no
hay CSV completo. Reanudar es decisión de Javier.

**Excepción puntual (2026-11-06):** a pedido del usuario en esta sesión, se sacó una
muestra única de 10 filas de SAAS para probar RX, con la intención de borrarla
después. Queda en `salida/precios-20261106-parcial.csv`. SAAS sigue en pausa: la
muestra se tomó activándola solo en memoria, y la caché con las 50 filas de esa
página se borró. No autoriza una recolección mayor.

| Fuente | Estado | Qué dicen sus términos | `robots.txt` | Enlaces |
|---|---|---|---|---|
| **keiti** | En pausa: requiere licencia | El §5 (v1.3, octubre de 2026) somete el acceso automatizado, la extracción sistemática y el consumo de sus API a licencia comercial con pago por consulta. Las peticiones sin autorización reciben HTTP 402. | Abierto (`Allow: /`). No cambia lo anterior. | [términos](https://keiti.io/terminos), [robots](https://keiti.io/robots.txt), [documentación](https://keiti.io/documentacion) |
| **Farmacia SAAS** | En pausa: prohibido sin consentimiento | Prohíben reproducir, copiar o distribuir contenido sin autorización expresa, y usarlo total o parcialmente sin consentimiento escrito. Definen contenido como nombres, textos, fotos, videos y software. No nombran precios ni acceso automatizado. | Solo cierra rutas como `/busca/*` y `/checkout/*`; no cierra `/api`. | [términos](https://www.farmaciasaas.com/tyc), [robots](https://www.farmaciasaas.com/robots.txt) |
| **Locatel** | En pausa: prohibido para este uso | Prohíben vender, modificar, anunciar públicamente o distribuir el contenido con fines comerciales, y presumen indebido todo uso no autorizado. No nombran el acceso automatizado. Enseñar sus precios a pacientes en Helios choca con esta cláusula. | Igual que SAAS. | [términos](https://www.locatel.com.ve/terminos-y-condiciones), [robots](https://www.locatel.com.ve/robots.txt) |
| **Farmatodo** | En pausa: prohibido sin autorización | Prohíben reproducir, copiar, distribuir o comunicar públicamente el contenido sin autorización o permiso legal. El informe previo cita además la prohibición de acceder a datos no destinados al usuario; esa cláusula no la releí hoy. No nombran robots ni raspado. | Cierra `/buscar*` y `/busqueda*`, y todo el sitio para dos versiones de Scrapy. | [términos](https://www.farmatodo.com.ve/terminos-y-condiciones), [robots](https://www.farmatodo.com.ve/robots.txt) |
| **FarmaBien** | En pausa: bloquea | Sin leer: el sitio y su `robots.txt` responden 429 con un desafío de seguridad de Vercel. No se intentó saltarlo. | No accesible. | [sitio](https://www.farmabien.com/) |

Ni **Farmadon** ni **Farmapaz** entran nunca: `prepararFilas` las excluye sin importar
mayúsculas, acentos ni espacios, y hay pruebas que lo demuestran.

## Fuera por otros motivos

| Sitio | Motivo | Comprobado |
|---|---|---|
| [Farmahorro](https://farmahorro.com.ve/) | Permite rastrear, pero sus datos parecen congelados: la portada sigue con `last-modified` del 2025-11-07. | Cabecera, hoy |
| [Merca Farma](https://www.mercafarma.com.ve/) | Su portada se presenta como de Valencia y Naguanagua; no consta que sea de Caracas. Términos sin leer. | Portada, hoy |
| [Xana](https://xana.com/) | Tiene sedes en Caracas, pero su portada no muestra catálogo ni precios. Las rutas `/productos` y `/terminos` dan 404. Hay rutas que no probé. | Hoy |
| [FarmaGo](https://www.farmago.com.ve/) | Error 522, origen caído. | Hoy |
| Farmarket, FarmaExpress, Farmacias Vida | Sin catálogo visible, hosting suspendido y dominio dudoso con 403, respectivamente. | Solo informe previo, 2026-11-04 |

Dos búsquedas web no encontraron otra cadena de Caracas con catálogo y precios
públicos. Eso no demuestra que no exista.

## Qué se pidió a cada sitio

Antes de leer los términos de SAAS hice unas 20 peticiones a su catálogo, con
pausa, para entender el formato y contar categorías: canal de venta, árbol de
categorías y de 1 a 50 productos por consulta. La ruta `/terminos-y-condiciones`
daba una página vacía y los términos reales estaban en `/tyc`. Al leerlos paré.
De esas muestras no sale ninguna fila ni fixture: las fixtures de `test/` usan
productos inventados y las muestras se borraron.

- **keiti:** solo páginas públicas y documentación (portada, `robots.txt`, sitemap,
  términos, descargo, `llms.txt`, `openapi.json`, `/documentacion`). No se llamó a
  ningún endpoint de datos. No se usó el token que su portada marca como
  «Anti-Scraping».
- **Locatel y Farmatodo:** solo `robots.txt` y términos.

## Si Javier decide reanudar

Para activar una fuente hay que cambiar su `estado` a `activa` en
`src/fuentes/index.mjs` y ajustar la prueba de registro, que exige hoy que todas
estén en pausa.

### keiti: la única vía con licencia para el acceso

- **Precio:** $0,005 por consulta con saldo prepagado, según su documentación. El
  catálogo diario completo (`/v1/b2b/catalogo-diario`) es por contrato. Un barrido
  costaría unos $2 a $25 según cómo se recorra. Es una estimación mía, sin probar.
- **Pago:** en USDT, sin reembolso. La clave la crea Javier con su propia cuenta.
- **Falta confirmar con keiti (`contacto@keiti.io`):** si la licencia permite
  mostrar sus datos a pacientes. Los términos no lo aclaran. Además, keiti recopila
  de las mismas cadenas, así que sus términos no resuelven lo que esas cadenas
  prohíben.
- **Falta programar:** `src/fuentes/keiti.mjs` solo traduce el ejemplo de `/v1/buscar`
  de su documentación. El recorrido del catálogo se escribe con respuestas reales.
  Falta también comprobar si la región «Centro» incluye a Caracas.

### SAAS y Locatel: adaptador listo, con riesgo

- **Riesgo:** activarlas va contra sus términos. Lo prudente es un permiso escrito o
  el visto bueno del abogado, como recomienda el informe previo. Grupo Cobeca es
  dueño de SAAS.
- **Sin probar:** nunca se ha corrido una lectura completa. Locatel solo tiene el
  código de categoría del informe previo.

### Farmatodo y FarmaBien

No tienen adaptador. Para Farmatodo, su índice de búsqueda no debería usarse sin
permiso: que la clave esté visible en la página no es una autorización.

## Decisiones de datos para cuando haya recolección

- **Solo medicamentos (SAAS):** sobre su árbol «Medicamentos», entran RX, Hospitalarios,
  Antigripales y analgésicos, Antiinflamatorios, Antisépticos y Digestivos.
  Dermocosmética y Papeletas entran solo si el producto trae «Clase terapéutica».
  Quedan fuera Antioxidante y Bienestar Integral (vitaminas, productos naturales y
  suplementos), unos 1.020 productos según el conteo de hoy. Un médico puede recetar
  una vitamina que entonces no aparecería, salvo que esté en RX. Se cambia en
  `CATEGORIAS_SAAS`.
- **Caracas:** en la muestra de SAAS, el catálogo solo trae un vendedor central y un
  precio, sin distinguir ciudad. Su ficha pide elegir ciudad solo para consultar la
  disponibilidad. Por eso `disponible` en SAAS sería del canal central, no de Caracas.
  Si una fuente distingue ciudad, como Farmatodo o keiti, hay que quedarse con Caracas
  en su adaptador.
- **Moneda de SAAS:** el canal VTEX declara `USD` y la ficha muestra «Ref.». En un
  producto, Ref. 1,22 equivalía a Bs 1.093,27, es decir 896,12 Bs por Ref., igual a
  la tasa BCV del dólar que keiti mostraba hoy. Es una sola observación.
- **Controlados:** SAAS trae el campo «Control sanitario». El informe previo recomienda
  dejar fuera los psicotrópicos, pero el CSV no tiene columna para marcarlos y hoy no
  se filtran. Falta decidirlo.
