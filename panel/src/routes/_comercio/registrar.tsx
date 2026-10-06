import { useEffect, useState } from 'react'
import { createFileRoute, useBlocker } from '@tanstack/react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { RotateCcw } from 'lucide-react'

import { PageAction } from '@/components/layouts/PageAction'
import { Pasos } from '@/components/registrar/Pasos'
import { PasoCedula } from '@/components/registrar/PasoCedula'
import { PasoConfirmar } from '@/components/registrar/PasoConfirmar'
import { PasoDatos } from '@/components/registrar/PasoDatos'
import { PasoListo } from '@/components/registrar/PasoListo'
import { PasoMonto } from '@/components/registrar/PasoMonto'
import { Button, ConfirmDialog, formatUsd, hoyCaracas } from '@/components/ui'
import { useStaff } from '@/features/auth/session'
import type { StaffContext } from '@/features/auth/session'
import { claveDelAlta, estrenarClaveDelAlta } from '@/features/merchant/claveDelAlta'
import {
  PACIENTE_VACIO,
  cedulaLegible,
  cedulaParaEnviar,
  correoLimpio,
  hayDatosDePaciente,
  limpio,
  pacienteParaEnviar,
  problemaDeCedula,
} from '@/features/merchant/paciente'
import type { BorradorPaciente, CampoDePaciente, Nacionalidad } from '@/features/merchant/paciente'
import {
  CONCEPTO_SUGERIDO,
  coincideConLoPedido,
  leerMontoDeConsulta,
  maximoParaFinanciar,
} from '@/features/merchant/registro'
import type { Elegibilidad, Financiamiento, PasoDelAlta } from '@/features/merchant/registro'
import {
  consultarCedula,
  fetchConfirmacionRequerida,
  registrarFinanciamiento,
} from '@/features/merchant/registroApi'

export const Route = createFileRoute('/_comercio/registrar')({
  staticData: { title: 'Nuevo pago en cuotas' },
  component: RegistrarRoute,
})

function RegistrarRoute() {
  const staff = useStaff()
  if (!staff) return null
  return <Registrar staff={staff} />
}

type Paso = PasoDelAlta | 'listo'

/** La consulta de cédula que se hizo, atada a la cédula exacta que se consultó. */
type Consulta = { documento: string; elegibilidad: Elegibilidad }

type Resultado = { financiamiento: Financiamiento; coincide: boolean }

/**
 * NUEVO PAGO EN CUOTAS (plan §2.1): la secretaria registra al paciente y la
 * consulta en un solo paso, con el paciente delante.
 *
 *   1. Cédula     → `helios_patient_eligibility`: nuevo, disponible o no.
 *   2. Datos      → solo si es nuevo. Uno conocido no se vuelve a pedir.
 *   3. Monto      → libre, del mínimo a lo disponible, con su concepto.
 *   4. Confirmar  → `preview_patient_charge` y el sí del paciente.
 *   5. Listo      → `create_patient_charge`: número, cuotas y comprobante.
 *
 * Todo se maneja con el teclado: cada paso es un formulario, Enter avanza y
 * el foco va solo al primer campo de cada paso (o al primero que falte).
 *
 * Lo que protege de los accidentes:
 *
 *   · La clave de idempotencia se crea al abrir el formulario y vive en
 *     `sessionStorage` (`claveDelAlta`): un doble clic o una recarga con la
 *     respuesta perdida devuelven el mismo pago en cuotas, no otro.
 *   · Salir con datos a medias —otro ítem del menú, cerrar la pestaña,
 *     recargar— pregunta antes (`useBlocker`).
 *   · Tras el alta, todo se vacía y la clave se estrena: el paciente
 *     siguiente es otro pago en cuotas.
 */
