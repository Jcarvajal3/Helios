import { sumarDias } from '@/components/ui'
import type { OpcionDeFecha } from '@/components/ui'
import { mesAnteriorA, mesDe, nombreDelMes, ultimoDia } from '@/features/admin/cierreMes'
import { SelectorDePaso } from './SelectorDePaso'

/** Los meses que ofrece la lista; más lejos se llega con las flechas. */
const MESES_EN_LA_LISTA = 12

/**
 * El mes que se mira en el cierre y en la exportación: «‹ 📅 agosto de 2026 ▾ ›».
 *
 * La lista trae los últimos doce meses, del más nuevo al más viejo. Un mes
 * que todavía no ha empezado no se puede elegir.
 */
export function SelectorDeMes({
  mes,
  maximo,
  onMes,
}: {
  /** 'YYYY-MM'. */
  mes: string
  /** El último mes elegible, normalmente el del día operativo de hoy. */
  maximo: string
  onMes: (mes: string) => void
}) {
  const siguiente = mesDe(sumarDias(ultimoDia(mes), 1))

  const opciones: OpcionDeFecha[] = []
  let m = maximo
  for (let i = 0; i < MESES_EN_LA_LISTA; i++) {
    const este = m
    opciones.push({
      clave: este,
      label: nombreDelMes(este),
      puesta: este === mes,
      onElegir: () => onMes(este),
    })
    m = mesAnteriorA(m)
  }

  return (
    <SelectorDePaso
      etiqueta="Mes"
      rotulo={nombreDelMes(mes)}
      anterior={{ onClick: () => onMes(mesAnteriorA(mes)) }}
      siguiente={{
        onClick: () => onMes(siguiente),
        disabled: siguiente > maximo,
        motivo: 'Ese mes todavía no ha empezado.',
      }}
      opciones={opciones}
    />
  )
}
