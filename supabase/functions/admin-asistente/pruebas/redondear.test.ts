import assert from 'node:assert/strict';

import { aCentimos, redondearDinero } from '../redondear.ts';

Deno.test('a céntimos, medio hacia fuera como el panel', () => {
  assert.equal(aCentimos(2.395), 2.4);
  assert.equal(aCentimos(50.264), 50.26);
  assert.equal(aCentimos(4.785), 4.79);
  assert.equal(aCentimos(-2.395), -2.4);
  assert.equal(aCentimos(1.005), 1.01);
  assert.equal(aCentimos(44), 44);
  assert.equal(aCentimos(1e-7), 0);
});

Deno.test('solo los campos de dinero, a cualquier profundidad; porcentajes y cuentas quedan igual', () => {
  const r = redondearDinero({
    total_pending_usd: 50.264,
    recovered: { usd: 2.395, installments: 1 },
    recovery_pct: 50.123,
    rows: [{ overdue_usd: 2.349, days_overdue: 14, merchant_name: 'Bar 1.5' }],
    rate: 972.648677,
  });
  assert.deepEqual(r, {
    total_pending_usd: 50.26,
    recovered: { usd: 2.4, installments: 1 },
    recovery_pct: 50.123,
    rows: [{ overdue_usd: 2.35, days_overdue: 14, merchant_name: 'Bar 1.5' }],
    rate: 972.648677,
  });
});
