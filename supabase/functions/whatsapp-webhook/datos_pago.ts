// ═══════════════════════════════════════════════════════════════════════════
// Helios — Los datos de un Pago Móvil escritos por el paciente, sin captura
// (docs/03 §4.5; decisiones de Javier del 2026-10-21, D8 y D9)
//
// Banco, teléfono desde el que pagó y referencia completa. Sin monto: lo pone
// el aviso del BNC que encaje (`helios_receipt_pair`). Se leen sin IA, como
// el formulario del médico (datos.ts): con etiquetas, «Banco: Banesco», o sin
// ellas, una respuesta por línea; sin etiquetas cada línea se reconoce por lo
// que es (un móvil, un banco de la lista, un número largo), no por su orden.
//
// Módulo puro: lo prueba `datos_pago.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

import { normalizar } from './logica.ts'

export type Campo = 'banco' | 'telefono' | 'referencia'

export type DatosDePago = { banco?: string; telefono?: string; referencia?: string }

export const CAMPOS: Array<[Campo, string]> = [
  ['banco', 'Banco desde el que pagaste'],
  ['telefono', 'Teléfono desde el que pagaste'],
  ['referencia', 'Referencia completa'],
]

/** El formulario con las líneas de los campos pedidos (todos, por defecto). */
export function formularioDePago(campos: Campo[] = CAMPOS.map(([c]) => c)): string {
  return CAMPOS.filter(([c]) => campos.includes(c)).map(([, e]) => `${e}:`).join('\n')
}

/** Bancos con Pago Móvil y su código (la lista de panel/src/features/admin/banks.ts). */
const BANCOS: ReadonlyArray<{ code: string; name: string; claves: string[] }> = [
  { code: '0102', name: 'Banco de Venezuela', claves: ['banco de venezuela', 'bdv'] },
  { code: '0104', name: 'Venezolano de Crédito', claves: ['venezolano de credito', 'venezolano'] },
  { code: '0105', name: 'Mercantil', claves: ['mercantil'] },
  { code: '0108', name: 'Provincial', claves: ['provincial', 'bbva'] },
  { code: '0114', name: 'Bancaribe', claves: ['bancaribe'] },
  { code: '0115', name: 'Exterior', claves: ['exterior'] },
  { code: '0128', name: 'Banco Caroní', claves: ['caroni'] },
  { code: '0134', name: 'Banesco', claves: ['banesco'] },
  { code: '0138', name: 'Banco Plaza', claves: ['plaza'] },
  { code: '0151', name: 'BFC Banco Fondo Común', claves: ['bfc', 'fondo comun'] },
  { code: '0156', name: '100% Banco', claves: ['100 banco', '100% banco'] },
  { code: '0163', name: 'Banco del Tesoro', claves: ['tesoro'] },
  { code: '0166', name: 'Banco Agrícola de Venezuela', claves: ['agricola'] },
  { code: '0168', name: 'Bancrecer', claves: ['bancrecer'] },
  { code: '0169', name: 'Mi Banco', claves: ['mi banco'] },
  { code: '0171', name: 'Banco Activo', claves: ['activo'] },
  { code: '0172', name: 'Bancamiga', claves: ['bancamiga'] },
  { code: '0174', name: 'Banplus', claves: ['banplus'] },
  { code: '0175', name: 'Banco Bicentenario', claves: ['bicentenario'] },
  { code: '0177', name: 'Banfanb', claves: ['banfanb'] },
  { code: '0191', name: 'BNC Banco Nacional de Crédito', claves: ['bnc', 'nacional de credito'] },
]

/** Un banco de la lista por su código o su nombre («banesco», «0134», «BNC»), o null. */
export function leerBanco(v: string): string | null {
  const t = v.trim()
  const codigo = /^(01\d{2})\b/.exec(t)?.[1]
  if (codigo) return BANCOS.find((b) => b.code === codigo)?.name ?? null
  const n = ` ${normalizar(t)} `
  return BANCOS.find((b) => b.claves.some((c) => n.includes(` ${normalizar(c)} `)))?.name ?? null
}

