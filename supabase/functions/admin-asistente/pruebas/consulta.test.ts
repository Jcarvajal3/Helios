/**
 * `consultar_datos`: la tabla o el gráfico salen de las filas de la base, no
 * del modelo, y se pintan detrás del texto que los explica.
 */

import assert from 'node:assert/strict';

import type { Base } from '../base.ts';
import { correrAsistente, repiteLaVista } from '../bucle.ts';
import { catalogoParaElPrompt, VISTAS } from '../herramientas/catalogo.ts';
import { pantallaDeLaConsulta, rotularColumna, unidadDeColumna, visualizarConsulta } from '../herramientas/consulta.ts';
import { ejecutarHerramienta } from '../herramientas/ejecutar.ts';
import { buscarHerramienta } from '../herramientas/index.ts';
import { leerMapa } from '../mapa.ts';
import type { EventoDelModelo, Proveedor } from '../proveedor.ts';
import type { Evento } from '../sse.ts';

const SISTEMAS = { filas: [{ sistema: 'Android', personas: 45 }, { sistema: 'iOS', personas: 42 }, { sistema: 'Sin dato', personas: 12 }], truncado: false, n: 3 };

const MAPA = leerMapa({ pantallas: [{ id: 'p', titulo: 'Pacientes', ruta: '/admin/pacientes' }] });

function baseCon(data: unknown, llamadas: Array<[string, unknown]> = []): Base {
  return {
    usuario: () => Promise.resolve('u'),
    rpc: (nombre, args) => {
      llamadas.push([nombre, args]);
      return Promise.resolve({ data, error: null });
    },
  };
}

Deno.test('un gráfico de barras se arma con las filas tal cual, sin pasar por el modelo', () => {
  const v = visualizarConsulta({ titulo: 'Personas por sistema', mostrar: 'barras', etiqueta: 'sistema', valor: 'personas' }, SISTEMAS);
  assert.deepEqual(v?.evento, {
    tipo: 'grafico',
    datos: {
      tipo: 'barras',
      titulo: 'Personas por sistema',
      unidad: 'numero',
      puntos: [{ etiqueta: 'Android', valor: 45 }, { etiqueta: 'iOS', valor: 42 }, { etiqueta: 'Sin dato', valor: 12 }],
    },
  });
  assert.match(v?.nota ?? '', /ya enseña este gráfico/);
});

Deno.test('sin columnas dichas, el gráfico toma la primera de texto y la primera numérica', () => {
  const v = visualizarConsulta({ titulo: 'x', mostrar: 'reparto' }, SISTEMAS);
  assert.ok(v?.evento?.tipo === 'grafico');
  assert.equal(v.evento.datos.puntos[1].etiqueta, 'iOS');
  assert.equal(v.evento.datos.tipo, 'reparto');
});

Deno.test('dos series llevan su leyenda, y la unidad sale del nombre de la columna', () => {
  const datos = { filas: [{ dia: '2026-09-24', consulta_usd: 120.5, comision_usd: 14.46 }] };
  const v = visualizarConsulta({ titulo: 'Financiado', mostrar: 'lineas', etiqueta: 'dia', valor: 'consulta_usd', valor2: 'comision_usd' }, datos);
  assert.ok(v?.evento?.tipo === 'grafico');
  // `eur` es la unidad de dinero del protocolo: el panel de Helios la pinta en dólares.
  assert.equal(v.evento.datos.unidad, 'eur');
  assert.deepEqual(v.evento.datos.leyenda, { valor: 'Financiado ($)', valor2: 'Comisión Helios ($)' });
  assert.deepEqual(v.evento.datos.puntos, [{ etiqueta: '24 sep', valor: 120.5, valor2: 14.46 }]);
});

Deno.test('si el gráfico no se puede, las filas salen igual en tabla y el modelo sabe por qué', () => {
  const v = visualizarConsulta({ titulo: 'x', mostrar: 'barras', etiqueta: 'plataforma', valor: 'personas' }, SISTEMAS);
  assert.equal(v?.evento?.tipo, 'tabla');
  assert.match(v?.nota ?? '', /no trae «plataforma»; columnas: sistema, personas/);

  const muchos = { filas: Array.from({ length: 70 }, (_, i) => ({ dia: `d${i}`, n: i })) };
  const w = visualizarConsulta({ titulo: 'x', mostrar: 'lineas' }, muchos);
  assert.equal(w?.evento?.tipo, 'tabla');
  assert.match(w?.nota ?? '', /70 puntos/);
});

