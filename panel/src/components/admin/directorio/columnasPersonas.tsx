import { Ban, MailWarning } from 'lucide-react'

import type { Column } from '@/components/DataTable'
import { EstadoBadge } from '@/components/admin/EstadoBadge'
import {
  Badge,
  Tooltip,
  formatDateTime,
  formatDocument,
  formatUsd,
  formatPhone,
} from '@/components/ui'
import { POR_QUE_NO_PUEDE_GASTAR } from '@/features/admin/directorio/cupo'
import { estadoDePersona } from '@/features/admin/estados'
import { sumandosDeDeuda } from '@/features/admin/directorio/padron'
import type { UserRow } from '@/features/admin/users'
import { csvDinero, csvInstante } from '@/lib/csv'

/**
 * Las columnas de la lista de usuarios.
 *
 * Cada una dice por qué valor se ordena: para saber quién debe más no hay que
 * leer las cien filas. Las que llevan `csv` salen en «Exportar CSV», estén a
 * la vista o no.
 */
export const COLUMNAS_PERSONAS: Array<Column<UserRow>> = [
  {
    key: 'persona',
    header: 'Paciente',
    // La que dice de quién es la fila: se queda pegada al desplazarse a lo
    // ancho y no se puede ocultar.
    identity: true,
    sort: (u) => u.fullName,
    csv: (u) => u.fullName,
    cell: (u) => (
      <>
        <div className="flex items-center gap-2">
          <p className={u.fullName ? 'font-medium text-on-surface' : 'text-on-surface-variant'}>
            {u.fullName ?? 'Sin nombre'}
          </p>
          {u.isBlacklisted && (
            <Tooltip contenido="Tiene marca interna">
              <span tabIndex={0} aria-label="Tiene marca interna" className="inline-flex rounded-full">
                <Ban size={13} aria-hidden className="text-error" />
              </span>
            </Tooltip>
          )}
          {u.emailInvalidAt && (
            <Tooltip contenido="Su correo rebotó: el comprobante no le llegó">
              <span tabIndex={0} aria-label="Correo inválido" className="inline-flex rounded-full">
                <MailWarning size={13} aria-hidden className="text-error" />
              </span>
            </Tooltip>
          )}
          {u.isTest && <Badge tone="neutral">Prueba</Badge>}
        </div>
        <p className="mt-0.5 type-panel-caption tabular-nums text-on-surface-variant">
          {formatPhone(u.phone)}
          {u.document && ` · ${formatDocument(u.document)}`}
        </p>
      </>
    ),
  },

  { key: 'telefono', header: 'Teléfono', hidden: true, csv: (u) => u.phone, cell: (u) => formatPhone(u.phone) },

  {
    key: 'cedula',
    header: 'Cédula',
    hidden: true,
    csv: (u) => u.document,
    cell: (u) => formatDocument(u.document),
  },

  {
    key: 'estado',
    header: 'Estado',
    sort: (u) => estadoDePersona(u.status).label,
    csv: (u) => estadoDePersona(u.status).label,
    cell: (u) => <EstadoBadge tipo="persona" valor={u.status} />,
  },

  {
    key: 'nivel',
    header: 'Nivel',
    info: 'El nivel decide el cupo. Todo paciente nace en el nivel 1 al registrarlo una clínica; los niveles 2 a 4 existen pero están apagados.',
    type: 'number',
    // Más alto primero: la pregunta de esta columna es quién tiene más cupo.
    sortDir: 'desc',
    sort: (u) => u.level,
    csv: (u) => u.level,
    cell: (u) =>
      // «Nivel 0» se leería como un nivel con cupo cero, que es otra cosa.
      u.level === 0 ? (
        <span className="text-on-surface-variant">Sin nivel</span>
      ) : (
        <span className="tabular-nums">{u.level}</span>
      ),
  },

  {
    key: 'disponible',
    header: 'Disponible hoy (sin fee)',
    info: 'Lo que puede financiarse hoy, sin fee: el cupo de su nivel menos lo que ocupan sus financiamientos sin pagar del todo, o cero si tiene una cuota vencida, la cuenta no está activa o hay un bloqueo.',
    type: 'number',
    hidden: true,
    sortDir: 'desc',
    sort: (u) => u.availableNowUsd,
    csv: (u) => (u.level === 0 || u.availableNowUsd === null ? null : csvDinero(u.availableNowUsd)),
    cell: (u) =>
      u.level === 0 || u.availableNowUsd === null ? (
        <span className="text-on-surface-variant">—</span>
      ) : (
        <span className="tabular-nums">
          {formatUsd(u.availableNowUsd)}
          <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
            {u.sinDisponible ? POR_QUE_NO_PUEDE_GASTAR[u.sinDisponible] : `de ${formatUsd(u.levelLimitUsd)}`}
          </span>
        </span>
      ),
  },

  {
    key: 'deuda',
    header: 'Deuda pendiente (financiamiento + fee)',
    info: 'Suma de sus cuotas sin cobrar y no dadas por perdidas (vencidas y por vencer), con el service fee + IVA dentro; debajo, lo financiado (sin fee) y el service fee + IVA; no incluye cargos por atraso.',
    type: 'number',
    sortDir: 'desc',
    sort: (u) => u.openDebtUsd,
    csv: (u) => csvDinero(u.openDebtUsd),
    cell: (u) =>
      u.openDebtUsd > 0 ? (
        <>
          {formatUsd(u.openDebtUsd)}
          {u.openDebtDesglose && (
            <span className="mt-0.5 block whitespace-nowrap type-panel-caption text-on-surface-variant">
              {sumandosDeDeuda(u.openDebtDesglose)}
            </span>
          )}
        </>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },

  {
    key: 'deuda-facturado',
    header: 'Deuda pendiente: financiado (sin fee)',
    hidden: true,
    type: 'number',
    sort: (u) => u.openDebtDesglose?.financedUsd ?? null,
    csv: (u) => (u.openDebtDesglose ? csvDinero(u.openDebtDesglose.financedUsd) : null),
    cell: (u) => (u.openDebtDesglose ? formatUsd(u.openDebtDesglose.financedUsd) : '—'),
  },

  {
    key: 'deuda-fee',
    header: 'Deuda pendiente: service fee + IVA',
    hidden: true,
    type: 'number',
    sort: (u) => u.openDebtDesglose?.feeUsd ?? null,
    csv: (u) => (u.openDebtDesglose ? csvDinero(u.openDebtDesglose.feeUsd) : null),
    cell: (u) => (u.openDebtDesglose ? formatUsd(u.openDebtDesglose.feeUsd) : '—'),
  },

  {
    key: 'vencido',
    header: 'Vencido (financiamiento + fee)',
    info: 'Suma de sus cuotas sin cobrar, no dadas por perdidas y con vencimiento anterior a hoy (día operativo), con el service fee + IVA dentro; debajo, su desglose y los días desde la más antigua.',
    type: 'number',
    sortDir: 'desc',
    sort: (u) => u.overdueUsd,
    csv: (u) => csvDinero(u.overdueUsd),
    cell: (u) =>
      u.overdueUsd > 0 ? (
        <>
          <span className="font-semibold">{formatUsd(u.overdueUsd)}</span>
          {u.overdueDesglose && (
            <span className="mt-0.5 block whitespace-nowrap type-panel-caption font-normal text-on-surface-variant">
              {sumandosDeDeuda(u.overdueDesglose)}
            </span>
          )}
          <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
            {u.daysOverdue} {u.daysOverdue === 1 ? 'día' : 'días'} de atraso
          </span>
        </>
      ) : (
        <span className="text-on-surface-variant">—</span>
      ),
  },

  {
    key: 'vencido-facturado',
    header: 'Vencido: financiado (sin fee)',
    hidden: true,
    type: 'number',
    sort: (u) => u.overdueDesglose?.financedUsd ?? null,
    csv: (u) => (u.overdueDesglose ? csvDinero(u.overdueDesglose.financedUsd) : null),
    cell: (u) => (u.overdueDesglose ? formatUsd(u.overdueDesglose.financedUsd) : '—'),
  },

  {
    key: 'vencido-fee',
    header: 'Vencido: service fee + IVA',
    hidden: true,
    type: 'number',
    sort: (u) => u.overdueDesglose?.feeUsd ?? null,
    csv: (u) => (u.overdueDesglose ? csvDinero(u.overdueDesglose.feeUsd) : null),
    cell: (u) => (u.overdueDesglose ? formatUsd(u.overdueDesglose.feeUsd) : '—'),
  },

  {
    key: 'dias-atraso',
    header: 'Días de atraso',
    info: 'Los días desde el vencimiento de su cuota vencida sin pagar más antigua.',
    hidden: true,
    type: 'number',
    sortDir: 'desc',
    sort: (u) => (u.overdueUsd > 0 ? u.daysOverdue : null),
    csv: (u) => (u.overdueUsd > 0 ? u.daysOverdue : null),
    cell: (u) => (u.overdueUsd > 0 ? u.daysOverdue : '—'),
  },

  {
    key: 'a-tiempo',
    header: 'Cobrado a tiempo (cuotas)',
    info: 'Cuotas cobradas dentro de los días de gracia tras su vencimiento (por el día en que reportó el pago), sobre sus cuotas con ese plazo ya cerrado (las dadas por perdidas cuentan como no cobradas); debajo, en cuántos financiamientos tiene cuota.',
    type: 'number',
    // Por la proporción: 3 de 3 es mejor que 8 de 20. Sin cuotas vencidas no
    // hay proporción, y `null` manda la fila al final en los dos sentidos.
    sort: (u) => (u.onTimeTotal === 0 ? null : u.onTimePaid / u.onTimeTotal),
    csv: (u) => (u.onTimeTotal === 0 ? null : `${u.onTimePaid} de ${u.onTimeTotal}`),
    cell: (u) =>
      // Sin ninguna cuota vencida no hay nada que juzgar: un 0 % sin
      // denominador es una acusación inventada.
      u.onTimeTotal === 0 ? (
        <span className="text-on-surface-variant">—</span>
      ) : (
        <>
          <span className="text-on-surface">
            {u.onTimePaid} de {u.onTimeTotal} cuotas
          </span>
          <span className="mt-0.5 block type-panel-caption font-normal text-on-surface-variant">
            {u.chargeCount} {u.chargeCount === 1 ? 'financiamiento' : 'financiamientos'}
          </span>
        </>
      ),
  },

  {
    key: 'registro',
    header: 'Registrado',
    info: 'Cuándo lo registró una clínica por primera vez: el paciente nace con su primer financiamiento.',
    sortDir: 'desc',
    sort: (u) => u.createdAt,
    csv: (u) => csvInstante(u.createdAt),
    cell: (u) => (
      <span className="block whitespace-nowrap type-panel-caption text-on-surface-variant">
        {formatDateTime(u.createdAt)}
      </span>
    ),
  },

  {
    key: 'ultimo',
    header: 'Último financiamiento',
    info: 'Su último financiamiento confirmado, y su clínica.',
    hidden: true,
    sortDir: 'desc',
    sort: (u) => u.lastChargeAt,
    csv: (u) => csvInstante(u.lastChargeAt),
    cell: (u) => (
      <span className="block whitespace-nowrap type-panel-caption text-on-surface-variant">
        {formatDateTime(u.lastChargeAt)}
        {u.lastMerchantName && (
          <span className="mt-0.5 block text-on-surface">{u.lastMerchantName}</span>
        )}
      </span>
    ),
  },

  {
    key: 'clinica-registro',
    header: 'Clínica de registro',
    info: 'La clínica que lo registró por primera vez. Si luego financió en otra, esa sale en «Último financiamiento».',
    sort: (u) => u.registeredMerchantName ?? null,
    csv: (u) => u.registeredMerchantName ?? null,
    cell: (u) => u.registeredMerchantName ?? <span className="text-on-surface-variant">—</span>,
  },

  {
    key: 'correo-invalido',
    header: 'Correo inválido',
    info: 'Su correo rebotó: el comprobante no le llegó y hay que corregirlo en su ficha.',
    hidden: true,
    sort: (u) => (u.emailInvalidAt ? 1 : 0),
    csv: (u) => (u.emailInvalidAt ? csvInstante(u.emailInvalidAt) : null),
    cell: (u) =>
      u.emailInvalidAt ? (
        <Badge tone="error" icono>
          Rebotó el {formatDateTime(u.emailInvalidAt)}
        </Badge>
      ) : (
        '—'
      ),
  },

  {
    key: 'ultimo-local',
    header: 'Clínica del último financiamiento',
    hidden: true,
    sort: (u) => u.lastMerchantName,
    csv: (u) => u.lastMerchantName,
    cell: (u) => u.lastMerchantName ?? '—',
  },

  {
    key: 'prueba',
    header: 'Cuenta de prueba',
    info: 'Sale en la lista con su etiqueta, pero sus cifras no cuentan: la deuda, lo vencido, los financiamientos y el cobrado a tiempo salen vacíos.',
    hidden: true,
    sort: (u) => (u.isTest ? 1 : 0),
    csv: (u) => (u.isTest ? 'Sí' : null),
    cell: (u) => (u.isTest ? 'Sí' : '—'),
  },
]
