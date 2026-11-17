import type { CSSProperties, ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { ArrowUpRight, ChevronRight } from 'lucide-react'

import { CONSULTA, dinero, dineroCorto } from './datos'
import { Preguntas, Pie } from './Final'
import { CALENDARIO_DE_COBRO, GUIAS, NOMBRE_DE_RUTA, TABLA_DE_CUOTAS, cadaCuota } from './guias'
import type { Guia as DatosDeGuia, RutaDeGuia } from './guias'
import { LineaDeCobro } from './Medicos'
import { Menu } from './Menu'
import { Desglose } from './Pacientes'
import { Boton, BotonAfiliarme, Lienzo, Revelar, Rotulo } from './piezas'
import { IsologoHelios } from '@/components/directorio/IsologoHelios'
import { TarjetaDeMedico } from '@/components/directorio/TarjetaDeMedico'
import { REDES, cabeceraPublica, preguntasFrecuentes, servicio } from '@/config/sitio'
import { apuntarContacto, cargarDirectorio } from '@/features/directorio/api'
import { clavesDelMedico } from '@/features/directorio/directorio'
import type { MedicoDelDirectorio } from '@/features/directorio/directorio'

/**
 * LAS PÁGINAS PARA BUSCADORES — `/pacientes`, `/medicos` y una por
 * especialidad, con el aspecto de la portada.
 *
 *   Cabecera     miga de pan, H1 con la frase que se busca y el ejemplo
 *                (el desglose del paciente o la línea de cobro del médico)
 *   Resumen      la respuesta corta: las cifras, sueltas, arriba
 *   Pasos        cómo funciona, desde ese público
 *   Cifras       una tabla: cuánto paga el paciente según el monto, o
 *                cuándo cobra el médico, día por día
 *   Ventajas     lo que tiene que saber
 *   Médicos      en las del paciente, hasta 6 médicos reales de su
 *                especialidad, del directorio (`cargarMedicosDeGuia`)
 *   Aparte       en las especialidades, unas líneas para el médico
 *   Preguntas    las suyas, también en el JSON-LD
 *   Relacionadas enlaces a las otras páginas (enlazado interno)
 *   Cierre       la llamada a la acción
 *
 * El texto vive en `guias.ts`. Cada ruta es un fichero corto:
 * `head: () => cabeceraDeGuia(ruta)`, `component: () => <Guia ruta=… />` y,
 * en las del paciente, `loader: () => cargarMedicosDeGuia(ruta)`.
 */

/** El `head` de una guía: metadatos, miga de pan, servicio y preguntas. */
export function cabeceraDeGuia(ruta: RutaDeGuia) {
  const g: DatosDeGuia = GUIAS[ruta]
  const base = cabeceraPublica({
    titulo: g.titulo,
    descripcion: g.descripcion,
    ruta,
    migas: [{ nombre: g.nombre, ruta }],
    aspecto: 'portada',
    datos: [
      servicio({
        ruta,
        nombre: g.servicio.nombre,
        descripcion: g.descripcion,
        publico: g.publico === 'medico' ? 'Clinician' : 'Patient',
        categoria: g.servicio.categoria,
      }),
      preguntasFrecuentes(ruta, g.preguntas),
    ],
  })
  return { ...base, meta: [...base.meta, { name: 'color-scheme', content: 'light' }] }
}

export function Guia({ ruta, medicos = SIN_MEDICOS }: { ruta: RutaDeGuia; medicos?: MedicosDeGuia }) {
  const g: DatosDeGuia = GUIAS[ruta]
  return (
    <div className="portada-raiz min-h-screen">
      <Menu />
      <main>
        <Cabecera guia={g} />
        <Resumen guia={g} />
        <Pasos guia={g} />
        {g.publico === 'medico' ? <CalendarioDeCobro /> : <CuantoPagas />}
        <Ventajas guia={g} />
        <MedicosDeLaGuia guia={g} medicos={medicos} />
        {g.aparte && <Aparte {...g.aparte} />}
        <Preguntas
          lista={g.preguntas}
          titular={{ antes: 'Preguntas', enfasis: 'frecuentes.' }}
        />
        <Relacionadas rutas={g.relacionadas} />
        <Cierre guia={g} />
      </main>
      <Pie />
    </div>
  )
}

function Migas({ nombre }: { nombre: string }) {
  return (
    <nav aria-label="Estás en">
      <ol className="flex flex-wrap items-center gap-1.5 text-[0.85rem] text-portada-tinta-3">
        <li>
          <Link
            to="/"
            className="underline-offset-4 hover:text-portada-tinta hover:underline"
          >
            Inicio
          </Link>
        </li>
        <li aria-hidden>
          <ChevronRight className="size-3.5" />
        </li>
        <li aria-current="page" className="text-portada-tinta-2">
          {nombre}
        </li>
      </ol>
    </nav>
  )
}

/**
 * La portada de la guía, con el amanecer del sistema (2026-11-12): el
 * titular centrado y el sol detrás de un horizonte curvo. El ejemplo (el
 * desglose o la línea de cobro) se apoya sobre el horizonte.
 */
function Cabecera({ guia: g }: { guia: DatosDeGuia }) {
  return (
    <>
    <section className="directorio-cielo portada-cierre relative isolate overflow-clip">
      <div aria-hidden className="directorio-rayos" />
      <div aria-hidden className="directorio-sol" />
      <div aria-hidden className="directorio-horizonte" />
      <Lienzo className="relative pb-[clamp(13rem,22vw,19rem)] pt-32 text-center sm:pt-40">
        <div className="directorio-entra flex justify-center">
          <Migas nombre={g.nombre} />
        </div>
        <div className="mx-auto mt-8 max-w-[64rem]">
          <div>
            <Rotulo className="directorio-entra justify-center">{g.rotulo}</Rotulo>
            <h1
              className="directorio-titular directorio-entra mt-6 text-portada-tinta"
              style={{ '--retraso': '100ms' } as CSSProperties}
            >
              {g.h1.antes}{' '}
              <em className="directorio-enfasis">{g.h1.enfasis}</em>
            </h1>
            <p
              className="directorio-entra mx-auto mt-7 max-w-[46ch] text-[clamp(1.1rem,0.95rem+0.6vw,1.4rem)] leading-[1.45] tracking-[-0.012em] text-portada-tinta-2"
              style={{ '--retraso': '240ms' } as CSSProperties}
            >
              {g.entrada}
            </p>
            <div
              className="directorio-entra mt-10 flex flex-wrap justify-center gap-3"
              style={{ '--retraso': '360ms' } as CSSProperties}
            >
              {g.publico === 'medico' ? (
                <>
                  <BotonAfiliarme />
                  <Boton to="/login" tono="contorno">
                    Entrar a la plataforma
                  </Boton>
                </>
              ) : (
                <>
                  {g.directorio ? (
                    <>
                      <Boton to={g.directorio.ruta}>{g.directorio.texto}</Boton>
                      <Boton href="#como-funciona" tono="contorno">
                        Ver cómo funciona
                      </Boton>
                    </>
                  ) : (
                    <>
                      <Boton href="#como-funciona">Ver cómo funciona</Boton>
                      <Boton href="#preguntas" tono="contorno">
                        Preguntas frecuentes
                      </Boton>
                    </>
                  )}
                </>
              )}
            </div>
          </div>

        </div>
      </Lienzo>
    </section>
    {/* El ejemplo, apoyado sobre el horizonte. */}
    <section className="relative z-[2] -mt-[7rem] bg-transparent">
      <Lienzo className="pb-20 sm:pb-28">
        <div className="mx-auto max-w-[44rem]">
          {g.publico === 'medico' ? (
            <div className="portada-bloque-azul rounded-[32px] p-2 sm:rounded-[40px]">
              <LineaDeCobro />
            </div>
          ) : (
            <Desglose />
          )}
        </div>
      </Lienzo>
    </section>
    </>
  )
}

/** La respuesta corta, en una lista de definiciones: lo que se busca, sin rodeos. */
function Resumen({ guia: g }: { guia: DatosDeGuia }) {
  return (
    <section aria-labelledby="resumen" className="relative bg-white">
      <Lienzo className="pb-20 sm:pb-24">
        <h2 id="resumen" className="portada-rotulo text-portada-azul-texto">
          En resumen
        </h2>
        <dl className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {g.resumen.map((d) => (
            <div key={d.termino} className="rounded-[28px] bg-portada-niebla px-6 py-6 sm:px-7">
              <dt className="text-[0.9rem] text-portada-tinta-2">{d.termino}</dt>
              <dd className="mt-2 text-[1.2rem] font-medium leading-snug tracking-[-0.03em] text-portada-tinta">
                {d.valor}
              </dd>
            </div>
          ))}
        </dl>
      </Lienzo>
    </section>
  )
}

/** Una sección con su titular y una tabla, que en el teléfono se desliza de lado. */
function SeccionDeTabla({
  rotulo,
  titular,
  nota,
  children,
}: {
  rotulo: string
  titular: { antes: string; enfasis: string }
  nota: string
  children: ReactNode
}) {
  return (
    <section className="relative bg-white">
      <Lienzo className="py-24 sm:py-32">
        <Revelar>
          <Rotulo>{rotulo}</Rotulo>
          <h2 className="portada-titular mt-6 max-w-[20ch] text-portada-tinta">
            {titular.antes}{' '}
            <em className="portada-serif portada-acento pr-[0.06em]">{titular.enfasis}</em>
          </h2>
        </Revelar>
        <Revelar retraso={80}>
          <div className="portada-tarjeta-solida mt-12 overflow-x-auto rounded-[32px] bg-white">
            {children}
          </div>
          <p className="mt-5 max-w-[70ch] text-[0.92rem] leading-relaxed text-portada-tinta-3">
            {nota}
          </p>
        </Revelar>
      </Lienzo>
    </section>
  )
}

const CELDA = 'px-5 py-4 sm:px-6'
const CABECERA_DE_TABLA =
  'bg-portada-niebla text-left text-[0.82rem] font-normal text-portada-tinta-3'

/** Cuánto paga el paciente según el monto de su consulta. */
function CuantoPagas() {
  return (
    <SeccionDeTabla
      rotulo="Las cifras"
      titular={{ antes: 'Cuánto pagas,', enfasis: 'según tu consulta.' }}
      nota="En dólares o en euros, según la moneda de tu consulta (en euros, las mismas cifras en €). La inicial es el 50% del total. Cada pago se hace en bolívares, a la tasa oficial del BCV del día en que pagas."
    >
      <table className="w-full min-w-[42rem] border-collapse text-[0.97rem]">
        <caption className="sr-only">
          Lo que pagas en cuotas con Helios según el monto de la consulta
        </caption>
        <thead>
          <tr>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Consulta</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Comisión Helios + IVA</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Total</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Inicial (día de la consulta)</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Cada cuota (días 14 y 28)</th>
          </tr>
        </thead>
        <tbody className="tabular-nums text-portada-tinta-2">
          {TABLA_DE_CUOTAS.map((f) => (
            <tr key={f.monto} className="border-t border-portada-linea">
              <th scope="row" className={`${CELDA} text-left font-medium text-portada-tinta`}>
                {dineroCorto(f.monto)}
              </th>
              <td className={CELDA}>{dinero(f.comision + f.iva)}</td>
              <td className={CELDA}>{dinero(f.total)}</td>
              <td className={`${CELDA} font-medium text-portada-tinta`}>{dinero(f.inicial)}</td>
              <td className={`${CELDA} font-medium text-portada-azul`}>{cadaCuota(f)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </SeccionDeTabla>
  )
}

/**
 * Cuándo cobra el médico, día por día. Sin la Comisión Helios: al médico
 * solo se le habla del precio de su consulta (CLAUDE.md).
 */
function CalendarioDeCobro() {
  const mitad = dineroCorto(CONSULTA / 2)
  return (
    <SeccionDeTabla
      rotulo="El calendario"
      titular={{ antes: 'Cuándo cobras,', enfasis: 'día por día.' }}
      nota={`Ejemplo: por una consulta de ${dineroCorto(CONSULTA)} recibes ${mitad} el día 8 y ${mitad} el día 15, por transferencia en bolívares a la tasa oficial del BCV. Se paga a diario, no una vez por semana.`}
    >
      <table className="w-full border-collapse text-[0.97rem]">
        <caption className="sr-only">Cuándo cobra el médico cada consulta registrada en Helios</caption>
        <thead>
          <tr>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA} w-24 sm:w-32`}>Día</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Qué pasa</th>
          </tr>
        </thead>
        <tbody className="text-portada-tinta-2">
          {CALENDARIO_DE_COBRO.map((d) => (
            <tr key={d.termino} className="border-t border-portada-linea">
              <th scope="row" className={`${CELDA} text-left font-medium text-portada-tinta`}>
                {d.termino}
              </th>
              <td className={CELDA}>{d.valor}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </SeccionDeTabla>
  )
}

function Pasos({ guia: g }: { guia: DatosDeGuia }) {
  return (
    <section id="como-funciona" className="relative bg-portada-niebla">
      <Lienzo className="py-24 sm:py-32">
        <Revelar>
          <Rotulo>Cómo funciona</Rotulo>
          <h2 className="portada-titular mt-6 max-w-[18ch] text-portada-tinta">
            {g.pasos.titulo.antes}{' '}
            <em className="portada-serif portada-acento pr-[0.06em]">
              {g.pasos.titulo.enfasis}
            </em>
          </h2>
        </Revelar>
        <ol className="mt-14 grid gap-4 md:grid-cols-3 lg:gap-5">
          {g.pasos.lista.map((p, i) => (
            <Revelar
              key={p.titulo}
              como="li"
              retraso={i * 80}
              className="portada-tarjeta-solida rounded-[34px] bg-white p-7 sm:p-8"
            >
              <span aria-hidden className="directorio-numeral block">
                {i + 1}
              </span>
              <h3 className="mt-8 text-[1.35rem] font-medium leading-snug tracking-[-0.03em] text-portada-tinta">
                {p.titulo}
              </h3>
              <p className="mt-3 text-[0.97rem] leading-relaxed text-portada-tinta-2">
                {p.texto}
              </p>
            </Revelar>
          ))}
        </ol>
      </Lienzo>
    </section>
  )
}

function Ventajas({ guia: g }: { guia: DatosDeGuia }) {
  return (
    <section className="relative bg-white">
      <Lienzo className="py-24 sm:py-32">
        <Revelar>
          <Rotulo>
            {g.publico === 'medico' ? 'Para tu consultorio' : 'Para ti'}
          </Rotulo>
          <h2 className="portada-titular mt-6 max-w-[20ch] text-portada-tinta">
            {g.ventajas.titulo.antes}{' '}
            <em className="portada-serif portada-acento pr-[0.06em]">
              {g.ventajas.titulo.enfasis}
            </em>
          </h2>
        </Revelar>
        <ul className="mt-14 grid gap-3 sm:grid-cols-2 lg:grid-cols-3 lg:gap-4">
          {g.ventajas.lista.map((v, i) => (
            <Revelar
              key={v.titulo}
              como="li"
              retraso={(i % 3) * 80}
              className="rounded-[32px] bg-portada-niebla p-7 sm:p-8"
            >
              <span aria-hidden className="portada-numero portada-acento block text-[2.75rem]">
                {i + 1}
              </span>
              <h3 className="mt-6 text-[1.25rem] font-medium leading-snug tracking-[-0.03em] text-portada-tinta">
                {v.titulo}
              </h3>
              <p className="mt-3 text-[0.97rem] leading-relaxed text-portada-tinta-2">
                {v.texto}
              </p>
            </Revelar>
          ))}
        </ul>
      </Lienzo>
    </section>
  )
}

function Aparte({ titulo, texto }: { titulo: string; texto: string }) {
  return (
    <section className="relative bg-white px-2 pb-2 sm:px-4 sm:pb-4">
      <div className="portada-bloque-azul relative overflow-hidden rounded-[32px] sm:rounded-[44px]">
        <IsologoHelios aria-hidden className="portada-rueda absolute -right-36 top-1/2 size-[40rem] -translate-y-1/2 opacity-[0.16]" />
        <Lienzo className="relative flex flex-col gap-8 py-16 sm:py-24 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <Rotulo tono="oscuro">Para médicos y centros</Rotulo>
            <h2 className="mt-5 max-w-[17ch] text-[clamp(2rem,1.2rem+3vw,4.5rem)] font-medium leading-none tracking-[-0.045em] text-white">
              {titulo}
            </h2>
            <p className="mt-5 max-w-[50ch] text-[1.08rem] leading-relaxed text-white/90">
              {texto}
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

function Relacionadas({ rutas }: { rutas: DatosDeGuia['relacionadas'] }) {
  return (
    <section className="relative bg-white">
      <Lienzo className="py-20 sm:py-24">
        <h2 className="portada-rotulo text-portada-azul-texto">
          También te puede interesar
        </h2>
        <ul className="mt-6 grid gap-3 sm:grid-cols-3">
          {rutas.map((r) => (
            <li key={r}>
              <Link
                to={r}
                className="portada-tarjeta-solida group flex h-full items-center justify-between gap-4 rounded-[28px] bg-white px-7 py-6 text-[1.15rem] font-medium tracking-[-0.025em] text-portada-tinta transition-[box-shadow,transform] duration-500 hover:-translate-y-1"
              >
                {NOMBRE_DE_RUTA[r]}
                <span className="grid size-10 shrink-0 place-items-center rounded-full bg-portada-tinta text-white transition-colors duration-300 group-hover:bg-portada-azul">
                  <ArrowUpRight className="size-4" />
                </span>
              </Link>
            </li>
          ))}
        </ul>
      </Lienzo>
    </section>
  )
}

/**
 * La llamada final. Al médico, afiliarse. Al paciente, desde el 2026-10-30,
 * buscar a su médico en el directorio (su especialidad, si la guía la tiene);
 * sin directorio, preguntar por Helios en la consulta.
 */
function Cierre({ guia: g }: { guia: DatosDeGuia }) {
  const directorio = g.publico === 'paciente' ? g.directorio : undefined
  return (
    <section className="directorio-cielo portada-cierre relative isolate overflow-clip">
      <div aria-hidden className="directorio-rayos" />
      <div aria-hidden className="directorio-sol" />
      <div aria-hidden className="directorio-horizonte" />
      <Lienzo className="relative flex flex-col items-center pb-[clamp(14rem,22vw,19rem)] pt-28 text-center sm:pt-36">
        <Rotulo>Medicina · Odontología · Cosmetología</Rotulo>
        <h2 className="directorio-titular-2 mt-6 max-w-[16ch] text-portada-tinta">
          {g.publico === 'medico' ? (
            <>
              Afilia tu consultorio,{' '}
              <em className="portada-serif portada-acento pr-[0.06em]">
                sin costo.
              </em>
            </>
          ) : directorio ? (
            <>
              {directorio.cierre.antes}{' '}
              <em className="portada-serif portada-acento pr-[0.06em]">
                {directorio.cierre.enfasis}
              </em>
            </>
          ) : (
            <>
              Pregunta por Helios{' '}
              <em className="portada-serif portada-acento pr-[0.06em]">
                en tu próxima consulta.
              </em>
            </>
          )}
        </h2>
        <div className="mt-10 flex flex-wrap justify-center gap-3">
          {g.publico === 'medico' ? (
            <>
              <BotonAfiliarme />
              <Boton to="/pacientes" tono="contorno">
                Lo que ve tu paciente
              </Boton>
            </>
          ) : (
            <>
              {directorio && <Boton to={directorio.ruta}>{directorio.texto}</Boton>}
              <Boton to="/medicos" tono={directorio ? 'contorno' : 'tinta'}>
                Soy médico
              </Boton>
              {!directorio &&
                REDES.map((r) => (
                  <Boton
                    key={r.url}
                    href={r.url}
                    externo
                    flecha="fuera"
                    tono="contorno"
                  >
                    Síguenos en {r.nombre}
                  </Boton>
                ))}
            </>
          )}
        </div>
      </Lienzo>
    </section>
  )
}

/**
 * Médicos de verdad, de la especialidad de la guía (hasta 6, en el orden
 * sorteado del directorio, que reparte los clics): su tarjeta, con el mismo
 * botón de WhatsApp y el nombre que lleva a su ficha, y «Ver todos». Sale de
 * la base al cargar la página; sin médicos, no sale.
 */
function MedicosDeLaGuia({ guia: g, medicos }: { guia: DatosDeGuia; medicos: MedicosDeGuia }) {
  const directorio = g.directorio
  if (!directorio || medicos.lista.length === 0) return null
  return (
    <section className="relative bg-portada-niebla">
      <Lienzo className="py-24 sm:py-32">
        <Revelar>
          <Rotulo>Directorio</Rotulo>
          <h2 className="portada-titular mt-6 max-w-[20ch] text-portada-tinta">
            {directorio.quienes} que{' '}
            <em className="portada-serif portada-acento pr-[0.06em]">ya aceptan Helios.</em>
          </h2>
          <p className="mt-5 max-w-[56ch] text-[1rem] leading-relaxed text-portada-tinta-2">
            Escríbeles por WhatsApp para agendar tu cita y paga el 50% el día de la consulta y el
            resto en 2 cuotas, a los 14 y 28 días.
          </p>
        </Revelar>
        <ul className="mt-12 grid gap-3 sm:grid-cols-2 sm:gap-4 lg:grid-cols-3">
          {medicos.lista.map((m, i) => (
            <Revelar key={m.id} como="li" retraso={(i % 3) * 60}>
              <TarjetaDeMedico
                medico={m}
                whatsappHelios={medicos.whatsappHelios}
                onContacto={() => apuntarContacto(m.id)}
              />
            </Revelar>
          ))}
        </ul>
        {medicos.total > medicos.lista.length && (
          <div className="mt-8">
            <Boton to={directorio.ruta} tono="contorno">
              Ver los {medicos.total} del directorio
            </Boton>
          </div>
        )}
      </Lienzo>
    </section>
  )
}

/** Lo que carga cada guía del paciente: hasta 6 médicos de lo suyo, cuántos hay y el WhatsApp de Helios. */
export type MedicosDeGuia = {
  lista: MedicoDelDirectorio[]
  total: number
  whatsappHelios: string | null
}

const SIN_MEDICOS: MedicosDeGuia = { lista: [], total: 0, whatsappHelios: null }

/**
 * El `loader` de una guía del paciente. Si el directorio no contesta, la
 * guía sale igual, sin la franja: es un extra, no el contenido.
 */
export async function cargarMedicosDeGuia(ruta: RutaDeGuia): Promise<MedicosDeGuia> {
  const g: DatosDeGuia = GUIAS[ruta]
  const directorio = g.directorio
  if (!directorio) return SIN_MEDICOS
  const datos = await cargarDirectorio()
  if (datos.fallo) return SIN_MEDICOS
  const suyos = directorio.claves
    ? datos.medicos.filter((m) => clavesDelMedico(m).some((c) => directorio.claves?.includes(c)))
    : datos.medicos
  return { lista: suyos.slice(0, 6), total: suyos.length, whatsappHelios: datos.whatsappHelios }
}
