import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  ConfirmDialog,
  EmptyState,
  ErrorBox,
  Input,
  Seccion,
  SkeletonList,
  Table,
  Td,
  Textarea,
  Tr,
  formatDateTime,
} from '@/components/ui'
import { fetchTermsVersions, publishTerms } from '@/features/admin/ajustes'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { describeError } from '@/lib/supabase'

/** Lo mínimo para que un texto de términos no sea un error de pegado. */
const TEXTO_MINIMO = 50

/**
 * Las condiciones del financiamiento que viajan dentro del comprobante por
 * correo (plan H9): qué versiones hay y cuál rige.
 *
 * Una versión publicada no se edita nunca: hay comprobantes enviados con ella,
 * y corregir una coma es publicar otra. En Helios no hay aceptación en una app
 * que contar: cada financiamiento guarda la versión con la que se envió.
 */
export function Terminos() {
  const isSuperAdmin = useIsSuperAdmin()
  const [publicando, setPublicando] = useState(false)

  const query = useQuery({ queryKey: ['admin-terms'], queryFn: fetchTermsVersions })

  if (query.isPending) return <SkeletonList rows={3} />
  if (query.isError) {
    return <ErrorBox title="No se pudieron leer los términos" detail={describeError(query.error)} />
  }

  const d = query.data

  return (
    <Seccion
      titulo="Condiciones del comprobante"
      info="Las condiciones del financiamiento que van dentro del comprobante que recibe cada paciente por correo: qué versiones hay y cuál rige. Una versión publicada no se edita nunca: hay comprobantes enviados con ella, y corregir una coma es publicar otra."
      controles={
        <Button
          size="sm"
          disabled={!isSuperAdmin}
          motivoApagado={isSuperAdmin ? undefined : SOLO_SUPER_ADMIN}
          onClick={() => setPublicando(true)}
        >
          Publicar una versión
        </Button>
      }
    >
      {d.rows.length === 0 ? (
        <EmptyState
          title="Todavía no hay ninguna versión publicada"
          description="Cada comprobante lleva las condiciones vigentes al enviarse: poder decir qué decían es la prueba de lo que se le comunicó al paciente."
        />
      ) : (
        <Table headers={['Versión', 'Publicada', 'Quién', '']}>
          {d.rows.map((t) => (
            <Tr key={t.version}>
              <Td className="font-medium">
                {t.version}
                {t.summary && (
                  <span className="mt-0.5 block type-panel-caption text-on-surface-variant">
                    {t.summary}
                  </span>
                )}
              </Td>
              <Td className="whitespace-nowrap text-on-surface-variant">
                {formatDateTime(t.publishedAt)}
              </Td>
              <Td className="text-on-surface-variant">{t.publishedByName}</Td>
              <Td>{t.isCurrent && <Badge>Vigente</Badge>}</Td>
            </Tr>
          ))}
        </Table>
      )}

      {publicando && (
        <PublicarTerminos onClose={() => setPublicando(false)} />
      )}
    </Seccion>
  )
}

/**
 * Publicar es `sensible`: la versión nueva va en todos los comprobantes desde ya. El
 * motivo que pide el diálogo es «qué cambia», que se guarda con la versión y
 * es lo que se lee después en la tabla y en la bitácora.
 */
function PublicarTerminos({ onClose }: { onClose: () => void }) {
  const avisar = useToast()
  const queryClient = useQueryClient()
  const [version, setVersion] = useState('')
  const [url, setUrl] = useState('')
  const [body, setBody] = useState('')

  const mutation = useMutation({
    mutationFn: (summary: string) =>
      publishTerms({
        version: version.trim(),
        body,
        summary,
        url: url.trim() || undefined,
      }),
    onSuccess: () => {
      avisar(`Condiciones ${version.trim()} publicadas. Van en los comprobantes desde ahora.`)
      void queryClient.invalidateQueries({ queryKey: ['admin-terms'] })
      onClose()
    },
  })

  return (
    <ConfirmDialog
      nivel="sensible"
      title="Publicar una versión de las condiciones"
      summary="Pasa a ser la vigente y va en el comprobante de cada financiamiento nuevo. La anterior se conserva tal cual: hay comprobantes enviados con ella."
      detail={
        <div className="flex flex-col gap-3">
          <Input
            id="terms-version"
            label="Versión"
            value={version}
            onChange={setVersion}
            placeholder="2026-10-1"
            autoFocus
          />
          <Input
            id="terms-url"
            label="Enlace público (opcional)"
            value={url}
            onChange={setUrl}
            placeholder="https://…/condiciones"
          />
          <Textarea
            id="terms-body"
            label="El texto completo"
            value={body}
            onChange={setBody}
            rows={10}
            placeholder="Pega aquí el texto entero."
            hint="Se guarda tal cual, para enseñarlo el día que el enlace ya no exista."
          />
        </div>
      }
      reasonLabel="Qué cambia en esta versión"
      reasonPlaceholder="Se aclara el cargo por atraso"
      bloqueo={
        version.trim().length === 0
          ? 'Falta el nombre de la versión.'
          : body.trim().length < TEXTO_MINIMO
            ? 'Falta el texto completo de las condiciones.'
            : undefined
      }
      confirmLabel="Publicar"
      busy={mutation.isPending}
      error={mutation.isError ? describeError(mutation.error) : undefined}
      onConfirm={(summary) => mutation.mutate(summary)}
      onClose={onClose}
    />
  )
}
