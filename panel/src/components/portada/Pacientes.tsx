import {
  Banknote,
  CalendarCheck2,
  Clock,
  Gauge,
  IdCard,
  Percent,
} from 'lucide-react'
import { useState } from 'react'

import type { CSSProperties } from 'react'
import {
  COMISION_PCT,
  CONSULTA,
  IVA_PCT,
  PARA_PACIENTES,
  comision,
  cuota,
  dinero,
  dineroCorto,
  iva,
  total,
} from './datos'
import type { Moneda } from './datos'
import { Lienzo, Revelar, Rotulo, useEnVista } from './piezas'

/**
 * PARA PACIENTES — lo que se paga, con todos sus números.
 *
 * El ejemplo de $100 se desarma en una barra (consulta, comisión, IVA) que
 * luego se parte en las dos cuotas. El selector cambia la moneda: la
 * consulta puede ir en dólares o en euros, con las mismas cuentas, y se paga
 * en bolívares.
 */

const ICONOS = [CalendarCheck2, Percent, Gauge, Banknote, Clock, IdCard]

function Desglose() {
  const [moneda, setMoneda] = useState<Moneda>('USD')
  const [ref, visto] = useEnVista<HTMLDivElement>({ umbral: 0.35 })

  const filas = [
    { concepto: 'Consulta', monto: CONSULTA, color: 'bg-portada-azul' },
    {
      concepto: `Comisión Helios (${COMISION_PCT}%)`,
      monto: comision,
      color: 'bg-portada-cielo',
    },
    {
      concepto: `IVA de la Comisión Helios (${IVA_PCT}%)`,
      monto: iva,
      color: 'bg-portada-cielo-2',
    },
  ]

  return (
    <div
      ref={ref}
      data-visto={visto ? '' : undefined}
      className="portada-desglose relative rounded-[32px] border border-portada-linea bg-white p-6 shadow-[0_40px_80px_-40px_rgba(0,39,112,0.25)] sm:p-8"
    >
      <div className="flex flex-wrap items-center justify-between gap-4">
        <p className="portada-etiqueta text-portada-tinta-3">
          Ejemplo · una consulta de {dineroCorto(CONSULTA, moneda)}
        </p>
        <div
          role="radiogroup"
          aria-label="Moneda de la consulta"
          className="relative flex rounded-full bg-portada-niebla p-1 text-[0.8rem] font-medium"
        >
          <span
            aria-hidden
            className="absolute inset-y-1 left-1 w-[calc(50%-4px)] rounded-full bg-white shadow-sm transition-transform duration-500 ease-[cubic-bezier(.22,1,.36,1)]"
            style={{
              transform: moneda === 'EUR' ? 'translateX(100%)' : undefined,
            }}
          />
          {(['USD', 'EUR'] as const).map((m) => (
            <button
              key={m}
              type="button"
              role="radio"
              aria-checked={moneda === m}
              onClick={() => setMoneda(m)}
              className={`relative z-10 w-20 rounded-full py-1.5 transition-colors ${
                moneda === m
                  ? 'text-portada-tinta'
                  : 'text-portada-tinta-3 hover:text-portada-tinta'
              }`}
            >
              {m === 'USD' ? 'Dólares' : 'Euros'}
            </button>
          ))}
        </div>
      </div>

      <ul className="mt-6">
        {filas.map((f, i) => (
          <li
            key={f.concepto}
            className="portada-desglose-fila flex items-center justify-between gap-4 border-b border-portada-linea py-3.5"
            style={{ '--i': i } as CSSProperties}
          >
            <span className="flex items-center gap-3 text-[0.97rem] text-portada-tinta-2">
              <span className={`size-2.5 rounded-full ${f.color}`} />
              {f.concepto}
            </span>
            <span className="text-[1.02rem] font-medium tabular-nums text-portada-tinta">
              {dinero(f.monto, moneda)}
            </span>
          </li>
        ))}
        <li className="flex items-baseline justify-between gap-4 py-4">
          <span className="text-[0.97rem] font-medium text-portada-tinta">
            Total
          </span>
          <span className="text-[1.6rem] font-medium tabular-nums tracking-[-0.03em] text-portada-tinta">
            {dinero(total, moneda)}
          </span>
        </li>
      </ul>

      {/* La barra: el total, por partes. */}
      <div className="flex h-3 gap-[3px] overflow-hidden rounded-full">
        {filas.map((f, i) => (
          <span
            key={f.concepto}
            className={`portada-desglose-barra h-full rounded-full ${f.color}`}
            style={
              {
                '--ancho': `${(f.monto / total) * 100}%`,
                '--i': i,
              } as CSSProperties
            }
          />
        ))}
      </div>

      <div className="mt-6 flex items-center gap-3">
        <span className="portada-etiqueta text-portada-tinta-3">
          Se divide en dos
        </span>
        <span className="h-px flex-1 bg-portada-linea" />
      </div>

      <div className="mt-4 grid grid-cols-2 gap-3">
        {[7, 14].map((d, i) => (
          <div
            key={d}
            className="portada-desglose-cuota rounded-2xl bg-portada-niebla p-4"
            style={{ '--i': i } as CSSProperties}
          >
            <p className="text-[0.8rem] text-portada-tinta-3">
              Cuota {i + 1} · a los {d} días
            </p>
            <p className="mt-1 text-[1.35rem] font-medium tabular-nums tracking-[-0.03em] text-portada-tinta">
              {dinero(cuota, moneda)}
            </p>
          </div>
        ))}
      </div>

      <p className="mt-5 text-[0.95rem] leading-relaxed text-portada-tinta-2">
        Pagas{' '}
        <strong className="font-medium text-portada-tinta">
          {dinero(cuota, moneda)}
        </strong>{' '}
        a los 7 días y{' '}
        <strong className="font-medium text-portada-tinta">
          {dinero(cuota, moneda)}
        </strong>{' '}
        a los 14. Hoy, nada.{' '}
        <span className="text-portada-tinta-3">
          Cada cuota se paga en bolívares, a la tasa oficial del{' '}
          {moneda === 'EUR' ? 'euro' : 'dólar'} del BCV del día en que pagas.
        </span>
      </p>
    </div>
  )
}

