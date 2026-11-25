# Helios — reglas para trabajar en este repo

Pagos en cuotas para consultas y tratamientos de salud privada en Venezuela
(medicina, odontología y cosmetología), **solo web**, operado por **Quarto
Latam, C.A.** Es un fork de Ronda (`C:\Users\Javie\Documents\Work\Ronda`): el
panel sale de `Ronda-panel/` y la base de `Ronda-app/supabase/`. Ante una duda
de comportamiento, mira primero cómo lo resuelve Ronda.

## Dónde está cada cosa

| Tema | Documento |
|---|---|
| Reglas del negocio con fechas y por qué | `docs/REGLAS-DEL-NEGOCIO.md` |
| Estado del trabajo y pendientes | `docs/ESTADO.md` |
| Plan maestro y decisiones (1.400 líneas) | `docs/00-PLAN-DE-IMPLEMENTACION.md` |
| Contrato de las RPC (2.500 líneas) | `docs/01-CONTRATO-RPC.md` |
| SEO del sitio público | `docs/02-AUDITORIA-SEO.md` |
| Lector de comprobantes | `docs/03-LECTOR-DE-COMPROBANTES.md` |
| Directorio por WhatsApp y su prueba A/B | `docs/04-…`, `docs/06-…` |
| OpenSEO por MCP (`.mcp.json`; cada consulta cuesta) | `docs/05-OPENSEO.md` |
| La inicial del 50% | `docs/07-INICIAL-DEL-50.md` |
| Récipes digitales (`conhelios.com/rx`) | `rx/README.md` |

**docs/00 y docs/01 no se leen enteros**: busca el encabezado con
`grep -n '^#' docs/01-CONTRATO-RPC.md` (o el nombre de la RPC) y lee solo esa
sección.

```
panel/      TanStack Start + React 19 + Tailwind v4 (fork de Ronda-panel)
rx/         Récipes digitales, en prueba y sin enlaces; se publica con el panel
supabase/   config, migrations/ (1 base consolidada + migraciones de Helios), tests/, poda/
tokens/     helios.tokens.json + build.mjs → panel/src/styles/tokens.gen.css, panel/src/theme/tokens.gen.ts
scripts/    portar-de-ronda.mjs (transforma SQL de Ronda al vocabulario de Helios)
```

## El negocio (detalle e historia en `docs/REGLAS-DEL-NEGOCIO.md`)

- **Paciente**: inicial del 50% del total el día del Sí (cuota
  `sequence = 0`, orden en `awaiting_down_payment`, se anula a las 3 h sin
  pago) y 2 cuotas a los 14 y 28 días. Hasta el lanzamiento (plantilla v3 de
  Meta), 2 cuotas sin inicial. Se decide por orden
  (`charges.down_payment_pct`). `/consultas` no se toca («$15 de inicial»).
- **Comisión Helios 12% + IVA 16%** sobre la comisión (`consumer_fee_pct`,
  `vat_pct`): $100 → total $113,92 → inicial $56,96 + 2 × $28,48.
- **Límite de $150** (nivel 1; los otros niveles están apagados: nunca decir
  que el límite «crece»). Las frases de nivel son una excepción aprobada:
  `helios_level_reminder()` / `FRASE_NIVEL`, `FRASE_SUBIR_DE_NIVEL`,
  `helios_level_up_phrase()`.
- **Médico**: cobra el 100% en dos mitades a los 8 y 15 días desde la orden,
  pague o no el paciente (`installments.settlement_due_date`, pago al día
  siguiente, a diario). La inicial no le genera pago. Sin costo ni
  permanencia. `installment_interval_days` mueve solo las cuotas del paciente.
- **Moneda**: el médico elige dólares o euros; una orden en euros queda en
  euros. El paciente **solo paga en bolívares** (Pago Móvil o transferencia).
- **Sin mora**: `late_fee_usd` = 0; el motor sigue en el código.

## Reglas no negociables (heredadas de Ronda)

- **Dinero**: `numeric(18,4)` en USD (los sufijos `_usd` son literales). VES
  `numeric(18,2)`, tasa `numeric(18,6)`. Jamás `float`.
- **Moneda del libro**: dólar BCV (libro, límite, mínimo, mora, métricas,
  superadmin). Una orden en euros se pasa a dólares con la tasa cruzada del
  día del registro (`charges.fx_usd_per_unit`) y guarda sus montos en euros en
  las columnas `_cur` (`amount_cur`, `base_cur`, `installments.amount_cur`,
  `settlements.amount_cur`…). Tasas: `exchange_rates` serie `BCV` y `BCV_EUR`. El VES
  es solo presentación y liquidación.
- **Zona horaria**: `America/Caracas`. El día operativo empieza a
  **medianoche** (`helios_business_date`), no a las 10 AM como en Ronda.
- **Libro contable**: partida doble, append-only, `idempotency_key` en toda
  mutación de dinero. La única función que crea deuda es `helios_assign_debt`.
