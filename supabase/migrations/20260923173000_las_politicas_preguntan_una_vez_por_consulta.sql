-- ============================================================================
-- Ronda — Las políticas preguntan quién eres una vez por consulta
--
-- Una política que llama a `auth.uid()` o a `is_platform_admin()` a secas
-- hace que Postgres las evalúe FILA POR FILA. `is_platform_admin()` además es
-- plpgsql y consulta `platform_admins`: ~22 µs por cada fila que la política
-- mira. Envueltas en `(select …)`, el planificador las calcula una vez al
-- principio de la consulta (un InitPlan) y cada fila solo compara un valor.
--
-- Pesa sobre todo en las tablas con dos políticas de lectura —la tuya y la
-- del administrador— porque RLS las une con OR: una lectura de la app sin
-- filtro de usuario sobre `installments` o `payment_reports` preguntaba
-- `is_platform_admin()` por cada cuota ajena de la tabla. La app ya filtra
-- por `user_id` (el mismo cambio, en el cliente), que es lo que deja al
-- planificador usar el índice; esto abarata lo que quede por recorrer.
--
-- Solo cambia CÓMO se evalúa la condición, no QUÉ deja ver: cada política
-- conserva su nombre, su orden, sus roles y la misma expresión con la
-- llamada envuelta. Por eso va con `alter policy` y no con drop/create: no
-- hay un instante sin política, y las que leen de otras tablas desde dentro
-- (`merchants_read_visible` mira cuotas y cobros con sus propias políticas)
-- siguen viendo exactamente lo mismo.
--
-- Y un índice que faltaba: `payment_reports` no tenía ninguno por usuario, y
-- la lista de pagos de la app filtra por él y ordena por fecha.
-- ============================================================================

create index if not exists payment_reports_user_created_idx
  on public.payment_reports (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Lecturas del administrador de la plataforma
-- ---------------------------------------------------------------------------
alter policy payment_reports_read_admin      on public.payment_reports       using ((select public.is_platform_admin()));
alter policy payment_quotes_read_admin       on public.payment_quotes        using ((select public.is_platform_admin()));
alter policy quote_items_read_admin          on public.payment_quote_items   using ((select public.is_platform_admin()));
alter policy installments_read_admin         on public.installments          using ((select public.is_platform_admin()));
alter policy charges_read_admin              on public.charges               using ((select public.is_platform_admin()));
alter policy profiles_read_admin             on public.profiles              using ((select public.is_platform_admin()));
alter policy credit_blocks_read_admin        on public.user_credit_blocks    using ((select public.is_platform_admin()));
alter policy merchants_read_admin            on public.merchants             using ((select public.is_platform_admin()));
alter policy merchant_users_read_admin       on public.merchant_users        using ((select public.is_platform_admin()));
alter policy branches_read_admin             on public.merchant_branches     using ((select public.is_platform_admin()));
alter policy payouts_read_admin              on public.merchant_payouts      using ((select public.is_platform_admin()));
alter policy payout_items_read_admin         on public.merchant_payout_items using ((select public.is_platform_admin()));
alter policy settlements_read_admin          on public.settlements           using ((select public.is_platform_admin()));
alter policy payment_destinations_read_admin on public.payment_destinations  using ((select public.is_platform_admin()));
alter policy bank_lines_read_admin           on public.bank_statement_lines  using ((select public.is_platform_admin()));
alter policy level_changes_read_admin        on public.level_changes         using ((select public.is_platform_admin()));

alter policy qa_case_marks_staff_read   on public.qa_case_marks using ((select public.is_platform_admin()));
alter policy qa_case_marks_staff_write  on public.qa_case_marks with check ((select public.is_platform_admin()));
alter policy qa_case_marks_staff_update on public.qa_case_marks
  using ((select public.is_platform_admin()))
  with check ((select public.is_platform_admin()));
alter policy qa_case_marks_staff_delete on public.qa_case_marks using ((select public.is_platform_admin()));

alter policy merchant_receipts_admin on storage.objects
  using (bucket_id = 'merchant-receipts' and (select public.is_platform_admin()))
  with check (bucket_id = 'merchant-receipts' and (select public.is_platform_admin()));

-- ---------------------------------------------------------------------------
-- La persona y su propia fila
-- ---------------------------------------------------------------------------
alter policy account_deletion_requests_select on public.account_deletion_requests
  using (user_id = (select auth.uid()) or (select public.is_platform_admin()));

-- ---------------------------------------------------------------------------
-- El gerente de un local
-- ---------------------------------------------------------------------------
alter policy settlements_read_merchant_staff on public.settlements
  using (merchant_id in (
    select mu.merchant_id
    from public.merchant_users mu
    where mu.user_id = (select auth.uid())
      and mu.is_active
      and mu.role = 'gerente'::public.merchant_role
  ));

alter policy payouts_read_merchant on public.merchant_payouts
  using (merchant_id in (
    select mu.merchant_id
    from public.merchant_users mu
    where mu.user_id = (select auth.uid())
      and mu.is_active
      and mu.role = 'gerente'::public.merchant_role
  ));

alter policy merchant_terms_read_staff on public.merchant_terms
  using (merchant_id in (
    select mu.merchant_id
    from public.merchant_users mu
    where mu.user_id = (select auth.uid())
      and mu.is_active
      and mu.role = 'gerente'::public.merchant_role
  ));

-- ---------------------------------------------------------------------------
-- Qué locales ve cada quien. Las tres puertas de siempre —el directorio, el
-- personal del local y quien le debe algo— y la tercera sigue leyendo cuotas
-- y cobros con SUS políticas.
-- ---------------------------------------------------------------------------
alter policy merchants_read_visible on public.merchants
  using (
    (status = 'active'::public.merchant_status and not is_test)
    or id in (select public.my_merchant_ids())
    or exists (
      select 1
      from public.installments i
      join public.charges c on c.id = i.charge_id
      where c.merchant_id = merchants.id
        and i.user_id = (select auth.uid())
    )
  );
