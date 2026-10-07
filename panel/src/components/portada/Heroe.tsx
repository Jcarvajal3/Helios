import type { CSSProperties, ReactNode } from 'react'
import { ManosEnTrama } from './ManosEnTrama'
import {
  COMISION_PCT,
  CONSULTA,
  ESPECIALIDADES,
  comision,
  cuota,
  dinero,
  dineroCorto,
  iva,
} from './datos'
import { Boton, BotonAfiliarme, Lienzo, Rotulo } from './piezas'

/**
 * LA PRIMERA PANTALLA — qué es Helios.
 *
 * Detrás, a toda pantalla, dos manos que casi se tocan, en trama de puntos
 * azules (ver `ManosEnTrama`): el paciente y su médico. Bajo el cursor la
 * trama se abre y deja ver la foto. Delante, el titular a dos tonos, los dos botones y el ejemplo de una
 * consulta de $100 como un recibo de vidrio.
 */

/** Entra al cargar, escalonado. */
function Entra({
  retraso = 0,
  children,
  className = '',
}: {
  retraso?: number
  children: ReactNode
  className?: string
}) {
  return (
    <div
      className={`portada-entra ${className}`}
      style={{ '--retraso': `${retraso}ms` } as CSSProperties}
    >
      {children}
    </div>
  )
}

const FILAS = [
  { cuando: 'Hoy, en la consulta', dia: 'Día 0', monto: dinero(0) },
  { cuando: 'Cuota 1 · a los 7 días', dia: 'Día 7', monto: dinero(cuota) },
  { cuando: 'Cuota 2 · a los 14 días', dia: 'Día 14', monto: dinero(cuota) },
]

function Recibo() {
  return (
    <div className="portada-vidrio relative w-full max-w-[380px] rounded-[28px] p-6 sm:p-7">
      <div className="flex items-center justify-between">
        <p className="portada-etiqueta text-portada-tinta-3">Ejemplo</p>
        <span className="portada-etiqueta rounded-full bg-portada-azul/[0.08] px-2.5 py-1 text-portada-azul">
          2 cuotas
        </span>
      </div>
      <p className="mt-3 text-[1.35rem] font-medium tracking-[-0.03em] text-portada-tinta">
        Una consulta de {dineroCorto(CONSULTA)}
      </p>

      <ol className="relative mt-6">
        <span
          aria-hidden
          className="portada-recibo-riel absolute bottom-5 left-[7px] top-5 w-px"
        />
        {FILAS.map((f, i) => (
          <li
            key={f.cuando}
            className="portada-recibo-fila relative flex items-center gap-4 py-3"
            style={{ '--i': i } as CSSProperties}
          >
            <span
              aria-hidden
              className={`relative z-10 grid size-[15px] shrink-0 place-items-center rounded-full border-2 ${
                i === 0
                  ? 'border-portada-azul bg-portada-azul'
                  : 'border-portada-azul/40 bg-white'
              }`}
            >
              {i === 0 ? (
                <span className="size-1 rounded-full bg-white" />
              ) : null}
            </span>
            <span className="min-w-0 flex-1">
              <span className="block text-[0.95rem] leading-tight text-portada-tinta">
                {f.cuando}
              </span>
              <span className="portada-etiqueta mt-1 block !text-[0.62rem] text-portada-tinta-3">
                {f.dia}
              </span>
            </span>
            <span className="text-[1.15rem] font-medium tabular-nums tracking-[-0.02em] text-portada-tinta">
              {f.monto}
            </span>
          </li>
        ))}
      </ol>

      <p className="mt-4 border-t border-portada-linea pt-4 text-[0.82rem] leading-relaxed text-portada-tinta-3">
        Las cuotas incluyen la comisión de servicio: {COMISION_PCT}% de la
        consulta más el IVA de la comisión ({dinero(comision + iva)} en este
        ejemplo).{' '}
        <a
          href="#pacientes"
          className="font-medium text-portada-azul underline-offset-4 hover:underline"
        >
          Ver el detalle
        </a>
      </p>
    </div>
  )
}

export function Heroe() {
  return (
    <section id="arriba" className="relative isolate overflow-hidden bg-white">
      {/* Debajo de lg las manos ocupan la primera pantalla, más anchas que
          ella para que se vean grandes, y el texto empieza debajo. */}
      <div
        aria-hidden
        className="portada-heroe-fondo absolute -inset-x-[38vw] top-0 -z-10 h-[60svh] sm:inset-x-0 lg:inset-0 lg:h-auto"
      >
        <div className="portada-aparece absolute inset-0">
          <ManosEnTrama />
        </div>
        {/* Un velo blanco abajo a la izquierda: el texto siempre se lee. */}
        <div className="portada-velo-heroe absolute inset-0" />
      </div>

      <Lienzo className="relative flex flex-col justify-end pb-24 pt-[44svh] sm:pb-28 lg:min-h-[max(100svh,820px)] lg:pt-36">
        <div className="grid items-end gap-12 lg:grid-cols-[minmax(0,1fr)_380px] lg:gap-16">
          <div>
            <Entra>
              <Rotulo>Salud privada en cuotas</Rotulo>
            </Entra>

            <h1 className="portada-display mt-6 text-portada-tinta">
              <span className="portada-linea">
                <span style={{ '--retraso': '120ms' } as CSSProperties}>
                  Tu consulta hoy.
                </span>
              </span>
              <span className="portada-linea">
                <span style={{ '--retraso': '220ms' } as CSSProperties}>
                  Págala en{' '}
                  <em className="portada-serif portada-degradado pr-[0.06em]">
                    dos cuotas.
                  </em>
                </span>
              </span>
            </h1>

            <Entra retraso={420}>
              <p className="portada-entrada mt-7 max-w-[50ch] text-portada-tinta-2">
                Helios es una forma de pagar consultas y tratamientos de salud
                privada en cuotas. Hoy no pagas nada: pagas en dos cuotas, a los
                7 y a los 14 días.
              </p>
            </Entra>

            <Entra retraso={520}>
              <ul
                aria-label="Especialidades"
                className="mt-6 flex flex-wrap gap-2"
              >
                {ESPECIALIDADES.map((e) => (
                  <li
                    key={e}
                    className="rounded-full border border-portada-linea bg-white/70 px-3.5 py-1.5 text-[0.88rem] text-portada-tinta backdrop-blur"
                  >
                    {e}
                  </li>
                ))}
              </ul>
            </Entra>

            <Entra retraso={620}>
              <div className="mt-9 flex flex-wrap gap-3">
                <Boton href="#como-funciona">Ver cómo funciona</Boton>
                <BotonAfiliarme tono="contorno" />
              </div>
            </Entra>
          </div>

          <Entra retraso={760} className="lg:justify-self-end">
            <Recibo />
          </Entra>
        </div>
      </Lienzo>

      <Lienzo className="pointer-events-none absolute inset-x-0 bottom-0 hidden pb-6 sm:block">
        <div
          className="portada-entra grid grid-cols-3 items-end text-[0.8rem] text-portada-tinta-3"
          style={{ '--retraso': '1100ms' } as CSSProperties}
        >
          <p>Hoy no pagas nada.</p>
          <a
            href="#cifras"
            className="pointer-events-auto flex flex-col items-center gap-2 justify-self-center"
          >
            <span className="portada-etiqueta">Desliza</span>
            <span
              aria-hidden
              className="portada-desliza relative block h-8 w-px overflow-hidden bg-portada-linea"
            />
          </a>
          <p className="text-right">
            Pagas en bolívares, por Pago Móvil o transferencia.
          </p>
        </div>
      </Lienzo>
    </section>
  )
}
