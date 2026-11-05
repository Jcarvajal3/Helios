// ═══════════════════════════════════════════════════════════════════════════
// RX — el vocabulario de la app. Lo comparten las pantallas, el PDF y la capa
// de datos. Los textos vacíos van como '' y no como null: así un formulario y
// un PDF los tratan igual.
// ═══════════════════════════════════════════════════════════════════════════

export interface Medicamento {
  /** «Amoxicilina 500 mg». Obligatorio. */
  medicamento: string
  /** «Cápsulas». */
  presentacion: string
  /** «1 caja», «21 cápsulas». */
  cantidad: string
  /** «1 cápsula cada 8 horas por 7 días». Va en la hoja de indicaciones. */
  indicacion: string
}

export interface Paciente {
  nombre: string
  documento: string
  edad: string
  correo: string
}

/** Lo que el récipe dice del médico. Sale de Helios y él puede corregirlo en RX. */
export interface Doctor {
  /** Con su título, «Dra. Ana Lara». Solo se cambia desde Helios. */
  nombre: string
  especialidad: string
  cedula: string
  mpps: string
  colegio: string
  telefono: string
  correo: string
  direccion: string
  ciudad: string
  consultorio: string
}

/** Respuesta de `rx_mi_perfil`. */
export interface Perfil extends Doctor {
  merchant_id: string
  /** El logo público que la clínica ya tiene en Helios, o ''. */
  logo_helios_url: string
  /** Rutas dentro del bucket privado `rx`, o ''. */
  firma_path: string
  logo_path: string
}

export type DatosEditables = Omit<Doctor, 'nombre'>

export interface EnvioResumen {
  correo: string
  estado: 'pendiente' | 'enviado' | 'fallido'
  at: string
}

/** Un récipe emitido (`rx_emitir`, `rx_listar`). */
export interface Recipe {
  id: string
  numero: number
  /** YYYY-MM-DD, el día de Caracas en que se emitió. */
  fecha: string
  paciente: Paciente
  medicamentos: Medicamento[]
  indicaciones: string
  pdf_path: string
  created_at: string
  ultimo_envio: EnvioResumen | null
}

/** Lo que hace falta para pintar un récipe, en el PDF o en la vista previa. */
export interface DatosRecipe {
  /** null mientras es un borrador. */
  numero: number | null
  fecha: string
  doctor: Doctor
  paciente: Paciente
  medicamentos: Medicamento[]
  indicaciones: string
}

/** PNG o JPEG, tal como se guardaron. */
export interface ImagenesRecipe {
  firma: Uint8Array | null
  logo: Uint8Array | null
}

/** La capa de datos. La implementan `datos/supabase.ts` y `datos/demo.ts`. */
export interface Datos {
  sesion(): Promise<boolean>
  entrar(correo: string, clave: string): Promise<void>
  salir(): Promise<void>
  perfil(): Promise<Perfil>
  guardarDatos(datos: DatosEditables): Promise<Perfil>
  /** Sube la imagen ya preparada y la deja como la firma o el logo. */
  subirImagen(tipo: 'firma' | 'logo', png: Blob): Promise<Perfil>
  quitarImagen(tipo: 'firma' | 'logo'): Promise<Perfil>
  /** Las imágenes del perfil en bytes, para el PDF. */
  imagenes(perfil: Perfil): Promise<ImagenesRecipe>
  /** Idempotente por `id`: reintentar no gasta otro número. */
  emitir(
    id: string,
    paciente: Paciente,
    medicamentos: Medicamento[],
    indicaciones: string,
  ): Promise<Recipe>
  adjuntarPdf(id: string, pdf: Uint8Array): Promise<void>
  descargarPdf(pdfPath: string): Promise<Uint8Array>
  listar(busqueda?: string): Promise<Recipe[]>
  enviar(id: string, correo: string): Promise<void>
}