Deno.test('una tabla deduce las unidades y escribe los sí y no', () => {
  const datos = { filas: [{ plantilla: 'bienvenida', enviados: 23, consulta_usd: 10.5, en_lista_negra: true, creado_at: '2026-09-24T12:00:00Z' }] };
  const v = visualizarConsulta({ titulo: 'WhatsApp', mostrar: 'tabla' }, datos);
  assert.ok(v?.evento?.tipo === 'tabla');
  assert.deepEqual(v.evento.datos.columnas.map((c) => [c.rotulo, c.unidad]), [
    ['Plantilla', 'texto'],
    ['Enviados', 'numero'],
    ['Financiado ($)', 'eur'],
    ['En lista negra', 'texto'],
    ['Fecha', 'fecha'],
  ]);
  assert.equal(v.evento.datos.filas[0].en_lista_negra, 'sí');
});

Deno.test('una sola cifra no hace tabla; «nada» no dibuja; sin filas se dice', () => {
  assert.deepEqual(visualizarConsulta({ titulo: 'x', mostrar: 'tabla' }, { filas: [{ n: 87 }] }), {
    nota: 'Es una sola cifra: dila en el texto; no hace falta tabla.',
  });
  assert.equal(visualizarConsulta({ titulo: 'x', mostrar: 'nada' }, SISTEMAS), null);
  assert.deepEqual(visualizarConsulta({ titulo: 'x', mostrar: 'barras' }, { filas: [] }), { nota: 'La consulta no devolvió filas.' });
});

Deno.test('la pantalla que se enlaza sale de las vistas leídas', () => {
  assert.deepEqual(pantallaDeLaConsulta('select plantilla, count(*) from mensajes group by 1'), { ruta: '/admin/avisos' });
  assert.deepEqual(pantallaDeLaConsulta('select estado, count(*) from comprobantes group by 1'), { ruta: '/admin/cobros' });
  assert.deepEqual(pantallaDeLaConsulta('select clinica, sum(monto_usd) from liquidaciones group by 1'), { ruta: '/admin/pagos-clinicas' });
  assert.deepEqual(pantallaDeLaConsulta('select sexo, count(*) from pacientes group by 1'), { ruta: '/admin/pacientes' });
  assert.deepEqual(pantallaDeLaConsulta('select paciente, dias_atraso from cuotas where vencida'), { ruta: '/admin/cobranza' });
  assert.deepEqual(pantallaDeLaConsulta('select clinica, count(distinct user_id) from cuotas group by 1'), { ruta: '/admin/financiamientos' });
  assert.deepEqual(
    pantallaDeLaConsulta('select c.categoria, count(*) from ordenes o join clinicas c using (clinica_id) group by 1'),
    { ruta: '/admin/financiamientos' },
  );
  // Una columna que se llama como una vista (pacientes.ordenes) no cambia la pantalla.
  assert.deepEqual(pantallaDeLaConsulta('select paciente, ordenes from pacientes'), { ruta: '/admin/pacientes' });
  assert.equal(pantallaDeLaConsulta('select 1'), null);
});

Deno.test('rótulos y unidades de columna', () => {
  assert.equal(rotularColumna('dia'), 'Día');
  assert.equal(rotularColumna('dias_sin_pagar'), 'Días sin pagar');
  assert.equal(rotularColumna('pagado_usd'), 'Pagado ($)');
  assert.equal(rotularColumna('ordenes_por_medico'), 'Órdenes por médico');
  assert.equal(unidadDeColumna('pagado_usd', [1.5]), 'eur');
  assert.equal(unidadDeColumna('monto_ves', [1500]), 'numero');
  assert.equal(unidadDeColumna('recovery_pct', [0.5]), 'pct');
  assert.equal(unidadDeColumna('vence_el', ['2026-09-30', null]), 'fecha');
});

Deno.test('ejecutar: la nota va delante de las filas, los dólares a céntimos y la vista aparte', async () => {
  const llamadas: Array<[string, unknown]> = [];
  const h = buscarHerramienta('consultar_datos');
  assert.ok(h);
  const r = await ejecutarHerramienta(
    h,
    { sql: 'select clinica_id, sum(consulta_usd) as consulta_usd from ordenes group by 1', titulo: 'Por clínica', mostrar: 'tabla' },
    { base: baseCon({ filas: [{ clinica: 'A', consulta_usd: 50.264 }, { clinica: 'B', consulta_usd: 2.395 }] }, llamadas), mapa: MAPA },
  );
  assert.deepEqual(llamadas, [['admin_assistant_query', { p_sql: 'select clinica_id, sum(consulta_usd) as consulta_usd from ordenes group by 1', p_max_rows: 200 }]]);
  assert.equal(r.esError, false);
  assert.match(r.contenido, /^El panel ya enseña esta tabla/);
  assert.match(r.contenido, /"consulta_usd":50\.26/);
  assert.ok(r.vista?.tipo === 'tabla');
  assert.equal(r.vista.datos.filas[1].consulta_usd, 2.4);
  assert.equal(r.evento, undefined);
  assert.deepEqual(r.pantalla, { ruta: '/admin/financiamientos' });
});

