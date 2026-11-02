import type { ReactNode } from 'react'
import { Link } from '@tanstack/react-router'

/**
 * Ajustes de Helios Lite, como la maqueta: a la izquierda los temas en cinco
 * grupos y a la derecha, en un panel, el ajuste elegido. Lo de dentro del
 * panel es el ajuste de Pro (`routes/admin/ajustes.tsx`), con sus vigencias,
 * su historia y sus permisos: aquí solo cambia cómo se llega.
 */
const GRUPOS: ReadonlyArray<{ titulo: string; temas: ReadonlyArray<{ id: string; rotulo: string }> }> = [
  {
    titulo: 'Reglas',
    temas: [
      { id: 'tasa', rotulo: 'Tasa BCV' },
      { id: 'parametros', rotulo: 'Parámetros' },
      { id: 'niveles', rotulo: 'Niveles y cupos' },
      { id: 'feriados', rotulo: 'Feriados' },
    ],
  },
  {
    titulo: 'Paciente y comprobante',
    temas: [
      { id: 'cobro', rotulo: 'Cuentas de cobro' },
      { id: 'contacto', rotulo: 'Contacto' },
      { id: 'terminos', rotulo: 'Condiciones' },
    ],
  },
  {
    titulo: 'Acceso',
    temas: [
      { id: 'equipo', rotulo: 'Equipo' },
      { id: 'seguridad', rotulo: 'Seguridad' },
    ],
  },
  {
    titulo: 'Capacitaciones y registro',
    temas: [
      { id: 'demo', rotulo: 'Números de capacitación' },
      { id: 'bitacora', rotulo: 'Bitácora' },
    ],
  },
  { titulo: 'Emergencia', temas: [{ id: 'mantenimiento', rotulo: 'Mantenimiento' }] },
]

export function AjustesLite({ activa, children }: { activa: string; children: ReactNode }) {
  const tema = GRUPOS.flatMap((g) => g.temas).find((t) => t.id === activa)

  return (
    <div className="lt-ajustes">
      <nav className="lt-ajustes-nav" aria-label="Secciones de ajustes">
        {GRUPOS.map((g) => (
          <div key={g.titulo}>
            <h2>{g.titulo}</h2>
            {g.temas.map((t) => (
              <Link
                key={t.id}
                to="/admin/ajustes"
                search={{ tab: t.id } as never}
                aria-current={t.id === activa ? 'page' : undefined}
              >
                {t.rotulo}
              </Link>
            ))}
          </div>
        ))}
      </nav>

      <section className="lt-panel">
        <div className="lt-panel-cabeza">
          <h2>{tema?.rotulo ?? 'Ajustes'}</h2>
        </div>
        <div className="lt-ajustes-cuerpo" style={{ paddingTop: 0 }}>
          {children}
        </div>
      </section>
    </div>
  )
}
