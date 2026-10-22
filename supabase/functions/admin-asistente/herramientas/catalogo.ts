/**
 * Las vistas que `consultar_datos` puede leer, contadas al modelo.
 *
 * La fuente es la migración `20261023010000_el_asistente_habla_de_pacientes_y_clinicas.sql`:
 * si una vista, una columna o un estado cambia allí, cambia aquí en el mismo
 * commit. Va en el system prompt (prefijo cacheado), así que se toca poco y a
 * propósito.
 *
 * Los estados están en español en la base (`asistente.estado`): el modelo los
 * filtra y los enseña tal cual, sin traducir nada.
 */

type Vista = { nombre: string; que: string; columnas: string };

export const VISTAS: readonly Vista[] = [
  {
    nombre: 'pacientes',
    que: 'una fila por paciente registrado',
    columnas:
      'user_id, paciente («MARÍA P.»), alta_at, alta_dia (día de Caracas), estado (activo, congelado, suspendido, ' +
      'cerrado…), nivel, en_lista_negra, sexo, edad, estado_del_pais (Miranda, Zulia…), ciudad, clinica_de_registro ' +
      '(la clínica que lo registró), primera_orden_at, ultima_orden_at, ordenes (confirmadas), consulta_usd ' +
      '(financiado, sin comisión)',
  },
  {
    nombre: 'clinicas',
    que: 'las clínicas y consultorios',
    columnas:
      'clinica_id, clinica, medico (el titular, con su título: «Dra. Nadia Khabbaze»), especialidad (texto libre), ' +
      'categoria (clinica, consultorio, odontologia, cosmetologia, laboratorio, imagenes), estado (activa, pausada, ' +
      'cerrada), ciudad, alta_at',
  },
  {
    nombre: 'ordenes',
    que:
      "cada orden de pago en cuotas que registra una clínica; solo cuentan como financiadas las de estado = 'confirmada' " +
      '(también hay esperando al paciente, rechazada por el paciente, vencida sin respuesta, anulada y revertida)',
    columnas:
      'orden_id, numero_orden, user_id y paciente, clinica_id, clinica, medico, sede, concepto (lo que se cobra: ' +
      '«Consulta»…), estado, canal (panel o whatsapp: desde dónde la registró el médico), moneda (USD o EUR), dia ' +
      '(el día en que se registró), creada_at, respondida_at (cuando el paciente dijo sí o no), confirmada_at, ' +
      'anulada_at, consulta_usd (financiado, SIN comisión: lo que recibe la clínica), comision_usd (Comisión Helios ' +
      'sin IVA), comision_iva_usd, total_a_cobrar_usd (CON la comisión: lo que paga el paciente en cuotas), ' +
      'a_la_clinica_usd, consulta_en_moneda (la consulta en la moneda de la orden), motivo_rechazo',
  },
  {
    nombre: 'cuotas',
    que: 'cada cuota de una orden confirmada (dos por orden)',
    columnas:
      'cuota_id, orden_id, numero_orden, user_id, paciente, clinica_id, clinica, dia_de_la_orden, moneda, numero ' +
      '(1 o 2), vence_el, estado (pendiente, pagada), vencida (pendiente y ya pasó el día), dias_atraso, cuota_usd ' +
      '(deuda CON comisión), consulta_usd (la parte de la consulta, SIN comisión), cuota_en_moneda, pagada_at, ' +
      'pagada_dia, castigada_at (dada por perdida)',
  },
  {
    nombre: 'pagos_reportados',
    que: 'cada pago de cuotas que se registra para revisar (lo registra el equipo o el bot desde el comprobante)',
    columnas:
      'pago_id, user_id, paciente, estado (reportado, en revisión, aprobado, rechazado, duplicado), metodo ' +
      '(pago_movil, transferencia), banco, registrado_por (equipo o bot), pagado_el, reportado_at, revisado_at, ' +
      'monto_usd (deuda con comisión), monto_ves (lo que dice el comprobante, en bolívares), cuotas',
  },
  {
    nombre: 'comprobantes',
    que: 'cada comprobante (foto o datos escritos) que un paciente manda por WhatsApp y lee el bot',
    columnas:
      'lectura_id, user_id, paciente, tipo (captura, datos), estado (pendiente, leyendo, esperando_referencia, ' +
      'esperando_aviso, registrado, duplicado, para_el_equipo, descartado, sombra), modo (sombra, activo), motivo ' +
      '(por qué fue al equipo: monto_no_cuadra, cuenta_ajena…), metodo, banco, monto_ves, pagado_el, intentos, ' +
      'recibido_at, decidido_at',
  },
  {
    nombre: 'liquidaciones',
    que: 'lo que Helios le debe pagar a cada clínica, partida a partida (dos mitades por orden y comisiones del personal)',
    columnas:
      'liquidacion_id, clinica_id, clinica, orden_id, numero_orden, motivo (mitad de la consulta, adelanto, al cobrar, ' +
      'comisión del personal), estado (pendiente, pagada en parte, pagada), se_paga_el, dia, moneda, monto_usd, ' +
      'pagado_usd, monto_en_moneda',
  },
  {
    nombre: 'pagos_a_clinicas',
    que: 'cada transferencia de Helios a una clínica',
    columnas: 'pago_id, clinica_id, clinica, monto_usd, monto_ves, tasa, metodo, pagado_el, dia, creado_at',
  },
  {
    nombre: 'contactos_cobranza',
    que: 'cada llamada, WhatsApp o visita del equipo de cobranza',
    columnas:
      'contacto_id, user_id, paciente, canal (whatsapp, llamada, en_local, otro), plantilla, resultado, promesa_para, ' +
      'proxima_accion, contactado_at',
  },
  {
    nombre: 'mensajes',
    que: 'cada WhatsApp o correo que sale de Helios (a pacientes y a médicos)',
    columnas:
      'mensaje_id, user_id, paciente (vacío si fue a un médico), orden_id, canal (whatsapp, whatsapp_manual, email), ' +
      'plantilla (bienvenida, confirmar_financiamiento, comprobante_financiamiento, bot_respuesta…), estado ' +
      '(pendiente, enviado, omitido, fallido, cancelado), intentos, error, creado_at, enviado_at',
  },
  { nombre: 'niveles', que: 'la escalera de niveles', columnas: 'nivel, nombre, limite_usd, activo' },
];

