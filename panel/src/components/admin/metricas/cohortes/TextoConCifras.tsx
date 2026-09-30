import type { Trozo } from '@/features/admin/metricas/cohortes/frases'

/**
 * Una frase con cifras dentro de otro párrafo (la línea de resumen de un
 * gráfico, que ya es un `<p>`): las cifras en blanco y el resto heredado.
 * Para una frase suelta está `FraseConCifras` del kit, que pone su `<p>`.
 */
export function TextoConCifras({ trozos }: { trozos: ReadonlyArray<Trozo> }) {
  return (
    <>
      {trozos.map((t, i) =>
        typeof t === 'string' ? (
          <span key={i}>{t}</span>
        ) : (
          <strong key={i} className="font-semibold text-on-surface">
            {t.cifra}
          </strong>
        ),
      )}
    </>
  )
}
