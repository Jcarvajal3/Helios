import {
  Bell,
  Check,
  CheckCheck,
  MessageCircle,
  MonitorSmartphone,
} from 'lucide-react'

import type { CSSProperties, ReactNode } from 'react'
import { CampoDePuntos } from './CampoDePuntos'
import {
  CONSULTA,
  PASOS,
  comision,
  cuota,
  dinero,
  dineroCorto,
  iva,
} from './datos'
import {
  Lienzo,
  Revelar,
  Rotulo,
  useCiclo,
  useEnVista,
  useQuieto,
} from './piezas'
import { HeliosIsotipo } from '@/components/HeliosLogo'

/**
 * CÓMO FUNCIONA — tres tarjetas, una por paso.
 *
 * Cada una tiene su campo de puntos de fondo y, encima, una miniatura que se
 * mueve sola mientras se ve: el formulario del médico, la conversación del
 * paciente y el calendario de las dos cuotas. Las miniaturas son ilustración;
 * los textos de abajo son los que cuentan.
 */

type Fondo = { fondo: string; tintas: readonly [string, string, string] }

const FONDOS: ReadonlyArray<Fondo> = [
  { fondo: '#031338', tintas: ['#0B3A9C', '#157EFD', '#73C3FE'] },
  { fondo: '#0546C4', tintas: ['#1C63E6', '#45A8FD', '#CDEBFF'] },
  { fondo: '#02163F', tintas: ['#0A4AB8', '#1F99FE', '#A6DBFF'] },
]

function Tarjeta({
  indice,
  children,
}: {
  indice: number
  children: (activo: boolean) => ReactNode
}) {
  const paso = PASOS[indice]
  const fondo = FONDOS[indice]
  const [ref, visto] = useEnVista<HTMLDivElement>({
    umbral: 0.35,
    continuo: true,
  })
  const quieto = useQuieto()

  return (
    <Revelar retraso={indice * 120} className="h-full">
      <article
        ref={ref}
        className="portada-tarjeta group relative isolate flex h-[540px] flex-col overflow-hidden rounded-[28px] sm:h-[580px]"
        style={{ backgroundColor: fondo.fondo }}
      >
        <div aria-hidden className="absolute inset-0 -z-10">
          <CampoDePuntos
            escena="marea"
            fondo={fondo.fondo}
            tintas={fondo.tintas}
            celda={6}
            semilla={indice * 3.7 + 1}
            intensidad={0.9}
          />
          <div
            className="absolute inset-x-0 bottom-0 h-[55%]"
            style={{
              background: `linear-gradient(to top, ${fondo.fondo} 8%, color-mix(in srgb, ${fondo.fondo} 80%, transparent) 45%, transparent)`,
            }}
          />
        </div>

        <header className="flex items-center justify-between px-6 pt-6">
          <span className="flex items-center gap-2 text-[0.85rem] font-medium tracking-[-0.01em] text-white">
            <span className="grid size-6 place-items-center rounded-md bg-white">
              <HeliosIsotipo size={16} />
            </span>
            helios
          </span>
          <span className="portada-etiqueta text-white/60">Paso {paso.n}</span>
        </header>

        <div className="relative flex flex-1 items-center justify-center px-6">
          <div className="portada-miniatura w-full max-w-[290px]">
            {children(visto && !quieto)}
          </div>
        </div>

        <footer className="px-6 pb-7">
          <h3 className="text-[1.3rem] font-medium leading-tight tracking-[-0.025em] text-white">
            {paso.titulo}
          </h3>
          <p className="mt-2.5 text-[0.93rem] leading-relaxed text-white/70">
            {paso.texto}
          </p>
        </footer>
      </article>
    </Revelar>
  )
}

// ── 01 · El médico registra ────────────────────────────────────────────────

const CEDULA = 'V-12.345.678'

