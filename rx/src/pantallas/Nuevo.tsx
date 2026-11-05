import { useEffect, useMemo, useRef, useState } from 'react'
import { CheckCircle2, Download, Eye, FilePlus2, Plus, Trash2, X } from 'lucide-react'

import type { Plantilla } from '../App.tsx'
import { datos } from '../datos/index.ts'
import type { DatosRecipe, Medicamento, Paciente, Perfil, Recipe } from '../modelo.ts'
import { VistaPrevia } from '../recipe/VistaPrevia.tsx'
import {
  MEDICAMENTO_VACIO,
  PACIENTE_VACIO,
  bajarPdf,
  correoValido,
  datosDelRecipe,
  guardarPdf,
  hoyEnCaracas,
  numeroLargo,
  verPdf,
} from '../recipe/util.ts'
import type { UrlsDeImagenes } from '../recipe/util.ts'
import { AreaDeTexto, Aviso, Boton, Campo, Tarjeta, mensajeDe } from '../ui.tsx'
import { EnviarCorreo } from './EnviarCorreo.tsx'
import { SubirImagen } from './SubirImagen.tsx'

const MAX_MEDICAMENTOS = 20
const CLAVE_BORRADOR = 'rx:borrador'

interface Borrador {
  paciente: Paciente
  medicamentos: Medicamento[]
  indicaciones: string
}

const BORRADOR_VACIO: Borrador = {
  paciente: PACIENTE_VACIO,
  medicamentos: [MEDICAMENTO_VACIO],
  indicaciones: '',
}

// El borrador sobrevive a recargar y a ir a otra pestaña de RX, pero se va al
// cerrar la pestaña del navegador: lleva datos de un paciente.
function leerBorrador(): Borrador {
  try {
    const crudo = sessionStorage.getItem(CLAVE_BORRADOR)
    if (crudo) return { ...BORRADOR_VACIO, ...(JSON.parse(crudo) as Partial<Borrador>) }
  } catch {
    // Sin almacenamiento se empieza en blanco.
  }
  return BORRADOR_VACIO
}

function guardarBorrador(b: Borrador | null) {
  try {
    if (b) sessionStorage.setItem(CLAVE_BORRADOR, JSON.stringify(b))
    else sessionStorage.removeItem(CLAVE_BORRADOR)
  } catch {
    // Sin almacenamiento no hay borrador; la app sigue.
  }
}

interface Errores {
  nombre?: string
  correo?: string
  medicamentos?: string
}

