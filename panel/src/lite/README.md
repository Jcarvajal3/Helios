# Helios Lite

La segunda versión del superadmin, con el diseño y la estructura de la maqueta
del rediseño (noviembre de 2026). Se elige con el interruptor **Pro / Lite** de
arriba del menú; la elección se guarda en el navegador (`version.ts`). No es un
permiso: la seguridad sigue en la base.

Lite usa las rutas de Pro. Cada ruta elige su pantalla con `conLite(Pro, Lite)`
(`espacio.tsx`): la de Lite si Lite está elegido y quien mira es super admin u
operador; si no, la de Pro. El rol de la agenda y el capacitador no tienen Lite.

Si la dirección trae parámetros que la pantalla de Lite no lee (`?asignar=` un
abono, `?clinica=` en Seguimiento, `?medico=` en el Directorio…), se abre la de
Pro con esa acción, dentro del marco de Lite: así «Asignar», «Ver semana» o
«Abrir caso» siguen llevando a donde se trabaja.

Las fichas (`/admin/pacientes/$id`, `/admin/clinicas/$id`, `/admin/cobros/$id`…)
y la bandeja de WhatsApp son las de Pro, con el vestido de Lite: allí están las
acciones (desactivar un paciente, pausar un médico, aprobar un pago…).

## Qué hay aquí

| Fichero | Qué es |
|---|---|
| `version.ts` | La versión elegida (`pro` o `lite`), en localStorage. |
| `InterruptorDeVersion.tsx` | El interruptor Pro / Lite. Se viste de cada versión. |
| `menu.ts` | Las secciones de Lite y sus pestañas (rutas de Pro). |
| `MarcoLite.tsx` | El marco: barra de iconos, cápsula de Helios Intelligence, cabecera y pestañas de cada sección. |
| `kit.tsx` | Piezas comunes: cabecera, vistas en píldoras, franja de cifras, periodo, barritas. |
| `espacio.tsx` | El espacio de trabajo de la maqueta (vistas, buscador, filtro de estado, CSV, tabla) y `conLite`. |
| `ResumenLite.tsx` | El Resumen (`/admin`). |
| `OperacionesLite.tsx` | Pagos reportados, Por cobrar, Pagos a médicos, Contabilidad y Alertas. |
| `PersonasLite.tsx` | Médicos y centros, Pacientes, Órdenes y Seguimiento. |
| `ClicsLite.tsx` | Clics por médico (Ads): el directorio con su interruptor de publicar. |
| `ResultadosLite.tsx` | «Cobranza y caja» (`/admin/metricas` sin `vista`). |
| `MetricasOriginalesLite.tsx` | Las Métricas de Pro (`?vista=…`) desde «Más vistas del admin original». |
| `AgendaLite.tsx` | La Agenda; «Abrir contacto» abre la ficha del médico de Pro. |
| `MensajesLite.tsx` | Avisos de hoy, Correos y Plantillas (con el editor de las de cobranza). |
| `AjustesLite.tsx` | Los temas de Ajustes agrupados; dentro, el ajuste de Pro. |
| `estilos/maqueta.css` | El sistema de diseño de la maqueta: tokens `--lt-*` y clases `lt-*`. |
| `estilos/vestido.css` | Cómo se ven las pantallas de Pro dentro de Lite (redefine tokens del panel solo con Lite en pantalla). |

## Cómo se aísla el estilo

- Todo el CSS de Lite cuelga de `:root[data-helios-lite]`. Ese atributo lo
  pone `MarcoLite` al montarse y lo quita al desmontarse: con Pro en
  pantalla, no aplica ni una regla.
- Los componentes de Lite usan solo clases `lt-*` de `estilos/maqueta.css`,
  no las utilidades ni los tokens del panel.
- Ningún fichero de fuera importa los estilos de Lite: los carga `MarcoLite`.

## Cómo quitar Lite

1. Borrar esta carpeta (`panel/src/lite/`).
2. `panel/src/routes/admin.tsx`: quitar los imports de `@/lite/…`, el bloque
   `if (version === 'lite') { … }` y la prop `cabeceraDelMenu` de
   `<PanelShell>`.
3. `panel/src/routes/admin/index.tsx`: quitar los imports de `@/lite/…` y
   volver a `component: InicioPage` (borrando `PortadaDelAdmin`).
4. `panel/src/routes/admin/metricas.tsx`: quitar los imports de `@/lite/…` y
   volver a `component: MetricasPage` (borrando `PaginaDeMetricas`).
5. En las rutas que usan `conLite` (agenda, alertas, avisos, clinicas,
   cobranza, cobros, contabilidad, directorio, financiamientos, pacientes,
   pagos-clinicas, seguimiento y ajustes): quitar los imports de `@/lite/…` y
   dejar en `component:` la pantalla de Pro, que es la primera de
   `conLite(…)`. En ajustes, `AjustesLitePage` se puede borrar. Al terminar,
   buscar `@/lite` en `panel/src`: no debe quedar ninguno.
6. Opcional: la prop `cabeceraDelMenu` de `PanelShell` y `cabecera` de
   `Sidebar` quedan sin uso; se pueden quitar o dejar (no pintan nada). El
   `: JSX.Element` de `AgendaPage` y `AlertasPage` también puede quedarse.

Con eso el panel vuelve a ser solo Pro. La clave `helios-admin:version` que
quede en el localStorage de cada navegador no hace nada.
