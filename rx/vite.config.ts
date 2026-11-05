import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Vive en conhelios.com/rx: el panel le pasa esa ruta a este proyecto.
export default defineConfig({
  base: '/rx/',
  resolve: { tsconfigPaths: true },
  plugins: [react(), tailwindcss()],
})
