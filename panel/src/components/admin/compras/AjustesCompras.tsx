import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Save } from 'lucide-react'

import { useToast } from '@/components/Toast'
import {
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
import { CLAVE_COMPRAS, consultaAjustesCompras } from '@/features/admin/compras/consultas'
import type { AjustesComprasConfig, ProveedorCatalogoCompra } from '@/features/admin/compras/tipos'
import { SOLO_SUPER_ADMIN, useIsSuperAdmin } from '@/features/admin/role'
import { formatoMontoEditable, leerMonto } from '@/lib/montos'
import { describeError } from '@/lib/supabase'

type BorradorAjustes = {
  taxUsaPct: string
  serviceFeePct: string
  airRatePerLbUsd: string
  airMinUsd: string
  seaRatePerFt3Usd: string
  seaMinUsd: string
  fallbackWeightLb: string
  quoteTtlHours: string
  catalogProvider: ProveedorCatalogoCompra
  isEnabled: boolean
}

function aBorrador(c: AjustesComprasConfig): BorradorAjustes {
  return {
    taxUsaPct: formatoMontoEditable(c.taxUsaPct),
    serviceFeePct: formatoMontoEditable(c.serviceFeePct),
    airRatePerLbUsd: formatoMontoEditable(c.airRatePerLbUsd),
    airMinUsd: formatoMontoEditable(c.airMinUsd),
    seaRatePerFt3Usd: formatoMontoEditable(c.seaRatePerFt3Usd),
    seaMinUsd: formatoMontoEditable(c.seaMinUsd),
    fallbackWeightLb: formatoMontoEditable(c.fallbackWeightLb),
    quoteTtlHours: formatoMontoEditable(c.quoteTtlHours),
    catalogProvider: c.catalogProvider,
    isEnabled: c.isEnabled,
  }
}

export function AjustesCompras() {
  const esSuperAdmin = useIsSuperAdmin()
  const queryClient = useQueryClient()
  const avisar = useToast()
  const query = useQuery(consultaAjustesCompras())

  const [form, setForm] = useState<BorradorAjustes | null>(null)

  useEffect(() => {
    if (query.data && form === null) {
      setForm(aBorrador(query.data))
    }
  }, [query.data, form])

  const guardar = useMutation({
    mutationFn: () => {
      if (!form) throw new Error('Sin datos de configuración.')
      const taxUsaPct = leerMonto(form.taxUsaPct)
      const serviceFeePct = leerMonto(form.serviceFeePct)
      const airRatePerLbUsd = leerMonto(form.airRatePerLbUsd)
      const airMinUsd = leerMonto(form.airMinUsd)
      const seaRatePerFt3Usd = leerMonto(form.seaRatePerFt3Usd)
      const seaMinUsd = leerMonto(form.seaMinUsd)
      const fallbackWeightLb = leerMonto(form.fallbackWeightLb)
      const quoteTtlHours = leerMonto(form.quoteTtlHours)

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
        quoteTtlHours: Math.max(1, Math.round(quoteTtlHours)),
        catalogProvider: form.catalogProvider,
        isEnabled: form.isEnabled,
      })
    },
    onSuccess: (actualizado) => {
      setForm(aBorrador(actualizado))
      void queryClient.invalidateQueries({ queryKey: CLAVE_COMPRAS })
      avisar('Tarifas y parámetros de Compras Amazon actualizados.')
    },
  })

  if (query.isPending || !form) {
    return <SkeletonCard />
  }

  if (query.isError) {
    return (
      <ErrorBox
        title="No se pudieron cargar los ajustes de compras"
        detail={describeError(query.error)}
      />
    )
  }

  const valoresInvalidos =
    leerMonto(form.taxUsaPct) === null ||
    leerMonto(form.serviceFeePct) === null ||
    leerMonto(form.airRatePerLbUsd) === null ||
    leerMonto(form.airMinUsd) === null ||
    leerMonto(form.seaRatePerFt3Usd) === null ||
    leerMonto(form.seaMinUsd) === null ||
    leerMonto(form.fallbackWeightLb) === null ||
    leerMonto(form.quoteTtlHours) === null

  return (
    <div className="flex max-w-4xl flex-col gap-shell-gap-block">
      <Seccion titulo="Tarifas y motor de cotización">
        <Card className="flex flex-col gap-5">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-panel-hairline pb-4">
            <Switch
              id="compras-habilitado"
              label="Módulo Compras Amazon activo en WhatsApp"
              checked={form.isEnabled}
              disabled={!esSuperAdmin}
              onChange={(v) => setForm((f) => (f ? { ...f, isEnabled: v } : f))}
            />
            {query.data.updatedAt && (
              <p className="type-panel-caption text-panel-muted">
                Último cambio: {formatDateTime(query.data.updatedAt)}
              </p>
            )}
          </div>

          <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            <Input
              id="compras-tax-usa"
              label="Tax USA (%)"
              value={form.taxUsaPct}
              onChange={(v) => setForm((f) => (f ? { ...f, taxUsaPct: v } : f))}
              inputMode="decimal"
              hint="Impuesto estatal de Florida/casillero aplicado sobre el subtotal Amazon."
            />
            <Input
              id="compras-tarifa-gestion"
              label="Tarifa de gestión Helios (%)"
              value={form.serviceFeePct}
              onChange={(v) => setForm((f) => (f ? { ...f, serviceFeePct: v } : f))}
              inputMode="decimal"
              hint="Porcentaje de gestión aplicado sobre el subtotal del producto en Amazon."
            />
            <Input
              id="compras-air-rate"
              label="Flete aéreo por libra (USD / lb)"
              value={form.airRatePerLbUsd}
              onChange={(v) => setForm((f) => (f ? { ...f, airRatePerLbUsd: v } : f))}
              inputMode="decimal"
            />
            <Input
              id="compras-air-min"
              label="Mínimo flete aéreo (USD)"
              value={form.airMinUsd}
              onChange={(v) => setForm((f) => (f ? { ...f, airMinUsd: v } : f))}
              inputMode="decimal"
            />
            <Input
              id="compras-sea-rate"
              label="Flete marítimo por pie cúbico (USD / ft³)"
              value={form.seaRatePerFt3Usd}
              onChange={(v) => setForm((f) => (f ? { ...f, seaRatePerFt3Usd: v } : f))}
              inputMode="decimal"
            />
            <Input
              id="compras-sea-min"
              label="Mínimo flete marítimo (USD)"
              value={form.seaMinUsd}
              onChange={(v) => setForm((f) => (f ? { ...f, seaMinUsd: v } : f))}
              inputMode="decimal"
            />
            <Input
              id="compras-fallback-weight"
              label="Peso de respaldo sin listar (lb)"
              value={form.fallbackWeightLb}
              onChange={(v) => setForm((f) => (f ? { ...f, fallbackWeightLb: v } : f))}
              inputMode="decimal"
              hint="Peso usado cuando Amazon no publica el peso del artículo."
            />
            <Input
              id="compras-quote-ttl"
              label="Vigencia de cotización (horas)"
              value={form.quoteTtlHours}
              onChange={(v) => setForm((f) => (f ? { ...f, quoteTtlHours: v } : f))}
              inputMode="numeric"
            />
            <Select
              id="compras-provider"
              label="Proveedor de catálogo Amazon"
              value={form.catalogProvider}
              options={[
                { value: 'mock', label: 'Catálogo Mock local (pruebas y simulador)' },
                { value: 'rainforest', label: 'Rainforest API (Amazon en vivo)' },
                { value: 'oxylabs', label: 'Oxylabs API (Amazon en vivo)' },
                { value: 'rapidapi', label: 'RapidAPI Amazon (Amazon en vivo)' },
              ]}
              onChange={(v) => setForm((f) => (f ? { ...f, catalogProvider: v } : f))}
            />
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
              disabled={!esSuperAdmin || valoresInvalidos || guardar.isPending}
              motivoApagado={
                !esSuperAdmin
                  ? SOLO_SUPER_ADMIN
                  : valoresInvalidos
                    ? 'Completa todos los campos con números válidos.'
                    : undefined
              }
              onClick={() => guardar.mutate()}
            >
              <Save size={15} aria-hidden />
              {guardar.isPending ? 'Guardando…' : 'Guardar tarifas'}
            </Button>
          </div>
        </Card>
      </Seccion>

      <Callout tone="info" titulo="Cómo activar el catálogo de Amazon en vivo">
        Mientras no se contrate la API externa, el módulo trabaja con el catálogo médico de pruebas
        y el Simulador WhatsApp. Para conectar precios e inventario reales de Amazon en la función
        de WhatsApp, configura los secretos de Supabase Edge Functions:{' '}
        <span className="font-mono">AMAZON_PROVIDER=rainforest</span> y{' '}
        <span className="font-mono">AMAZON_API_KEY=&lt;tu_clave&gt;</span>, y selecciona
        «Rainforest API» en el desplegable superior.
      </Callout>
    </div>
  )
}
