import type { LucideIcon } from 'lucide-react'

import {
  SOLO_SUPER_ADMIN,
  formatDateTime,
  formatDay,
  formatDocument,
  formatUsd,
  formatPhone,
  formatVes,
} from '@/components/ui'
import type { BadgeTone } from '@/components/ui'
import { CATALOGO, PANTALLAS } from '@/features/admin/catalogo'
import type { Destino, Entrada } from '@/features/admin/catalogo'
import { estadoDe } from '@/features/admin/estados'
import type { MerchantRow } from '@/features/admin/api'
import type { ChargeRow } from '@/features/admin/ops'
import type { UserRow } from '@/features/admin/users'
import { enElGrupo } from './consulta'
import type { IdGrupo } from './consulta'
import type { PagoEncontrado } from './fuentes'
import type { ClaseEntidad, Reciente } from './recientes'

// ═══════════════════════════════════════════════════════════════════════════
// Cada resultado de la paleta como una `Opcion`: qué se pinta y qué pasa al
// elegirlo.
//
// Sin React, para poder probarlo: que una acción del super admin salga
// apagada con su motivo, que un consumo no enseñe un monto con el service fee
// dentro, que lo guardado en Recientes no arrastre cifras que caducan.
// ═══════════════════════════════════════════════════════════════════════════

/** Adónde lleva una opción: una pantalla del catálogo o la ficha de algo. */
export type Destinatario = { clase: 'ruta'; destino: Destino } | { clase: ClaseEntidad; id: string }

/** Lo que pasa al elegir una opción. */
export type Efecto =
  | { tipo: 'abrir'; destinatario: Destinatario; reciente: Reciente }
  /** Un término: la definición se despliega en la misma ventana. */
  | { tipo: 'desplegar'; definicion: string; reciente: Reciente }
  /** La línea de un grupo que falló: elegirla vuelve a preguntar. */
  | { tipo: 'reintentar'; grupo: IdGrupo }
  /** Se ve pero no se puede usar, y el motivo va escrito. */
  | { tipo: 'apagada'; motivo: string }
  /** Lleva lo tecleado al asistente, como pregunta. */
  | { tipo: 'preguntar'; texto: string }

export type Insignia = { texto: string; tono: BadgeTone }

export type Opcion = {
  /** Única en toda la lista: `grupo:id`. */
  clave: string
  /** Qué es. Decide el icono cuando no trae uno propio. */
  clase: Entrada['tipo'] | ClaseEntidad | 'fallo' | 'asistente'
  /** El icono de una pantalla del catálogo. */
  icono?: LucideIcon
  titulo: string
  detalle?: string
  /** Una frase larga en su propia línea: el `que` de una cifra. */
  nota?: string
  insignias: ReadonlyArray<Insignia>
  efecto: Efecto
}

const PRUEBA: Insignia = { texto: 'Prueba', tono: 'neutral' }

/** Las partes que existen, unidas con « · ». */
function unir(partes: ReadonlyArray<string | null | undefined>): string {
  return partes.filter((p): p is string => !!p && p !== '—').join(' · ')
}

function abrirFicha(clase: ClaseEntidad, id: string, titulo: string, detalle: string): Efecto {
  return {
    tipo: 'abrir',
    destinatario: { clase, id },
    reciente: { tipo: clase, id, titulo, detalle },
  }
}

// ── Del catálogo ───────────────────────────────────────────────────────────

/** «En Dinero»: la pantalla donde vive una cifra, que es adonde lleva. */
function dondeVive(e: Entrada): string {
  const suya = PANTALLAS.find((p) => p.destino.to === e.destino.to)
  return suya ? `En ${suya.titulo}` : e.descripcion
}

export function opcionDeEntrada(e: Entrada, grupo: IdGrupo, esSuperAdmin: boolean): Opcion {
  const clave = `${grupo}:${e.id}`
  const reciente: Reciente = { tipo: 'catalogo', id: e.id }
  const abrir: Efecto = { tipo: 'abrir', destinatario: { clase: 'ruta', destino: e.destino }, reciente }

  switch (e.tipo) {
    case 'pantalla':
      return { clave, clase: e.tipo, icono: e.icono, titulo: e.titulo, detalle: e.descripcion, insignias: [], efecto: abrir }
    case 'accion': {
      const apagada = e.soloSuperAdmin === true && !esSuperAdmin
      return {
        clave,
        clase: e.tipo,
        titulo: e.titulo,
        detalle: e.descripcion,
        insignias: [],
        efecto: apagada ? { tipo: 'apagada', motivo: SOLO_SUPER_ADMIN } : abrir,
      }
    }
    case 'cifra':
      return { clave, clase: e.tipo, titulo: e.titulo, detalle: dondeVive(e), nota: e.que, insignias: [], efecto: abrir }
    case 'termino':
      return {
        clave,
        clase: e.tipo,
        titulo: e.titulo,
        detalle: e.descripcion,
        insignias: [],
        efecto: { tipo: 'desplegar', definicion: e.definicion, reciente },
      }
  }
}

// ── De las fuentes ─────────────────────────────────────────────────────────

export type PersonaDePaleta = Pick<
  UserRow,
  'userId' | 'fullName' | 'phone' | 'document' | 'status' | 'isTest' | 'overdueUsd'
>

/**
 * Una persona. Lo vencido es deuda, y va rotulado como tal: es lo que se le
 * reclama, no un consumo.
 */
