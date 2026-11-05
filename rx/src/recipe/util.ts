import { useEffect, useState } from 'react'

import { datos } from '../datos/index.ts'
import type { DatosRecipe, ImagenesRecipe, Medicamento, Paciente, Perfil, Recipe } from '../modelo.ts'
import { generarPdf, nombreDelArchivo } from './pdf.ts'

export const PACIENTE_VACIO: Paciente = { nombre: '', documento: '', edad: '', correo: '' }
export const MEDICAMENTO_VACIO: Medicamento = { medicamento: '', presentacion: '', cantidad: '', indicacion: '' }

export function hoyEnCaracas(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Caracas' }).format(new Date())
}

export function correoValido(correo: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(correo.trim())
}

export function datosDelRecipe(recipe: Recipe, perfil: Perfil): DatosRecipe {
  return {
    numero: recipe.numero,
    fecha: recipe.fecha,
    doctor: perfil,
    paciente: recipe.paciente,
    medicamentos: recipe.medicamentos,
    indicaciones: recipe.indicaciones,
  }
}

export function numeroLargo(numero: number): string {
  return String(numero).padStart(6, '0')
}

/** Genera el PDF de un récipe emitido y lo deja guardado. Se puede reintentar. */
export async function guardarPdf(recipe: Recipe, perfil: Perfil): Promise<Uint8Array> {
  const imagenes = await datos.imagenes(perfil)
  const pdf = await generarPdf(datosDelRecipe(recipe, perfil), imagenes)
  await datos.adjuntarPdf(recipe.id, pdf)
  return pdf
}

/** El PDF guardado; si quedó sin guardar en su momento, lo genera ahora. */
export async function pdfDe(recipe: Recipe, perfil: Perfil): Promise<Uint8Array> {
  return recipe.pdf_path ? datos.descargarPdf(recipe.pdf_path) : guardarPdf(recipe, perfil)
}

function urlDe(pdf: Uint8Array): string {
  return URL.createObjectURL(new Blob([pdf.slice()], { type: 'application/pdf' }))
}

export function verPdf(pdf: Uint8Array) {
  const url = urlDe(pdf)
  window.open(url, '_blank', 'noopener')
  setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

export function bajarPdf(pdf: Uint8Array, numero: number | null) {
  const url = urlDe(pdf)
  const a = document.createElement('a')
  a.href = url
  a.download = nombreDelArchivo(numero)
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

export interface UrlsDeImagenes {
  firmaUrl: string | null
  logoUrl: string | null
}

function urlDeImagen(bytes: Uint8Array | null): string | null {
  return bytes ? URL.createObjectURL(new Blob([bytes.slice()])) : null
}

/** Las imágenes del perfil para pintarlas en la vista previa. */
export function useImagenes(perfil: Perfil | null): UrlsDeImagenes {
  const [urls, setUrls] = useState<UrlsDeImagenes>({ firmaUrl: null, logoUrl: null })
  const firma = perfil?.firma_path
  const logo = perfil?.logo_path
  const logoHelios = perfil?.logo_helios_url

  useEffect(() => {
    if (!perfil) return
    let vigente = true
    let creadas: UrlsDeImagenes | null = null
    datos
      .imagenes(perfil)
      .catch((): ImagenesRecipe => ({ firma: null, logo: null }))
      .then((imagenes) => {
        if (!vigente) return
        creadas = { firmaUrl: urlDeImagen(imagenes.firma), logoUrl: urlDeImagen(imagenes.logo) }
        setUrls(creadas)
      })
    return () => {
      vigente = false
      if (creadas?.firmaUrl) URL.revokeObjectURL(creadas.firmaUrl)
      if (creadas?.logoUrl) URL.revokeObjectURL(creadas.logoUrl)
    }
    // Solo cambian si cambia alguna de las tres rutas, no con cada dato del perfil.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [firma, logo, logoHelios])

  return urls
}
