/**
 * Pruebas del contacto de Helios y de la configuración incompleta.
 *
 *   npx tsx src/features/admin/contacto/contacto.test.ts
 *
 * Lo que se vigila: que el WhatsApp se guarde en E.164, que un correo mal
 * escrito no se mande, que «no cambiaste nada» no llegue a la base, que cada
 * cosa que falta diga qué pasa y dónde se arregla, y el orden de las cuentas
 * de cobro (varias activas).
 */
import {
  cambioDeContacto,
  faltantesDeConfiguracion,
  leerContacto,
  leerEstadoDeConfiguracion,
  moverCuenta,
  normalizarWhatsApp,
  ordenarCuentas,
  siguienteOrden,
} from './contacto'

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

// ── WhatsApp ───────────────────────────────────────────────────────────────

igual('móvil local', normalizarWhatsApp('0414 123 45 67'), '+584141234567')
igual('con el 58', normalizarWhatsApp('+58 414-1234567'), '+584141234567')
igual('sin el cero', normalizarWhatsApp('4141234567'), '+584141234567')
igual('un fijo de Caracas también', normalizarWhatsApp('0212 555 12 34'), '+582125551234')
igual('corto no', normalizarWhatsApp('0414 12345'), null)
igual('vacío no', normalizarWhatsApp(''), null)

// ── El cambio ──────────────────────────────────────────────────────────────

const actual = leerContacto({
  whatsapp_number: '+584141234567',
  support_email: 'hola@helios.com',
  support_hours: null,
  sender_name: 'Helios',
  sender_email: 'comprobantes@helios.com',
  updated_at: '2026-10-01T10:00:00Z',
  updated_by_name: 'Javier',
})

const igualQueAntes = {
  whatsappNumber: '0414 1234567',
  supportEmail: 'hola@helios.com',
  supportHours: '',
  senderName: 'Helios',
  senderEmail: 'Comprobantes@Helios.com',
}
igual('el mismo número escrito distinto no es un cambio', cambioDeContacto(actual, igualQueAntes), {
  ok: false,
  motivo: 'No has cambiado nada.',
})

const conHorario = cambioDeContacto(actual, { ...igualQueAntes, supportHours: 'L-V 8:00 a 17:00' })
igual('un cambio lista qué cambió', conHorario.ok ? conHorario.cambios : null, ['el horario'])
igual(
  'y manda la fila entera en snake_case',
  conHorario.ok ? conHorario.payload : null,
  {
    whatsapp_number: '+584141234567',
    support_email: 'hola@helios.com',
    support_hours: 'L-V 8:00 a 17:00',
    sender_name: 'Helios',
    sender_email: 'comprobantes@helios.com',
  },
)
igual(
  'un WhatsApp que no es número',
  cambioDeContacto(actual, { ...igualQueAntes, whatsappNumber: '1234' }).ok,
  false,
)
igual(
  'un correo de soporte mal escrito',
  cambioDeContacto(actual, { ...igualQueAntes, supportEmail: 'hola@helios' }),
  { ok: false, motivo: 'Revisa el correo de soporte: no parece un correo.' },
)
igual(
  'remitente sin nombre',
  cambioDeContacto(null, { whatsappNumber: '', supportEmail: '', supportHours: '', senderName: '', senderEmail: 'a@b.com' }).ok,
  false,
)
const vaciar = cambioDeContacto(actual, { ...igualQueAntes, whatsappNumber: '' })
igual('borrar el WhatsApp es un cambio a null', vaciar.ok ? vaciar.payload.whatsapp_number : 'x', null)

// ── Configuración incompleta ───────────────────────────────────────────────

const todo = leerEstadoDeConfiguracion({ whatsapp: true, cuentas_de_cobro: 2, resend: true, remitente: true })
igual('con todo configurado, nada', faltantesDeConfiguracion(todo), [])

const nada = leerEstadoDeConfiguracion({ whatsapp: false, cuentas_de_cobro: '0', resend: 'true', remitente: null })
const faltan = faltantesDeConfiguracion(nada)
igual('lo que falta, por lo que más duele', faltan.map((f) => f.id), ['cuentas', 'whatsapp', 'remitente', 'resend'])
igual('las cuentas se arreglan en Ajustes › Cuentas de cobro', faltan[0]?.arreglo?.destino, {
  to: '/admin/ajustes',
  search: { tab: 'cobro' },
})
igual('el WhatsApp, en Contacto', faltan[1]?.arreglo?.destino, { to: '/admin/ajustes', search: { tab: 'contacto' } })
igual('la clave de Resend no se arregla desde el panel', faltan[3]?.arreglo, null)
igual('un «true» en texto no es verdad', nada.resend, false)
igual('una base que no manda la API no se da por rota', nada.whatsappApi, true)

const sinApi = leerEstadoDeConfiguracion({ whatsapp: true, cuentas_de_cobro: 1, resend: true, remitente: true, whatsapp_api: false, whatsapp_sandbox: true })
igual('sin la API de WhatsApp, avisa (y el sandbox no se suma)', faltantesDeConfiguracion(sinApi).map((f) => f.id), ['whatsapp_api'])
const enSandbox = leerEstadoDeConfiguracion({ whatsapp: true, cuentas_de_cobro: 1, resend: true, remitente: true, whatsapp_api: true, whatsapp_sandbox: true })
igual('en sandbox, avisa', faltantesDeConfiguracion(enSandbox).map((f) => f.id), ['whatsapp_sandbox'])

// ── Cuentas de cobro ───────────────────────────────────────────────────────

const cuentas = [
  { id: 'vieja', isActive: false, sortOrder: 1, createdAt: '2026-09-01' },
  { id: 'zelle', isActive: true, sortOrder: 2, createdAt: '2026-10-02' },
  { id: 'pm', isActive: true, sortOrder: 1, createdAt: '2026-10-03' },
  { id: 'sin-orden', isActive: true, sortOrder: null, createdAt: '2026-10-01' },
  { id: 'otra-vieja', isActive: false, sortOrder: null, createdAt: '2026-09-15' },
]
igual(
  'activas por orden, las retiradas al final',
  ordenarCuentas(cuentas).map((c) => c.id),
  ['pm', 'zelle', 'sin-orden', 'otra-vieja', 'vieja'],
)
igual('la nueva va detrás de la última activa', siguienteOrden(cuentas), 3)
igual('sin activas, la primera', siguienteOrden([]), 1)
igual(
  'subir la segunda intercambia órdenes',
  moverCuenta(cuentas, 'zelle', -1)?.map((m) => [m.cuenta.id, m.sortOrder]),
  [
    ['zelle', 1],
    ['pm', 2],
  ],
)
igual('la primera no sube', moverCuenta(cuentas, 'pm', -1), null)
igual('una retirada no se mueve', moverCuenta(cuentas, 'vieja', 1), null)
const empatadas = [
  { id: 'a', isActive: true, sortOrder: null, createdAt: '2026-10-01' },
  { id: 'b', isActive: true, sortOrder: null, createdAt: '2026-10-02' },
]
igual(
  'sin orden, se numeran por su puesto',
  moverCuenta(empatadas, 'b', -1)?.map((m) => [m.cuenta.id, m.sortOrder]),
  [
    ['b', 1],
    ['a', 2],
  ],
)

if (fallos > 0) {
  console.error(`\n${fallos} ${fallos === 1 ? 'prueba falló' : 'pruebas fallaron'}`)
  process.exit(1)
}
console.log('\nTodo bien.')
