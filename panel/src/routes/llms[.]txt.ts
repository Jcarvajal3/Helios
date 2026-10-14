import { createFileRoute } from '@tanstack/react-router'

import { GUIAS } from '@/components/portada/guias'
import {
  COMISION_PCT,
  IVA_PCT,
  LIMITE,
  cuota,
  dinero,
} from '@/components/portada/datos'
import { NOMBRE, urlAbsoluta } from '@/config/sitio'

/**
 * `/llms.txt` — Helios en una página de texto, para los buscadores con IA
 * (ChatGPT, Perplexity, Gemini…), que lo leen antes que el HTML. Sale de los
 * mismos datos que la portada y las guías, así que no se desactualiza solo.
 * Mismas reglas de vocabulario que el resto del sitio público.
 */
function texto() {
  const guias = Object.values(GUIAS)
    .map((g) => `- [${g.nombre}](${urlAbsoluta(g.ruta)}): ${g.descripcion}`)
    .join('\n')

  return `# ${NOMBRE}

> ${NOMBRE} permite pagar consultas y tratamientos de salud privada en Venezuela (medicina, odontología y cosmetología) en dos cuotas, a los 7 y 14 días, sin inicial. El médico o centro de salud afiliado recibe el 100% de la consulta, pague o no el paciente.

## Para pacientes

- Dos cuotas, a los 7 y a los 14 días. Sin inicial.
- Comisión Helios: ${COMISION_PCT}% del monto de la consulta más ${IVA_PCT}% de IVA sobre la comisión, incluida en las cuotas. Ejemplo: una consulta de $100 se paga en dos cuotas de ${dinero(cuota)}.
- Límite inicial de $${LIMITE}: lo máximo que se puede tener en cuotas a la vez.
- Se paga en bolívares, por Pago Móvil o transferencia, a la tasa oficial del BCV del día del pago. La consulta puede ir en dólares o en euros.
- Sin app ni cuenta: el médico registra al paciente con su cédula y el paciente confirma por WhatsApp.
- Para mayores de 18 años con cédula; un menor de edad se atiende a nombre de su representante.

## Para médicos y centros de salud

- Reciben el 100% del precio de la consulta: la mitad a los 8 días y la otra mitad a los 15, pague o no el paciente.
- Sin costo de afiliación ni mensualidad; la Comisión Helios la paga el paciente. Sin permanencia.
- Registran la consulta desde la plataforma web o por WhatsApp. Sin punto de venta.
- Afiliación: ${urlAbsoluta('/afiliacion')}

## Páginas

- [Inicio](${urlAbsoluta('/')})
${guias}
- [Quiero afiliarme](${urlAbsoluta('/afiliacion')})
- [Soporte](${urlAbsoluta('/soporte')})
- [Términos y condiciones](${urlAbsoluta('/legal/terminos')})
`
}

export const Route = createFileRoute('/llms.txt')({
  server: {
    handlers: {
      GET: () =>
        new Response(texto(), {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'public, max-age=3600',
          },
        }),
    },
  },
})
