import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { RotateCcw } from 'lucide-react'

import {
  Badge,
  Button,
  Card,
  Chip,
  DataLabel,
  ErrorBox,
  InfoDot,
  NoSePudoLeer,
  Seccion,
  SkeletonList,
  Textarea,
  formatDateTime,
} from '@/components/ui'
import { useToast } from '@/components/Toast'
import { resetCollectionTemplate, setCollectionTemplate } from '@/features/admin/ajustes'
import type { CollectionTemplate } from '@/features/admin/ajustes'
import { consultaPlantillas } from '@/features/admin/cobranza/consultas'
import { CLAVES_PLANTILLA, EJEMPLO_DE_COBRO, cuandoSeUsa, rellenar } from '@/features/admin/plantillas'
import type { ClavePlantilla } from '@/features/admin/plantillas'
import { cortesDeTramo } from '@/features/admin/tramos'
import { useParametros } from '@/features/admin/useParametros'
import { unoDe } from '@/lib/busqueda'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/**
 * Los mensajes que se mandan por WhatsApp al cobrar: uno por cada tramo de
 * atraso, con los días de cada tramo. Los recordatorios antes del vencimiento
 * y el del día salen solos y no se editan aquí.
 *
 * No son avisos automáticos: nadie los manda solo. Son el texto con el que se
 * abre el chat desde la cartera vencida y el caso de cada persona que debe
 * algo vencido. Cada uno
 * se ve tal como lo recibe la persona, con datos de ejemplo.
 */
export function PlantillasCobranza() {
  const query = useQuery(consultaPlantillas())
  // Sin parámetros el rótulo de días no se pinta: nunca se inventa.
  const parametros = useParametros()
  const cortes = cortesDeTramo(parametros.data)

  if (query.isPending) return <SkeletonList rows={4} />

  if (query.isError) {
    return (
      <Card>
        <p className="flex flex-wrap items-baseline gap-x-2 type-panel-body text-on-surface-variant">
          Plantillas de WhatsApp:
          <NoSePudoLeer onReintentar={() => void query.refetch()} />
        </p>
      </Card>
    )
  }

  return (
    <Seccion
      titulo="Lo que se manda al cobrar"
      info="No son avisos automáticos: nadie los manda solo. Son el texto con el que se abre el chat de WhatsApp desde Por cobrar y el caso de cada paciente con algo vencido, uno por tramo de atraso. Los recordatorios antes del vencimiento y el del día salen solos."
    >
      <div className="flex flex-col gap-4">
        {plantillasEnOrden(query.data.rows).map(({ clave, template }) => (
          <Plantilla
            key={clave}
            template={template}
            cuando={cuandoSeUsa(clave, cortes)}
            variables={query.data.variables}
          />
        ))}
      </div>
    </Seccion>
  )
}

/** Las cuatro del panel, en su orden. Una clave que no conoce no se enseña. */
function plantillasEnOrden(
  rows: ReadonlyArray<CollectionTemplate>,
): Array<{ clave: ClavePlantilla; template: CollectionTemplate }> {
  return rows
    .flatMap((template) => {
      const clave = unoDe(CLAVES_PLANTILLA, template.bucket)
      return clave ? [{ clave, template }] : []
    })
    .sort((a, b) => CLAVES_PLANTILLA.indexOf(a.clave) - CLAVES_PLANTILLA.indexOf(b.clave))
}

