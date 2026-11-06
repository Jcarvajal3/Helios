# RX — récipes digitales de Helios

El médico arma el récipe, lo firma con su firma digitalizada y se lo manda al
paciente por correo, sin gastar papel. Es un proyecto **aparte** para probarlo
antes de integrarlo al panel: nada de la web, del panel ni del superadmin
enlaza aquí, y la app pide a los buscadores que no la indexen.

## Cómo está hecho

| Pieza | Dónde | Notas |
|---|---|---|
| App | `rx/` | Vite + React + Tailwind v4, con los tokens de Helios |
| Dirección | `conhelios.com/rx` | Se publica con el panel, en el proyecto `helios`: `panel/scripts/construir-rx.mjs` lo compila a `public/rx`. Un cambio que solo toque `rx/` no despliega: hace falta que el último commit del push toque `panel/` |
| Base | proyecto `Helios` (producción) | Mismo login que el panel. Tablas `rx_*`, sin tocar las demás |
| Archivos | bucket privado `rx` | `<merchant>/firma/…`, `<merchant>/logo/…`, `<merchant>/recipes/<id>.pdf` |
| Correo | Edge Function `rx-enviar` | PDF adjunto por Resend. No pasa por `outbound_messages` |

Solo entra el **administrador** de una clínica activa (rol `gerente`), que hoy
es casi siempre el médico titular. La secretaria no: un récipe lleva la firma
del médico. Ojo: `gerente` no garantiza ser el médico. Una clínica con dos
administradores comparte firma e historial, y antes de abrir RX a todos habría
que ligar la cuenta con el titular. Durante la prueba no hay lista de clínicas:
entra cualquier administrador que conozca la dirección. Al compartir dominio con
el panel, también comparte la sesión del navegador.

Topes de correo por día de Caracas: 60 por clínica, 5 por destinatario en cada
clínica y 500 en total. Todo PDF adjuntado queda fijo: no se reemplaza ni se borra.

## Comandos

```bash
cd rx
npm install
npm run demo    # http://localhost:3003, datos de mentira: no toca la base ni manda correos
npm run dev     # http://localhost:3002, contra la base real (necesita .env)
npm test
npm run build
```

## Contrato

Todas las RPC son `security definer`, solo para `authenticated`, y miran la
clínica con `rx_clinica_activa()`. Quien no es administrador de una clínica
activa recibe el error `42501`. Los errores llevan el mensaje en español, listo para enseñarlo.

| RPC | Devuelve | Qué hace |
|---|---|---|
| `rx_mi_perfil()` | perfil | Datos de `merchants` con las correcciones de `rx_perfiles` encima |
| `rx_guardar_perfil(p_datos jsonb)` | perfil | Guarda las correcciones. Un campo vacío vuelve al dato de Helios |
| `rx_guardar_imagen(p_tipo text, p_path text)` | perfil | `firma` o `logo`. La ruta debe ser de su clínica; `null` la quita |
| `rx_emitir(p_id uuid, p_paciente jsonb, p_medicamentos jsonb, p_indicaciones text)` | récipe | Da el número y la fecha (hoy en Caracas). Idempotente por `p_id` |
| `rx_adjuntar_pdf(p_id uuid, p_path text)` | récipe | Guarda la ruta del PDF subido |
| `rx_listar(p_busqueda text default null, p_limite int default 50)` | lista de récipes | Los de su clínica, del más nuevo al más viejo; busca por nombre, cédula o número |
| `rx_buscar_medicamentos(p_busqueda text, p_limite int default 20)` | lista de nombres | El buscador del médico |
| `rx_preparar_envio(p_id uuid, p_correo text)` | datos del envío | Valida, aplica el tope diario y anota el envío. La llama `rx-enviar` |
| `rx_resultado_envio(p_envio_id uuid, p_estado text, p_provider_id text, p_error text)` | | Solo `service_role`. La llama `rx-enviar` |

