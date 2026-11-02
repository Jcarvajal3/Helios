# Helios Lite

La segunda versión del superadmin, con el diseño de la maqueta del rediseño
(noviembre de 2026). Se elige con el interruptor **Pro / Lite** de arriba del
menú; la elección se guarda en el navegador (`version.ts`). No es un permiso:
la seguridad sigue en la base.

Lite usa las rutas de Pro. Tres son pantallas propias, con la estructura de
la maqueta y las mismas lecturas que Pro: el Resumen (`/admin`), Resultados
(`/admin/metricas`, «Cobranza y caja») y la Agenda (`/admin/agenda`). En las
demás pestañas se ve la pantalla de Pro, con el vestido de Lite.

## Qué hay aquí

| Fichero | Qué es |
|---|---|
| `version.ts` | La versión elegida (`pro` o `lite`), en localStorage. |
| `InterruptorDeVersion.tsx` | El interruptor Pro / Lite. Se viste de cada versión. |
| `menu.ts` | Las secciones de Lite y sus pestañas (rutas de Pro). |
| `MarcoLite.tsx` | El marco: barra de iconos, cápsula de Helios Intelligence, cabecera y pestañas de cada sección. |
| `kit.tsx` | Piezas comunes: cabecera, vistas en píldoras, franja de cifras, periodo. |
| `ResumenLite.tsx` | El Resumen (`/admin`). |
| `ResultadosLite.tsx` | «Cobranza y caja» (`/admin/metricas` sin `vista`). |
| `MetricasOriginalesLite.tsx` | Las Métricas de Pro (`?vista=…`) desde «Más vistas del admin original». |
| `AgendaLite.tsx` | La Agenda; «Abrir contacto» abre la ficha del médico de Pro. |
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
5. `panel/src/routes/admin/agenda.tsx`: quitar los imports de `@/lite/…` y
   volver a `component: AgendaPage` (borrando `PaginaDeLaAgenda`).
6. Opcional: la prop `cabeceraDelMenu` de `PanelShell` y `cabecera` de
   `Sidebar` quedan sin uso; se pueden quitar o dejar (no pintan nada).

Con eso el panel vuelve a ser solo Pro. La clave `helios-admin:version` que
quede en el localStorage de cada navegador no hace nada.
