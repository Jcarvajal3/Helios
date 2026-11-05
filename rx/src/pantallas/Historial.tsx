import { useEffect, useState } from 'react'
import { CheckCircle2, CopyPlus, Eye, FileText, Search, Send, TriangleAlert } from 'lucide-react'

import type { Plantilla } from '../App.tsx'
import { datos } from '../datos/index.ts'
import type { Perfil, Recipe } from '../modelo.ts'
import { fechaLatina } from '../recipe/pdf.ts'
import { guardarPdf, numeroLargo, pdfDe, verPdf } from '../recipe/util.ts'
import { Aviso, Boton, mensajeDe } from '../ui.tsx'
import { EnviarCorreo } from './EnviarCorreo.tsx'

function Envio({ recipe }: { recipe: Recipe }) {
  const envio = recipe.ultimo_envio
  if (!envio) return <span className="text-on-surface-faint">Sin enviar</span>
  if (envio.estado === 'fallido') {
    return (
      <span className="inline-flex items-center gap-1 text-error">
        <TriangleAlert aria-hidden className="size-3.5 shrink-0" />
        No salió a {envio.correo}
      </span>
    )
  }
  if (envio.estado === 'pendiente') return <span className="text-on-surface-faint">Enviando a {envio.correo}</span>
  return (
    <span className="inline-flex items-center gap-1 text-success">
      <CheckCircle2 aria-hidden className="size-3.5 shrink-0" />
      Enviado a {envio.correo}
    </span>
  )
}

function Fila({
  recipe,
  perfil,
  alRepetir,
  alCambiar,
}: {
  recipe: Recipe
  perfil: Perfil
  alRepetir: (p: Plantilla) => void
  alCambiar: () => void
}) {
  const [enviando, setEnviando] = useState(false)
  const [abriendo, setAbriendo] = useState(false)
  const [error, setError] = useState('')

  const ver = async () => {
    setAbriendo(true)
    setError('')
    try {
      verPdf(await pdfDe(recipe, perfil))
    } catch (e) {
      setError(mensajeDe(e))
    } finally {
      setAbriendo(false)
    }
  }

  const medicamentos = recipe.medicamentos.map((m) => m.medicamento).join(', ')

  return (
    <li className="px-4 py-3.5 sm:px-5">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-baseline gap-x-2">
            <span className="text-[16px] font-semibold">{recipe.paciente.nombre}</span>
            {recipe.paciente.documento && (
              <span className="text-[14px] text-on-surface-variant">{recipe.paciente.documento}</span>
            )}
          </div>
          <p className="mt-0.5 truncate text-[14px] text-on-surface-variant">{medicamentos}</p>
          <p className="mt-0.5 flex flex-wrap items-center gap-x-2 text-[13px] text-on-surface-faint">
            <span>N.º {numeroLargo(recipe.numero)}</span>
            <span aria-hidden>·</span>
            <span>{fechaLatina(recipe.fecha)}</span>
            <span aria-hidden>·</span>
            <Envio recipe={recipe} />
          </p>
        </div>
        <div className="-ml-2 flex shrink-0 flex-wrap items-center gap-0.5 sm:ml-0">
          <Boton variante="texto" className="px-3" cargando={abriendo} icono={<Eye aria-hidden className="size-4" />} onClick={() => void ver()}>
            Ver
          </Boton>
          <Boton variante="texto" className="px-3" icono={<Send aria-hidden className="size-4" />} aria-expanded={enviando} onClick={() => setEnviando((x) => !x)}>
            Enviar
          </Boton>
          <Boton
            variante="texto"
            className="px-3"
            icono={<CopyPlus aria-hidden className="size-4" />}
            title="Crear un récipe nuevo con estos datos"
            onClick={() =>
              alRepetir({
                paciente: recipe.paciente,
                medicamentos: recipe.medicamentos,
                indicaciones: recipe.indicaciones,
              })
            }
          >
            Repetir
          </Boton>
        </div>
      </div>
      {error && (
        <div className="mt-2">
          <Aviso>{error}</Aviso>
        </div>
      )}
      {enviando && (
        <div className="aparecer mt-3 rounded-medium bg-surface-container p-3">
          <EnviarCorreo
            recipeId={recipe.id}
            correoInicial={recipe.ultimo_envio?.correo || recipe.paciente.correo}
            antesDeEnviar={async () => {
              if (!recipe.pdf_path) await guardarPdf(recipe, perfil)
            }}
            alEnviar={alCambiar}
          />
        </div>
      )}
    </li>
  )
}

export function Historial({
  perfil,
  alRepetir,
  alNuevo,
}: {
  perfil: Perfil
  alRepetir: (p: Plantilla) => void
  alNuevo: () => void
}) {
  const [busqueda, setBusqueda] = useState('')
  const [recipes, setRecipes] = useState<Recipe[] | null>(null)
  const [error, setError] = useState('')
  const [vuelta, setVuelta] = useState(0)

  useEffect(() => {
    let vigente = true
    const espera = setTimeout(() => {
      datos
        .listar(busqueda.trim())
        .then((lista) => {
          if (!vigente) return
          setRecipes(lista)
          setError('')
        })
        .catch((e: unknown) => {
          if (vigente) setError(mensajeDe(e))
        })
    }, 250)
    return () => {
      vigente = false
      clearTimeout(espera)
    }
  }, [busqueda, vuelta])

  const sinNinguno = recipes?.length === 0 && !busqueda.trim()

  return (
    <div className="mx-auto flex max-w-3xl flex-col gap-4">
      <h1 className="text-[26px] font-semibold leading-tight tracking-tight">Historial</h1>

      {!sinNinguno && (
        <div className="relative">
          <Search aria-hidden className="pointer-events-none absolute left-3.5 top-1/2 size-4.5 -translate-y-1/2 text-on-surface-faint" />
          <input
            type="search"
            aria-label="Buscar por paciente, cédula o número"
            placeholder="Buscar por paciente, cédula o número"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
            className="h-11 w-full rounded-full border border-outline-variant bg-surface pl-10 pr-4 text-[16px] outline-none placeholder:text-placeholder focus:border-primary focus:ring-2 focus:ring-primary/15"
          />
        </div>
      )}

      {error && <Aviso>{error}</Aviso>}

      {recipes === null && !error && (
        <div className="flex flex-col gap-2" role="status" aria-label="Cargando">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-20 animate-pulse rounded-large bg-surface-container-high" />
          ))}
        </div>
      )}

      {sinNinguno && (
        <div className="flex flex-col items-center gap-3 rounded-large border border-dashed border-outline-variant px-4 py-12 text-center">
          <FileText aria-hidden className="size-8 text-on-surface-faint" />
          <p className="text-[16px] text-on-surface-variant">Aún no has emitido ningún récipe.</p>
          <Boton onClick={alNuevo}>Hacer el primero</Boton>
        </div>
      )}

      {recipes?.length === 0 && busqueda.trim() && (
        <p className="py-8 text-center text-[15px] text-on-surface-variant">Nada coincide con «{busqueda.trim()}».</p>
      )}

      {recipes && recipes.length > 0 && (
        <ul className="divide-y divide-outline-variant/70 rounded-large border border-outline-variant/70 bg-surface">
          {recipes.map((r) => (
            <Fila
              key={r.id}
              recipe={r}
              perfil={perfil}
              alRepetir={alRepetir}
              alCambiar={() => setVuelta((v) => v + 1)}
            />
          ))}
        </ul>
      )}
    </div>
  )
}
