import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Vive en conhelios.com/rx: se publica con el panel, dentro de `public/rx`.
export default defineConfig({
  base: '/rx/',
  resolve: { tsconfigPaths: true },
  plugins: [react(), tailwindcss()],
})
