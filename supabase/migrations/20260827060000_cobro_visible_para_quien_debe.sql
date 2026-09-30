-- ============================================================================
-- Ronda — Quien debe una cuota puede leer su cobro
--
-- 🐛 **Regresión introducida al retirar los grupos (2026-08-27).**
--
-- La política `charges_read_group_member` (20260826000000) existía para
-- arreglar exactamente este fallo: `confirm_charge_as_group` escribía
-- `charges.user_id = quien inicia`, y la única política de lectura era
-- `user_id = auth.uid()`, así que los otros siete integrantes tenían sus
-- cuotas pero la FILA DEL COBRO vedada. Como los embeds de PostgREST son left
-- joins, la app recibía la cuota con `charges` en null y la pintaba así:
--
--     Comercio · #0 · sin fecha
--
-- en la pestaña Cuotas, para todo el que no hubiera escaneado él mismo.
--
-- Aquella política se apoyaba en `my_group_ids()`. Al retirar los grupos, esa
-- función se quedó sin grupos que devolver y la política dejó de conceder
-- nada — mientras `confirm_charge_as_tab` sigue escribiendo `user_id = quien
-- inicia`. El mismo fallo, otra vez, y esta vez para toda la mesa.
--
-- ---------------------------------------------------------------------------
-- La condición correcta no era "es de mi grupo": es "yo debo parte de esto"
-- ---------------------------------------------------------------------------
-- La regla nueva mira `installments`, que es donde está escrito quién debe
-- qué. Es más simple, más estrecha y no hay que volver a tocarla cada vez que
-- aparezca una forma nueva de repartir: la mesa, el reparto posterior con el
-- QR de la orden (§3.6.2) y cualquier cosa que venga después caen dentro sin
-- añadir nada, porque todas acaban generando una cuota.
--
-- Sin riesgo de recursión: la política de `installments` solo mira
-- `user_id = auth.uid()` y no vuelve sobre `charges`.
--
-- Y es la baranda que faltaba, además: sin cuota no hay acceso, así que
-- adivinar el uuid de un cobro ajeno no enseña nada.
-- ============================================================================

drop policy if exists "charges_read_group_member" on public.charges;

create policy "charges_read_debtor"
  on public.charges for select to authenticated
  using (
    exists (
      select 1 from public.installments i
      where i.charge_id = charges.id
        and i.user_id = (select auth.uid())
    )
  );

comment on policy "charges_read_debtor" on public.charges is
  'Puedes leer un cobro si debes alguna de sus cuotas. Sustituye a charges_read_group_member, que dependía de los grupos retirados el 2026-08-27.';

-- La columna `group_name` se queda: es una copia congelada del nombre del
-- grupo en el momento del consumo, y hay recibos vivos que la usan. Su trigger
-- ya no dispara nada porque no nacen cobros con `group_id`.
