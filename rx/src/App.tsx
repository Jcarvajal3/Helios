import { useCallback, useEffect, useState } from 'react'
import { FilePlus2, History, LogOut, PenLine } from 'lucide-react'

import { datos, esDemo } from './datos/index.ts'
import type { Medicamento, Paciente, Perfil } from './modelo.ts'
import { Entrar } from './pantallas/Entrar.tsx'
import { Historial } from './pantallas/Historial.tsx'
import { MiRecipe } from './pantallas/MiRecipe.tsx'
import { Nuevo } from './pantallas/Nuevo.tsx'
import { useImagenes } from './recipe/util.ts'
import { Aviso, Boton, mensajeDe } from './ui.tsx'

type Vista = 'nuevo' | 'historial' | 'mi-recipe'

const VISTAS: Array<{ id: Vista; titulo: string; Icono: typeof FilePlus2 }> = [
  { id: 'nuevo', titulo: 'Nuevo', Icono: FilePlus2 },
  { id: 'historial', titulo: 'Historial', Icono: History },
  { id: 'mi-recipe', titulo: 'Mi récipe', Icono: PenLine },
]

function vistaDelHash(): Vista {
  const h = window.location.hash.replace(/^#\/?/, '')
  return VISTAS.some((v) => v.id === h) ? (h as Vista) : 'nuevo'
}

export interface Plantilla {
  paciente: Paciente
  medicamentos: Medicamento[]
  indicaciones: string
}

function Marca() {
  return (
    <span className="flex items-center gap-2">
      <span
        aria-hidden
        className="grid size-8 place-items-center rounded-medium bg-primary font-display text-[15px] font-bold tracking-tight text-on-primary"
      >
        Rx
      </span>
      <span className="font-display text-[19px] font-semibold tracking-tight">RX</span>
    </span>
  )
}

export function App() {
  const [estado, setEstado] = useState<'cargando' | 'fuera' | 'dentro' | 'sin-acceso'>('cargando')
  const [perfil, setPerfil] = useState<Perfil | null>(null)
  const [error, setError] = useState('')
  const [vista, setVista] = useState<Vista>(vistaDelHash)
  const [plantilla, setPlantilla] = useState<Plantilla | null>(null)
  const imagenes = useImagenes(perfil)

  useEffect(() => {
    const alCambiar = () => setVista(vistaDelHash())
    window.addEventListener('hashchange', alCambiar)
    return () => window.removeEventListener('hashchange', alCambiar)
  }, [])

  const cargarPerfil = useCallback(async () => {
    setEstado('cargando')
    setError('')
    try {
      setPerfil(await datos.perfil())
      setEstado('dentro')
    } catch (e) {
      setError(mensajeDe(e))
      setEstado('sin-acceso')
    }
  }, [])

  useEffect(() => {
    void datos.sesion().then((hay) => {
      if (hay) void cargarPerfil()
      else setEstado('fuera')
    })
  }, [cargarPerfil])

  const salir = async () => {
    await datos.salir()
    // El borrador lleva datos de un paciente: no se queda para quien entre después.
    try {
      sessionStorage.removeItem('rx:borrador')
    } catch {
      // Sin almacenamiento no había borrador.
    }
    setPerfil(null)
    setEstado('fuera')
  }

  const ir = (v: Vista) => {
    window.location.hash = `/${v}`
    window.scrollTo(0, 0)
  }

  const repetir = (p: Plantilla) => {
    setPlantilla(p)
    ir('nuevo')
  }

  if (estado === 'cargando') {
    return (
      <div className="grid min-h-dvh place-items-center" role="status" aria-label="Cargando">
        <div className="animate-pulse">
          <Marca />
        </div>
      </div>
    )
  }

  if (estado === 'fuera') return <Entrar marca={<Marca />} alEntrar={cargarPerfil} />

  if (estado === 'sin-acceso' || !perfil) {
    return (
      <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-4 px-4">
        <Marca />
        <Aviso>{error}</Aviso>
        <div className="flex gap-2">
          <Boton variante="secundario" onClick={() => void cargarPerfil()}>
            Reintentar
          </Boton>
          <Boton variante="texto" onClick={() => void salir()}>
            Salir
          </Boton>
        </div>
      </main>
    )
  }

  return (
    <div className="min-h-dvh pb-24 lg:pb-8">
      <header className="sticky top-0 z-20 border-b border-outline-variant/70 bg-surface/95 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-[1240px] items-center gap-3 px-4">
          <Marca />
          <nav aria-label="Principal" className="ml-auto flex items-center gap-1 sm:ml-5">
            {VISTAS.map(({ id, titulo, Icono }) => {
              const activa = vista === id
              return (
                <a
                  key={id}
                  href={`#/${id}`}
                  aria-current={activa ? 'page' : undefined}
                  className={`flex h-10 items-center gap-1.5 rounded-full px-3 text-[14px] font-semibold transition-colors sm:text-[15px] ${
                    activa ? 'bg-primary-container text-on-primary-container' : 'text-on-surface-variant hover:bg-surface-container-high'
                  }`}
                >
                  <Icono aria-hidden className="hidden size-4 sm:block" />
                  {titulo}
                </a>
              )
            })}
          </nav>
          <div className="ml-auto hidden items-center gap-2 sm:flex">
            {esDemo && (
              <span className="rounded-full bg-warning-container px-2.5 py-1 text-[13px] font-semibold text-on-warning-container">
                Demo
              </span>
            )}
            <span className="hidden max-w-56 truncate text-[14px] text-on-surface-variant md:block">{perfil.nombre}</span>
            <button
              type="button"
              onClick={() => void salir()}
              aria-label="Salir"
              title="Salir"
              className="grid size-10 place-items-center rounded-full text-on-surface-variant hover:bg-surface-container-high"
            >
              <LogOut aria-hidden className="size-4.5" />
            </button>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-[1240px] px-4 pt-5">
        {vista === 'nuevo' && (
          <Nuevo
            perfil={perfil}
            imagenes={imagenes}
            plantilla={plantilla}
            alConsumirPlantilla={() => setPlantilla(null)}
            alCambiarPerfil={setPerfil}
            alVerHistorial={() => ir('historial')}
          />
        )}
        {vista === 'historial' && (
          <Historial perfil={perfil} alRepetir={repetir} alNuevo={() => ir('nuevo')} />
        )}
        {vista === 'mi-recipe' && (
          <MiRecipe perfil={perfil} imagenes={imagenes} alCambiarPerfil={setPerfil} />
        )}
        <div className="mt-6 sm:hidden">
          <Boton variante="texto" icono={<LogOut aria-hidden className="size-4" />} onClick={() => void salir()}>
            Salir
          </Boton>
        </div>
      </main>
    </div>
  )
}
