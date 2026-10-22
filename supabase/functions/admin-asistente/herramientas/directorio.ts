/** Directorio: buscar pacientes, clínicas y órdenes, y leer su ficha. */

import {
  DESDE,
  entero,
  esFila,
  filasSinClaves,
  HASTA,
  leerEntero,
  leerOpcion,
  leerTexto,
  leerUuid,
  objeto,
  opcion,
  rango,
  sinClaves,
  sinVacios,
  textoLibre,
  uuid,
  uuidObligatorio,
} from './esquema.ts';
import type { Entrada, HerramientaDeDatos, PantallaDeHerramienta } from './tipos.ts';

export const ESTADOS_DE_PERSONA = ['pending_kyc', 'pending_pin', 'active', 'frozen', 'suspended', 'expelled'] as const;
export const ESTADOS_DE_CONSUMO = ['pending', 'confirmed', 'voided', 'reverted', 'declined', 'expired'] as const;

/**
 * La ficha trae mucho que no contesta nada (aparatos, movimientos de Bits,
 * avatar: restos de Ronda) y `charges`, que `consumos` ya cubre.
 * `credit.available_usd` es el límite viejo, que no coincide con el freno real.
 */
export function recortarFicha(datos: unknown): unknown {
  const sinPeso = sinClaves(datos, ['devices', 'bits_entries', 'charges', 'avatar_color', 'avatar_emoji']);
  if (!esFila(sinPeso)) return sinPeso;
  return { ...sinPeso, credit: sinClaves(sinPeso.credit, ['available_usd']) };
}

/** La ficha `/admin/<base>/<uuid>` del id que trae la entrada, o `null` si no trae uno válido. */
function fichaDeLaEntrada(base: string, campo: string): (entrada: Entrada) => PantallaDeHerramienta | null {
  return (entrada) => {
    const id = leerUuid(entrada[campo]);
    return id ? { ruta: `/admin/${base}/${id}` } : null;
  };
}

/**
 * Una búsqueda que da una sola fila lleva a la ficha de esa fila; si da
 * varias (o ninguna), a la lista.
 */
function fichaSiEsUnaSola(base: string, campoId: string): (entrada: Entrada, datos: unknown) => PantallaDeHerramienta {
  return (_entrada, datos) => {
    const id = Array.isArray(datos) && datos.length === 1 && esFila(datos[0]) ? leerUuid(datos[0][campoId]) : undefined;
    return { ruta: id ? `/admin/${base}/${id}` : `/admin/${base}` };
  };
}

const PERSONA_ID = uuid('El user_id del paciente (sale de admin_user_directory o de la ruta /admin/pacientes/<uuid>).');

