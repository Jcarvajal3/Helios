import {
  CalendarCheck2,
  DoorOpen,
  MessageCircle,
  ShieldCheck,
  Wallet,
} from 'lucide-react'

import { CampoDePuntos } from './CampoDePuntos'
import { CONSULTA, PARA_MEDICOS, dineroCorto } from './datos'
import {
  Boton,
  BotonAfiliarme,
  EnlaceMas,
  Lienzo,
  Revelar,
  Rotulo,
  useCiclo,
  useEnVista,
  useQuieto,
} from './piezas'

/**
 * PARA MÉDICOS Y CENTROS — el bloque oscuro.
 *
 * Lo central es la línea de tiempo: el paciente paga a los 7 y a los 14
 * días, y la clínica cobra cada mitad al día siguiente, a los 8 y a los 15,
 * pague o no el paciente. Aquí, como en todo lo que ve una clínica, los
 * montos van sin la Comisión Helios.
 */

const NOCHE = '#020B24'
const ICONOS = [CalendarCheck2, Wallet, MessageCircle, DoorOpen]

const MITAD = CONSULTA / 2

const HITOS = [
  { dia: 0, carril: 'abajo', texto: 'Atiendes', corto: 'Atiendes' },
  { dia: 7, carril: 'arriba', texto: 'Cuota 1', corto: 'Cuota 1' },
  {
    dia: 8,
    carril: 'abajo',
    texto: `Recibes ${dineroCorto(MITAD)}`,
    corto: `+${dineroCorto(MITAD)}`,
  },
  { dia: 14, carril: 'arriba', texto: 'Cuota 2', corto: 'Cuota 2' },
  {
    dia: 15,
    carril: 'abajo',
    texto: `Recibes ${dineroCorto(MITAD)}`,
    corto: `+${dineroCorto(MITAD)}`,
  },
] as const

export function LineaDeCobro() {
  const [ref, visto] = useEnVista<HTMLDivElement>({
    umbral: 0.4,
    continuo: true,
  })
  const quieto = useQuieto()
  const activo = visto && !quieto
  const paso = useCiclo(
    17,
    (p) =>
      p === 0 ? 1000 : p === 16 ? 3200 : p === 8 || p === 15 ? 1100 : 320,
    activo,
  )
  const dia = activo ? Math.min(paso, 15) : 15
  const recibido = (dia >= 8 ? MITAD : 0) + (dia >= 15 ? MITAD : 0)

  return (
    <div ref={ref} className="portada-vidrio-oscuro rounded-[28px] p-6 sm:p-8">
      <div className="flex flex-wrap items-end justify-between gap-6">
        <div>
          <p className="portada-etiqueta text-white/50">
            Una consulta de {dineroCorto(CONSULTA)}
          </p>
          <p className="mt-3 text-[0.95rem] text-white/70">
            Día <span className="tabular-nums text-white">{dia}</span> de 15
          </p>
        </div>
        <div className="sm:text-right">
          <p className="portada-etiqueta text-white/50">Recibes</p>
          <p
            key={recibido}
            className="portada-cifra portada-salta mt-1 text-white"
          >
            {dineroCorto(recibido)}
            <span className="ml-2 align-middle text-[0.4em] font-normal tracking-normal text-portada-cielo-2">
              {Math.round((recibido / CONSULTA) * 100)}%
            </span>
          </p>
        </div>
      </div>

      <div className="mt-10 flex gap-4 sm:gap-6">
        <div className="flex h-36 shrink-0 flex-col justify-between py-3">
          <span className="portada-etiqueta text-[0.6rem] text-white/40">
            Paciente
          </span>
          <span className="portada-etiqueta text-[0.6rem] text-white/40">
            Tú
          </span>
        </div>
        <div className="relative h-36 flex-1">
          {/* El riel y lo recorrido. */}
          <div className="absolute inset-x-0 top-1/2 h-px -translate-y-1/2 bg-white/15" />
          <div
            className="absolute left-0 top-1/2 h-[2px] -translate-y-1/2 bg-gradient-to-r from-portada-azul via-portada-cielo to-portada-cielo-2 shadow-[0_0_18px_rgba(69,168,253,0.8)] transition-[width] duration-300 ease-linear"
            style={{ width: `${(dia / 15) * 100}%` }}
          />

          {HITOS.map((h) => {
            const llego = dia >= h.dia
            const x = `${(h.dia / 15) * 100}%`
            return (
              <div key={h.dia} className="absolute top-1/2" style={{ left: x }}>
                <span
                  className={`absolute left-0 top-0 block size-3 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 transition-all duration-500 ${
                    llego
                      ? 'scale-110 border-white bg-portada-cielo shadow-[0_0_0_6px_rgba(69,168,253,0.18)]'
                      : 'border-white/30 bg-[#020B24]'
                  }`}
                />
                <span
                  aria-hidden
                  className={`absolute left-0 w-px -translate-x-1/2 transition-colors duration-500 ${
                    h.carril === 'arriba' ? 'bottom-2 h-6' : 'top-2 h-6'
                  } ${llego ? 'bg-white/40' : 'bg-white/10'}`}
                />
                <span
                  className={`absolute whitespace-nowrap text-[0.72rem] font-medium transition-all duration-500 sm:text-[0.8rem] ${
                    h.carril === 'arriba' ? 'bottom-9' : 'top-9'
                  } ${h.dia === 0 ? '-translate-x-1.5' : h.dia === 15 ? '-translate-x-[calc(100%-6px)] text-right' : '-translate-x-1/2 text-center'} ${
                    llego
                      ? h.carril === 'abajo'
                        ? 'text-portada-cielo-2'
                        : 'text-white'
                      : 'text-white/35'
                  }`}
                >
                  <span className="sm:hidden">{h.corto}</span>
                  <span className="hidden sm:inline">{h.texto}</span>
                  <span className="block text-[0.62rem] font-normal tabular-nums text-white/40">
                    Día {h.dia}
                  </span>
                </span>
              </div>
            )
          })}
        </div>
      </div>

      <p className="mt-6 flex items-center gap-2 border-t border-white/10 pt-5 text-[0.88rem] text-white/70">
        <ShieldCheck className="size-4 shrink-0 text-portada-cielo-2" />
        Pague o no el paciente. El cobro corre por cuenta de Helios.
      </p>
    </div>
  )
}

