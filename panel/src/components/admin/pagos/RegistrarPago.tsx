import { useMemo, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowRight, HandCoins, Search } from 'lucide-react'

import { AdjuntarComprobante } from '@/components/admin/caja/AdjuntarComprobante'
import { VerCaptura } from '@/components/admin/caja/VerCaptura'
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
  formatBcvRateDe,
  formatDateTime,
  formatDay,
  formatDocument,
  formatPhone,
  formatMoneda,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { reconcilePayment } from '@/features/admin/api'
import { BANKS } from '@/features/admin/banks'
import { motivoDeLaLectura, paraElFormulario } from '@/features/admin/lectorComprobantes'
import type { Lectura, LoQueLeyo } from '@/features/admin/lectorComprobantes'
import { fetchUltimaLectura } from '@/features/admin/lectorComprobantesApi'
import { fetchPaymentReport } from '@/features/admin/pagosReportados'
import { useIsSuperAdmin } from '@/features/admin/role'
import { consultaCargosPorAtraso } from '@/features/admin/cobranza/consultas'
import { valorDe } from '@/features/admin/parametros'
import { useParametros } from '@/features/admin/useParametros'
import { fetchUserDetail, fetchUsers } from '@/features/admin/users'
import type { UserRow } from '@/features/admin/users'
import { preverPago, registrarPago, subirComprobanteDePago } from '@/features/admin/pagosRegistrados/api'
import {
  METODOS_DEL_PACIENTE,
  alternarCuota,
  armarCuotas,
  diferenciaEnBs,
  fraseDelExtracto,
  montoDeLaCuota,
  motivoDeArchivo,
  motivoDeSeleccion,
  totalDeLaSeleccion,
} from '@/features/admin/pagosRegistrados/registrarPago'
import type {
  CuotaParaPagar,
  MetodoDelPaciente,
  PagoRegistrado,
  PrevisionDelPago,
} from '@/features/admin/pagosRegistrados/registrarPago'
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
 *
 * El paciente solo paga en bolívares (Pago Móvil o transferencia), cada cuota
 * a la tasa BCV de la moneda de su orden del día en que pagó. Lo que debería
 * decir el comprobante lo da la base para esas cuotas y esa fecha
 * (`admin_payment_preview`): no se multiplica aquí por una sola tasa.
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
                {u.document && ` · ${formatDocument(u.document)}`} · debe {formatUsd(u.openDebtUsd)} con comisión
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
  const [metodo, setMetodo] = useState<MetodoDelPaciente>('pago_movil')
  const [banco, setBanco] = useState('')
  const [referencia, setReferencia] = useState('')
  const [pagadoEl, setPagadoEl] = useState(hoy)
  const [montoBs, setMontoBs] = useState('')
  const [archivo, setArchivo] = useState<File | null>(null)
  const [nota, setNota] = useState('')

  // Lo que leyó el bot de la última captura de este paciente que no
  // registró solo (docs/03): se ofrece para no teclearlo, y su captura vale
  // como la del pago.
  const leida = useQuery({
    queryKey: ['receipt-read-latest', paciente.userId],
    queryFn: () => fetchUltimaLectura(paciente.userId),
    staleTime: 60_000,
  })
  const [usada, setUsada] = useState<LoQueLeyo | null>(null)
  function usarLoLeido(l: LoQueLeyo) {
    if (l.metodo) setMetodo(l.metodo)
    if (l.banco) setBanco(l.banco)
    if (l.referencia) setReferencia(l.referencia)
    if (l.fecha && l.fecha <= hoy) setPagadoEl(l.fecha)
    if (l.montoBs) setMontoBs(l.montoBs)
    setUsada(l)
  }

  const total = totalDeLaSeleccion(seleccion, cuotas, cargosSueltosUsd)
  const idsMarcados = cuotas.filter((c) => seleccion.has(c.id)).map((c) => c.id)
  const fechaValida = pagadoEl !== '' && pagadoEl <= hoy
  // Lo que debería decir el comprobante, según la base: cada parte a la tasa
  // BCV de su moneda del día del pago. Mientras se cambia la selección se
  // queda la cifra anterior en vez de parpadear.
  const prevision = useQuery({
    queryKey: ['admin-payment-preview', paciente.userId, idsMarcados, pagadoEl],
    queryFn: () => preverPago({ userId: paciente.userId, installmentIds: idsMarcados, paidOn: pagadoEl }),
    enabled: idsMarcados.length > 0 && fechaValida,
    placeholderData: keepPreviousData,
  })
  const esperado = idsMarcados.length > 0 ? (prevision.data ?? null) : null
  const esperadoBs = esperado?.amountVes ?? null
  const escritoBs = leerMonto(montoBs)
  const diferencia = diferenciaEnBs(escritoBs, esperadoBs, esperado?.fxRate ?? null)
  const cuatroOjos = valorDe(parametros.data, 'payment_four_eyes') === 1

  const faltan: string[] = []
  const motivoCuotas = motivoDeSeleccion(seleccion, cuotas, hoy)
  if (motivoCuotas) faltan.push(motivoCuotas)
  if (!banco) faltan.push('Elige el banco desde el que pagó.')
  if (referencia.trim().length < 4) faltan.push('Escribe la referencia del comprobante.')
  if (!fechaValida) faltan.push('La fecha del pago no puede ser futura.')
  if (escritoBs === null || escritoBs <= 0) faltan.push('Escribe el monto en bolívares que dice el comprobante.')
  const motivoArchivo = archivo ? motivoDeArchivo(archivo) : null
  if (motivoArchivo) faltan.push(motivoArchivo)

  const mutation = useMutation({
    mutationFn: async () => {
      const ruta = archivo
        ? await subirComprobanteDePago({ userId: paciente.userId, file: archivo })
        : (usada?.rutaCaptura ?? null)
      return registrarPago({
        userId: paciente.userId,
        installmentIds: idsMarcados,
        method: metodo,
        bank: banco,
        reference: referencia,
        paidOn: pagadoEl,
        // `faltan` ya impide llegar aquí sin él.
        amountVes: escritoBs ?? 0,
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
          <Fila rotulo={`${seleccion.size} ${seleccion.size === 1 ? 'cuota' : 'cuotas'}, con comisión`} valor={formatUsd(total.cuotasUsd)} />
          {total.cargosUsd > 0 && <Fila rotulo="Cargos por atraso que viajan con ellas" valor={formatUsd(total.cargosUsd)} />}
          <Fila rotulo="Total a pagar" valor={formatUsd(total.totalUsd)} fuerte />
          <LoQueDiceElComprobante
            prevision={esperado}
            cargando={prevision.isFetching && !esperado}
            error={prevision.isError}
            dia={pagadoEl}
            hoy={hoy}
          />
        </div>
      )}

      {leida.data && !usada && <LoQueLeyoElBot lectura={leida.data} onUsar={usarLoLeido} />}

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <Select
          id="registrar-pago-metodo"
          label="Cómo pagó (solo en bolívares)"
          value={metodo}
          options={METODOS_DEL_PACIENTE}
          onChange={setMetodo}
        />
        <Select
          id="registrar-pago-banco"
          label="Desde qué banco"
          value={banco}
          placeholder="Elige el banco"
          options={BANKS.map((b) => ({ value: b.name, label: b.name }))}
          onChange={setBanco}
        />
        <Input
          id="registrar-pago-referencia"
          label="Referencia"
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
                ? `Cuadra con lo esperado a las tasas del ${formatDay(pagadoEl)}.`
                : `${diferencia.bs > 0 ? 'Pagó de más' : 'Faltan'} ${formatVes(Math.abs(diferencia.bs))} (≈ ${formatUsd(Math.abs(diferencia.usd))}) respecto a lo esperado a las tasas del ${formatDay(pagadoEl)}.`
          }
          error={diferencia !== null && !diferencia.cuadra}
        />
        <div className="flex flex-col gap-1">
          <AdjuntarComprobante id="registrar-pago-captura" file={archivo} onChange={setArchivo} />
          {usada?.rutaCaptura && !archivo && (
            <p className="type-panel-caption text-on-surface-variant">
              Sin otra captura, se guarda la que mandó por WhatsApp.
            </p>
          )}
        </div>
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

/**
 * La última captura de este paciente que leyó el bot y no registró sola
 * (fue al equipo, o el lector está en sombra): lo que leyó, para no
 * teclearlo. Las cuotas las sigue eligiendo el equipo.
 */
function LoQueLeyoElBot({ lectura, onUsar }: { lectura: Lectura; onUsar: (l: LoQueLeyo) => void }) {
  const motivo = motivoDeLaLectura(lectura.motivo)
  const resumen = [
    lectura.montoVes === null ? null : formatVes(lectura.montoVes),
    lectura.referencia ? `ref. ${lectura.referencia}` : null,
    lectura.banco,
    lectura.pagadoEl ? formatDay(lectura.pagadoEl) : null,
  ]
    .filter(Boolean)
    .join(' · ')

  return (
    <Callout
      tone="info"
      titulo={`El bot leyó ${lectura.tipo === 'captura' ? 'una captura' : 'los datos de un pago'} del ${formatDateTime(lectura.llego)}`}
      accion={
        <div className="flex flex-wrap gap-2">
          <Button size="sm" variant="tonal" onClick={() => onUsar(paraElFormulario(lectura))}>
            Usar lo que leyó
          </Button>
          {lectura.rutaCaptura && <VerCaptura ruta={lectura.rutaCaptura} rotulo="Ver la captura" />}
        </div>
      }
      detalles={motivo ? `No lo registró solo: ${motivo.charAt(0).toLowerCase()}${motivo.slice(1)}.` : undefined}
    >
      {resumen || 'No se leyó ningún dato.'}
    </Callout>
  )
}

/**
 * Lo que debería decir el comprobante en bolívares, según la base: el total
 * y, si hay cuotas de órdenes en euros, qué parte va a la tasa del euro y qué
 * parte a la del dólar.
 */
function LoQueDiceElComprobante({
  prevision,
  cargando,
  error,
  dia,
  hoy,
}: {
  prevision: PrevisionDelPago | null
  cargando: boolean
  error: boolean
  dia: string
  hoy: string
}) {
  const cuando = dia === hoy ? 'de hoy' : `del ${formatDay(dia)}`
  if (error) {
    return (
      <p className="mt-1 type-panel-caption text-warning">
        No se pudo calcular el monto en bolívares. El servidor lo calculará al registrar.
      </p>
    )
  }
  if (cargando || !prevision) {
    return <p className="mt-1 type-panel-caption text-on-surface-variant">Calculando los bolívares…</p>
  }
  if (prevision.amountVes === null) {
    const falta = prevision.amountEur > 0 && prevision.fxRateEur === null ? 'del euro' : 'del dólar'
    return (
      <p className="mt-1 type-panel-caption text-warning">
        Falta la tasa BCV {falta} {cuando}: sin ella no se puede calcular el monto en bolívares. Cárgala en
        Ajustes › Tasa BCV.
      </p>
    )
  }
  const partes = [
    prevision.amountEur > 0 && prevision.fxRateEur !== null
      ? `${formatMoneda(prevision.amountEur, 'EUR')} a la ${formatBcvRateDe(prevision.fxRateEur, 'EUR')}`
      : null,
    prevision.amountUsdPart > 0 && prevision.fxRate !== null
      ? `${formatUsd(prevision.amountUsdPart)} a la ${formatBcvRate(prevision.fxRate)}`
      : null,
  ].filter((p): p is string => p !== null)
  return (
    <p className="mt-1 type-panel-caption text-on-surface-variant">
      En bolívares, a las tasas {cuando}:{' '}
      <span className="font-semibold text-on-surface">{formatVes(prevision.amountVes)}</span>
      {partes.length > 0 && ` (${partes.join(' + ')})`}.
    </p>
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
            <span className="text-right font-semibold tabular-nums text-on-surface">{montoDeLaCuota(c)}</span>
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

/**
 * El pago, registrado. Tres finales posibles, de más corto a más largo:
 *
 *   - el aviso del BNC (SMS) ya lo encontró y lo aprobó solo (bot en modo
 *     activo, `helios_bank_sms_on_report`): no queda nada que hacer;
 *   - hay un único movimiento del extracto que encaja: se aprueba aquí mismo
 *     con él, sin ir a Pagos reportados (si el doble control no lo impide);
 *   - si no, queda en Pagos reportados para aprobarlo allí.
 */
function PagoHecho({ pago, nombre, onClose }: { pago: PagoRegistrado; nombre: string | null; onClose: () => void }) {
  const extracto = fraseDelExtracto(pago.candidatosExtracto)
  const queryClient = useQueryClient()
  const parametros = useParametros()
  const esSuperAdmin = useIsSuperAdmin()
  // Con el doble control, quien registra no aprueba (salvo un super admin).
  const puedeAprobar = valorDe(parametros.data, 'payment_four_eyes') !== 1 || esSuperAdmin

  // Cómo quedó: el bot de avisos del BNC lo puede haber aprobado ya.
  const estado = useQuery({
    queryKey: ['payment-report', pago.reportId],
    queryFn: () => fetchPaymentReport(pago.reportId),
  })
  const aprobadoYa = estado.data?.status === 'reconciled'

  const aprobar = useMutation({
    // Sin movimiento: la base liga el único candidato libre del extracto.
    mutationFn: () => reconcilePayment({ reportId: pago.reportId, approve: true }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['payment-report', pago.reportId] })
      void queryClient.invalidateQueries({ queryKey: ['payment-queue'] })
      void queryClient.invalidateQueries({ queryKey: ['reconciliation-health'] })
    },
  })
  const aprobadoAqui = aprobar.isSuccess
  const ofrecerAprobar =
    !aprobadoYa && !aprobadoAqui && estado.data?.status === 'reported' && pago.candidatosExtracto === 1 && puedeAprobar

  return (
    <div className="flex flex-col gap-4">
      <Callout tone="success" titulo={`Pago de ${formatUsd(pago.amountUsd)} registrado${nombre ? ` a ${nombre}` : ''}`}>
        {pago.amountVes !== null && pago.fxRate !== null
          ? `${formatVes(pago.amountVes)} a ${formatBcvRate(pago.fxRate)}${
              pago.amountEur !== null && pago.amountEur > 0 && pago.fxRateEur !== null
                ? ` (lo de euros, ${formatMoneda(pago.amountEur, 'EUR')}, a ${formatBcvRateDe(pago.fxRateEur, 'EUR')})`
                : ''
            }. `
          : ''}
        {pago.lateFeeUsd > 0 ? `Incluye ${formatUsd(pago.lateFeeUsd)} de cargos por atraso. ` : ''}
        {aprobadoYa && !aprobadoAqui
          ? 'Lo aprobó al momento el aviso (SMS) del BNC: las cuotas ya están saldadas.'
          : aprobadoAqui
            ? 'Aprobado con el movimiento del extracto: las cuotas ya están saldadas.'
            : 'Queda en Pagos reportados para aprobarlo.'}
      </Callout>
      {!aprobadoYa && !aprobadoAqui && (
        <Callout tone={extracto.tono} titulo="Candidatos en el extracto">
          {extracto.texto}
          {pago.candidatosExtracto === 1 && !puedeAprobar &&
            ' El doble control está activo: lo aprueba otra persona del equipo.'}
        </Callout>
      )}
      {aprobar.isError && <ErrorBox title="No se pudo aprobar" detail={describeError(aprobar.error)} />}
      <div className="flex flex-wrap gap-3">
        {ofrecerAprobar ? (
          <Button size="md" disabled={aprobar.isPending} onClick={() => aprobar.mutate()}>
            {aprobar.isPending ? 'Aprobando…' : `Aprobar ahora ${formatUsd(pago.amountUsd)}`}
          </Button>
        ) : null}
        <Link
          to="/admin/cobros/$id"
          params={{ id: pago.reportId }}
          search={{}}
          className={claseDeBoton(ofrecerAprobar ? 'tonal' : 'filled', 'md')}
        >
          Abrir en Pagos reportados <ArrowRight size={14} aria-hidden />
        </Link>
        <Button size="md" variant="text" onClick={onClose}>
          Cerrar
        </Button>
      </div>
    </div>
  )
}
