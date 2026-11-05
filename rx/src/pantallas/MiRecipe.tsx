import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { Check } from 'lucide-react'

import { datos } from '../datos/index.ts'
import type { DatosEditables, DatosRecipe, Perfil } from '../modelo.ts'
import { VistaPrevia } from '../recipe/VistaPrevia.tsx'
import { correoValido, hoyEnCaracas } from '../recipe/util.ts'
import type { UrlsDeImagenes } from '../recipe/util.ts'
import { Aviso, Boton, Campo, Tarjeta, mensajeDe } from '../ui.tsx'
import { SubirImagen } from './SubirImagen.tsx'

function editables(p: Perfil): DatosEditables {
  return {
    especialidad: p.especialidad,
    cedula: p.cedula,
    mpps: p.mpps,
    colegio: p.colegio,
    telefono: p.telefono,
    correo: p.correo,
    direccion: p.direccion,
    ciudad: p.ciudad,
    consultorio: p.consultorio,
  }
}

const EJEMPLO = {
  paciente: { nombre: 'Nombre del paciente', documento: 'V-12345678', edad: '35', correo: '' },
  medicamentos: [
    {
      medicamento: 'Nombre del medicamento',
      presentacion: 'Presentación',
      cantidad: 'Cantidad',
      indicacion: 'Cómo tomarlo',
    },
  ],
}

export function MiRecipe({
  perfil,
  imagenes,
  alCambiarPerfil,
}: {
  perfil: Perfil
  imagenes: UrlsDeImagenes
  alCambiarPerfil: (p: Perfil) => void
}) {
  const [form, setForm] = useState<DatosEditables>(() => editables(perfil))
  const [guardando, setGuardando] = useState(false)
  const [guardado, setGuardado] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!guardado) return
    const t = setTimeout(() => setGuardado(false), 3000)
    return () => clearTimeout(t)
  }, [guardado])

  const cambiado = (Object.keys(form) as Array<keyof DatosEditables>).some((k) => form[k] !== perfil[k])

  const campo = (clave: keyof DatosEditables) => ({
    value: form[clave],
    onChange: (e: { target: { value: string } }) => {
      setForm((f) => ({ ...f, [clave]: e.target.value }))
      setGuardado(false)
    },
  })

  const guardar = async (e: FormEvent) => {
    e.preventDefault()
    if (form.correo.trim() && !correoValido(form.correo)) {
      setError('Revisa el correo: parece incompleto.')
      return
    }
    setGuardando(true)
    setError('')
    try {
      const nuevo = await datos.guardarDatos(form)
      alCambiarPerfil(nuevo)
      setForm(editables(nuevo))
      setGuardado(true)
    } catch (err) {
      setError(mensajeDe(err))
    } finally {
      setGuardando(false)
    }
  }

  const previa: DatosRecipe = {
    numero: null,
    fecha: hoyEnCaracas(),
    doctor: { ...perfil, ...form },
    paciente: EJEMPLO.paciente,
    medicamentos: EJEMPLO.medicamentos,
    indicaciones: '',
  }

  const logoDeHelios = !perfil.logo_path && Boolean(perfil.logo_helios_url)

  return (
    <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_420px]">
      <div className="flex min-w-0 flex-col gap-4">
        <h1 className="text-[26px] font-semibold leading-tight tracking-tight">Mi récipe</h1>

        <div className="grid gap-4 sm:grid-cols-2">
          <Tarjeta titulo="Firma" detalle="Una foto en papel blanco sirve: le quitamos el fondo.">
            <div className="mb-3 grid h-24 place-items-center rounded-medium border border-dashed border-outline-variant bg-white p-2">
              {imagenes.firmaUrl ? (
                <img src={imagenes.firmaUrl} alt="Tu firma" className="max-h-full max-w-full object-contain" />
              ) : (
                <span className="text-[14px] text-on-surface-faint">Sin firma</span>
              )}
            </div>
            <SubirImagen tipo="firma" tieneImagen={Boolean(perfil.firma_path)} alCambiarPerfil={alCambiarPerfil} />
          </Tarjeta>

          <Tarjeta
            titulo="Logo"
            detalle={logoDeHelios ? 'Usamos el de tu ficha en Helios. Puedes poner otro.' : 'De la clínica o el consultorio. Es opcional.'}
          >
            <div className="mb-3 grid h-24 place-items-center rounded-medium border border-dashed border-outline-variant bg-white p-2">
              {imagenes.logoUrl ? (
                <img src={imagenes.logoUrl} alt="Tu logo" className="max-h-full max-w-full object-contain" />
              ) : (
                <span className="text-[14px] text-on-surface-faint">Sin logo</span>
              )}
            </div>
            <SubirImagen tipo="logo" tieneImagen={Boolean(perfil.logo_path)} alCambiarPerfil={alCambiarPerfil} />
          </Tarjeta>
        </div>

        <Tarjeta titulo="Tus datos" detalle="Vienen de tu ficha en Helios. Lo que cambies aquí solo se usa en tus récipes.">
          <form onSubmit={(e) => void guardar(e)} noValidate className="grid gap-4 sm:grid-cols-2">
            <Campo
              etiqueta="Nombre"
              className="sm:col-span-2"
              value={perfil.nombre}
              disabled
              ayuda="Si hay un error, escríbele a soporte de Helios."
            />
            <Campo etiqueta="Especialidad" className="sm:col-span-2" autoComplete="off" maxLength={120} {...campo('especialidad')} />
            <Campo etiqueta="Cédula" autoComplete="off" maxLength={30} {...campo('cedula')} />
            <Campo etiqueta="MPPS" autoComplete="off" maxLength={30} {...campo('mpps')} />
            <Campo etiqueta="Colegio de Médicos (C.M.)" autoComplete="off" maxLength={30} {...campo('colegio')} />
            <Campo etiqueta="Teléfono" type="tel" autoComplete="off" maxLength={40} {...campo('telefono')} />
            <Campo
              etiqueta="Correo"
              className="sm:col-span-2"
              type="email"
              autoComplete="off"
              ayuda="Las respuestas de los pacientes llegan aquí."
              maxLength={160}
              {...campo('correo')}
            />
            <Campo etiqueta="Consultorio" autoComplete="off" maxLength={120} {...campo('consultorio')} />
            <Campo etiqueta="Ciudad" autoComplete="off" maxLength={80} {...campo('ciudad')} />
            <Campo etiqueta="Dirección" className="sm:col-span-2" autoComplete="off" maxLength={240} {...campo('direccion')} />
            {error && (
              <div className="sm:col-span-2">
                <Aviso>{error}</Aviso>
              </div>
            )}
            <div className="flex items-center gap-3 sm:col-span-2">
              <Boton type="submit" cargando={guardando} disabled={!cambiado}>
                Guardar
              </Boton>
              {guardado && (
                <span role="status" className="aparecer inline-flex items-center gap-1 text-[15px] font-semibold text-success">
                  <Check aria-hidden className="size-4" />
                  Guardado
                </span>
              )}
            </div>
          </form>
        </Tarjeta>
      </div>

      <aside aria-label="Vista previa" className="p-1 lg:sticky lg:top-[72px] lg:max-h-[calc(100dvh-88px)] lg:overflow-y-auto">
        <p className="mb-2 text-[14px] font-semibold text-on-surface-variant">Así se verá</p>
        <VistaPrevia datos={previa} firmaUrl={imagenes.firmaUrl} logoUrl={imagenes.logoUrl} />
      </aside>
    </div>
  )
}
