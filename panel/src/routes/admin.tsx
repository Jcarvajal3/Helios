import { useMemo } from 'react'
import { createFileRoute, Outlet } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'

import {
  AsistenteProvider,
  BotonAsistente,
  PanelAsistente,
  siNoHayNadaDelAsistente,
  useAsistentePanel,
} from '@/components/admin/asistente'
import {
  TOPE_ABONOS,
  consultaAbonosSinDueno,
  consultaPagosPorAprobar,
  consultaRecuentoDeAlertas,
} from '@/components/admin/inicio/consultas'
import {
  resumirAbonos,
  resumirAlertasAltas,
  resumirAvisosDeHoy,
  resumirCambiosPropuestos,
  resumirCartera,
  resumirCorreosRebotados,
  resumirPagosReportados,
  resumirPromesasDeHoy,
} from '@/components/admin/inicio/colas'
import { consultaColaDeAvisos, consultaCorreosRecientes } from '@/features/admin/avisos/api'
import { consultaCambiosPropuestos } from '@/features/admin/pacientes/api'
import { hoyOperativo } from '@/components/admin/inicio/reloj'
import { NO_INDEXAR } from '@/config/sitio'
import { BuscadorDeLaBarra, PaletaDelPanel } from '@/components/admin/paleta'
import { PlatformGate } from '@/components/PlatformGate'
import { HeliosIsotipo, HeliosLogo } from '@/components/HeliosLogo'
import { Badge, diaOperativo } from '@/components/ui'
import { PanelShell } from '@/components/layouts/PanelShell'
import { contadorDeCola, sumarContadores } from '@/components/layouts/contadores'
import type { Contador } from '@/components/layouts/contadores'
import { superAdminNavGroups, superAdminNavPie, visibleGroups } from '@/config/navigation'
import { consultaCartera, consultaPromesas } from '@/features/admin/cobranza/consultas'
import { useSession } from '@/features/auth/session'
import type { PlatformAdmin } from '@/features/admin/api'
import { asistenteActivo } from '@/lib/asistente'
import { entorno } from '@/lib/entorno'

export const Route = createFileRoute('/admin')({
  head: () => NO_INDEXAR,
  component: SuperAdminLayoutRoute,
})

/**
 * Shell del super admin. Es el mismo `PanelShell` que el panel del local con
 * otros grupos, otra identidad y el buscador global puesto — por eso el marco
 * recibe todo eso como props.
 */
function SuperAdminLayoutRoute() {
  return (
    <PlatformGate>
      {(admin) => (
        // El asistente solo existe con un admin confirmado: su conversación
        // viaja con el JWT de quien pregunta.
        <AsistenteProvider>
          <AdminShell admin={admin} />
        </AsistenteProvider>
      )}
    </PlatformGate>
  )
}

/**
 * Componente propio (no una función suelta dentro del render prop) para que
 * los contadores del menú solo se pidan una vez que `PlatformGate` ya
 * confirmó que hay un admin — si los hooks vivieran en el arrow function de
 * `children`, PlatformGate los llamaría un número distinto de veces según su
 * propio estado (skeleton, "no es admin", shell), lo que rompe las reglas de
 * hooks.
 */
function AdminShell({ admin }: { admin: PlatformAdmin }) {
  // Para el bloque de cuenta: la tabla de admins guarda el nombre, pero es
  // opcional, y sin él el correo es lo único que identifica a la persona.
  const session = useSession()

  const contadores = useContadores()
  const asistente = useAsistentePanel()
  // El asistente llega en la fase 5: hasta entonces, ni cajón ni botón ni
  // «Preguntar» en la paleta (`VITE_ASISTENTE`).
  const conAsistente = asistenteActivo()

  const esSuperAdmin = admin.role === 'super_admin'
  const rol = esSuperAdmin ? 'Super admin' : 'Operador'

  // El mismo menú para todo el mundo y en el mismo orden: es orden, no
  // permiso.
  const groups = useMemo(() => visibleGroups(superAdminNavGroups, esSuperAdmin), [esSuperAdmin])

  return (
    <PanelShell
      groups={groups}
      pie={superAdminNavPie}
      sitio="Helios Admin"
      contadores={contadores}
      logo={(plegado) => <LogoDelEquipo plegado={plegado} rol={rol} />}
      account={{
        name: admin.fullName ?? session?.user.email ?? 'Equipo de Helios',
        detail: rol,
        // De aquí sale el nombre de pila con el que saluda Inicio.
        nombreCompleto: admin.fullName,
      }}
      // Casi toda llamada empieza con un teléfono, una cédula o una
      // referencia, y antes había que adivinar en qué pantalla buscarlos. En
      // la barra de arriba está a la misma distancia desde todas, y con
      // Ctrl K ni siquiera hace falta ir a buscarla. Con el asistente
      // encendido, además, ofrece preguntárselo; el botón de al lado (o
      // Ctrl J) abre la conversación sin pasar por ella.
      search={<BuscadorDeLaBarra conAsistente={conAsistente} />}
      asistente={conAsistente ? <BotonAsistente /> : undefined}
      lateral={conAsistente ? { abierto: asistente.abierto, contenido: <PanelAsistente /> } : undefined}
    >
      {/* La ventana de la paleta vive aquí y no en la barra de arriba: Inicio
          no tiene barra, y «Buscar en el panel» del asistente tiene que poder
          abrirla también ahí. */}
      {conAsistente ? (
        <PaletaDelPanel onPreguntar={asistente.preguntar} siNoHayNada={siNoHayNadaDelAsistente} />
      ) : (
        <PaletaDelPanel />
      )}
      <Outlet />
    </PanelShell>
  )
}

