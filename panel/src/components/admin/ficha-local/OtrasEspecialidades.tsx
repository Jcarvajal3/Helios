import { useState } from 'react'
import type { FormEvent } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Plus, Save, X } from 'lucide-react'

import { useToast } from '@/components/Toast'
import { Button, Card, Chip, ErrorBox, Input, Seccion, Select } from '@/components/ui'
import {
  consultaEspecialidadesDelMedico,
  guardarOtrasEspecialidades,
  refrescarDirectorio,
} from '@/features/admin/directorioDeMedicos/api'
import {
  MAXIMO_DE_OTRAS_ESPECIALIDADES,
  limpiarNombreDeEspecialidad,
  motivoDelNombreDeEspecialidad,
  otrasDelBorrador,
} from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import type { EspecialidadesDelMedico } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { ESPECIALIDADES, nombreDeEspecialidad } from '@/features/directorio/especialidades'
import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'
import { describeError } from '@/lib/supabase'

/**
 * Las otras especialidades del médico (el psiquiatra que también es
 * internista), en su perfil. Antes se elegían en la ficha del directorio; el
 * dato vive en la tarjeta (`directory_listings`), pero se edita aquí para
 * tener todo lo del médico en un solo sitio.
 *
 * Dos clases, que juntas no pasan de tres:
 *  - las de la lista (`other_specialty_keys`): salen también en su filtro y en
 *    su página;
 *  - las escritas a mano (`other_specialty_names`, 20261125200000), para las
 *    que no están en la lista: se leen en la tarjeta, sin filtro ni página.
 *
 * Lo ven y lo guardan el super admin y el capacitador
 * (`admin_medico_especialidades_guardar`): solo cambia esas listas, nada más
 * de la tarjeta. Una sola tarjeta: nada de duplicar al médico. La
 * especialidad principal (filtro e icono) se sigue eligiendo en la tarjeta del
 * directorio, que es del super admin.
 */
export function OtrasEspecialidades({ merchantId }: { merchantId: string }) {
  const lectura = useQuery(consultaEspecialidadesDelMedico(merchantId))

  return (
    <Seccion
      titulo="Otras especialidades"
      info="Las especialidades además de la principal en las que sale el médico en el directorio (hasta tres en total): el psiquiatra que también es internista. Las de la lista salen también en su filtro y en su página, con la misma tarjeta; si no está en la lista, se escribe a mano y se lee en la tarjeta, sin filtro propio. La principal (filtro e icono) la elige el super admin en la tarjeta del directorio."
    >
      <Card className="flex flex-col gap-3">
        {lectura.isPending && <p className="type-panel-caption text-on-surface-variant">Leyendo sus especialidades…</p>}
        {lectura.isError && <ErrorBox title="No se pudieron leer sus especialidades" detail={describeError(lectura.error)} />}
        {lectura.data && (
          <Editor
            key={[...lectura.data.otrasClaves, ...lectura.data.otrosNombres].join(',')}
            merchantId={merchantId}
            actuales={lectura.data}
          />
        )}
      </Card>
    </Seccion>
  )
}

function Editor({ merchantId, actuales }: { merchantId: string; actuales: EspecialidadesDelMedico }) {
  const client = useQueryClient()
  const avisar = useToast()
  const principal = actuales.clave
  const [elegidas, setElegidas] = useState<ClaveDeEspecialidad[]>(actuales.otrasClaves)
  const [nombres, setNombres] = useState<string[]>(actuales.otrosNombres)
  const [tecleado, setTecleado] = useState('')

  // La principal cuenta aparte: no se repite entre las otras.
  const claves = otrasDelBorrador({ clave: principal, otrasClaves: elegidas })
  const lleno = claves.length + nombres.length >= MAXIMO_DE_OTRAS_ESPECIALIDADES
  const cambiado =
    claves.join(',') !== actuales.otrasClaves.join(',') || nombres.join('|') !== actuales.otrosNombres.join('|')
  const opciones = ESPECIALIDADES.filter((e) => e.clave !== 'otra' && e.clave !== principal && !claves.includes(e.clave)).map(
    (e) => ({ value: e.clave, label: e.nombre }),
  )
  const motivoDelTexto = tecleado.trim() ? motivoDelNombreDeEspecialidad(tecleado, { principal, nombres }) : null

  const guardar = useMutation({
    mutationFn: () => guardarOtrasEspecialidades(merchantId, claves, nombres),
    onSuccess: () => {
      // La lectura de aquí y el directorio del super admin, que las enseña.
      refrescarDirectorio(client)
      avisar('Especialidades guardadas')
    },
  })

  function añadirEscrita(e: FormEvent) {
    e.preventDefault()
    if (!tecleado.trim() || motivoDelTexto || lleno) return
    setNombres([...nombres, limpiarNombreDeEspecialidad(tecleado)])
    setTecleado('')
  }

  return (
    <>
      <p className="type-panel-caption text-on-surface-variant">
        Principal: <span className="text-on-surface">{nombreDeEspecialidad(principal)}</span>
      </p>

      <div className="flex flex-col gap-1.5">
        <p className="type-panel-label text-on-surface-variant">También sale en</p>
        {claves.length + nombres.length === 0 ? (
          <p className="type-panel-caption text-on-surface-variant">Solo en la principal.</p>
        ) : (
          <ul className="flex flex-wrap gap-2">
            {claves.map((c) => (
              <li key={c}>
                <Chip onClick={() => setElegidas(claves.filter((x) => x !== c))}>
                  {nombreDeEspecialidad(c)} <X size={13} aria-label={`Quitar ${nombreDeEspecialidad(c)}`} />
                </Chip>
              </li>
            ))}
            {nombres.map((n) => (
              <li key={n}>
                <Chip onClick={() => setNombres(nombres.filter((x) => x !== n))}>
                  {n} <X size={13} aria-label={`Quitar ${n}`} />
                </Chip>
              </li>
            ))}
          </ul>
        )}
      </div>

      {!lleno && (
        <div className="grid gap-3 sm:grid-cols-2">
          <Select
            id={`otras-especialidades-${merchantId}`}
            label="Añadir de la lista"
            value=""
            placeholder="Elige una…"
            options={opciones}
            onChange={(clave) => setElegidas([...claves, clave])}
          />
          <form onSubmit={añadirEscrita} className="flex items-end gap-2">
            <div className="min-w-0 flex-1">
              <Input
                id={`otra-especialidad-escrita-${merchantId}`}
                label="¿No está en la lista? Escríbela"
                value={tecleado}
                onChange={setTecleado}
                placeholder="Hepatología pediátrica"
                autoComplete="off"
                error={!!motivoDelTexto}
              />
            </div>
            <Button type="submit" size="md" variant="tonal" disabled={!tecleado.trim() || !!motivoDelTexto}>
              <Plus size={15} aria-hidden /> Añadir
            </Button>
          </form>
        </div>
      )}
      {motivoDelTexto && <p className="type-panel-caption text-error">{motivoDelTexto}</p>}
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