export const directorio: HerramientaDeDatos[] = [
  {
    clase: 'datos',
    nombre: 'admin_user_directory',
    rpc: 'admin_user_directory',
    rotulo: 'Buscando pacientes',
    descripcion:
      'Encuentra a un paciente por nombre (sin tildes), teléfono o cédula, o lista pacientes por estado: es el ' +
      'primer paso de cualquier pregunta sobre alguien por su nombre («¿por qué no puede pagar en cuotas X?»). Da ' +
      'su user_id, estado, nivel, deuda viva y vencida (con la comisión), días de atraso y lo que puede financiar ' +
      'hoy (available_now_usd, sin comisión; available_blocked_reason dice por qué es 0). Los nombres llegan ' +
      'acortados (primer nombre e inicial) y teléfono y cédula tapados; para el nombre entero y el detalle de UN ' +
      'paciente, después admin_user_detail o admin_collection_case. Pantalla: /admin/pacientes.',
    esquema: objeto({
      buscar: textoLibre('Nombre, teléfono o cédula. Si se omite, lista sin filtrar por texto.'),
      estado: opcion(ESTADOS_DE_PERSONA, 'Solo pacientes en este estado.'),
      limite: entero('Cuántas filas como mucho, de 1 a 50. Por defecto 20.'),
    }),
    argumentos: (e) =>
      sinVacios({
        p_search: leerTexto(e.buscar, 100),
        p_status: leerOpcion(e.estado, ESTADOS_DE_PERSONA),
        p_limit: leerEntero(e.limite, 1, 50) ?? 20,
      }),
    recortar: (datos) => filasSinClaves(datos, ['available_usd']),
    pantalla: fichaSiEsUnaSola('pacientes', 'user_id'),
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_user_detail',
    rpc: 'admin_user_detail',
    rotulo: 'Leyendo la ficha del paciente',
    descripcion:
      'Contesta preguntas sobre UN paciente («¿por qué está congelada María?», «¿por qué no puede pagar en ' +
      'cuotas?»): estado, nivel, límite (credit.available_now_usd y el motivo si no puede financiar), deuda, ' +
      'cuotas, órdenes (consumos), pagos, lista negra y cambios de nivel. Necesita el user_id ' +
      '(admin_user_directory). Clases: consumos[].*_usd y credit.available_* son financiado, sin comisión; debt ' +
      'y las cuotas son deuda con la comisión. Aquí el nombre llega entero; teléfono y cédula, tapados. ' +
      'Pantalla: /admin/pacientes/<user_id>.',
    esquema: objeto({ persona_id: PERSONA_ID }, ['persona_id']),
    argumentos: (e) => ({ p_user_id: uuidObligatorio(e.persona_id, 'persona_id') }),
    recortar: recortarFicha,
    pantalla: fichaDeLaEntrada('pacientes', 'persona_id'),
    datosPersonales: 'ficha',
  },
  {
    clase: 'datos',
    nombre: 'admin_collection_case',
    rpc: 'admin_collection_case',
    rotulo: 'Leyendo el caso de cobranza',
    descripcion:
      'Contesta la situación de cobranza de UN paciente: tramo (al_dia si no debe nada dentro del horizonte), ' +
      'deuda vencida y por vencer (con la comisión), días de atraso, última gestión, promesa y su estado, y último ' +
      'pago. Necesita el user_id (admin_user_directory). null si el paciente no existe o es de prueba. ' +
      'Pantalla: /admin/pacientes/<user_id>.',
    esquema: objeto({
      persona_id: PERSONA_ID,
      horizonte_dias: entero('Incluye lo que vence en estos días, de 0 a 30. Por defecto 3.'),
    }, ['persona_id']),
    argumentos: (e) =>
      sinVacios({
        p_user: uuidObligatorio(e.persona_id, 'persona_id'),
        p_horizon_days: leerEntero(e.horizonte_dias, 0, 30),
      }),
    pantalla: fichaDeLaEntrada('pacientes', 'persona_id'),
    datosPersonales: 'ficha',
  },
  {
    clase: 'datos',
    nombre: 'admin_charges',
    rpc: 'admin_charges',
    rotulo: 'Buscando órdenes',
    descripcion:
      'Busca órdenes por número, paciente, clínica, estado o fechas (día de registro). Estados: pending (esperando ' +
      'al paciente), confirmed, declined (el paciente dijo que no), expired (no contestó), voided (anulada), ' +
      'reverted. Por orden: número, estado, clínica, médico, paciente, cuotas pagadas, concepto y financed_usd (la ' +
      'consulta, sin comisión). Incluye las de prueba marcadas con is_test: no las cuentes. Para sumar lo ' +
      'financiado en una semana, admin_weekly_summary. Pantalla: /admin/financiamientos y la ficha ' +
      '/admin/financiamientos/<charge_id>.',
    esquema: objeto({
      buscar: textoLibre('Número de orden, nombre o teléfono.'),
      local_id: uuid('Solo las de esta clínica (merchant_id).'),
      estado: opcion(ESTADOS_DE_CONSUMO, 'Solo en este estado.'),
      desde: DESDE,
      hasta: HASTA,
      limite: entero('Cuántas filas como mucho, de 1 a 100. Por defecto 50.'),
    }),
    argumentos: (e) =>
      sinVacios({
        p_search: leerTexto(e.buscar, 100),
        p_merchant_id: leerUuid(e.local_id),
        p_status: leerOpcion(e.estado, ESTADOS_DE_CONSUMO),
        ...rango(e),
        p_limit: leerEntero(e.limite, 1, 100) ?? 50,
      }),
    // amount_usd es la orden CON la comisión: un total con la comisión sumada.
    recortar: (datos) => filasSinClaves(datos, ['amount_usd']),
    pantalla: fichaSiEsUnaSola('financiamientos', 'charge_id'),
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_charge_detail',
    rpc: 'admin_charge_detail',
    rotulo: 'Leyendo la orden',
    descripcion:
      'Contesta el detalle de UNA orden: clínica y sede, médico, paciente, concepto, moneda y cuotas. ' +
      'financed_usd es la consulta sin comisión; consumer_fee_usd y consumer_fee_vat_usd son la Comisión Helios ' +
      'y su IVA como líneas aparte del desglose (nunca se suman a la consulta); las cuotas son deuda con la ' +
      'comisión repartida. Pantalla: /admin/financiamientos/<charge_id>.',
    esquema: objeto({ consumo_id: uuid('El charge_id de la orden (sale de admin_charges).') }, ['consumo_id']),
    argumentos: (e) => ({ p_charge_id: uuidObligatorio(e.consumo_id, 'consumo_id') }),
    recortar: (datos) => sinClaves(datos, ['amount_usd']),
    pantalla: fichaDeLaEntrada('financiamientos', 'consumo_id'),
    datosPersonales: 'lista',
  },
  {
    clase: 'datos',
    nombre: 'admin_merchant_stats',
    rpc: 'admin_merchant_stats',
    rotulo: 'Leyendo las cifras de la clínica',
    descripcion:
      'Contesta sobre UNA clínica: financiado y monto medio por orden en la ventana (sin comisión), número de ' +
      'órdenes, y la cartera de sus pacientes (portfolio: total a cobrar, pagado, vencido, perdido y cobro a ' +
      'tiempo, todo deuda con la comisión). El merchant_id sale de admin_merchant_risk o admin_merchant_payables. ' +
      'Pantalla: /admin/clinicas/<merchant_id>.',
    esquema: objeto({
      local_id: uuid('El merchant_id de la clínica.'),
      dias: entero('Ventana en días, de 1 a 365. Por defecto 30.'),
    }, ['local_id']),
    argumentos: (e) =>
      sinVacios({
        p_merchant_id: uuidObligatorio(e.local_id, 'local_id'),
        p_days: leerEntero(e.dias, 1, 365),
      }),
    recortar: (datos) => sinClaves(datos, ['distinct_users']),
    pantalla: fichaDeLaEntrada('clinicas', 'local_id'),
    datosPersonales: 'lista',
  },
];
