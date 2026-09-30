# Helios · Panel

Panel web de Helios, el BNPL para consultas médicas. Dos caras que comparten
login y base de datos:

- **Clínica** (`/registrar`, `/financiamientos`, …): la recepción registra
  financiamientos; el administrador ve además métricas, pagos y personal.
- **Super admin** (`/admin`): el equipo de Helios cobra, concilia, paga a las
  clínicas y lleva la contabilidad.

El login reparte a cada quien según sea personal de una clínica
(`merchant_users`, roles `gerente` = Administrador y `cajero` = Secretaria) o
del equipo (`platform_admins`).

Fork de `Ronda-panel` @ `13468dc` (2026-09-30). La base conserva los nombres de
dominio de Ronda (`merchants`, `charges`, `installments`…); solo cambia el
prefijo de marca de las funciones (`ronda_` → `helios_`) y el vocabulario de
la interfaz. Plan y decisiones: [`../docs/00-PLAN-DE-IMPLEMENTACION.md`](../docs/00-PLAN-DE-IMPLEMENTACION.md).

**Stack:** TanStack Start + React 19 + Tailwind 4, sin backend propio: cliente
de Supabase con clave publicable, RLS y RPC.

## Puesta en marcha

```bash
cp .env.example .env     # URL y clave publicable del proyecto (dev o local)
npm install
npm run dev              # http://localhost:3000
```

| Variable | Para qué |
|---|---|
| `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` | El proyecto de Supabase |
| `VITE_ENTORNO` | `desarrollo` pinta la pastilla DEV en el super admin |
| `VITE_SENTRY_DSN` | Opcional: errores a Sentry |
| `VITE_ASISTENTE` | `1` enciende el asistente de IA (fase 5; apagado por defecto) |

## Comprobaciones

```bash
npx tsr generate         # regenera src/routeTree.gen.ts
npx tsc --noEmit
npm run lint
npm run build
npx tsx src/<ruta>.test.ts   # las pruebas son scripts sueltos, una por módulo
```

## Marca

Los tokens salen de [`../tokens/helios.tokens.json`](../tokens/helios.tokens.json):
`npm run tokens` regenera `src/styles/tokens.gen.css` y
`src/theme/tokens.gen.ts` y comprueba el contraste AA. Tema claro por defecto;
el oscuro se elige en el pie del menú. Logo e isotipo en
`src/components/HeliosLogo.tsx`, sacados de `../brand/helios-logo.svg`.

## Qué falta (por fase)

- **Fase 2 (hecha en el panel):** `/registrar`, `/financiamientos` (+ ficha
  con reenviar comprobante), `/comisiones`, `/pagos` partido en consultas y
  comisiones, y `/metricas` en vocabulario médico. Se programó contra
  `docs/01-CONTRATO-RPC.md` §1: la capa tipada vive en
  `src/features/merchant/` (lectores puros con sus `*.test.ts` y un
  `*Api.ts` por pantalla). Falta probarla de punta a punta contra la base
  con las RPC de la fase 1.
- **Fase 3:** «Avisos de hoy» en `/admin/avisos`, registrar pagos, alertas de
  H10, y la poda de textos de métricas y del catálogo del super admin que
  todavía hablan de la app de Ronda.
- **Fase 4:** `/soporte` y `/legal/privacidad` son marcadores sin razón social.
