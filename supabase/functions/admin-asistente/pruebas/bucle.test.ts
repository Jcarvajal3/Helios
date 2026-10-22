/**
 * El bucle de herramientas con un proveedor de mentira que sigue un guion:
 * no sabe qué modelo hay detrás, y aquí no hay ninguno.
 */

import assert from 'node:assert/strict';

import type { Base } from '../base.ts';
import { AVISO_ULTIMA_VUELTA, correrAsistente } from '../bucle.ts';
import { MAX_VUELTAS } from '../config.ts';
import { leerMapa } from '../mapa.ts';
import type { EventoDelModelo, MotivoDeFin, PeticionAlModelo, Proveedor } from '../proveedor.ts';
import type { Evento } from '../sse.ts';

type Vuelta = { texto?: string; llamadas?: Array<{ id: string; nombre: string; entrada?: Record<string, unknown> }>; motivo?: MotivoDeFin };

function guion(vueltas: Vuelta[]) {
  const peticiones: PeticionAlModelo[] = [];
  const proveedor: Proveedor = {
    modelo: 'modelo-de-mentira',
    async *responder(p): AsyncGenerator<EventoDelModelo> {
      peticiones.push({ ...p, mensajes: [...p.mensajes] });
      const v = vueltas[Math.min(peticiones.length - 1, vueltas.length - 1)];
      if (v.texto) yield { tipo: 'texto', delta: v.texto };
      const llamadas = (v.llamadas ?? []).map((l) => ({ tipo: 'llamada' as const, id: l.id, nombre: l.nombre, entrada: l.entrada ?? {} }));
      for (const llamada of llamadas) yield { tipo: 'llamada', llamada };
      yield {
        tipo: 'fin',
        motivo: v.motivo ?? (llamadas.length > 0 ? 'herramientas' : 'fin'),
        modelo: 'modelo-de-mentira-001',
        uso: { entrada: 10, salida: 5, cacheLeida: 100 },
        turno: { bloques: [...(v.texto ? [{ tipo: 'texto' as const, texto: v.texto }] : []), ...llamadas], nativo: `vuelta-${peticiones.length}` },
      };
    },
    describirError: () => ({ codigo: 'otro', mensaje: 'falló', reintentar: true }),
  };
  return { proveedor, peticiones };
}

const base: Base = {
  usuario: () => Promise.resolve('u'),
  rpc: (nombre) => Promise.resolve({ data: { rpc: nombre, full_name: 'MARÍA PÉREZ' }, error: null }),
};

async function correr(proveedor: Proveedor, b: Base = base) {
  const eventos: Evento[] = [];
  const resumen = await correrAsistente({
    proveedor,
    system: 'system',
    mensajes: [{ rol: 'persona', bloques: [{ tipo: 'texto', texto: '¿Qué clínicas tienen más mora?' }] }],
    base: b,
    mapa: leerMapa({ pantallas: [{ id: 'r', titulo: 'Riesgo', ruta: '/admin/riesgo' }] }),
    canal: { enviar: (e) => eventos.push(e), senal: new AbortController().signal },
  });
  return { eventos, resumen };
}

