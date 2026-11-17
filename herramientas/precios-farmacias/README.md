# precios-farmacias

Recolecta precios de medicamentos y los entrega en un CSV para cargarlo en RX. No
escribe en la base de datos. Usa Node 24 y no tiene dependencias.

**Estado (2026-11-06): todas las fuentes están en pausa y no hay CSV completo**,
porque sus términos prohíben esta recolección o la someten a licencia. Solo existe
una muestra de prueba de 10 filas de SAAS. Los detalles y lo que falta decidir están
en [FUENTES.md](FUENTES.md).

## Uso

```bash
npm test
```

```bash
npm run recolectar -- --listar
```

```bash
npm run recolectar
```

| Opción | Qué hace |
|---|---|
| `--limite N` | Lee como máximo N filas por fuente, para una muestra |
| `--fuentes saas,locatel` | Corre solo esas fuentes. Una en pausa sigue sin leerse |
| `--pausa S` | Segundos entre peticiones al mismo dominio. Mínimo y valor por defecto: 2 |
| `--salida DIR` | Carpeta de salida. Por defecto, `salida/` |
| `--desde-cero` | Borra el avance de hoy y vuelve a leer |
| `--listar` | Muestra cada fuente, su estado y el motivo |

Códigos de salida: `0` todo bien, `2` hubo CSV pero alguna fuente falló o se bloqueó,
`3` no se generó CSV.

### Reanudar

Basta con volver a correr el comando. Cada página leída queda en
`salida/.cache/AAAAMMDD/<fuente>/` y no se vuelve a pedir ese mismo día de Caracas.
Al día siguiente se lee de nuevo, porque los precios cambian.

### Comparar con la página de origen

```bash
npm run verificar -- salida/precios-AAAAMMDD.csv --muestra 25
```

Toma filas al azar y compara cada precio con el JSON-LD de la ficha del producto.

## Salida

- `salida/precios-AAAAMMDD.csv`: lectura completa.
- `salida/precios-AAAAMMDD-parcial.csv`: lectura incompleta, por `--limite`, bloqueo o
  fallo. Nunca lleva el nombre del definitivo.
- `salida/precios-AAAAMMDD[-parcial].resumen.json`: filas por farmacia y moneda,
  descartes y estado de cada fuente.

El CSV va en UTF-8, separado por comas, con esta cabecera:

```
farmacia,nombre,precio,moneda,laboratorio,presentacion,sku,url,disponible,visto_en,fuente
```

No lleva filas de Farmadon ni Farmapaz, ni productos sin precio, ni monedas que no
sean `VES` o `USD`, ni enlaces que no sean `https`. No hay duplicados: la clave es
`farmacia` más `sku`, o más `nombre` si no hay sku, y queda la lectura más reciente.

## Cómo se comporta en la red

Lee una página a la vez con pausa por dominio, respeta `robots.txt` y se identifica
con su propio User-Agent, sin datos personales. Reintenta los errores 5xx y de red
con espera creciente. Con 401, 402, 403, 451, un desafío de seguridad o un 429 que
persiste, para esa fuente y sigue con las demás. No usa cuentas ni rota IP.

## Añadir o quitar una fuente

Se hace en `src/fuentes/index.mjs`. Una fuente es un objeto con `id`, `nombre`,
`estado`, `motivo`, `segmentos(cliente)` y
`leerPagina(cliente, segmento, desde, visto_en)`. Si la tienda corre en VTEX, basta
con `crearFuenteVtex`. Antes de activar una fuente, lee sus términos y documenta en
[FUENTES.md](FUENTES.md) qué permite.
