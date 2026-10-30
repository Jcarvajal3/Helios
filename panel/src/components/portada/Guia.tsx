import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'
import { ArrowUpRight, ChevronRight } from 'lucide-react'

import { CONSULTA, dinero, dineroCorto } from './datos'
import { Preguntas, Pie } from './Final'
import { CALENDARIO_DE_COBRO, GUIAS, NOMBRE_DE_RUTA, TABLA_DE_CUOTAS } from './guias'
import type { Guia as DatosDeGuia, RutaDeGuia } from './guias'
import { LineaDeCobro } from './Medicos'
import { Menu } from './Menu'
import { Desglose } from './Pacientes'
import { Boton, BotonAfiliarme, Lienzo, Revelar, Rotulo } from './piezas'
import { REDES, cabeceraPublica, preguntasFrecuentes, servicio } from '@/config/sitio'

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
 *   Aparte       en las especialidades, unas líneas para el médico
 *   Preguntas    las suyas, también en el JSON-LD
 *   Relacionadas enlaces a las otras páginas (enlazado interno)
 *   Cierre       la llamada a la acción
 *
 * El texto vive en `guias.ts`. Cada ruta es un fichero de tres líneas:
 * `head: () => cabeceraDeGuia(ruta)` y `component: () => <Guia ruta=… />`.
 */

const NOCHE = '#020B24'

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

