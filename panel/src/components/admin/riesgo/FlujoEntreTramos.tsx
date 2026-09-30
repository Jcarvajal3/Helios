import { useQuery } from '@tanstack/react-query'

import { Card, Table, Td, Tr, formatDayShort, formatPct, sumarDias } from '@/components/ui'
import { Cifra } from '@/components/admin/tableros/CifrasEnFila'
import { SelectorDePaso } from '@/components/admin/tableros/SelectorDePaso'
import { CLAVES_RIESGO, fetchFlujoEntreTramos } from '@/features/admin/riesgo/consultas'
import {
  TRAMOS,
  matrizDeFlujo,
  resumenDelFlujo,
  rotuloDeOrigen,
  sentidoDelPaso,
} from '@/features/admin/riesgo/flujo'
import type {
  FlujoEntreTramos as Flujo,
  OrigenDelPaso,
  SemanaDeFlujo,
} from '@/features/admin/riesgo/flujo'
import { Bloque } from './Bloque'

/** Cuántos lunes se piden. Ocho semanas bastan para ver una tendencia sin cargar la base. */
const SEMANAS = 8

const COLOR_DEL_SENTIDO = {
  entra: 'text-on-surface',
  mejora: 'text-success',
  igual: 'text-on-surface-variant',
  empeora: 'text-error',
} as const

/**
 * El paso entre tramos: de un lunes al siguiente, de dónde venía la gente
 * (fila) y dónde está ahora (columna).
 *
 * La mora por tramo es una foto; esto es el movimiento. Una mora estable puede
 * esconder que media cartera se pone al día y otra media entra nueva, y eso
 * solo se ve aquí. En la matriz, verde es mejorar de tramo y rojo empeorar:
 * es la forma de leerla, no un aviso. La semana se elige con las flechas de
 * la cabecera.
 */
export function FlujoEntreTramos({
  corte,
  onCambiarCorte,
}: {
  corte: string | undefined
  onCambiarCorte: (corte: string) => void
}) {
  const flujo = useQuery({
    queryKey: CLAVES_RIESGO.flujo(SEMANAS),
    queryFn: () => fetchFlujoEntreTramos(SEMANAS),
  })

  const semanas = flujo.data?.semanas ?? []
  // Sin corte en la URL, o con uno que ya no está en la ventana, el último.
  const elegida = semanas.find((s) => s.corte === corte) ?? semanas.at(-1)
  const i = elegida ? semanas.indexOf(elegida) : -1
  const anterior = i > 0 ? semanas.at(i - 1) : undefined
  const siguiente = i >= 0 ? semanas.at(i + 1) : undefined

  return (
    <Bloque
      titulo="El paso entre tramos"
      info="Cada lunes a las 10 de la mañana se mira en qué tramo está cada paciente, por su cuota más atrasada, y se compara con el lunes anterior. Los tramos son los de los parámetros vigentes hoy para todas las semanas, así que un cambio de parámetros no mueve a nadie de tramo. No cuenta las cuentas de prueba."
      consulta={flujo}
      aside={
        elegida && semanas.length > 1 ? (
          <SelectorDePaso
            etiqueta="Semana"
            rotulo={`Hasta el lunes ${formatDayShort(elegida.corte)}`}
            anterior={{
              onClick: () => anterior && onCambiarCorte(anterior.corte),
              disabled: !anterior,
              motivo: 'Es la semana más antigua que se lee.',
            }}
            siguiente={{
              onClick: () => siguiente && onCambiarCorte(siguiente.corte),
              disabled: !siguiente,
              motivo: 'Es la última semana.',
            }}
            opciones={[...semanas].reverse().map((s) => ({
              clave: s.corte,
              label: `Hasta el lunes ${formatDayShort(s.corte)}`,
              puesta: s.corte === elegida.corte,
              onElegir: () => onCambiarCorte(s.corte),
            }))}
          />
        ) : undefined
      }
    >
      {(data) =>
        elegida ? (
          <MatrizDeFlujo flujo={data} semana={elegida} />
        ) : (
          <Card>
            <p className="type-panel-body text-on-surface-variant">Todavía no hay semanas que comparar.</p>
          </Card>
        )
      }
    </Bloque>
  )
}

/**
 * La matriz de una semana del flujo: de dónde venía la gente (fila) y adónde
 * fue (columna), con la frase de arriba. La usa también Métricas › Cobranza y
 * riesgo, plegada debajo del paso de la semana.
 */
export function MatrizDeFlujo({ flujo, semana }: { flujo: Flujo; semana: SemanaDeFlujo }) {
  const filas = matrizDeFlujo(semana)
  const resumen = resumenDelFlujo(semana)
  const rotulo = (t: OrigenDelPaso) => rotuloDeOrigen(t, flujo.cortes)

  return (
    <>
      <p className="mb-3 type-panel-body text-on-surface-variant">
        Del lunes {formatDayShort(semana.desde ?? sumarDias(semana.corte, -7))}{' '}
        {semana.enCurso ? 'a hoy' : `al ${formatDayShort(semana.corte)}`}:{' '}
        <Cifra>{resumen.empeoran}</Cifra> {resumen.empeoran === 1 ? 'empeoró' : 'empeoraron'} de
        tramo y <Cifra>{resumen.mejoran}</Cifra> {resumen.mejoran === 1 ? 'mejoró' : 'mejoraron'}
        {resumen.estabanVencidos > 0 && (
          <>
            {' '}
            · <Cifra>{resumen.curados}</Cifra> de {resumen.estabanVencidos} con algo vencido se
            pusieron al día
          </>
        )}
      </p>

      {filas.length === 0 ? (
        <Card>
          <p className="type-panel-body text-on-surface-variant">
            Nadie tenía cuotas en ninguno de los dos lunes.
          </p>
        </Card>
      ) : (
        <Table
          headers={[
            { label: 'Estaban en', info: 'El tramo de cada paciente el lunes anterior. «Nuevos» son quienes todavía no tenían ninguna cuota.' },
            ...TRAMOS.map((t) => rotulo(t)),
            { label: 'Se pusieron al día', info: 'De quienes estaban en ese tramo, qué parte está al día este lunes.' },
          ]}
        >
          {filas.map((f) => {
            const cura = f.desde === 'nuevo' || f.desde === 'al_dia' ? null : semana.cura[f.desde]
            return (
              <Tr key={f.desde}>
                <Td className="whitespace-nowrap font-medium">{rotulo(f.desde)}</Td>
                {TRAMOS.map((t) => {
                  const n = f.hacia[t]
                  return (
                    <Td
                      key={t}
                      className={`tabular-nums ${
                        n === 0 ? 'text-panel-muted' : COLOR_DEL_SENTIDO[sentidoDelPaso(f.desde, t)]
                      }`}
                    >
                      {n}
                    </Td>
                  )
                })}
                <Td className="tabular-nums text-on-surface-variant">
                  {cura === null ? '' : cura.pct === null ? '—' : formatPct(cura.pct, 0)}
                </Td>
              </Tr>
            )
          })}
          <Tr>
            <Td className="whitespace-nowrap type-panel-caption text-panel-muted">
              Pacientes este lunes
            </Td>
            {TRAMOS.map((t) => (
              <Td key={t} className="tabular-nums type-panel-caption text-panel-muted">
                {semana.porTramo[t]}
              </Td>
            ))}
            <Td />
          </Tr>
        </Table>
      )}
    </>
  )
}