Deno.test('una pregunta con una consulta y un enlace: eventos en orden y resultados de vuelta al modelo', async () => {
  const { proveedor, peticiones } = guion([
    { llamadas: [{ id: 'l1', nombre: 'admin_merchant_risk', entrada: { dias: 90 } }, { id: 'l2', nombre: 'mostrar_enlace', entrada: { titulo: 'Ver riesgo', ruta: '/admin/riesgo' } }] },
    { texto: 'El consultorio de la Dra. Palmero tiene la mora más alta.' },
  ]);
  const { eventos, resumen } = await correr(proveedor);

  // El enlace que pide el modelo se pinta detrás del texto, como todo lo que se dibuja.
  assert.deepEqual(eventos.map((e) => e.tipo), ['herramienta', 'herramienta', 'texto', 'enlace', 'fin']);
  const estados = eventos.flatMap((e) => (e.tipo === 'herramienta' ? [e.datos] : []));
  assert.deepEqual(estados, [
    { id: 'l1', rotulo: 'Leyendo el riesgo por clínica', estado: 'consultando' },
    { id: 'l1', rotulo: 'Leyendo el riesgo por clínica', estado: 'hecho' },
  ]);
  assert.deepEqual(eventos.find((e) => e.tipo === 'enlace'), { tipo: 'enlace', datos: { titulo: 'Ver riesgo', ruta: '/admin/riesgo' } });
  assert.deepEqual(eventos[4], { tipo: 'fin', datos: { modelo: 'modelo-de-mentira-001', entrada: 20, salida: 10, cacheLeida: 200 } });
  assert.deepEqual(resumen.herramientas, ['admin_merchant_risk', 'mostrar_enlace']);

  // La segunda vuelta ve el turno nativo del modelo y los dos resultados, con su nombre.
  const segunda = peticiones[1].mensajes;
  assert.deepEqual(segunda[1], {
    rol: 'asistente',
    bloques: [
      { tipo: 'llamada', id: 'l1', nombre: 'admin_merchant_risk', entrada: { dias: 90 } },
      { tipo: 'llamada', id: 'l2', nombre: 'mostrar_enlace', entrada: { titulo: 'Ver riesgo', ruta: '/admin/riesgo' } },
    ],
    nativo: 'vuelta-1',
  });
  const resultados = segunda[2];
  assert.equal(resultados.rol, 'persona');
  if (resultados.rol === 'persona') {
    const [r1, r2] = resultados.bloques;
    assert.ok(r1.tipo === 'resultado' && r1.nombre === 'admin_merchant_risk' && r1.contenido.includes('MARÍA P.'));
    assert.ok(r2.tipo === 'resultado' && r2.contenido === 'ok');
  }
});

Deno.test(`como mucho ${MAX_VUELTAS} vueltas: la última va sin herramientas y con el aviso`, async () => {
  const { proveedor, peticiones } = guion([
    { llamadas: [{ id: 'x', nombre: 'admin_risk_alert_counts' }] },
  ]);
  const { eventos } = await correr(proveedor);
  assert.equal(peticiones.length, MAX_VUELTAS);
  assert.deepEqual(peticiones.map((p) => p.permitirHerramientas), [true, true, true, true, true, false]);
  const ultima = peticiones[MAX_VUELTAS - 1].mensajes;
  assert.match(JSON.stringify(ultima[ultima.length - 1]), new RegExp(AVISO_ULTIMA_VUELTA.slice(0, 30)));
  assert.equal(eventos[eventos.length - 1].tipo, 'fin');
  assert.ok(!eventos.some((e) => e.tipo === 'error'));
});

Deno.test('un rechazo no ejecuta nada y da un error sobrio', async () => {
  const { proveedor } = guion([{ llamadas: [{ id: 'x', nombre: 'admin_overview' }], motivo: 'rechazo' }]);
  const { eventos, resumen } = await correr(proveedor);
  assert.deepEqual(eventos.map((e) => e.tipo), ['error', 'fin']);
  assert.deepEqual(eventos[0], { tipo: 'error', datos: { codigo: 'otro', mensaje: 'El asistente no puede responder a esta pregunta.', reintentar: false } });
  assert.deepEqual(resumen.herramientas, []);
});

Deno.test('una llamada cortada por tokens no se ejecuta; un fallo del modelo se puede reintentar', async () => {
  const corte = await correr(guion([{ llamadas: [{ id: 'x', nombre: 'admin_overview' }], motivo: 'corte' }]).proveedor);
  assert.deepEqual(corte.eventos.map((e) => e.tipo), ['error', 'fin']);
  assert.deepEqual(corte.resumen.herramientas, []);

  const fallo = await correr(guion([{ motivo: 'fallo' }]).proveedor);
  assert.equal(fallo.eventos[0].tipo, 'error');
  assert.ok(fallo.eventos[0].tipo === 'error' && fallo.eventos[0].datos.reintentar);
});

Deno.test('si el proveedor falla, el error es el que él describe (el 429 de la cuota, por ejemplo)', async () => {
  const proveedor: Proveedor = {
    modelo: 'm',
    // deno-lint-ignore require-yield
    async *responder(): AsyncGenerator<EventoDelModelo> {
      throw new Error('429');
    },
    describirError: () => ({ codigo: 'cuota', mensaje: 'El asistente llegó a su cuota gratuita; prueba en un minuto.', reintentar: true }),
  };
  const { eventos } = await correr(proveedor);
  assert.deepEqual(eventos, [
    { tipo: 'error', datos: { codigo: 'cuota', mensaje: 'El asistente llegó a su cuota gratuita; prueba en un minuto.', reintentar: true } },
    { tipo: 'fin', datos: { modelo: 'm', entrada: 0, salida: 0, cacheLeida: 0 } },
  ]);
});