/**
 * El logo de Helios en la cabecera del menú, suelto y sin tarjeta, con la
 * pastilla DEV cuando el panel apunta a la base de desarrollo: el mismo panel
 * se compila contra las dos bases, y nada decía contra cuál se estaba
 * trabajando. En producción no se pinta nada.
 *
 * Plegada la barra, a 64 px no cabe el logotipo entero y queda el isotipo. El
 * rol no va aquí: lo dice el bloque de la cuenta, en el pie.
 */
function LogoDelEquipo({ plegado, rol }: { plegado: boolean; rol: string }) {
  return (
    <div
      title={plegado ? `Helios · ${rol}` : undefined}
      className={`flex items-center gap-2 ${plegado ? 'lg:flex-col lg:gap-1.5' : ''}`}
    >
      {/* Envueltos: el SVG del logo trae `display` en línea y una clase no
          podría esconderlo. */}
      <span className={`flex ${plegado ? 'lg:hidden' : ''}`}>
        <HeliosLogo height={22} />
      </span>
      {plegado && (
        <span className="hidden lg:flex">
          <HeliosIsotipo size={26} />
        </span>
      )}
      {entorno() === 'desarrollo' && <Badge tone="warning">DEV</Badge>}
    </div>
  )
}

/**
 * Los contadores del menú: cuántos esperan en cada cola, y si alguno ya se
 * pasó de plazo.
 *
 * Cada uno con la misma clave que su pantalla y que Inicio, tope incluido
 * (`inicio/consultas.ts`): con la pantalla abierta el contador no cuesta una
 * llamada más. El número y la urgencia salen de los mismos resúmenes que
 * «Tu cola» de Inicio (`inicio/colas.ts`): rojo es lo que allí va arriba del
 * todo, con el plazo pasado. Se refrescan cada minuto con la pestaña delante, y
 * al volver a ella se repreguntan en el acto. Con la pestaña oculta no se
 * pregunta: nadie mira el menú, y una pestaña olvidada abierta todo el día
 * eran 5 consultas por minuto contra la base, las más caras del super admin.
 * Un cero no pinta nada.
 */
function useContadores(): Partial<Record<string, Contador>> {
  const alVolver = { refetchOnWindowFocus: true } as const

  // La espera de un pago se mide contra la hora de cada lectura: el contador
  // se pone rojo al pasar de 24 h aunque la cola no haya cambiado.
  const pagos = useQuery({
    ...consultaPagosPorAprobar(),
    ...alVolver,
    select: (d) => contadorDeCola(resumirPagosReportados(d, Date.now())),
  })
  const abonos = useQuery({
    ...consultaAbonosSinDueno(),
    ...alVolver,
    select: (d) => contadorDeCola(resumirAbonos(d, TOPE_ABONOS)),
  })
  const promesas = useQuery({
    ...consultaPromesas(),
    ...alVolver,
    select: (d) => contadorDeCola(resumirPromesasDeHoy(d)),
  })
  const sinContactar = useQuery({
    ...consultaCartera(),
    ...alVolver,
    select: (d) => contadorDeCola(resumirCartera(d.rows, 'sin_contactar', hoyOperativo())),
  })
  // Solo el recuento: la base cuenta y no manda las filas.
  const alertas = useQuery({
    ...consultaRecuentoDeAlertas(),
    ...alVolver,
    select: (r) => contadorDeCola(resumirAlertasAltas(r)),
  })

  // Los avisos de hoy por mandar y los comprobantes que rebotaron: las dos
  // pestañas de Avisos que tienen cola.
  const avisos = useQuery({
    ...consultaColaDeAvisos(diaOperativo()),
    ...alVolver,
    select: (d) => contadorDeCola(resumirAvisosDeHoy(d)),
  })
  const rebotados = useQuery({
    ...consultaCorreosRecientes(),
    ...alVolver,
    select: (d) => contadorDeCola(resumirCorreosRebotados(d.filas)),
  })
  const cambios = useQuery({
    ...consultaCambiosPropuestos('pendiente'),
    ...alVolver,
    select: (d) => contadorDeCola(resumirCambiosPropuestos(d)),
  })

  return {
    // Abonos sin dueño es una pestaña de Pagos reportados: su cola suma en
    // el mismo contador, y cada pestaña enseña la suya.
    '/admin/cobros': sumarContadores([pagos.data, abonos.data]),
    '/admin/avisos': sumarContadores([avisos.data, rebotados.data]),
    '/admin/pacientes': cambios.data,
    // Promesas es una pestaña de Por cobrar: las dos colas suman en el mismo
    // contador.
    '/admin/cobranza': sumarContadores([sinContactar.data, promesas.data]),
    '/admin/alertas': alertas.data,
  }
}