- **A la clínica, ningún total incluye la Comisión Helios**: va solo dentro
  de las cuotas o como línea aparte, y en todo desglose del médico (panel y
  bot) seguida de **«(Lo paga el paciente)»** (`LO_PAGA_EL_PACIENTE`). **Al
  paciente sí** se le enseña el total con la comisión.
- **Al paciente se le nombra a su médico, no a la clínica**
  (`helios_doctor_ref`). Los **bolívares van solo en el bloque de pago**
  (`helios_payment_block`).
- Montos en mensajes al estilo venezolano: `helios_money_text` («$100», «$1,92», «$1.250,50»),
  `helios_money_cur_text` («€56,96»), `helios_ves_text` («Bs 55.432,10»); las
  variables de dinero de las plantillas ya traen su símbolo.
- **Seguridad en la base, no en el router**: RLS + RPC `security definer` con
  `set search_path`. El personal de la clínica **no lee** `profiles`,
  `installments` ni `payment_reports` directamente.
- **Privacidad entre clínicas**: una clínica nunca ve la deuda, la mora ni el
  motivo de "no disponible" de un paciente.
- Toda acción de admin escribe en `audit.admin_actions` (`audit.log`).
- Escrituras de admin: `helios_assert_super_admin()` / `is_platform_admin()`
  (MFA). Los roles internos limitados **no** pasan `is_platform_admin()`:
  - `agenda`: `helios_puede_usar_la_agenda()` (docs/01 §2.9).
  - `capacitador`: la Agenda, `helios_puede_ver_clinicas()` y
    `helios_assert_puede_afiliar()` (docs/01 §2.14).
  - `cobranza`: `helios_puede_cobrar()` (docs/01 §2.20).

## Nombres

- La base **conserva los nombres de dominio de Ronda** (`profiles`,
  `merchants`, `charges`, `installments`, `settlements`, `merchant_users`…);
  solo cambia el prefijo `ronda_` → `helios_`, para portar arreglos con
  `scripts/portar-de-ronda.mjs`.
- **La clínica se llama como su médico titular**: `merchants.name` lo arma un
  trigger («Dra. Ana Lara»); el consultorio va en `merchants.consultorio`. En
  tablas y filtros, el médico va primero.
- Vocabulario médico: médico, centro o clínica, sede, paciente, **pago en
  cuotas** (u «orden»), **Comisión Helios** (al paciente: «comisión de
  servicio»), secretaria (rol `cajero`), administrador (rol `gerente`).
- **Prohibido en todo lo externo** (portada, panel de la clínica, bot,
  WhatsApp, correos, errores que ve una clínica): «préstamo»,
  «financiamiento», «financiar», «crédito», «fee». Tampoco se publica que no
  se verifica la identidad del paciente, quién firma los contratos ni
  detalles internos del equipo. El superadmin y los identificadores de la base
  (`charges`, `comprobante_financiamiento`, `/financiamientos`) conservan sus
  nombres.
- Código, comentarios, migraciones y textos **en español**. Migraciones:
  `YYYYMMDDHHMMSS_el_paciente_no_tiene_cuenta.sql`.

## Comandos

**Sin Docker.** Todo se aplica y se prueba en el proyecto remoto `Helios`, que
**es producción**, vía Management API:

```bash
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb "select 1"
supabase db query --linked --project-ref ahyfbnfsbyzdoyjzjvfb -f ruta.sql
node supabase/poda/aplicar.mjs        # migraciones pendientes (registra la historia)
bash supabase/tests/run.sh            # suites SQL (begin/rollback)
node scripts/verificar-contrato.mjs   # ¿cada RPC del panel existe con esos parámetros?
cd panel && npm run dev               # http://localhost:3000 (datos reales)
npm run build && npm run lint && npx tsc --noEmit
```

## Remotos

- **Supabase** `Helios` (`ahyfbnfsbyzdoyjzjvfb`, org de Ronda): **PRODUCCIÓN**
  y único proyecto por ahora.
  - Las suites hacen `begin`/`rollback` y `_ayudas.sql` apaga la
    configuración real (contacto, cuentas de cobro, confirmación, mora). Una
    suite nueva que llame a `helios_dispatch_*` sin sustituir antes la función
    de HTTP **manda mensajes reales**: la extensión `http` no se deshace con
    el `rollback`.
  - Nada de SQL suelto que escriba en tablas reales sin que lo pida Javier.
  - `panel/.env` apunta a esta base.
  - Nunca escribir en los proyectos de Ronda.
- **Vercel**: proyecto `helios` (`jcarvajal3s-projects`), raíz `panel/`.
  Despliega solo al pushear a `main`; nunca `vercel deploy` a mano. Dominio
  `conhelios.com`.
- **Edge Function** `whatsapp-webhook`: no la despliega Vercel; se despliega
  con el comando de su `index.ts` (sin JWT: la protege `?token=`).
- **GitHub**: `https://github.com/Jcarvajal3/Helios.git`.
