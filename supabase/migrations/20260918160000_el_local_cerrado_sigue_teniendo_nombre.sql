-- ============================================================================
-- Ronda — Un local cerrado sigue teniendo nombre en tus cuotas
--
-- `merchants_read_active` dejaba pasar los comercios activos y los tuyos como
-- personal. Suena a regla del directorio, pero la RLS no distingue para qué se
-- lee una fila: la app lee el nombre del local con un embed de PostgREST
-- —`charges(merchants(name))`, en features/credit/api.ts y dos veces en
-- features/payments/api.ts— y un embed pasa por la misma policy.
--
-- Así que pausar o terminar un comercio no lo escondía solo del buscador:
-- borraba su nombre de las cuotas, del historial y del detalle de la cuenta de
-- todo el que hubiera consumido allí. Donde ponía «La Quinta Bar» pasaba a
-- poner «Comercio», que es el `?? 'Comercio'` que la app deja de red cuando el
-- embed viene vacío. La deuda sigue ahí y hay que pagarla, pero el recibo ya no
-- dice de qué era.
--
-- Es exactamente la trampa por la que `is_test` se dejó FUERA de la policy a
-- propósito —hay un comentario largo sobre esto en features/merchants/api.ts—;
-- con `status` se cayó en ella porque ahí el filtro sí vivía en la RLS.
--
-- ---------------------------------------------------------------------------
-- Lo que cambia
-- ---------------------------------------------------------------------------
-- Se añade una tercera puerta: **el local donde compraste**. Con eso el recibo
-- vuelve a tener nombre y el directorio sigue cerrado, que es lo que se pedía:
-- que no salga en el buscador, no que deje de existir.
--
-- No se abre la tabla entera (`using (true)`) porque no hace falta: nadie
-- necesita poder listar los locales pausados con los que no ha tenido nada que
-- ver. Quien sí lo necesita —el super admin— ya entra por `merchants_read_admin`.
--
-- Quien filtra el buscador sigue siendo el cliente, con el `status = 'active'`
-- explícito que `searchMerchants` y `fetchMerchantCities` ya tenían. Ahora es el
-- único filtro del directorio y por eso se dice aquí: si alguien lo quita, los
-- locales cerrados vuelven a la pantalla de Buscar.
-- ============================================================================

drop policy if exists "merchants_read_active" on public.merchants;

create policy "merchants_read_visible"
  on public.merchants for select to authenticated
  using (
    status = 'active'
    -- El personal ve el suyo aunque esté cerrado: es su panel.
    or id in (select public.my_merchant_ids())
    -- Y cualquiera ve el local en el que compró, esté como esté. Se mira por
    -- `installments` y no por `charges.user_id`: en un consumo de grupo el
    -- cargo es de quien lo confirmó, pero la cuota —y el recibo— son de cada
    -- integrante.
    or exists (
      select 1
      from public.installments i
      join public.charges c on c.id = i.charge_id
      where c.merchant_id = merchants.id
        and i.user_id = auth.uid()
    )
  );

comment on policy "merchants_read_visible" on public.merchants is
  'Ve un comercio quien puede ir a el (activo), quien trabaja en el, y quien compro alli alguna vez —para que su recibo conserve el nombre—. El buscador filtra los no activos en el cliente.';

-- La puerta nueva pregunta «¿tiene este usuario alguna cuota de este local?», y
-- los dos índices que necesita para no recorrer nada ya están puestos:
-- `installments_user_idx` y `charges_merchant_idx`. No hace falta ninguno nuevo.
