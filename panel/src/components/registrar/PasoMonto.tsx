import { useEffect, useRef, useState } from 'react'
import { ArrowLeft } from 'lucide-react'

import {
  Button,
  Callout,
  Card,
  Chip,
  NOMBRE_DE_MONEDA,
  SIMBOLO_DE_MONEDA,
  Tecla,
  formatMoneda,
  formatVes,
} from '@/components/ui'
import type { Moneda } from '@/components/ui'
import {
  CONCEPTO_SUGERIDO,
  DE_LA_MONEDA,
  TOPE_CONCEPTO,
  enBolivares,
  leerMontoDeConsulta,
} from '@/features/merchant/registro'

import { BotonConFoco, Campo, Opciones } from './Campo'

/** Conceptos de un toque. Genéricos a propósito: el concepto viaja en el correo. */
const CONCEPTOS = ['Consulta', 'Consulta y exámenes', 'Control', 'Procedimiento']

const MONEDAS: ReadonlyArray<{ value: Moneda; label: string }> = [
  { value: 'USD', label: 'Dólares (USD)' },
  { value: 'EUR', label: 'Euros (EUR)' },
]

/**
 * PASO 3 · CUÁNTO Y DE QUÉ.
 *
 * Monto libre (sin catálogo, D-H4), en dólares o en euros (lo elige el
 * médico, 2026-10-07), desde el mínimo de Helios y hasta lo que el paciente
 * tiene disponible (o el límite, si es nuevo). Es lo que vale la consulta y lo
 * que se le paga a la clínica: el servicio de Helios va aparte y lo paga el
 * paciente dentro de sus cuotas.
 *
 * El mínimo y el máximo viven en dólares; en euros llegan ya convertidos con
 * la tasa cruzada de hoy (`limitesEnMoneda`). Sin tasa del euro, `limites` es
 * null y no se puede seguir en euros. Debajo del monto, lo que serían hoy en
 * bolívares: solo de referencia, el paciente paga a la tasa del día en que paga.
 *
 * El concepto es opcional y conviene genérico: el nombre de un servicio
 * puede revelar un diagnóstico («consulta oncológica») y va en el correo.
 */
