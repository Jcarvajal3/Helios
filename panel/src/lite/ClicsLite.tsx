import { useMemo, useState } from 'react'
import { Link } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { useToast } from '@/components/Toast'
import { diaOperativo, formatPct } from '@/components/ui'
import { sumarDias } from '@/components/kit/rango'
import { consultaDirectorio, guardarTarjeta, refrescarDirectorio } from '@/features/admin/directorioDeMedicos/api'
import type { MedicoEnElDirectorio } from '@/features/admin/directorioDeMedicos/directorioDeMedicos'
import { consultaDeJuanPablo } from '@/features/admin/metricas/juan-pablo/api'
import { nombreDeEspecialidad } from '@/features/directorio/especialidades'
import { describeError } from '@/lib/supabase'
import { Barritas, cambio, inicialesDeMedico } from './kit'

/**
 * Personas › Clics por médico (Ads), como «Médicos del directorio» de la
 * maqueta: cada médico con su punto (publicado u oculto), sus clics al
 * WhatsApp y sus consultas de los últimos 30 días, las barritas de la semana,
 * «Ver médico» y el interruptor que lo publica u oculta en el directorio (el
 * mismo guardado que Pro, `admin_directorio_guardar`).
 */
const ENTERO = new Intl.NumberFormat('es-VE')

export function ClicsLite() {
  const client = useQueryClient()
  const avisar = useToast()
  const [texto, setTexto] = useState('')
  const hoy = diaOperativo()
  const directorio = useQuery(consultaDirectorio())
  const metricas = useQuery(consultaDeJuanPablo({ from: sumarDias(hoy, -29), to: hoy }))

  const publicar = useMutation({
    mutationFn: ({ id, visible }: { id: string; visible: boolean }) => guardarTarjeta(id, { visible }),
    onSuccess: (_, { visible }) => {
      refrescarDirectorio(client)
      avisar(visible ? 'Publicado en el directorio.' : 'Oculto del directorio.')
    },
    onError: (e) => avisar(describeError(e) ?? 'No se pudo guardar el directorio.'),
  })

  const filas = useMemo(() => {
    const ordenes = new Map((metricas.data?.porMedico ?? []).map((p) => [p.merchantId, p.ordenes]))
    const aguja = texto.trim().toLowerCase()
    return (directorio.data?.medicos ?? [])
      .filter((m) => !m.esPrueba && m.estado !== 'terminated')
      .filter((m) => !aguja || `${m.tarjeta.nombre} ${m.tarjeta.especialidad ?? ''} ${m.clinica}`.toLowerCase().includes(aguja))
      .map((m) => ({ m, ordenes: ordenes.get(m.id) ?? 0 }))
      .sort((a, b) => Number(b.m.visible) - Number(a.m.visible) || b.m.clics.d30 - a.m.clics.d30)
  }, [directorio.data, metricas.data, texto])

  return (
    <>
      <div className="lt-herramientas">
        <input
          className="lt-campo"
          type="search"
          value={texto}
          onChange={(e) => setTexto(e.target.value)}
          placeholder="Buscar médico o especialidad"
          aria-label="Buscar médico o especialidad"
        />
      </div>

      <section className="lt-panel">
        <div className="lt-panel-cabeza">
          <div>
            <h2>Médicos del directorio</h2>
            <p>Clics a WhatsApp y consultas registradas en los últimos 30 días</p>
          </div>
        </div>
        <div className="lt-desliza">
          <table className="lt-tabla">
            <thead>
              <tr>
                <th>Médico</th>
                <th className="lt-num">Clics a WhatsApp (Ads)</th>
                <th className="lt-num">Consultas en Helios</th>
                <th>Tendencia de clics</th>
                <th>
                  <span className="sr-only">Acciones</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {directorio.isPending && (
                <tr>
                  <td colSpan={5} className="lt-vacio">
                    Leyendo el directorio…
                  </td>
                </tr>
              )}
              {directorio.isError && (
                <tr>
                  <td colSpan={5} className="lt-vacio">
                    No se pudo leer el directorio.{' '}
                    <button type="button" className="lt-boton-texto" onClick={() => void directorio.refetch()}>
                      Reintentar
                    </button>
                  </td>
                </tr>
              )}
              {directorio.isSuccess && filas.length === 0 && (
                <tr>
                  <td colSpan={5} className="lt-vacio">
                    No hay médicos con ese nombre.
                  </td>
                </tr>
              )}
              {filas.map(({ m, ordenes }) => (
                <FilaDeMedico
                  key={m.id}
                  medico={m}
                  ordenes={ordenes}
                  ocupado={publicar.isPending && publicar.variables.id === m.id}
                  onPublicar={(visible) => publicar.mutate({ id: m.id, visible })}
                />
              ))}
            </tbody>
          </table>
        </div>
        <div className="lt-nota">
          Fuente: el botón de WhatsApp de conhelios.com/directorio. Un clic indica intención de contacto; no confirma una
          conversación ni una consulta.
        </div>
      </section>
    </>
  )
}

function FilaDeMedico({
  medico: m,
  ordenes,
  ocupado,
  onPublicar,
}: {
  medico: MedicoEnElDirectorio
  ordenes: number
  ocupado: boolean
  onPublicar: (visible: boolean) => void
}) {
  const nombre = m.tarjeta.nombre || m.clinica
  const semana = m.clics.porDia.slice(-7)
  const tendencia = cambio(
    semana.reduce((s, n) => s + n, 0),
    m.clics.porDia.slice(-14, -7).reduce((s, n) => s + n, 0),
  )
  // Una clínica pausada o sin WhatsApp no se puede publicar: lo dice la base.
  const bloqueada = m.bloqueo !== null

  return (
    <tr>
      <td>
        <div className="lt-medico">
          <span
            className="lt-punto-estado"
            data-apagado={!m.visible || undefined}
            role="img"
            aria-label={m.visible ? 'Publicado' : 'Oculto'}
            title={m.visible ? 'Publicado' : 'Oculto'}
          />
          <span className="lt-medico-avatar" aria-hidden>
            {inicialesDeMedico(nombre)}
          </span>
          <div>
            <strong>{nombre}</strong>
            <small>{m.tarjeta.especialidad ?? nombreDeEspecialidad(m.tarjeta.clave)}</small>
          </div>
        </div>
      </td>
      <td className="lt-num">
        <strong>{ENTERO.format(m.clics.d30)}</strong>
      </td>
      <td className="lt-num">{ENTERO.format(ordenes)}</td>
      <td>
        <Barritas serie={semana} />
        {tendencia !== undefined && (
          <span className="lt-tendencia">
            {tendencia >= 0 ? '+' : '−'}
            {formatPct(Math.abs(tendencia), 0)}
          </span>
        )}
      </td>
      <td style={{ textAlign: 'right' }}>
        <span className="lt-acciones-fila">
          <Link to="/admin/clinicas/$id" params={{ id: m.id }} className="lt-boton-texto">
            Ver médico →
          </Link>
          <button
            type="button"
            role="switch"
            className="lt-interruptor-fila"
            aria-checked={m.visible}
            aria-label={`Publicado en el directorio: ${nombre}`}
            title={bloqueada && !m.visible ? 'No se puede publicar: revisa su ficha' : m.visible ? 'Ocultar' : 'Publicar'}
            disabled={ocupado || (bloqueada && !m.visible)}
            onClick={() => onPublicar(!m.visible)}
          />
        </span>
      </td>
    </tr>
  )
}
