import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Plus, Save, X } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
  Badge,
  Button,
  Callout,
  Card,
  ErrorBox,
  Input,
  Seccion,
  Select,
  SkeletonCard,
  Switch,
  formatDateTime,
} from '@/components/ui'
import { guardarAjustesCompras } from '@/features/admin/compras/api'
import {
  CLAVE_COMPRAS,
  consultaAjustesCompras,
  consultaDiagnosticoSimulador,
} from '@/features/admin/compras/consultas'
import { rotuloDelProveedor } from '@/features/admin/compras/estados'
import type {
  AjustesComprasConfig,
  ProveedorCatalogoCompra,
} from '@/features/admin/compras/tipos'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

type ClaveNumerica =
  | 'taxUsaPct'
  | 'serviceFeePct'
  | 'airRatePerLbUsd'
  | 'airMinUsd'
  | 'seaRatePerFt3Usd'
  | 'seaMinUsd'
  | 'fallbackWeightLb'
  | 'quoteTtlHours'

/** Los mismos topes que valida la base: así el botón se apaga antes de que falle. */
const CAMPOS: ReadonlyArray<{
  clave: ClaveNumerica
  label: string
  hint?: string
  min: number
  max?: number
  entero?: boolean
  mayorQueMin?: boolean
}> = [
  {
    clave: 'taxUsaPct',
    label: 'Tax USA (%)',
    min: 0,
    max: 30,
    hint: 'Impuesto aplicado sobre el subtotal Amazon.',
  },
  {
    clave: 'serviceFeePct',
    label: 'Tarifa de gestión Helios (%)',
    min: 0,
    max: 50,
    hint: 'Porcentaje sobre el subtotal del producto.',
  },
  {
    clave: 'airRatePerLbUsd',
    label: 'Flete aéreo por libra (USD / lb)',
    min: 0,
  },
  { clave: 'airMinUsd', label: 'Mínimo flete aéreo (USD)', min: 0 },
  {
    clave: 'seaRatePerFt3Usd',
    label: 'Flete marítimo por pie cúbico (USD / ft³)',
    min: 0,
  },
  { clave: 'seaMinUsd', label: 'Mínimo flete marítimo (USD)', min: 0 },
  {
    clave: 'fallbackWeightLb',
    label: 'Peso de respaldo sin listar (lb)',
    min: 0,
    mayorQueMin: true,
    hint: 'Peso usado cuando Amazon no publica el peso.',
  },
  {
    clave: 'quoteTtlHours',
    label: 'Vigencia de cotización (horas)',
    min: 1,
    max: 168,
    entero: true,
  },
]

const E164 = /^\+[1-9]\d{7,14}$/

type Borrador = {
  numeros: Record<ClaveNumerica, string>
  catalogProvider: ProveedorCatalogoCompra
  isEnabled: boolean
  pilotPhones: string[]
}

function aBorrador(c: AjustesComprasConfig): Borrador {
  const numeros = Object.fromEntries(
    CAMPOS.map((f) => [f.clave, formatoMontoEditable(c[f.clave])]),
  ) as Record<ClaveNumerica, string>
  return {
    numeros,
    catalogProvider: c.catalogProvider,
    isEnabled: c.isEnabled,
    pilotPhones: c.pilotPhones,
  }
}

function leerCampo(f: (typeof CAMPOS)[number], texto: string): number | null {
  const n = leerMonto(texto)
  if (n === null) return null
  if (f.mayorQueMin ? n <= f.min : n < f.min) return null
  if (f.max !== undefined && n > f.max) return null
  if (f.entero && !Number.isInteger(n)) return null
  return n
}

export function AjustesCompras() {
  const query = useQuery(consultaAjustesCompras())

  if (query.isPending) return <SkeletonCard />
  if (query.isError) {
    return (
      <ErrorBox
        title="No se pudieron cargar los ajustes de compras"
        detail={describeError(query.error)}
      />
    )
  }
  return <FormularioAjustes ajustes={query.data} />
}

