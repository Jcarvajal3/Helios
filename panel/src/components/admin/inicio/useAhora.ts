import { useEffect, useState } from 'react'

/** Cada cuánto se mueven el reloj y el saludo de Inicio. */
const CADA_MEDIO_MINUTO = 30_000

/** La hora de ahora, que se refresca sola: el reloj de la tira y el saludo. */
export function useAhora(cada: number = CADA_MEDIO_MINUTO): Date {
  const [ahora, setAhora] = useState(() => new Date())
  useEffect(() => {
    const id = setInterval(() => setAhora(new Date()), cada)
    return () => clearInterval(id)
  }, [cada])
  return ahora
}
