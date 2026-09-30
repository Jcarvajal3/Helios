import { useEffect, useMemo, useState } from 'react'
import type { KeyboardEvent } from 'react'

import { useIsSuperAdmin } from '@/features/admin/role'
import { interpretar } from './consulta'
import type { Consulta, IdGrupo } from './consulta'
import { anuncioDe, construirGrupos, noHayNada, resumir } from './grupos'
import type { Grupo } from './grupos'
import type { Opcion } from './opciones'
import { useIrA } from './navegar'
import { anadirReciente, cargarRecientes, guardarRecientes } from './recientes'
import type { Reciente } from './recientes'
import { useFuentes } from './useFuentes'

/**
 * Cuánto se espera desde la última tecla antes de preguntar al servidor. Lo
 * justo para no lanzar una consulta por tecla al dictar un teléfono; el
 * catálogo no espera, se busca en cada tecla.
 */
export const RETARDO_SERVIDOR = 250

/** `valor`, pero solo cuando lleva `ms` sin cambiar. */
function useDiferido<T>(valor: T, ms: number): T {
  const [diferido, setDiferido] = useState(valor)
  useEffect(() => {
    const id = setTimeout(() => setDiferido(valor), ms)
    return () => clearTimeout(id)
  }, [valor, ms])
  return diferido
}

export type EstadoPaleta = {
  texto: string
  cambiarTexto: (texto: string) => void
  consulta: Consulta
  grupos: ReadonlyArray<Grupo>
  /** La opción señalada, la que abre Enter. */
  activa: Opcion | null
  /** El término cuya definición está desplegada. */
  desplegada: string | null
  /** Si toca decir «Nada con…». */
  vacia: boolean
  /** Lo que se le dice al lector de pantalla cuando termina de buscar. */
  anuncio: string
  senalar: (clave: string) => void
  elegir: (opcion: Opcion, nuevaPestana: boolean) => void
  alTeclear: (evento: KeyboardEvent<HTMLInputElement>) => void
}

/**
 * El estado y el teclado de la paleta.
 *
 * La selección se guarda por clave y no por posición: los grupos del servidor
 * llegan después que los del catálogo, y una posición guardada acabaría
 * señalando otra cosa. Mientras la persona no mueva la selección, la señalada
 * es siempre la primera, también cuando lo primero cambia al llegar datos.
 */
export function usePaleta({
  onCerrar,
  onPreguntar,
  textoInicial = '',
}: {
  onCerrar: () => void
  /** Lleva lo tecleado al asistente. Sin esto no se ofrece preguntar. */
  onPreguntar?: (texto: string) => void
  /** Lo que ya viene escrito al abrir (`abrirPaleta(texto)`). */
  textoInicial?: string
}): EstadoPaleta {
  const esSuperAdmin = useIsSuperAdmin()
  const irA = useIrA()

  const [texto, setTexto] = useState(textoInicial)
  // La paleta solo se monta al abrirla, en el navegador: aquí ya hay
  // `localStorage`, y leerlo al abrir recoge lo abierto en otra pestaña.
  const [recientes, setRecientes] = useState<ReadonlyArray<Reciente>>(cargarRecientes)
  const [elegida, setElegida] = useState<string | null>(null)
  const [desplegada, setDesplegada] = useState<string | null>(null)

  const consulta = useMemo(() => interpretar(texto), [texto])
  const diferido = useDiferido(consulta.texto, RETARDO_SERVIDOR)
  const consultaDiferida = useMemo(() => interpretar(diferido), [diferido])
  const esperando = consulta.texto !== consultaDiferida.texto

  const fuentes = useFuentes(consultaDiferida, esperando)

  const grupos = useMemo(
    () =>
      construirGrupos({
        consulta,
        esSuperAdmin,
        recientes,
        personas: fuentes.personas,
        locales: fuentes.locales,
        consumos: fuentes.consumos,
        pagos: fuentes.pagos,
        preguntar: onPreguntar !== undefined,
      }),
    [
      consulta,
      esSuperAdmin,
      recientes,
      fuentes.personas,
      fuentes.locales,
      fuentes.consumos,
      fuentes.pagos,
      onPreguntar,
    ],
  )
  const opciones = useMemo(() => grupos.flatMap((g) => g.opciones), [grupos])
  const resumen = resumir(grupos)

  const activa =
    opciones.find((o) => o.clave === elegida) ?? (opciones.length > 0 ? opciones[0] : null)

  function cambiarTexto(nuevo: string) {
    setTexto(nuevo)
    setElegida(null)
    setDesplegada(null)
  }

  function mover(paso: 1 | -1) {
    if (opciones.length === 0) return
    const i = activa ? opciones.indexOf(activa) : -1
    const siguiente = opciones.at((i + paso + opciones.length) % opciones.length)
    if (siguiente) setElegida(siguiente.clave)
  }

  function recordar(r: Reciente) {
    const lista = anadirReciente(recientes, r)
    guardarRecientes(lista)
    setRecientes(lista)
  }

  const reintentos: Partial<Record<IdGrupo, () => void>> = {
    personas: fuentes.personas.reintentar,
    locales: fuentes.locales.reintentar,
    consumos: fuentes.consumos.reintentar,
    pagos: fuentes.pagos.reintentar,
  }

  function elegir(opcion: Opcion, nuevaPestana: boolean) {
    setElegida(opcion.clave)
    const efecto = opcion.efecto
    switch (efecto.tipo) {
      case 'apagada':
        return
      case 'preguntar':
        // Como al abrir: primero se cierra la paleta y luego se abre el cajón,
        // que se queda con el foco.
        onCerrar()
        onPreguntar?.(efecto.texto)
        return
      case 'reintentar':
        reintentos[efecto.grupo]?.()
        return
      case 'desplegar':
        recordar(efecto.reciente)
        setDesplegada((actual) => (actual === opcion.clave ? null : opcion.clave))
        return
      case 'abrir':
        recordar(efecto.reciente)
        // Primero se cierra: la ventana devuelve el foco a quien la abrió y
        // luego cambia la pantalla, no al revés.
        onCerrar()
        irA(efecto.destinatario, nuevaPestana)
    }
  }

  function alTeclear(evento: KeyboardEvent<HTMLInputElement>) {
    if (evento.nativeEvent.isComposing) return
    if (evento.key === 'ArrowDown' || evento.key === 'ArrowUp') {
      evento.preventDefault()
      mover(evento.key === 'ArrowDown' ? 1 : -1)
    } else if (evento.key === 'Enter') {
      evento.preventDefault()
      if (activa) elegir(activa, evento.ctrlKey || evento.metaKey)
    } else if (evento.key === 'Tab' && !evento.shiftKey && activa?.efecto.tipo === 'preguntar') {
      // Con «Preguntarle al asistente» señalada, Tab también la elige: es el
      // gesto de «completar» de muchos buscadores.
      evento.preventDefault()
      elegir(activa, false)
    }
  }

  // Una definición recién desplegada se lee en voz alta: la opción señalada
  // no cambia, así que el lector de pantalla no volvería a leerla solo.
  const abierta = opciones.find((o) => o.clave === desplegada)
  const definicion = abierta?.efecto.tipo === 'desplegar' ? abierta.efecto.definicion : null

  return {
    texto,
    cambiarTexto,
    consulta,
    grupos,
    activa,
    desplegada,
    vacia: noHayNada(consulta, resumen),
    anuncio: definicion ?? anuncioDe(consulta, resumen),
    senalar: (clave) => {
      if (clave !== activa?.clave) setElegida(clave)
    },
    elegir,
    alTeclear,
  }
}
