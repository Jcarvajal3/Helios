import { useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Link, createFileRoute, useNavigate, useRouter } from '@tanstack/react-router'
import { ChevronRight, RotateCw, Search, X } from 'lucide-react'

import { IconoDeEspecialidad } from '@/components/directorio/IconoDeEspecialidad'
import { TarjetaDeMedico } from '@/components/directorio/TarjetaDeMedico'
import { Pie } from '@/components/portada'
import { Menu } from '@/components/portada/Menu'
import { Desglose } from '@/components/portada/Pacientes'
import { BotonAfiliarme, Boton, Lienzo, Revelar, Rotulo } from '@/components/portada/piezas'
import { IMAGEN_COMPARTIR, NOMBRE, urlAbsoluta } from '@/config/sitio'
import { apuntarContacto, consultarDirectorio } from '@/features/directorio/api'
import { especialidadesPresentes, filtrarDirectorio } from '@/features/directorio/directorio'
import type { MedicoDelDirectorio } from '@/features/directorio/directorio'
import { CLAVES_DE_ESPECIALIDAD, nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { comoTexto, unoDe } from '@/lib/busqueda'
import { FUENTES_DE_LA_PORTADA } from '@/lib/fuentes'

/**
 * EL DIRECTORIO DE MÉDICOS — `/directorio`.
 *
 * Los médicos que aceptan Helios, para que un paciente encuentre uno por su
 * nombre, su especialidad o su zona y le escriba por WhatsApp. Quién sale y
 * con qué datos lo decide el equipo en superadmin › Directorio de médicos.
 *
 * No se enlaza desde ninguna parte del sitio ni sale en el sitemap: se llega
 * escribiendo o compartiendo la URL (decisión de Javier, 2026-10-26). Por lo
 * mismo lleva `noindex`, pero sí su vista previa para WhatsApp: es por donde
 * se va a compartir. La búsqueda y la especialidad viven en la URL
 * (`?q=…&especialidad=odontologia`), así que también se comparte un filtro.
 *
 * Tiene el aspecto de la portada (`styles/portada.css`), siempre en claro.
 */

const TITULO = 'Directorio de médicos que aceptan Helios'
const DESCRIPCION =
  'Encuentra médicos, odontólogos y especialistas que aceptan Helios, escríbeles por WhatsApp y paga tu consulta en dos cuotas, a los 7 y 14 días, sin inicial.'

type BusquedaDelDirectorio = {
  q?: string
  especialidad?: ClaveDeEspecialidad
}

export const Route = createFileRoute('/directorio')({
  validateSearch: (search: Record<string, unknown>): BusquedaDelDirectorio => ({
    q: comoTexto(search.q, 80),
    especialidad: unoDe(CLAVES_DE_ESPECIALIDAD, search.especialidad),
  }),
  // La lista no depende de la búsqueda: filtrar no vuelve a pedirla.
  loaderDeps: () => ({}),
  staleTime: 60_000,
  loader: async () => {
    try {
      return { medicos: await consultarDirectorio(), fallo: false }
    } catch {
      return { medicos: [] as MedicoDelDirectorio[], fallo: true }
    }
  },
  head: () => {
    const url = urlAbsoluta('/directorio')
    const imagen = urlAbsoluta(IMAGEN_COMPARTIR.ruta)
    return {
      meta: [
        { title: `${TITULO} | ${NOMBRE}` },
        { name: 'description', content: DESCRIPCION },
        { name: 'robots', content: 'noindex, follow' },
        { name: 'color-scheme', content: 'light' },
        { property: 'og:type', content: 'website' },
        { property: 'og:site_name', content: NOMBRE },
        { property: 'og:locale', content: 'es_VE' },
        { property: 'og:url', content: url },
        { property: 'og:title', content: TITULO },
        { property: 'og:description', content: DESCRIPCION },
        { property: 'og:image', content: imagen },
        { property: 'og:image:width', content: String(IMAGEN_COMPARTIR.ancho) },
        { property: 'og:image:height', content: String(IMAGEN_COMPARTIR.alto) },
        { property: 'og:image:alt', content: IMAGEN_COMPARTIR.alt },
        { name: 'twitter:card', content: 'summary_large_image' },
        { name: 'twitter:title', content: TITULO },
        { name: 'twitter:description', content: DESCRIPCION },
        { name: 'twitter:image', content: imagen },
      ],
      links: [FUENTES_DE_LA_PORTADA],
    }
  },
  component: Directorio,
})

const NOCHE = '#020B24'

function Directorio() {
  const { medicos, fallo } = Route.useLoaderData()
  const search = Route.useSearch()
  const navigate = useNavigate({ from: '/directorio' })

  // Se filtra con lo que se teclea, al momento; la URL se pone al día al
  // dejar de teclear (sin dejar un paso en el historial por cada letra).
  const [texto, setTexto] = useState(search.q ?? '')
  useEffect(() => {
    const q = texto.trim() || undefined
    if (q === search.q) return
    const t = window.setTimeout(() => {
      void navigate({ search: (prev) => ({ ...prev, q }), replace: true })
    }, 350)
    return () => window.clearTimeout(t)
  }, [texto, search.q, navigate])

  const especialidades = useMemo(() => especialidadesPresentes(medicos), [medicos])
  const encontrados = useMemo(
    () => filtrarDirectorio(medicos, { q: texto, especialidad: search.especialidad }),
    [medicos, texto, search.especialidad],
  )

  function elegirEspecialidad(clave: ClaveDeEspecialidad | undefined) {
    void navigate({ search: (prev) => ({ ...prev, especialidad: clave }) })
  }

  function limpiar() {
    setTexto('')
    void navigate({ search: {} })
  }

  return (
    <div className="portada-raiz min-h-screen">
      <Menu />
      <main>
        <Cabecera
          texto={texto}
          onTexto={setTexto}
          especialidades={especialidades}
          elegida={search.especialidad}
          onEspecialidad={elegirEspecialidad}
          total={medicos.length}
        />
        <Resultados
          medicos={medicos}
          encontrados={encontrados}
          fallo={fallo}
          texto={texto.trim()}
          especialidad={search.especialidad}
          onLimpiar={limpiar}
        />
        <ComoPagas />
        <ParaMedicos />
      </main>
      <Pie />
    </div>
  )
}

// ── La cabecera: el titular, el buscador y las especialidades ──────────────

function Cabecera({
  texto,
  onTexto,
  especialidades,
  elegida,
  onEspecialidad,
  total,
}: {
  texto: string
  onTexto: (t: string) => void
  especialidades: ReturnType<typeof especialidadesPresentes>
  elegida: ClaveDeEspecialidad | undefined
  onEspecialidad: (clave: ClaveDeEspecialidad | undefined) => void
  total: number
}) {
  const campo = useRef<HTMLInputElement>(null)

  return (
    <section className="relative isolate overflow-hidden bg-white">
      <div
        aria-hidden
        className="portada-aurora absolute -right-[25%] -top-[35%] -z-10 size-[900px] rounded-full"
      />
      <div
        aria-hidden
        className="portada-aurora absolute -left-[30%] top-[40%] -z-10 size-[700px] rounded-full opacity-60"
      />
      <Lienzo className="pb-10 pt-32 sm:pb-14 sm:pt-40">
        <nav aria-label="Estás en">
          <ol className="flex flex-wrap items-center gap-1.5 text-[0.85rem] text-portada-tinta-3">
            <li>
              <Link to="/" className="underline-offset-4 hover:text-portada-tinta hover:underline">
                Inicio
              </Link>
            </li>
            <li aria-hidden>
              <ChevronRight className="size-3.5" />
            </li>
            <li aria-current="page" className="text-portada-tinta-2">
              Directorio de médicos
            </li>
          </ol>
        </nav>

        <div className="mt-10 max-w-[52rem]">
          <Rotulo>Directorio de médicos</Rotulo>
          <h1 className="portada-titular mt-6 text-portada-tinta">
            Encuentra a tu médico,{' '}
            <em className="portada-serif portada-degradado pr-[0.06em]">paga en dos cuotas.</em>
          </h1>
          <p className="portada-entrada mt-7 max-w-[54ch] text-portada-tinta-2">
            Médicos, odontólogos y especialistas que aceptan Helios. Escríbeles por WhatsApp,
            agenda tu consulta y págala en dos cuotas, a los 7 y 14 días, sin inicial.
          </p>
        </div>

        <form
          role="search"
          onSubmit={(e) => {
            e.preventDefault()
            campo.current?.blur()
            document.getElementById('medicos')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
          }}
          className="directorio-buscador mt-10 flex h-16 max-w-[52rem] items-center gap-3 rounded-full bg-white pl-6 pr-2"
        >
          <Search aria-hidden className="size-5 shrink-0 text-portada-tinta-3" />
          <label htmlFor="buscar-medico" className="sr-only">
            Buscar médico por nombre, especialidad o zona
          </label>
          <input
            ref={campo}
            id="buscar-medico"
            type="search"
            enterKeyHint="search"
            autoComplete="off"
            value={texto}
            onChange={(e) => onTexto(e.target.value)}
            placeholder={total > 0 ? 'Nombre, especialidad o zona' : 'Buscar médico'}
            className="h-full min-w-0 flex-1 bg-transparent text-[1.05rem] tracking-[-0.01em] text-portada-tinta placeholder:text-portada-tinta-3 [&::-webkit-search-cancel-button]:hidden"
          />
          {texto && (
            <button
              type="button"
              onClick={() => {
                onTexto('')
                campo.current?.focus()
              }}
              aria-label="Borrar la búsqueda"
              className="grid size-10 shrink-0 place-items-center rounded-full text-portada-tinta-3 transition-colors hover:bg-portada-niebla hover:text-portada-tinta"
            >
              <X className="size-4" />
            </button>
          )}
          <button
            type="submit"
            className="hidden h-12 shrink-0 items-center rounded-full bg-portada-tinta px-6 text-[0.95rem] font-medium tracking-[-0.01em] text-white transition-colors duration-300 hover:bg-portada-marino sm:inline-flex"
          >
            Buscar
          </button>
        </form>

        {especialidades.length > 1 && (
          <div className="-mx-5 mt-6 sm:-mx-8 lg:mx-0">
            <ul
              aria-label="Especialidades"
              className="directorio-chips flex gap-2 overflow-x-auto px-5 pb-1 sm:px-8 lg:flex-wrap lg:overflow-visible lg:px-0"
            >
              <li className="shrink-0">
                <ChipDeEspecialidad activa={!elegida} onClick={() => onEspecialidad(undefined)}>
                  Todas
                  <Cuenta activa={!elegida}>{total}</Cuenta>
                </ChipDeEspecialidad>
              </li>
              {especialidades.map((e) => (
                <li key={e.clave} className="shrink-0">
                  <ChipDeEspecialidad
                    activa={elegida === e.clave}
                    onClick={() => onEspecialidad(elegida === e.clave ? undefined : e.clave)}
                  >
                    <IconoDeEspecialidad clave={e.clave} className="size-4" strokeWidth={1.9} />
                    {e.nombre}
                    <Cuenta activa={elegida === e.clave}>{e.cuantos}</Cuenta>
                  </ChipDeEspecialidad>
                </li>
              ))}
            </ul>
          </div>
        )}
      </Lienzo>
    </section>
  )
}

function ChipDeEspecialidad({
  activa,
  onClick,
  children,
}: {
  activa: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      onClick={onClick}
      className={`directorio-chip inline-flex h-10 items-center gap-2 whitespace-nowrap rounded-full border pl-4 pr-1.5 text-[0.9rem] tracking-[-0.01em] ${
        activa
          ? 'border-portada-tinta bg-portada-tinta text-white'
          : 'border-portada-linea bg-white/80 text-portada-tinta-2 backdrop-blur hover:border-portada-tinta/25 hover:text-portada-tinta'
      }`}
    >
      {children}
    </button>
  )
}

function Cuenta({ activa, children }: { activa: boolean; children: ReactNode }) {
  return (
    <span
      className={`grid h-7 min-w-7 place-items-center rounded-full px-2 font-[family-name:var(--font-portada-mono)] text-[0.72rem] tabular-nums ${
        activa ? 'bg-white/15 text-white' : 'bg-portada-niebla text-portada-tinta-3'
      }`}
    >
      {children}
    </span>
  )
}

// ── Los resultados ─────────────────────────────────────────────────────────

function Resultados({
  medicos,
  encontrados,
  fallo,
  texto,
  especialidad,
  onLimpiar,
}: {
  medicos: MedicoDelDirectorio[]
  encontrados: MedicoDelDirectorio[]
  fallo: boolean
  texto: string
  especialidad: ClaveDeEspecialidad | undefined
  onLimpiar: () => void
}) {
  const router = useRouter()
  const [reintentando, setReintentando] = useState(false)
  const filtrado = texto !== '' || especialidad !== undefined

  return (
    <section id="medicos" className="relative bg-portada-niebla">
      <Lienzo className="py-14 sm:py-20">
        {fallo ? (
          <Aviso
            titulo="No pudimos cargar el directorio"
            texto="Revisa tu conexión e inténtalo de nuevo en un momento."
          >
            <button
              type="button"
              disabled={reintentando}
              onClick={() => {
                setReintentando(true)
                void router.invalidate().finally(() => setReintentando(false))
              }}
              className="inline-flex h-12 items-center gap-2 rounded-full bg-portada-tinta px-6 text-[0.95rem] font-medium text-white transition-colors hover:bg-portada-marino disabled:opacity-60"
            >
              <RotateCw className={`size-4 ${reintentando ? 'animate-spin' : ''}`} aria-hidden />
              Reintentar
            </button>
          </Aviso>
        ) : medicos.length === 0 ? (
          <Aviso
            titulo="Muy pronto verás aquí a los médicos que aceptan Helios"
            texto="Mientras tanto, pregunta por Helios en tu próxima consulta: tu médico puede registrar el pago en cuotas en un par de minutos."
          />
        ) : (
          <>
            <div className="flex flex-wrap items-end justify-between gap-x-6 gap-y-3">
              <p aria-live="polite" className="text-[1.05rem] tracking-[-0.015em] text-portada-tinta">
                <span className="font-medium tabular-nums">{encontrados.length}</span>{' '}
                {encontrados.length === 1 ? 'médico' : 'médicos'}
                {especialidad && (
                  <span className="text-portada-tinta-2"> en {nombreDeEspecialidad(especialidad)}</span>
                )}
                {texto && <span className="text-portada-tinta-2"> para «{texto}»</span>}
              </p>
              {filtrado && (
                <button
                  type="button"
                  onClick={onLimpiar}
                  className="inline-flex items-center gap-1.5 text-[0.93rem] font-medium text-portada-azul underline-offset-4 hover:underline"
                >
                  <X className="size-4" aria-hidden /> Quitar filtros
                </button>
              )}
            </div>

            {encontrados.length === 0 ? (
              <div className="mt-8">
                <Aviso
                  titulo={texto ? `No encontramos médicos para «${texto}»` : 'No hay médicos en esta especialidad todavía'}
                  texto="Prueba con otra especialidad, o escribe solo una parte del nombre o de la zona."
                >
                  <button
                    type="button"
                    onClick={onLimpiar}
                    className="inline-flex h-12 items-center rounded-full border border-portada-linea bg-white px-6 text-[0.95rem] font-medium tracking-[-0.01em] text-portada-tinta transition-colors hover:border-portada-tinta/25"
                  >
                    Ver todos los médicos
                  </button>
                </Aviso>
              </div>
            ) : (
              <ul className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 lg:gap-5">
                {encontrados.map((m, i) => (
                  <Revelar key={m.id} como="li" retraso={(i % 3) * 70}>
                    <TarjetaDeMedico medico={m} onContacto={() => apuntarContacto(m.id)} />
                  </Revelar>
                ))}
              </ul>
            )}
          </>
        )}
      </Lienzo>
    </section>
  )
}

function Aviso({ titulo, texto, children }: { titulo: string; texto: string; children?: ReactNode }) {
  return (
    <div className="flex flex-col items-center rounded-[32px] border border-dashed border-portada-linea bg-white px-6 py-16 text-center sm:py-20">
      <span className="directorio-icono grid size-14 place-items-center rounded-[18px] text-portada-azul">
        <Search className="size-6" strokeWidth={1.75} aria-hidden />
      </span>
      <h2 className="mt-6 max-w-[30ch] text-[1.35rem] font-medium leading-snug tracking-[-0.03em] text-portada-tinta">
        {titulo}
      </h2>
      <p className="mt-3 max-w-[48ch] text-[0.98rem] leading-relaxed text-portada-tinta-2">{texto}</p>
      {children && <div className="mt-8">{children}</div>}
    </div>
  )
}

// ── Cómo se paga ───────────────────────────────────────────────────────────

const PASOS_DEL_PACIENTE = [
  {
    titulo: 'Escríbele a tu médico',
    texto: 'Agenda tu consulta por WhatsApp y dile que quieres pagarla con Helios.',
  },
  {
    titulo: 'Confirma por WhatsApp',
    texto: 'El día de la consulta te llega el monto con tus dos cuotas. Respondes «Sí» y listo: hoy no pagas nada.',
  },
  {
    titulo: 'Paga en dos cuotas',
    texto: 'A los 7 y 14 días, en bolívares, por Pago Móvil o transferencia.',
  },
]

function ComoPagas() {
  return (
    <section className="relative overflow-hidden bg-white">
      <Lienzo className="py-24 sm:py-32">
        <div className="grid gap-14 lg:grid-cols-[minmax(0,1fr)_minmax(0,0.95fr)] lg:items-center lg:gap-20">
          <div>
            <Revelar>
              <Rotulo>Cómo pagas</Rotulo>
            </Revelar>
            <Revelar retraso={80}>
              <h2 className="portada-titular mt-6 max-w-[16ch] text-portada-tinta">
                Te atiendes hoy,{' '}
                <em className="portada-serif text-portada-azul">hoy no pagas nada.</em>
              </h2>
            </Revelar>
            <ol className="mt-12 flex flex-col">
              {PASOS_DEL_PACIENTE.map((p, i) => (
                <Revelar
                  key={p.titulo}
                  como="li"
                  retraso={i * 80}
                  className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-5 border-t border-portada-linea py-6"
                >
                  <span className="portada-etiqueta pt-1 text-portada-tinta-3">0{i + 1}</span>
                  <div>
                    <h3 className="text-[1.12rem] font-medium leading-snug tracking-[-0.02em] text-portada-tinta">
                      {p.titulo}
                    </h3>
                    <p className="mt-2 text-[0.97rem] leading-relaxed text-portada-tinta-2">{p.texto}</p>
                  </div>
                </Revelar>
              ))}
            </ol>
          </div>
          <Revelar retraso={160}>
            <Desglose />
          </Revelar>
        </div>
      </Lienzo>
    </section>
  )
}

// ── Para los médicos ───────────────────────────────────────────────────────

function ParaMedicos() {
  return (
    <section className="relative bg-white px-2 pb-2 sm:px-4 sm:pb-4">
      <div
        className="relative overflow-hidden rounded-[32px] sm:rounded-[44px]"
        style={{ backgroundColor: NOCHE }}
      >
        <Lienzo className="flex flex-col gap-8 py-16 sm:py-20 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <Rotulo tono="oscuro">Para médicos y centros</Rotulo>
            <h2 className="mt-5 text-[clamp(1.7rem,1.2rem+1.8vw,2.6rem)] font-medium leading-tight tracking-[-0.04em] text-white">
              ¿Eres médico? Afilia tu consultorio a Helios.
            </h2>
            <p className="mt-4 max-w-[52ch] text-[1.02rem] leading-relaxed text-white/70">
              Tus pacientes pagan en dos cuotas y tú recibes el 100% de la consulta a los 8 y 15
              días, pague o no el paciente. Sin costo ni permanencia.
            </p>
          </div>
          <div className="flex shrink-0 flex-wrap gap-3">
            <BotonAfiliarme tono="claro" />
            <Boton to="/medicos" tono="vidrio">
              Cómo funciona
            </Boton>
          </div>
        </Lienzo>
      </div>
    </section>
  )
}