/** Un móvil venezolano (0414-123.45.67, +58 414 1234567) como 04141234567, o null. */
export function leerMovil(v: string): string | null {
  const d = v.replace(/\D/g, '').replace(/^58(?=4\d{9}$)/, '0')
  return /^04(12|14|16|22|24|26)\d{7}$/.test(d) ? d : null
}

/** La referencia completa: de 8 a 20 cifras, con lo que la separe; o null. */
export function leerReferenciaCompleta(v: string): string | null {
  if (/[a-z]{3,}/i.test(v.replace(/^\s*(ref(erencia)?|nro|n[uú]mero)\.?:?/i, ''))) return null
  const d = v.replace(/\D/g, '')
  return d.length >= 8 && d.length <= 20 ? d : null
}

function campoDeLaEtiqueta(etiqueta: string): Campo | null {
  const e = normalizar(etiqueta)
  if (e.includes('banco')) return 'banco'
  if (e.includes('telefono') || e.startsWith('tel') || e.includes('celular') || e.includes('movil')) return 'telefono'
  if (e.includes('referencia') || e.startsWith('ref') || e.includes('numero de operacion')) return 'referencia'
  return null
}

/**
 * Lo que trae un mensaje. Con etiquetas, cada línea a su campo; sin ellas,
 * cada línea por lo que parece. Un valor que no se entiende no se guarda (y
 * el bot lo vuelve a pedir).
 */
export function leerDatosDePago(t: string): DatosDePago {
  const d: DatosDePago = {}
  const lineas = t.split(/\r?\n/).map((l) => l.replace(/^\s*[-*•·]\s+/, '').trim()).filter((l) => l !== '')

  for (const linea of lineas) {
    const i = linea.indexOf(':')
    const campo = i > 0 ? campoDeLaEtiqueta(linea.slice(0, i)) : null
    if (campo) {
      const leido = LECTORES[campo](linea.slice(i + 1).trim())
      if (leido) d[campo] = leido
      continue
    }

    // Sin etiqueta, por lo que parece. El móvil primero: con sus 11 cifras
    // también pasaría por una referencia.
    const movil = leerMovil(linea)
    if (movil && !d.telefono) {
      d.telefono = movil
      continue
    }
    const banco = leerBanco(linea)
    if (banco && !d.banco) {
      d.banco = banco
      continue
    }
    const referencia = leerReferenciaCompleta(linea)
    if (referencia && !d.referencia) d.referencia = referencia
  }
  return d
}

const LECTORES: Record<Campo, (v: string) => string | null> = {
  banco: leerBanco,
  telefono: leerMovil,
  referencia: leerReferenciaCompleta,
}

/** Lo nuevo sobre lo que ya había. */
export function juntarDatosDePago(antes: DatosDePago, nuevo: DatosDePago): DatosDePago {
  return { ...antes, ...Object.fromEntries(Object.entries(nuevo).filter(([, v]) => v)) }
}

export function faltanDatosDePago(d: DatosDePago): Campo[] {
  return CAMPOS.map(([c]) => c).filter((c) => !d[c])
}

/** «el banco», «el teléfono y la referencia». */
export function nombrarCampos(campos: Campo[]): string {
  const nombres: Record<Campo, string> = {
    banco: 'el banco desde el que pagaste',
    telefono: 'el teléfono desde el que pagaste',
    referencia: 'la referencia completa',
  }
  const n = campos.map((c) => nombres[c])
  return n.length <= 1 ? (n[0] ?? '') : `${n.slice(0, -1).join(', ')} y ${n[n.length - 1]}`
}

/** «datos», «no tengo captura»: el paciente quiere escribir los datos en vez de mandar la foto. */
export function quiereEscribirLosDatos(t: string): boolean {
  const n = normalizar(t)
  return (
    n === 'datos' ||
    n === 'escribir datos' ||
    n === 'enviar datos' ||
    n === 'datos del pago' ||
    /^no tengo (la |el )?(captura|capture|comprobante|foto|screenshot)/.test(n)
  )
}
