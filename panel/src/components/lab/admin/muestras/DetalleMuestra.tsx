import { useState } from 'react'
import type { ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Mail, MessageCircle } from 'lucide-react'

import {
  Button,
  Callout,
  Card,
  ConfirmDialog,
  DataLabel,
  ErrorBox,
  Modal,
  Segmented,
  SkeletonList,
  Textarea,
  formatDateTime,
  formatPhone,
  formatUsd,
} from '@/components/ui'
import {
  cambiarEstado,
  consultaMuestra,
  enlaceCorreo,
  enlaceWhatsapp,
  mensajeDeError,
} from '@/features/lab/admin'
import type { DetalleMuestra as Detalle } from '@/features/lab/admin'
import { PASOS_MUESTRA, ROTULOS_PRECIO, ROTULO_CANAL, ROTULO_ESTADO } from '@/features/lab/tipos'
import type { CanalResultado, EstadoMuestra } from '@/features/lab/tipos'

import { Captura, InsigniaEstado, InsigniaPago, useEscritura } from './comun'
import { AccionesDelPago, LecturaDelPago, MontoEnBs } from './Pago'

/** El detalle de una muestra, en una ventana. */
export function DetalleMuestra({ id, onClose }: { id: string; onClose: () => void }) {
  const q = useQuery(consultaMuestra(id))

  return (
    <Modal title="Muestra" onClose={onClose} width="lg">
      {q.isPending && <SkeletonList rows={5} />}
      {q.isError && <ErrorBox title="No se pudo leer la muestra" detail={mensajeDeError(q.error)} />}
      {q.data && <Cuerpo detalle={q.data} onClose={onClose} />}
    </Modal>
  )
}

function Dato({ rotulo, children }: { rotulo: string; children: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-col gap-1">
      <DataLabel>{rotulo}</DataLabel>
      <div className="type-panel-body break-words text-on-surface">{children}</div>
    </div>
  )
}