// ── Enlaces automáticos ────────────────────────────────────────────────────

/** Un mapa con la forma que escribe el panel: `search` en listas. */
const BUSQUEDA_METRICAS = { vista: ['caja', 'cobros', 'mora', 'semana'], sub: ['cupos', 'impago-por-cuota', 'proyeccion', 'rendimiento'] };
const MAPA_GENERADO = leerMapa({
  version: 1,
  pantallas: [
    { id: 'metricas', titulo: 'Métricas', ruta: '/admin/metricas', search: BUSQUEDA_METRICAS },
    { id: 'metricas-cobros', titulo: 'Métricas › Cobros', ruta: '/admin/metricas', search: BUSQUEDA_METRICAS },
    { id: 'metricas-cobros-impago-por-cuota', titulo: 'Métricas › Cobros › Impago por cuota', ruta: '/admin/metricas', search: BUSQUEDA_METRICAS },
    { id: 'metricas-mora-cupos', titulo: 'Métricas › Riesgo › Cupos', ruta: '/admin/metricas', search: BUSQUEDA_METRICAS },
    { id: 'metricas-semana-rendimiento', titulo: 'Métricas › Semana › Rendimiento', ruta: '/admin/metricas', search: BUSQUEDA_METRICAS },
    { id: 'alertas', titulo: 'Alertas', ruta: '/admin/alertas', search: {} },
    { id: 'pagos', titulo: 'Pagos a clínicas', ruta: '/admin/pagos-clinicas', search: {} },
  ],
  fichas: [{ id: 'ficha-persona', titulo: 'Ficha de un paciente', ruta: '/admin/pacientes/$id' }],
});

async function correrCon(proveedor: Proveedor) {
  const eventos: Evento[] = [];
  await correrAsistente({
    proveedor,
    system: 'system',
    mensajes: [{ rol: 'persona', bloques: [{ tipo: 'texto', texto: '¿Cómo vamos?' }] }],
    base,
    mapa: MAPA_GENERADO,
    canal: { enviar: (e) => eventos.push(e), senal: new AbortController().signal },
  });
  return eventos;
}

const enlaces = (eventos: Evento[]) => eventos.flatMap((e) => (e.tipo === 'enlace' ? [e.datos] : []));