export function opcionDePersona(p: PersonaDePaleta): Opcion {
  const titulo = p.fullName ?? 'Paciente sin nombre'
  const identidad = unir([p.phone && formatPhone(p.phone), p.document && formatDocument(p.document)])
  const estado = estadoDe('persona', p.status)
  return {
    clave: `personas:${p.userId}`,
    clase: 'persona',
    titulo,
    detalle: unir([identidad, p.overdueUsd > 0 ? `Deuda vencida ${formatUsd(p.overdueUsd)}` : null]),
    insignias: [{ texto: estado.label, tono: estado.tone }, ...(p.isTest ? [PRUEBA] : [])],
    // En Recientes, sin la deuda: cambia cada día y se leería como de hoy.
    efecto: abrirFicha('persona', p.userId, titulo, identidad),
  }
}

export type LocalDePaleta = Pick<MerchantRow, 'id' | 'name' | 'taxId' | 'city' | 'status' | 'isTest'>

/** Un local. Activo es lo normal y no lleva insignia; los demás estados, sí. */
export function opcionDeLocal(m: LocalDePaleta): Opcion {
  const detalle = unir([m.taxId, m.city])
  const estado = estadoDe('local', m.status)
  return {
    clave: `locales:${m.id}`,
    clase: 'local',
    titulo: m.name,
    detalle,
    insignias: [
      ...(m.status === 'active' ? [] : [{ texto: estado.label, tono: estado.tone }]),
      ...(m.isTest ? [PRUEBA] : []),
    ],
    efecto: abrirFicha('local', m.id, m.name, detalle),
  }
}

export type ConsumoDePaleta = Pick<
  ChargeRow,
  | 'chargeId'
  | 'orderNumber'
  | 'merchantName'
  | 'fullName'
  | 'businessDate'
  | 'status'
  | 'isTest'
  | 'financedUsd'
>

/**
 * Un consumo, con su monto sin el service fee (`financed_usd`): lo
 * consumido en el local. `amount_usd` lleva el fee dentro y no se enseña; el desglose
 * está en la ficha.
 */
export function opcionDeConsumo(c: ConsumoDePaleta): Opcion {
  const titulo = `Orden #${c.orderNumber ?? '—'}`
  const detalle = unir([
    c.merchantName,
    c.fullName ?? 'Sin paciente asociado',
    formatUsd(c.financedUsd),
    c.businessDate ? formatDay(c.businessDate) : null,
  ])
  const estado = estadoDe('consumo', c.status)
  return {
    clave: `consumos:${c.chargeId}`,
    clase: 'consumo',
    titulo,
    detalle,
    insignias: [
      { texto: estado.label, tono: estado.tone },
      ...(c.isTest ? [PRUEBA] : []),
    ],
    efecto: abrirFicha('consumo', c.chargeId, titulo, detalle),
  }
}

/**
 * Un pago reportado. El monto va en bolívares: es lo que se transfirió y lo
 * que se coteja contra el extracto del banco, junto a la referencia.
 */
export function opcionDePago(p: PagoEncontrado): Opcion {
  const titulo = `Ref. ${p.reference ?? '—'}`
  const detalle = unir([
    p.fullName ?? 'Paciente sin nombre',
    p.bank,
    p.amountVes === null ? null : formatVes(p.amountVes),
    formatDateTime(p.createdAt),
  ])
  const estado = estadoDe('pago', p.status)
  return {
    clave: `pagos:${p.reportId}`,
    clase: 'pago',
    titulo,
    detalle,
    insignias: [{ texto: estado.label, tono: estado.tone }, ...(p.isTest ? [PRUEBA] : [])],
    efecto: abrirFicha('pago', p.reportId, titulo, detalle),
  }
}

/** Lo que dice un grupo que falló. Elegirla vuelve a preguntar. */
export function opcionReintentar(grupo: IdGrupo): Opcion {
  return {
    clave: `${grupo}:reintentar`,
    clase: 'fallo',
    titulo: `No se pudo buscar en ${enElGrupo(grupo)}`,
    detalle: 'Pulsa Enter o haz clic para volver a intentarlo.',
    insignias: [],
    efecto: { tipo: 'reintentar', grupo },
  }
}

/**
 * «Preguntarle al asistente: «…»». No busca nada: abre el asistente con lo
 * tecleado como pregunta, y el asistente lee las cifras de la base.
 */
export function opcionPreguntar(texto: string): Opcion {
  return {
    clave: 'asistente:preguntar',
    clase: 'asistente',
    titulo: `Preguntarle al asistente: «${texto}»`,
    detalle: 'Contesta con las cifras de la base y enlaza la pantalla donde se ven.',
    insignias: [],
    efecto: { tipo: 'preguntar', texto },
  }
}

/** Una entrada de Recientes, o `null` si lo que apuntaba ya no existe. */
export function opcionDeReciente(r: Reciente, esSuperAdmin: boolean): Opcion | null {
  if (r.tipo === 'catalogo') {
    const entrada = CATALOGO.find((e) => e.id === r.id)
    return entrada ? opcionDeEntrada(entrada, 'recientes', esSuperAdmin) : null
  }
  return {
    clave: `recientes:${r.tipo}:${r.id}`,
    clase: r.tipo,
    titulo: r.titulo,
    detalle: r.detalle || undefined,
    insignias: [],
    efecto: abrirFicha(r.tipo, r.id, r.titulo, r.detalle),
  }
}