export function Medicos() {
  return (
    <section
      id="medicos"
      className="relative bg-white px-2 py-2 sm:px-4 sm:py-4"
    >
      <div
        className="relative isolate overflow-hidden rounded-[32px] sm:rounded-[44px]"
        style={{ backgroundColor: NOCHE }}
      >
        <div aria-hidden className="absolute inset-0 -z-10 opacity-80">
          <CampoDePuntos
            escena="marea"
            fondo={NOCHE}
            tintas={['#062460', '#0D4CC0', '#2F86F0']}
            celda={7}
            semilla={11}
            intensidad={0.55}
          />
          <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_top_left,rgba(2,11,36,0.95)_20%,transparent_65%)]" />
        </div>

        <Lienzo className="py-24 sm:py-32">
          <div className="grid gap-14 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.05fr)] lg:items-center lg:gap-16">
            <div>
              <Revelar>
                <Rotulo tono="oscuro">Para médicos y centros</Rotulo>
              </Revelar>
              <Revelar retraso={80}>
                <h2 className="portada-titular mt-6 text-white">
                  Tu pago está garantizado,{' '}
                  <em className="portada-serif text-portada-cielo-2">
                    aunque el paciente no pague.
                  </em>
                </h2>
              </Revelar>
              <Revelar retraso={160}>
                <p className="portada-entrada mt-7 max-w-[46ch] text-white/70">
                  Atiendes hoy y Helios te paga la consulta completa. El cobro
                  al paciente corre por nuestra cuenta.
                </p>
                <p className="mt-5">
                  <EnlaceMas to="/medicos" tono="oscuro">
                    Cómo funciona para médicos y centros
                  </EnlaceMas>
                </p>
              </Revelar>
              <Revelar retraso={240}>
                <div className="mt-10 flex flex-wrap gap-3">
                  <BotonAfiliarme tono="claro" />
                  <Boton to="/login" tono="vidrio">
                    Entrar a la plataforma
                  </Boton>
                </div>
              </Revelar>
            </div>

            <Revelar retraso={200}>
              <LineaDeCobro />
            </Revelar>
          </div>

          <div className="mt-20 grid gap-px overflow-hidden rounded-[28px] border border-white/10 bg-white/10 sm:grid-cols-2 lg:grid-cols-4">
            {PARA_MEDICOS.map((b, i) => {
              const Icono = ICONOS[i] ?? Wallet
              return (
                <Revelar
                  key={b.titulo}
                  retraso={i * 90}
                  className="portada-beneficio group relative p-7"
                  style={{ backgroundColor: NOCHE }}
                >
                  <span className="grid size-11 place-items-center rounded-2xl border border-white/10 bg-white/[0.04] text-portada-cielo-2 transition-all duration-500 group-hover:border-portada-cielo/40 group-hover:bg-portada-azul/20">
                    <Icono className="size-5" strokeWidth={1.6} />
                  </span>
                  <h3 className="mt-8 text-[1.12rem] font-medium leading-snug tracking-[-0.02em] text-white">
                    {b.titulo}
                  </h3>
                  <p className="mt-2.5 text-[0.93rem] leading-relaxed text-white/60">
                    {b.texto}
                  </p>
                </Revelar>
              )
            })}
          </div>
        </Lienzo>
      </div>
    </section>
  )
}
