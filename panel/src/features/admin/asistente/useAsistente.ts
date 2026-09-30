import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useRouterState } from '@tanstack/react-router'

import { SUPABASE_ANON_KEY, SUPABASE_URL, supabase } from '@/lib/supabase'
import { preguntarAlAsistente } from './cliente'
import {
  alTerminarElFlujo,
  aplicarEvento,
  conFallo,
  escribirConversacion,
  historialParaEnviar,
  leerConversacion,
  parada,
  respuestaVacia,
  ultimaPregunta,
} from './conversacion'
import type { Fallo, Mensaje, MensajeAsistente } from './conversacion'
import { ESPERA_DEL_REINTENTO, falloDelFlujo, seReintentaSolo } from './errores'

/** Dónde se guarda la conversación: dura lo que dura la pestaña. */
const CLAVE = 'helios-panel:asistente'

function cargar(): Mensaje[] {
  try {
    return leerConversacion(window.sessionStorage.getItem(CLAVE))
  } catch {
    // Almacenamiento bloqueado: se empieza de cero y no pasa nada.
    return []
  }
}

function guardar(mensajes: ReadonlyArray<Mensaje>) {
  try {
    if (mensajes.length === 0) window.sessionStorage.removeItem(CLAVE)
    else window.sessionStorage.setItem(CLAVE, escribirConversacion(mensajes))
  } catch {
    // Lleno o bloqueado: la conversación sigue en memoria mientras la pestaña viva.
  }
}

let contador = 0
/** Un id local, único en la pestaña. No sale del navegador. */
function nuevoId(): string {
  contador += 1
  return `${Date.now().toString(36)}-${contador}`
}

export type EstadoAsistente = {
  mensajes: ReadonlyArray<Mensaje>
  /** Hay una respuesta llegando: el botón de enviar pasa a «Parar». */
  enviando: boolean
  /** La consulta que corre ahora, para «Leyendo la cartera vencida…». */
  consultando: string | null
  enviar: (texto: string) => void
  parar: () => void
  /** Vuelve a hacer la última pregunta, en lugar de la respuesta fallida. */
  reintentar: () => void
  /**
   * El reintento automático en marcha, con el instante en que salta; `null`
   * si no hay ninguno. Solo se programa uno por pregunta.
   */
  reintentoAutomatico: { hasta: number } | null
  cancelarReintento: () => void
  /** Vacía la conversación (y para lo que estuviera llegando). */
  nueva: () => void
}

/**
 * La conversación con el asistente: la envía, lee la respuesta mientras llega
 * y la guarda en `sessionStorage`.
 *
 * El servidor no recuerda nada: cada pregunta viaja con la conversación
 * entera. La petición lleva el JWT de la sesión, así que el asistente lee con
 * los permisos de quien pregunta, ni uno más.
 *
 * Si el modelo contesta que está ocupado (`saturado` o `cuota`), la pregunta
 * se repite sola una vez a los diez segundos. Vive aquí y no en el aviso: el
 * reintento sigue aunque el cajón se cierre o se cambie de pantalla.
 */