function Registrar({ staff }: { staff: StaffContext }) {
  const queryClient = useQueryClient()

  const [paso, setPaso] = useState<Paso>('cedula')
  const [nacionalidad, setNacionalidad] = useState<Nacionalidad>('V')
  const [numero, setNumero] = useState('')
  const [consulta, setConsulta] = useState<Consulta | null>(null)
  const [intentado, setIntentado] = useState(false)
  const [noCoincide, setNoCoincide] = useState(false)
  const [paciente, setPaciente] = useState<BorradorPaciente>(PACIENTE_VACIO)
  const [monto, setMonto] = useState('')
  const [concepto, setConcepto] = useState(CONCEPTO_SUGERIDO)
  const [beneficiario, setBeneficiario] = useState('')
  const [resultado, setResultado] = useState<Resultado | null>(null)

  // ¿La orden espera el Sí del paciente por WhatsApp? Lo decide Helios; solo
  // cambia lo que dice el paso de confirmar. Si no se sabe, el texto de antes.
  const confirmacion = useQuery({
    queryKey: ['confirmacion-requerida'],
    queryFn: fetchConfirmacionRequerida,
    staleTime: 5 * 60_000,
  })

  // El día de hoy, para la edad. Se lee al montar y no en cada tecla.
  const [hoy] = useState(hoyCaracas)

  // La clave nace al abrir el formulario. En un efecto y no al pintar: en el
  // servidor no hay `sessionStorage`, y generarla ahí no serviría de nada.
  useEffect(() => {
    claveDelAlta()
  }, [])

  const documento = cedulaParaEnviar(nacionalidad, numero)
  // La respuesta solo vale para la cédula que está escrita. Si se cambia un
  // dígito, lo de antes deja de verse: era de otra persona.
  const elegibilidad =
    consulta && consulta.documento === documento ? consulta.elegibilidad : null
  const esNuevo = elegibilidad?.estado === 'nuevo'
  const minimo =
    elegibilidad && elegibilidad.estado !== 'no_disponible' ? elegibilidad.minChargeUsd : 0
  const maximo = elegibilidad ? maximoParaFinanciar(elegibilidad) : null
  const lecturaMonto = leerMontoDeConsulta(monto, { minimo, maximo }, formatUsd)

  // Un paso que se quedó sin lo que necesita —se cambió la cédula y ya no hay
  // respuesta para ella— vuelve al principio en vez de dejar la pantalla vacía.
  const sinConsulta = paso !== 'cedula' && paso !== 'listo' && !elegibilidad
  useEffect(() => {
    if (sinConsulta) setPaso('cedula')
  }, [sinConsulta])

  const elegir = useMutation({
    mutationFn: consultarCedula,
    onSuccess: (e, variables) => {
      setConsulta({ documento: variables.document, elegibilidad: e })
      setNoCoincide(false)
    },
  })

  const alta = useMutation({
    mutationFn: registrarFinanciamiento,
    onSuccess: (f, variables) => {
      const documentoPedido = variables.patient.document ?? ''
      const coincide = coincideConLoPedido(f, {
        amountUsd: variables.amountUsd,
        document: documentoPedido,
      })
      setResultado({ financiamiento: f, coincide })
      setPaso('listo')
      // El alta ya existe: el paciente siguiente es otro financiamiento.
      estrenarClaveDelAlta()
      // Con el alta hecha, los datos tecleados sobran: fuera de la memoria de
      // la pantalla. Salvo si la base devolvió un alta anterior: entonces
      // son justo lo que hace falta para registrar el que se quería.
      if (coincide) limpiarFormulario()
      // Las listas del panel ya no están al día.
      void queryClient.invalidateQueries({ queryKey: ['merchant-transactions'] })
      void queryClient.invalidateQueries({ queryKey: ['merchant-transactions-summary'] })
      void queryClient.invalidateQueries({ queryKey: ['merchant-sales-by-staff'] })
      void queryClient.invalidateQueries({ queryKey: ['comisiones'] })
    },
  })

  // ── Salir con datos a medias ──────────────────────────────────────────
  const conDatos =
    paso !== 'listo' &&
    (numero.trim() !== '' || hayDatosDePaciente(paciente) || monto.trim() !== '')

  const bloqueo = useBlocker({
    // Cambiar solo la búsqueda de la misma pantalla no es salir.
    shouldBlockFn: ({ current, next }) =>
      (conDatos || alta.isPending) && current.pathname !== next.pathname,
    enableBeforeUnload: () => conDatos || alta.isPending,
    withResolver: true,
  })

  // ── Transiciones ──────────────────────────────────────────────────────
  /**
   * Vacía lo tecleado. La clave NO se estrena aquí: si un alta anterior llegó
   * a la base y su respuesta se perdió, volver a teclear el mismo paciente
   * tiene que devolver aquella y no crear otra. Solo un alta buena la cambia.
   */
  function limpiarFormulario() {
    setNacionalidad('V')
    setNumero('')
    setConsulta(null)
    setIntentado(false)
    setNoCoincide(false)
    setPaciente(PACIENTE_VACIO)
    setMonto('')
    setConcepto(CONCEPTO_SUGERIDO)
    setBeneficiario('')
    elegir.reset()
  }

  /** «Registrar otro» y «Empezar de nuevo»: al principio, sin nada. */
  function empezarDeCero() {
    limpiarFormulario()
    setResultado(null)
    alta.reset()
    setPaso('cedula')
  }

  function seguirDesdeLaCedula() {
    setPaso(esNuevo ? 'datos' : 'monto')
  }

  function consultar() {
    setIntentado(true)
    if (problemaDeCedula(numero) || elegir.isPending) return
    // Cada consulta cuenta contra el límite diario de la secretaria: un
    // segundo Enter sobre la misma cédula ya contestada sigue adelante en vez
    // de volver a preguntar.
    if (elegibilidad) {
      if (elegibilidad.estado !== 'no_disponible' && !noCoincide) seguirDesdeLaCedula()
      return
    }
    elegir.mutate({ merchantId: staff.merchantId, document: documento })
  }

  function cambiarCedula(n: Nacionalidad, num: string) {
    setNacionalidad(n)
    setNumero(num)
    // Lo que diga el error de la consulta anterior ya no es de esta cédula.
    if (elegir.isError) elegir.reset()
  }

  function irA(destino: PasoDelAlta) {
    alta.reset()
    setPaso(destino)
  }

  function confirmar() {
    if (!elegibilidad || !lecturaMonto.ok || alta.isPending) return
    const concept = limpio(concepto)
    const beneficiary = limpio(beneficiario)
    alta.mutate({
      merchantId: staff.merchantId,
      branchId: staff.branchId,
      // Un paciente conocido va solo con su cédula: la base no le cambia nada.
      patient: esNuevo ? pacienteParaEnviar(documento, paciente, hoy) : { document: documento },
      amountUsd: lecturaMonto.usd,
      concept: concept === '' ? null : concept,
      beneficiaryName: beneficiary === '' ? null : beneficiary,
      idempotencyKey: claveDelAlta(),
    })
  }

  // ── Lo que se enseña ──────────────────────────────────────────────────
  const documentoLegible = `${nacionalidad}-${cedulaLegible(numero)}`
  const titular = esNuevo
    ? `${limpio(`${paciente.firstName} ${paciente.lastName}`)} · ${documentoLegible}`
    : elegibilidad?.estado === 'disponible'
      ? `${elegibilidad.nombreEnmascarado ?? 'Paciente'} · ${documentoLegible}`
      : documentoLegible
  const correoDestino = esNuevo
    ? correoLimpio(paciente.email)
    : elegibilidad?.estado === 'disponible'
      ? elegibilidad.emailEnmascarado
      : null

  return (
    <div className="mx-auto flex max-w-3xl flex-col">
      {conDatos && (
        <PageAction>
          <Button size="sm" variant="text" onClick={empezarDeCero}>
            <RotateCcw size={15} aria-hidden />
            Empezar de nuevo
          </Button>
        </PageAction>
      )}

      {paso !== 'listo' && <Pasos actual={paso} sinDatos={elegibilidad?.estado === 'disponible'} />}

      {paso === 'cedula' && (
        <PasoCedula
          nacionalidad={nacionalidad}
          numero={numero}
          onNacionalidad={(n) => cambiarCedula(n, numero)}
          onNumero={(num) => cambiarCedula(nacionalidad, num)}
          consultando={elegir.isPending}
          error={elegir.error}
          elegibilidad={elegibilidad}
          noCoincide={noCoincide}
          intentado={intentado}
          onConsultar={consultar}
          onSeguir={seguirDesdeLaCedula}
          onNoCoincide={() => setNoCoincide(true)}
        />
      )}

      {paso === 'datos' && esNuevo && (
        <PasoDatos
          documentoLegible={documentoLegible}
          paciente={paciente}
          onCambio={(campo: CampoDePaciente, valor: string) =>
            setPaciente((p) => ({ ...p, [campo]: valor }))
          }
          hoy={hoy}
          onAtras={() => setPaso('cedula')}
          onSeguir={() => setPaso('monto')}
        />
      )}

      {paso === 'monto' && elegibilidad && elegibilidad.estado !== 'no_disponible' && (
        <PasoMonto
          titular={titular}
          monto={monto}
          concepto={concepto}
          beneficiario={beneficiario}
          minimo={minimo}
          maximo={maximo}
          onMonto={setMonto}
          onConcepto={setConcepto}
          onBeneficiario={setBeneficiario}
          onAtras={() => setPaso(esNuevo ? 'datos' : 'cedula')}
          atrasLabel={esNuevo ? 'Volver a los datos' : 'Cambiar la cédula'}
          onSeguir={() => setPaso('confirmar')}
        />
      )}

      {paso === 'confirmar' && elegibilidad && lecturaMonto.ok && (
        <PasoConfirmar
          merchantId={staff.merchantId}
          documento={documento}
          amountUsd={lecturaMonto.usd}
          concepto={limpio(concepto) === '' ? null : limpio(concepto)}
          beneficiario={limpio(beneficiario) === '' ? null : limpio(beneficiario)}
          titular={titular}
          correoDestino={correoDestino}
          esNuevo={esNuevo}
          conConfirmacion={confirmacion.data === true}
          confirmando={alta.isPending}
          errorAlta={alta.error}
          onConfirmar={confirmar}
          onIrA={irA}
        />
      )}

      {paso === 'listo' && resultado && (
        <PasoListo
          financiamiento={resultado.financiamiento}
          coincide={resultado.coincide}
          onOtro={empezarDeCero}
          onRegistrarElQueQueria={() => {
            // La clave ya se estrenó al recibir el alta vieja: volver a
            // confirmar crea el que se quería, con los datos que siguen ahí.
            setResultado(null)
            alta.reset()
            setPaso('confirmar')
          }}
        />
      )}

      {bloqueo.status === 'blocked' && (
        <ConfirmDialog
          title="¿Salir sin registrar?"
          summary={
            alta.isPending
              ? 'El pago en cuotas se está registrando ahora mismo. Espera a que termine para no perder la respuesta.'
              : 'Se pierden los datos que escribiste de este paciente. El pago en cuotas no se ha registrado.'
          }
          confirmLabel="Salir sin registrar"
          danger
          onConfirm={() => bloqueo.proceed()}
          onClose={() => bloqueo.reset()}
        />
      )}
    </div>
  )
}