Deno.test('ejecutar: sin sql no llama a la base', async () => {
  const llamadas: Array<[string, unknown]> = [];
  const h = buscarHerramienta('consultar_datos');
  assert.ok(h);
  const r = await ejecutarHerramienta(h, { titulo: 'x', mostrar: 'tabla' }, { base: baseCon({}, llamadas), mapa: MAPA });
  assert.equal(r.esError, true);
  assert.match(r.contenido, /Falta «sql»/);
  assert.equal(llamadas.length, 0);
});

Deno.test('en la respuesta, el gráfico va detrás del texto y antes del enlace y el fin', async () => {
  let vuelta = 0;
  const proveedor: Proveedor = {
    modelo: 'm',
    async *responder(): AsyncGenerator<EventoDelModelo> {
      vuelta++;
      if (vuelta === 1) {
        const llamada = {
          tipo: 'llamada' as const,
          id: 'c1',
          nombre: 'consultar_datos',
          entrada: { sql: 'select sistema, count(*) as personas from pacientes group by 1', titulo: 'Por sistema', mostrar: 'barras' },
        };
        yield { tipo: 'llamada', llamada };
        yield { tipo: 'fin', motivo: 'herramientas', modelo: 'm', uso: { entrada: 1, salida: 1, cacheLeida: 0 }, turno: { bloques: [llamada] } };
        return;
      }
      yield { tipo: 'texto', delta: '**45 personas** usan Android.' };
      yield { tipo: 'fin', motivo: 'fin', modelo: 'm', uso: { entrada: 1, salida: 1, cacheLeida: 0 }, turno: { bloques: [] } };
    },
    describirError: () => null,
  };
  const eventos: Evento[] = [];
  await correrAsistente({
    proveedor,
    system: 's',
    mensajes: [{ rol: 'persona', bloques: [{ tipo: 'texto', texto: 'Apple o Android' }] }],
    base: baseCon(SISTEMAS),
    mapa: MAPA,
    canal: { enviar: (e) => eventos.push(e), senal: new AbortController().signal },
  });
  assert.deepEqual(eventos.map((e) => e.tipo), ['herramienta', 'herramienta', 'texto', 'grafico', 'enlace', 'fin']);
  assert.deepEqual(eventos[4], { tipo: 'enlace', datos: { titulo: 'Pacientes', ruta: '/admin/pacientes' } });
});

Deno.test('un gráfico del modelo con lo que la consulta ya dibujó no sale repetido', async () => {
  let vuelta = 0;
  const vistas: string[] = [];
  const consulta = {
    tipo: 'llamada' as const,
    id: 'c1',
    nombre: 'consultar_datos',
    entrada: { sql: 'select sistema, count(*) as personas from pacientes group by 1', titulo: 'Por sistema', mostrar: 'barras' },
  };
  const grafico = {
    tipo: 'llamada' as const,
    id: 'g1',
    nombre: 'mostrar_grafico',
    entrada: { tipo: 'barras', titulo: 'Otra vez', unidad: 'numero', puntos: [{ etiqueta: 'iOS', valor: 0 }] },
  };
  const proveedor: Proveedor = {
    modelo: 'm',
    async *responder(p): AsyncGenerator<EventoDelModelo> {
      vuelta++;
      const llamadas = vuelta === 1 ? [consulta, grafico] : [];
      if (vuelta === 2) {
        const ultimo = p.mensajes[p.mensajes.length - 1];
        if (ultimo.rol === 'persona') for (const b of ultimo.bloques) if (b.tipo === 'resultado') vistas.push(`${b.nombre}:${b.esError}`);
        yield { tipo: 'texto', delta: 'Listo.' };
      }
      for (const llamada of llamadas) yield { tipo: 'llamada', llamada };
      yield {
        tipo: 'fin',
        motivo: llamadas.length ? 'herramientas' : 'fin',
        modelo: 'm',
        uso: { entrada: 1, salida: 1, cacheLeida: 0 },
        turno: { bloques: llamadas },
      };
    },
    describirError: () => null,
  };
  const eventos: Evento[] = [];
  await correrAsistente({
    proveedor,
    system: 's',
    mensajes: [{ rol: 'persona', bloques: [{ tipo: 'texto', texto: 'Apple o Android' }] }],
    base: baseCon(SISTEMAS),
    mapa: MAPA,
    canal: { enviar: (e) => eventos.push(e), senal: new AbortController().signal },
  });
  const graficos = eventos.flatMap((e) => (e.tipo === 'grafico' ? [e.datos.titulo] : []));
  assert.deepEqual(graficos, ['Por sistema']);
  // Los resultados vuelven en el orden de las llamadas, y el del gráfico repetido es un error.
  assert.deepEqual(vistas, ['consultar_datos:false', 'mostrar_grafico:true']);
});