function Registro({ activo }: { activo: boolean }) {
  // 0 vacío · 1 cédula · 2 monto · 3 pulsa · 4 enviado
  const paso = useCiclo(
    5,
    (p) => [900, 1500, 1200, 450, 2600][p] ?? 1000,
    activo,
  )
  const fase = activo ? paso : 4

  return (
    <div className="portada-panelito rounded-[20px] bg-white p-4 shadow-[0_30px_60px_-20px_rgba(0,8,40,0.55)]">
      <p className="text-[0.85rem] font-medium tracking-[-0.01em] text-portada-tinta">
        Nueva orden
      </p>
      <span className="mt-3 grid grid-cols-2 rounded-full bg-portada-niebla p-0.5 text-[0.7rem] font-medium">
        <span className="flex items-center justify-center gap-1.5 rounded-full bg-white py-1 text-portada-tinta shadow-sm">
          <MonitorSmartphone className="size-3" /> Plataforma
        </span>
        <span className="flex items-center justify-center gap-1.5 py-1 text-portada-tinta-3">
          <MessageCircle className="size-3" /> WhatsApp
        </span>
      </span>

      <label className="mt-4 block text-[0.68rem] font-medium uppercase tracking-[0.08em] text-portada-tinta-3">
        Cédula del paciente
      </label>
      <div
        className={`portada-campo mt-1.5 ${fase === 1 ? 'portada-campo-activo' : ''}`}
      >
        {fase >= 1 ? (
          <span
            key={`c${activo ? paso : 9}`}
            className={fase === 1 ? 'portada-tecleo' : ''}
            style={{ '--letras': CEDULA.length } as CSSProperties}
          >
            {CEDULA}
          </span>
        ) : (
          <span className="text-portada-tinta-3/60">V-00.000.000</span>
        )}
      </div>

      <label className="mt-3 block text-[0.68rem] font-medium uppercase tracking-[0.08em] text-portada-tinta-3">
        Monto de la consulta
      </label>
      <div className="mt-1.5 flex gap-2">
        <span className="flex shrink-0 items-center rounded-xl bg-portada-niebla p-0.5 text-[0.78rem] font-medium">
          <span className="rounded-[10px] bg-white px-2.5 py-1.5 text-portada-tinta shadow-sm">
            $
          </span>
          <span className="px-2.5 py-1.5 text-portada-tinta-3">€</span>
        </span>
        <div
          className={`portada-campo flex-1 ${fase === 2 ? 'portada-campo-activo' : ''}`}
        >
          {fase >= 2 ? (
            <span
              key={`m${activo ? paso : 9}`}
              className={fase === 2 ? 'portada-tecleo' : ''}
              style={{ '--letras': 6 } as CSSProperties}
            >
              100,00
            </span>
          ) : (
            <span className="text-portada-tinta-3/60">0,00</span>
          )}
        </div>
      </div>

      <div className="relative mt-4 h-10">
        <span
          className={`absolute inset-0 flex items-center justify-center rounded-xl bg-portada-tinta text-[0.82rem] font-medium text-white transition-all duration-300 ${
            fase === 3 ? 'scale-[0.96] bg-portada-marino' : ''
          } ${fase === 4 ? 'scale-95 opacity-0' : ''}`}
        >
          Registrar
        </span>
        <span
          className={`absolute inset-0 flex items-center justify-center gap-2 rounded-xl bg-[#E7F7EE] text-[0.8rem] font-medium text-[#0B7A43] transition-all duration-500 ${
            fase === 4 ? 'scale-100 opacity-100' : 'scale-105 opacity-0'
          }`}
        >
          <Check className="size-4" /> Enviado al paciente
        </span>
      </div>
    </div>
  )
}

// ── 02 · El paciente confirma ──────────────────────────────────────────────