/** Consultas de ejemplo, para que el modelo copie la forma. */
const EJEMPLOS: ReadonlyArray<readonly [string, string]> = [
  [
    '¿Qué especialidad financia más?',
    "select c.categoria, count(*) as ordenes, sum(o.consulta_usd) as consulta_usd from ordenes o join clinicas c using " +
    "(clinica_id) where o.estado = 'confirmada' group by 1 order by 3 desc",
  ],
  [
    '¿Cuántas órdenes aceptan, rechazan o dejan vencer los pacientes?',
    "select estado, count(*) as ordenes from ordenes where estado <> 'anulada' group by 1 order by 2 desc",
  ],
  [
    '¿Cuántos pacientes ha atendido cada médico?',
    "select medico, clinica, count(distinct user_id) as pacientes, count(*) as ordenes from ordenes " +
    "where estado = 'confirmada' group by 1, 2 order by 3 desc",
  ],
  [
    '¿Cómo les fue a los WhatsApp de esta semana?',
    "select plantilla, count(*) as mensajes, count(*) filter (where estado = 'fallido') as fallidos from mensajes " +
    "where canal = 'whatsapp' and (creado_at at time zone 'America/Caracas')::date >= date_trunc('week', hoy())::date " +
    'group by 1 order by 2 desc',
  ],
  [
    'Financiado de los últimos 7 días, día a día',
    "select dia, sum(consulta_usd) as consulta_usd, count(*) as ordenes from ordenes " +
    "where estado = 'confirmada' and dia > hoy() - 7 group by 1 order by 1",
  ],
];

export function catalogoParaElPrompt(): string {
  const vistas = VISTAS.map((v) => `- ${v.nombre}: ${v.que}. Columnas: ${v.columnas}.`).join('\n');
  const ejemplos = EJEMPLOS.map(([pregunta, sql]) => `- «${pregunta}» → ${sql}`).join('\n');
  return [
    'Con consultar_datos lees estas vistas con un SELECT (PostgreSQL). Ya vienen sin cuentas ni clínicas de prueba, ' +
    'con los estados en español y con el nombre de cada paciente y de cada clínica.',
    vistas,
    '',
    'Funciones de fecha: hoy() (el día de hoy en Caracas). Las columnas *_at son instantes en UTC: para el día usa ' +
    "(x at time zone 'America/Caracas')::date.",
    'Reglas del SQL:',
    '- Un solo SELECT (o WITH … SELECT), sin punto y coma y sin prefijo de esquema.',
    '- Agrega en la base (count, sum, avg, group by) y trae solo las filas que vas a usar: como mucho 200.',
    '- Selecciona columnas que una persona entienda: paciente, clinica, medico, numero_orden, fechas y cifras. Los *_id ' +
    'sirven para unir vistas, no para enseñarlos.',
    '- Nunca sumes consulta_usd con comision_usd ni mezcles montos sin comisión (consulta_usd) con montos con comisión ' +
    '(cuota_usd, total_a_cobrar_usd, monto_usd de pagos_reportados).',
    '- Para sumar dinero usa siempre las columnas *_usd; las *_en_moneda mezclan dólares y euros.',
    "- Si la persona nombra categorías que pueden salir en cero, que salgan igual: from (values ('USD'), ('EUR')) " +
    's(moneda) left join ordenes o using (moneda).',
    '- Si la pregunta no fija un periodo, no filtres por fecha: usa todo lo registrado y dilo en la línea de la fuente.',
    '- Si la consulta falla, lee el error, corrígela y vuelve a intentarlo una vez.',
    'Ejemplos:',
    ejemplos,
  ].join('\n');
}
