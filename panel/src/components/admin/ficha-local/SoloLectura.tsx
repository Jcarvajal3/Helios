import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { KeyRound } from 'lucide-react'

import { CabeceraDeFicha, MarcoDeFicha } from '@/components/admin/ficha'
import { AccionesDeFicha } from '@/components/admin/ficha/CarrilDeFicha'
import { LogoLocal } from '@/components/admin/directorio/LogoLocal'
import { OpcionesDelAlta, YaDadaDeAlta, darAccesoAlTitular } from '@/components/admin/directorio/AccesoDelTitular'
import type { DespuesDelAlta, OpcionesDeAcceso } from '@/components/admin/directorio/AccesoDelTitular'
import { Seccion } from '@/components/kit/Seccion'
import { Badge, Button, Card, DataLabel, ErrorBox, Modal, formatDateTime } from '@/components/ui'
import { MERCHANT_CATEGORY_LABEL } from '@/features/admin/api'
import type { MerchantDetail, MerchantRow } from '@/features/admin/api'
import { ALTA_VACIA, fichaParaCompartir, pareceCorreo } from '@/features/admin/clinicas/clinicas'
import type { AltaDeClinica } from '@/features/admin/clinicas/clinicas'
import { ESTADOS_LOCAL } from '@/features/admin/estados'
import { ROLE_LABEL } from '@/features/auth/permissions'
import { describeError } from '@/lib/supabase'
import { CopiarDatos } from './Cabecera'

/**
 * La ficha de una clínica para el capacitador (20261102130100): quién es el
 * médico, su consultorio y quién entra a su panel, para leer. Nada de dinero
 * —la base no se lo manda— ni de editar. Lo único que hace aquí es darle al
 * titular su primer acceso, si la clínica aún no tiene a nadie.
 */