Las formas del perfil y del récipe están en `src/modelo.ts` (`Perfil`, `Recipe`).

`POST /functions/v1/rx-enviar` con `{ "recipe_id": "…", "correo": "…" }` y el JWT
del médico responde `{ "ok": true }` o `{ "error": "codigo", "mensaje": "texto en español" }`.

## Farmacias y precios para el paciente

El correo lleva, si hay precios recientes, un enlace a `conhelios.com/rx/#/medicinas/<token>`.
Se abre sin cuenta y enseña, por cada medicamento que coincidió con un producto, lo que
publican las farmacias, de menor a mayor precio. De los demás solo dice cuántos son. No
dice de quién es el récipe y vence a los 30 días. La lista de medicamentos sigue siendo
un dato de salud, y el enlace no se puede revocar.

- **El médico no elige farmacias ni precios.** Ninguna RPC suya los recibe, las tablas no
  tienen permisos para la API y no recibe el enlace del paciente: lo pide `rx-enviar` con
  la service_role. Tampoco va en el PDF que firma: la Ley de Ejercicio de la Medicina le
  impide sugerir farmacias. Lo único que puede hacer es lo normal, recetar una marca, y eso
  acota el resultado.
- **Mejor no enseñar nada que enseñar otro medicamento.** `rx_ofertas` exige coincidencia en
  los dos sentidos, salvo `rx_palabras_neutras()` y las palabras del laboratorio, y no busca
  sin dosis. «Metformina 500 mg» no encuentra «Metformina XR 500 mg». El costo es que muchos
  productos no coincidirán: hay que medirlo con datos reales antes de ampliar la lista neutra.
- **Controlados fuera.** `rx_controlados` es una lista de principios activos y marcas que ni
  se cargan ni se enseñan. No es exhaustiva y debe revisarla un farmacéutico.
- **Un dato dudoso no entra.** Solo farmacias de `rx_farmacias`, fecha ISO con zona, precios
  sin ambigüedad y dentro de rango (de $0,05 a $1.000, a la tasa BCV).
- **Un precio viejo no se enseña.** Lo que no se vio en 14 días deja de salir.

**El campo de medicamento** busca con `rx_buscar_medicamentos` entre los productos cargados y
lo que su clínica ya recetó. Solo devuelve nombres, por orden alfabético: ni farmacia, ni precio,
ni si tiene precio. Lo que el médico escriba y no coincida se anota en `rx_medicamentos` al emitir,
visible solo para su clínica porque es texto libre. `rx_medicamentos_sin_precio` es la lista de
trabajo para buscarles precio: lo más recetado primero, solo de uso interno.

Para cargar precios, con el CLI de Supabase con sesión y desde la raíz del repo:

```bash
npm --prefix rx run precios -- ruta/precios.csv --fuente excel --seco
npm --prefix rx run precios -- ruta/precios.csv --fuente excel
```

Acepta `.csv` y `.xlsx`, con las columnas de `rx/plantilla-precios.csv`. El primer comando
solo lee el archivo. Una farmacia nueva se admite con `--farmacia-nueva "Nombre"`, y la fecha
de un archivo sin ella se indica con `--visto-en`. Cada carga queda en `rx_cargas`. Si cambian
las reglas de `rx_tokens`, `rx_recalcular_tokens()` recalcula lo cargado.

**Las fuentes (2026-11-06):** ninguna permite hoy extraer precios sin licencia o permiso; el
detalle está en `herramientas/precios-farmacias/FUENTES.md`. Solo se cargan datos con permiso.

## El PDF

Media carta vertical, como el récipe venezolano de siempre: una hoja **Récipe**
para la farmacia y una hoja **Indicaciones** para el paciente, cada una con el
membrete, el paciente, la firma y los datos del consultorio. Se genera en el
navegador (`src/recipe/pdf.ts`) y se guarda en el bucket, así lo que se reenvía
es siempre el mismo documento.