Deno.test('una consulta corregida sustituye el gráfico de la anterior; uno distinto se suma', () => {
  const g = (titulo: string, etiquetas: string[], unidad: 'numero' | 'eur' = 'numero'): Evento => ({
    tipo: 'grafico',
    datos: { tipo: 'barras', titulo, unidad, puntos: etiquetas.map((etiqueta) => ({ etiqueta, valor: 1 })) },
  });
  assert.equal(repiteLaVista(g('Usuarios por sistema', ['Android']), g('Usuarios por sistema (Apple vs Android)', ['Android', 'iOS'])), true);
  assert.equal(repiteLaVista(g('Por día', ['2026-09-24']), g('Por día', ['2026-09-24'], 'eur')), false);
  assert.equal(repiteLaVista(g('Por local', ['Bar A']), g('Por sistema', ['iOS'])), false);
});

Deno.test('en la respuesta, dos consultas del mismo gráfico dejan solo el de la segunda', async () => {
  let vuelta = 0;
  const sql = ['select sistema, count(*) as personas from pacientes group by 1', "select s.sistema, count(p.user_id) as personas from (values ('iOS'), ('Android')) s(sistema) left join pacientes p using (sistema) group by 1"];
  const proveedor: Proveedor = {
    modelo: 'm',
    async *responder(): AsyncGenerator<EventoDelModelo> {
      vuelta++;
      if (vuelta <= 2) {
        const llamada = { tipo: 'llamada' as const, id: `c${vuelta}`, nombre: 'consultar_datos', entrada: { sql: sql[vuelta - 1], titulo: `Intento ${vuelta}`, mostrar: 'barras' } };
        yield { tipo: 'llamada', llamada };
        yield { tipo: 'fin', motivo: 'herramientas', modelo: 'm', uso: { entrada: 1, salida: 1, cacheLeida: 0 }, turno: { bloques: [llamada] } };
        return;
      }
      yield { tipo: 'texto', delta: 'Listo.' };
      yield { tipo: 'fin', motivo: 'fin', modelo: 'm', uso: { entrada: 1, salida: 1, cacheLeida: 0 }, turno: { bloques: [] } };
    },
    describirError: () => null,
  };
  let consultas = 0;
  const filas = [
    { filas: [{ sistema: 'Android', personas: 2 }] },
    { filas: [{ sistema: 'iOS', personas: 0 }, { sistema: 'Android', personas: 2 }] },
  ];
  const base: Base = { usuario: () => Promise.resolve('u'), rpc: () => Promise.resolve({ data: filas[consultas++], error: null }) };
  const eventos: Evento[] = [];
  await correrAsistente({
    proveedor,
    system: 's',
    mensajes: [{ rol: 'persona', bloques: [{ tipo: 'texto', texto: 'Apple o Android' }] }],
    base,
    mapa: MAPA,
    canal: { enviar: (e) => eventos.push(e), senal: new AbortController().signal },
  });
  const graficos = eventos.flatMap((e) => (e.tipo === 'grafico' ? [e.datos] : []));
  assert.equal(graficos.length, 1);
  assert.equal(graficos[0].titulo, 'Intento 2');
  assert.deepEqual(graficos[0].puntos.map((p) => p.etiqueta), ['iOS', 'Android']);
});

Deno.test('el catálogo del prompt nombra cada vista y sus ejemplos solo usan vistas del catálogo', () => {
  const texto = catalogoParaElPrompt();
  for (const v of VISTAS) assert.match(texto, new RegExp(`- ${v.nombre}: `));
  const nombres = new Set(VISTAS.map((v) => v.nombre));
  for (const [, tabla] of texto.matchAll(/\bfrom (\w+)/g)) assert.ok(nombres.has(tabla), `el ejemplo lee «${tabla}», que no es una vista`);
});
