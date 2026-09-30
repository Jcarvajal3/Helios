// Prueba de integración de la facturación por cuenta de terceros.
//
// 🔁 REESCRITA el 2026-08-30. Hasta entonces replicaba el ejemplo del memo de
// SC Moreno, Díaz y Asociados (26-ago-2026) tal cual: Helios calculaba el IVA de
// la venta y le cobraba un servicio tecnológico al comercio, así que de una base
// de 100 salían 127,60 para el consumidor y 104,40 para el local.
//
// Desde `20260830140000_el_iva_lo_pone_el_comercio` la cuenta tiene dos patas
// menos: el comercio incluye su IVA en el precio y ya no paga fee. La vía del
// Art. 10 sigue en pie —Helios solo reconoce como ingreso su comisión—, pero esa
// comisión ahora es una sola.
//
// 🔁 Y desde `20260902100000_el_fee_del_servicio_sube_al_20` esa comisión es del
// 20%: de 100 tecleados salen 123,20 para el consumidor y 100,00 íntegros para
// el local.
//
// Corre dentro de una transacción que SIEMPRE se revierte.
//
//   SUPABASE_DB_URL=postgresql://... node supabase/tests/facturacion.test.mjs
import pg from 'pg';

const c = new pg.Client({
  connectionString: process.env.SUPABASE_DB_URL,
  ssl: { rejectUnauthorized: false },
});

/** Ejecuta como un usuario concreto: es lo que hace que `auth.uid()` responda. */
async function as(userId, sql, params = []) {
  await c.query(`select set_config('request.jwt.claims', $1, true)`, [
    JSON.stringify({ sub: userId, role: 'authenticated' }),
  ]);
  await c.query(`select set_config('role', 'authenticated', true)`);
  const r = await c.query(sql, params);
  await c.query(`reset role`);
  return r;
}

let failures = 0;
const check = (label, cond, extra = '') => {
  if (!cond) failures++;
  console.log(`${cond ? '✅' : '❌'} ${label}${extra ? '  ' + extra : ''}`);
};
const money = (n) => Number(n).toFixed(2);
const eq = (a, b) => Math.abs(Number(a) - Number(b)) < 0.005;

await c.connect();
await c.query("set statement_timeout = '20s'");
await c.query('begin');

