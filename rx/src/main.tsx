import { Suspense, lazy, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'

import { tokenDelHash } from './recipe/precios.ts'
import './styles.css'

// El paciente solo baja su página: ni la app del médico ni el generador de PDF.
const App = lazy(() => import('./App.tsx').then((m) => ({ default: m.App })))
const Medicinas = lazy(() => import('./pantallas/Medicinas.tsx').then((m) => ({ default: m.Medicinas })))

function Raiz() {
  const [token, setToken] = useState(() => tokenDelHash(window.location.hash))

  useEffect(() => {
    const alCambiar = () => setToken(tokenDelHash(window.location.hash))
    window.addEventListener('hashchange', alCambiar)
    return () => window.removeEventListener('hashchange', alCambiar)
  }, [])

  return <Suspense fallback={null}>{token ? <Medicinas token={token} /> : <App />}</Suspense>
}

createRoot(document.getElementById('raiz')!).render(<Raiz />)
