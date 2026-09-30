/**
 * Pruebas de los avisos.
 *
 *   npx tsx src/features/admin/avisos/avisos.test.ts
 *
 * Lo que se vigila: que el enlace de `wa.me` lleve los dígitos con el 58 y el
 * texto codificado (un «&» sin codificar corta el mensaje), que la cola se
 * agrupe en el orden en que le llegan los avisos a un paciente con lo
 * pendiente arriba, que omitir pida nota y que un rebote corregido deje de
 * contar.
 */
import {
  agruparPorPlantilla,
  colaDeTrabajo,
  contarAvisos,
  correoValido,
  enlaceWhatsApp,
  estadoDeCorreo,
  leerAviso,
  motivoParaNoMarcar,
  rebotadosSinCorregir,
  rotuloDePlantilla,
} from './avisos'
import type { Aviso } from './avisos'

let fallos = 0
function igual(nombre: string, obtenido: unknown, esperado: unknown) {
  const ok = JSON.stringify(obtenido) === JSON.stringify(esperado)
  if (!ok) {
    fallos++
    console.error(`✗ ${nombre}\n  esperado: ${JSON.stringify(esperado)}\n  obtenido: ${JSON.stringify(obtenido)}`)
  } else {
    console.log(`✓ ${nombre}`)
  }
}

// ── wa.me ──────────────────────────────────────────────────────────────────

igual(
  'E.164 → dígitos y texto codificado',
  enlaceWhatsApp('+584141234567', 'Hola José, tu cuota de $61,60 vence hoy & mañana'),
  'https://wa.me/584141234567?text=Hola%20Jos%C3%A9%2C%20tu%20cuota%20de%20%2461%2C60%20vence%20hoy%20%26%20ma%C3%B1ana',
)
igual('un móvil local lleva el 58 delante', enlaceWhatsApp('0414-123.45.67', 'x'), 'https://wa.me/584141234567?text=x')
igual('sin teléfono no hay enlace', enlaceWhatsApp(null, 'Hola'), null)
igual('teléfono vacío tampoco', enlaceWhatsApp('  ', 'Hola'), null)
igual('sin texto, el chat a secas', enlaceWhatsApp('+584141234567', '   '), 'https://wa.me/584141234567')
igual('saltos de línea codificados', enlaceWhatsApp('+584241112233', 'a\nb'), 'https://wa.me/584241112233?text=a%0Ab')

// ── Lectura ────────────────────────────────────────────────────────────────

const crudo = {
  id: 'a1',
  channel: 'whatsapp_manual',
  template_key: 'cuota_hoy',
  template_label: null,
  profile_id: 'p1',
  patient_name: 'José Pérez',
  phone_e164: '+584141234567',
  charge_id: 'c1',
  order_number: '1042',
  due_date: '2026-10-08',
  rendered_text: 'Hola José',
  status: 'raro',
  created_at: '2026-10-08T12:00:00Z',
  attempts: null,
}
const leido = leerAviso(crudo)
igual('sin rótulo de la base, el de la lista', leido.templateLabel, 'La cuota vence hoy')
igual('un estado desconocido se lee pendiente', leido.status, 'pendiente')
igual('el número de orden como número', leido.orderNumber, 1042)
igual('sin intentos, cero', leido.attempts, 0)
igual('rótulo de una clave desconocida: la clave', rotuloDePlantilla('otra_cosa'), 'otra_cosa')
igual('el rótulo de la base manda', rotuloDePlantilla('cuota_hoy', 'Hoy vence'), 'Hoy vence')

// ── La cola ────────────────────────────────────────────────────────────────

function aviso(p: Partial<Aviso> & Pick<Aviso, 'id' | 'templateKey'>): Aviso {
  return {
    channel: 'whatsapp_manual',
    templateLabel: rotuloDePlantilla(p.templateKey),
    profileId: null,
    patientName: null,
    phone: null,
    chargeId: null,
    orderNumber: null,
    dueDate: null,
    renderedText: '',
    status: 'pendiente',
    createdAt: '2026-10-08T12:00:00Z',
    sentAt: null,
    sentByName: null,
    email: null,
    providerId: null,
    lastEvent: null,
    attempts: 0,
    ...p,
  }
}

