import { createFileRoute } from '@tanstack/react-router'

import { CALENDARIO_DE_COBRO, GUIAS, TABLA_DE_CUOTAS } from '@/components/portada/guias'
import {
  COMISION_PCT,
  IVA_PCT,
  LIMITE,
  PREGUNTAS,
  cuota,
  dinero,
  dineroCorto,
} from '@/components/portada/datos'
import { RESPONSABLE } from '@/config/legal'
import { NOMBRE, urlAbsoluta } from '@/config/sitio'
import { consultarDirectorio } from '@/features/directorio/api'
import { especialidadDeTarjeta, lugarDeTarjeta } from '@/features/directorio/directorio'
import type { MedicoDelDirectorio } from '@/features/directorio/directorio'

/**
 * `/llms.txt` — Helios en una página de texto, para los buscadores con IA
 * (ChatGPT, Perplexity, Gemini…), que lo leen antes que el HTML. Sale de los
 * mismos datos que la portada, las guías y el directorio, así que no se
 * desactualiza solo. Mismas reglas de vocabulario que el resto del sitio
 * público. Lo que va arriba es la respuesta directa: qué es y cuánto cuesta.
 */
function texto(medicos: MedicoDelDirectorio[]) {
  const guias = Object.values(GUIAS)
    .map((g) => `- [${g.nombre}](${urlAbsoluta(g.ruta)}): ${g.descripcion}`)
    .join('\n')

  const cuotas = TABLA_DE_CUOTAS.map(
    (f) =>
      `| ${dineroCorto(f.monto)} | ${dinero(f.comision + f.iva)} | ${dinero(f.total)} | ${dinero(f.cuota)} |`,
  ).join('\n')

  const calendario = CALENDARIO_DE_COBRO.map((d) => `- ${d.termino}: ${d.valor}`).join('\n')

  // Las preguntas de la portada y de las páginas de pacientes y médicos, sin repetir.
  const vistas = new Set<string>()
  const preguntas = [...PREGUNTAS, ...GUIAS['/pacientes'].preguntas, ...GUIAS['/medicos'].preguntas]
    .filter((p) => {
      if (vistas.has(p.pregunta)) return false
      vistas.add(p.pregunta)
      return true
    })
    .map((p) => `### ${p.pregunta}\n\n${p.respuesta}`)
    .join('\n\n')

  const directorio = medicos.length
    ? medicos
        .map((m) =>
          [m.nombre, especialidadDeTarjeta(m), lugarDeTarjeta(m)].filter(Boolean).join(' — '),
        )
        .map((linea) => `- ${linea}`)
        .join('\n')
    : '- Muy pronto: el directorio se está llenando.'

  const contacto = [
    RESPONSABLE.soporte && `- Correo: ${RESPONSABLE.soporte}`,
    RESPONSABLE.whatsapp && `- WhatsApp: +${RESPONSABLE.whatsapp}`,
    `- Soporte: ${urlAbsoluta('/soporte')}`,
  ]
    .filter(Boolean)
    .join('\n')

  return `# ${NOMBRE}

> ${NOMBRE} permite pagar consultas y tratamientos de salud privada en Venezuela (medicina, odontología y cosmetología) en dos cuotas, a los 7 y 14 días, sin inicial. El médico o centro de salud afiliado recibe el 100% de la consulta, pague o no el paciente.

## En resumen

- Cuotas: 2, a los 7 y a los 14 días. Sin inicial.
- Comisión Helios: ${COMISION_PCT}% del monto de la consulta más ${IVA_PCT}% de IVA sobre la comisión, incluida en las cuotas. Una consulta de $100 se paga en dos cuotas de ${dinero(cuota)}.
- Pago: en bolívares, por Pago Móvil o transferencia, a la tasa oficial del BCV del día del pago.
- Límite inicial: $${LIMITE} en cuotas a la vez.
- Para el médico: recibe el 100% de la consulta (la mitad a los 8 días y la otra a los 15), sin costo de afiliación ni mensualidad.

## Para pacientes

- Dos cuotas, a los 7 y a los 14 días. Sin inicial.
- Comisión Helios: ${COMISION_PCT}% del monto de la consulta más ${IVA_PCT}% de IVA sobre la comisión, incluida en las cuotas.
- Límite inicial de $${LIMITE}: lo máximo que se puede tener en cuotas a la vez.
- Se paga en bolívares, por Pago Móvil o transferencia, a la tasa oficial del BCV del día del pago. La consulta puede ir en dólares o en euros.
- Sin app ni cuenta: el médico registra al paciente con su cédula y el paciente confirma por WhatsApp.
- Para mayores de 18 años con cédula; un menor de edad se atiende a nombre de su representante.

### Cuánto se paga según el monto de la consulta

| Consulta | Comisión Helios + IVA | Total | Cada cuota (días 7 y 14) |
| --- | --- | --- | --- |
${cuotas}

En euros, las mismas cifras en €. Cada cuota se paga en bolívares a la tasa BCV del día del pago.

## Para médicos y centros de salud

- Reciben el 100% del precio de la consulta: la mitad a los 8 días y la otra mitad a los 15, pague o no el paciente.
- Sin costo de afiliación ni mensualidad; la Comisión Helios la paga el paciente. Sin permanencia.
- Registran la consulta desde la plataforma web o por WhatsApp. Sin punto de venta.
- Afiliación: ${urlAbsoluta('/afiliacion')}

### Cuándo cobra el médico

${calendario}

## Médicos que aceptan Helios

Directorio completo, con filtro por especialidad y contacto por WhatsApp: ${urlAbsoluta('/directorio')}

${directorio}

## Preguntas frecuentes

${preguntas}

## Páginas

- [Inicio](${urlAbsoluta('/')})
${guias}
- [Directorio de médicos](${urlAbsoluta('/directorio')})
- [Quiero afiliarme](${urlAbsoluta('/afiliacion')})
- [Soporte](${urlAbsoluta('/soporte')})
- [Términos y condiciones](${urlAbsoluta('/legal/terminos')})

## Contacto

${contacto}
`
}

export const Route = createFileRoute('/llms.txt')({
  server: {
    handlers: {
      GET: async () => {
        // Sin directorio (si falla la consulta), el resto del texto sale igual.
        const medicos = await consultarDirectorio().catch(() => [])
        return new Response(texto(medicos), {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'public, max-age=3600',
          },
        })
      },
    },
  },
})
