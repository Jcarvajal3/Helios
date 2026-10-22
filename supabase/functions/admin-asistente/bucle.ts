/**
 * El bucle de herramientas: pregunta, consultas, respuesta, en streaming.
 *
 * No sabe qué modelo hay detrás: habla con un `Proveedor` (ver `proveedor.ts`).
 * Cada vuelta le cuenta al panel qué se está leyendo, guarda lo que piden las
 * herramientas de presentación y aplica las reglas de parada:
 * - `rechazo`: no se ejecuta nada de esa vuelta (un rechazo puede cortar una
 *   llamada a medias) y el panel recibe un error sobrio;
 * - `corte` con llamadas: la entrada llegó truncada y no se ejecuta;
 * - la última vuelta (`MAX_VUELTAS`) va sin herramientas: el modelo contesta
 *   con lo que ya leyó;
 * - una vuelta con texto que solo pide herramientas de presentación cierra la
 *   respuesta: se dibuja lo pedido y no se vuelve a preguntar;
 * - el texto pasa por `texto.ts`, que corta una llamada escrita como texto.
 *
 * Al terminar pinta, detrás del texto que los explica, las tablas y los gráficos
 * que armaron las herramientas de datos con lo leído (`visualizar`) y lo que
 * pidieron las de presentación; un gráfico o una tabla del modelo no se dibuja
 * si una consulta ya dibujó uno con las filas de la base. Si terminó bien,
 * enlaza además solo las pantallas de las herramientas de datos que se usaron
 * (ver `enlaces.ts`).
 */

import type { Base } from './base.ts';
import { MAX_VUELTAS } from './config.ts';
import { enlacesAutomaticos } from './enlaces.ts';
import { ejecutarHerramienta } from './herramientas/ejecutar.ts';
import { buscarHerramienta, definiciones } from './herramientas/index.ts';
import type { PantallaDeHerramienta } from './herramientas/tipos.ts';
import type { Mapa } from './mapa.ts';
import type { BloqueLlamada, BloqueResultado, BloqueTexto, EventoDelModelo, MensajeNeutral, Proveedor } from './proveedor.ts';
import type { Canal, Enlace, ErrorDelAsistente, Evento } from './sse.ts';
import { crearFiltroDeTexto } from './texto.ts';

export type OpcionesDeCorrida<Nativo = unknown> = {
  proveedor: Proveedor<Nativo>;
  system: string;
  mensajes: ReadonlyArray<MensajeNeutral<Nativo>>;
  base: Base;
  mapa: Mapa;
  canal: Pick<Canal, 'enviar' | 'senal'>;
};

export type ResumenDeCorrida = {
  herramientas: string[];
  modelo: string;
  entrada: number;
  salida: number;
  cacheLeida: number;
};

const DEFINICIONES = definiciones();

export const AVISO_ULTIMA_VUELTA =
  'Ya no puedes hacer más consultas en esta pregunta. Contesta con lo que ya leíste y di con claridad qué no llegaste a comprobar.';

type FinDeVuelta<Nativo> = Extract<EventoDelModelo<Nativo>, { tipo: 'fin' }>;

/** Lo que se va viendo en la corrida, para lo que se pinta al final. */
type Registro = {
  pantallas: PantallaDeHerramienta[];
  enlazados: Enlace[];
  /** Lo que se pinta al final, en orden: tablas y gráficos de las consultas y lo que pidió el modelo. */
  vistas: Evento[];
  /** Las formas que ya dibujó una consulta con las filas de la base. */
  dibujadasPorDatos: Set<'grafico' | 'tabla'>;
  /** Las tablas y los gráficos de consultas, para que uno corregido sustituya al anterior. */
  deDatos: Evento[];
};

/**
 * Si una consulta repite lo que ya dibujó otra de la misma respuesta: mismo
 * gráfico con alguna categoría en común y la misma unidad, o tabla con las
 * mismas columnas. Pasa cuando el modelo corrige la consulta (p. ej. para que
 * salga una categoría en cero) y la segunda es la buena.
 */
export function repiteLaVista(antes: Evento, ahora: Evento): boolean {
  if (antes.tipo === 'grafico' && ahora.tipo === 'grafico') {
    const etiquetas = new Set(antes.datos.puntos.map((p) => p.etiqueta));
    return antes.datos.tipo === ahora.datos.tipo && antes.datos.unidad === ahora.datos.unidad &&
      ahora.datos.puntos.some((p) => etiquetas.has(p.etiqueta));
  }
  if (antes.tipo === 'tabla' && ahora.tipo === 'tabla') {
    const claves = (t: typeof antes.datos) => t.columnas.map((c) => c.clave).join('|');
    return claves(antes.datos) === claves(ahora.datos);
  }
  return false;
}

