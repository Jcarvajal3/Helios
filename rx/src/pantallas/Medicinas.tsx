import { useEffect, useState } from 'react'
import { ExternalLink, Info, LoaderCircle } from 'lucide-react'

import { datos } from '../datos/index.ts'
import type { Oferta, PreciosPublicos } from '../modelo.ts'
import { enlaceSeguro, fechaDeCaracas, textoDePrecio } from '../recipe/precios.ts'
import { Aviso, mensajeDe } from '../ui.tsx'

// La página que abre el paciente desde el correo, sin cuenta. Es de Helios, no
// del médico: él no elige ni modifica nada de lo que sale aquí, y esta página no
// dice de quién es el récipe.

function FilaOferta({ oferta }: { oferta: Oferta }) {
  const enlace = enlaceSeguro(oferta.url)
  const detalle = [oferta.laboratorio, oferta.presentacion].filter(Boolean).join(' · ')
  return (
    <li className="flex items-start justify-between gap-4 py-3.5 first:pt-0 last:pb-0">
      <div className="min-w-0">
        <p className="text-[16px] font-semibold leading-snug">{oferta.farmacia}</p>
        <p className="mt-0.5 text-[15px] leading-snug text-on-surface-variant">{oferta.producto}</p>
        {detalle && <p className="mt-0.5 text-[14px] text-on-surface-faint">{detalle}</p>}
        <p className="mt-1 text-[13px] text-on-surface-faint">Visto el {fechaDeCaracas(oferta.visto_en)}</p>
      </div>
      <div className="shrink-0 text-right">
        <p className="font-display text-[18px] font-semibold">{textoDePrecio(oferta.moneda, oferta.precio)}</p>
        {enlace && (
          <a
            href={enlace}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-1 inline-flex min-h-9 items-center gap-1 text-[14px] font-semibold text-primary underline-offset-2 hover:underline"
          >
            Ver
            <ExternalLink aria-hidden className="size-3.5" />
            <span className="sr-only">en {oferta.farmacia}</span>
          </a>
        )}
      </div>
    </li>
  )
}

export function Medicinas({ token }: { token: string }) {
  const [precios, setPrecios] = useState<PreciosPublicos | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    let vigente = true
    datos
      .preciosPublicos(token)
      .then((p) => {
        if (vigente) setPrecios(p)
      })
      .catch((e: unknown) => {
        if (vigente) setError(mensajeDe(e))
      })
    return () => {
      vigente = false
    }
  }, [token])

  return (
    <div className="min-h-dvh pb-10">
      <header className="border-b border-outline-variant/70 bg-surface">
        <div className="mx-auto flex h-14 max-w-2xl items-center px-4">
          <img src={`${import.meta.env.BASE_URL}logo.svg`} alt="Helios" className="h-7 w-auto" />
        </div>
      </header>

      <main className="mx-auto flex max-w-2xl flex-col gap-4 px-4 pt-6">
        <div>
          <h1 className="text-[26px] font-semibold leading-tight tracking-tight">Dónde conseguir tus medicamentos</h1>
          <p className="mt-2 text-[16px] text-on-surface-variant">
            Lo que publican las farmacias, de menor a mayor precio.
          </p>
        </div>

        <div className="flex items-start gap-2.5 rounded-medium bg-secondary-container px-3.5 py-3 text-on-secondary-container">
          <Info aria-hidden className="mt-0.5 size-4.5 shrink-0" />
          <p className="text-[15px] leading-snug">
            Esta información es de Helios. <b>Tu médico no elige estas farmacias ni estos precios.</b>
          </p>
        </div>

        {error && <Aviso>{error}</Aviso>}

        {!precios && !error && (
          <div role="status" aria-label="Cargando" className="grid place-items-center py-12 text-on-surface-faint">
            <LoaderCircle aria-hidden className="size-6 animate-spin" />
          </div>
        )}

        {precios?.medicamentos.map((m, i) => (
          <section key={i} className="aparecer rounded-large border border-outline-variant/70 bg-surface p-4 sm:p-5">
            <h2 className="text-[18px] font-semibold leading-tight">{m.nombre}</h2>
            <ul className="mt-3 divide-y divide-outline-variant/70">
              {m.ofertas.map((o, j) => (
                <FilaOferta key={j} oferta={o} />
              ))}
            </ul>
          </section>
        ))}

        {precios && precios.sin_precio > 0 && (
          <p className="rounded-large border border-dashed border-outline-variant px-4 py-3 text-[15px] text-on-surface-variant">
            {precios.sin_precio === 1
              ? 'De 1 medicamento de tu récipe no tenemos un precio reciente.'
              : `De ${precios.sin_precio} medicamentos de tu récipe no tenemos un precio reciente.`}{' '}
            Puedes preguntar en tu farmacia.
          </p>
        )}

        {precios && (
          <div className="flex flex-col gap-2 px-1 text-[14px] leading-snug text-on-surface-variant">
            <p>Los precios pueden cambiar según la tienda y el día. Confirma el precio y la existencia antes de comprar.</p>
            <p>Revisa también la cantidad que trae cada caja: una caja más barata puede traer menos unidades.</p>
            <p>
              <b>Compra lo que te recetaron.</b> Si quieres cambiar de marca o de producto, pregúntale antes a tu médico.
            </p>
          </div>
        )}
      </main>
    </div>
  )
}
