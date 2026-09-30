// ═══════════════════════════════════════════════════════════════════════════
// Qué locales ofrece el selector de Métricas, y en qué orden.
//
// Los de prueba no salen: sus ventas no cuentan en ninguna cifra, y elegir uno
// enseñaría ceros que no significan nada. Primero los activos, por nombre;
// después los pausados y los terminados, que siguen teniendo historia (sus
// cohortes, lo que se les debe) pero ya no venden.
//
// Puro: se prueba en `opcionesDeLocal.test.ts`.
// ═══════════════════════════════════════════════════════════════════════════

/** Lo que el selector necesita de cada local (una fila de `merchant_directory`). */
export type LocalElegible = {
  id: string
  name: string
  status: 'active' | 'paused' | 'terminated'
  isTest: boolean
}

export type OpcionesDeLocal = {
  activos: ReadonlyArray<LocalElegible>
  /** Pausados y terminados. */
  otros: ReadonlyArray<LocalElegible>
}

const porNombre = (a: LocalElegible, b: LocalElegible) => a.name.localeCompare(b.name, 'es')

export function opcionesDeLocal(locales: ReadonlyArray<LocalElegible>): OpcionesDeLocal {
  const reales = locales.filter((l) => !l.isTest)
  return {
    activos: reales.filter((l) => l.status === 'active').sort(porNombre),
    otros: reales.filter((l) => l.status !== 'active').sort(porNombre),
  }
}

/**
 * El nombre del local elegido. `null` sin local, o si no está en la lista
 * (un enlace a un local de prueba, o uno que ya no existe).
 */
export function nombreDelLocal(locales: ReadonlyArray<LocalElegible>, id: string | null): string | null {
  if (id === null) return null
  return locales.find((l) => l.id === id)?.name ?? null
}