export function Nuevo({
  perfil,
  imagenes,
  plantilla,
  alConsumirPlantilla,
  alCambiarPerfil,
  alVerHistorial,
}: {
  perfil: Perfil
  imagenes: UrlsDeImagenes
  plantilla: Plantilla | null
  alConsumirPlantilla: () => void
  alCambiarPerfil: (p: Perfil) => void
  alVerHistorial: () => void
}) {
  const [borrador, setBorrador] = useState<Borrador>(() => plantilla ?? leerBorrador())
  const [errores, setErrores] = useState<Errores>({})
  const [errorGeneral, setErrorGeneral] = useState('')
  const [emitiendo, setEmitiendo] = useState(false)
  const [emitido, setEmitido] = useState<Recipe | null>(null)
  const [previaAbierta, setPreviaAbierta] = useState(false)
  const [conocidos, setConocidos] = useState<Recipe[]>([])
  const idRef = useRef(crypto.randomUUID())
  const zonaFirma = useRef<HTMLDivElement>(null)

  const { paciente, medicamentos, indicaciones } = borrador

  useEffect(() => {
    if (plantilla) alConsumirPlantilla()
    // La plantilla se consume una sola vez, al montar.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    guardarBorrador(borrador)
  }, [borrador])

  useEffect(() => {
    datos.listar().then(setConocidos).catch(() => setConocidos([]))
  }, [emitido])

  // Sugerencias: solo de lo que este médico ya recetó y a quién.
  const pacientesConocidos = useMemo(() => {
    const vistos = new Map<string, Paciente>()
    for (const r of conocidos) {
      const clave = r.paciente.nombre.trim().toLowerCase()
      if (clave && !vistos.has(clave)) vistos.set(clave, r.paciente)
    }
    return [...vistos.values()]
  }, [conocidos])

  const medicamentosConocidos = useMemo(() => {
    const vistos = new Map<string, Medicamento>()
    for (const r of conocidos) {
      for (const m of r.medicamentos) {
        const clave = m.medicamento.trim().toLowerCase()
        if (clave && !vistos.has(clave)) vistos.set(clave, m)
      }
    }
    return [...vistos.values()]
  }, [conocidos])

  const cambiarPaciente = (campo: keyof Paciente, valor: string) => {
    setBorrador((b) => {
      let nuevo = { ...b.paciente, [campo]: valor }
      // Al escribir un paciente que ya atendió, se completa lo que falte.
      const buscado = valor.trim().toLowerCase()
      if (buscado && (campo === 'nombre' || campo === 'documento')) {
        const conocido = pacientesConocidos.find((p) => p[campo].trim().toLowerCase() === buscado)
        if (conocido) {
          nuevo = {
            nombre: nuevo.nombre || conocido.nombre,
            documento: nuevo.documento || conocido.documento,
            edad: nuevo.edad || conocido.edad,
            correo: nuevo.correo || conocido.correo,
          }
        }
      }
      return { ...b, paciente: nuevo }
    })
    setErrores((e) => ({ ...e, [campo]: undefined }))
  }

  const cambiarMedicamento = (i: number, campo: keyof Medicamento, valor: string) => {
    setBorrador((b) => ({
      ...b,
      medicamentos: b.medicamentos.map((m, j) => {
        if (j !== i) return m
        let nuevo = { ...m, [campo]: valor }
        if (campo === 'medicamento') {
          const conocido = medicamentosConocidos.find(
            (c) => c.medicamento.trim().toLowerCase() === valor.trim().toLowerCase(),
          )
          if (conocido) {
            nuevo = {
              ...nuevo,
              presentacion: nuevo.presentacion || conocido.presentacion,
              cantidad: nuevo.cantidad || conocido.cantidad,
              indicacion: nuevo.indicacion || conocido.indicacion,
            }
          }
        }
        return nuevo
      }),
    }))
    setErrores((e) => ({ ...e, medicamentos: undefined }))
  }

  const agregarMedicamento = () => {
    setBorrador((b) => ({ ...b, medicamentos: [...b.medicamentos, MEDICAMENTO_VACIO] }))
    // El campo nuevo aún no existe: se enfoca después de pintarlo.
    setTimeout(() => {
      document.querySelector<HTMLInputElement>(`[data-medicamento="${medicamentos.length}"]`)?.focus()
    })
  }

  const quitarMedicamento = (i: number) => {
    setBorrador((b) => ({ ...b, medicamentos: b.medicamentos.filter((_, j) => j !== i) }))
  }

  const empezarOtro = () => {
    idRef.current = crypto.randomUUID()
    setBorrador(BORRADOR_VACIO)
    setEmitido(null)
    setErrores({})
    setErrorGeneral('')
    window.scrollTo(0, 0)
  }

  const emitir = async () => {
    const errs: Errores = {}
    if (!paciente.nombre.trim()) errs.nombre = 'Escribe el nombre del paciente.'
    if (paciente.correo.trim() && !correoValido(paciente.correo)) errs.correo = 'Revisa el correo: parece incompleto.'
    const listos = medicamentos.filter((m) => m.medicamento.trim())
    if (listos.length === 0) errs.medicamentos = 'Agrega al menos un medicamento.'
    setErrores(errs)
    setErrorGeneral('')
    if (Object.keys(errs).length > 0) {
      setTimeout(() => document.querySelector<HTMLElement>('[aria-invalid="true"], [data-error-medicamentos]')?.scrollIntoView({ block: 'center', behavior: 'smooth' }))
      return
    }
    if (!perfil.firma_path) {
      setErrorGeneral('Sube tu firma antes de emitir el récipe.')
      zonaFirma.current?.scrollIntoView({ block: 'center', behavior: 'smooth' })
      return
    }
    setEmitiendo(true)
    try {
      const recipe = await datos.emitir(
        idRef.current,
        {
          nombre: paciente.nombre.trim(),
          documento: paciente.documento.trim(),
          edad: paciente.edad.trim(),
          correo: paciente.correo.trim(),
        },
        listos.map((m) => ({
          medicamento: m.medicamento.trim(),
          presentacion: m.presentacion.trim(),
          cantidad: m.cantidad.trim(),
          indicacion: m.indicacion.trim(),
        })),
        indicaciones.trim(),
      )
      guardarBorrador(null)
      setEmitido(recipe)
      window.scrollTo(0, 0)
    } catch (e) {
      setErrorGeneral(mensajeDe(e))
    } finally {
      setEmitiendo(false)
    }
  }

  const datosPrevia: DatosRecipe = {
    numero: null,
    fecha: hoyEnCaracas(),
    doctor: perfil,
    paciente,
    medicamentos,
    indicaciones,
  }

  const pedirFirma = () => {
    setPreviaAbierta(false)
    zonaFirma.current?.scrollIntoView({ block: 'center', behavior: 'smooth' })
  }

  if (emitido) {
    return (
      <Listo
        recipe={emitido}
        perfil={perfil}
        imagenes={imagenes}
        alNuevo={empezarOtro}
        alVerHistorial={alVerHistorial}
      />
    )
  }

  return (
    <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
      <div className="flex min-w-0 flex-col gap-4">
        <h1 className="text-[26px] font-semibold leading-tight tracking-tight">Nuevo récipe</h1>

        {!perfil.firma_path && (
          <div ref={zonaFirma} className="scroll-mt-20 rounded-large border border-primary/30 bg-primary-container/50 p-4">
            <h2 className="text-[16px] font-semibold">Primero, tu firma</h2>
            <p className="mb-3 mt-1 text-[15px] text-on-surface-variant">
              Sube una foto de tu firma en papel blanco. Le quitamos el fondo y la ponemos en cada récipe.
            </p>
            <SubirImagen tipo="firma" tieneImagen={false} variante="primario" alCambiarPerfil={alCambiarPerfil} />
          </div>
        )}

        <Tarjeta titulo="Paciente">
          <div className="grid gap-4 sm:grid-cols-6">
            <Campo
              etiqueta="Nombre y apellido"
              obligatorio
              className="sm:col-span-6"
              autoComplete="off"
              list="rx-pacientes"
              value={paciente.nombre}
              error={errores.nombre}
              onChange={(e) => cambiarPaciente('nombre', e.target.value)}
            />
            <datalist id="rx-pacientes">
              {pacientesConocidos.map((p) => (
                <option key={p.nombre} value={p.nombre}>
                  {p.documento}
                </option>
              ))}
            </datalist>
            <Campo
              etiqueta="Cédula"
              className="sm:col-span-2"
              autoComplete="off"
              maxLength={20}
              placeholder="V-12345678"
              value={paciente.documento}
              onChange={(e) => cambiarPaciente('documento', e.target.value)}
            />
            <Campo
              etiqueta="Edad"
              className="sm:col-span-1"
              autoComplete="off"
              maxLength={20}
              value={paciente.edad}
              onChange={(e) => cambiarPaciente('edad', e.target.value)}
            />
            <Campo
              etiqueta="Correo"
              className="sm:col-span-3"
              type="email"
              inputMode="email"
              autoComplete="off"
              ayuda="Para enviarle el récipe."
              value={paciente.correo}
              error={errores.correo}
              onChange={(e) => cambiarPaciente('correo', e.target.value)}
            />
          </div>
        </Tarjeta>

        <Tarjeta titulo="Medicamentos">
          <datalist id="rx-medicamentos">
            {medicamentosConocidos.map((m) => (
              <option key={m.medicamento} value={m.medicamento} />
            ))}
          </datalist>
          <div className="flex flex-col gap-5">
            {medicamentos.map((m, i) => (
              <fieldset key={i} className="relative border-t border-outline-variant/70 pt-4 first:border-t-0 first:pt-0">
                <legend className="sr-only">Medicamento {i + 1}</legend>
                <div className="grid gap-3 sm:grid-cols-2">
                  <div className="flex items-end gap-2 sm:col-span-2">
                    <Campo
                      etiqueta={medicamentos.length > 1 ? `Medicamento ${i + 1}` : 'Medicamento'}
                      obligatorio
                      className="min-w-0 flex-1"
                      autoComplete="off"
                      list="rx-medicamentos"
                      placeholder="Amoxicilina 500 mg"
                      maxLength={160}
                      data-medicamento={i}
                      value={m.medicamento}
                      onChange={(e) => cambiarMedicamento(i, 'medicamento', e.target.value)}
                    />
                    {medicamentos.length > 1 && (
                      <button
                        type="button"
                        aria-label={`Quitar medicamento ${i + 1}`}
                        title="Quitar"
                        onClick={() => quitarMedicamento(i)}
                        className="grid size-11 shrink-0 place-items-center rounded-full text-on-surface-variant hover:bg-error-container hover:text-error"
                      >
                        <Trash2 aria-hidden className="size-4.5" />
                      </button>
                    )}
                  </div>
                  <Campo
                    etiqueta="Presentación"
                    autoComplete="off"
                    placeholder="Cápsulas"
                    maxLength={80}
                    value={m.presentacion}
                    onChange={(e) => cambiarMedicamento(i, 'presentacion', e.target.value)}
                  />
                  <Campo
                    etiqueta="Cantidad"
                    autoComplete="off"
                    placeholder="1 caja"
                    maxLength={80}
                    value={m.cantidad}
                    onChange={(e) => cambiarMedicamento(i, 'cantidad', e.target.value)}
                  />
                  <AreaDeTexto
                    etiqueta="Cómo tomarlo"
                    className="sm:col-span-2"
                    rows={2}
                    maxLength={500}
                    placeholder="1 cápsula cada 8 horas por 7 días"
                    value={m.indicacion}
                    onChange={(e) => cambiarMedicamento(i, 'indicacion', e.target.value)}
                  />
                </div>
              </fieldset>
            ))}
          </div>
          {errores.medicamentos && (
            <p role="alert" data-error-medicamentos className="mt-3 text-[14px] text-error">
              {errores.medicamentos}
            </p>
          )}
          {medicamentos.length < MAX_MEDICAMENTOS && (
            <Boton
              variante="texto"
              className="-ml-2 mt-3"
              icono={<Plus aria-hidden className="size-4" />}
              onClick={agregarMedicamento}
            >
              Agregar otro medicamento
            </Boton>
          )}
        </Tarjeta>

        <Tarjeta titulo="Indicaciones generales" detalle="Opcional. Reposo, dieta, control, lo que aplique a todo el tratamiento.">
          <AreaDeTexto
            etiqueta="Indicaciones generales"
            rows={3}
            maxLength={2000}
            className="[&>label]:sr-only"
            value={indicaciones}
            onChange={(e) => setBorrador((b) => ({ ...b, indicaciones: e.target.value }))}
          />
        </Tarjeta>

        {errorGeneral && <Aviso>{errorGeneral}</Aviso>}

        <div className="hidden lg:block">
          <Boton cargando={emitiendo} className="w-full" onClick={() => void emitir()}>
            Emitir récipe
          </Boton>
          <p className="mt-2 text-center text-[14px] text-on-surface-faint">
            Después de emitirlo podrás enviarlo por correo. Un récipe emitido ya no se edita.
          </p>
        </div>
      </div>

      <aside aria-label="Vista previa" className="sticky top-[72px] hidden max-h-[calc(100dvh-88px)] overflow-y-auto p-1 lg:block">
        <p className="mb-2 text-[14px] font-semibold text-on-surface-variant">Así se verá</p>
        <VistaPrevia datos={datosPrevia} firmaUrl={imagenes.firmaUrl} logoUrl={imagenes.logoUrl} alPedirFirma={pedirFirma} />
      </aside>

      {/* En el teléfono, las dos acciones siempre a mano. */}
      <div className="fixed inset-x-0 bottom-0 z-20 flex gap-2 border-t border-outline-variant/70 bg-surface px-4 pb-[max(env(safe-area-inset-bottom),12px)] pt-3 lg:hidden">
        <Boton
          variante="secundario"
          className="shrink-0"
          icono={<Eye aria-hidden className="size-4" />}
          onClick={() => setPreviaAbierta(true)}
        >
          Ver
        </Boton>
        <Boton cargando={emitiendo} className="flex-1" onClick={() => void emitir()}>
          Emitir récipe
        </Boton>
      </div>

      {previaAbierta && (
        <div role="dialog" aria-modal="true" aria-label="Vista previa" className="fixed inset-0 z-30 overflow-y-auto bg-surface-container-highest p-4 lg:hidden">
          <div className="mb-3 flex items-center justify-between">
            <h2 className="text-[18px] font-semibold">Así se verá</h2>
            <button
              type="button"
              autoFocus
              aria-label="Cerrar vista previa"
              onClick={() => setPreviaAbierta(false)}
              className="grid size-11 place-items-center rounded-full bg-surface"
            >
              <X aria-hidden className="size-5" />
            </button>
          </div>
          <VistaPrevia datos={datosPrevia} firmaUrl={imagenes.firmaUrl} logoUrl={imagenes.logoUrl} alPedirFirma={pedirFirma} />
        </div>
      )}
    </div>
  )
}