Deno.test('al terminar, enlaza sola la pantalla de cada herramienta usada, con el título del mapa', async () => {
  const eventos = await correrCon(guion([
    { llamadas: [{ id: 'a', nombre: 'admin_first_payment_default' }, { id: 'b', nombre: 'admin_risk_alert_counts' }] },
    { llamadas: [{ id: 'c', nombre: 'admin_risk_alert_counts' }] },
    { texto: 'El impago de la primera cuota es del 100 %.' },
  ]).proveedor);
  // Después del texto y antes del fin; una vez cada ruta, en el orden en que se leyeron.
  assert.deepEqual(eventos.map((e) => e.tipo).slice(-4), ['texto', 'enlace', 'enlace', 'fin']);
  assert.deepEqual(enlaces(eventos), [
    { titulo: 'Métricas › Cobros › Impago por cuota', ruta: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota' } },
    { titulo: 'Alertas', ruta: '/admin/alertas' },
  ]);
});

Deno.test('no repite una pestaña que el modelo ya enlazó, y enlaza la ficha del paciente leído', async () => {
  const id = '839bba23-640e-4f57-9280-c814013233bc';
  const eventos = await correrCon(guion([
    {
      llamadas: [
        { id: 'a', nombre: 'admin_first_payment_default' },
        { id: 'b', nombre: 'admin_user_detail', entrada: { persona_id: id } },
        {
          id: 'c',
          nombre: 'mostrar_enlace',
          entrada: {
            titulo: 'Ver el impago',
            ruta: '/admin/metricas',
            search: [{ clave: 'vista', valor: 'cobros' }, { clave: 'sub', valor: 'impago-por-cuota' }],
          },
        },
      ],
    },
    { texto: 'Listo.' },
  ]).proveedor);
  assert.deepEqual(enlaces(eventos), [
    { titulo: 'Ver el impago', ruta: '/admin/metricas', search: { vista: 'cobros', sub: 'impago-por-cuota' } },
    { titulo: 'Ficha de un paciente', ruta: `/admin/pacientes/${id}` },
  ]);
});

Deno.test('dos pestañas distintas de Métricas se enlazan las dos', async () => {
  const eventos = await correrCon(guion([
    { llamadas: [{ id: 'a', nombre: 'admin_weekly_summary' }, { id: 'b', nombre: 'admin_credit_utilization' }] },
    { texto: 'Listo.' },
  ]).proveedor);
  assert.deepEqual(enlaces(eventos).map((e) => e.titulo), ['Métricas › Semana › Rendimiento', 'Métricas › Riesgo › Cupos']);
});

Deno.test('como mucho tres enlaces automáticos, y ninguno si la respuesta acabó en error', async () => {
  const muchas = await correrCon(guion([
    {
      llamadas: [
        { id: 'a', nombre: 'admin_first_payment_default' },
        { id: 'b', nombre: 'admin_risk_alert_counts' },
        { id: 'c', nombre: 'admin_merchant_payables' },
        { id: 'd', nombre: 'admin_weekly_summary' },
      ],
    },
    { texto: 'Todo.' },
  ]).proveedor);
  assert.deepEqual(enlaces(muchas).map((e) => e.ruta), ['/admin/metricas', '/admin/alertas', '/admin/pagos-clinicas']);

  const conError = await correrCon(guion([
    { llamadas: [{ id: 'a', nombre: 'admin_risk_alert_counts' }] },
    { motivo: 'fallo' },
  ]).proveedor);
  assert.deepEqual(enlaces(conError), []);
  assert.deepEqual(conError.map((e) => e.tipo).slice(-2), ['error', 'fin']);
});

Deno.test('una herramienta que falla no deja enlace', async () => {
  const baseQueFalla: Base = { usuario: () => Promise.resolve('u'), rpc: () => Promise.resolve({ data: null, error: { message: 'no' } }) };
  const eventos: Evento[] = [];
  await correrAsistente({
    proveedor: guion([{ llamadas: [{ id: 'a', nombre: 'admin_risk_alert_counts' }] }, { texto: 'No pude leerlo.' }]).proveedor,
    system: 'system',
    mensajes: [{ rol: 'persona', bloques: [{ tipo: 'texto', texto: '¿Alertas?' }] }],
    base: baseQueFalla,
    mapa: MAPA_GENERADO,
    canal: { enviar: (e) => eventos.push(e), senal: new AbortController().signal },
  });
  assert.deepEqual(enlaces(eventos), []);
});

Deno.test('texto y solo presentación cierran la respuesta: se dibuja y no se vuelve a preguntar', async () => {
  const { proveedor, peticiones } = guion([
    { llamadas: [{ id: 'a', nombre: 'admin_risk_alert_counts' }] },
    { texto: 'Hay dos alertas sin revisar.', llamadas: [{ id: 'b', nombre: 'mostrar_enlace', entrada: { titulo: 'Ver', ruta: '/admin/metricas' } }] },
    { texto: 'Hay dos alertas sin revisar.' },
  ]);
  const eventos = await correrCon(proveedor);
  assert.equal(peticiones.length, 2);
  assert.equal(eventos.filter((e) => e.tipo === 'texto').length, 1);
  assert.deepEqual(enlaces(eventos).map((e) => e.ruta), ['/admin/metricas', '/admin/alertas']);

  // Sin texto, la vuelta de presentación no cierra: el modelo todavía tiene que contestar.
  const sinTexto = guion([
    { llamadas: [{ id: 'a', nombre: 'mostrar_enlace', entrada: { titulo: 'Ver', ruta: '/admin/metricas' } }] },
    { texto: 'Listo.' },
  ]);
  await correrCon(sinTexto.proveedor);
  assert.equal(sinTexto.peticiones.length, 2);
});

Deno.test('una llamada escrita como texto no llega al panel', async () => {
  const eventos = await correrCon(guion([
    { llamadas: [{ id: 'a', nombre: 'admin_risk_alert_counts' }] },
    { texto: 'Hay dos alertas sin revisar.\n\n{mostrar_enlace(ruta="/admin/alertas")}' },
  ]).proveedor);
  const texto = eventos.flatMap((e) => (e.tipo === 'texto' ? [e.datos.delta] : [])).join('');
  assert.equal(texto, 'Hay dos alertas sin revisar.');
  assert.deepEqual(enlaces(eventos).map((e) => e.ruta), ['/admin/alertas']);
});
