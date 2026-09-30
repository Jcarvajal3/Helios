import { Card, Seccion, Table, Td, Tr } from '@/components/ui'
import { PLANTILLAS, VARIABLES_DE_PLANTILLA } from '@/features/admin/avisos/avisos'

/**
 * Las plantillas de los avisos automáticos (contrato §4): cuáles hay, por qué
 * canal salen, cuándo y con qué variables.
 *
 * Solo lectura. TODO(contrato): editar su texto necesita una RPC que el
 * contrato todavía no tiene (`notification_templates`); mientras tanto se
 * cambian en la base. Las plantillas de cobranza, las que se abren a mano
 * desde Por cobrar, sí se editan: van debajo.
 */
export function PlantillasDeAvisos() {
  return (
    <Seccion
      titulo="Los avisos automáticos"
      info="Los mensajes que generan solos los crons: el comprobante por correo, la bienvenida, los recordatorios de cada cuota y lo que pasa con un pago. Se ven aquí para saber qué le llega al paciente y cuándo."
    >
      <Table headers={['Plantilla', 'Canal', 'Cuándo']}>
        {PLANTILLAS.map((p) => (
          <Tr key={p.clave}>
            <Td>
              <span className="font-medium text-on-surface">{p.rotulo}</span>
              <span className="mt-0.5 block font-mono type-panel-caption text-on-surface-variant">{p.clave}</span>
            </Td>
            <Td className="text-on-surface-variant">{p.canal}</Td>
            <Td className="text-on-surface-variant">{p.cuando}</Td>
          </Tr>
        ))}
      </Table>
      <Card tone="inset" className="mt-3">
        <p className="type-panel-label text-on-surface-variant">Variables que puede usar un texto</p>
        <dl className="mt-2 grid grid-cols-1 gap-x-6 gap-y-1 sm:grid-cols-2">
          {VARIABLES_DE_PLANTILLA.map((v) => (
            <div key={v.variable} className="flex gap-2 type-panel-caption">
              <dt className="font-mono text-on-surface">{v.variable}</dt>
              <dd className="text-on-surface-variant">{v.que}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-3 type-panel-caption text-on-surface-variant">
          Por ahora el texto de estos avisos no se edita desde el panel: pídeselo al equipo técnico.
        </p>
      </Card>
    </Seccion>
  )
}
