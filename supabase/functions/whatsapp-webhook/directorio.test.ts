/**
 * Pruebas de quien escribe desde el directorio, con una base de mentira:
 * cada RPC responde lo que diga la prueba y se anota.
 *
 *   npx tsx supabase/functions/whatsapp-webhook/directorio.test.ts
 */
import { atenderAlInteresado } from './directorio.ts'
import type { EventoDeMensaje } from './logica.ts'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

type Llamada = { fn: string; args: Record<string, unknown> }

/** Lo que no se dice hacia fuera (CLAUDE.md, «Nombres»). */
const PROHIBIDO = /pr[eé]stamo|financiamiento|financiar|cr[eé]dito|\bfee\b/i

const TARJETA = {
  ok: true,
  nuevo: true,
  lead_id: 'lead-1',
  merchant_id: 'm-1',
  name: 'Dra. Ana Pérez',
  specialty: 'Odontología',
  address: 'Av. Francisco de Miranda',
  city: 'Caracas',
  whatsapp: '+584141234567',
}

/** Corre la ruta con lo que devuelva `bot_directorio_interesado`. */
async function correr(interesado: unknown) {
  const llamadas: Llamada[] = []
  const rpc = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    llamadas.push({ fn, args })
    if (fn === 'bot_directorio_interesado') return interesado as T
    return null as T
  }
  const m: EventoDeMensaje = {
    kind: 'message',
    id: 'wamid.DIR',
    from: '584120009999',
    type: 'text',
    texto: 'Hola, quiero agendar una consulta con la Dra. Ana Pérez. (Código DIR-7K2P)',
    boton: null,
    adjunto: null,
    raw: {},
  }
  const res = await atenderAlInteresado({ rpc, mensaje: m, codigo: 'DIR-7K2P' })
  const envios = llamadas.filter((l) => l.fn === 'helios_whatsapp_patient_text').map((l) => l.args)
  return { res, llamadas, envios, fns: llamadas.map((l) => l.fn) }
}

async function main() {
  console.log('Una tarjeta publicada')
  {
    const r = await correr(TARJETA)
    comprueba(
      JSON.stringify(r.fns) === JSON.stringify(['bot_directorio_interesado', 'helios_whatsapp_patient_text']),
      'guarda al interesado y le contesta, en ese orden',
      JSON.stringify(r.fns),
    )
    const a = r.llamadas[0].args
    comprueba(
      a.p_phone === '584120009999' && a.p_code === 'DIR-7K2P' && a.p_message_id === 'wamid.DIR',
      'bot_directorio_interesado con el teléfono, el código y el wamid',
      JSON.stringify(a),
    )
    const e = r.envios[0]
    comprueba(e?.p_to === '584120009999' && e?.p_profile_id === null, 'le contesta a quien escribió, sin perfil', JSON.stringify(e))
    comprueba(Array.isArray(e?.p_buttons) && (e?.p_buttons as unknown[]).length === 0, 'sin botones')
    const t = String(e?.p_text)
    comprueba(t.includes('*Dra. Ana Pérez*') && t.includes('https://wa.me/584141234567?text='), 'con el contacto del médico', t)
    comprueba(!PROHIBIDO.test(t), 'sin vocabulario prohibido')
    comprueba(
      JSON.stringify(r.res) ===
        JSON.stringify({ accion: 'directorio', codigo: 'DIR-7K2P', ok: true, nuevo: true, lead_id: 'lead-1', merchant_id: 'm-1' }),
      'el resultado para helios_whatsapp_inbound_done',
      JSON.stringify(r.res),
    )
  }
  {
    const r = await correr({ ...TARJETA, nuevo: false, specialty: null, address: null, city: null })
    comprueba(r.res.nuevo === false, 'un interesado que vuelve a escribir: nuevo = false')
    comprueba(!String(r.envios[0]?.p_text).includes('📍'), 'sin dirección, no la inventa')
  }

  console.log('\nUna tarjeta que ya no sale')
  for (const motivo of ['no_publicado', 'codigo_desconocido']) {
    const r = await correr({ ok: false, motivo })
    comprueba(r.envios.length === 1, `${motivo}: le contesta una vez`)
    const t = String(r.envios[0]?.p_text)
    comprueba(t.includes('ya no está en nuestro directorio') && t.includes('https://conhelios.com/directorio'), `${motivo}: el enlace al directorio`, t)
    comprueba(!t.includes('wa.me'), `${motivo}: sin contacto de nadie`)
    comprueba(!PROHIBIDO.test(t), `${motivo}: sin vocabulario prohibido`)
    comprueba(
      JSON.stringify(r.res) === JSON.stringify({ accion: 'directorio', codigo: 'DIR-7K2P', ok: false, motivo }),
      `${motivo}: el resultado`,
      JSON.stringify(r.res),
    )
  }

  console.log(fallos === 0 ? '\nTODO BIEN' : `\n${fallos} FALLOS`)
  process.exit(fallos === 0 ? 0 : 1)
}

main()