export function PasoMonto({
  titular,
  moneda,
  monto,
  concepto,
  beneficiario,
  limites,
  tasaBs,
  buscandoTasas,
  onReintentarTasas,
  onMoneda,
  onMonto,
  onConcepto,
  onBeneficiario,
  onAtras,
  atrasLabel,
  onSeguir,
}: {
  /** Quién paga, para tenerlo delante: nombre tecleado o el que ya tiene Helios, y cédula. */
  titular: string
  moneda: Moneda
  monto: string
  concepto: string
  beneficiario: string
  /** El mínimo y el máximo en `moneda`. Null si no hay tasa para convertirlos. */
  limites: { minimo: number; maximo: number | null } | null
  /** Bs por unidad de `moneda`, hoy. Null sin tasa: no se enseña el equivalente. */
  tasaBs: number | null
  /** Las tasas de hoy todavía no han llegado. */
  buscandoTasas: boolean
  /** Si la consulta de las tasas falló, para volver a pedirlas. */
  onReintentarTasas?: () => void
  onMoneda: (v: Moneda) => void
  onMonto: (v: string) => void
  onConcepto: (v: string) => void
  onBeneficiario: (v: string) => void
  onAtras: () => void
  atrasLabel: string
  onSeguir: () => void
}) {
  const montoRef = useRef<HTMLInputElement>(null)
  const conceptoRef = useRef<HTMLInputElement>(null)
  const [intentado, setIntentado] = useState(false)
  const [tocado, setTocado] = useState(false)

  useEffect(() => {
    montoRef.current?.focus()
  }, [])

  const formato = (n: number) => formatMoneda(n, moneda)
  const lectura = limites ? leerMontoDeConsulta(monto, limites, formato) : null
  const enBs = lectura?.ok ? enBolivares(lectura.monto, tasaBs) : null
  const problemaConcepto =
    concepto.trim().length > TOPE_CONCEPTO ? `El concepto no puede pasar de ${TOPE_CONCEPTO} caracteres.` : null

  function seguir() {
    setIntentado(true)
    // Sin tasa para la moneda elegida no hay nada que validar: el aviso de
    // arriba ya dice qué hacer.
    if (!lectura) return
    if (!lectura.ok) {
      montoRef.current?.focus()
      return
    }
    if (problemaConcepto) {
      conceptoRef.current?.focus()
      return
    }
    onSeguir()
  }

  const rango = !limites
    ? null
    : limites.maximo === null
      ? `Desde ${formato(limites.minimo)}`
      : `Entre ${formato(limites.minimo)} y ${formato(limites.maximo)}`

  return (
    <form
      noValidate
      onSubmit={(e) => {
        e.preventDefault()
        seguir()
      }}
      className="flex flex-col gap-5"
    >
      <p className="type-panel-body text-on-surface-variant">
        Titular: <strong className="text-on-surface">{titular}</strong>
      </p>

      <Card variant="hero" className="flex flex-col gap-5">
        <Opciones
          id="alta-moneda"
          label="Moneda de la consulta"
          value={moneda}
          opciones={MONEDAS}
          onChange={onMoneda}
        />

        {!limites &&
          (buscandoTasas ? (
            <p role="status" className="type-panel-body text-on-surface-variant">
              Buscando la tasa BCV {DE_LA_MONEDA[moneda]} de hoy…
            </p>
          ) : (
            <Callout
              tone="warning"
              titulo={
                onReintentarTasas
                  ? `No pudimos leer la tasa BCV ${DE_LA_MONEDA[moneda]} de hoy`
                  : `Hoy no tenemos la tasa BCV ${DE_LA_MONEDA[moneda]}`
              }
              accion={
                onReintentarTasas && (
                  <Button size="sm" variant="tonal" onClick={onReintentarTasas}>
                    Reintentar
                  </Button>
                )
              }
            >
              Sin ella no se puede cobrar en {NOMBRE_DE_MONEDA[moneda]}. Cobra en dólares o
              vuelve a intentarlo más tarde.
            </Callout>
          ))}

        <Campo
          id="alta-monto"
          label={`Monto de la consulta, en ${NOMBRE_DE_MONEDA[moneda]}`}
          value={monto}
          onChange={onMonto}
          onBlur={() => setTocado(true)}
          inputRef={montoRef}
          inputMode="decimal"
          autoComplete="off"
          maxLength={12}
          placeholder="0,00"
          prefijo={SIMBOLO_DE_MONEDA[moneda]}
          grande
          // Vacío solo se reclama al intentar seguir; lo mal escrito, en
          // cuanto se sale del campo.
          error={
            lectura && !lectura.ok && (intentado || (tocado && monto.trim() !== ''))
              ? lectura.problema
              : null
          }
          hint={
            !lectura ? null : lectura.ok ? (
              <>
                {formato(lectura.monto)} · lo que cobra la clínica. {rango}.
                {enBs !== null && (
                  // Solo de referencia: el paciente paga a la tasa del día en que paga.
                  <span className="block">
                    ≈ {formatVes(enBs)} a la tasa BCV {DE_LA_MONEDA[moneda]} de hoy
                  </span>
                )}
              </>
            ) : (
              `${rango}. Sin la Comisión Helios: esa la paga el paciente en sus cuotas.`
            )
          }
          className="max-w-sm"
        />

        <div className="flex flex-col gap-2">
          <Campo
            id="alta-concepto"
            label="Concepto"
            opcional
            value={concepto}
            onChange={onConcepto}
            inputRef={conceptoRef}
            autoComplete="off"
            maxLength={TOPE_CONCEPTO}
            placeholder={CONCEPTO_SUGERIDO}
            error={problemaConcepto}
            hint="Mejor algo general: el concepto aparece en el correo del paciente."
          />
          <div className="flex flex-wrap gap-2">
            {CONCEPTOS.map((c) => (
              <Chip key={c} selected={concepto.trim() === c} onClick={() => onConcepto(c)}>
                {c}
              </Chip>
            ))}
          </div>
        </div>

        <Campo
          id="alta-beneficiario"
          label="Paciente atendido (si es distinto del titular)"
          opcional
          value={beneficiario}
          onChange={onBeneficiario}
          autoComplete="off"
          maxLength={TOPE_CONCEPTO}
          placeholder="Nombre y apellido"
          hint="Por ejemplo, el hijo menor de edad del titular."
        />
      </Card>

      <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3">
        <BotonConFoco type="submit" disabled={!limites}>
          Ver las cuotas
          <Tecla enBoton>Enter</Tecla>
        </BotonConFoco>
        <BotonConFoco variant="text" onClick={onAtras}>
          <ArrowLeft size={16} aria-hidden />
          {atrasLabel}
        </BotonConFoco>
      </div>
    </form>
  )
}