function Plantilla({
  template,
  cuando,
  variables,
}: {
  template: CollectionTemplate
  /** «1–7 días de atraso»; `null` mientras no se conozcan los cortes. */
  cuando: string | null
  variables: string[]
}) {
  const queryClient = useQueryClient()
  const isSuperAdmin = useIsSuperAdmin()
  const avisar = useToast()
  const [texto, setTexto] = useState(template.body)
  const [editando, setEditando] = useState(false)
  // El `Textarea` del kit no reenvía la ref: el cursor se busca por el id.
  const idArea = `plantilla-${template.bucket}`

  function refrescar() {
    void queryClient.invalidateQueries({ queryKey: consultaPlantillas().queryKey })
  }

  const guardar = useMutation({
    mutationFn: () => setCollectionTemplate(template.bucket, texto),
    onSuccess: () => {
      avisar(`Plantilla «${template.label}» guardada.`)
      setEditando(false)
      refrescar()
    },
  })

  const volver = useMutation({
    mutationFn: () => resetCollectionTemplate(template.bucket),
    onSuccess: () => {
      avisar(`«${template.label}» vuelve al texto de fábrica.`)
      setTexto(template.defaultBody)
      setEditando(false)
      refrescar()
    },
  })

  // Una variable que no existe sale con las llaves a la vista en el teléfono
  // de alguien: se avisa antes de guardar.
  const desconocidas = [...texto.matchAll(/\{(\w+)\}/g)]
    .map((m) => m[1])
    .filter((v) => !variables.includes(v))

  const cambiado = texto !== template.body

  /** Pone la variable donde está el cursor, o al final si el campo no tiene foco. */
  function insertar(variable: string) {
    const nodo = document.getElementById(idArea)
    const area = nodo instanceof HTMLTextAreaElement ? nodo : null
    const marca = `{${variable}}`
    const desde = area?.selectionStart ?? texto.length
    const hasta = area?.selectionEnd ?? texto.length
    setTexto(texto.slice(0, desde) + marca + texto.slice(hasta))
    requestAnimationFrame(() => {
      area?.focus()
      area?.setSelectionRange(desde + marca.length, desde + marca.length)
    })
  }

  const motivoGuardar = !cambiado
    ? 'No has cambiado nada.'
    : desconocidas.length > 0
      ? 'Hay una variable que no existe.'
      : undefined

  return (
    <Card className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-col gap-1">
          <div className="flex items-center gap-2">
            <h3 className="type-panel-section text-on-surface">{template.label}</h3>
            {template.edited && <Badge>Editada</Badge>}
          </div>
          {cuando && <span className="type-panel-caption text-panel-muted">{cuando}</span>}
        </div>
        <span className="type-panel-caption text-panel-muted">
          {template.edited
            ? `${template.updatedByName} · ${formatDateTime(template.updatedAt)}`
            : 'Texto de fábrica'}
        </span>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <div className="flex min-w-0 flex-col gap-3">
          {editando ? (
            <>
              <Textarea
                id={idArea}
                label="Texto"
                value={texto}
                onChange={setTexto}
                rows={6}
                // Una variable que no existe sale con las llaves a la vista:
                // se dice debajo del campo y no deja guardar.
                error={
                  desconocidas.length > 0
                    ? `${desconocidas.map((v) => `{${v}}`).join(', ')} ${
                        desconocidas.length === 1 ? 'no existe' : 'no existen'
                      } y saldría con las llaves a la vista.`
                    : undefined
                }
              />
              <div>
                <p className="mb-2 flex items-center gap-1 type-panel-caption text-panel-muted">
                  Púlsalas para ponerlas donde está el cursor.
                  <InfoDot
                    title="Variables"
                    what="El panel las rellena con los datos del paciente y la cuenta de cobro activa al abrir el chat. Una que no existe dejaría las llaves a la vista, así que no se puede guardar."
                  />
                </p>
                <div className="flex flex-wrap gap-2">
                  {variables.map((v) => (
                    <Chip key={v} onClick={() => insertar(v)}>{`{${v}}`}</Chip>
                  ))}
                </div>
              </div>
            </>
          ) : (
            <>
              <DataLabel>Texto</DataLabel>
              <p className="whitespace-pre-wrap rounded-panel-control border border-panel-hairline p-4 type-panel-body leading-6 text-on-surface-variant">
                {template.body}
              </p>
            </>
          )}
        </div>

        <div className="flex min-w-0 flex-col gap-3">
          <DataLabel>Así lo recibe el paciente (datos de ejemplo)</DataLabel>
          <p className="whitespace-pre-wrap rounded-panel-card bg-panel-raised p-4 type-panel-body leading-6 text-on-surface">
            {rellenar(texto, EJEMPLO_DE_COBRO)}
          </p>
        </div>
      </div>

      {editando ? (
        <div className="flex flex-wrap items-start gap-3">
          <Button
            size="sm"
            disabled={!isSuperAdmin || motivoGuardar !== undefined || guardar.isPending}
            motivoApagado={!isSuperAdmin ? SOLO_SUPER_ADMIN : motivoGuardar}
            onClick={() => guardar.mutate()}
          >
            {guardar.isPending ? 'Guardando…' : 'Guardar'}
          </Button>
          <Button
            size="sm"
            variant="text"
            onClick={() => {
              setTexto(template.body)
              setEditando(false)
            }}
          >
            Cancelar
          </Button>
          {template.edited && (
            <Button
              size="sm"
              variant="text"
              disabled={!isSuperAdmin || volver.isPending}
              motivoApagado={!isSuperAdmin ? SOLO_SUPER_ADMIN : undefined}
              onClick={() => volver.mutate()}
            >
              <RotateCcw size={14} aria-hidden /> Volver al de fábrica
            </Button>
          )}
        </div>
      ) : (
        <div>
          <Button
            size="sm"
            variant="tonal"
            disabled={!isSuperAdmin}
            motivoApagado={SOLO_SUPER_ADMIN}
            onClick={() => setEditando(true)}
          >
            Cambiar el texto
          </Button>
        </div>
      )}

      {(guardar.isError || volver.isError) && (
        <ErrorBox title="No se pudo guardar" detail={describeError(guardar.error ?? volver.error)} />
      )}
    </Card>
  )
}
