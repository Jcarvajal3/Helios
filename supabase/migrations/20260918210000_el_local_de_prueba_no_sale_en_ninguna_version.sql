-- ============================================================================
-- Ronda — El local de prueba no sale en el buscador de ninguna versión
--
-- Los comercios de prueba se filtraban solo en el cliente
-- (`searchMerchants`, `.eq('is_test', false)`), y ese filtro se añadió el
-- 2026-09-17. Cualquier binario anterior —la 1.0.0 (23), sin ir más lejos—
-- sigue enseñándolos en Buscar, y desde el servidor no había forma de
-- arreglarlo: una app publicada lleva su propia consulta dentro.
--
-- La razón por la que el filtro vivía fuera de la RLS era buena: la policy
-- gobierna también el embed `charges(merchants(name))` con el que la app
-- pone el nombre del local en las cuotas y en el historial, así que esconder
-- la fila dejaba esos recibos diciendo «Comercio». Hay consumos de gente real
-- hechos en locales de prueba.
--
-- Lo que ha cambiado es que desde 20260918160000 la policy ya no es «activo o
-- mío»: tiene una tercera puerta, **el local donde compraste**. Con ella, el
-- motivo para dejar `is_test` fuera desaparece — quien tiene una cuota de ese
-- local entra por su propia puerta y su recibo conserva el nombre—, así que
-- ahora sí puede ir dentro.
--
-- Resultado: el local de prueba desaparece del buscador en TODAS las
-- versiones, viejas incluidas, sin publicar nada. Sigue cobrando, liquidando
-- y escaneándose por QR, porque ese camino va por RPC y no pasa por la RLS.
--
-- El filtro del cliente se queda donde está. No sobra: es el que mantiene
-- fuera del buscador a los locales **pausados o terminados**, que sí tienen
-- que seguir siendo legibles para cualquiera —a uno cerrado se puede volver—
-- y por eso su `status` no está en esta condición.
-- ============================================================================

drop policy if exists "merchants_read_visible" on public.merchants;

create policy "merchants_read_visible"
  on public.merchants for select to authenticated
  using (
    -- Un sitio al que se puede ir esta noche: activo y de verdad.
    (status = 'active' and not is_test)
    -- El personal ve el suyo, sea de prueba o esté cerrado: es su panel.
    or id in (select public.my_merchant_ids())
    -- Y cualquiera ve el local en el que compró, pase lo que pase con él. Se
    -- mira por `installments` y no por `charges.user_id`: en un consumo de
    -- grupo el cargo es de quien lo confirmó, pero la cuota —y el recibo— son
    -- de cada integrante.
    or exists (
      select 1
      from public.installments i
      join public.charges c on c.id = i.charge_id
      where c.merchant_id = merchants.id
        and i.user_id = auth.uid()
    )
  );

comment on policy "merchants_read_visible" on public.merchants is
  'Ve un comercio quien puede ir a el (activo y no de prueba), quien trabaja en el, y quien compro alli alguna vez —para que su recibo conserve el nombre—. Los pausados y terminados los filtra el cliente, que a esos si se puede volver.';
