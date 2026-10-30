import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Link, useRouter } from '@tanstack/react-router'
import { ChevronRight, ChevronUp, RotateCw, Search, X } from 'lucide-react'

import { IconoDeEspecialidad } from '@/components/directorio/IconoDeEspecialidad'
import { TarjetaDeMedico } from '@/components/directorio/TarjetaDeMedico'
import { Pie } from '@/components/portada'
import { Menu } from '@/components/portada/Menu'
import { Desglose } from '@/components/portada/Pacientes'
import { BotonAfiliarme, Boton, Lienzo, Revelar, Rotulo } from '@/components/portada/piezas'
import { apuntarContacto } from '@/features/directorio/api'
import { especialidadesPresentes, fichasQueCaben, filtrarDirectorio } from '@/features/directorio/directorio'
import type { EspecialidadPresente, MedicoDelDirectorio } from '@/features/directorio/directorio'
import { nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { rutaDeEspecialidad } from '@/features/directorio/paginas'

/**
 * EL DIRECTORIO DE MÉDICOS — la página de `/directorio` y de
 * `/directorio/<especialidad>` (las rutas solo leen y pasan los datos).
 *
 * Los médicos que aceptan Helios, para que un paciente elija uno por su
 * especialidad y le escriba por WhatsApp. Quién sale y con qué datos lo
 * decide el equipo en superadmin › Directorio de médicos.
 *
 * Es una página para convertir: el titular, una línea y las especialidades
 * caben en la primera pantalla del teléfono junto a las primeras tarjetas, y
 * cada tarjeta entera lleva al chat (el nombre, a su ficha). Sin buscador
 * (2026-10-27): con pocos médicos, las especialidades bastan.
 *
 * Cada especialidad es un enlace a su página (2026-10-30): así Google las
 * sigue y cada una puede salir sola en los resultados («ginecólogos con
 * pago en cuotas»). Cambiar de especialidad no sube la página.
 *
 * Tiene el aspecto de la portada (`styles/portada.css`), siempre en claro.
 */

const NOCHE = '#020B24'

export function PaginaDelDirectorio({
  medicos,
  fallo,
  whatsappHelios,
  especialidad,
  h1,
  entrada,
  guia,
}: {
  medicos: MedicoDelDirectorio[]
  fallo: boolean
  whatsappHelios: string | null
  /** La de la página; sin ella, todos los médicos. */
  especialidad?: ClaveDeEspecialidad
  h1: { antes: string; enfasis: string }
  entrada: string
  /** La guía del pago en cuotas que más se le parece («/odontologia-en-cuotas»). */
  guia: { ruta: string; texto: string }
}) {
  const especialidades = useMemo(() => especialidadesPresentes(medicos), [medicos])
  const encontrados = useMemo(() => filtrarDirectorio(medicos, { especialidad }), [medicos, especialidad])

  return (
    <div className="portada-raiz min-h-screen">
      <Menu />
      <main>
        <Cabecera
          especialidades={especialidades}
          elegida={especialidad}
          total={medicos.length}
          h1={h1}
          entrada={entrada}
        />
        <Resultados
          medicos={medicos}
          encontrados={encontrados}
          fallo={fallo}
          whatsappHelios={whatsappHelios}
          especialidad={especialidad}
        />
        <ComoPagas guia={guia} />
        <ParaMedicos />
      </main>
      <Pie />
    </div>
  )
}

/** «Inicio › Directorio › Odontología»: la miga de pan visible. El último tramo no es enlace. */
export function MigasDelDirectorio({ tramos }: { tramos: Array<{ texto: string; to?: string }> }) {
  return (
    <nav aria-label="Estás en">
      <ol className="flex flex-wrap items-center gap-1.5 text-[0.85rem] text-portada-tinta-3">
        {tramos.map((t, i) => (
          <li key={t.texto} className="flex items-center gap-1.5">
            {i > 0 && <ChevronRight aria-hidden className="size-3.5" />}
            {t.to ? (
              <Link to={t.to} className="underline-offset-4 hover:text-portada-tinta hover:underline">
                {t.texto}
              </Link>
            ) : (
              <span aria-current="page" className="text-portada-tinta-2">
                {t.texto}
              </span>
            )}
          </li>
        ))}
      </ol>
    </nav>
  )
}

// ── La cabecera: el titular y las especialidades ───────────────────────────

function Cabecera({
  especialidades,
  elegida,
  total,
  h1,
  entrada,
}: {
  especialidades: EspecialidadPresente[]
  elegida: ClaveDeEspecialidad | undefined
  total: number
  h1: { antes: string; enfasis: string }
  entrada: string
}) {
  return (
    <section className="relative isolate overflow-clip bg-white">
      <div
        aria-hidden
        className="portada-aurora absolute -right-[25%] -top-[35%] -z-10 size-[900px] rounded-full"
      />
      <div
        aria-hidden
        className="portada-aurora absolute -left-[30%] top-[40%] -z-10 size-[700px] rounded-full opacity-60"
      />
      <Lienzo className="pb-7 pt-28 sm:pb-10 sm:pt-36">
        <div className="max-w-[52rem]">
          {elegida && (
            <div className="mb-6">
              <MigasDelDirectorio
                tramos={[
                  { texto: 'Inicio', to: '/' },
                  { texto: 'Directorio', to: '/directorio' },
                  { texto: nombreDeEspecialidad(elegida) },
                ]}
              />
            </div>
          )}
          <h1 className="portada-titular text-portada-tinta">
            {h1.antes}{' '}
            <em className="portada-serif portada-degradado pr-[0.06em]">{h1.enfasis}</em>
          </h1>
          <p className="portada-entrada mt-4 max-w-[60ch] text-portada-tinta-2 sm:mt-5">{entrada}</p>
        </div>

        {especialidades.length > 1 && (
          <Especialidades especialidades={especialidades} elegida={elegida} total={total} />
        )}
      </Lienzo>
    </section>
  )
}

/** El hueco entre fichas (`gap-2`), en píxeles: lo usa la medición. */
const HUECO_ENTRE_FICHAS = 8

/**
 * Las especialidades, envueltas en filas (sin deslizar de lado): 3 filas en
 * el teléfono y 2 desde 640 px. Las que no quepan esperan detrás de «Ver
 * más». Cuántas caben se mide sobre una copia invisible de la lista con
 * todas las fichas, así que vale con cualquier ancho y cualquier nombre.
 */
function Especialidades({
  especialidades,
  elegida,
  total,
}: {
  especialidades: EspecialidadPresente[]
  elegida: ClaveDeEspecialidad | undefined
  total: number
}) {
  const copia = useRef<HTMLUListElement>(null)
  // Cuántas fichas (contando «Todas») se ven con la lista cerrada; `null`
  // hasta medir (en el servidor, la lista se recorta con CSS).
  const [caben, setCaben] = useState<number | null>(null)
  const [abierta, setAbierta] = useState(false)

  useLayoutEffect(() => {
    const lista = copia.current
    if (!lista) return
    const medir = () => {
      const anchos = [...lista.children].map((f) => f.getBoundingClientRect().width)
      const verMas = anchos.pop() ?? 0
      setCaben(
        fichasQueCaben(anchos, {
          ancho: lista.getBoundingClientRect().width,
          hueco: HUECO_ENTRE_FICHAS,
          filas: window.matchMedia('(min-width: 640px)').matches ? 2 : 3,
          verMas,
        }),
      )
    }
    medir()
    // Al cambiar el ancho y cuando termina de cargar la letra (cambia el
    // ancho de cada ficha).
    const ro = new ResizeObserver(medir)
    ro.observe(lista)
    void document.fonts.ready.then(medir)
    return () => ro.disconnect()
  }, [especialidades])

  // Quien llega a la página de una especialidad que no cabe la ve marcada:
  // la lista se abre sola, solo esa vez.
  const posicionElegida = elegida ? especialidades.findIndex((e) => e.clave === elegida) + 1 : 0
  const yaMedida = useRef(false)
  useEffect(() => {
    if (caben === null || yaMedida.current) return
    yaMedida.current = true
    if (posicionElegida >= caben) setAbierta(true)
  }, [caben, posicionElegida])

  const fichas = 1 + especialidades.length
  const sobran = caben === null ? 0 : fichas - caben
  const visibles = caben === null || abierta ? especialidades : especialidades.slice(0, caben - 1)

  const todas = (
    <ChipDeEspecialidad activa={!elegida} to="/directorio">
      Todas
      <Cuenta activa={!elegida}>{total}</Cuenta>
    </ChipDeEspecialidad>
  )
  // Tocar la que ya está elegida vuelve a «Todas».
  const ficha = (e: EspecialidadPresente) => (
    <ChipDeEspecialidad
      activa={elegida === e.clave}
      to={elegida === e.clave ? '/directorio' : rutaDeEspecialidad(e.clave)}
    >
      <IconoDeEspecialidad clave={e.clave} className="size-4" strokeWidth={1.9} />
      {e.nombre}
      <Cuenta activa={elegida === e.clave}>{e.cuantos}</Cuenta>
    </ChipDeEspecialidad>
  )

  return (
    <div className="relative mt-7 sm:mt-9">
      <ul
        id="especialidades"
        aria-label="Especialidades"
        className={`flex flex-wrap gap-2 ${caben === null ? 'max-h-[128px] overflow-hidden sm:max-h-[88px]' : ''}`}
      >
        <li>{todas}</li>
        {visibles.map((e) => (
          <li key={e.clave}>{ficha(e)}</li>
        ))}
        {sobran > 0 && (
          <li>
            <ChipDeEspecialidad
              activa={false}
              aria-expanded={abierta}
              aria-controls="especialidades"
              onClick={() => setAbierta((a) => !a)}
              variante="mas"
            >
              {abierta ? 'Ver menos' : 'Ver más'}
              <span className="grid size-7 place-items-center rounded-full bg-portada-niebla text-portada-tinta-3">
                {abierta ? (
                  <ChevronUp className="size-4" aria-hidden />
                ) : (
                  <span className="font-[family-name:var(--font-portada-mono)] text-[0.72rem] tabular-nums">
                    +{sobran}
                  </span>
                )}
              </span>
            </ChipDeEspecialidad>
          </li>
        )}
      </ul>

      {/* La copia que se mide: todas las fichas y «Ver más», invisible y
          sin alto (no asoma ni se puede desplazar hasta ella). */}
      <div
        aria-hidden
        inert
        className="pointer-events-none invisible absolute inset-x-0 top-0 h-0 overflow-hidden"
      >
        <ul ref={copia} className="flex flex-wrap gap-2">
          <li>{todas}</li>
          {especialidades.map((e) => (
            <li key={e.clave}>{ficha(e)}</li>
          ))}
          <li>
            <ChipDeEspecialidad activa={false} onClick={() => {}} variante="mas">
              Ver más
              <span className="grid size-7 place-items-center rounded-full font-[family-name:var(--font-portada-mono)] text-[0.72rem]">
                +{fichas}
              </span>
            </ChipDeEspecialidad>
          </li>
        </ul>
      </div>
    </div>
  )
}

/**
 * Una ficha de especialidad (un enlace a su página, `to`) o «Ver más» (un
 * botón, `onClick`). El enlace no sube la página: quien elige una
 * especialidad sigue viendo las tarjetas.
 */
function ChipDeEspecialidad({
  activa,
  to,
  onClick,
  variante = 'especialidad',
  children,
  ...aria
}: {
  activa: boolean
  to?: string
  onClick?: () => void
  variante?: 'especialidad' | 'mas'
  children: ReactNode
  'aria-expanded'?: boolean
  'aria-controls'?: string
}) {
  const clases = `directorio-chip inline-flex h-10 items-center gap-2 whitespace-nowrap rounded-full border pl-3.5 pr-1.5 text-[0.88rem] tracking-[-0.01em] sm:pl-4 sm:text-[0.9rem] ${
    activa
      ? 'border-portada-tinta bg-portada-tinta text-white'
      : variante === 'mas'
        ? 'border-dashed border-portada-tinta/25 bg-white/80 font-medium text-portada-tinta backdrop-blur hover:border-portada-tinta/45'
        : 'border-portada-linea bg-white/80 text-portada-tinta-2 backdrop-blur hover:border-portada-tinta/25 hover:text-portada-tinta'
  }`
  if (to) {
    return (
      <Link to={to} resetScroll={false} aria-current={activa ? 'page' : undefined} className={clases}>
        {children}
      </Link>
    )
  }
  return (
    <button type="button" onClick={onClick} {...aria} className={clases}>
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
  whatsappHelios,
  especialidad,
}: {
  medicos: MedicoDelDirectorio[]
  encontrados: MedicoDelDirectorio[]
  fallo: boolean
  whatsappHelios: string | null
  especialidad: ClaveDeEspecialidad | undefined
}) {
  const router = useRouter()
  const [reintentando, setReintentando] = useState(false)

  return (
    <section id="medicos" className="relative bg-portada-niebla">
      <Lienzo className="pb-16 pt-6 sm:pb-24 sm:pt-10">
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
            <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-2">
              <p aria-live="polite" className="text-[0.98rem] tracking-[-0.015em] text-portada-tinta">
                <span className="font-medium tabular-nums">{encontrados.length}</span>{' '}
                {encontrados.length === 1 ? 'médico' : 'médicos'}
                {especialidad && (
                  <span className="text-portada-tinta-2"> en {nombreDeEspecialidad(especialidad)}</span>
                )}
              </p>
              {especialidad && (
                <Link
                  to="/directorio"
                  resetScroll={false}
                  className="inline-flex items-center gap-1.5 text-[0.9rem] font-medium text-portada-azul underline-offset-4 hover:underline"
                >
                  <X className="size-4" aria-hidden /> Ver todos
                </Link>
              )}
            </div>

            {encontrados.length === 0 ? (
              <div className="mt-5">
                <Aviso
                  titulo="No hay médicos en esta especialidad todavía"
                  texto="Prueba con otra especialidad: todos los médicos de este directorio aceptan Helios."
                >
                  <Link
                    to="/directorio"
                    resetScroll={false}
                    className="inline-flex h-12 items-center rounded-full border border-portada-linea bg-white px-6 text-[0.95rem] font-medium tracking-[-0.01em] text-portada-tinta transition-colors hover:border-portada-tinta/25"
                  >
                    Ver todos los médicos
                  </Link>
                </Aviso>
              </div>
            ) : (
              <ul className="mt-4 grid gap-3 sm:mt-5 sm:grid-cols-2 sm:gap-4 lg:grid-cols-3">
                {encontrados.map((m, i) => (
                  <Revelar key={m.id} como="li" retraso={(i % 3) * 60}>
                    <TarjetaDeMedico
                      medico={m}
                      whatsappHelios={whatsappHelios}
                      onContacto={() => apuntarContacto(m.id)}
                    />
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

export function ComoPagas({ guia }: { guia: { ruta: string; texto: string } }) {
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
            {/* Quien bajó a leer cómo se paga vuelve a la lista con un toque. */}
            <Revelar retraso={240} className="mt-4 flex flex-wrap gap-3">
              <Boton href="#medicos">Elegir mi médico</Boton>
              {/* La guía que explica el pago en cuotas de esta especialidad. */}
              <Boton to={guia.ruta} tono="contorno">
                {guia.texto}
              </Boton>
            </Revelar>
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

export function ParaMedicos() {
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
