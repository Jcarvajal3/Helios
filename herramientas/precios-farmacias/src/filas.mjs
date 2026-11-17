// El contrato del CSV: columnas, validación, exclusión de farmacias,
// deduplicación y escritura. Toda fila de toda fuente pasa por prepararFilas.

export const COLUMNAS = [
  'farmacia',
  'nombre',
  'precio',
  'moneda',
  'laboratorio',
  'presentacion',
  'sku',
  'url',
  'disponible',
  'visto_en',
  'fuente',
];

// Farmacias que no son de Caracas (decisión de Javier). Se comparan con
// normalizarTexto, así que da igual si vienen en mayúsculas, con acento o
// con espacios («FARMA DÓN»).
const FARMACIAS_EXCLUIDAS = ['farmadon', 'farmapaz'];

export function normalizarTexto(texto) {
  return String(texto ?? '')
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

export function esFarmaciaExcluida(farmacia) {
  const normal = normalizarTexto(farmacia);
  return FARMACIAS_EXCLUIDAS.some((excluida) => normal.includes(excluida));
}

// Si la concentración viene en otro campo y el nombre no la trae, va al final.
export function unirConcentracion(nombre, concentracion) {
  const base = String(nombre ?? '').trim();
  const dosis = String(concentracion ?? '').trim();
  if (!dosis) return base;
  return normalizarTexto(base).includes(normalizarTexto(dosis)) ? base : `${base} ${dosis}`;
}

// Devuelve el precio como texto con punto decimal, o null si no es válido.
// No adivina formatos: «1.234,56» y «1,22» se rechazan.
export function formatearPrecio(valor) {
  if (typeof valor !== 'number' && typeof valor !== 'string') return null;
  const texto = String(valor).trim();
  if (!/^\d+(\.\d+)?$/.test(texto)) return null;
  return Number(texto) > 0 ? texto : null;
}

const ISO_CON_ZONA = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

// Devuelve { fila } con los campos ya en su forma final, o { motivo } si no entra.
export function validarFila(entrada) {
  const texto = (campo) => String(entrada[campo] ?? '').trim();
  const fila = Object.fromEntries(COLUMNAS.map((columna) => [columna, texto(columna)]));

  if (!fila.farmacia) return { motivo: 'sin_farmacia' };
  if (!fila.nombre) return { motivo: 'sin_nombre' };
  const precio = formatearPrecio(entrada.precio);
  if (precio === null) return { motivo: 'precio_invalido' };
  fila.precio = precio;
  if (fila.moneda !== 'VES' && fila.moneda !== 'USD') return { motivo: 'moneda_invalida' };
  if (!fila.url.startsWith('https://')) return { motivo: 'url_no_https' };
  if (!['si', 'no', ''].includes(fila.disponible)) return { motivo: 'disponible_invalido' };
  if (!ISO_CON_ZONA.test(fila.visto_en)) return { motivo: 'visto_en_invalido' };
  if (!fila.fuente) return { motivo: 'sin_fuente' };
  return { fila };
}

// Excluye, valida y deduplica. Ante dos lecturas del mismo producto se queda
// con la más reciente.
export function prepararFilas(entradas) {
  const porClave = new Map();
  const rechazos = {};
  let excluidas = 0;
  let duplicadas = 0;

  for (const entrada of entradas) {
    if (esFarmaciaExcluida(entrada.farmacia)) {
      excluidas += 1;
      continue;
    }
    const { fila, motivo } = validarFila(entrada);
    if (!fila) {
      rechazos[motivo] = (rechazos[motivo] ?? 0) + 1;
      continue;
    }
    const producto = fila.sku ? `sku:${fila.sku}` : `nombre:${normalizarTexto(fila.nombre)}`;
    const clave = `${normalizarTexto(fila.farmacia)}|${producto}`;
    const anterior = porClave.get(clave);
    if (anterior) {
      duplicadas += 1;
      if (Date.parse(fila.visto_en) < Date.parse(anterior.visto_en)) continue;
    }
    porClave.set(clave, fila);
  }
  return { filas: [...porClave.values()], excluidas, duplicadas, rechazos };
}

function campoCsv(valor) {
  const texto = String(valor);
  return /[",\r\n]/.test(texto) ? `"${texto.replaceAll('"', '""')}"` : texto;
}

export function aCsv(filas) {
  const lineas = [COLUMNAS.join(',')];
  for (const fila of filas) {
    lineas.push(COLUMNAS.map((columna) => campoCsv(fila[columna])).join(','));
  }
  return `${lineas.join('\n')}\n`;
}

export function leerCsv(contenido) {
  const registros = [];
  let registro = [];
  let campo = '';
  let entreComillas = false;
  for (let i = 0; i < contenido.length; i += 1) {
    const c = contenido[i];
    if (entreComillas) {
      if (c === '"' && contenido[i + 1] === '"') {
        campo += '"';
        i += 1;
      } else if (c === '"') {
        entreComillas = false;
      } else {
        campo += c;
      }
    } else if (c === '"') {
      entreComillas = true;
    } else if (c === ',') {
      registro.push(campo);
      campo = '';
    } else if (c === '\n') {
      registro.push(campo);
      registros.push(registro);
      registro = [];
      campo = '';
    } else if (c !== '\r') {
      campo += c;
    }
  }
  const [cabecera, ...resto] = registros;
  return resto.map((valores) => Object.fromEntries(cabecera.map((nombre, i) => [nombre, valores[i]])));
}

// «2026-11-06T10:35:00-04:00»: la hora de Caracas con su zona.
export function horaCaracas(fecha = new Date()) {
  const partes = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Caracas',
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      timeZoneName: 'longOffset',
    })
      .formatToParts(fecha)
      .map((parte) => [parte.type, parte.value]),
  );
  const zona = partes.timeZoneName.replace('GMT', '') || '+00:00';
  return `${partes.year}-${partes.month}-${partes.day}T${partes.hour}:${partes.minute}:${partes.second}${zona}`;
}

export function fechaCompacta(fecha = new Date()) {
  return horaCaracas(fecha).slice(0, 10).replaceAll('-', '');
}