function Cuerpo({ detalle, onClose }: { detalle: Detalle; onClose: () => void }) {
  const m = detalle.muestra
  const wa = enlaceWhatsapp(m.pacienteWhatsapp)
  const correo = enlaceCorreo(m.pacienteCorreo)
  const linea = [...detalle.pasos, ...detalle.historia]

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center gap-2">
        <span className="type-panel-section font-bold text-on-surface">{m.codigo}</span>
        <InsigniaEstado estado={m.estado} />
        <InsigniaPago pago={m.pagoEstado} />
      </div>
      {m.estado === 'anulada' && detalle.motivoAnulada && (
        <Callout tone="warning" titulo="Muestra anulada">
          {detalle.motivoAnulada}
        </Callout>
      )}

      <Card tone="inset" className="grid gap-4 sm:grid-cols-2">
        <Dato rotulo="Paciente">{m.paciente}</Dato>
        <Dato rotulo="Médico">{m.medico}</Dato>
        <Dato rotulo="WhatsApp">
          {wa ? (
            <a href={wa} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1.5 text-primary hover:underline">
              <MessageCircle size={14} aria-hidden />
              {formatPhone(m.pacienteWhatsapp)}
            </a>
          ) : (
            '—'
          )}
        </Dato>
        <Dato rotulo="Correo">
          {correo ? (
            <a href={correo} className="inline-flex items-center gap-1.5 text-primary hover:underline">
              <Mail size={14} aria-hidden />
              {m.pacienteCorreo}
            </a>
          ) : (
            '—'
          )}
        </Dato>
        <Dato rotulo="Examen">{m.examen}</Dato>
        <Dato rotulo="Laboratorio">{m.laboratorio}</Dato>
      </Card>
      <p className="-mt-3 type-panel-caption text-panel-muted">
        El resultado se le envía al paciente por fuera, por correo o WhatsApp. Aquí solo se marca como entregado.
      </p>

      <section className="flex flex-col gap-2">
        <h3 className="type-panel-label font-semibold text-on-surface">Precio</h3>
        <Card tone="inset" className="flex flex-col gap-1.5">
          <Fila rotulo={ROTULOS_PRECIO.base} valor={formatUsd(m.baseUsd)} />
          <Fila rotulo={ROTULOS_PRECIO.cargo} valor={formatUsd(m.cargoUsd)} />
          <Fila rotulo={ROTULOS_PRECIO.comisionMedico} valor={formatUsd(m.comisionUsd)} />
          <div className="mt-1 border-t border-panel-hairline pt-2">
            <Fila rotulo={ROTULOS_PRECIO.precio} valor={formatUsd(m.precioUsd)} fuerte />
          </div>
        </Card>
      </section>

      <section className="flex flex-col gap-3">
        <h3 className="type-panel-label font-semibold text-on-surface">Pago</h3>
        <div className="grid gap-4 sm:grid-cols-2">
          <Dato rotulo="Monto en bolívares">
            <MontoEnBs muestra={m} />
          </Dato>
          <Dato rotulo="Referencia y banco">
            {m.pagoReferencia ?? '—'}
            {m.pagoBanco && <span className="text-panel-muted"> · {m.pagoBanco}</span>}
          </Dato>
        </div>
        {m.pagoNota && <p className="type-panel-caption text-on-surface-variant">Nota: {m.pagoNota}</p>}
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="flex flex-col gap-2">
            <DataLabel>Captura</DataLabel>
            {m.comprobantePath ? <Captura ruta={m.comprobantePath} /> : <span className="type-panel-caption text-panel-muted">Sin captura</span>}
          </div>
          <div className="flex flex-col gap-2">
            <DataLabel>Lo que leyó el lector</DataLabel>
            <LecturaDelPago muestra={m} />
          </div>
        </div>
        <AccionesDelPago muestra={m} />
      </section>

      <section className="flex flex-col gap-2">
        <h3 className="type-panel-label font-semibold text-on-surface">Recorrido</h3>
        {linea.length === 0 ? (
          <span className="type-panel-caption text-panel-muted">Sin movimientos todavía.</span>
        ) : (
          <ol className="flex flex-col gap-1.5">
            {linea.map((p, i) => (
              <li key={i} className="flex flex-wrap gap-x-3 type-panel-body">
                <span className="w-32 shrink-0 tabular-nums text-panel-muted">{formatDateTime(p.cuando)}</span>
                <span className="text-on-surface">
                  {p.texto}
                  {p.quien && <span className="text-panel-muted"> · {p.quien}</span>}
                </span>
              </li>
            ))}
            {detalle.canalResultado && (
              <li className="type-panel-caption text-panel-muted">
                Resultado entregado por {ROTULO_CANAL[detalle.canalResultado].toLowerCase()}.
              </li>
            )}
          </ol>
        )}
      </section>

      <AccionesDeEstado detalle={detalle} onClose={onClose} />
    </div>
  )
}

function Fila({ rotulo, valor, fuerte = false }: { rotulo: string; valor: string; fuerte?: boolean }) {
  return (
    <div className={`flex justify-between gap-4 type-panel-body ${fuerte ? 'font-bold text-on-surface' : 'text-on-surface-variant'}`}>
      <span>{rotulo}</span>
      <span className="tabular-nums">{valor}</span>
    </div>
  )
}

type Dialogo = 'recibido' | 'entregado' | 'corregir' | 'anular' | null