export function Guia({ ruta }: { ruta: RutaDeGuia }) {
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
        {g.aparte && <Aparte {...g.aparte} />}
        <Preguntas
          lista={g.preguntas}
          titular={{ antes: 'Preguntas', enfasis: 'frecuentes.' }}
        />
        <Relacionadas rutas={g.relacionadas} />
        <Cierre publico={g.publico} />
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

function Cabecera({ guia: g }: { guia: DatosDeGuia }) {
  return (
    <section className="relative isolate overflow-hidden bg-white">
      <div
        aria-hidden
        className="portada-aurora absolute -right-[25%] -top-[30%] -z-10 size-[900px] rounded-full"
      />
      <Lienzo className="pb-20 pt-32 sm:pb-28 sm:pt-40">
        <Migas nombre={g.nombre} />
        <div className="mt-10 grid gap-14 lg:grid-cols-[minmax(0,1fr)_minmax(0,0.9fr)] lg:items-center lg:gap-16">
          <div>
            <Rotulo>{g.rotulo}</Rotulo>
            <h1 className="portada-titular mt-6 text-portada-tinta">
              {g.h1.antes}{' '}
              <em className="portada-serif portada-degradado pr-[0.06em]">
                {g.h1.enfasis}
              </em>
            </h1>
            <p className="portada-entrada mt-7 max-w-[52ch] text-portada-tinta-2">
              {g.entrada}
            </p>
            <div className="mt-9 flex flex-wrap gap-3">
              {g.publico === 'medico' ? (
                <>
                  <BotonAfiliarme />
                  <Boton to="/login" tono="contorno">
                    Entrar a la plataforma
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
            </div>
          </div>

          {g.publico === 'medico' ? (
            <div
              className="rounded-[32px] p-2 sm:rounded-[40px]"
              style={{ backgroundColor: NOCHE }}
            >
              <LineaDeCobro />
            </div>
          ) : (
            <Desglose />
          )}
        </div>
      </Lienzo>
    </section>
  )
}

/** La respuesta corta, en una lista de definiciones: lo que se busca, sin rodeos. */
function Resumen({ guia: g }: { guia: DatosDeGuia }) {
  return (
    <section aria-labelledby="resumen" className="relative bg-white">
      <Lienzo className="pb-20 sm:pb-24">
        <h2 id="resumen" className="portada-etiqueta text-portada-tinta-3">
          En resumen
        </h2>
        <dl className="mt-6 grid overflow-hidden rounded-[28px] border border-portada-linea sm:grid-cols-2 lg:grid-cols-3">
          {g.resumen.map((d) => (
            <div
              key={d.termino}
              className="-mb-px -mr-px border-b border-r border-portada-linea px-6 py-5"
            >
              <dt className="text-[0.85rem] text-portada-tinta-3">{d.termino}</dt>
              <dd className="mt-1.5 text-[1.02rem] font-medium leading-snug tracking-[-0.015em] text-portada-tinta">
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
    <section className="relative border-t border-portada-linea bg-white">
      <Lienzo className="py-24 sm:py-32">
        <Revelar>
          <Rotulo>{rotulo}</Rotulo>
          <h2 className="portada-titular mt-6 max-w-[20ch] text-portada-tinta">
            {titular.antes}{' '}
            <em className="portada-serif text-portada-azul">{titular.enfasis}</em>
          </h2>
        </Revelar>
        <Revelar retraso={80}>
          <div className="mt-12 overflow-x-auto rounded-[28px] border border-portada-linea">
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
      nota="En dólares o en euros, según la moneda de tu consulta (en euros, las mismas cifras en €). Pagas cada cuota en bolívares, a la tasa oficial del BCV del día en que pagas."
    >
      <table className="w-full min-w-[34rem] border-collapse text-[0.97rem]">
        <caption className="sr-only">
          Lo que pagas en cuotas con Helios según el monto de la consulta
        </caption>
        <thead>
          <tr>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Consulta</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Comisión Helios + IVA</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Total</th>
            <th scope="col" className={`${CELDA} ${CABECERA_DE_TABLA}`}>Cada cuota (días 7 y 14)</th>
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
              <td className={`${CELDA} font-medium text-portada-azul`}>{dinero(f.cuota)}</td>
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
            <em className="portada-serif text-portada-azul">
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
              className="rounded-[28px] border border-portada-linea bg-white p-7"
            >
              <span className="portada-etiqueta text-portada-tinta-3">
                0{i + 1}
              </span>
              <h3 className="mt-8 text-[1.2rem] font-medium leading-snug tracking-[-0.02em] text-portada-tinta">
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
            <em className="portada-serif text-portada-azul">
              {g.ventajas.titulo.enfasis}
            </em>
          </h2>
        </Revelar>
        <ul className="mt-14 grid gap-x-10 gap-y-12 sm:grid-cols-2 lg:grid-cols-3">
          {g.ventajas.lista.map((v, i) => (
            <Revelar
              key={v.titulo}
              como="li"
              retraso={(i % 3) * 80}
              className="border-t border-portada-linea pt-6"
            >
              <h3 className="text-[1.12rem] font-medium leading-snug tracking-[-0.02em] text-portada-tinta">
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
      <div
        className="relative overflow-hidden rounded-[32px] sm:rounded-[44px]"
        style={{ backgroundColor: NOCHE }}
      >
        <Lienzo className="flex flex-col gap-8 py-16 sm:py-20 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <Rotulo tono="oscuro">Para médicos y centros</Rotulo>
            <h2 className="mt-5 text-[clamp(1.7rem,1.2rem+1.8vw,2.6rem)] font-medium leading-tight tracking-[-0.04em] text-white">
              {titulo}
            </h2>
            <p className="mt-4 max-w-[52ch] text-[1.02rem] leading-relaxed text-white/70">
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
        <h2 className="portada-etiqueta text-portada-tinta-3">
          También te puede interesar
        </h2>
        <ul className="mt-6 grid gap-3 sm:grid-cols-3">
          {rutas.map((r) => (
            <li key={r}>
              <Link
                to={r}
                className="group flex h-full items-center justify-between gap-4 rounded-[22px] border border-portada-linea bg-white px-6 py-5 text-[1.06rem] font-medium tracking-[-0.02em] text-portada-tinta transition-[border-color,box-shadow] duration-300 hover:border-portada-azul/30 hover:shadow-[0_24px_50px_-30px_rgba(0,39,112,0.3)]"
              >
                {NOMBRE_DE_RUTA[r]}
                <ArrowUpRight className="size-4 shrink-0 text-portada-azul transition-transform duration-300 group-hover:-translate-y-0.5 group-hover:translate-x-0.5" />
              </Link>
            </li>
          ))}
        </ul>
      </Lienzo>
    </section>
  )
}

function Cierre({ publico }: { publico: DatosDeGuia['publico'] }) {
  return (
    <section className="relative isolate overflow-hidden border-t border-portada-linea bg-portada-niebla">
      <Lienzo className="flex flex-col items-center py-24 text-center sm:py-32">
        <Rotulo>Medicina · Odontología · Cosmetología</Rotulo>
        <h2 className="portada-titular mt-6 max-w-[16ch] text-portada-tinta">
          {publico === 'medico' ? (
            <>
              Afilia tu consultorio,{' '}
              <em className="portada-serif portada-degradado pr-[0.06em]">
                sin costo.
              </em>
            </>
          ) : (
            <>
              Pregunta por Helios{' '}
              <em className="portada-serif portada-degradado pr-[0.06em]">
                en tu próxima consulta.
              </em>
            </>
          )}
        </h2>
        <div className="mt-10 flex flex-wrap justify-center gap-3">
          {publico === 'medico' ? (
            <>
              <BotonAfiliarme />
              <Boton to="/pacientes" tono="contorno">
                Lo que ve tu paciente
              </Boton>
            </>
          ) : (
            <>
              <Boton to="/medicos">Soy médico</Boton>
              {REDES.map((r) => (
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
