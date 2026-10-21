import { Contact, MessageCircle } from 'lucide-react'

import type { Entrada } from './tipos'

/**
 * Seguimiento: el contacto del equipo con los médicos y su personal. A quién
 * llamar, con qué número, qué se habló la última vez y quién usa más Helios;
 * y el inbox de WhatsApp, donde se les contesta.
 */
export const seguimiento = [
  // ── Pantallas ────────────────────────────────────────────────────────────
  {
    tipo: 'pantalla',
    id: 'seguimiento',
    titulo: 'Seguimiento',
    descripcion:
      'Cada clínica con su médico, su teléfono, todo su personal con su número y sus órdenes, y el último contacto del equipo: a quién llamar hoy y qué se habló.',
    espacio: 'seguimiento',
    sinonimos: [
      'seguimiento',
      'contacto con clínicas',
      'llamar al médico',
      'llamar a la secretaria',
      'teléfono del médico',
      'feedback',
      'opinión',
      'quién más órdenes crea',
      'quién más usa helios',
      'personal de las clínicas',
      'cuentas de las clínicas',
      'crm',
    ],
    destino: { to: '/admin/seguimiento' },
    icono: Contact,
  },
  {
    tipo: 'pantalla',
    id: 'whatsapp',
    titulo: 'WhatsApp',
    descripcion:
      'El inbox del número de Helios: leer lo que escriben pacientes y médicos y contestarles, desde el Inbox de 360dialog.',
    espacio: 'seguimiento',
    sinonimos: [
      'inbox',
      'bandeja de entrada',
      'chats',
      'conversaciones',
      'mensajes recibidos',
      'contestar',
      'responder',
      '360dialog',
    ],
    destino: { to: '/admin/whatsapp' },
    icono: MessageCircle,
  },

  // ── Acciones ─────────────────────────────────────────────────────────────
  {
    tipo: 'accion',
    id: 'anotar-contacto-clinica',
    titulo: 'Anotar un contacto con una clínica',
    descripcion:
      'Dejar constancia de una llamada, un mensaje o una visita a un médico o su secretaria: de qué se habló y cuándo volver a llamar. Queda en la bitácora.',
    espacio: 'seguimiento',
    sinonimos: ['llamada a la clínica', 'pedir feedback', 'pedir opinión', 'volver a llamar', 'nota de la clínica'],
    destino: { to: '/admin/seguimiento' },
  },
  {
    tipo: 'accion',
    id: 'quien-mas-ordenes',
    titulo: 'Ver quién registra más órdenes',
    descripcion: 'Todo el personal de todas las clínicas, quien más pagos en cuotas registró primero, con su número.',
    espacio: 'seguimiento',
    sinonimos: ['ranking de secretarias', 'quién más vende', 'usuarios más activos', 'top usuarios'],
    destino: { to: '/admin/seguimiento', search: { vista: 'personas' } },
  },
] as const satisfies ReadonlyArray<Entrada>
