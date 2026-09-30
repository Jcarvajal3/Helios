-- ============================================================================
-- Ronda — El IVA lo pone el comercio, y al comercio no se le cobra nada
--
-- Regla del 2026-08-30. Cambian las dos mitades de la cuenta a la vez:
--
--   1. **El IVA de la venta deja de calcularse aquí.** El comercio ya lo
--      incluye en el precio de sus productos, así que lo que teclea el cajero
--      LO LLEVA DENTRO. Ronda no vuelve a sumarle un 16% encima.
--   2. **Ronda deja de cobrarle un fee al comercio.** Al comercio le entra el
--      coste total de sus productos, íntegro. El único ingreso de Ronda es el
--      fee del consumidor, y el único IVA que declara es el de ese fee.
--
-- ---------------------------------------------------------------------------
-- La orden, con la cifra que teclea el cajero en 100
-- ---------------------------------------------------------------------------
--     Producto (IVA del comercio ya dentro) ... 100,00   ← lo que teclea
--     + Fee del servicio (10%) ................  10,00
--     + IVA del fee (16%) .....................   1,60
--     ──────────────────────────────────────────────────
--     LO QUE VE Y DEBE EL USUARIO ............. 111,60   → 2 cuotas de 55,80
--
--     AL COMERCIO ............................. 100,00   íntegro, sin descuento
--     ingreso propio de Ronda .................  10,00   ← base de IAE y LOCTI
--     IVA que Ronda declara ...................   1,60
--
--     100,00 + 10,00 + 1,60 = 111,60
--
-- ---------------------------------------------------------------------------
-- Lo que NO cambia
-- ---------------------------------------------------------------------------
-- **La vía del Art. 10 de la LIVA sigue en pie** (docs/00-BASES §2.11): Ronda
-- sigue siendo mandatario del comercio y sigue reconociendo como ingreso solo
-- su comisión. Lo que cambia es de dónde sale el IVA de la venta —ahora lo
-- repercute el comercio dentro de su propio precio— y que la comisión al
-- comercio pasa a ser cero. La base de IAE y LOCTI baja de 20,00 a 10,00.
--
-- **El asiento sigue teniendo tres patas** y no hubo que tocarlo: se deriva de
-- las columnas guardadas del cobro (20260829080000), y con el fee del comercio
-- en cero la pata de `merchant_payable` recibe la base entera:
--
--     Dr user_receivable   111,60
--       Cr merchant_payable        100,00
--       Cr platform_revenue         10,00
--       Cr vat_payable               1,60
--
-- **El desglose se sigue guardando en el cobro y no se recalcula.** Es lo que
-- permite reimprimir dentro de dos años una orden emitida hoy con los números
-- de hoy — justo lo que hace falta cuando los porcentajes cambian tres veces en
-- un mes, como acaba de pasar.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El desglose
-- ---------------------------------------------------------------------------
/**
 * Se conserva la FIRMA —y todas las claves del jsonb— a propósito.
 *
 * La llaman los seis caminos de cobro, el asiento contable y el panel. Cambiar
 * el cuerpo los pasa a todos a la regla nueva a la vez y ninguno puede quedarse
 * con la vieja; cambiar la forma habría obligado a tocarlos uno por uno, que es
 * exactamente como se queda uno atrás.
 *
 * `p_merchant_fee_pct` sigue entrando por parámetro aunque hoy valga 0 en todos
 * los comercios: es una condición negociable local a local
 * (`merchant_settlement_terms.commission_pct`), y borrar la mecánica para
 * volver a escribirla el día que alguien negocie un fee cuesta más que dejar
 * pasar un cero por aquí.
 */
create or replace function public.helios_charge_breakdown(
  p_base_usd          numeric,
  p_merchant_fee_pct  numeric
)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_vat_pct  numeric := public.helios_vat_pct();
  v_cfee_pct numeric := public.helios_consumer_fee_pct();
  v_base     numeric(18,4) := round(p_base_usd, 2);
  v_cfee     numeric(18,4);
  v_cfee_vat numeric(18,4);
  v_mfee     numeric(18,4);
  v_mfee_vat numeric(18,4);
begin
  -- El IVA de la VENTA ya no se calcula: viene dentro de `v_base` porque lo
  -- repercute el comercio en su propio precio. Calcularlo aquí lo cobraría dos
  -- veces, una en el precio del producto y otra encima.
  v_cfee     := round(v_base * v_cfee_pct / 100, 2);
  v_cfee_vat := round(v_cfee * v_vat_pct / 100, 2);
  v_mfee     := round(v_base * p_merchant_fee_pct / 100, 2);
  v_mfee_vat := round(v_mfee * v_vat_pct / 100, 2);

  return jsonb_build_object(
    'base_usd',             v_base,
    -- Se conserva la alícuota porque es la que se le aplica al fee, y es la que
    -- hay que estampar en la factura junto a esos 1,60.
    'vat_pct',              v_vat_pct,
    -- CERO desde el 2026-08-30, y no por descuido: el IVA de la venta lo
    -- declara el comercio, no Ronda.
    'vat_usd',              0::numeric(18,4),
    'consumer_fee_pct',     v_cfee_pct,
    'consumer_fee_usd',     v_cfee,
    'consumer_fee_vat_usd', v_cfee_vat,
    -- Lo que debe el usuario. Es lo único que se le enseña como total.
    'consumer_total_usd',   v_base + v_cfee + v_cfee_vat,
    -- La venta del comercio, que es lo que va en la factura por cuenta de
    -- terceros. Con el IVA dentro, es la base tal cual.
    'merchant_gross_usd',   v_base,
    'merchant_fee_pct',     p_merchant_fee_pct,
    'merchant_fee_usd',     v_mfee,
    'merchant_fee_vat_usd', v_mfee_vat,
    -- Lo que se le paga al comercio. Con fee 0, la base entera.
    'merchant_net_usd',     v_base - v_mfee - v_mfee_vat,
    -- Ingreso propio de Ronda: base imponible de IAE y LOCTI.
    'revenue_usd',          v_cfee + v_mfee,
    -- IVA que Ronda declara como débito fiscal. NO es ingreso.
    'vat_payable_usd',      v_cfee_vat + v_mfee_vat
  );
