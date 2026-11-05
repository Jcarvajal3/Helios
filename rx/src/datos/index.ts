import type { Datos } from '../modelo.ts'

// `MODE` lo fija Vite al compilar: en producción la rama del demo desaparece.
export const esDemo = import.meta.env.MODE === 'demo'

export const datos: Datos = esDemo
  ? (await import('./demo.ts')).datosDemo
  : (await import('./supabase.ts')).datosSupabase