export function Pacientes() {
  return (
    <section id="pacientes" className="relative overflow-hidden bg-white">
      <div
        aria-hidden
        className="portada-aurora absolute -right-[20%] top-[10%] -z-0 size-[900px] rounded-full"
      />
      <Lienzo className="relative py-24 sm:py-36">
        <div className="grid gap-14 lg:grid-cols-[minmax(0,0.95fr)_minmax(0,1fr)] lg:items-center lg:gap-20">
          <div>
            <Revelar>
              <Rotulo>Para pacientes</Rotulo>
            </Revelar>
            <Revelar retraso={80}>
              <h2 className="portada-titular mt-6 text-portada-tinta">
                Lo que pagas,{' '}
                <em className="portada-serif text-portada-azul">
                  con todos sus números.
                </em>
              </h2>
            </Revelar>
            <Revelar retraso={160}>
              <p className="portada-entrada mt-7 max-w-[44ch] text-portada-tinta-2">
                Una sola comisión, dicha desde el principio. Antes de confirmar
                ves el monto, la Comisión Helios y tus dos cuotas.
              </p>
            </Revelar>
          </div>

          <Revelar retraso={160}>
            <Desglose />
          </Revelar>
        </div>

        <div className="mt-24 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {PARA_PACIENTES.map((p, i) => {
            const Icono = ICONOS[i] ?? Percent
            return (
              <Revelar key={p.titulo} retraso={(i % 3) * 90}>
                <article className="portada-regla group relative h-full overflow-hidden rounded-[24px] border border-portada-linea bg-white p-7">
                  <div className="flex items-start justify-between">
                    <span className="grid size-11 place-items-center rounded-2xl bg-portada-azul/[0.07] text-portada-azul transition-all duration-500 group-hover:bg-portada-azul group-hover:text-white">
                      <Icono className="size-5" strokeWidth={1.6} />
                    </span>
                    <span className="portada-etiqueta text-portada-tinta-3/70">
                      0{i + 1}
                    </span>
                  </div>
                  <h3 className="mt-10 text-[1.15rem] font-medium leading-snug tracking-[-0.02em] text-portada-tinta">
                    {p.titulo}
                  </h3>
                  <p className="mt-2.5 text-[0.95rem] leading-relaxed text-portada-tinta-2">
                    {p.texto}
                  </p>
                </article>
              </Revelar>
            )
          })}
        </div>
      </Lienzo>
    </section>
  )
}
