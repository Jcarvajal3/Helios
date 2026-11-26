-- ============================================================================
-- El teléfono del médico en la lista de clínicas
--
-- La lista de `/admin/clinicas` gana un botón de WhatsApp que abre el chat
-- con el médico titular. El número es el de su perfil (`merchants.phone`, el
-- que se pone en el alta y se corrige en la ficha). Va crudo: la vista es
-- `security_invoker` y `helios_normalize_ve_phone` no se le da a
-- `authenticated`; el panel lo pasa a formato de wa.me.
--
-- La columna va al final: `create or replace view` solo admite añadirlas ahí.
-- ============================================================================

create or replace view public.merchant_directory
with (security_invoker = true) as
 SELECT id,
    name,
    legal_name,
    tax_id,
    status,
    created_at,
    ( SELECT count(*) AS count
           FROM merchant_users mu
          WHERE mu.merchant_id = m.id AND mu.is_active) AS staff_count,
    ( SELECT count(*) AS count
           FROM charges c
          WHERE c.merchant_id = m.id AND c.status = 'confirmed'::charge_status AND NOT c.is_test) AS sales_count,
    category,
    city,
    handle,
    logo_url,
    social_url,
    is_test,
    ( SELECT count(*) AS count
           FROM charges c
          WHERE c.merchant_id = m.id AND c.status = 'confirmed'::charge_status AND NOT c.is_test AND c.business_date > (helios_business_date(now()) - 30)) AS sales_30d,
    ( SELECT COALESCE(sum(COALESCE(c.base_usd, c.amount_usd)), 0::numeric) AS "coalesce"
           FROM charges c
          WHERE c.merchant_id = m.id AND c.status = 'confirmed'::charge_status AND NOT c.is_test AND c.business_date > (helios_business_date(now()) - 30)) AS financed_30d,
    owner_name,
    consultorio,
    -- NUEVO (20261126130000).
    phone
   FROM merchants m;