function Listo({
  recipe,
  perfil,
  imagenes,
  alNuevo,
  alVerHistorial,
}: {
  recipe: Recipe
  perfil: Perfil
  imagenes: UrlsDeImagenes
  alNuevo: () => void
  alVerHistorial: () => void
}) {
  const [pdf, setPdf] = useState<Uint8Array | null>(null)
  const [error, setError] = useState('')
  const empezado = useRef(false)

  const guardar = async () => {
    setError('')
    try {
      setPdf(await guardarPdf(recipe, perfil))
    } catch (e) {
      setError(mensajeDe(e))
    }
  }

  useEffect(() => {
    if (empezado.current) return
    empezado.current = true
    void guardar()
    // Una vez por récipe; los reintentos van por el botón.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
      <div className="aparecer flex min-w-0 flex-col gap-4">
        <div className="flex items-start gap-3">
          <CheckCircle2 aria-hidden className="mt-0.5 size-8 shrink-0 text-success" />
          <div>
            <h1 className="text-[26px] font-semibold leading-tight tracking-tight">Récipe listo</h1>
            <p className="mt-1 text-[16px] text-on-surface-variant">
              N.º {numeroLargo(recipe.numero)} para {recipe.paciente.nombre}
            </p>
          </div>
        </div>

        {error && (
          <Aviso>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span>{error}</span>
              <button type="button" className="font-semibold underline" onClick={() => void guardar()}>
                Reintentar
              </button>
            </div>
          </Aviso>
        )}

        <Tarjeta
          titulo="Enviar por correo"
          detalle={
            perfil.correo
              ? `Le llega con el PDF adjunto. Si responde, la respuesta te llega a ${perfil.correo}.`
              : 'Le llega con el PDF adjunto.'
          }
        >
          <EnviarCorreo recipeId={recipe.id} correoInicial={recipe.paciente.correo} listoParaEnviar={Boolean(pdf)} />
        </Tarjeta>

        <div className="flex flex-wrap gap-2">
          <Boton
            variante="secundario"
            disabled={!pdf}
            icono={<Eye aria-hidden className="size-4" />}
            onClick={() => pdf && verPdf(pdf)}
          >
            Ver PDF
          </Boton>
          <Boton
            variante="secundario"
            disabled={!pdf}
            icono={<Download aria-hidden className="size-4" />}
            onClick={() => pdf && bajarPdf(pdf, recipe.numero)}
          >
            Descargar
          </Boton>
        </div>

        <div className="flex flex-wrap gap-2 border-t border-outline-variant/70 pt-4">
          <Boton icono={<FilePlus2 aria-hidden className="size-4" />} onClick={alNuevo}>
            Nuevo récipe
          </Boton>
          <Boton variante="texto" onClick={alVerHistorial}>
            Ver historial
          </Boton>
        </div>
      </div>

      <aside aria-label="El récipe emitido" className="p-1 lg:sticky lg:top-[72px] lg:max-h-[calc(100dvh-88px)] lg:overflow-y-auto">
        <VistaPrevia datos={datosDelRecipe(recipe, perfil)} firmaUrl={imagenes.firmaUrl} logoUrl={imagenes.logoUrl} />
      </aside>
    </div>
  )
}