export async function correrAsistente<Nativo>(o: OpcionesDeCorrida<Nativo>): Promise<ResumenDeCorrida> {
  const mensajes: Array<MensajeNeutral<Nativo>> = [...o.mensajes];
  const resumen: ResumenDeCorrida = { herramientas: [], modelo: o.proveedor.modelo, entrada: 0, salida: 0, cacheLeida: 0 };
  const registro: Registro = { pantallas: [], enlazados: [], vistas: [], dibujadasPorDatos: new Set(), deDatos: [] };
  let huboError = false;
  const error = (datos: ErrorDelAsistente) => {
    huboError = true;
    o.canal.enviar({ tipo: 'error', datos });
  };

  try {
    for (let vuelta = 1; vuelta <= MAX_VUELTAS; vuelta++) {
      const ultima = vuelta === MAX_VUELTAS;
      const llamadas: BloqueLlamada[] = [];
      let escribio = false;
      let fin: FinDeVuelta<Nativo> | null = null;
      const filtro = crearFiltroDeTexto();
      const escribir = (delta: string) => {
        if (delta === '') return;
        if (delta.trim() !== '') escribio = true;
        o.canal.enviar({ tipo: 'texto', datos: { delta } });
      };

      for await (
        const evento of o.proveedor.responder({
          system: o.system,
          mensajes,
          herramientas: DEFINICIONES,
          permitirHerramientas: !ultima,
          senal: o.canal.senal,
        })
      ) {
        if (evento.tipo === 'texto') escribir(filtro.empujar(evento.delta));
        else if (evento.tipo === 'llamada') llamadas.push(evento.llamada);
        else fin = evento;
      }
      escribir(filtro.vaciar());
      if (!fin) throw new Error('El proveedor terminó sin evento de fin');

      resumen.modelo = fin.modelo;
      resumen.entrada += fin.uso.entrada;
      resumen.salida += fin.uso.salida;
      resumen.cacheLeida += fin.uso.cacheLeida;

      if (fin.motivo === 'rechazo') {
        error({ codigo: 'otro', mensaje: 'El asistente no puede responder a esta pregunta.', reintentar: false });
        break;
      }
      if (fin.motivo === 'fallo') {
        error({ codigo: 'otro', mensaje: 'El asistente devolvió una respuesta que no se pudo usar. Vuelve a intentarlo.', reintentar: true });
        break;
      }
      if (fin.motivo === 'contexto_lleno') {
        error({ codigo: 'conversacion_larga', mensaje: 'La conversación es demasiado larga. Empieza una conversación nueva.', reintentar: false });
        break;
      }
      if (llamadas.length === 0 || ultima) break;
      if (fin.motivo === 'corte') {
        error({ codigo: 'otro', mensaje: 'La respuesta se cortó antes de terminar la consulta. Vuelve a intentarlo.', reintentar: true });
        break;
      }

      mensajes.push({ rol: 'asistente', bloques: fin.turno.bloques, nativo: fin.turno.nativo });
      // Primero las consultas, a la vez; después lo que se dibuja, en orden: así
      // un gráfico del modelo ya sabe si la consulta dibujó el suyo.
      const esPresentacion = (l: BloqueLlamada) => buscarHerramienta(l.nombre)?.clase === 'presentacion';
      const porId = new Map<string, BloqueResultado>();
      await Promise.all(llamadas.filter((l) => !esPresentacion(l)).map(async (l) => {
        porId.set(l.id, await ejecutarLlamada(l, o, resumen, registro));
      }));
      for (const l of llamadas.filter(esPresentacion)) porId.set(l.id, await ejecutarLlamada(l, o, resumen, registro));
      const resultados = llamadas.map((l) => porId.get(l.id)).filter((r): r is BloqueResultado => r !== undefined);
      // Con la respuesta ya escrita y solo enlaces, gráficos o tablas pendientes,
      // la pregunta está contestada: otra vuelta solo sirve para que el modelo
      // repita el texto (el ligero lo hace) y gasta cuota.
      if (escribio && llamadas.every((l) => buscarHerramienta(l.nombre)?.clase === 'presentacion')) break;
      const bloques: Array<BloqueTexto | BloqueResultado> = [...resultados];
      // Antes de la última vuelta se le avisa, detrás de los resultados.
      if (vuelta + 1 === MAX_VUELTAS) bloques.push({ tipo: 'texto', texto: AVISO_ULTIMA_VUELTA });
      mensajes.push({ rol: 'persona', bloques });
    }
  } catch (e) {
    const descrito = o.canal.senal.aborted ? null : o.proveedor.describirError(e);
    if (!descrito) return resumen;
    console.error('asistente: la consulta al modelo falló', e instanceof Error ? e.message : String(e));
    error(descrito);
  }

  // Las tablas, los gráficos y los enlaces van detrás del texto que los explica,
  // en el orden en que se pidieron. Salen también si el modelo falló después.
  for (const vista of registro.vistas) o.canal.enviar(vista);

  if (!huboError) {
    for (const enlace of enlacesAutomaticos(o.mapa, registro.pantallas, registro.enlazados)) {
      o.canal.enviar({ tipo: 'enlace', datos: enlace });
    }
  }

  const intentos = o.proveedor.intentos?.() ?? [];
  o.canal.enviar({
    tipo: 'fin',
    datos: {
      modelo: resumen.modelo,
      entrada: resumen.entrada,
      salida: resumen.salida,
      cacheLeida: resumen.cacheLeida,
      ...(intentos.length > 0 ? { intentos: [...intentos] } : {}),
    },
  });
  return resumen;
}

