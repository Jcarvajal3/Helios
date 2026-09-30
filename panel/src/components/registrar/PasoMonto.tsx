import { useEffect, useRef, useState } from 'react'
import { ArrowLeft } from 'lucide-react'

import { Card, Chip, Tecla, formatUsd } from '@/components/ui'
import { CONCEPTO_SUGERIDO, TOPE_CONCEPTO, leerMontoDeConsulta } from '@/features/merchant/registro'

import { BotonConFoco, Campo } from './Campo'

/** Conceptos de un toque. Genéricos a propósito: el concepto viaja en el correo. */
const CONCEPTOS = ['Consulta', 'Consulta y exámenes', 'Control', 'Procedimiento']

/**
 * PASO 3 · CUÁNTO Y DE QUÉ.
 *
 * Monto libre (sin catálogo, D-H4), en dólares, desde el mínimo de Helios y
 * hasta lo que el paciente tiene disponible (o el límite, si es nuevo). Es lo
 * que vale la consulta y lo que se le paga a la clínica: el servicio de
 * Helios va aparte y lo paga el paciente dentro de sus cuotas.
 *
 * El concepto es opcional y conviene genérico: el nombre de un servicio
 * puede revelar un diagnóstico («consulta oncológica») y va en el correo.
 */
export function PasoMonto({
  titular,
  monto,
  concepto,
  beneficiario,
  minimo,
  maximo,
  onMonto,
  onConcepto,
  onBeneficiario,
  onAtras,
  atrasLabel,
  onSeguir,
}: {
  /** Quién paga, para tenerlo delante: nombre tecleado o enmascarado, y cédula. */
  titular: string
  monto: string
  concepto: string
  beneficiario: string
  minimo: number
  maximo: number | null
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

  const lectura = leerMontoDeConsulta(monto, { minimo, maximo }, formatUsd)
  const problemaConcepto =
    concepto.trim().length > TOPE_CONCEPTO ? `El concepto no puede pasar de ${TOPE_CONCEPTO} caracteres.` : null

  function seguir() {
    setIntentado(true)
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

  const rango =
    maximo === null
      ? `Desde ${formatUsd(minimo)}`
      : `Entre ${formatUsd(minimo)} y ${formatUsd(maximo)}`

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
        <Campo
          id="alta-monto"
          label="Monto de la consulta, en dólares"
          value={monto}
          onChange={onMonto}
          onBlur={() => setTocado(true)}
          inputRef={montoRef}
          inputMode="decimal"
          autoComplete="off"
          maxLength={12}
          placeholder="0,00"
          prefijo="$"
          grande
          // Vacío solo se reclama al intentar seguir; lo mal escrito, en
          // cuanto se sale del campo.
          error={
            !lectura.ok && (intentado || (tocado && monto.trim() !== '')) ? lectura.problema : null
          }
          hint={
            lectura.ok
              ? `${formatUsd(lectura.usd)} · lo que cobra la clínica. ${rango}.`
              : `${rango}. Sin el servicio Helios: ese lo paga el paciente en sus cuotas.`
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

      <div className="flex flex-wrap items-center gap-3">
        <BotonConFoco type="submit">
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
