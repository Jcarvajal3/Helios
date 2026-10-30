# OpenSEO: datos de SEO para el agente (2026-10-30)

OpenSEO ([every-app/open-seo](https://github.com/every-app/open-seo), MIT) da
al agente (Claude Code) volúmenes de búsqueda, resultados de Google,
competencia, posiciones y visibilidad en asistentes con IA, para decidir qué
páginas crear. Los datos salen de DataForSEO; OpenSEO los compra y los cobra
por uso.

## Cómo quedó instalado

- **Hospedado en openseo.so** (Javier, 2026-10-30). Se descartó instalarlo en
  Cloudflare: pedía cuenta de Cloudflare con tarjeta (para R2) y otra de
  DataForSEO con recarga mínima de $50. Docker sigue descartado (2026-09-30).
- Cuenta de Javier, con un proyecto **conhelios.com**: mercado **Venezuela**
  (`locationCode` 2862), idioma `es`. Caracas es la ubicación 1028528.
- **Claude Code lo usa por MCP**: `.mcp.json` en la raíz del repo apunta a
  `https://app.openseo.so/mcp`, sin llaves. Cada persona inicia sesión con su
  cuenta de OpenSEO desde `/mcp` (OAuth). Probado desde Claude Code el
  2026-10-30.
- Precio: el plan Base cuesta $10/mes e incluye $10 de consultas; cada
  consulta cuesta lo que cobra DataForSEO más un 28%. La cuenta nueva trae
  457 créditos de prueba ($0,46). **1 crédito = $0,001.**

### Lo que cuesta cada herramienta (medido en la prueba)

| Herramienta | Qué da | Costo medido |
| --- | --- | --- |
| `get_keyword_metrics` | Volumen mensual, dificultad, intención y CPC de hasta 700 búsquedas conocidas | **16 créditos por llamada** (con 22 a 24 búsquedas; sin tendencias mensuales) |
| `get_serp_results` | Los resultados de Google de 1 a 10 búsquedas | **3 créditos por búsqueda** con `depth: 10` |
| `research_keywords` | Ideas de búsquedas a partir de 1 a 5 semillas, con volumen | **46 a 50 créditos por semilla** |
| `whoami`, `list_projects`, `search_serp_locations` | Saldo, proyecto, códigos de ubicación | Gratis |
| `explore_prompt`, visibilidad en IA | Respuestas de ChatGPT, Gemini, Perplexity… y si citan a Helios | Exige plan de pago en la versión hospedada: **sin probar** |

## La prueba de Venezuela

**Gasto real: 367 créditos ($0,37), salidos del saldo de prueba. De bolsillo,
$0.** Quedan 90 créditos. Seis llamadas: dos de métricas con las búsquedas
de `docs/03`, una de resultados de Google con 10 búsquedas, dos de ideas con
6 semillas («cashea», «odontólogo», «consulta médica», «cuotas», «dentista»,
«ginecólogo») y una de métricas sin tildes.

### ¿Sirven los datos de Venezuela? En parte

**Sí hay volúmenes** para Venezuela, con dificultad e intención (no es uno de
los países que DataForSEO solo cubre con datos de Google Ads). Búsquedas al
mes:

| Búsqueda | Volumen | Búsqueda | Volumen |
| --- | ---: | --- | ---: |
| cashea | 110.000 | ginecologo caracas | 590 |
| psicologo | 18.100 | odontologo caracas | 480 |
| oftalmologo | 9.900 | farmacia con cashea | 320 |
| dermatologo | 2.400 | ginecólogo cerca de mí | 320 |
| cardiologo | 2.400 | consulta médica | 260 |
| pediatra | 1.600 | odontologo con cashea | 210 |
| psicólogo caracas | 1.300 | cuotas de cashea | 170 |
| nutricionista | 1.000 | pediatra caracas | 110 |
| doctoralia venezuela | 90 | laboratorio con cashea | 70 |
| dentista caracas | 50 | traumatólogo caracas, urólogo caracas | 30 |

**Sin volumen** (debajo del umbral de Google Ads o sin datos; no quiere decir
que nadie lo busque): **todas las búsquedas «en cuotas» de `docs/03`**
(consulta médica en cuotas, odontólogo en cuotas caracas, dentista sin
inicial, tratamiento dental en cuotas, ortodoncia en cuotas, ginecólogo en
cuotas caracas, cosmetología en cuotas, salud en cuotas, cobrar consultas en
cuotas), y también pagar médico con cashea, clínicas que aceptan cashea,
cashea para médicos, médicos que aceptan cashea, cashea salud y directorio
médico venezuela.

**Cuidado con las tildes**: Google agrupa las variantes y DataForSEO guarda
el volumen en una sola. «odontólogo caracas» sale sin datos y «odontologo
caracas» con 480; «dermatólogo» sin datos y «dermatologo» con 2.400; en
cambio «psicólogo caracas» sí trae 1.300 con tilde. **Hay que pedir las dos
formas y quedarse con la que tenga datos, sin sumarlas.** También hay
diferencias entre herramientas: «consulta médica» trae 260 en
`research_keywords` y nada en `get_keyword_metrics`.

**Sin idioma**: no se pudo probar. El MCP no deja quitar el idioma: si no se
pasa, usa el del proyecto (`es`). Con `es` los volúmenes llegan, así que no
hace falta.

### Quién sale en Google Venezuela (10 búsquedas)

- **conhelios.com no sale en ninguna.** «helios salud venezuela» devuelve
  solo a Helios Salud de Argentina (confirma `docs/03`, punto 2).
- **Respuesta de IA de Google (AI Overview) en 7 de 10**: todas las de
  cuotas, Cashea y marca. Las de especialista en Caracas sacan en cambio el
  **mapa con 3 consultorios** (Google Business Profile) arriba de todo.
- **Las búsquedas «en cuotas» las ganan publicaciones de Instagram y
  Facebook** de clínicas que anuncian Cashea; no hay páginas dedicadas.
  Confirma en Google el hueco que `docs/03` vio en Bing.
- Competidores con página propia: Quota Salud (2.º en «cobrar consultas en
  cuotas»), Mediktorio («El directorio médico para especialistas que aceptan
  Cashea», en «pagar médico con cashea»), Doctoralia («Los 20 Dermatólogos
  más recomendados en Caracas», en «dermatólogo caracas»), psicologos.co.ve y
  mentalzon.com en «psicólogo caracas», la página de comercios de Cashea en
  «clínicas que aceptan cashea».
- **Limitación**: muchas direcciones llegan como redirección de Google
  (`google.com/goto?...`) y se pierde el dominio; hay que reconocer el sitio
  por el título.

### Visibilidad en IA

Sin probar: `explore_prompt` y el seguimiento de IA exigen el plan de pago en
la versión hospedada. Según openseo.so/pricing cuestan unos $0,002 por
pregunta y por asistente.

## Lo que dicen los datos para el sitio

1. **Las páginas por especialidad deben nombrarse como se busca**:
   «Psicólogos en Caracas» (1.300), «Ginecólogos en Caracas» (590),
   «Odontólogos en Caracas» (480), con el «en cuotas» como diferencia, no
   como búsqueda principal. Las frases «en cuotas» no tienen volumen medible:
   su demanda real se verá en Search Console.
2. **La gente busca «especialista + forma de pago»**: «odontologo con
   cashea» (210), «farmacia con cashea» (320), «laboratorio con cashea» (70).
   Es la misma intención que cubre Helios.
3. **Se buscan los directorios de cada centro**: «clínica loira directorio
   médico» (70), «clínica ccct directorio médico» (40), «centro médico cagua
   directorio médico» (170). Una página por sede tendría sentido cuando haya
   varios médicos de Helios en una misma clínica.
4. **El mapa manda en las búsquedas de especialista**: que cada médico tenga
   su perfil de Google Business Profile con enlace a su ficha
   (`/medico/<slug>`) puede valer más que la ficha sola.

## Recomendación

**Seguir con la versión hospedada; no hace falta cambiar de instalación.**
Los datos de Venezuela sirven para elegir especialidades, ciudades y
palabras, pero no miden las frases largas «en cuotas»; para eso, Search
Console. Pagar el plan Base ($10) cuando se quiera:

- probar la visibilidad en IA («¿dónde pago una consulta médica en cuotas en
  Venezuela?» en ChatGPT, Gemini y Perplexity), y
- seguir cada semana las posiciones de unas 20 búsquedas (unos 3 créditos
  por búsqueda).

Con $10 de consultas al mes alcanza de sobra para ese uso. Si al mes Search
Console ya da las búsquedas y posiciones reales de conhelios.com, se puede
dejar el plan y volver a OpenSEO solo para investigar palabras nuevas.

## Cómo lo usa el agente

- Proyecto `d00f00f5-8280-4073-9c1b-4be0a5948422` (conhelios.com); pásalo
  como `projectId`. Ubicación 2862, idioma `es`.
- Mira el saldo con `whoami` (gratis) antes y después de gastar, y pide el sí
  de Javier antes de cualquier consulta que cobre.
- Pide cada búsqueda con y sin tildes; `includeMonthlyTrends: false` y
  `depth: 10` para gastar menos.
- `research_keywords` devuelve mucho ruido (universidades, días festivos);
  filtra por especialidad, ciudad o forma de pago antes de leerlo.
