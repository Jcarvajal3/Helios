import { whatsappNumber } from '@/components/ui'
import { claveDePlantilla, mensajeDeCobro, usaLaCuenta } from '@/features/admin/plantillas'
import type { CortesDeTramo } from '@/features/admin/tramos'
import type { CollectionRow } from './cartera'

// ═══════════════════════════════════════════════════════════════════════════
// Si se puede escribir a una persona por WhatsApp, y con qué mensaje.
//
// El chat solo se abre con la plantilla de su tramo ya rellenada: el tramo
// sale de sus días de atraso y de los cortes vigentes (`tramos.ts`), igual
// que el filtro de la cartera. Solo a quien debe algo vencido: los
// recordatorios antes del vencimiento y el del día salen solos. Si falta
// algo —la plantilla no cargó, no hay cuenta de cobro activa— se dice por qué
// y no se abre un chat vacío ni un mensaje con la cuenta en blanco.
// Módulo puro: recibe el estado de cada lectura.
// ═══════════════════════════════════════════════════════════════════════════

/** Una lectura de la base: todavía no, falló, o ya está. */
export type Lectura<T> = { estado: 'cargando' } | { estado: 'error' } | { estado: 'listo'; valor: T }

type Plantilla = { bucket: string; label: string; body: string }
type Cuenta = { isActive: boolean; bankName: string; rif: string; phone: string }

export type WhatsAppDeCobro =
  | { listo: true; href: string; plantilla: string }
  | { listo: false; motivo: string }

function no(motivo: string): WhatsAppDeCobro {
  return { listo: false, motivo }
}

export function whatsAppDeCobro(e: {
  /** La fila de la cartera; `null` si la persona no está en ella. */
  persona: Lectura<CollectionRow | null>
  plantillas: Lectura<ReadonlyArray<Plantilla>>
  cuentas: Lectura<ReadonlyArray<Cuenta>>
  /** La tasa BCV del día; `null` si la base no tiene ninguna. */
  tasa: Lectura<number | null>
  /** Los cortes de los tramos; `null` si falta algún parámetro. */
  cortes: Lectura<CortesDeTramo | null>
}): WhatsAppDeCobro {
  if (e.persona.estado === 'cargando') return no('Cargando la cartera…')
  if (e.persona.estado === 'error') return no('No se pudo leer la cartera.')
  const persona = e.persona.valor
  if (!persona) return no('No tiene cuotas vencidas ni por vencer esta semana.')
  if (persona.daysOverdue <= 0) return no('No tiene nada vencido: sus recordatorios le llegan solos.')

  const numero = whatsappNumber(persona.phone)
  if (!numero) return no('No tiene teléfono.')

  if (e.cortes.estado === 'cargando') return no('Cargando los tramos de atraso…')
  if (e.cortes.estado === 'error') return no('No se pudieron leer los parámetros de los tramos.')
  const cortes = e.cortes.valor
  if (!cortes) return no('Faltan los días de los tramos en Ajustes › Parámetros.')

  if (e.plantillas.estado === 'cargando') return no('Cargando la plantilla…')
  if (e.plantillas.estado === 'error') return no('No se pudieron leer las plantillas.')
  const clave = claveDePlantilla(persona, cortes)
  if (clave === null) return no('No tiene nada vencido: sus recordatorios le llegan solos.')
  const plantilla = e.plantillas.valor.find((p) => p.bucket === clave)
  if (!plantilla) return no('No hay plantilla para este tramo.')

  let cuenta: Cuenta | null = null
  if (usaLaCuenta(plantilla.body)) {
    if (e.cuentas.estado === 'cargando') return no('Cargando la cuenta de cobro…')
    if (e.cuentas.estado === 'error') return no('No se pudo leer la cuenta de cobro.')
    cuenta = e.cuentas.valor.find((c) => c.isActive) ?? null
    if (!cuenta) return no('No hay una cuenta de cobro activa.')
  }

  // Sin tasa el monto en bolívares se escribe con palabras; mientras carga,
  // se espera, que es cosa de un momento.
  if (plantilla.body.includes('{monto_bs}') && e.tasa.estado === 'cargando') {
    return no('Cargando la tasa del día…')
  }
  const tasa = e.tasa.estado === 'listo' ? e.tasa.valor : null

  const texto = mensajeDeCobro(plantilla.body, { persona, tasa, cuenta })
  return {
    listo: true,
    href: `https://wa.me/${numero}?text=${encodeURIComponent(texto)}`,
    plantilla: plantilla.label,
  }
}

/** El estado de una consulta de TanStack Query, como `Lectura`. */
export function lecturaDe<T>(q: { isError: boolean; isPending: boolean; data: T | undefined }): Lectura<T> {
  if (q.isError) return { estado: 'error' }
  if (q.isPending || q.data === undefined) return { estado: 'cargando' }
  return { estado: 'listo', valor: q.data }
}
