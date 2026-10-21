import { useRef } from 'react'
import { createFileRoute, useRouter } from '@tanstack/react-router'

import { useAnfitrionDeCharla } from '@/components/admin/asistente'
import { CharlaDeInicio } from '@/components/admin/inicio/CharlaDeInicio'
import { CifrasDeHoy } from '@/components/admin/inicio/CifrasDeHoy'
import { ConfiguracionIncompleta } from '@/components/admin/inicio/ConfiguracionIncompleta'
import { DiaOperativo } from '@/components/admin/inicio/DiaOperativo'
import { Heroe } from '@/components/admin/inicio/Heroe'
import { Pendiente } from '@/components/admin/inicio/Pendiente'
import { TARJETAS_EN_LA_FILA } from '@/components/admin/inicio/tarjetasDePendiente'
import { hoyOperativo } from '@/components/admin/inicio/reloj'
import { asistenteActivo } from '@/lib/asistente'
import { comoBooleano } from '@/lib/busqueda'

/** `charla`: Inicio convertido en la conversación con el asistente. En la URL para que Atrás lo deshaga. */
type BusquedaDeInicio = { charla?: boolean }

export const Route = createFileRoute('/admin/')({
  // Inmersiva: la barra de arriba desaparece y la de Inicio es título y buscador.
  staticData: { title: 'Inicio', width: 'wide', inmersiva: true },
  validateSearch: (search: Record<string, unknown>): BusquedaDeInicio => ({
    charla: comoBooleano(search.charla),
  }),
  component: InicioPage,
})

/**
 * Inicio: lo que pide atención hoy y, debajo, la barra del asistente.
 *
 * Es la pantalla por la que entra todo el mundo y tiene que contestar en
 * cinco segundos, sin desplazar: qué día operativo corre, lo pendiente (lo
 * que bloquea y las colas con trabajo), una cifra por área y la barra, que
 * pregunta y busca.
 *
 * Mientras está montada es el sitio de la charla: preguntar desde la barra, la
 * paleta, Ctrl J o el botón del asistente la convierte en la conversación
 * (`?charla=1`), en vez de abrir el cajón.
 */
function InicioPage() {
  const { charla } = Route.useSearch()
  const navigate = Route.useNavigate()
  const router = useRouter()
  const hoy = hoyOperativo()
  // Sin asistente (`VITE_ASISTENTE`) no hay charla: `?charla=1` se ignora.
  const conAsistente = asistenteActivo()
  const enCharla = conAsistente && charla === true

  // Si la charla se abrió desde esta pantalla, volver es deshacer ese paso del
  // historial: así Atrás no vuelve a la charla que se acaba de cerrar.
  const empujada = useRef(false)

  function irALaCharla() {
    if (enCharla) return
    empujada.current = true
    void navigate({ search: { charla: true } })
  }

  function volver() {
    if (!enCharla) return
    if (empujada.current) {
      empujada.current = false
      router.history.back()
      return
    }
    // Se entró con la charla ya abierta (un enlace, recargar): se sustituye.
    void navigate({ search: {}, replace: true })
  }

  // La pregunta ya llega enviada: aquí solo se enseña la conversación.
  useAnfitrionDeCharla(conAsistente ? { mostrar: irALaCharla } : null)

  if (enCharla) return <CharlaDeInicio onVolver={volver} />

  return (
    <div className="flex flex-1 flex-col gap-7">
      <DiaOperativo />
      <ConfiguracionIncompleta />
      <Pendiente />
      <CifrasDeHoy hoy={hoy} desde={TARJETAS_EN_LA_FILA} />
      <Heroe onSeguirLaConversacion={irALaCharla} conAsistente={conAsistente} />
    </div>
  )
}