async function ejecutarLlamada<Nativo>(
  llamada: BloqueLlamada,
  o: OpcionesDeCorrida<Nativo>,
  resumen: ResumenDeCorrida,
  registro: Registro,
): Promise<BloqueResultado> {
  const herramienta = buscarHerramienta(llamada.nombre);
  if (!herramienta) {
    return {
      tipo: 'resultado',
      id: llamada.id,
      nombre: llamada.nombre,
      esError: true,
      contenido: `No existe la herramienta ${llamada.nombre}.`,
    };
  }
  resumen.herramientas.push(herramienta.nombre);

  // Un gráfico o una tabla del modelo con las cifras que la consulta ya dibujó
  // sale repetido; el de la consulta es el bueno: sus cifras no pasan por el modelo.
  const forma = herramienta.nombre === 'mostrar_grafico' ? 'grafico' : herramienta.nombre === 'mostrar_tabla' ? 'tabla' : null;
  if (forma && registro.dibujadasPorDatos.has(forma)) {
    return {
      tipo: 'resultado',
      id: llamada.id,
      nombre: llamada.nombre,
      esError: true,
      contenido:
        `No se dibuja: el panel ya enseña ${forma === 'grafico' ? 'el gráfico' : 'la tabla'} de consultar_datos con las filas de la base. ` +
        'Si falta una categoría (por ejemplo, una con cero), dilo en el texto.',
    };
  }

  const rotulo = herramienta.clase === 'datos' ? herramienta.rotulo : null;
  if (rotulo) o.canal.enviar({ tipo: 'herramienta', datos: { id: llamada.id, rotulo, estado: 'consultando' } });

  let resultado: Awaited<ReturnType<typeof ejecutarHerramienta>>;
  try {
    resultado = await ejecutarHerramienta(herramienta, llamada.entrada, { base: o.base, mapa: o.mapa });
  } catch (e) {
    console.error('asistente: la herramienta falló', llamada.nombre, e instanceof Error ? e.message : String(e));
    resultado = { contenido: 'La consulta falló por un error inesperado.', esError: true };
  }

  if (rotulo) {
    o.canal.enviar({ tipo: 'herramienta', datos: { id: llamada.id, rotulo, estado: resultado.esError ? 'error' : 'hecho' } });
  }
  if (resultado.evento) registro.vistas.push(resultado.evento);
  if (resultado.evento?.tipo === 'enlace') registro.enlazados.push(resultado.evento.datos);
  if (resultado.pantalla) registro.pantallas.push(resultado.pantalla);
  if (resultado.vista) {
    const nueva = resultado.vista;
    const anterior = registro.deDatos.find((v) => repiteLaVista(v, nueva));
    if (anterior) {
      // Se queda en el sitio de la anterior, con las filas de la consulta corregida.
      registro.vistas[registro.vistas.indexOf(anterior)] = nueva;
      registro.deDatos[registro.deDatos.indexOf(anterior)] = nueva;
    } else {
      registro.vistas.push(nueva);
      registro.deDatos.push(nueva);
    }
    if (nueva.tipo === 'grafico' || nueva.tipo === 'tabla') registro.dibujadasPorDatos.add(nueva.tipo);
  }

  return {
    tipo: 'resultado',
    id: llamada.id,
    nombre: llamada.nombre,
    esError: resultado.esError,
    contenido: resultado.contenido,
  };
}
