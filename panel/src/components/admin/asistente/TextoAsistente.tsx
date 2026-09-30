import { Fragment } from 'react'

import { bloquesDe } from '@/features/admin/asistente/texto'
import type { Trozo } from '@/features/admin/asistente/texto'

function Trozos({ trozos }: { trozos: ReadonlyArray<Trozo> }) {
  return trozos.map((t, i) =>
    t.negrita ? (
      <strong key={i} className="font-semibold text-on-surface">
        {t.texto}
      </strong>
    ) : (
      <Fragment key={i}>{t.texto}</Fragment>
    ),
  )
}

/**
 * El texto de una respuesta: párrafos, listas y negritas, y nada más. Lo
 * demás se lee como texto; nunca se mete HTML del modelo en la página.
 *
 * El tamaño lo hereda de la conversación: 14 en el cajón y 16 en Inicio.
 */
export function TextoAsistente({ texto }: { texto: string }) {
  return (
    <div className="flex flex-col gap-2.5 text-on-surface">
      {bloquesDe(texto).map((b, i) => {
        switch (b.tipo) {
          case 'titulo':
            return (
              <p key={i} className="font-semibold text-on-surface">
                <Trozos trozos={b.trozos} />
              </p>
            )
          case 'parrafo':
            return (
              <p key={i}>
                {b.lineas.map((linea, j) => (
                  <Fragment key={j}>
                    {j > 0 && <br />}
                    <Trozos trozos={linea} />
                  </Fragment>
                ))}
              </p>
            )
          case 'lista': {
            const Lista = b.ordenada ? 'ol' : 'ul'
            return (
              <Lista
                key={i}
                className={`flex flex-col gap-1 pl-5 ${b.ordenada ? 'list-decimal' : 'list-disc'} marker:text-on-surface-variant`}
              >
                {b.elementos.map((e, j) => (
                  <li key={j}>
                    <Trozos trozos={e} />
                  </li>
                ))}
              </Lista>
            )
          }
        }
      })}
    </div>
  )
}