const cola = [
  aviso({ id: 'h2', templateKey: 'cuota_hoy', patientName: 'Zoila', dueDate: '2026-10-08' }),
  aviso({ id: 'b1', templateKey: 'bienvenida', patientName: 'Ana', status: 'enviado' }),
  aviso({ id: 'x1', templateKey: 'plantilla_nueva', patientName: 'Beto' }),
  aviso({ id: 'h1', templateKey: 'cuota_hoy', patientName: 'Ana', dueDate: '2026-10-08', status: 'omitido' }),
  aviso({ id: 'h3', templateKey: 'cuota_hoy', patientName: 'Carla', dueDate: '2026-10-08' }),
  aviso({ id: 'b2', templateKey: 'bienvenida', patientName: 'Luis' }),
  aviso({ id: 'm1', templateKey: 'cuota_manana', patientName: 'Mario', dueDate: '2026-10-09' }),
]
const grupos = agruparPorPlantilla(cola)
igual(
  'los grupos en el orden de las plantillas; lo desconocido al final',
  grupos.map((g) => g.clave),
  ['bienvenida', 'cuota_manana', 'cuota_hoy', 'plantilla_nueva'],
)
igual(
  'dentro del grupo, lo pendiente arriba y por nombre',
  grupos[2]?.avisos.map((a) => a.id),
  ['h3', 'h2', 'h1'],
)
igual('pendientes de cada grupo', grupos.map((g) => g.pendientes), [1, 1, 2, 1])
igual('la cola de trabajo sigue el orden de la lista', colaDeTrabajo(cola).map((a) => a.id), ['b2', 'm1', 'h3', 'h2', 'x1'])
igual('recuento', contarAvisos(cola), { total: 7, pendiente: 5, enviado: 1, omitido: 1, fallido: 0 })
igual('sin avisos, sin grupos', agruparPorPlantilla([]), [])

// ── Marcar ─────────────────────────────────────────────────────────────────

igual('enviado no pide nota', motivoParaNoMarcar('enviado', ''), null)
igual('omitir sin nota no', motivoParaNoMarcar('omitido', '  '), 'Escribe por qué no se manda.')
igual('omitir con nota sí', motivoParaNoMarcar('omitido', 'Número equivocado'), null)
igual('no se vuelve a pendiente', motivoParaNoMarcar('pendiente', 'x') !== null, true)

// ── Correos ────────────────────────────────────────────────────────────────

const correo = (p: Partial<Aviso> & Pick<Aviso, 'id'>) =>
  aviso({ templateKey: 'comprobante_financiamiento', channel: 'email', status: 'enviado', ...p })

igual('rebotado manda sobre el estado', estadoDeCorreo(correo({ id: 'e', lastEvent: 'bounced' })).label, 'Rebotado')
igual('entregado', estadoDeCorreo(correo({ id: 'e', lastEvent: 'delivered' })).tone, 'success')
igual('sin evento y pendiente: en cola', estadoDeCorreo(correo({ id: 'e', status: 'pendiente' })).label, 'En cola')

const correos = [
  correo({ id: 'e1', chargeId: 'c1', lastEvent: 'bounced', createdAt: '2026-10-01T10:00:00Z' }),
  // El mismo financiamiento, reenviado a un correo corregido: resuelto.
  correo({ id: 'e2', chargeId: 'c1', lastEvent: 'delivered', createdAt: '2026-10-02T10:00:00Z' }),
  correo({ id: 'e3', chargeId: 'c2', lastEvent: 'delivered', createdAt: '2026-10-01T10:00:00Z' }),
  // Reenviado y volvió a rebotar: sigue contando, una vez.
  correo({ id: 'e4', chargeId: 'c2', lastEvent: 'complained', createdAt: '2026-10-03T10:00:00Z' }),
  correo({ id: 'e5', chargeId: 'c3', lastEvent: 'bounced', createdAt: '2026-10-04T10:00:00Z' }),
  correo({ id: 'e6', chargeId: null, lastEvent: 'bounced', createdAt: '2026-10-05T10:00:00Z' }),
  aviso({ id: 'w1', templateKey: 'cuota_hoy', chargeId: 'c9', lastEvent: 'bounced' }),
]
igual('rebotados sin corregir, del más nuevo al más viejo', rebotadosSinCorregir(correos).map((c) => c.id), ['e6', 'e5', 'e4'])

igual('correo válido', correoValido(' jose@gmail.com '), true)
igual('sin dominio no', correoValido('jose@gmail'), false)
igual('con espacios no', correoValido('jo se@gmail.com'), false)

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