function AccionesDeEstado({ detalle, onClose }: { detalle: Detalle; onClose: () => void }) {
  const m = detalle.muestra
  const [dialogo, setDialogo] = useState<Dialogo>(null)
  const [canal, setCanal] = useState<CanalResultado>('whatsapp')
  const [nuevo, setNuevo] = useState<EstadoMuestra>(m.estado === 'anulada' ? 'lista_para_retirar' : m.estado)
  const [nota, setNota] = useState('')
  const cerrar = () => setDialogo(null)

  const poner = useEscritura(
    (v: { estado: EstadoMuestra; canal?: CanalResultado; nota?: string }) => cambiarEstado({ id: m.id, ...v }),
    'Muestra actualizada.',
    () => {
      cerrar()
      setNota('')
    },
  )

  const anulada = m.estado === 'anulada'
  const entregada = m.estado === 'resultado_entregado'

  return (
    <section className="flex flex-col gap-3 border-t border-panel-hairline pt-4">
      <div className="flex flex-wrap gap-2">
        {!anulada && m.estado !== 'resultado_recibido' && !entregada && (
          <Button size="md" onClick={() => setDialogo('recibido')}>
            Resultado recibido
          </Button>
        )}
        {!anulada && !entregada && (
          <Button size="md" onClick={() => setDialogo('entregado')}>
            Resultado entregado
          </Button>
        )}
        <Button size="md" variant="outlined" onClick={() => setDialogo('corregir')}>
          Corregir el estado
        </Button>
        {!anulada && (
          <Button size="md" variant="danger" onClick={() => setDialogo('anular')}>
            Anular
          </Button>
        )}
        <Button size="md" variant="text" onClick={onClose}>
          Cerrar
        </Button>
      </div>

      {dialogo === 'recibido' && (
        <ConfirmDialog
          title="Resultado recibido"
          summary={`Llegó el resultado de ${m.codigo} del laboratorio. Ahora hay que enviárselo a ${m.paciente}.`}
          confirmLabel="Marcar como recibido"
          busy={poner.isPending}
          error={poner.mensaje}
          onConfirm={() => poner.mutate({ estado: 'resultado_recibido' })}
          onClose={cerrar}
        />
      )}

      {dialogo === 'entregado' && (
        <ConfirmDialog
          title="Resultado entregado"
          summary={`¿Por qué canal le enviaste el resultado de ${m.codigo} a ${m.paciente}?`}
          detail={
            <Segmented
              etiqueta="Canal"
              options={(['whatsapp', 'correo'] as const).map((c) => ({ value: c, label: ROTULO_CANAL[c] }))}
              value={canal}
              onChange={setCanal}
            />
          }
          confirmLabel="Marcar como entregado"
          busy={poner.isPending}
          error={poner.mensaje}
          onConfirm={() => poner.mutate({ estado: 'resultado_entregado', canal })}
          onClose={cerrar}
        />
      )}

      {dialogo === 'anular' && (
        <ConfirmDialog
          title="Anular la muestra"
          summary={`Vas a anular ${m.codigo}. El médico la verá como anulada.`}
          nivel="sensible"
          reasonLabel="Motivo de la anulación"
          confirmLabel="Anular"
          danger
          busy={poner.isPending}
          error={poner.mensaje}
          onConfirm={(motivo) => poner.mutate({ estado: 'anulada', nota: motivo })}
          onClose={cerrar}
        />
      )}

      {dialogo === 'corregir' && (
        <ConfirmDialog
          title="Corregir el estado"
          summary={`${m.codigo} está «${ROTULO_ESTADO[m.estado]}». Elige el estado correcto; queda anotado en la auditoría.`}
          detail={
            <div className="flex flex-col gap-3">
              <Segmented
                etiqueta="Estado"
                options={PASOS_MUESTRA.map((e) => ({ value: e, label: ROTULO_ESTADO[e] }))}
                value={nuevo === 'anulada' ? 'lista_para_retirar' : nuevo}
                onChange={setNuevo}
              />
              <Textarea id="nota-estado" label="Nota" rows={2} value={nota} onChange={setNota} />
            </div>
          }
          confirmLabel="Corregir"
          bloqueo={nuevo === m.estado ? 'Elige un estado distinto del actual.' : undefined}
          busy={poner.isPending}
          error={poner.mensaje}
          onConfirm={() =>
            poner.mutate({
              estado: nuevo,
              nota,
              canal: nuevo === 'resultado_entregado' ? (detalle.canalResultado ?? canal) : undefined,
            })
          }
          onClose={cerrar}
        />
      )}
    </section>
  )
}