function Conversacion({ activo }: { activo: boolean }) {
  // 0 llega el mensaje · 1 escribe · 2 «Sí» · 3 comprobante
  const paso = useCiclo(4, (p) => [1600, 1100, 900, 3000][p] ?? 1000, activo)
  const fase = activo ? paso : 3

  return (
    <div className="flex flex-col gap-2 rounded-[20px] bg-[#EEF3FA] p-3 shadow-[0_30px_60px_-20px_rgba(0,8,40,0.55)]">
      <div className="flex items-center gap-2 border-b border-portada-tinta/[0.06] px-1 pb-2.5">
        <span className="grid size-7 place-items-center rounded-full bg-white">
          <HeliosIsotipo size={18} />
        </span>
        <span className="leading-tight">
          <span className="block text-[0.8rem] font-medium text-portada-tinta">
            Helios
          </span>
          <span className="block text-[0.65rem] text-portada-tinta-3">
            {fase === 1 ? 'escribiendo…' : 'en línea'}
          </span>
        </span>
      </div>

      <div className="portada-burbuja portada-burbuja-entra max-w-[92%] rounded-2xl rounded-tl-md bg-white p-3 text-[0.74rem] text-portada-tinta shadow-sm">
        <p className="font-medium">Tu pago en cuotas</p>
        <dl className="mt-2 space-y-1 text-portada-tinta-2">
          <div className="flex justify-between gap-3">
            <dt>Consulta</dt>
            <dd className="tabular-nums">{dineroCorto(CONSULTA)}</dd>
          </div>
          <div className="flex justify-between gap-3">
            <dt>Comisión de servicio</dt>
            <dd className="tabular-nums">{dinero(comision + iva)}</dd>
          </div>
          <div className="flex justify-between gap-3 border-t border-portada-linea pt-1 text-portada-tinta">
            <dt>Cuota 1 · 7 días</dt>
            <dd className="tabular-nums">{dinero(cuota)}</dd>
          </div>
          <div className="flex justify-between gap-3 text-portada-tinta">
            <dt>Cuota 2 · 14 días</dt>
            <dd className="tabular-nums">{dinero(cuota)}</dd>
          </div>
        </dl>
        <p className="mt-2 text-portada-tinta-2">¿Confirmas? Responde «Sí».</p>
      </div>

      <div className="flex min-h-[34px] justify-end">
        {fase === 1 ? (
          <span className="portada-burbuja-entra flex items-center gap-1 rounded-2xl rounded-br-md bg-portada-azul px-3.5 py-3">
            <span className="portada-punto-escribe" />
            <span className="portada-punto-escribe [animation-delay:150ms]" />
            <span className="portada-punto-escribe [animation-delay:300ms]" />
          </span>
        ) : fase >= 2 ? (
          <span className="portada-burbuja-entra flex items-end gap-1.5 rounded-2xl rounded-br-md bg-portada-azul px-3.5 py-2 text-[0.85rem] font-medium text-white">
            Sí <CheckCheck className="mb-0.5 size-3.5 text-white/80" />
          </span>
        ) : null}
      </div>

      <div className="min-h-[36px]">
        {fase === 3 ? (
          <p className="portada-burbuja-entra flex items-center gap-2 rounded-2xl rounded-tl-md bg-white px-3 py-2.5 text-[0.74rem] text-portada-tinta shadow-sm">
            <span className="grid size-5 shrink-0 place-items-center rounded-full bg-[#E7F7EE] text-[#0B7A43]">
              <Check className="size-3" />
            </span>
            Listo. Tu comprobante va a tu correo.
          </p>
        ) : null}
      </div>
    </div>
  )
}

// ── 03 · Paga en dos cuotas ────────────────────────────────────────────────

const DIAS = Array.from({ length: 17 }, (_, i) => i)
const ANCHO_DIA = 38