export function FichaDeSoloLectura({
  merchant,
  detalle,
  onDone,
}: {
  merchant: MerchantRow
  detalle: MerchantDetail
  onDone: () => void
}) {
  const [dandoAcceso, setDandoAcceso] = useState(false)
  const estado = ESTADOS_LOCAL[merchant.status]
  const { datos, titular } = detalle
  const sinAcceso = detalle.staff.length === 0

  return (
    <>
      <MarcoDeFicha
        cabecera={
          <CabeceraDeFicha
            identidad={<LogoLocal name={merchant.name} logoUrl={merchant.logoUrl} size="lg" />}
            nombre={merchant.name}
            insignias={
              <>
                <Badge tone={estado.tone} icono>
                  {estado.label}
                </Badge>
                {merchant.isTest && <Badge>Clínica de prueba</Badge>}
              </>
            }
            datos={[
              merchant.consultorio,
              merchant.city,
              merchant.category ? MERCHANT_CATEGORY_LABEL[merchant.category] : null,
              `Alta el ${formatDateTime(merchant.createdAt)}`,
            ]}
            acciones={
              <CopiarDatos
                texto={fichaParaCompartir({
                  nombre: titular.doctorName ?? merchant.name,
                  especialidad: datos.specialty,
                  telefono: datos.phone,
                  direccion: datos.address,
                  ciudad: merchant.city,
                })}
              />
            }
          />
        }
        carril={
          <AccionesDeFicha
            titulo="Su acceso"
            info="El usuario con el que el médico entra a su panel. Darle el primero es parte de afiliarlo; los demás cambios de su personal los hace su administrador o un super admin."
          >
            {sinAcceso ? (
              <div className="flex flex-col gap-3">
                <p className="type-panel-body text-on-surface-variant">Todavía no tiene usuario para entrar a su panel.</p>
                <Button size="sm" onClick={() => setDandoAcceso(true)}>
                  <KeyRound size={14} aria-hidden /> Darle su acceso
                </Button>
              </div>
            ) : (
              <ul className="flex w-full flex-col gap-2">
                {detalle.staff.map((s) => (
                  <li key={s.userId} className="flex flex-col">
                    <span className="type-panel-body text-on-surface">{s.name ?? s.email ?? 'Sin nombre'}</span>
                    <span className="type-panel-caption text-on-surface-variant">
                      {s.role === 'inventario' ? 'Inventario' : ROLE_LABEL[s.role]}
                      {s.email && s.email !== s.name ? ` · ${s.email}` : ''}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </AccionesDeFicha>
        }
      >
        <Seccion titulo="El médico">
          <Card>
            <Datos
              filas={[
                ['Nombre', titular.doctorName ?? titular.ownerName],
                ['Cédula o RIF', titular.ownerDocument],
                ['Especialidad', datos.specialty],
                ['Colegio', titular.collegeNumber],
                ['MPPS', datos.mppsNumber],
              ]}
            />
          </Card>
        </Seccion>

        <Seccion titulo="El consultorio">
          <Card>
            <Datos
              filas={[
                ['Nombre', datos.consultorio],
                ['RIF', detalle.profile.taxId],
                ['Dirección', datos.address],
                ['Teléfono', datos.phone],
                ['Correo', datos.email],
              ]}
            />
          </Card>
        </Seccion>
      </MarcoDeFicha>

      {dandoAcceso && (
        <DarleSuAcceso
          merchantId={merchant.id}
          alta={{
            ...ALTA_VACIA,
            ownerName: titular.ownerName ?? '',
            clinicName: merchant.name,
            email: datos.email ?? '',
            phone: datos.phone ?? '',
          }}
          onClose={() => {
            setDandoAcceso(false)
            onDone()
          }}
        />
      )}
    </>
  )
}

/** Los datos en dos columnas: el rótulo y su valor, o una raya si no hay. */
function Datos({ filas }: { filas: ReadonlyArray<[string, string | null]> }) {
  return (
    <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-[10rem_minmax(0,1fr)]">
      {filas.map(([rotulo, valor]) => (
        <div key={rotulo} className="contents">
          <dt>
            <DataLabel>{rotulo}</DataLabel>
          </dt>
          <dd className="type-panel-body break-words text-on-surface">{valor?.trim() || '—'}</dd>
        </div>
      ))}
    </dl>
  )
}

/**
 * Su primer usuario, su número del bot y la bienvenida: lo mismo que al
 * aprobar o dar de alta, para una clínica que se afilió sin acceso.
 */
function DarleSuAcceso({
  merchantId,
  alta,
  onClose,
}: {
  merchantId: string
  alta: AltaDeClinica
  onClose: () => void
}) {
  const [opciones, setOpciones] = useState<OpcionesDeAcceso>({ crearUsuario: true, darBot: true })
  const dar = useMutation({
    mutationFn: (): Promise<DespuesDelAlta> => darAccesoAlTitular(merchantId, alta, opciones),
  })

  if (dar.data) return <YaDadaDeAlta despues={dar.data} alta={alta} onClose={onClose} />

  const sinCorreo = !pareceCorreo(alta.email)

  return (
    <Modal title={`Darle su acceso a ${alta.ownerName.trim() || alta.clinicName}`} width="md" onClose={onClose}>
      <div className="flex flex-col gap-4">
        <OpcionesDelAlta
          id="dar-acceso"
          alta={alta}
          opciones={opciones}
          onChange={setOpciones}
          titulo="Lo que se le da"
        />
        {sinCorreo && (
          <ErrorBox
            title="Su ficha no tiene un correo válido"
            detail="Su usuario entra con su correo. Pídele a un super admin que lo corrija en su perfil."
          />
        )}
        {dar.isError && <ErrorBox title="No se pudo darle su acceso" detail={describeError(dar.error)} />}
        <div>
          <Button
            size="md"
            disabled={dar.isPending || sinCorreo || !opciones.crearUsuario}
            onClick={() => dar.mutate()}
          >
            {dar.isPending ? 'Dándole su acceso…' : 'Darle su acceso'}
          </Button>
        </div>
      </div>
    </Modal>
  )
}
