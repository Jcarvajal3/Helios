import { useMemo, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowRight, HandCoins, Search } from 'lucide-react'

import { AdjuntarComprobante } from '@/components/admin/caja/AdjuntarComprobante'
import { consultaPagosPorAprobar } from '@/components/admin/inicio/consultas'
import {
  Badge,
  Button,
  Callout,
  Checkbox,
  ErrorBox,
  Input,
  Modal,
  SectionTitle,
  Select,
  SkeletonList,
  Textarea,
  claseDeBoton,
  diaOperativo,
  formatBcvRate,
  formatDay,
  formatDocument,
  formatPhone,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { BANKS } from '@/features/admin/banks'
import { consultaCargosPorAtraso, consultaTasa } from '@/features/admin/cobranza/consultas'
import { METODOS_DE_PAGO, medioConReferencia } from '@/features/admin/liquidaciones'
import type { PayoutMethod } from '@/features/admin/liquidaciones'
import { valorDe } from '@/features/admin/parametros'
import { useParametros } from '@/features/admin/useParametros'
import { fetchUserDetail, fetchUsers } from '@/features/admin/users'
import type { UserRow } from '@/features/admin/users'
import { registrarPago, subirComprobanteDePago } from '@/features/admin/pagosRegistrados/api'
import {
  alternarCuota,
  armarCuotas,
  bolivaresEsperados,
  diferenciaEnBs,
  fraseDelExtracto,
  medioConBanco,
  medioEnBolivares,
  motivoDeArchivo,
  motivoDeSeleccion,
  totalDeLaSeleccion,
} from '@/features/admin/pagosRegistrados/registrarPago'
import type { CuotaParaPagar, PagoRegistrado } from '@/features/admin/pagosRegistrados/registrarPago'
import { leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

/** El paciente al que se le registra: basta el id y cómo se llama. */
export type PacienteDelPago = { userId: string; nombre: string | null }

/**
 * «Registrar pago»: el paciente pagó y mandó la captura por WhatsApp
 * (contrato §2.1, plan §7.1).
 *
 * Desde la ficha del paciente llega con él puesto; desde Pagos reportados
 * empieza por buscarlo. Se eligen las cuotas —lo vencido primero—, se copia
 * lo que dice el comprobante y se sube la captura. El pago queda en la cola
 * de Pagos reportados y se aprueba allí contra el extracto.
 */
export function RegistrarPago({
  paciente,
  onClose,
}: {
  /** Sin él, el primer paso es buscar al paciente. */
  paciente?: PacienteDelPago
  onClose: () => void
}) {
  const [elegido, setElegido] = useState<PacienteDelPago | null>(paciente ?? null)
  const [hecho, setHecho] = useState<PagoRegistrado | null>(null)

  return (
    <Modal title="Registrar un pago" width="lg" onClose={onClose}>
      {hecho ? (
        <PagoHecho pago={hecho} nombre={elegido?.nombre ?? null} onClose={onClose} />
      ) : elegido ? (
        <FormularioDelPago
          paciente={elegido}
          onCambiarPaciente={paciente ? undefined : () => setElegido(null)}
          onHecho={setHecho}
        />
      ) : (
        <ElegirPaciente onElegir={(u) => setElegido({ userId: u.userId, nombre: u.fullName })} />
      )}
    </Modal>
  )
}

/**
 * El botón que abre «Registrar pago», con su ventana. Va en la cabecera de
 * la ficha del paciente y en Pagos reportados (sin paciente: lo busca).
 */
export function BotonRegistrarPago({
  paciente,
  variante = 'tonal',
}: {
  paciente?: PacienteDelPago
  variante?: 'filled' | 'tonal'
}) {
  const [abierto, setAbierto] = useState(false)
  return (
    <>
      <Button size="sm" variant={variante} onClick={() => setAbierto(true)}>
        <HandCoins size={14} aria-hidden /> Registrar pago
      </Button>
      {abierto && <RegistrarPago paciente={paciente} onClose={() => setAbierto(false)} />}
    </>
  )
}

// ── 1. El paciente ─────────────────────────────────────────────────────────

function ElegirPaciente({ onElegir }: { onElegir: (u: UserRow) => void }) {
  const [texto, setTexto] = useState('')
  const buscable = texto.trim().length >= 2
  const busqueda = useQuery({
    queryKey: ['admin-users', texto, ''],
    queryFn: () => fetchUsers({ search: texto, limit: 8 }),
    enabled: buscable,
  })

  return (
    <div className="flex flex-col gap-3">
      <SectionTitle>¿De quién es el pago?</SectionTitle>
      <p className="type-panel-body text-on-surface-variant">
        Busca al paciente con el teléfono desde el que escribió, su cédula o su nombre.
      </p>
      <Input id="registrar-pago-buscar" value={texto} onChange={setTexto} placeholder="Teléfono, cédula o nombre" autoFocus />

      {buscable && busqueda.isPending && <SkeletonList rows={2} />}
      {busqueda.isError && <ErrorBox title="No se pudo buscar" detail={describeError(busqueda.error)} />}
      {busqueda.data?.length === 0 && (
        <p className="type-panel-body text-on-surface-variant">
          Nadie coincide. Prueba con el teléfono completo o con la cédula sin puntos.
        </p>
      )}

      <div className="flex flex-col gap-2">
        {(busqueda.data ?? []).map((u) => (
          <button
            key={u.userId}
            type="button"
            onClick={() => onElegir(u)}
            className="flex items-center justify-between gap-3 rounded-panel-control bg-panel-raised p-3 text-left transition-colors duration-[var(--transition-fast)] hover:bg-panel-control"
          >
            <span>
              <span className="block type-panel-body text-on-surface">{u.fullName ?? 'Sin nombre'}</span>
              <span className="block type-panel-caption text-on-surface-variant">
                {formatPhone(u.phone)}
                {u.document && ` · ${formatDocument(u.document)}`} · debe {formatUsd(u.openDebtUsd)} con fee
                {u.overdueUsd > 0 && `, ${formatUsd(u.overdueUsd)} vencido`}
              </span>
            </span>
            <Search size={14} className="shrink-0 text-on-surface-variant" aria-hidden />
          </button>
        ))}
      </div>
    </div>
  )
}

// ── 2. Las cuotas y el comprobante ─────────────────────────────────────────

function FormularioDelPago({
  paciente,
  onCambiarPaciente,
  onHecho,
}: {
  paciente: PacienteDelPago
  onCambiarPaciente?: () => void
  onHecho: (pago: PagoRegistrado) => void
}) {
  const client = useQueryClient()
  const hoy = diaOperativo()

  // Las mismas claves que la ficha: abrir esto desde ella no cuesta llamadas.
  const detalle = useQuery({ queryKey: ['admin-user', paciente.userId], queryFn: () => fetchUserDetail(paciente.userId) })
  const cargos = useQuery(consultaCargosPorAtraso(paciente.userId))
  const cola = useQuery(consultaPagosPorAprobar())
  const tasa = useQuery(consultaTasa())
  const parametros = useParametros()

  // Las cuotas que ya tienen un pago registrado sin aprobar.
  const enRevision = useMemo(
    () =>
      new Set(
        (cola.data ?? [])
          .filter((p) => p.userId === paciente.userId)
          .flatMap((p) => p.purchases.flatMap((c) => c.installments.map((i) => i.installmentId))),
      ),
    [cola.data, paciente.userId],
  )
  const { cuotas, cargosSueltosUsd } = useMemo(
    () => armarCuotas(detalle.data?.installments ?? [], cargos.data ?? [], enRevision),
    [detalle.data, cargos.data, enRevision],
  )

  const [seleccion, setSeleccion] = useState<Set<string>>(new Set())
  const [metodo, setMetodo] = useState<PayoutMethod>('pago_movil')
  const [banco, setBanco] = useState('')
  const [referencia, setReferencia] = useState('')
  const [pagadoEl, setPagadoEl] = useState(hoy)
  const [montoBs, setMontoBs] = useState('')
  const [archivo, setArchivo] = useState<File | null>(null)
  const [nota, setNota] = useState('')

  const total = totalDeLaSeleccion(seleccion, cuotas, cargosSueltosUsd)
  const tasaHoy = tasa.data?.rate ?? null
  const esperadoBs = bolivaresEsperados(total.totalUsd, tasaHoy)
  const enBs = medioEnBolivares(metodo)
  const escritoBs = enBs ? leerMonto(montoBs) : null
  const diferencia = enBs ? diferenciaEnBs(escritoBs, esperadoBs, tasaHoy) : null
  const cuatroOjos = valorDe(parametros.data, 'payment_four_eyes') === 1

  const faltan: string[] = []
  const motivoCuotas = motivoDeSeleccion(seleccion, cuotas, hoy)
  if (motivoCuotas) faltan.push(motivoCuotas)
  if (medioConBanco(metodo) && !banco) faltan.push('Elige el banco desde el que pagó.')
  if (medioConReferencia(metodo) && referencia.trim().length < 4) faltan.push('Escribe la referencia del comprobante.')
  if (!pagadoEl || pagadoEl > hoy) faltan.push('La fecha del pago no puede ser futura.')
  if (enBs && (escritoBs === null || escritoBs <= 0)) faltan.push('Escribe el monto en bolívares que dice el comprobante.')
  const motivoArchivo = archivo ? motivoDeArchivo(archivo) : null
  if (motivoArchivo) faltan.push(motivoArchivo)

  const mutation = useMutation({
    mutationFn: async () => {
      const ruta = archivo ? await subirComprobanteDePago({ userId: paciente.userId, file: archivo }) : null
      return registrarPago({
        userId: paciente.userId,
        installmentIds: cuotas.filter((c) => seleccion.has(c.id)).map((c) => c.id),
        method: metodo,
        bank: medioConBanco(metodo) ? banco : null,
        reference: referencia,
        paidOn: pagadoEl,
        amountVes: enBs ? escritoBs : null,
        receiptPath: ruta,
        note: nota,
      })
    },
    onSuccess: (pago) => {
      void client.invalidateQueries({ queryKey: ['payment-queue'] })
      void client.invalidateQueries({ queryKey: ['admin-user', paciente.userId] })
      void client.invalidateQueries({ queryKey: ['admin-late-fees', paciente.userId] })
      void client.invalidateQueries({ queryKey: ['admin-collections'] })
      onHecho(pago)
    },
  })

  return (
    <div className="flex flex-col gap-5">
      <div className="flex items-center justify-between gap-3">
        <SectionTitle>Cuotas de {paciente.nombre ?? 'este paciente'}</SectionTitle>
        {onCambiarPaciente && (
          <Button size="sm" variant="text" onClick={onCambiarPaciente}>
            Cambiar de paciente
          </Button>
        )}
      </div>

      {(detalle.isPending || cargos.isPending) && <SkeletonList rows={3} />}
      {detalle.isError && <ErrorBox title="No se pudieron leer sus cuotas" detail={describeError(detalle.error)} />}
      {cargos.isError && (
        <Callout tone="warning" titulo="No se pudieron leer sus cargos por atraso">
          El total de abajo no los incluye, pero el servidor sí los cobrará.
        </Callout>
      )}

      {detalle.data && cuotas.length === 0 && (
        <Callout tone="info" titulo="Este paciente no tiene ninguna cuota pendiente">
          No hay nada que registrar. Si pagó de más, anótalo en una gestión y avisa al equipo.
        </Callout>
      )}

      {cuotas.length > 0 && (
        <ListaDeCuotas
          cuotas={cuotas}
          seleccion={seleccion}
          hoy={hoy}
          onAlternar={(id) => setSeleccion((s) => alternarCuota(s, id, cuotas, hoy))}
        />
      )}

      {seleccion.size > 0 && (
        <div className="flex flex-col gap-1 rounded-panel-control border border-panel-hairline p-4">
          <Fila rotulo={`${seleccion.size} ${seleccion.size === 1 ? 'cuota' : 'cuotas'}, con fee`} valor={formatUsd(total.cuotasUsd)} />
          {total.cargosUsd > 0 && <Fila rotulo="Cargos por atraso que viajan con ellas" valor={formatUsd(total.cargosUsd)} />}
          <Fila rotulo="Total a pagar" valor={formatUsd(total.totalUsd)} fuerte />
          <p className="mt-1 type-panel-caption text-on-surface-variant">
            {esperadoBs !== null && tasaHoy !== null
              ? `A la tasa BCV de hoy (${formatBcvRate(tasaHoy)}): ${formatVes(esperadoBs)}.`
              : 'Sin tasa BCV cargada no se puede calcular el monto en bolívares.'}
          </p>
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <Select
          id="registrar-pago-metodo"
          label="Cómo pagó"
          value={metodo}
          options={METODOS_DE_PAGO}
          onChange={setMetodo}
        />
        {medioConBanco(metodo) && (
          <Select
            id="registrar-pago-banco"
            label="Desde qué banco"
            value={banco}
            placeholder="Elige el banco"
            options={BANKS.map((b) => ({ value: b.name, label: b.name }))}
            onChange={setBanco}
          />
        )}
        <Input
          id="registrar-pago-referencia"
          label={medioConReferencia(metodo) ? 'Referencia' : 'Referencia (opcional)'}
          value={referencia}
          onChange={setReferencia}
          placeholder="Los últimos dígitos del comprobante"
          autoComplete="off"
        />
        <Input
          id="registrar-pago-fecha"
          label="Fecha del pago"
          type="date"
          value={pagadoEl}
          onChange={setPagadoEl}
          max={hoy}
        />
        {enBs && (
          <Input
            id="registrar-pago-monto"
            label="Monto en bolívares (lo que dice el comprobante)"
            value={montoBs}
            onChange={setMontoBs}
            inputMode="decimal"
            placeholder={esperadoBs !== null ? formatVes(esperadoBs) : 'Bs'}
            hint={
              diferencia === null
                ? undefined
                : diferencia.cuadra
                  ? 'Cuadra con lo esperado a la tasa de hoy.'
                  : `${diferencia.bs > 0 ? 'Pagó de más' : 'Faltan'} ${formatVes(Math.abs(diferencia.bs))} (≈ ${formatUsd(Math.abs(diferencia.usd))}) respecto a lo esperado a la tasa de hoy.`
            }
            error={diferencia !== null && !diferencia.cuadra}
          />
        )}
        <AdjuntarComprobante id="registrar-pago-captura" file={archivo} onChange={setArchivo} />
      </div>

      <Textarea
        id="registrar-pago-nota"
        label="Nota (opcional)"
        value={nota}
        onChange={setNota}
        rows={2}
        maxLength={300}
        placeholder="Mandó la captura por WhatsApp a las 9:40"
      />

      {cuatroOjos && (
        <p className="type-panel-caption text-on-surface-variant">
          El doble control está activo: el pago lo tendrá que aprobar otra persona del equipo (o un super admin).
        </p>
      )}

      {mutation.isError && <ErrorBox title="No se pudo registrar el pago" detail={describeError(mutation.error)} />}

      <Button
        size="md"
        disabled={faltan.length > 0 || mutation.isPending || cuotas.length === 0}
        motivoApagado={faltan[0]}
        onClick={() => mutation.mutate()}
      >
        {mutation.isPending ? 'Registrando…' : `Registrar el pago de ${formatUsd(total.totalUsd)}`}
      </Button>
    </div>
  )
}

function Fila({ rotulo, valor, fuerte = false }: { rotulo: string; valor: string; fuerte?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="type-panel-body text-on-surface-variant">{rotulo}</span>
      <span className={`tabular-nums text-on-surface ${fuerte ? 'type-panel-section' : 'type-panel-body font-semibold'}`}>
        {valor}
      </span>
    </div>
  )
}

/**
 * Las cuotas pendientes, de la que vence antes a la que vence después, cada
 * una con su vencimiento, su monto y su cargo por atraso. Marcar una por
 * vencer marca también lo vencido (`alternarCuota`).
 */
function ListaDeCuotas({
  cuotas,
  seleccion,
  hoy,
  onAlternar,
}: {
  cuotas: CuotaParaPagar[]
  seleccion: ReadonlySet<string>
  hoy: string
  onAlternar: (id: string) => void
}) {
  return (
    <div className="flex max-h-80 flex-col gap-2 overflow-y-auto">
      {cuotas.map((c) => {
        const vencida = c.dueDate < hoy
        return (
          <div key={c.id} className="flex items-center gap-3 rounded-panel-control bg-panel-raised p-3">
            <div className="flex-1">
              <Checkbox
                id={`registrar-pago-cuota-${c.id}`}
                checked={seleccion.has(c.id)}
                onChange={() => onAlternar(c.id)}
                label={
                  <>
                    <span className="block">
                      Cuota {c.sequence} · {c.merchantName}
                      {c.orderNumber !== null && ` · #${c.orderNumber}`}
                      {c.enRevision && (
                        <Badge tone="warning" className="ml-2">
                          Con un pago sin aprobar
                        </Badge>
                      )}
                    </span>
                    <span className={`block type-panel-caption ${vencida ? 'text-error' : 'text-on-surface-variant'}`}>
                      {c.dueDate === hoy ? 'Vence hoy' : vencida ? `Venció el ${formatDay(c.dueDate)}` : `Vence el ${formatDay(c.dueDate)}`}
                      {c.lateFeesUsd > 0 && `, con ${formatUsd(c.lateFeesUsd)} de cargo por atraso`}
                    </span>
                  </>
                }
              />
            </div>
            <span className="font-semibold tabular-nums text-on-surface">{formatUsd(c.amountUsd)}</span>
          </div>
        )
      })}
      <p className="type-panel-caption text-on-surface-variant">
        Lo vencido va primero: marcar una cuota por vencer marca también las que vencen hoy o antes.
      </p>
    </div>
  )
}

// ── 3. Hecho ───────────────────────────────────────────────────────────────

function PagoHecho({ pago, nombre, onClose }: { pago: PagoRegistrado; nombre: string | null; onClose: () => void }) {
  const extracto = fraseDelExtracto(pago.candidatosExtracto)
  return (
    <div className="flex flex-col gap-4">
      <Callout tone="success" titulo={`Pago de ${formatUsd(pago.amountUsd)} registrado${nombre ? ` a ${nombre}` : ''}`}>
        {pago.amountVes !== null && pago.fxRate !== null
          ? `${formatVes(pago.amountVes)} a ${formatBcvRate(pago.fxRate)}. `
          : ''}
        {pago.lateFeeUsd > 0 ? `Incluye ${formatUsd(pago.lateFeeUsd)} de cargos por atraso. ` : ''}
        Queda en Pagos reportados para aprobarlo.
      </Callout>
      <Callout tone={extracto.tono} titulo="Candidatos en el extracto">
        {extracto.texto}
      </Callout>
      <div className="flex flex-wrap gap-3">
        <Link to="/admin/cobros/$id" params={{ id: pago.reportId }} search={{}} className={claseDeBoton('filled', 'md')}>
          Abrir en Pagos reportados <ArrowRight size={14} aria-hidden />
        </Link>
        <Button size="md" variant="text" onClick={onClose}>
          Cerrar
        </Button>
      </div>
    </div>
  )
}
