import assert from 'node:assert/strict';

import { acortarNombre, enmascarar, taparCedula, taparNumerosSueltos, taparTelefono } from '../enmascarar.ts';

Deno.test('el teléfono deja el país y las tres últimas cifras', () => {
  assert.equal(taparTelefono('+584141234567'), '+58•••••••567');
  assert.equal(taparTelefono('0414-123 4567'), '••••••••567');
  assert.equal(taparTelefono('12'), '12');
});

Deno.test('la cédula deja la letra y las tres últimas cifras', () => {
  assert.equal(taparCedula('V-12345678'), 'V-•••••678');
  assert.equal(taparCedula('E12345678'), 'E•••••678');
  assert.equal(taparCedula('12345678'), '•••••678');
});

Deno.test('el nombre se queda en el primero y la inicial del apellido', () => {
  assert.equal(acortarNombre('JAVIER CARVAJAL'), 'JAVIER C.');
  assert.equal(acortarNombre('María Pérez'), 'María P.');
  assert.equal(acortarNombre('MARÍA JOSEFINA PÉREZ GÓMEZ'), 'MARÍA P.');
  assert.equal(acortarNombre('  PRUEBA   USER '), 'PRUEBA U.');
  assert.equal(acortarNombre('Cher'), 'Cher');
});

Deno.test('en un texto libre se tapan los teléfonos, las cédulas y los números largos', () => {
  assert.equal(
    taparNumerosSueltos('Llamar al 0414-123-45-67, cédula V-20111222, ref 12345678901'),
    'Llamar al ••••-•••-•5-67, cédula V-•••••222, ref ••••••••901',
  );
  // Las fechas, los montos y los números de orden no se tocan.
  assert.equal(taparNumerosSueltos('Prometió el 2026-09-25 pagar 23,50 € de la orden 1043'), 'Prometió el 2026-09-25 pagar 23,50 € de la orden 1043');
});

Deno.test('en una lista: nombres acortados y datos tapados a cualquier profundidad', () => {
  const entrada = {
    rows: [
      {
        full_name: 'MARÍA PÉREZ',
        phone_e164: '+584121112233',
        document_number: 'V-20111222',
        overdue_usd: 12.5,
        note: 'Su hermano: 04161234567',
        merchant_name: 'Bar Nocturno',
        user: { phone: '+584169998877', birth_date: '1990-01-01' },
      },
    ],
    total: 1,
  };
  assert.deepEqual(enmascarar(entrada), {
    rows: [
      {
        full_name: 'MARÍA P.',
        phone_e164: '+58•••••••233',
        document_number: 'V-•••••222',
        overdue_usd: 12.5,
        note: 'Su hermano: ••••••••567',
        merchant_name: 'Bar Nocturno',
        user: { phone: '+58•••••••877', birth_date: '(oculto)' },
      },
    ],
    total: 1,
  });
});

Deno.test('en la ficha: el nombre entero, pero el teléfono y la cédula siguen tapados', () => {
  assert.deepEqual(enmascarar({ full_name: 'MARÍA PÉREZ', phone_e164: '+584121112233', document_number: 'V-20111222' }, 'ficha'), {
    full_name: 'MARÍA PÉREZ',
    phone_e164: '+58•••••••233',
    document_number: 'V-•••••222',
  });
});

Deno.test('un nulo en un campo personal se queda nulo y no se muta la entrada', () => {
  const entrada = { phone_e164: null, document_number: null, birth_date: null, full_name: null };
  assert.deepEqual(enmascarar(entrada), entrada);
  const original = { phone_e164: '+584141234567' };
  enmascarar(original);
  assert.equal(original.phone_e164, '+584141234567');
});
