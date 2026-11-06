import type { Datos, Perfil, Recipe } from '../modelo.ts'

// ═══════════════════════════════════════════════════════════════════════════
// `npm run demo`: la app entera con datos de mentira, en memoria de este
// navegador. No toca la base ni manda correos. Solo existe en ese modo: el
// build de producción no incluye este archivo.
// ═══════════════════════════════════════════════════════════════════════════

const espera = (ms = 250) => new Promise((r) => setTimeout(r, ms))

let dentro = true
const archivos = new Map<string, Uint8Array>()
const recipes: Recipe[] = []
let ultimoNumero = 127

let perfil: Perfil = {
  merchant_id: 'demo',
  nombre: 'Dra. Ana Lara',
  especialidad: 'Dermatología',
  cedula: 'V-14.235.678',
  mpps: '58.214',
  colegio: '12.907',
  telefono: '0412-555-0134',
  correo: 'consultas@ejemplo.com',
  direccion: 'Av. Francisco de Miranda, Torre Médica, piso 4, consultorio 4-B',
  ciudad: 'Caracas',
  consultorio: 'Consultorio Lara',
  logo_helios_url: '',
  firma_path: '',
  logo_path: '',
}

function hoyEnCaracas(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Caracas' }).format(new Date())
}

export const datosDemo: Datos = {
  async sesion() {
    return dentro
  },
  async entrar() {
    await espera()
    dentro = true
  },
  async salir() {
    dentro = false
  },
  async perfil() {
    await espera(100)
    return perfil
  },
  async guardarDatos(datos) {
    await espera()
    perfil = { ...perfil, ...datos }
    return perfil
  },
  async subirImagen(tipo, png) {
    await espera()
    const ruta = `demo/${tipo}/${Date.now()}.png`
    archivos.set(ruta, new Uint8Array(await png.arrayBuffer()))
    perfil = { ...perfil, [`${tipo}_path`]: ruta }
    return perfil
  },
  async quitarImagen(tipo) {
    await espera()
    perfil = { ...perfil, [`${tipo}_path`]: '' }
    return perfil
  },
  async imagenes(p) {
    return {
      firma: archivos.get(p.firma_path) ?? null,
      logo: archivos.get(p.logo_path) ?? null,
    }
  },
  async emitir(id, paciente, medicamentos, indicaciones) {
    await espera()
    const ya = recipes.find((r) => r.id === id)
    if (ya) return ya
    if (!perfil.firma_path) throw new Error('Sube tu firma antes de emitir el récipe.')
    const recipe: Recipe = {
      id,
      numero: ++ultimoNumero,
      fecha: hoyEnCaracas(),
      paciente,
      medicamentos,
      indicaciones,
      pdf_path: '',
      created_at: new Date().toISOString(),
      ultimo_envio: null,
    }
    recipes.unshift(recipe)
    return recipe
  },
  async adjuntarPdf(id, pdf) {
    await espera()
    const ruta = `demo/recipes/${id}.pdf`
    archivos.set(ruta, pdf)
    const r = recipes.find((x) => x.id === id)
    if (r) r.pdf_path = ruta
  },
  async descargarPdf(ruta) {
    const pdf = archivos.get(ruta)
    if (!pdf) throw new Error('No encontramos ese PDF.')
    return pdf
  },
  async listar(busqueda) {
    await espera(100)
    const q = (busqueda ?? '').trim().toLowerCase()
    if (!q) return [...recipes]
    return recipes.filter(
      (r) =>
        r.paciente.nombre.toLowerCase().includes(q) ||
        r.paciente.documento.toLowerCase().includes(q) ||
        String(r.numero).includes(q),
    )
  },
  async preciosPublicos(token) {
    await espera()
    if (token !== 'demo') throw new Error('Este enlace no existe o ya venció.')
    const hace = new Date(Date.now() - 2 * 86_400_000).toISOString()
    return {
      sin_precio: 1,
      medicamentos: [
        {
          nombre: 'Amoxicilina 500 mg',
          ofertas: [
            { farmacia: 'Farmacia Uno', producto: 'AMOXICILINA 500MG CAPSULAS X 21', laboratorio: 'Laboratorio A', presentacion: 'Caja x 21', moneda: 'VES', precio: 1117.9, url: 'https://example.com', disponible: true, visto_en: hace },
            { farmacia: 'Farmacia Dos', producto: 'Amoxicilina 500 mg cápsulas x 21', laboratorio: '', presentacion: '', moneda: 'VES', precio: 1555, url: '', disponible: null, visto_en: hace },
            { farmacia: 'Farmacia Tres', producto: 'AMOXIL 500 MG', laboratorio: 'Laboratorio B', presentacion: 'Caja x 12', moneda: 'USD', precio: 5.22, url: 'https://example.com', disponible: null, visto_en: hace },
          ],
        },
      ],
    }
  },
  async enviar(id, correo) {
    await espera(600)
    const r = recipes.find((x) => x.id === id)
    if (r) r.ultimo_envio = { correo, estado: 'enviado', at: new Date().toISOString() }
  },
}
