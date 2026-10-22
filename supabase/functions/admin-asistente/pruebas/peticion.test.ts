import assert from 'node:assert/strict';

import { aMensajes, leerPeticion } from '../peticion.ts';
import { construirSystem, contextoDelTurno } from '../prompt.ts';
import { leerMapa } from '../mapa.ts';

Deno.test('la petición necesita una conversación que termine en pregunta', () => {
  assert.equal(leerPeticion(null).ok, false);
  assert.equal(leerPeticion({ conversacion: [] }).ok, false);
  assert.equal(leerPeticion({ conversacion: [{ rol: 'persona', texto: 'hola' }, { rol: 'asistente', texto: 'x' }] }).ok, false);
  assert.equal(leerPeticion({ conversacion: [{ rol: 'sistema', texto: 'x' }] }).ok, false);
  const larga = leerPeticion({ conversacion: [{ rol: 'persona', texto: 'a'.repeat(4001) }] });
  assert.equal(larga.ok, false);
  if (!larga.ok) assert.match(larga.mensaje, /demasiado larga/);
});

Deno.test('se descartan los turnos vacíos, las respuestas del principio y una ruta rara', () => {
  const r = leerPeticion({
    conversacion: [
      { rol: 'asistente', texto: 'Bienvenida' },
      { rol: 'persona', texto: '  ' },
      { rol: 'persona', texto: '¿Cuánto se recuperó esta semana?' },
    ],
    rutaActual: 'javascript:alert(1)',
  });
  assert.ok(r.ok);
  if (r.ok) {
    assert.deepEqual(r.peticion.conversacion, [{ rol: 'persona', texto: '¿Cuánto se recuperó esta semana?' }]);
    assert.equal(r.peticion.rutaActual, null);
  }
  const conRuta = leerPeticion({
    conversacion: [{ rol: 'persona', texto: '¿y esto?' }],
    rutaActual: '/admin/personas/839bba23-640e-4f57-9280-c814013233bc',
  });
  assert.ok(conRuta.ok && conRuta.peticion.rutaActual === '/admin/personas/839bba23-640e-4f57-9280-c814013233bc');
});

Deno.test('la conversación pasa al formato neutro con el contexto delante de la última pregunta', () => {
  const r = leerPeticion({
    conversacion: [
      { rol: 'persona', texto: '¿Quién debe más?' },
      { rol: 'asistente', texto: 'María, con 40 €.' },
      { rol: 'persona', texto: '¿Y desde cuándo?' },
      { rol: 'persona', texto: 'En días.' },
    ],
  });
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.deepEqual(aMensajes(r.peticion, '<contexto>x</contexto>'), [
    { rol: 'persona', bloques: [{ tipo: 'texto', texto: '¿Quién debe más?' }] },
    { rol: 'asistente', bloques: [{ tipo: 'texto', texto: 'María, con 40 €.' }] },
    {
      rol: 'persona',
      bloques: [
        { tipo: 'texto', texto: '<contexto>x</contexto>' },
        { tipo: 'texto', texto: '¿Y desde cuándo?\n\nEn días.' },
      ],
    },
  ]);
});

Deno.test('en Helios el día cambia a medianoche de Caracas: el contexto no habla de día operativo', () => {
  // 2026-09-26 03:59 UTC = 23:59 del viernes en Caracas.
  assert.match(contextoDelTurno(new Date('2026-09-26T03:59:00Z'), null), /viernes 2026-09-25, las 23:59/);
  // 2026-09-26 04:00 UTC = medianoche: ya es sábado.
  assert.match(contextoDelTurno(new Date('2026-09-26T04:00:00Z'), null), /sábado 2026-09-26, las 00:00/);
  assert.doesNotMatch(contextoDelTurno(new Date('2026-09-26T04:00:00Z'), null), /operativo/);
});

Deno.test('el contexto del turno lleva fecha, hora de Caracas y ruta', () => {
  const texto = contextoDelTurno(new Date('2026-09-25T18:32:00Z'), '/admin/cobranza');
  assert.match(texto, /viernes 2026-09-25, las 14:32 en Caracas/);
  assert.match(texto, /mirando \/admin\/cobranza/);
  assert.doesNotMatch(contextoDelTurno(new Date(), null), /mirando/);
});

Deno.test('el system no lleva nada volátil: mismo mapa, mismos bytes', () => {
  const mapa = leerMapa({ pantallas: [{ id: 'a', titulo: 'A', ruta: '/admin/a' }] });
  assert.equal(construirSystem(mapa), construirSystem(mapa));
  assert.doesNotMatch(construirSystem(mapa), /2026-\d\d-\d\d/);
  assert.match(construirSystem(mapa), /Nunca des un total con la comisión sumada/);
  assert.match(construirSystem(mapa), /Comisión Helios/);
  assert.doesNotMatch(construirSystem(mapa), /equipo de Ronda|en euros, aunque/);
});
