import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { Link, useNavigate, useRouter, useSearch } from '@tanstack/react-router'
import { ChevronRight, ChevronUp, RotateCw, Search, Tag, X } from 'lucide-react'

import { HeliosLogo } from '@/components/HeliosLogo'
import { IsologoHelios } from '@/components/directorio/IsologoHelios'
import { TarjetaDeMedico } from '@/components/directorio/TarjetaDeMedico'
import { Pie } from '@/components/portada'
import { Menu } from '@/components/portada/Menu'
import { Desglose } from '@/components/portada/Pacientes'
import { BotonAfiliarme, Boton, Lienzo, Revelar, Rotulo } from '@/components/portada/piezas'
import { operador } from '@/config/legal'
import { apuntarContacto } from '@/features/directorio/api'
import {
  CLAVES_DE_TRAMO,
  TRAMOS_DE_PRECIO,
  especialidadesPresentes,
  fichasQueCaben,
  filtrarDirectorio,
  tramosConMedicos,
} from '@/features/directorio/directorio'
import type {
  ClaveDeTramo,
  EspecialidadPresente,
  MedicoDelDirectorio,
  VarianteDelDirectorio,
} from '@/features/directorio/directorio'
import { unoDe } from '@/lib/busqueda'
import { nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { apuntarLlegada } from '@/features/directorio/origen'
import { rutaDeEspecialidad } from '@/features/directorio/paginas'
import { useVisitaDelDirectorio } from '@/features/directorio/visita'

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
 * El filtro de precio va en la dirección (`?precio=`), para que siga ahí al
 * cambiar de especialidad o al volver de una ficha. Son botones, no enlaces, y
 * el canonical no lleva el parámetro: no crea páginas nuevas para Google, que
 * sigue viendo a todos los médicos.
 *
 * Tiene el aspecto de la portada (`styles/portada.css`), siempre en claro.
 *
 * LA VARIANTE B — `/consultas` (`variante="b"`, prueba A/B, docs/06). La
 * misma página con otra oferta («$15 de inicial»), para quien llega por un
 * anuncio o un enlace compartido. Lo que cambia:
 *   - el filtro de especialidad se queda en la página (`?especialidad=`) y
 *     no hay filtro de precio ni migas (ni enlaces a `/directorio`);
 *   - las tarjetas no enlazan a la ficha y su botón pasa por el WhatsApp de
 *     Helios con «-B» en el código;
 *   - sin menú, pie, «Cómo pagas» ni «Para médicos»: todo eso enlaza a
 *     guías que dicen «50% de inicial» y las fechas de las cuotas, que
 *     contradicen la oferta. Lleva una marca arriba y una línea legal abajo.
 *
 * Las dos apuntan la visita (`useVisitaDelDirectorio`) con su variante.
 */

/** El tramo de precio elegido, de la dirección. */
function useTramoElegido(): ClaveDeTramo | undefined {
  return useSearch({ strict: false, select: (s) => unoDe(CLAVES_DE_TRAMO, (s as { precio?: unknown }).precio) })
}

/** Adónde lleva una ficha de especialidad (o «Todas», sin `clave`). */
type Destino = { to: string; search: Record<string, string> }

/**
 * En A, cada especialidad es su página y el filtro de precio sigue puesto;
 * en B, todo se queda en `/consultas` con `?especialidad=`.
 */
function useDestinos(variante: VarianteDelDirectorio): (clave?: ClaveDeEspecialidad) => Destino {
  const precio = useTramoElegido()
  return (clave) => {
    if (variante === 'b') {
      const search: Record<string, string> = clave ? { especialidad: clave } : {}
      return { to: '/consultas', search }
    }
    const search: Record<string, string> = precio ? { precio } : {}
    return { to: clave ? rutaDeEspecialidad(clave) : '/directorio', search }
  }
}

export function PaginaDelDirectorio({
  medicos,
  fallo,
  whatsappHelios,
  especialidad,
  h1,
  entrada,
  guia,
  variante = 'a',
}: {
  medicos: MedicoDelDirectorio[]
  fallo: boolean
  whatsappHelios: string | null
  /** La de la página; sin ella, todos los médicos. */
  especialidad?: ClaveDeEspecialidad
  h1: { antes: string; enfasis: string }
  entrada: string
  /** La guía del pago en cuotas que más se le parece («/odontologia-en-cuotas»). Solo en A. */
  guia?: { ruta: string; texto: string }
  /** `'b'`: `/consultas`. */
  variante?: VarianteDelDirectorio
}) {
  const especialidades = useMemo(() => especialidadesPresentes(medicos), [medicos])
  const deLaEspecialidad = useMemo(() => filtrarDirectorio(medicos, { especialidad }), [medicos, especialidad])
  useVisitaDelDirectorio(variante)
  const enB = variante === 'b'

  return (
    <div className="portada-raiz directorio-raiz min-h-screen">
      {enB ? <MarcaDeConsultas /> : <Menu />}
      <main>
        <Cabecera elegida={especialidad} h1={h1} entrada={entrada} variante={variante} />
        <Resultados
          especialidades={especialidades}
          total={medicos.length}
          medicos={medicos}
          deLaEspecialidad={deLaEspecialidad}
          fallo={fallo}
          whatsappHelios={whatsappHelios}
          especialidad={especialidad}
          variante={variante}
        />
        {!enB && guia && <ComoPagas guia={guia} />}
        {!enB && <ParaMedicos />}
      </main>
      {enB ? <PieDeConsultas /> : <Pie />}
    </div>
  )
}

/**
 * Arriba de `/consultas`: solo la marca, sin enlaces (ni a la portada, que
 * dice «0% inicial»). Apunta la llegada como el menú, que aquí no está.
 */
function MarcaDeConsultas() {
  useEffect(() => apuntarLlegada(), [])
  return (
    <header className="absolute inset-x-0 top-0 z-50 px-3 pt-3 sm:px-5 sm:pt-4">
      <div className="mx-auto flex w-full max-w-[calc(var(--portada-ancho)+1.5rem)] items-center py-2 pl-5">
        <HeliosLogo height={26} color="#002770" />
      </div>
    </header>
  )
}

/**
 * Abajo de `/consultas`: quién opera Helios y la privacidad. Sin los
 * términos ni las guías: dicen «sin inicial» (docs/06).
 */
function PieDeConsultas() {
  return (
    <footer className="border-t border-portada-linea bg-white">
      <Lienzo className="flex flex-col gap-3 py-8 text-[0.82rem] leading-relaxed text-portada-tinta-3 sm:flex-row sm:items-center sm:justify-between">
        <p>Helios es operado por {operador()} · Venezuela · Solo para mayores de 18 años.</p>
        <Link to="/legal/privacidad" className="underline-offset-4 hover:text-portada-tinta hover:underline">
          Política de privacidad
        </Link>
      </Lienzo>
    </footer>
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

/**
 * La cabecera, con el amanecer del sistema (2026-11-12): el titular centrado
 * y, debajo, el sol de Helios que sale detrás de un horizonte curvo. La barra
 * de filtros se apoya sobre ese horizonte (`Resultados`).
 */
function Cabecera({
  elegida,
  h1,
  entrada,
  variante,
}: {
  elegida: ClaveDeEspecialidad | undefined
  h1: { antes: string; enfasis: string }
  entrada: string
  variante: VarianteDelDirectorio
}) {
  return (
    <section className="directorio-cielo relative isolate overflow-clip">
      <div aria-hidden className="directorio-rayos" />
      <div aria-hidden className="directorio-sol" />
      <div aria-hidden className="directorio-horizonte" />
      <Lienzo className="relative pb-[clamp(13rem,22vw,19rem)] pt-32 text-center sm:pt-40">
        <div className="mx-auto max-w-[64rem]">
          {elegida && variante === 'a' && (
            <div className="directorio-entra mb-7 flex justify-center">
              <MigasDelDirectorio
                tramos={[
                  { texto: 'Inicio', to: '/' },
                  { texto: 'Directorio', to: '/directorio' },
                  { texto: nombreDeEspecialidad(elegida) },
                ]}
              />
            </div>
          )}
          <h1 className="directorio-titular text-portada-tinta">
            <span className="directorio-entra block" style={{ '--retraso': '80ms' } as React.CSSProperties}>
              {h1.antes}
            </span>{' '}
            <span className="directorio-entra block pb-[0.08em]" style={{ '--retraso': '200ms' } as React.CSSProperties}>
              <em className="directorio-enfasis">{h1.enfasis}</em>
            </span>
          </h1>
          <p
            className="directorio-entra mx-auto mt-6 max-w-[40ch] text-[clamp(1.1rem,0.95rem+0.6vw,1.45rem)] leading-[1.45] tracking-[-0.012em] text-portada-tinta-2 sm:mt-9"
            style={{ '--retraso': '340ms' } as React.CSSProperties}
          >
            {entrada}
          </p>
        </div>
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
  variante,
}: {
  especialidades: EspecialidadPresente[]
  elegida: ClaveDeEspecialidad | undefined
  total: number
  variante: VarianteDelDirectorio
}) {
  const destino = useDestinos(variante)
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
    <ChipDeEspecialidad activa={!elegida} destino={destino()}>
      Todas
      <Cuenta activa={!elegida}>{total}</Cuenta>
    </ChipDeEspecialidad>
  )
  // Tocar la que ya está elegida vuelve a «Todas».
  const ficha = (e: EspecialidadPresente) => (
    <ChipDeEspecialidad
      activa={elegida === e.clave}
      destino={destino(elegida === e.clave ? undefined : e.clave)}
    >
      {e.nombre}
      <Cuenta activa={elegida === e.clave}>{e.cuantos}</Cuenta>
    </ChipDeEspecialidad>
  )

  return (
    <div className="relative">
      <ul
        id="especialidades"
        aria-label="Especialidades"
        className={`flex flex-wrap gap-2 ${caben === null ? 'max-h-[144px] overflow-hidden sm:max-h-[96px]' : ''}`}
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
              <span className="grid size-8 place-items-center rounded-full bg-portada-niebla text-portada-tinta-2">
                {abierta ? (
                  <ChevronUp className="size-4" aria-hidden />
                ) : (
                  <span className="font-semibold text-[0.72rem] tabular-nums">
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
              <span className="grid size-7 place-items-center rounded-full font-semibold text-[0.72rem]">
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
 * Una ficha de especialidad (un enlace, `destino`: su página en A, el filtro
 * en B) o «Ver más» (un botón, `onClick`). El enlace no sube la página:
 * quien elige una especialidad sigue viendo las tarjetas.
 */
function ChipDeEspecialidad({
  activa,
  destino,
  onClick,
  variante = 'especialidad',
  children,
  ...aria
}: {
  activa: boolean
  destino?: Destino
  onClick?: () => void
  variante?: 'especialidad' | 'mas'
  children: ReactNode
  'aria-expanded'?: boolean
  'aria-controls'?: string
}) {
  const clases = `directorio-chip inline-flex h-[46px] items-center gap-2.5 whitespace-nowrap rounded-full border pl-[18px] pr-[7px] text-[15px] font-medium tracking-[-0.01em] ${
    activa
      ? 'directorio-chip-activa border-portada-tinta bg-portada-tinta text-white'
      : variante === 'mas'
        ? 'border-dashed border-portada-tinta/25 bg-white text-portada-tinta hover:border-portada-azul/50'
        : 'border-portada-tinta/[0.07] bg-white text-portada-tinta hover:border-portada-azul/50'
  }`
  if (destino) {
    return (
      <Link
        to={destino.to}
        search={destino.search as never}
        resetScroll={false}
        aria-current={activa ? 'page' : undefined}
        className={clases}
      >
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
      className={`grid h-8 min-w-8 place-items-center rounded-full px-2.5 text-[0.78rem] font-medium tabular-nums ${
        activa ? 'bg-white/16 text-white' : 'bg-portada-niebla text-portada-tinta-2'
      }`}
    >
      {children}
    </span>
  )
}

// ── Los resultados ─────────────────────────────────────────────────────────

function Resultados({
  especialidades,
  total,
  medicos,
  deLaEspecialidad,
  fallo,
  whatsappHelios,
  especialidad,
  variante,
}: {
  especialidades: EspecialidadPresente[]
  total: number
  medicos: MedicoDelDirectorio[]
  deLaEspecialidad: MedicoDelDirectorio[]
  fallo: boolean
  whatsappHelios: string | null
  especialidad: ClaveDeEspecialidad | undefined
  variante: VarianteDelDirectorio
}) {
  const router = useRouter()
  const navigate = useNavigate()
  const [reintentando, setReintentando] = useState(false)
  const enB = variante === 'b'
  const tramoElegido = useTramoElegido()
  // B no tiene filtro de precio.
  const precio = enB ? undefined : tramoElegido
  const todos = useDestinos(variante)()
  const encontrados = useMemo(
    () => filtrarDirectorio(deLaEspecialidad, { precio }),
    [deLaEspecialidad, precio],
  )
  const sinPrecio = deLaEspecialidad.filter((m) => m.precio === null).length

  function elegirTramo(tramo: ClaveDeTramo | undefined) {
    void navigate({ to: '.', search: (tramo ? { precio: tramo } : {}) as never, resetScroll: false, replace: true })
  }

  return (
    <section id="medicos" className="relative z-[2] -mt-[4.5rem] scroll-mt-28">
      <Lienzo className="pb-24 sm:pb-36">
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
              className="inline-flex h-[3.25rem] items-center gap-2 rounded-full bg-portada-tinta px-7 text-[0.98rem] font-medium text-white transition-colors hover:bg-portada-azul disabled:opacity-60"
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
            {/* La barra de filtros: vidrio sobre el horizonte. Estática (Javier,
                2026-11-12): pegada arriba quitaba demasiada pantalla. */}
            <div className="directorio-barra relative z-20 flex flex-col gap-3 rounded-[32px] p-3">
              {especialidades.length > 1 && (
                <Especialidades
                  especialidades={especialidades}
                  elegida={especialidad}
                  total={total}
                  variante={variante}
                />
              )}
              <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-2 px-1.5 sm:px-2">
                {!enB && <FiltroDePrecio medicos={deLaEspecialidad} elegido={precio} onElegir={elegirTramo} />}
                <div className="ml-auto flex items-center gap-4">
                  {especialidad && (
                    <Link
                      to={todos.to}
                      search={todos.search as never}
                      resetScroll={false}
                      className="inline-flex items-center gap-1.5 text-[0.9rem] font-medium text-portada-azul underline-offset-4 hover:underline"
                    >
                      <X className="size-4" aria-hidden /> Ver todos
                    </Link>
                  )}
                  <p aria-live="polite" className="text-[0.95rem] tracking-[-0.01em] text-portada-tinta-2">
                    <span className="directorio-cuenta text-portada-tinta">{encontrados.length}</span>{' '}
                    {encontrados.length === 1 ? 'médico' : 'médicos'}
                    {especialidad && <span> en {nombreDeEspecialidad(especialidad)}</span>}
                  </p>
                </div>
              </div>
            </div>

            {precio && sinPrecio > 0 && (
              <p className="mt-4 px-2 text-[0.85rem] text-portada-tinta-3">
                No incluye {sinPrecio === 1 ? 'al médico que no publica' : `a los ${sinPrecio} médicos que no publican`} su
                precio.
              </p>
            )}

            {encontrados.length === 0 && precio && deLaEspecialidad.length > 0 ? (
              <div className="mt-8">
                <Aviso
                  titulo="No hay médicos en este rango de precio"
                  texto="Prueba con otro rango o mira a todos los médicos de esta lista."
                >
                  <button
                    type="button"
                    onClick={() => elegirTramo(undefined)}
                    className="inline-flex h-[3.25rem] items-center rounded-full bg-portada-tinta px-7 text-[0.98rem] font-medium tracking-[-0.01em] text-white transition-[background-color,transform] duration-300 hover:bg-portada-azul active:scale-[0.97]"
                  >
                    Ver todos los precios
                  </button>
                </Aviso>
              </div>
            ) : encontrados.length === 0 ? (
              <div className="mt-8">
                <Aviso
                  titulo="No hay médicos en esta especialidad todavía"
                  texto="Prueba con otra especialidad: todos los médicos de este directorio aceptan Helios."
                >
                  <Link
                    to={todos.to}
                    search={(enB ? {} : undefined) as never}
                    resetScroll={false}
                    className="inline-flex h-[3.25rem] items-center rounded-full bg-portada-tinta px-7 text-[0.98rem] font-medium tracking-[-0.01em] text-white transition-[background-color,transform] duration-300 hover:bg-portada-azul active:scale-[0.97]"
                  >
                    Ver todos los médicos
                  </Link>
                </Aviso>
              </div>
            ) : (
              <ul className="mt-8 grid gap-4 sm:mt-10 sm:grid-cols-2 sm:gap-5 lg:grid-cols-3">
                {encontrados.map((m, i) => (
                  <Revelar key={m.id} como="li" retraso={(i % 3) * 60}>
                    <TarjetaDeMedico
                      medico={m}
                      whatsappHelios={whatsappHelios}
                      onContacto={() => apuntarContacto(m.id, variante)}
                      variante={variante}
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

/**
 * El precio de la consulta, en botones. Solo los tramos que tienen algún
 * médico de esta lista (y el elegido, aunque se haya quedado sin ninguno);
 * si nadie publica su precio, no hay filtro.
 */
function FiltroDePrecio({
  medicos,
  elegido,
  onElegir,
}: {
  medicos: MedicoDelDirectorio[]
  elegido: ClaveDeTramo | undefined
  onElegir: (tramo: ClaveDeTramo | undefined) => void
}) {
  const conMedicos = tramosConMedicos(medicos)
  const tramos = TRAMOS_DE_PRECIO.filter((t) => conMedicos.includes(t.clave) || t.clave === elegido)
  if (tramos.length === 0) return null

  return (
    <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-4">
      <span id="filtro-de-precio" className="inline-flex items-center gap-1.5 text-[0.9rem] text-portada-tinta-2">
        <Tag aria-hidden className="size-3.5 text-portada-tinta-2" />
        Precio mínimo de la consulta
      </span>
      <div role="group" aria-labelledby="filtro-de-precio" className="directorio-precios">
        <button type="button" aria-pressed={!elegido} onClick={() => onElegir(undefined)} className="directorio-precio">
          Todos
        </button>
        {tramos.map((t) => (
          <button
            key={t.clave}
            type="button"
            aria-pressed={t.clave === elegido}
            // Tocar el que ya está elegido lo quita.
            onClick={() => onElegir(t.clave === elegido ? undefined : t.clave)}
            className="directorio-precio"
          >
            {t.rotulo}
          </button>
        ))}
      </div>
    </div>
  )
}

function Aviso({ titulo, texto, children }: { titulo: string; texto: string; children?: ReactNode }) {
  return (
    <div className="directorio-aviso flex flex-col items-center rounded-[36px] bg-white px-6 py-16 text-center sm:py-24">
      <span className="directorio-icono grid size-16 place-items-center rounded-full text-white">
        <Search className="size-6" strokeWidth={1.75} aria-hidden />
      </span>
      <h2 className="mt-7 max-w-[26ch] text-[clamp(1.5rem,1.2rem+1vw,2rem)] font-medium leading-tight tracking-[-0.035em] text-portada-tinta">
        {titulo}
      </h2>
      <p className="mt-3 max-w-[46ch] text-[1.02rem] leading-relaxed text-portada-tinta-2">{texto}</p>
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
    texto: 'El día de la consulta te llega el monto con la inicial y tus dos cuotas. Lo confirmas por WhatsApp y pagas la inicial, el 50%, ese mismo día.',
  },
  {
    titulo: 'Paga el resto en dos cuotas',
    texto: 'A los 14 y 28 días, en bolívares, por Pago Móvil o transferencia.',
  },
]

export function ComoPagas({ guia }: { guia: { ruta: string; texto: string } }) {
  return (
    // Como la maqueta aprobada (2026-11-12): el titular centrado y, debajo, los
    // pasos a la izquierda y el desglose dentro de un sol a la derecha.
    <section className="relative overflow-hidden bg-white">
      <Lienzo className="py-24 sm:py-36">
        <Revelar className="text-center">
          <p className="mb-[22px] text-[14px] font-semibold uppercase tracking-[0.16em] text-[#0a4fcb]">Cómo pagas</p>
          <h2 className="directorio-titular-2 mx-auto max-w-[15ch] text-portada-tinta">
            Paga la mitad hoy{' '}
            <em className="directorio-enfasis">y el resto en dos cuotas.</em>
          </h2>
        </Revelar>

        <div className="mt-12 flex flex-wrap items-stretch gap-[18px] sm:mt-20">
          <ol className="flex min-w-0 flex-[1_1_420px] flex-col gap-[18px]">
            {PASOS_DEL_PACIENTE.map((p, i) => (
              <Revelar
                key={p.titulo}
                como="li"
                retraso={i * 80}
                className="flex flex-1 items-center gap-6 rounded-[34px] bg-portada-niebla px-[30px] py-[26px]"
              >
                <span aria-hidden className="directorio-numeral w-14 shrink-0">
                  {i + 1}
                </span>
                <div>
                  <h3 className="text-[22px] font-medium leading-snug tracking-[-0.03em] text-portada-tinta">
                    {p.titulo}
                  </h3>
                  <p className="mt-1.5 max-w-[42ch] text-[1rem] leading-relaxed text-portada-tinta-2">{p.texto}</p>
                </div>
              </Revelar>
            ))}
          </ol>

          <Revelar
            retraso={160}
            className="directorio-sol-desglose relative min-w-0 flex-[1_1_420px] overflow-hidden rounded-[34px] p-[clamp(14px,3vw,36px)]"
          >
            <div aria-hidden className="directorio-sol-desglose-luz" />
            <div className="relative">
              <Desglose />
            </div>
          </Revelar>
        </div>

        {/* Quien bajó a leer cómo se paga vuelve a la lista con un toque. */}
        <Revelar retraso={240} className="mt-9 flex flex-wrap justify-center gap-2.5">
          <Boton href="#medicos">Elegir mi médico</Boton>
          {/* La guía que explica el pago en cuotas de esta especialidad. */}
          <Boton to={guia.ruta} tono="contorno">
            {guia.texto}
          </Boton>
        </Revelar>
      </Lienzo>
    </section>
  )
}

// ── Para los médicos ───────────────────────────────────────────────────────

export function ParaMedicos() {
  return (
    <section className="relative bg-white px-2 pb-2 sm:px-4 sm:pb-4">
      <div className="portada-bloque-azul relative overflow-hidden rounded-[32px] sm:rounded-[44px]">
        <IsologoHelios aria-hidden className="portada-rueda absolute -right-36 top-1/2 size-[40rem] -translate-y-1/2 opacity-[0.16]" />
        <Lienzo className="relative flex flex-col gap-8 py-16 sm:py-24 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <Rotulo tono="oscuro">Para médicos y centros</Rotulo>
            <h2 className="mt-5 max-w-[17ch] text-[clamp(2rem,1.2rem+3vw,4.5rem)] font-medium leading-none tracking-[-0.045em] text-white">
              ¿Eres médico? Afilia tu consultorio a Helios.
            </h2>
            <p className="mt-5 max-w-[50ch] text-[1.08rem] leading-relaxed text-white/90">
              Tus pacientes pagan la mitad el día de la consulta y el resto en dos cuotas, y tú
              recibes el 100% de la consulta a los 8 y 15 días, pague o no el paciente sus cuotas.
              Sin costo ni permanencia.
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
