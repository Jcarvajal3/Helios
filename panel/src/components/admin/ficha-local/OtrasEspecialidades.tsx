import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Save, X } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { Button, Card, Chip, ErrorBox, Seccion, Select } from '@/components/ui'
import { consultaDirectorio, guardarTarjeta, refrescarDirectorio } from '@/features/admin/directorioDeMedicos/api'
import { MAXIMO_DE_OTRAS_ESPECIALIDADES, otrasDelBorrador } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type { MedicoEnElDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { ESPECIALIDADES, nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { describeError } from '@/lib/supabase'

/**
 * Las otras especialidades del médico (el psiquiatra que también es
 * internista), en su perfil. Antes se elegían en la ficha del directorio; el
 * dato vive en la tarjeta (`directory_listings.other_specialty_keys`), pero se
 * edita aquí para tener todo lo del médico en un solo sitio.
 *
 * Solo el super admin: guardar pasa por `admin_directorio_guardar`, que exige
 * `is_platform_admin()` (el capacitador no la pasa). Una sola tarjeta: nada de
 * duplicar al médico. La especialidad principal (filtro e icono) se sigue
 * eligiendo en la tarjeta del directorio.
 */
export function OtrasEspecialidades({ merchantId }: { merchantId: string }) {
  // Sin relectura periódica: aquí no se miran los clics.
  const tablero = useQuery({ ...consultaDirectorio(), refetchInterval: false, refetchOnWindowFocus: false })
  const medico = tablero.data?.medicos.find((m) => m.id === merchantId) ?? null

  return (
    <Seccion
      titulo="Otras especialidades"
      info="Las especialidades además de la principal en las que sale el médico en el directorio (hasta tres): el psiquiatra que también es internista. Sale también en el filtro y en la página de cada una, con la misma tarjeta; no se duplica. La principal (filtro e icono) se elige en la tarjeta del directorio."
    >
      <Card className="flex flex-col gap-3">
        {tablero.isPending && <p className="type-panel-caption text-on-surface-variant">Leyendo sus especialidades…</p>}
        {tablero.isError && <ErrorBox title="No se pudieron leer sus especialidades" detail={describeError(tablero.error)} />}
        {tablero.isSuccess && !medico && (
          <p className="type-panel-caption text-on-surface-variant">Esta clínica todavía no está en el directorio.</p>
        )}
        {medico && <Editor key={medico.tarjeta.otrasClaves.join(',')} medico={medico} />}
      </Card>
    </Seccion>
  )
}

function Editor({ medico: m }: { medico: MedicoEnElDirectorio }) {
  const client = useQueryClient()
  const avisar = useToast()
  const principal = m.tarjeta.clave
  const guardadas = m.tarjeta.otrasClaves
  const [elegidas, setElegidas] = useState<ClaveDeEspecialidad[]>(guardadas)

  // La principal cuenta aparte: no se repite entre las otras.
  const limpias = otrasDelBorrador({ clave: principal, otrasClaves: elegidas })
  const lleno = limpias.length >= MAXIMO_DE_OTRAS_ESPECIALIDADES
  const cambiado = limpias.join(',') !== guardadas.join(',')
  const opciones = ESPECIALIDADES.filter((e) => e.clave !== 'otra' && e.clave !== principal && !limpias.includes(e.clave)).map(
    (e) => ({ value: e.clave, label: e.nombre }),
  )

  const guardar = useMutation({
    mutationFn: () => guardarTarjeta(m.id, { other_specialty_keys: limpias }),
    onSuccess: () => {
      refrescarDirectorio(client)
      avisar('Especialidades guardadas')
    },
  })

  return (
    <>
      <p className="type-panel-caption text-on-surface-variant">
        Principal: <span className="text-on-surface">{nombreDeEspecialidad(principal)}</span>
      </p>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <p className="type-panel-label text-on-surface-variant">También sale en</p>
          {limpias.length === 0 ? (
            <p className="type-panel-caption text-on-surface-variant">Solo en la principal.</p>
          ) : (
            <ul className="flex flex-wrap gap-2">
              {limpias.map((c) => (
                <li key={c}>
                  <Chip onClick={() => setElegidas(limpias.filter((x) => x !== c))}>
                    {nombreDeEspecialidad(c)} <X size={13} aria-label={`Quitar ${nombreDeEspecialidad(c)}`} />
                  </Chip>
                </li>
              ))}
            </ul>
          )}
        </div>
        {!lleno && (
          <Select
            id={`otras-especialidades-${m.id}`}
            label="Añadir otra especialidad"
            value=""
            placeholder="Elige una…"
            options={opciones}
            onChange={(clave) => setElegidas([...limpias, clave])}
          />
        )}
      </div>
      {lleno && (
        <p className="type-panel-caption text-on-surface-variant">
          Como mucho {MAXIMO_DE_OTRAS_ESPECIALIDADES} además de la principal.
        </p>
      )}

      {guardar.isError && <ErrorBox title="No se pudieron guardar las especialidades" detail={describeError(guardar.error)} />}

      <div>
        <Button
          size="md"
          variant="tonal"
          disabled={!cambiado || guardar.isPending}
          motivoApagado={guardar.isPending || cambiado ? undefined : 'No has cambiado nada.'}
          onClick={() => guardar.mutate()}
        >
          <Save size={15} aria-hidden /> {guardar.isPending ? 'Guardando…' : 'Guardar las especialidades'}
        </Button>
      </div>
    </>
  )
}
