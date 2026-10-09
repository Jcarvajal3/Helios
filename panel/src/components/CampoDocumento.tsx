import { DataLabel, Input, Select } from '@/components/ui'
import { NOMBRE_LETRA, componerDocumento, partirDocumento } from '@/lib/documento'
import type { LetraDocumento } from '@/lib/documento'

/**
 * Una cédula, un pasaporte o un RIF: la letra en un selector y el número en
 * un campo que solo admite dígitos (letras y dígitos con P, pasaporte). El
 * valor es siempre la letra pegada al número, `V12345678` (ver
 * `lib/documento.ts`): sin puntos, sin guiones, sin espacios.
 */
export function CampoDocumento({
  id,
  label,
  value,
  onChange,
  letras,
  placeholder,
  error = false,
  className = '',
}: {
  id: string
  label: string
  value: string
  onChange: (valor: string) => void
  letras: ReadonlyArray<LetraDocumento>
  placeholder?: string
  error?: boolean
  className?: string
}) {
  const { letra, numero } = partirDocumento(value, letras)

  return (
    <div className={className}>
      <label htmlFor={id} className="mb-shell-gap-stack block">
        <DataLabel>{label}</DataLabel>
      </label>
      <div className="flex gap-2">
        <div className="w-[4.75rem] shrink-0" title={NOMBRE_LETRA[letra]}>
          <label htmlFor={`${id}-letra`} className="sr-only">
            Tipo de documento
          </label>
          <Select
            id={`${id}-letra`}
            value={letra}
            options={letras.map((l) => ({ value: l, label: l }))}
            onChange={(l) => onChange(componerDocumento(l, numero))}
          />
        </div>
        <Input
          id={id}
          value={numero}
          onChange={(texto) => {
            // Pegar «V-12.345.678» también vale: si trae su letra, se elige.
            const pegado = partirDocumento(texto, letras)
            const conLetra = /^[A-Za-z]/.test(texto.trim()) && pegado.numero !== '' && letra !== 'P'
            onChange(conLetra ? componerDocumento(pegado.letra, pegado.numero) : componerDocumento(letra, texto))
          }}
          inputMode={letra === 'P' ? 'text' : 'numeric'}
          placeholder={letra === 'P' ? 'Número de pasaporte' : (placeholder ?? '12345678')}
          error={error}
          className="min-w-0 flex-1"
        />
      </div>
    </div>
  )
}
