# Helios — reglas para trabajar en este repo

Pagos en cuotas para consultas y tratamientos de salud privada en Venezuela
(medicina, odontología y cosmetología), **solo web**, operado por **Quarto
Latam, C.A.** Es un fork de Ronda
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

## El negocio, en cifras (2026-10-06)

- Paciente: **2 cuotas a los 7 y 14 días**, sin inicial. **Comisión
  Helios del 12% + IVA 16%** sobre la comisión (`consumer_fee_pct`,
  `vat_pct`): consulta de $100 → $12 + $1,92 → 2 cuotas de $56,96.
  **Límite inicial de $150** (nivel 1; los demás niveles están apagados, así
  que hacia fuera nunca se dice que el límite «crece»).
- Médico o centro: recibe el **100%** de la consulta en dos mitades, **a los
  8 y 15 días** (cada mitad, el día siguiente al vencimiento de su cuota:
  `helios_settlement_run_for(d) = d + 1`; se paga a diario, ya no los
  lunes), **pague o no el paciente**. No le cuesta nada y no hay permanencia
  (cancela con aviso previo).
- Especialidades: medicina, odontología y cosmetología.
- **Moneda de la consulta** (2026-10-07): el médico elige **dólares o euros**
  en el paso del monto (panel y bot). Una orden en euros **queda en euros**:
  el paciente paga cada cuota en bolívares a la tasa BCV del euro del día en
  que paga, y a la clínica se le paga en Bs a la tasa del euro. El paciente
  **solo paga en bolívares** (Pago Móvil o transferencia; nada de Zelle,
  USDT ni efectivo).
- **Sin cargos por mora** (2026-10-07): `late_fee_usd` = 0. El motor sigue en
  el código; para retomarlo basta poner el monto en el parámetro (los textos
  del cargo dependen de él) y reescribir el párrafo de `/legal/terminos`.

## Reglas no negociables (heredadas de Ronda)

- **Dinero**: `numeric(18,4)` en USD (los sufijos `_usd` son literales). VES
  `numeric(18,2)`, tasa `numeric(18,6)`. Jamás `float`.
- **Moneda del libro**: dólar BCV. El libro, el límite, el mínimo, la mora,
  las métricas y el superadmin van en dólares. Una orden en euros se pasa a
  dólares con la tasa cruzada del día del registro (`charges.fx_usd_per_unit`)
  y guarda sus montos en euros en las columnas `_cur` (`amount_cur`,
  `base_cur`, `installments.amount_cur`, `settlements.amount_cur`…). Tasas:
  `exchange_rates` serie `BCV` (dólar) y `BCV_EUR` (euro). El VES es solo
  presentación y liquidación.
- **Zona horaria**: `America/Caracas` siempre. El día operativo empieza a
  **medianoche** (`helios_business_date`), no a las 10 AM como en Ronda.
- **Libro contable**: partida doble, append-only, `idempotency_key` en toda
  mutación de dinero. La única función que crea deuda es `helios_assign_debt`.
- **A la clínica, ningún total incluye la Comisión Helios.** La comisión
  (12% + IVA, parámetro `consumer_fee_pct`) aparece solo dentro de las
  cuotas o como línea aparte en un desglose, y en todo desglose que ve el
  médico (panel y bot) va seguida de **«(Lo paga el paciente)»** (Javier,
  2026-10-13; `LO_PAGA_EL_PACIENTE`). La clínica ve solo montos sin
  comisión. **Al paciente sí** se le enseña el total con la comisión
  (decisión de Javier, 2026-10-06: es lo que paga).
- Los montos en los mensajes (WhatsApp, correo) van al estilo venezolano:
  `helios_money_text` → «$100», «$1,92», «$1.250,50». Con moneda:
  `helios_money_cur_text` («€56,96») y `helios_ves_text` («Bs 55.432,10»);
  las variables de dinero de las plantillas ya traen su símbolo.
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
- La interfaz habla en vocabulario médico: médico, centro o clínica, sede,
  paciente, **pago en cuotas** (u «orden» con su número), **Comisión Helios**
  (desde el 2026-10-13; los mensajes al paciente —la pregunta de WhatsApp,
  su plantilla de Meta y el comprobante— siguen diciendo «comisión de
  servicio»), secretaria (rol `cajero`), administrador (rol `gerente`).
- **Prohibido en todo lo externo** (portada, panel de la clínica, bot,
  WhatsApp, correos, errores que ve una clínica): «préstamo»,
  «financiamiento», «financiar», «crédito», «fee». Tampoco se publica que
  no se verifica la identidad del paciente, quién firma los
  contratos ni detalles internos del equipo. El superadmin (interno) y los
  identificadores de la base (`charges`, `comprobante_financiamiento`, rutas
  como `/financiamientos`) conservan sus nombres.
- Código, comentarios, migraciones y textos: **en español**, como en Ronda.
  Migraciones con nombre descriptivo: `YYYYMMDDHHMMSS_el_paciente_no_tiene_cuenta.sql`.

## Comandos

**Sin Docker** (decisión del usuario, 2026-09-30). Todo se aplica y se prueba
directamente en el proyecto remoto `Helios`, que **es producción** (ver
Remotos), vía Management API:

```bash
# SQL suelto o un fichero contra Helios
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb "select 1"
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb -f ruta.sql

# Aplicar migraciones pendientes (runner propio, registra la historia)
node supabase/poda/aplicar.mjs

# Suites SQL (cada una hace begin/rollback: no dejan datos)
bash supabase/tests/run.sh

# ¿Cada llamada RPC del panel existe en la base con esos parámetros?
node scripts/verificar-contrato.mjs

# Panel
cd panel && npm run dev           # http://localhost:3000
npm run build && npm run lint && npx tsc --noEmit
```

## Remotos

- Supabase: proyecto `Helios` (`ahyfbnfsbyzdoyjzjvfb`, org de Ronda). Desde
  el 2026-10-08 es **PRODUCCIÓN** (decisión de Javier) y sigue siendo el
  único proyecto: el de desarrollo llegará más adelante. Mientras tanto:
  - Las migraciones y las suites se siguen corriendo aquí. Las suites hacen
    `begin`/`rollback` y `_ayudas.sql` apaga dentro de su transacción la
    configuración real (contacto, cuentas de cobro, confirmación, mora); los
    envíos (Resend, 360dialog) solo se ejercen con dobles. Una suite nueva
    que llame a `helios_dispatch_*` sin sustituir antes la función de HTTP
    **manda mensajes reales**: la extensión `http` no se deshace con el
    `rollback`.
  - Nada de SQL suelto que escriba en tablas reales sin que lo pida Javier.
  - `panel/.env` apunta a esta base: `npm run dev` en local trabaja con
    datos reales.
  - Nunca escribir en los proyectos de Ronda.
- Vercel: proyecto `helios` (equipo `jcarvajal3s-projects`), raíz `panel/`.
  Despliega solo al pushear a `main`; nunca `vercel deploy` a mano. Dominio
  `conhelios.com`.
- Edge Function `whatsapp-webhook`: no la despliega Vercel. Se despliega con
  el comando de su `index.ts` (sin JWT: la protege `?token=`).
- GitHub: `https://github.com/Jcarvajal3/Helios.git`.
