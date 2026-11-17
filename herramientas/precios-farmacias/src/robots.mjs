// Lector mínimo de robots.txt (RFC 9309): grupos por agente, Allow y Disallow
// con comodines; gana la regla más larga y, en empate, Allow.

function grupos(texto) {
  const lista = [];
  let actual = null;
  let leyendoAgentes = false;
  for (const cruda of texto.split(/\r?\n/)) {
    const linea = cruda.replace(/#.*$/, '').trim();
    const separador = linea.indexOf(':');
    if (separador < 0) continue;
    const campo = linea.slice(0, separador).trim().toLowerCase();
    const valor = linea.slice(separador + 1).trim();
    if (campo === 'user-agent') {
      if (!leyendoAgentes) {
        actual = { agentes: [], reglas: [] };
        lista.push(actual);
      }
      actual.agentes.push(valor.toLowerCase());
      leyendoAgentes = true;
    } else if (actual && (campo === 'allow' || campo === 'disallow')) {
      leyendoAgentes = false;
      if (valor) actual.reglas.push({ permite: campo === 'allow', patron: valor });
    } else {
      leyendoAgentes = false;
    }
  }
  return lista;
}

function coincide(patron, ruta) {
  const exacto = patron.endsWith('$');
  const cuerpo = exacto ? patron.slice(0, -1) : patron;
  const regex = cuerpo
    .split('*')
    .map((parte) => parte.replace(/[.+?^${}()|[\]\\]/g, '\\$&'))
    .join('.*');
  return new RegExp(`^${regex}${exacto ? '$' : ''}`).test(ruta);
}

export function rutaPermitida(textoRobots, agente, ruta) {
  const todos = grupos(textoRobots);
  const nombre = agente.toLowerCase();
  const propios = todos.filter((g) => g.agentes.some((a) => a !== '*' && nombre.includes(a)));
  const aplicables = propios.length ? propios : todos.filter((g) => g.agentes.includes('*'));
  let mejor = null;
  for (const regla of aplicables.flatMap((g) => g.reglas)) {
    if (!coincide(regla.patron, ruta)) continue;
    const gana =
      !mejor ||
      regla.patron.length > mejor.patron.length ||
      (regla.patron.length === mejor.patron.length && regla.permite);
    if (gana) mejor = regla;
  }
  return mejor ? mejor.permite : true;
}
