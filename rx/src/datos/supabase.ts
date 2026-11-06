import { createClient } from '@supabase/supabase-js'

import type { Datos, Perfil, PreciosPublicos, Recipe, ImagenesRecipe } from '../modelo.ts'

// ═══════════════════════════════════════════════════════════════════════════
// La capa de datos real: la misma base y el mismo login que el panel. Los
// errores de las RPC traen su texto en español, listo para enseñarlo.
// ═══════════════════════════════════════════════════════════════════════════

const url = import.meta.env.VITE_SUPABASE_URL as string
const clave = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string

if (!url || !clave) {
  throw new Error('Faltan VITE_SUPABASE_URL o VITE_SUPABASE_PUBLISHABLE_KEY. Copia .env.example a .env.')
}

const supabase = createClient(url, clave, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
})

const BUCKET = 'rx'

async function rpc<T>(nombre: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(nombre, args)
  if (error) throw new Error(error.message)
  return data as T
}

async function bajar(ruta: string): Promise<Uint8Array> {
  const { data, error } = await supabase.storage.from(BUCKET).download(ruta)
  if (error) throw new Error('No pudimos bajar el archivo. Intenta de nuevo.')
  return new Uint8Array(await data.arrayBuffer())
}

/** La base guarda null donde el formulario y el PDF esperan ''. */
function normalizar(r: Recipe): Recipe {
  return {
    ...r,
    paciente: {
      nombre: r.paciente.nombre ?? '',
      documento: r.paciente.documento ?? '',
      edad: r.paciente.edad ?? '',
      correo: r.paciente.correo ?? '',
    },
    medicamentos: r.medicamentos.map((m) => ({
      medicamento: m.medicamento ?? '',
      presentacion: m.presentacion ?? '',
      cantidad: m.cantidad ?? '',
      indicacion: m.indicacion ?? '',
    })),
    indicaciones: r.indicaciones ?? '',
    pdf_path: r.pdf_path ?? '',
  }
}

export const datosSupabase: Datos = {
  async sesion() {
    const { data } = await supabase.auth.getSession()
    return Boolean(data.session)
  },

  async entrar(correo, contrasena) {
    const { error } = await supabase.auth.signInWithPassword({ email: correo, password: contrasena })
    if (error) throw new Error('El correo o la clave no coinciden. Son los mismos del panel de Helios.')
  },

  async salir() {
    // Solo este dispositivo, como en el panel.
    await supabase.auth.signOut({ scope: 'local' })
  },

  perfil: () => rpc<Perfil>('rx_mi_perfil'),

  guardarDatos: (datos) => rpc<Perfil>('rx_guardar_perfil', { p_datos: datos }),

  async subirImagen(tipo, png) {
    const perfil = await rpc<Perfil>('rx_mi_perfil')
    const anterior = tipo === 'firma' ? perfil.firma_path : perfil.logo_path
    const ruta = `${perfil.merchant_id}/${tipo}/${crypto.randomUUID()}.png`
    const { error } = await supabase.storage.from(BUCKET).upload(ruta, png, { contentType: 'image/png' })
    if (error) throw new Error('No pudimos subir la imagen. Intenta de nuevo.')
    const nuevo = await rpc<Perfil>('rx_guardar_imagen', { p_tipo: tipo, p_path: ruta })
    if (anterior) void supabase.storage.from(BUCKET).remove([anterior])
    return nuevo
  },

  async quitarImagen(tipo) {
    const perfil = await rpc<Perfil>('rx_mi_perfil')
    const anterior = tipo === 'firma' ? perfil.firma_path : perfil.logo_path
    const nuevo = await rpc<Perfil>('rx_guardar_imagen', { p_tipo: tipo, p_path: null })
    if (anterior) void supabase.storage.from(BUCKET).remove([anterior])
    return nuevo
  },

  async imagenes(perfil): Promise<ImagenesRecipe> {
    const firma = perfil.firma_path ? await bajar(perfil.firma_path) : null
    let logo: Uint8Array | null = null
    if (perfil.logo_path) {
      logo = await bajar(perfil.logo_path)
    } else if (perfil.logo_helios_url) {
      // El logo que la clínica ya tiene en Helios. Si no baja, el récipe sale sin él.
      try {
        const r = await fetch(perfil.logo_helios_url)
        if (r.ok) logo = new Uint8Array(await r.arrayBuffer())
      } catch {
        logo = null
      }
    }
    return { firma, logo }
  },

  emitir: async (id, paciente, medicamentos, indicaciones) =>
    normalizar(
      await rpc<Recipe>('rx_emitir', {
        p_id: id,
        p_paciente: paciente,
        p_medicamentos: medicamentos,
        p_indicaciones: indicaciones,
      }),
    ),

  async adjuntarPdf(id, pdf) {
    const perfil = await rpc<Perfil>('rx_mi_perfil')
    const ruta = `${perfil.merchant_id}/recipes/${id}.pdf`
    const { error } = await supabase.storage
      .from(BUCKET)
      .upload(ruta, new Blob([pdf.slice()], { type: 'application/pdf' }), {
        contentType: 'application/pdf',
        upsert: true,
      })
    if (error) throw new Error('No pudimos guardar el PDF. Intenta de nuevo.')
    await rpc<Recipe>('rx_adjuntar_pdf', { p_id: id, p_path: ruta })
  },

  descargarPdf: bajar,

  listar: async (busqueda) =>
    (await rpc<Recipe[]>('rx_listar', { p_busqueda: busqueda || null, p_limite: 100 })).map(normalizar),

  buscarMedicamentos: (texto) => rpc<string[]>('rx_buscar_medicamentos', { p_busqueda: texto }),

  preciosPublicos: (token) => rpc<PreciosPublicos>('rx_precios_publicos', { p_token: token }),

  async enviar(id, correo) {
    const { data, error } = await supabase.functions.invoke<{ ok?: boolean; mensaje?: string }>('rx-enviar', {
      body: { recipe_id: id, correo },
    })
    if (error) {
      // La función responde 4xx con `{mensaje}`: ese es el texto para el médico.
      const cuerpo = await (error as { context?: Response }).context?.json?.().catch(() => null)
      throw new Error(cuerpo?.mensaje ?? 'No pudimos enviar el correo. Intenta de nuevo.')
    }
    if (!data?.ok) throw new Error(data?.mensaje ?? 'No pudimos enviar el correo. Intenta de nuevo.')
  },
}
