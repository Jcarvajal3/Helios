import { useMemo, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Save, Store } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { EstadoDelInteresado } from '@/components/admin/directorio-de-medicos/columnasDeInteresados'
import { BarChart } from '@/components/charts/barras'
import { TarjetaDeMedico } from '@/components/directorio/TarjetaDeMedico'
import {
  Badge,
  Button,
  Callout,
  ErrorBox,
  Input,
  Modal,
  Select,
  Switch,
  formatDateTime,
  formatDayShort,
  formatPhone,
} from '@/components/ui'
import { REDES_SOCIALES } from '@/features/admin/clinicas/clinicas'
import type { RedSocial } from '@/features/admin/clinicas/clinicas'
import { consultaInteresados, guardarTarjeta, refrescarDirectorio } from '@/features/admin/directorioDeMedicos/api'
import {
  ROTULO_BLOQUEO,
  borradorDe,
  cambiosDelBorrador,
  comoTarjetaPublica,
  datosDelBorrador,
  motivoParaNoGuardar,
} from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type { BorradorDeTarjeta, MedicoEnElDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { ESPECIALIDADES, nombreDeEspecialidad } from '@/features/directorio/especialidades'
import { describeError } from '@/lib/supabase'

const cuenta = (n: number) => String(Math.round(n))

const OPCIONES_RED = REDES_SOCIALES.map((r) => ({ value: r.value, label: r.label }))

function nombreDeRed(red: RedSocial | null): string {
  return REDES_SOCIALES.find((r) => r.value === red)?.label ?? 'sin red'
}

/**
 * La ficha de un médico en el directorio: si sale, los datos de su tarjeta
 * (con la vista previa de cómo la verá el paciente), sus clics de contacto y
 * sus interesados.
 *
 * Cada campo arranca con lo que se enseña hoy. Vacío, vuelve a ser el de la
 * ficha de la clínica, que se lee debajo del campo; igual al de la ficha,
 * también (la base no guarda una copia que luego se quede vieja).
 */
export function FichaDelDirectorio({
  medico: m,
  dias,
  onClose,
}: {
  medico: MedicoEnElDirectorio
  /** Los días de las barras, del más viejo a hoy ('YYYY-MM-DD'). */
  dias: ReadonlyArray<string>
  onClose: () => void
}) {
  const client = useQueryClient()
  const avisar = useToast()
  const [borrador, setBorrador] = useState<BorradorDeTarjeta>(() => borradorDe(m.tarjeta))

  const vistaPrevia = useMemo(() => comoTarjetaPublica(m.id, datosDelBorrador(borrador, m.ficha)), [borrador, m])
  const cambios = cambiosDelBorrador(borrador, m.tarjeta)
  const motivo = motivoParaNoGuardar(borrador)

  const guardar = useMutation({
    mutationFn: (c: Record<string, string | boolean>) => guardarTarjeta(m.id, c),
    onSuccess: (_, c) => {
      refrescarDirectorio(client)
      if ('visible' in c && Object.keys(c).length === 1) {
        avisar(c.visible ? `${m.tarjeta.nombre} ya sale en el directorio.` : `${m.tarjeta.nombre} ya no sale en el directorio.`)
      } else {
        avisar(`Tarjeta de ${vistaPrevia.nombre} guardada.`)
        // Lo vaciado vuelve a ser lo de la ficha: el borrador se queda con lo
        // que la base enseña ahora, y deja de contar como cambio.
        setBorrador((b) => borradorDe(datosDelBorrador(b, m.ficha)))
      }
    },
  })

  function cambiar(parte: Partial<BorradorDeTarjeta>) {
    setBorrador((b) => ({ ...b, ...parte }))
  }

  const deLaFicha = (valor: string | null) => (valor ? `Vacío: «${valor}», el de la ficha.` : 'La ficha no tiene ninguno.')
  const opcionesClave = ESPECIALIDADES.map((e) => ({
    value: e.clave,
    label: e.clave === m.ficha.clave ? `${e.nombre} (la de la ficha)` : e.nombre,
  }))

  return (
    <Modal title={m.tarjeta.nombre} width="lg" onClose={onClose}>
      <div className="flex flex-col gap-6">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="flex flex-col gap-2">
            <Switch
              id="ficha-directorio-visible"
              label={m.visible ? 'Sale en el directorio' : 'No sale en el directorio'}
              checked={m.visible}
              disabled={guardar.isPending || (m.bloqueo !== null && !m.visible)}
              onChange={(visible) => guardar.mutate({ visible })}
            />
            {m.publicadoEl && m.visible && (
              <p className="type-panel-caption text-on-surface-variant">Publicado el {formatDateTime(m.publicadoEl)}</p>
            )}
          </div>
          <Link
            to="/admin/clinicas/$id"
            params={{ id: m.id }}
            className="inline-flex items-center gap-1 type-panel-caption text-on-surface-variant underline-offset-2 hover:text-on-surface hover:underline"
          >
            <Store size={13} aria-hidden /> Abrir la ficha de {m.clinica}
          </Link>
        </div>

        {m.bloqueo && (
          <Callout tone="warning" titulo={`No sale en el directorio: ${ROTULO_BLOQUEO[m.bloqueo].toLowerCase()}`}>
            {m.bloqueo === 'sin_whatsapp'
              ? 'Ponle un WhatsApp abajo y guarda; después ya se puede publicar.'
              : m.bloqueo === 'prueba'
                ? 'Las clínicas de prueba nunca salen.'
                : 'Vuelve a salir sola si la clínica se reactiva y sigue marcada como visible.'}
          </Callout>
        )}

        <div className="grid gap-6 md:grid-cols-[minmax(0,1fr)_minmax(0,320px)]">
          <section className="flex flex-col gap-3">
            <h3 className="type-panel-label text-on-surface-variant">La tarjeta</h3>
            <Input
              id="ficha-directorio-nombre"
              label="Nombre"
              value={borrador.nombre}
              onChange={(nombre) => cambiar({ nombre })}
              hint={deLaFicha(m.ficha.nombre)}
            />
            <div className="grid gap-3 sm:grid-cols-2">
              <Input
                id="ficha-directorio-especialidad"
                label="Especialidad (lo que se lee)"
                value={borrador.especialidad}
                onChange={(especialidad) => cambiar({ especialidad })}
                placeholder={nombreDeEspecialidad(borrador.clave)}
                hint={deLaFicha(m.ficha.especialidad)}
              />
              <Select
                id="ficha-directorio-clave"
                label="Filtro e icono"
                value={borrador.clave}
                options={opcionesClave}
                onChange={(clave) => cambiar({ clave })}
              />
            </div>
            <Input
              id="ficha-directorio-direccion"
              label="Dirección"
              value={borrador.direccion}
              onChange={(direccion) => cambiar({ direccion })}
              hint={deLaFicha(m.ficha.direccion)}
            />
            <div className="grid gap-3 sm:grid-cols-2">
              <Input
                id="ficha-directorio-ciudad"
                label="Ciudad"
                value={borrador.ciudad}
                onChange={(ciudad) => cambiar({ ciudad })}
                hint={deLaFicha(m.ficha.ciudad)}
              />
              <Input
                id="ficha-directorio-whatsapp"
                label="WhatsApp"
                type="tel"
                inputMode="tel"
                autoComplete="off"
                value={borrador.whatsapp}
                onChange={(whatsapp) => cambiar({ whatsapp })}
                placeholder="0414-1234567"
                error={!!borrador.whatsapp.trim() && motivo !== null && motivo.startsWith('El WhatsApp')}
                hint={deLaFicha(m.ficha.whatsapp ? formatPhone(m.ficha.whatsapp) : null)}
              />
            </div>
            <div className="grid gap-3 sm:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
              <Select
                id="ficha-directorio-red"
                label="Red social"
                value={borrador.red}
                options={OPCIONES_RED}
                placeholder="Sin red social"
                onChange={(red) => cambiar({ red })}
              />
              <Input
                id="ficha-directorio-usuario-red"
                label="Usuario o enlace"
                value={borrador.usuarioDeRed}
                onChange={(usuarioDeRed) => cambiar({ usuarioDeRed })}
                placeholder="@draperez"
                autoComplete="off"
                hint={
                  m.ficha.usuarioDeRed
                    ? deLaFicha(`${m.ficha.usuarioDeRed} (${nombreDeRed(m.ficha.red)})`)
                    : 'La ficha no tiene ninguna.'
                }
              />
            </div>

            <div className="mt-1 flex flex-wrap items-center justify-end gap-3">
              {motivo && <p className="type-panel-caption text-error">{motivo}</p>}
              <Button
                size="sm"
                disabled={!cambios || !!motivo || guardar.isPending}
                title={!cambios ? 'No hay cambios que guardar' : (motivo ?? undefined)}
                onClick={() => {
                  if (cambios && !motivo) guardar.mutate(cambios)
                }}
              >
                <Save size={15} aria-hidden /> {guardar.isPending ? 'Guardando…' : 'Guardar la tarjeta'}
              </Button>
            </div>
            {guardar.isError && <ErrorBox title="No se pudo guardar" detail={describeError(guardar.error)} />}
          </section>

          <section className="flex flex-col gap-3">
            <h3 className="flex items-center justify-between gap-2 type-panel-label text-on-surface-variant">
              Así la ve el paciente
              {cambios && <Badge tone="warning">Sin guardar</Badge>}
            </h3>
            {/* La tarjeta lleva la paleta fija de la portada: va sobre su niebla
                también en el tema oscuro del panel. */}
            <div className="rounded-panel-card bg-[#f4f6fa] p-3 font-[family-name:var(--font-portada)]">
              <TarjetaDeMedico medico={vistaPrevia} />
            </div>
            {!vistaPrevia.whatsapp && (
              <p className="type-panel-caption text-warning">Sin WhatsApp el botón no lleva a ningún sitio.</p>
            )}
          </section>
        </div>

        <section className="flex flex-col gap-3">
          <h3 className="type-panel-label text-on-surface-variant">Contactos desde el directorio</h3>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <Mini rotulo="Hoy y 6 días antes" valor={m.clics.d7} />
            <Mini rotulo="Últimos 30 días" valor={m.clics.d30} />
            <Mini rotulo="Personas en 30 días" valor={m.clics.visitantes30d} />
            <Mini rotulo="Desde que salió" valor={m.clics.total} />
          </div>
          <BarChart
            title="Clics por día"
            summary={
              m.clics.ultimo ? <>El último, {formatDateTime(m.clics.ultimo)}</> : 'Todavía nadie le ha escrito desde el directorio.'
            }
            enteros
            series={[{ key: 'clics', label: 'Clics' }]}
            points={dias.map((dia, i) => ({ key: dia, label: formatDayShort(dia), values: [m.clics.porDia[i] ?? 0] }))}
            format={cuenta}
            formatShort={cuenta}
            ejeLabel="Día"
            height={140}
            footnote="Toques al botón de WhatsApp de su tarjeta. Los del equipo y los del personal de las clínicas no cuentan."
            empty="Sin clics en los últimos 30 días."
          />
        </section>

        <SusInteresados medico={m} />
      </div>
    </Modal>
  )
}

/**
 * Quien le escribió al WhatsApp de Helios desde su tarjeta (con el código del
 * médico), el más reciente primero, y si ya se hizo su paciente. El teléfono
 * no se le pasa al médico: está aquí solo para medir.
 */
function SusInteresados({ medico: m }: { medico: MedicoEnElDirectorio }) {
  const lista = useQuery(consultaInteresados(m.id))
  return (
    <section className="flex flex-col gap-3">
      <h3 className="type-panel-label text-on-surface-variant">Interesados</h3>
      <div className="grid grid-cols-3 gap-3">
        <Mini rotulo="Últimos 30 días" valor={m.interesados.d30} />
        <Mini rotulo="Desde que salió" valor={m.interesados.total} />
        <Mini rotulo="Ya son pacientes" valor={m.interesados.convertidos} />
      </div>
      {lista.isPending && <p className="type-panel-caption text-on-surface-variant">Leyendo los interesados…</p>}
      {lista.isError && <ErrorBox title="No se pudo leer sus interesados" detail={describeError(lista.error)} />}
      {lista.isSuccess && lista.data.length === 0 && (
        <p className="type-panel-body text-on-surface-variant">
          Todavía nadie le ha escrito al WhatsApp de Helios desde su tarjeta.
        </p>
      )}
      {lista.isSuccess && lista.data.length > 0 && (
        <ul className="divide-y divide-panel-hairline rounded-panel-card border border-panel-hairline">
          {lista.data.map((i) => (
            <li key={i.id} className="flex flex-wrap items-start justify-between gap-x-4 gap-y-2 px-3 py-2.5">
              <div className="min-w-0">
                <p className="tabular-nums text-on-surface">
                  {formatPhone(i.telefono)}
                  {i.paciente?.nombre && (
                    <span className="type-panel-caption text-on-surface-variant"> · {i.paciente.nombre}</span>
                  )}
                </p>
                <p className="type-panel-caption text-on-surface-variant">
                  Escribió el {formatDateTime(i.primeraVez)}
                  {i.ultimaVez !== i.primeraVez && <> · el último, {formatDateTime(i.ultimaVez)}</>}
                  {' · '}
                  {i.mensajes} {i.mensajes === 1 ? 'mensaje' : 'mensajes'}
                </p>
              </div>
              <EstadoDelInteresado interesado={i} />
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function Mini({ rotulo, valor }: { rotulo: string; valor: number }) {
  return (
    <div className="rounded-panel-card border border-panel-hairline px-3 py-2.5">
      <p className="type-panel-caption text-on-surface-variant">{rotulo}</p>
      <p className="mt-0.5 type-panel-section tabular-nums text-on-surface">{valor}</p>
    </div>
  )
}
