import { useMemo, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { CheckCircle2, FlaskConical } from 'lucide-react'

import { Callout } from '@/components/kit/Callout'
import {
  Button,
  Card,
  EmptyState,
  ErrorBox,
  Input,
  Select,
  SkeletonList,
  formatBcvRate,
  formatUsd,
  formatVes,
} from '@/components/ui'
import { motivoDeArchivo } from '@/features/admin/pagosRegistrados/registrarPago'
import {
  cotizacionLabOptions,
  explicarErrorLab,
  preciosLabOptions,
  registrarMuestra,
  subirCapturaLab,
  validarMuestra,
} from '@/features/lab/medico'
import type { MuestraRegistrada } from '@/features/lab/medico'
import { ROTULOS_PRECIO } from '@/features/lab/tipos'

type Props = {
  merchantId: string
  /** Preselección que viene de Precios o de la dirección. */
  examenId: string
  laboratorioId: string
  onElegir: (examenId: string, laboratorioId: string) => void
  onVerMuestras: () => void
}

export function Registrar({ merchantId, examenId, laboratorioId, onElegir, onVerMuestras }: Props) {
  const queryClient = useQueryClient()
  const precios = useQuery(preciosLabOptions(merchantId))

  // Una clave por intento de formulario: doble clic o reintento = misma muestra.
  const [clave, setClave] = useState(() => crypto.randomUUID())
  const [nombre, setNombre] = useState('')
  const [whatsapp, setWhatsapp] = useState('')
  const [correo, setCorreo] = useState('')
  const [referencia, setReferencia] = useState('')
  const [banco, setBanco] = useState('')
  const [archivo, setArchivo] = useState<File | null>(null)
  const [intentado, setIntentado] = useState(false)
  const [listo, setListo] = useState<MuestraRegistrada | null>(null)
  // La captura ya subida: si la RPC falla, el reintento no la sube otra vez.
  const subida = useRef<{ file: File; ruta: string } | null>(null)

  const examenes = useMemo(() => {
    const vistos = new Map<string, string>()
    for (const p of precios.data ?? []) if (!vistos.has(p.examenId)) vistos.set(p.examenId, p.nombre)
    return [...vistos].map(([value, label]) => ({ value, label }))
  }, [precios.data])

  const laboratorios = useMemo(
    () =>
      (precios.data ?? [])
        .filter((p) => p.examenId === examenId)
        .map((p) => ({ value: p.laboratorioId, label: `${p.laboratorioNombre} · ${formatUsd(p.precioUsd)}` })),
    [precios.data, examenId],
  )

  const elegido = !!examenId && laboratorios.some((l) => l.value === laboratorioId)

  const cotizacion = useQuery({
    ...cotizacionLabOptions(merchantId, examenId, laboratorioId),
    enabled: elegido,
  })

  const errores = validarMuestra({
    pacienteNombre: nombre,
    pacienteWhatsapp: whatsapp,
    pacienteCorreo: correo,
    pagoReferencia: referencia,
  })
  const errorDeArchivo = archivo ? motivoDeArchivo(archivo) : null
  const hayErrores = Object.keys(errores).length > 0 || !!errorDeArchivo

  const registrar = useMutation({
    mutationFn: async () => {
      let ruta: string | null = null
      if (archivo) {
        if (subida.current?.file !== archivo) {
          subida.current = { file: archivo, ruta: await subirCapturaLab({ merchantId, file: archivo }) }
        }
        ruta = subida.current.ruta
      }
      return registrarMuestra({
        merchantId,
        examenId,
        laboratorioId,
        pacienteNombre: nombre,
        pacienteWhatsapp: whatsapp,
        pacienteCorreo: correo,
        pagoReferencia: referencia,
        pagoBanco: banco,
        comprobantePath: ruta,
        clave,
      })
    },
    onSuccess: (r) => {
      setListo(r)
      void queryClient.invalidateQueries({ queryKey: ['lab-medico', 'muestras'] })
      void queryClient.invalidateQueries({ queryKey: ['lab-medico', 'kits'] })
    },
  })

  function otra() {
    setClave(crypto.randomUUID())
    setNombre('')
    setWhatsapp('')
    setCorreo('')
    setReferencia('')
    setBanco('')
    setArchivo(null)
    setIntentado(false)
    setListo(null)
    subida.current = null
    registrar.reset()
  }

  function enviar() {
    setIntentado(true)
    if (hayErrores || !elegido || registrar.isPending) return
    registrar.mutate()
  }

  if (listo) {
    return (
      <Card className="flex flex-col gap-4">
        <div className="flex items-start gap-3">
          <CheckCircle2 className="mt-0.5 shrink-0 text-success" size={22} aria-hidden />
          <div>
            <p className="type-panel-body font-semibold text-on-surface">
              Listo. Helios ya sabe que hay una muestra para retirar.
            </p>
            <p className="mt-1 type-panel-body text-on-surface-variant">
              Código de la muestra: <strong className="text-on-surface">{listo.codigo}</strong>. Rotula el tubo con
              ese código.
            </p>
            <p className="type-panel-caption text-on-surface-variant">
              {formatUsd(listo.precioUsd)} · {formatVes(listo.montoVes)}
            </p>
          </div>
        </div>
        {listo.kitsRestantes !== null && listo.kitsRestantes <= 0 && (
          <Callout tone="warning" titulo="Ya no te quedan kits de este tipo">
            Pídelos en la pestaña Kits para la próxima muestra.
          </Callout>
        )}
        <div className="flex flex-wrap gap-2">
          <Button onClick={otra}>Registrar otra muestra</Button>
          <Button variant="outlined" onClick={onVerMuestras}>
            Ver mis muestras
          </Button>
        </div>
      </Card>
    )
  }

  if (precios.isPending) return <SkeletonList />
  if (precios.isError)
    return <ErrorBox title="No se pudieron cargar los exámenes" detail={explicarErrorLab(precios.error)} />
  if (examenes.length === 0)
    return (
      <EmptyState
        icon={<FlaskConical size={28} />}
        title="Todavía no hay exámenes con precio"
        description="Cuando Helios cargue la lista de exámenes, podrás registrar muestras."
      />
    )

  const c = cotizacion.data

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(e) => {
        e.preventDefault()
        enviar()
      }}
    >
      <Card className="flex flex-col gap-3">
        <Select
          id="lab-examen"
          label="Examen"
          value={examenId}
          options={examenes}
          placeholder="Elige el examen"
          onChange={(v) => {
            // Con un solo laboratorio para ese examen, ya queda elegido.
            const delExamen = precios.data.filter((p) => p.examenId === v)
            onElegir(v, delExamen.length === 1 ? delExamen[0].laboratorioId : '')
          }}
        />
        {examenId && (
          <Select
            id="lab-laboratorio"
            label="Laboratorio"
            value={elegido ? laboratorioId : ''}
            options={laboratorios}
            placeholder="Elige el laboratorio"
            onChange={(v) => onElegir(examenId, v)}
          />
        )}

        {elegido && cotizacion.isPending && <SkeletonList />}
        {elegido && cotizacion.isError && (
          <ErrorBox title="No se pudo cotizar" detail={explicarErrorLab(cotizacion.error)} />
        )}
        {elegido && c && (
          <Card tone="inset">
            <p className="type-panel-caption text-on-surface-variant">{ROTULOS_PRECIO.precio}: dícelo al paciente</p>
            <p className="text-3xl font-bold tabular-nums text-on-surface">{formatUsd(c.precioUsd)}</p>
            <p className="type-panel-body font-semibold tabular-nums text-on-surface">
              {formatVes(c.montoVes)}
            </p>
            <p className="type-panel-caption text-on-surface-variant">
              A la tasa BCV de hoy: {formatBcvRate(c.tasaBcv)} Bs por dólar. El paciente paga en bolívares por Pago
              Móvil a la cuenta de Helios.
            </p>
          </Card>
        )}
      </Card>

      {elegido && c && (
        <Card className="flex flex-col gap-3">
          <Input
            id="lab-nombre"
            label="Nombre del paciente"
            value={nombre}
            onChange={setNombre}
            autoComplete="off"
            error={intentado && !!errores.pacienteNombre}
            hint={intentado ? errores.pacienteNombre : undefined}
          />
          <Input
            id="lab-whatsapp"
            label="WhatsApp del paciente"
            value={whatsapp}
            onChange={setWhatsapp}
            type="tel"
            inputMode="tel"
            autoComplete="off"
            placeholder="0414 123 4567"
            error={intentado && !!errores.pacienteWhatsapp}
            hint={intentado && errores.pacienteWhatsapp ? errores.pacienteWhatsapp : 'Ahí le llegará el resultado.'}
          />
          <Input
            id="lab-correo"
            label="Correo del paciente (opcional)"
            value={correo}
            onChange={setCorreo}
            type="email"
            autoComplete="off"
            error={intentado && !!errores.pacienteCorreo}
            hint={intentado ? errores.pacienteCorreo : undefined}
          />
          <Input
            id="lab-referencia"
            label="Referencia del Pago Móvil"
            value={referencia}
            onChange={setReferencia}
            inputMode="numeric"
            autoComplete="off"
            error={intentado && !!errores.pagoReferencia}
            hint={intentado && errores.pagoReferencia ? errores.pagoReferencia : 'Los dígitos de la referencia del pago.'}
          />
          <Input
            id="lab-banco"
            label="Banco del paciente (opcional)"
            value={banco}
            onChange={setBanco}
            autoComplete="off"
          />
          <div>
            <label htmlFor="lab-captura" className="mb-1.5 block type-panel-label text-on-surface-variant">
              Captura del pago (recomendada)
            </label>
            <input
              id="lab-captura"
              type="file"
              accept="image/*,application/pdf"
              onChange={(e) => setArchivo(e.target.files?.[0] ?? null)}
              className="block w-full type-panel-body text-on-surface-variant"
            />
            <p className={`mt-1.5 type-panel-caption ${errorDeArchivo ? 'text-error' : 'text-panel-muted'}`}>
              {errorDeArchivo ??
                'Imagen o PDF de hasta 10 MB. Con la captura, Helios confirma el pago más rápido.'}
            </p>
          </div>
        </Card>
      )}

      {registrar.isError && (
        <ErrorBox title="No se pudo registrar la muestra" detail={explicarErrorLab(registrar.error)} />
      )}

      {elegido && c && (
        <div>
          <Button
            type="submit"
            disabled={registrar.isPending}
            motivoApagado={registrar.isPending ? 'Registrando la muestra…' : undefined}
          >
            {registrar.isPending ? 'Registrando…' : 'Registrar muestra'}
          </Button>
        </div>
      )}
    </form>
  )
}