export function useAsistente(): EstadoAsistente {
  const [mensajes, setMensajes] = useState<Mensaje[]>([])
  const [cargada, setCargada] = useState(false)
  const [espera, setEspera] = useState<{ hasta: number } | null>(null)
  const controlador = useRef<AbortController | null>(null)
  const rutaActual = useRouterState({ select: (s) => s.location.href })
  const rutaRef = useRef(rutaActual)

  useEffect(() => {
    rutaRef.current = rutaActual
  }, [rutaActual])

  // Se lee al montar y no al construir el estado: esto también se renderiza
  // en el servidor, donde no hay `sessionStorage`.
  useEffect(() => {
    setMensajes(cargar())
    setCargada(true)
  }, [])

  useEffect(() => {
    if (cargada) guardar(mensajes)
  }, [mensajes, cargada])

  // Al salir del panel no se deja una respuesta llegando a ninguna parte.
  useEffect(() => () => controlador.current?.abort(), [])

  const cambiarRespuesta = useCallback(
    (id: string, cambio: (m: MensajeAsistente) => MensajeAsistente) =>
      setMensajes((lista) =>
        lista.map((m) => (m.id === id && m.rol === 'asistente' ? cambio(m) : m)),
      ),
    [],
  )

  /**
   * Pide la respuesta de `historia` y la va escribiendo en el mensaje `id`.
   * `automatico` dice si es el reintento automático, que no programa otro.
   */
  const responder = useCallback(
    async (historia: ReadonlyArray<Mensaje>, id: string, automatico: boolean) => {
      controlador.current?.abort()
      const control = new AbortController()
      controlador.current = control

      const { data } = await supabase.auth.getSession()
      const token = data.session?.access_token
      if (!token) {
        cambiarRespuesta(id, (m) =>
          conFallo(m, {
            causa: 'sin-permiso',
            mensaje: 'La sesión ha caducado. Vuelve a iniciar sesión para preguntar.',
            reintentar: false,
          }),
        )
        return
      }

      // El fallo que llegue dentro del flujo, para decidir si se reintenta solo.
      const delFlujo: Fallo[] = []
      const resultado = await preguntarAlAsistente({
        url: SUPABASE_URL,
        token,
        apikey: SUPABASE_ANON_KEY,
        conversacion: historialParaEnviar(historia),
        rutaActual: rutaRef.current,
        signal: control.signal,
        alEvento: (evento) => {
          if (evento.tipo === 'error') delFlujo.push(falloDelFlujo(evento.error))
          cambiarRespuesta(id, (m) => aplicarEvento(m, evento))
        },
      })

      const vigente = controlador.current === control
      if (vigente) controlador.current = null
      if (resultado.tipo === 'completa') cambiarRespuesta(id, alTerminarElFlujo)
      else if (resultado.tipo === 'parada') cambiarRespuesta(id, parada)
      else cambiarRespuesta(id, (m) => conFallo(m, resultado.fallo))

      const fallo = resultado.tipo === 'fallida' ? resultado.fallo : delFlujo.at(-1)
      if (vigente && !automatico && fallo && seReintentaSolo(fallo)) {
        setEspera({ hasta: Date.now() + ESPERA_DEL_REINTENTO })
      }
    },
    [cambiarRespuesta],
  )

  const ultima = mensajes.at(-1)
  const enviando = ultima?.rol === 'asistente' && ultima.estado === 'escribiendo'
  const consultando =
    enviando
      ? ([...ultima.herramientas].reverse().find((h) => h.estado === 'consultando')?.rotulo ?? null)
      : null

  const enviar = useCallback(
    (texto: string) => {
      const pregunta = texto.trim()
      if (pregunta === '' || enviando) return
      // Una pregunta nueva deja sin sentido repetir la anterior.
      setEspera(null)
      const historia: Mensaje[] = [...mensajes, { id: nuevoId(), rol: 'persona', texto: pregunta }]
      const respuesta = respuestaVacia(nuevoId())
      setMensajes([...historia, respuesta])
      void responder(historia, respuesta.id, false)
    },
    [mensajes, enviando, responder],
  )

  /** Repite la última pregunta en lugar de su respuesta fallida. */
  const repetir = useCallback(
    (automatico: boolean) => {
      const pregunta = ultimaPregunta(mensajes)
      if (!pregunta || enviando) return
      setEspera(null)
      const historia = mensajes.slice(0, mensajes.indexOf(pregunta) + 1)
      const respuesta = respuestaVacia(nuevoId())
      setMensajes([...historia, respuesta])
      void responder(historia, respuesta.id, automatico)
    },
    [mensajes, enviando, responder],
  )

  const reintentar = useCallback(() => repetir(false), [repetir])

  // El temporizador del reintento automático llama a la última `repetir`,
  // sin volver a programarse cada vez que cambia la conversación.
  const repetirSolo = useRef(() => repetir(true))
  useEffect(() => {
    repetirSolo.current = () => repetir(true)
  }, [repetir])

  useEffect(() => {
    if (!espera) return
    const id = window.setTimeout(() => {
      setEspera(null)
      repetirSolo.current()
    }, Math.max(0, espera.hasta - Date.now()))
    return () => window.clearTimeout(id)
  }, [espera])

  const cancelarReintento = useCallback(() => setEspera(null), [])

  const parar = useCallback(() => controlador.current?.abort(), [])

  const nueva = useCallback(() => {
    controlador.current?.abort()
    controlador.current = null
    setEspera(null)
    setMensajes([])
  }, [])

  return useMemo(
    () => ({
      mensajes,
      enviando,
      consultando,
      enviar,
      parar,
      reintentar,
      reintentoAutomatico: espera,
      cancelarReintento,
      nueva,
    }),
    [mensajes, enviando, consultando, enviar, parar, reintentar, espera, cancelarReintento, nueva],
  )
}