try {
  // ── Un usuario con cupo de sobra y un comercio con las condiciones nuevas ──
  const { rows: [u] } = await c.query(
    `insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
       email_confirmed_at, created_at, updated_at)
     values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
       'authenticated', 'fact@helios.test', '', now(), now(), now())
     returning id`);
  await c.query(
    `insert into public.profiles (id, phone_e164, full_name, status, level)
     values ($1, '+584121234567', 'Facturación', 'active', 3)`, [u.id]);
  await as(u.id, `select public.set_user_pin('5837')`);
  // Nivel 3 son €80 de límite y el total con el fee son €123,20: no cabe. Se
  // sube el nivel a €500 para que lo que falle aquí sea la facturación y no el
  // cupo, que ya tiene su propia prueba.
  await c.query(`update public.levels set monthly_limit_usd = 500 where level = 3`);

  const { rows: [m] } = await c.query(
    `insert into public.merchants (name, status) values ('Bar del memo', 'active') returning id`);
  const { rows: [b] } = await c.query(
    `insert into public.merchant_branches (merchant_id, name) values ($1, 'Barra') returning id`, [m.id]);
  const { rows: [staff] } = await c.query(
    `insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
       email_confirmed_at, created_at, updated_at)
     values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated',
       'authenticated', 'cajero@helios.test', '', now(), now(), now())
     returning id`);
  await c.query(
    `insert into public.merchant_users (merchant_id, user_id, role, is_active)
     values ($1, $2, 'gerente', true)`, [m.id, staff.id]);

  const { rows: [t] } = await c.query(
    `select upfront_pct::float u, per_installment_pct::float p, commission_pct::float k
     from public.merchant_settlement_terms where merchant_id = $1`, [m.id]);
  check('El comercio nace sin fee y cobrando media venta por cuota',
    eq(t.u, 0) && eq(t.p, 50) && eq(t.k, 0), `${t.u} / ${t.p} / ${t.k}`);

  // ── El cajero teclea 100, con el IVA del comercio ya dentro ──────────────
  const { rows: [ch] } = await as(staff.id,
    `select * from public.request_charge($1, $2,
       '[{"name":"Consumo","unit_price_usd":100,"quantity":1}]'::jsonb, $3)`,
    [m.id, b.id, 'memo-' + Date.now()]);

  check('Producto (IVA del comercio dentro) = 100,00', eq(ch.base_usd, 100), `$${money(ch.base_usd)}`);
  check('Helios NO calcula IVA de la venta = 0,00', eq(ch.vat_usd, 0), `$${money(ch.vat_usd)}`);
  check('Fee del servicio (20%) = 20,00', eq(ch.consumer_fee_usd, 20), `$${money(ch.consumer_fee_usd)}`);
  check('IVA del fee (16%) = 3,20', eq(ch.consumer_fee_vat_usd, 3.2), `$${money(ch.consumer_fee_vat_usd)}`);
  check('LO QUE DEBE EL USUARIO = 123,20', eq(ch.amount_usd, 123.2), `$${money(ch.amount_usd)}`);
  check('Al comercio no se le cobra nada',
    eq(ch.merchant_fee_usd, 0) && eq(ch.merchant_fee_vat_usd, 0),
    `$${money(ch.merchant_fee_usd)} + $${money(ch.merchant_fee_vat_usd)}`);
  check('AL COMERCIO = 100,00, el coste total de sus productos',
    eq(ch.merchant_net_usd, 100), `$${money(ch.merchant_net_usd)}`);

  // ── El usuario paga ──────────────────────────────────────────────────────
  const { rows: [res] } = await as(u.id,
    `select public.confirm_charge($1, $2, '5837') as r`, [ch.id, 'memo-key-' + ch.id]);
  check('El cobro sale', res.r.ok === true);

  const { rows: cuotas } = await c.query(
    `select sequence, amount_usd::float a, due_date from public.installments
     where charge_id = $1 order by sequence`, [ch.id]);
  check('Dos cuotas de 61,60', cuotas.length === 2 && eq(cuotas[0].a, 61.6) && eq(cuotas[1].a, 61.6),
    cuotas.map((q) => `$${money(q.a)}`).join(' + '));

  // Semanales desde 20260830150000: 7 y 14 días desde el día operativo.
  const { rows: [bd] } = await c.query(
    `select business_date from public.charges where id = $1`, [ch.id]);
  const dias = (d) => Math.round((new Date(d) - new Date(bd.business_date)) / 86400000);
  check('Vencen a los 7 y a los 14 días',
    dias(cuotas[0].due_date) === 7 && dias(cuotas[1].due_date) === 14,
    `${dias(cuotas[0].due_date)} y ${dias(cuotas[1].due_date)} días`);

  // ── El asiento, en tres patas ────────────────────────────────────────────
  const { rows: asiento } = await c.query(
    `select a.account_type::text tipo, (e.credit - e.debit)::float importe
     from ledger.entries e
     join ledger.accounts a on a.id = e.account_id
     join ledger.transactions t on t.id = e.transaction_id
     where t.reference_id = $1 and t.type = 'charge'
     order by 1`, [ch.id]);
  const pata = (tipo) => asiento.find((x) => x.tipo === tipo)?.importe ?? 0;

  check('Debe: el consumidor debe 123,20', eq(-pata('user_receivable'), 123.2),
    `$${money(-pata('user_receivable'))}`);
  check('Haber: al comercio 100,00', eq(pata('merchant_payable'), 100),
    `$${money(pata('merchant_payable'))}`);
  check('Haber: ingreso de Helios 20,00 — el fee, SIN el IVA',
    eq(pata('platform_revenue'), 20), `$${money(pata('platform_revenue'))}`);
  check('Haber: IVA que Helios declara 3,20', eq(pata('vat_payable'), 3.2),
    `$${money(pata('vat_payable'))}`);
  check('El asiento cuadra',
    eq(asiento.reduce((s, x) => s + x.importe, 0), 0));

  // ── Lo que se le paga al comercio ────────────────────────────────────────
  // Nada al vender: desde 20260902120000 el comercio devenga media venta en la
  // fecha de cada cuota, y cobra lo devengado en el cierre del lunes siguiente.
  const { rows: alVender } = await c.query(
    `select 1 from public.settlements where charge_id = $1`, [ch.id]);
  check('Vender no encola nada: se cobra por fecha de cuota', alVender.length === 0,
    `${alVender.length} filas`);

  for (const q of cuotas) {
    await c.query(`select public.run_scheduled_settlements($1::date)`, [q.due_date]);
  }
  const { rows: pagos } = await c.query(
    `select reason::text r, amount_usd::float a from public.settlements
     where charge_id = $1 order by created_at`, [ch.id]);
  const total = pagos.reduce((s, x) => s + x.a, 0);

  check('Dos tramos por fecha de cuota, de 50,00 cada uno',
    pagos.length === 2 && pagos.every((x) => x.r === 'scheduled_installment' && eq(x.a, 50)),
    pagos.map((x) => `${x.r} $${money(x.a)}`).join(' + '));
  check('Al comercio se le debe su neto entero: 100,00', eq(total, 100), `$${money(total)}`);

  // El techo: correr el cron otra vez no puede pasar del neto del consumo.
  for (const q of cuotas) {
    await c.query(`select public.run_scheduled_settlements($1::date)`, [q.due_date]);
  }
  const { rows: [tope] } = await c.query(
    `select coalesce(sum(amount_usd), 0)::float a from public.settlements where charge_id = $1`,
    [ch.id]);
  check('Por un consumo nunca se devenga más que su neto', eq(tope.a, 100), `$${money(tope.a)}`);

  // ── La identidad que sostiene todo ───────────────────────────────────────
  check('100,00 + 20,00 + 3,20 = 123,20',
    eq(Number(ch.merchant_net_usd) + pata('platform_revenue') + pata('vat_payable'), ch.amount_usd));
} finally {
  await c.query('rollback');
  await c.end();
}

console.log(failures === 0
  ? '\n✅ la facturación cuadra, céntimo a céntimo'
  : `\n❌ ${failures} comprobaciones fallidas`);
process.exit(failures === 0 ? 0 : 1);
