# Helios — reglas para trabajar en este repo

BNPL para consultas médicas en Venezuela, **solo web**. Es un fork de Ronda
(`C:\Users\Javie\Documents\Work\Ronda`): el panel sale de `Ronda-panel/` y la
base de `Ronda-app/supabase/`. Ante cualquier duda de comportamiento, mira
primero cómo lo resuelve Ronda y reutilízalo.

- Plan maestro y decisiones: `docs/00-PLAN-DE-IMPLEMENTACION.md`.
- Contrato de las RPC nuevas: `docs/01-CONTRATO-RPC.md`.

## Estructura

```
panel/      TanStack Start + React 19 + Tailwind v4 (fork de Ronda-panel)
supabase/   config, migrations/ (1 base consolidada + migraciones de Helios), tests/, poda/
tokens/     helios.tokens.json + build.mjs → panel/src/styles/tokens.gen.css, panel/src/theme/tokens.gen.ts
scripts/    portar-de-ronda.mjs (transforma SQL de Ronda al vocabulario de Helios)
docs/       plan, contrato, reglas
```

## Reglas no negociables (heredadas de Ronda)

- **Dinero**: `numeric(18,4)` en USD (los sufijos `_usd` son literales). VES
  `numeric(18,2)`, tasa `numeric(18,6)`. Jamás `float`.
- **Moneda**: dólar BCV. El VES es solo presentación y liquidación.
- **Zona horaria**: `America/Caracas` siempre. El día operativo empieza a
  **medianoche** (`helios_business_date`), no a las 10 AM como en Ronda.
- **Libro contable**: partida doble, append-only, `idempotency_key` en toda
  mutación de dinero. La única función que crea deuda es `helios_assign_debt`.
- **Ningún total mostrado incluye el fee de Helios.** El fee (20% + IVA)
  aparece solo dentro de las cuotas o como línea aparte en un desglose. La
  clínica ve solo montos sin fee.
- **Seguridad en la base, no en el router**: RLS + RPC `security definer` con
  `set search_path`. El personal de la clínica **no lee** `profiles`,
  `installments` ni `payment_reports` directamente.
- **Privacidad entre clínicas**: una clínica nunca ve la deuda, la mora ni el
  motivo de "no disponible" de un paciente.
- Toda acción de admin escribe en `audit.admin_actions` (`audit.log`).
- Escrituras de admin pasan por `helios_assert_super_admin()` / `is_platform_admin()` (MFA).

## Nombres

- La base **conserva los nombres de dominio de Ronda** (`profiles`, `merchants`,
  `charges`, `installments`, `settlements`, `merchant_users`…). Solo el prefijo
  de marca cambia: `ronda_` → `helios_`. Así los arreglos de Ronda se portan
  con `scripts/portar-de-ronda.mjs`.
- La interfaz habla en vocabulario médico: clínica, sede, paciente,
  financiamiento, secretaria (rol `cajero`), administrador (rol `gerente`).
- Código, comentarios, migraciones y textos: **en español**, como en Ronda.
  Migraciones con nombre descriptivo: `YYYYMMDDHHMMSS_el_paciente_no_tiene_cuenta.sql`.

## Comandos

**Sin Docker** (decisión del usuario, 2026-09-30). Todo se aplica y se prueba
directamente en el proyecto remoto `Helios`, vía Management API:

```bash
# SQL suelto o un fichero contra Helios
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb "select 1"
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb -f ruta.sql

# Aplicar migraciones pendientes (runner propio, registra la historia)
node supabase/poda/aplicar.mjs

# Suites SQL (cada una hace begin/rollback: no dejan datos)
bash supabase/tests/run.sh

# Panel
cd panel && npm run dev           # http://localhost:3000
npm run build && npm run lint && npx tsc --noEmit
```

## Remotos

- Supabase: proyecto `Helios` (`ahyfbnfsbyzdoyjzjvfb`, org de Ronda). Hoy es
  el **único** proyecto y hace de entorno de desarrollo: el usuario autorizó
  migrar y probar ahí. Antes de tener pacientes reales habrá que separar
  producción. Nunca escribir en los proyectos de Ronda.
- GitHub: `https://github.com/Jcarvajal3/Helios.git`.