end;
$$;

revoke all on function public.helios_charge_breakdown(numeric, numeric) from public, anon;
grant execute on function public.helios_charge_breakdown(numeric, numeric) to authenticated;

comment on function public.helios_charge_breakdown(numeric, numeric) is
  'Todo lo que se deriva de lo que teclea el cajero. Desde 2026-08-30 esa cifra YA lleva dentro el IVA del comercio, y solo se le suman el fee del consumidor y el IVA de ese fee. Ver docs/00-BASES 2.11.';

-- Las columnas siguen ahí y siguen significando lo mismo; lo que cambia es qué
-- valor traen los cobros nuevos. Los viejos conservan su IVA real, y por eso el
-- comentario fecha el cambio en vez de decir "siempre 0".
comment on column public.charges.vat_usd is
  'IVA de la venta calculado por Helios. CERO en los cobros desde 2026-08-30: el comercio lo incluye en el precio de sus productos y lo declara él. Los cobros anteriores conservan el que se les aplicó.';
comment on column public.charges.base_usd is
  'Lo que teclea el cajero. Desde 2026-08-30 lleva DENTRO el IVA del comercio, y es también lo que se le paga a él.';
comment on column public.charges.merchant_fee_usd is
  'Servicio tecnológico que Helios le factura al comercio. CERO desde 2026-08-30: al comercio le entra el coste total de sus productos. Se conserva la mecánica por si un comercio negocia uno.';

-- ---------------------------------------------------------------------------
-- 2. Al comercio no se le cobra fee
-- ---------------------------------------------------------------------------
-- A TODOS los comercios, no solo a los que estaban en el valor por defecto:
-- esto no es un default nuevo, es que Ronda dejó de cobrarle al comercio. Uno
-- con fee negociado tampoco lo paga ya.
update public.merchant_settlement_terms
set commission_pct = 0, updated_at = now()
where commission_pct <> 0;

alter table public.merchant_settlement_terms
  alter column commission_pct set default 0;

comment on column public.merchant_settlement_terms.commission_pct is
  'Servicio tecnológico como % de la base. 0 desde 2026-08-30: Helios ya no le cobra al comercio. Sigue siendo parametrizable por si vuelve a negociarse.';

-- ---------------------------------------------------------------------------
-- 3. Al comercio se le puede pagar cualquier día
-- ---------------------------------------------------------------------------
/**
 * PENDIENTE DE CONFIRMAR (2026-08-30) — el reparto en tramos queda inerte, no
 * borrado.
 *
 * Lo confirmado es que **las fechas dejan de ser fijas**: al comercio se le
 * puede pagar cualquier día. Lo que no se ha confirmado es si sobrevive algo
 * del calendario 30/35/35, así que se elige lo que menos promete:
 *
 *     upfront_pct = 100 · per_installment_pct = 0
 *
 * Con eso la obligación entera nace en el momento de la venta, en una sola fila
 * de `settlements` que ninguna fecha ata, y el operador transfiere cuando
 * quiera desde /admin/pagos-comercios. Es la traducción literal de "se le puede
 * pagar en cualquier fecha".
 *
 * **Por qué inerte y no borrado.** `run_scheduled_settlements` y el tramo por
 * cuota siguen en el esquema y funcionando. Con `per_installment_pct = 0` el
 * cron no encola nada —ya se salta los importes en cero desde 20260829030000—,
 * así que volver a un calendario por fechas el día que se confirme otra cosa es
 * un UPDATE de una fila, no una migración. Borrar el motor para reescribirlo en
 * dos semanas sería el peor de los dos caminos.
 *
 * El check `settlement_splits_net` se cumple sin tocarlo: 100 + (0 * 2) = 100.
 *
 * Se acota a los comercios que están en las condiciones POR DEFECTO. A uno con
 * condiciones negociadas no se le cambia el calendario de pago desde una
 * migración: eso son los términos de un contrato.
 */
update public.merchant_settlement_terms
set upfront_pct = 100.00, per_installment_pct = 0, updated_at = now()
where upfront_pct = 30.00 and per_installment_pct = 35.00;

alter table public.merchant_settlement_terms
  alter column upfront_pct set default 100.00,
  alter column per_installment_pct set default 0;

comment on column public.merchant_settlement_terms.upfront_pct is
  '% del neto que se devenga al vender. 100 desde 2026-08-30 (PENDIENTE DE CONFIRMAR): sin fechas fijas, la obligación entera nace con la venta.';
comment on column public.merchant_settlement_terms.per_installment_pct is
  '% del neto que se devenga en la fecha de cada cuota. 0 desde 2026-08-30 (PENDIENTE DE CONFIRMAR): el calendario por fechas queda inerte, no borrado.';

comment on function public.run_scheduled_settlements(date) is
  'Cron de liquidación por fecha de cuota. Con per_installment_pct = 0 —el valor por defecto desde 2026-08-30— no encola nada: el motor sigue vivo por si se vuelve a un calendario con fechas. Ver docs/00-BASES 2.5.';
