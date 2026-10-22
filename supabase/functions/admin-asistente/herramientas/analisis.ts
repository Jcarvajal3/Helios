/**
 * Análisis para gerencia: cómo le va a cada clínica y qué vence cada día. Son
 * las lecturas de Métricas › Clínicas y del calendario de Por cobrar.
 */

import type { Tabla } from '../sse.ts';
import { DESDE, ErrorDeEntrada, esFila, fecha, HASTA, leerFecha, objeto, rango, sinClaves, sinVacios } from './esquema.ts';
import type { HerramientaDeDatos, Visualizacion } from './tipos.ts';

const numeroO = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);

/** El cambio frente al periodo anterior, en %; `null` si antes no hubo nada con que medirlo. */
function cambioPct(ahora: number | null, antes: number | null): number | null {
  if (ahora === null || antes === null || antes === 0) return null;
  return Math.round(((ahora - antes) / antes) * 1000) / 10;
}

/**
 * La tabla de las clínicas, de la que más financió a la que menos. Con una
 * sola no hace falta. La RPC es la de Ronda: `locales`, `consumos`, `personas`.
 * La unidad `eur` del protocolo es el dinero: el panel la pinta en dólares.
 */
export function visualizarRendimiento(_entrada: unknown, datos: unknown): Visualizacion | null {
  if (!esFila(datos) || !Array.isArray(datos.locales)) return null;
  const clinicas = datos.locales.filter(esFila);
  if (clinicas.length < 2) return null;
  const orden = [...clinicas].sort((a, b) => (numeroO(b.consumo_usd) ?? 0) - (numeroO(a.consumo_usd) ?? 0));
  const tabla: Tabla = {
    titulo: `Rendimiento de las clínicas, del ${datos.desde ?? '?'} al ${datos.hasta ?? '?'}`,
    columnas: [
      { clave: 'clinica', rotulo: 'Clínica', unidad: 'texto' },
      { clave: 'financiado', rotulo: 'Financiado ($)', unidad: 'eur' },
      { clave: 'cambio', rotulo: 'Frente al periodo anterior', unidad: 'pct' },
      { clave: 'ordenes', rotulo: 'Órdenes', unidad: 'numero' },
      { clave: 'pacientes', rotulo: 'Pacientes', unidad: 'numero' },
      { clave: 'nuevos', rotulo: 'Nuevos', unidad: 'numero' },
      { clave: 'medio', rotulo: 'Monto medio ($)', unidad: 'eur' },
    ],
    filas: orden.slice(0, 50).map((l) => ({
      clinica: typeof l.nombre === 'string' ? l.nombre : null,
      financiado: numeroO(l.consumo_usd),
      cambio: cambioPct(numeroO(l.consumo_usd), numeroO(l.consumo_anterior_usd)),
      ordenes: numeroO(l.consumos),
      pacientes: numeroO(l.personas),
      nuevos: numeroO(l.nuevas),
      medio: numeroO(l.ticket_medio_usd),
    })),
  };
  return {
    evento: { tipo: 'tabla', datos: tabla },
    nota: 'El panel ya enseña la tabla de las clínicas: comenta lo que destaca, no copies sus filas.',
  };
}

export const analisis: HerramientaDeDatos[] = [
  {
    clase: 'datos',
    nombre: 'admin_merchant_performance',
    rpc: 'admin_merchant_performance',
    rotulo: 'Leyendo el rendimiento de las clínicas',
    descripcion:
      'Contesta cómo le va a cada clínica en un periodo (locales[]): financiado sin comisión (consumo_usd), órdenes ' +
      '(consumos), monto medio por orden (ticket_medio_usd), pacientes atendidos (personas), cuántos eran nuevos en ' +
      'esa clínica (nuevas), días con órdenes (noches) y el mejor día (mejor_noche), cada uno frente al periodo ' +
      'anterior del mismo largo (consumo_anterior_usd, consumos_anteriores). También salen las clínicas sin ' +
      'órdenes. Para «¿cuántos pacientes atendió X?» es esta. Sin fechas, los últimos 30 días.',
    esquema: objeto({ desde: DESDE, hasta: HASTA }),
    argumentos: (e) => sinVacios({ p_desde: leerFecha(e.desde), p_hasta: leerFecha(e.hasta) }),
    recortar: (datos) =>
      esFila(datos) && Array.isArray(datos.locales)
        ? { ...datos, locales: datos.locales.map((l) => sinClaves(l, ['consumos_en_grupo'])) }
        : datos,
    pantalla: { ruta: '/admin/metricas', search: { vista: 'locales' } },
    visualizar: visualizarRendimiento,
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_receivables_by_day',
    rpc: 'admin_receivables_by_day',
    rotulo: 'Leyendo el calendario de cobro',
    descripcion:
      'Contesta cuánto vence cada día en cuotas y sigue sin pagar, y de qué clínica es: por día, consumo_usd ' +
      '(financiado, sin comisión), comision_usd (la Comisión Helios con su IVA, línea aparte), cuotas y pacientes ' +
      '(personas); también el total del periodo y, si se pide, lo ya cobrado. total_usd es lo que vence en cuotas ' +
      '(deuda con la comisión dentro): al dar el desglose, financiado y comisión van por separado. El día es el ' +
      'vencimiento de la cuota.',
    esquema: objeto({
      desde: fecha('Primer día de vencimiento, inclusive (YYYY-MM-DD).'),
      hasta: fecha('Último día de vencimiento, inclusive (YYYY-MM-DD). Como mucho unas semanas después de desde.'),
      incluir_pagadas: { type: 'boolean', description: 'true para sumar también lo ya cobrado de esas fechas. Por defecto false.' },
    }, ['desde', 'hasta']),
    argumentos: (e) => {
      const { p_from, p_to } = rango(e);
      if (!p_from || !p_to) throw new ErrorDeEntrada('Pon «desde» y «hasta» (YYYY-MM-DD): el calendario necesita las dos fechas.');
      return sinVacios({ p_desde: p_from, p_hasta: p_to, p_incluir_pagadas: typeof e.incluir_pagadas === 'boolean' ? e.incluir_pagadas : undefined });
    },
    // `cotejo` cuadra el calendario con el libro: es un control del panel, no una cifra que contar.
    recortar: (datos) => sinClaves(datos, ['cotejo']),
    pantalla: { ruta: '/admin/cobranza', search: { vista: 'calendario' } },
    datosPersonales: 'lista',
  },
];
