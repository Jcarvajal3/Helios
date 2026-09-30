import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Search } from 'lucide-react'

import {
  Badge,
  ErrorBox,
  Input,
  SectionTitle,
  SkeletonList,
  formatDocument,
  formatUsd,
  formatPhone,
} from '@/components/ui'
import type { UnmatchedDeposit } from '@/features/admin/deposits'
import { matchesPayer, payerDocument, readPayerHint } from '@/features/admin/payer'
import { fetchUsers } from '@/features/admin/users'
import type { UserRow } from '@/features/admin/users'
import { describeError } from '@/lib/supabase'

/**
 * El primer paso de asignar un abono: de quién es.
 *
 * Arranca con la búsqueda hecha: el banco escribe en la descripción la cédula
 * o el teléfono de quien pagó (`payer.ts`), y copiarlos a mano era el paso que
 * sobraba. Quien coincide con esos datos lleva la marca «Es quien pagó».
 */
export function QuienPagoElAbono({
  deposit,
  onElegir,
}: {
  deposit: UnmatchedDeposit
  onElegir: (persona: UserRow) => void
}) {
  const pagador = readPayerHint(deposit.description)
  const pagadorDocumento = pagador?.document ?? null
  const pagadorTelefono = pagador?.phone ?? null

  const [texto, setTexto] = useState(pagadorDocumento ?? pagadorTelefono ?? '')
  const buscable = texto.trim().length >= 2

  const busqueda = useQuery({
    queryKey: ['admin-users', texto, ''],
    queryFn: () => fetchUsers({ search: texto, limit: 8 }),
    enabled: buscable,
  })

  return (
    <div className="flex flex-col gap-3">
      <SectionTitle>¿De quién es?</SectionTitle>

      {pagador && (
        <div className="rounded-panel-control bg-panel-raised p-3">
          <p className="type-panel-caption text-on-surface-variant">
            Según el banco, el pago salió de
          </p>
          <div className="mt-2 flex flex-wrap items-baseline gap-x-3 gap-y-1">
            {pagadorDocumento !== null && (
              <button
                type="button"
                onClick={() => setTexto(pagadorDocumento)}
                className="type-panel-body font-semibold text-on-surface underline decoration-panel-muted underline-offset-2 hover:decoration-on-surface"
              >
                {formatDocument(payerDocument(pagador))}
              </button>
            )}
            {pagadorTelefono !== null && (
              <button
                type="button"
                onClick={() => setTexto(pagadorTelefono)}
                className="type-panel-body text-on-surface underline decoration-panel-muted underline-offset-2 hover:decoration-on-surface"
              >
                {formatPhone(pagadorTelefono)}
              </button>
            )}
            {pagador.bankName !== null && (
              <span className="type-panel-caption text-on-surface-variant">
                desde {pagador.bankName}
              </span>
            )}
          </div>
        </div>
      )}

      <Input
        id="buscar-dueno"
        value={texto}
        onChange={setTexto}
        placeholder="Teléfono, nombre o cédula"
        autoFocus
      />

      {buscable && busqueda.isPending && <SkeletonList rows={2} />}

      {busqueda.isError && (
        <ErrorBox title="No se pudo buscar" detail={describeError(busqueda.error)} />
      )}

      {busqueda.data?.length === 0 && (
        <p className="type-panel-body text-on-surface-variant">
          {texto === pagadorDocumento || texto === pagadorTelefono
            ? // Que no haya nadie no es un fallo de la búsqueda: es la
              // respuesta. Quien transfirió no tiene cuenta.
              'Ningún paciente tiene esos datos: seguramente pagó en nombre de un paciente. Búscalo por su nombre.'
            : 'Nadie coincide. Prueba con el teléfono completo o con la cédula sin puntos.'}
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
              <span className="block type-panel-body text-on-surface">
                {u.fullName ?? 'Sin nombre'}
                {/* La cédula o el teléfono son los mismos que mandó el banco:
                    no es que el nombre se parezca, es esta persona. */}
                {matchesPayer(pagador, { document: u.document, phone: u.phone }) && (
                  <Badge tone="success" icono className="ml-2">
                    Es quien pagó
                  </Badge>
                )}
                {u.isTest && (
                  <Badge tone="neutral" className="ml-2">
                    Prueba
                  </Badge>
                )}
              </span>
              <span className="block type-panel-caption text-on-surface-variant">
                {formatPhone(u.phone)} · debe {formatUsd(u.openDebtUsd)} con fee
                {u.openDebtDesglose &&
                  ` (financiado ${formatUsd(u.openDebtDesglose.financedUsd)} + service fee + IVA ${formatUsd(u.openDebtDesglose.feeUsd)})`}
              </span>
            </span>
            <Search size={14} className="shrink-0 text-on-surface-variant" aria-hidden />
          </button>
        ))}
      </div>
    </div>
  )
}
