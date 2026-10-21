import type { Entrada } from './tipos'

/**
 * Las palabras del negocio, con su definición.
 *
 * Cada una está escrita a partir del código y de sus comentarios, no de
 * memoria. Las cifras que son parámetros del negocio (días de gracia, cargo
 * por atraso, plazos de bloqueo y expulsión, intervalo de cuotas) no se
 * escriben como número: cambian desde Ajustes sin tocar esto.
 *
 * El vocabulario de las cifras (Javier, 27-09) está aquí entero, con el
 * nombre que se usa en pantalla: Pacientes, Registros, Financiamientos,
 * Financiado (sin comisión), Comisión Helios + IVA, Comisión Helios sin IVA,
 * Total a cobrar, Cuota 1 / Cuota 2, Cobrado (a tiempo, con atraso), Vencido,
 * Por vencer, Perdido, Mora (%), Ticket medio (sin comisión) y Días de gracia. Los
 * ids viejos se quedan (los Recientes guardados apuntan a ellos).
 */
export const glosario = [
  {
    tipo: 'termino',
    id: 'dia-operativo',
    titulo: 'Día operativo',
    descripcion: 'El día de Helios, de medianoche a medianoche en Caracas.',
    espacio: 'inicio',
    sinonimos: ['fecha operativa', 'día de caja', 'business date'],
    destino: { to: '/admin' },
    definicion:
      'El día de Helios va de medianoche a medianoche, hora de Caracas, y todo el dinero se cuenta por día operativo. Una semana es de lunes a domingo por día operativo.',
  },

  // ── Quién ──────────────────────────────────────────────────────────────
  {
    tipo: 'termino',
    id: 'usuario',
    titulo: 'Paciente',
    descripcion: 'Un paciente que una clínica registró en Helios; en las cifras de financiamiento y de cobro, contado por sus cuotas.',
    espacio: 'directorio',
    sinonimos: ['pacientes', 'gente', 'usuario', 'pacientes que se financiaron', 'pacientes con deuda vencida'],
    destino: { to: '/admin/pacientes' },
    definicion:
      'Un paciente que una clínica registró en Helios: la secretaria o el administrador lo da de alta en el mismo paso que su primer financiamiento. No tiene app, ni cuenta, ni contraseña. En toda cifra de financiamiento, deuda o cobro se cuenta por sus cuotas (installments.user_id). Así se leen «Pacientes que se financiaron», «Pacientes con deuda vencida» o «Pacientes nuevos en la clínica» (su primera cuota en esa clínica es de ese día o semana). Las cuentas de prueba no cuentan.',
  },
  {
    tipo: 'termino',
    id: 'registro',
    titulo: 'Registro',
    descripcion: 'Un paciente dado de alta por una clínica.',
    espacio: 'gerencia',
    sinonimos: ['registros', 'registrado', 'altas', 'alta de paciente', 'pacientes registrados'],
    destino: { to: '/admin/metricas', search: { vista: 'gente' } },
    definicion:
      'Un paciente cuenta como registro cuando una clínica lo da de alta, y su día de registro es el día operativo de esa alta. La secretaria o el administrador lo registra en el mismo paso que su primer financiamiento, así que nace activo y con nivel 1: no hay app, ni código, ni verificación de identidad que esperar.',
  },

  // ── El financiamiento y su dinero ──────────────────────────────────────
  {
    tipo: 'termino',
    id: 'consumos-termino',
    titulo: 'Financiamientos',
    descripcion: 'El número de financiamientos confirmados: cada consulta que una clínica financió por Helios.',
    espacio: 'directorio',
    sinonimos: ['número de financiamientos', 'consultas', 'cargos', 'transacciones', 'nro. financiamientos'],
    destino: { to: '/admin/financiamientos' },
    definicion:
      'Cuántos financiamientos confirmados hubo: cada consulta que una clínica registró y financió por Helios, por el día operativo del financiamiento. Los anulados o revertidos no cuentan, y los de prueba tampoco.',
  },
  {
    tipo: 'termino',
    id: 'consumo',
    titulo: 'Financiado (sin comisión)',
    descripcion: 'Lo financiado en las clínicas, sin la Comisión Helios: lo que ve la secretaria y lo que ocupa cupo.',
    espacio: 'directorio',
    sinonimos: [
      'financiado',
      'total financiado',
      'financiamiento',
      'financiamiento (sin comisión)',
      'financed',
      'financiamiento sin servicio',
      'sin comisión',
    ],
    destino: { to: '/admin/financiamientos' },
    definicion:
      'La suma de lo financiado en las clínicas en financiamientos confirmados, sin la Comisión Helios: lo que ve la secretaria en su comprobante y lo que ocupa cupo (la suma de financed_usd de sus cuotas). «Total financiado (sin comisión)» es el de todo un periodo. Toda cifra de financiamiento dice si lleva la comisión o no: sin él, «Financiado (sin comisión)» o «Financiamiento (sin comisión)»; con él, «Total a cobrar (financiamiento + comisión)», y siempre con sus dos partes a la vista, porque un total con la comisión dentro nunca va solo.',
  },
  {
    tipo: 'termino',
    // El id se queda (Recientes guardados); el nombre es el que usa Javier.
    id: 'servicio-ronda',
    titulo: 'Comisión Helios + IVA',
    descripcion: 'Lo que el paciente paga a Helios por financiarle la consulta, con su IVA. Donde no cabe, «comisión».',
    espacio: 'caja',
    sinonimos: [
      'Comisión Helios',
      'fee',
      'comisión',
      'comisión del paciente',
      'servicio',
      'servicio helios',
      'servicio de helios',
      'servicio tecnológico',
      'servicio e iva',
      'tarifa',
      'IVA de la Comisión Helios',
    ],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    definicion:
      'Lo que el paciente paga a Helios por financiarle la consulta: un porcentaje sobre el financiado, fijado en los parámetros del negocio, más el IVA que lo grava; en cada cuota es la cuota menos su parte de financiamiento (payable − financed). Va dentro de las cuotas y nunca se suma al financiado en un total suelto: se enseña como línea aparte de un desglose («financiamiento $X · comisión $Y») o repartido en las cuotas. «Comisión Helios + IVA» lleva el IVA dentro; lo que gana Helios es la «Comisión Helios sin IVA», y el IVA solo es el «IVA de la Comisión Helios». A la clínica no le cuesta nada: recibe la consulta entera.',
  },
  {
    tipo: 'termino',
    id: 'service-comisión-sin-iva',
    titulo: 'Comisión Helios sin IVA',
    descripcion: 'El ingreso de Helios: la Comisión Helios de los financiamientos confirmados, sin su IVA.',
    espacio: 'caja',
    sinonimos: ['ingreso de helios', 'ingresos', 'Comisión Helios ganada', 'servicio ganado', 'revenue', 'comisión devengada'],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    definicion:
      'La Comisión Helios de los financiamientos confirmados sin el IVA que lo grava: lo que gana Helios. Se gana al confirmar el financiamiento y se cobra con las cuotas («Comisión Helios sin IVA cobrado» es la parte ya pagada). Los cargos por atraso son otro ingreso y van aparte, y nunca se suma al financiado.',
  },
  {
    tipo: 'termino',
    id: 'total-a-cobrar',
    titulo: 'Total a cobrar',
    descripcion: 'Lo que hay que cobrar de un periodo o de una semana de financiamiento: financiado + Comisión Helios + IVA.',
    espacio: 'cobranza',
    sinonimos: ['a cobrar', 'financiamiento + comisión', 'payable', 'deuda', 'lo que se cobra'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    definicion:
      'La suma de las cuotas (payable) de los financiamientos de un periodo o de una semana de financiamiento: el financiado (sin comisión) más la Comisión Helios + IVA, que es lo que los pacientes tienen que transferir. Se enseña siempre con su desglose a la vista («financiado $X · Comisión Helios $Y»), nunca como un total suelto. Los cargos por atraso no entran.',
  },
  {
    tipo: 'termino',
    id: 'ticket-medio-sin-comisión',
    titulo: 'Ticket medio (sin comisión)',
    descripcion: 'Lo financiado de media en cada financiamiento, sin la Comisión Helios.',
    espacio: 'gerencia',
    sinonimos: ['ticket', 'ticket medio', 'ticket promedio', 'gasto por financiamiento'],
    destino: { to: '/admin/metricas', search: { vista: 'semana' } },
    definicion:
      'El financiado (sin comisión) de un periodo ÷ el número de financiamientos confirmados de ese periodo.',
  },
  {
    tipo: 'termino',
    id: 'numero-de-orden',
    titulo: 'Número de orden',
    descripcion: 'El número que identifica un financiamiento, único en todo Helios.',
    espacio: 'directorio',
    sinonimos: ['orden', 'número de financiamiento'],
    destino: { to: '/admin/financiamientos' },
    definicion:
      'El número que identifica un financiamiento entre todos, único en todo Helios. Es lo que el paciente y la clínica tienen delante cuando llaman.',
  },
  {
    tipo: 'termino',
    id: 'cupo',
    titulo: 'Cupo',
    descripcion: 'El financiado máximo (sin comisión) que un paciente puede tener sin pagar a la vez.',
    espacio: 'riesgo',
    sinonimos: ['límite', 'crédito disponible', 'disponible'],
    destino: { to: '/admin/ajustes', search: { tab: 'niveles' } },
    definicion:
      'El financiado máximo (sin comisión) que un paciente puede tener sin pagar a la vez. Lo fija su nivel y se va gastando con cada financiamiento. No vuelve cuota a cuota: lo de cada financiamiento se libera cuando están pagadas todas sus cuotas, y con una cuota vencida el disponible es cero. La Comisión Helios y los cargos por atraso no ocupan cupo.',
  },
  {
    tipo: 'termino',
    id: 'nivel',
    titulo: 'Nivel',
    descripcion: 'El escalón que fija el cupo de un paciente.',
    espacio: 'riesgo',
    sinonimos: ['escalera de niveles', 'categoría'],
    destino: { to: '/admin/ajustes', search: { tab: 'niveles' } },
    definicion:
      'El escalón que fija el cupo de un paciente. Todo paciente nace con el nivel 1. El estado automático lo sube al nivel más alto cuyos requisitos cumple, gasto pagado y antigüedad, y lo baja cuando el atraso llega a los días de suspensión. El equipo también puede cambiarlo a mano desde su ficha.',
  },

  // ── Las cuotas y su estado ─────────────────────────────────────────────
  {
    tipo: 'termino',
    id: 'cuota',
    titulo: 'Cuota 1 / Cuota 2',
    descripcion: 'Cada una de las dos partes en que un paciente paga su financiamiento, con su desglose.',
    espacio: 'cobranza',
    sinonimos: ['cuota', 'cuotas', 'plazo', 'vencimiento', 'pago en cuotas', 'primera cuota', 'segunda cuota'],
    destino: { to: '/admin/cobranza' },
    definicion:
      'Cada financiamiento se paga en dos cuotas. La cuota 1 vence un intervalo de cuotas después del financiamiento y la cuota 2, otro intervalo después de la 1; el intervalo es un parámetro del negocio. El monto de cada cuota es financiamiento + Comisión Helios (su parte de financiado más su parte de la comisión con su IVA) y se enseña con ese desglose.',
  },
  {
    tipo: 'termino',
    id: 'vencido',
    titulo: 'Vencido',
    descripcion: 'Lo que está sin pagar y cuyo vencimiento ya pasó, sin lo dado por perdido.',
    espacio: 'cobranza',
    sinonimos: ['vencida', 'vencidas', 'cuotas vencidas', 'deuda vencida', 'atrasado', 'plazo vencido'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    definicion:
      'Las cuotas pendientes cuyo día de vencimiento es anterior a hoy (día operativo), sin las dadas por perdidas: financiamiento + Comisión Helios, con su desglose. «Pacientes con deuda vencida» son los que tienen alguna. Ojo: la cola de Por cobrar enseña además la deuda dada por perdida, que se sigue cobrando; su «vencido» lo dice.',
  },
  {
    tipo: 'termino',
    id: 'por-vencer',
    titulo: 'Por vencer',
    descripcion: 'Lo que está sin pagar y vence hoy o más adelante.',
    espacio: 'cobranza',
    sinonimos: ['por vencer', 'sin vencer', 'plazo vigente', 'próximos vencimientos'],
    destino: { to: '/admin/cobranza' },
    definicion:
      'Las cuotas pendientes cuyo día de vencimiento es hoy (día operativo) o posterior, sin las dadas por perdidas: financiamiento + Comisión Helios, con su desglose. Vencido + por vencer es la deuda viva.',
  },
  {
    tipo: 'termino',
    id: 'cobrado',
    titulo: 'Cobrado',
    descripcion: 'Lo que los pacientes ya pagaron de sus cuotas: a tiempo o con atraso.',
    espacio: 'cobranza',
    sinonimos: ['pagado', 'cobrado a tiempo', 'cobrado con atraso', 'cobrado tarde', 'pagada a tiempo', 'a tiempo'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    definicion:
      'Las cuotas pagadas, en financiamiento + Comisión Helios con su desglose. «Cobrado a tiempo» son las pagadas como tarde el último día de gracia (vencimiento + días de gracia) y «Cobrado con atraso», las pagadas después. El día del pago es el día operativo en que se REGISTRÓ el pago, no el de su aprobación. «Cobrado a tiempo (%)» es la parte a tiempo de las cuotas cuyo plazo ya terminó.',
  },
  {
    tipo: 'termino',
    id: 'dado-por-perdido-termino',
    titulo: 'Perdido',
    descripcion: 'La deuda declarada incobrable al llegar al plazo de expulsión.',
    espacio: 'caja',
    sinonimos: ['dado por perdido', 'castigado', 'castigo', 'incobrable', 'write off'],
    destino: { to: '/admin/metricas', search: { vista: 'caja' } },
    definicion:
      'La deuda que se declara incobrable cuando el atraso llega al plazo de expulsión. Deja de contar en lo vencido, en lo por vencer y en lo que se espera cobrar, y pasa a pérdida; se enseña aparte, sin comisión o con su Comisión Helios + IVA según la cifra. En la cola de Por cobrar sigue, porque se sigue llamando.',
  },
  {
    tipo: 'termino',
    id: 'mora',
    titulo: 'Mora (%)',
    descripcion: 'Qué parte de la deuda viva ya venció: vencido ÷ (vencido + por vencer).',
    espacio: 'cobranza',
    sinonimos: ['mora', 'tasa de mora', 'morosidad', 'atraso'],
    destino: { to: '/admin/metricas', search: { vista: 'mora' } },
    definicion:
      'Vencido ÷ (vencido + por vencer), en financiamiento + comisión y sin lo dado por perdido, a una fecha (hoy, o el cierre de una semana). Estar «en mora» es tener algo vencido: desde el primer día de atraso la cuenta queda congelada, tras los días de gracia cae el cargo por atraso, al llegar a los días de la baja pierde un nivel y queda suspendida, y pasado el plazo de expulsión se la expulsa y su deuda se da por perdida.',
  },
  {
    tipo: 'termino',
    id: 'dias-de-gracia',
    titulo: 'Días de gracia',
    descripcion: 'Los días de atraso que se perdonan: dentro de ellos una cuota cuenta como pagada a tiempo.',
    espacio: 'cobranza',
    sinonimos: ['gracia', 'días antes del cargo', 'días de reintento', 'gracia de a tiempo'],
    destino: { to: '/admin/ajustes', search: { tab: 'parametros' } },
    definicion:
      'Los días de atraso que se perdonan sobre una cuota. Es UN solo parámetro del negocio para tres cosas: una cuota pagada dentro de ellos cuenta como cobrada a tiempo; al pasarlos cae el cargo por atraso; y el impago de cada cuota se juzga al acabarlos.',
  },
  {
    tipo: 'termino',
    id: 'cargo-por-atraso',
    titulo: 'Cargo por atraso',
    descripcion: 'El monto que se suma a la deuda de una cuota que sigue sin pagarse tras los días de gracia.',
    espacio: 'cobranza',
    sinonimos: ['multa', 'recargo', 'penalización', 'late comisión'],
    destino: { to: '/admin/cobranza' },
    definicion:
      'Un monto fijo, fijado en los parámetros del negocio, que el estado automático suma a la deuda cuando una cuota sigue sin pagarse tras los días de gracia, una sola vez por cuota. Es ingreso de Helios, va aparte de las cuotas y no se suma a la Comisión Helios. Se puede condonar desde la ficha del paciente si no correspondía.',
  },
  {
    tipo: 'termino',
    id: 'cohorte',
    titulo: 'Cohorte',
    descripcion: 'Los financiamientos de una misma semana, seguidos hasta que se cobran sus dos cuotas.',
    espacio: 'metricas',
    sinonimos: ['cohortes', 'cohorte de financiamiento', 'cohorte de cuotas', 'semana de financiamiento'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    definicion:
      'Los financiamientos cuyo día operativo cae en una misma semana, de lunes a domingo, con sus cuotas 1 y 2. Se siguen hasta el final: su total a cobrar, cuánto se cobró a tiempo, cuánto con atraso, cuánto sigue vencido y cuánto se dio por perdido. No son los pacientes que se registraron juntos: eso es una cohorte de registro.',
  },
  {
    tipo: 'termino',
    id: 'cosecha',
    titulo: 'Cosecha',
    descripcion: 'Los financiamientos de un mismo periodo, seguidos para ver cuánto se cobró y cuánto se perdió.',
    espacio: 'riesgo',
    sinonimos: ['vintage', 'cosecha mensual'],
    destino: { to: '/admin/metricas', search: { vista: 'cobros' } },
    definicion:
      'Los financiamientos de un mismo periodo, seguidos en el tiempo para ver cuánto se cobró y cuánto se dio por perdido. Se agrupan por el día del financiamiento y no por el de la pérdida, y una cosecha solo es definitiva cuando sus últimas cuotas han tenido tiempo de llegar al plazo de expulsión. En Métricas se siguen por semana, y cada una es una cohorte.',
  },

  // ── Cobranza ───────────────────────────────────────────────────────────
  {
    tipo: 'termino',
    id: 'estado-automatico',
    titulo: 'Estado automático',
    descripcion: 'El proceso que cada día recalcula el estado de cada cuenta según su atraso.',
    espacio: 'cobranza',
    sinonimos: ['motor', 'motor de mora'],
    destino: { to: '/admin/cobranza' },
    definicion:
      'El proceso que cada día, al empezar el día operativo, recalcula el estado de cada cuenta según su atraso: congela, bloquea, baja de nivel, pone los cargos por atraso y expulsa, y devuelve a activa a quien ya no tiene cuotas vencidas. Por eso una sanción del equipo no se pone cambiando el estado, sino con un bloqueo manual.',
  },
  {
    tipo: 'termino',
    id: 'bloqueo-manual',
    titulo: 'Bloqueo manual',
    descripcion: 'La sanción que pone el equipo y que el estado automático no deshace.',
    espacio: 'directorio',
    sinonimos: ['bloquear', 'sanción'],
    destino: { to: '/admin/pacientes' },
    definicion:
      'Una sanción que pone alguien del equipo, aparte del estado de la cuenta, para que el estado automático no la deshaga al día siguiente. Mientras dura, ninguna clínica puede financiar al paciente (solo ve «No disponible», sin el motivo), y solo alguien del equipo la levanta.',
  },
  {
    tipo: 'termino',
    id: 'pago-reportado',
    titulo: 'Pago reportado',
    descripcion: 'Un pago que el equipo registró con el comprobante del paciente, a la espera de aprobarse.',
    espacio: 'cobranza',
    sinonimos: ['pago registrado', 'registrar pago', 'comprobante de pago', 'reporte de pago', 'cobro', 'aprobar un pago'],
    destino: { to: '/admin/cobros' },
    definicion:
      'El paciente paga por Pago Móvil o transferencia y manda el comprobante por WhatsApp; alguien del equipo lo registra desde su ficha, con el banco, la referencia, la fecha y el monto, y cae en Pagos reportados. Se aprueba cuando se comprueba contra el extracto del banco, y entonces salda sus cuotas; si no se comprueba, se rechaza.',
  },
  {
    tipo: 'termino',
    id: 'abono-sin-dueno',
    titulo: 'Abono sin dueño',
    descripcion: 'Dinero que entró al banco y no corresponde a ningún pago registrado.',
    espacio: 'cobranza',
    sinonimos: ['depósito sin reportar', 'sin dueño', 'dinero sin reclamar'],
    destino: { to: '/admin/cobros', search: { vista: 'abonos' } },
    definicion:
      'Un ingreso que aparece en el extracto del banco y no corresponde a ningún pago registrado: un paciente transfirió y no mandó el comprobante, se registró con la referencia mal escrita o alguien pagó por otro paciente. Se asigna a quien corresponda o se descarta.',
  },
  {
    tipo: 'termino',
    id: 'extracto',
    titulo: 'Extracto del banco',
    descripcion: 'El archivo de movimientos del banco que se importa para cotejar los pagos.',
    espacio: 'cobranza',
    sinonimos: ['estado de cuenta', 'movimientos del banco', 'xls del banco'],
    destino: { to: '/admin/cobros', search: { importar: true } },
    definicion:
      'El archivo de movimientos que se descarga del banco y se importa en el panel. Sirve para comprobar que cada pago reportado existió y para encontrar los abonos sin dueño. Cada abono se identifica por banco, referencia, fecha y monto, así que importarlo dos veces no duplica nada.',
  },

  // ── Caja y clínicas ────────────────────────────────────────────────────
  {
    tipo: 'termino',
    id: 'liquidacion',
    titulo: 'Liquidación',
    descripcion: 'Lo que Helios le debe a una clínica por el financiamiento de sus pacientes.',
    espacio: 'caja',
    sinonimos: ['settlement', 'deuda con la clínica', 'pago a la clínica'],
    destino: { to: '/admin/pagos-clinicas' },
    definicion:
      'Lo que Helios le debe a una clínica por el financiamiento de sus pacientes: la consulta entera (sin la Comisión Helios, que paga el paciente) más lo que gana su personal. A la clínica se le liquida por la fecha de vencimiento, pague o no el paciente a tiempo, y cada liquidación se transfiere el día siguiente a su vencimiento: cada mitad de la consulta, el día siguiente a su cuota; lo que gana la secretaria, junto con la primera mitad. Puede quedar pagada en parte.',
  },
  {
    tipo: 'termino',
    id: 'cierre-de-caja',
    titulo: 'Día de pago a las clínicas',
    descripcion: 'El día en que se les transfiere a las clínicas lo que se les debe: se paga a diario.',
    espacio: 'caja',
    sinonimos: ['cierre', 'cierre de caja', 'pago diario', 'pago de hoy', 'cierre del lunes'],
    destino: { to: '/admin/pagos-clinicas' },
    definicion:
      'El día en que se les transfiere a las clínicas lo que se les debe. Se paga a diario: cada liquidación pertenece a un solo día de pago, el siguiente a su vencimiento (cada mitad de la consulta, el día siguiente a su cuota; lo que gana la secretaria, junto con la primera mitad), y lo que sale hoy incluye lo atrasado de días anteriores. Hasta el 2026-10-06 era el cierre de los lunes.',
  },
  {
    tipo: 'termino',
    id: 'tasa-bcv',
    titulo: 'Tasa BCV',
    descripcion: 'Las tasas oficiales del dólar y del euro con las que se cotiza cada pago en bolívares.',
    espacio: 'ajustes',
    sinonimos: ['tasa', 'tipo de cambio', 'bcv', 'dólar', 'euro'],
    destino: { to: '/admin/ajustes', search: { tab: 'tasa' } },
    definicion:
      'Las tasas oficiales que publica el Banco Central de Venezuela: la del dólar y la del euro. El paciente solo paga en bolívares, y cada cuota se convierte con la tasa de la moneda de su orden del día en que paga (los cargos por atraso, con la del dólar); a la clínica se le paga igual. Sin la tasa del día no se puede cotizar un pago. Se buscan solas y, si fallan, se cargan a mano.',
  },

  // ── Riesgo y directorio ────────────────────────────────────────────────
  {
    tipo: 'termino',
    id: 'cuenta-de-prueba',
    titulo: 'Cuenta de prueba',
    descripcion: 'Una cuenta o una clínica que no cuenta en ninguna cifra ni en ninguna cola.',
    espacio: 'directorio',
    sinonimos: ['prueba', 'test', 'clínica de prueba'],
    destino: { to: '/admin/pacientes', search: { prueba: true } },
    definicion:
      'Una cuenta o una clínica marcada como prueba. No cuenta en ninguna cifra ni en ninguna cola, pero sigue en las listas con su etiqueta, y sus financiamientos y pagos se escriben en el libro marcados como prueba.',
  },
  {
    tipo: 'termino',
    id: 'marca-interna',
    titulo: 'Marca interna',
    descripcion: 'Una bandera sobre una cuenta que impide que una clínica vuelva a financiar esa cédula.',
    espacio: 'directorio',
    sinonimos: ['lista negra', 'blacklist'],
    destino: { to: '/admin/pacientes', search: { marca: true } },
    definicion:
      'Una bandera sobre una cuenta que sobrevive a cualquier cambio de estado, también a la expulsión. Si una clínica vuelve a buscar esa cédula para financiarla, Helios no la financia: la clínica solo ve «No disponible», sin el motivo.',
  },
] as const satisfies ReadonlyArray<Entrada>
