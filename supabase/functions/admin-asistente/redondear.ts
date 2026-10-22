/**
 * Los importes, a céntimos, antes de llegar al modelo.
 *
 * Varias RPC devuelven dólares con tres decimales (`50.264`, `2.395`). El modelo
 * los escribe en español y confunde el punto decimal con el de los miles: el
 * 2026-09-25 contestó «50.264,00 €» a «¿cuánto le debemos a los locales?»
 * (eran 50,26 €; en Ronda). Con dos decimales no hay confusión posible.
 *
 * Se redondea como el panel (`Intl.NumberFormat`, medio hacia fuera, sobre la
 * representación decimal del número): 2,395 € se lee 2,40 €, no 2,39 €.
 */

type Fila = Record<string, unknown>;

const esFila = (v: unknown): v is Fila => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Un campo de dinero: `*_usd` o `usd`, y `*_eur` si alguna RPC lo trae. */
const DINERO = /(^|_)(usd|eur)$/;

/** A céntimos, medio hacia fuera: 2.395 → 2.4, −2.395 → −2.4. */
export function aCentimos(v: number): number {
  const signo = v < 0 ? -1 : 1;
  const texto = String(Math.abs(v));
  // «2.395e2» es 239.5 exacto; 2.395 * 100 es 239.49999… y bajaría.
  const centimos = texto.includes('e') ? Math.abs(v) * 100 : Number(`${texto}e2`);
  return (signo * Math.round(centimos)) / 100;
}

/** Recorre el resultado y deja a céntimos cada número de un campo de dinero. */
export function redondearDinero(valor: unknown, clave = ''): unknown {
  if (Array.isArray(valor)) return valor.map((v) => redondearDinero(v, clave));
  if (esFila(valor)) return Object.fromEntries(Object.entries(valor).map(([k, v]) => [k, redondearDinero(v, k)]));
  if (typeof valor === 'number' && Number.isFinite(valor) && DINERO.test(clave)) return aCentimos(valor);
  return valor;
}