function FormularioAjustes({ ajustes }: { ajustes: AjustesComprasConfig }) {
  const esSuperAdmin = useIsSuperAdmin()
  const queryClient = useQueryClient()
  const avisar = useToast()
  const diagnostico = useQuery(consultaDiagnosticoSimulador())

  const [form, setForm] = useState<Borrador>(() => aBorrador(ajustes))
  const [telefonoNuevo, setTelefonoNuevo] = useState('')

  const telefono = telefonoNuevo.trim()
  const telefonoError =
    telefono === ''
      ? null
      : !E164.test(telefono)
        ? 'Formato internacional con +, por ejemplo +584141234567.'
        : form.pilotPhones.includes(telefono)
          ? 'Ese teléfono ya está en la lista.'
          : null

  const valores = CAMPOS.map((f) => leerCampo(f, form.numeros[f.clave]))
  const hayInvalidos = valores.some((v) => v === null)
  const abiertoConMock = form.isEnabled && form.catalogProvider === 'mock'
  const motivoApagado = !esSuperAdmin
    ? SOLO_SUPER_ADMIN
    : abiertoConMock
      ? 'Un catálogo de prueba no se abre a todos los médicos: elige Rainforest o deja solo el piloto.'
      : hayInvalidos
        ? 'Revisa los campos marcados: los valores tienen que ser números dentro de su rango.'
        : undefined

  const guardar = useMutation({
    mutationFn: () => {
      const [
        taxUsaPct,
        serviceFeePct,
        airRatePerLbUsd,
        airMinUsd,
        seaRatePerFt3Usd,
        seaMinUsd,
        fallbackWeightLb,
        quoteTtlHours,
      ] = valores
      if (
        taxUsaPct === null ||
        serviceFeePct === null ||
        airRatePerLbUsd === null ||
        airMinUsd === null ||
        seaRatePerFt3Usd === null ||
        seaMinUsd === null ||
        fallbackWeightLb === null ||
        quoteTtlHours === null
      ) {
        throw new Error('Revisa los valores numéricos antes de guardar.')
      }
      return guardarAjustesCompras({
        taxUsaPct,
        serviceFeePct,
        airRatePerLbUsd,
        airMinUsd,
        seaRatePerFt3Usd,
        seaMinUsd,
        fallbackWeightLb,
        quoteTtlHours,
        catalogProvider: form.catalogProvider,
        isEnabled: form.isEnabled,
        pilotPhones: form.pilotPhones,
      })
    },
    onSuccess: (actualizado) => {
      setForm(aBorrador(actualizado))
      void queryClient.invalidateQueries({ queryKey: CLAVE_COMPRAS })
      avisar('Ajustes de Compras Amazon actualizados.')
    },
  })

  function agregarTelefono() {
    if (telefono === '' || telefonoError) return
    setForm((f) => ({ ...f, pilotPhones: [...f.pilotPhones, telefono] }))
    setTelefonoNuevo('')
  }

  return (
    <div className="flex max-w-4xl flex-col gap-shell-gap-block">
      <Seccion titulo="Disponibilidad y proveedor">
        <Card className="flex flex-col gap-5">
          <div className="flex flex-col gap-2">
            <Switch
              id="compras-habilitado"
              label="Habilitado para todos los médicos"
              checked={form.isEnabled}
              disabled={!esSuperAdmin}
              onChange={(v) => setForm((f) => ({ ...f, isEnabled: v }))}
            />
            <p className="type-panel-caption text-on-surface-variant">
              Apagado: solo los teléfonos piloto ven la opción de comprar en
              WhatsApp. Encendido: la ven todos los médicos. Un catálogo de
              prueba nunca se puede abrir a todos.
            </p>
            {ajustes.updatedAt && (
              <p className="type-panel-caption text-panel-muted">
                Último cambio: {formatDateTime(ajustes.updatedAt)}
              </p>
            )}
          </div>

          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <Select
              id="compras-provider"
              label="Proveedor de catálogo Amazon"
              value={form.catalogProvider}
              options={[
                { value: 'mock', label: 'Catálogo de prueba' },
                { value: 'rainforest', label: 'Rainforest API (Amazon real)' },
              ]}
              onChange={(v) => setForm((f) => ({ ...f, catalogProvider: v }))}
              className="max-w-sm"
            />
            <div className="flex flex-wrap items-center gap-2 type-panel-caption text-on-surface-variant">
              Estado del proveedor guardado:
              {diagnostico.data && (
                <Badge
                  tone={diagnostico.data.proveedorListo ? 'success' : 'error'}
                  icono
                >
                  {rotuloDelProveedor(diagnostico.data)}
                </Badge>
              )}
              {diagnostico.isPending && <span>consultando…</span>}
              {diagnostico.isError && (
                <span className="text-error">
                  {describeError(diagnostico.error)}
                </span>
              )}
            </div>
          </div>

          <div className="flex flex-col gap-2 border-t border-panel-hairline pt-4">
            <p className="type-panel-body font-semibold text-on-surface">
              Teléfonos piloto
            </p>
            <ul className="flex flex-wrap gap-2" aria-label="Teléfonos piloto">
              {form.pilotPhones.length === 0 && (
                <li className="type-panel-caption text-on-surface-variant">
                  Ninguno todavía.
                </li>
              )}
              {form.pilotPhones.map((t) => (
                <li key={t}>
                  <Badge tone="neutral">
                    <span className="tabular-nums">{t}</span>
                    <button
                      type="button"
                      aria-label={`Quitar ${t}`}
                      disabled={!esSuperAdmin}
                      onClick={() =>
                        setForm((f) => ({
                          ...f,
                          pilotPhones: f.pilotPhones.filter((p) => p !== t),
                        }))
                      }
                    >
                      <X size={12} aria-hidden />
                    </button>
                  </Badge>
                </li>
              ))}
            </ul>
            <div className="flex items-start gap-2">
              <Input
                id="compras-piloto-nuevo"
                label="Agregar teléfono"
                value={telefonoNuevo}
                onChange={setTelefonoNuevo}
                inputMode="tel"
                placeholder="+584141234567"
                error={telefonoError !== null}
                hint={telefonoError ?? undefined}
                className="max-w-xs"
              />
              <div className="pt-6">
                <Button
                  size="md"
                  variant="tonal"
                  disabled={
                    !esSuperAdmin || telefono === '' || telefonoError !== null
                  }
                  motivoApagado={
                    !esSuperAdmin
                      ? SOLO_SUPER_ADMIN
                      : (telefonoError ?? undefined)
                  }
                  onClick={agregarTelefono}
                >
                  <Plus size={14} aria-hidden /> Agregar
                </Button>
              </div>
            </div>
          </div>
        </Card>
      </Seccion>

      <Seccion titulo="Tarifas y motor de cotización">
        <Card className="flex flex-col gap-5">
          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            {CAMPOS.map((f, i) => (
              <Input
                key={f.clave}
                id={`compras-${f.clave}`}
                label={f.label}
                value={form.numeros[f.clave]}
                onChange={(v) =>
                  setForm((b) => ({
                    ...b,
                    numeros: { ...b.numeros, [f.clave]: v },
                  }))
                }
                inputMode={f.entero ? 'numeric' : 'decimal'}
                error={valores[i] === null}
                hint={
                  valores[i] === null
                    ? `Valor inválido${f.max !== undefined ? ` (de ${f.min} a ${f.max})` : ''}.`
                    : f.hint
                }
              />
            ))}
          </div>

          {guardar.isError && (
            <ErrorBox
              title="No se pudieron guardar los ajustes"
              detail={describeError(guardar.error)}
            />
          )}

          <div className="flex flex-wrap items-start gap-3 border-t border-panel-hairline pt-4">
            <Button
              size="md"
              disabled={motivoApagado !== undefined || guardar.isPending}
              motivoApagado={motivoApagado}
              onClick={() => guardar.mutate()}
            >
              <Save size={15} aria-hidden />
              {guardar.isPending ? 'Guardando…' : 'Guardar ajustes'}
            </Button>
          </div>
        </Card>
      </Seccion>

      <Callout tone="info" titulo="Cómo activar el catálogo de Amazon real">
        Guarda la clave de Rainforest como secreto de Edge Functions con el
        nombre <span className="font-mono">RAINFOREST_API_KEY</span>, elige
        «Rainforest API» arriba y revisa que el estado diga «listo». Sin la
        clave, el bot responde que las compras no están disponibles; nunca cae
        al catálogo de prueba.
      </Callout>
    </div>
  )
}