function Calendario({ activo }: { activo: boolean }) {
  // Del día 0 al 15, y una pausa al final.
  const paso = useCiclo(
    17,
    (p) => (p === 0 ? 900 : p === 16 ? 2600 : p === 7 || p === 14 ? 1300 : 420),
    activo,
  )
  const dia = activo ? Math.min(paso, 15) : 15
  const aviso = dia === 6 || dia === 13

  const cuotas = [
    { n: 1, vence: 7 },
    { n: 2, vence: 14 },
  ]

  return (
    <div className="relative">
      <div
        className={`absolute -top-14 left-1/2 flex w-max -translate-x-1/2 items-center gap-2 rounded-full bg-white/95 py-1.5 pl-1.5 pr-3.5 text-[0.72rem] text-portada-tinta shadow-lg transition-all duration-500 ${
          aviso ? 'translate-y-0 opacity-100' : '-translate-y-2 opacity-0'
        }`}
      >
        <span className="grid size-5 place-items-center rounded-full bg-portada-azul text-white">
          <Bell className="size-3" />
        </span>
        Tu cuota {dia < 10 ? 1 : 2} vence mañana
      </div>

      <div className="relative mx-auto h-11 overflow-hidden rounded-full bg-white/10 ring-1 ring-white/15 backdrop-blur">
        <div
          className="absolute left-1/2 top-0 flex h-full items-center transition-transform duration-500 ease-[cubic-bezier(.22,1,.36,1)]"
          style={{ transform: `translateX(${-(dia + 0.5) * ANCHO_DIA}px)` }}
        >
          {DIAS.map((d) => (
            <span
              key={d}
              className={`grid h-8 shrink-0 place-items-center text-[0.8rem] tabular-nums transition-all duration-300 ${
                d === dia
                  ? 'scale-110 font-semibold text-portada-tinta'
                  : d === 7 || d === 14
                    ? 'text-white'
                    : 'text-white/45'
              }`}
              style={{ width: ANCHO_DIA }}
            >
              {d}
            </span>
          ))}
        </div>
        <span
          aria-hidden
          className="absolute left-1/2 top-1/2 -z-10 size-8 -translate-x-1/2 -translate-y-1/2 rounded-full bg-white"
        />
        <span
          aria-hidden
          className="pointer-events-none absolute inset-y-0 left-0 w-10 bg-gradient-to-r from-[#02163F] to-transparent opacity-70"
        />
        <span
          aria-hidden
          className="pointer-events-none absolute inset-y-0 right-0 w-10 bg-gradient-to-l from-[#02163F] to-transparent opacity-70"
        />
      </div>
      <p className="mt-2 text-center text-[0.65rem] uppercase tracking-[0.14em] text-white/50">
        Día de la consulta → día 15
      </p>

      <div className="mt-4 rounded-[20px] bg-white p-2 shadow-[0_30px_60px_-20px_rgba(0,8,40,0.55)]">
        {cuotas.map((c) => {
          const pagada = dia >= c.vence
          return (
            <div
              key={c.n}
              className="flex items-center gap-3 rounded-[14px] px-2.5 py-2.5 transition-colors duration-500 even:mt-1"
              style={{
                backgroundColor:
                  dia === c.vence ? 'rgba(4,94,243,0.06)' : undefined,
              }}
            >
              <span
                className={`grid size-7 shrink-0 place-items-center rounded-full border transition-all duration-500 ${
                  pagada
                    ? 'border-transparent bg-[#E7F7EE] text-[#0B7A43]'
                    : 'border-portada-linea text-portada-tinta-3'
                }`}
              >
                {pagada ? (
                  <Check className="size-3.5" />
                ) : (
                  <span className="text-[0.65rem] font-medium">{c.n}</span>
                )}
              </span>
              <span className="min-w-0 flex-1 leading-tight">
                <span className="block text-[0.8rem] font-medium text-portada-tinta">
                  Cuota {c.n}
                </span>
                <span className="block text-[0.68rem] text-portada-tinta-3">
                  A los {c.vence} días
                </span>
              </span>
              <span className="text-right leading-tight">
                <span className="block text-[0.82rem] font-medium tabular-nums text-portada-tinta">
                  {dinero(cuota)}
                </span>
                <span
                  className={`block text-[0.65rem] ${pagada ? 'text-[#0B7A43]' : 'text-portada-tinta-3'}`}
                >
                  {pagada ? 'Pagada' : 'Pendiente'}
                </span>
              </span>
            </div>
          )
        })}
        <div className="mt-1 flex gap-1.5 border-t border-portada-linea px-2 pb-1 pt-2.5">
          {['Pago Móvil', 'Transferencia'].map((m) => (
            <span
              key={m}
              className="rounded-full bg-portada-niebla px-2.5 py-1 text-[0.66rem] font-medium text-portada-tinta-2"
            >
              {m}
            </span>
          ))}
        </div>
      </div>
    </div>
  )
}

export function ComoFunciona() {
  return (
    <section id="como-funciona" className="relative bg-portada-niebla">
      <Lienzo className="py-24 sm:py-32">
        <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,22rem)] lg:items-end">
          <Revelar>
            <Rotulo>Cómo funciona</Rotulo>
            <h2 className="portada-titular mt-6 text-portada-tinta">
              Tres pasos,{' '}
              <em className="portada-serif text-portada-azul">y listo.</em>
            </h2>
          </Revelar>
          <Revelar retraso={120}>
            <p className="portada-entrada text-portada-tinta-2">
              Sin app, sin cuenta y sin contraseña, ni para el médico ni para el
              paciente.
            </p>
          </Revelar>
        </div>

        <div className="mt-14 grid gap-4 md:grid-cols-2 lg:grid-cols-3 lg:gap-5">
          <Tarjeta indice={0}>
            {(activo) => <Registro activo={activo} />}
          </Tarjeta>
          <Tarjeta indice={1}>
            {(activo) => <Conversacion activo={activo} />}
          </Tarjeta>
          <div className="md:col-span-2 md:mx-auto md:w-1/2 md:px-2 lg:col-span-1 lg:mx-0 lg:w-auto lg:px-0">
            <Tarjeta indice={2}>
              {(activo) => <Calendario activo={activo} />}
            </Tarjeta>
          </div>
        </div>
      </Lienzo>
    </section>
  )
}
