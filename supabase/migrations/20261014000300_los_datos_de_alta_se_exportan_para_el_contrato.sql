-- ============================================================================
-- Helios — Los datos de alta de las clínicas se exportan para el contrato
--
-- El equipo redacta el contrato de cada clínica con sus datos de alta y los
-- del médico titular. Hasta ahora había que copiarlos a mano de tres sitios
-- de la ficha (Perfil, titular y Cuenta de pago). Ahora (Javier, 2026-10-14):
--
-- 1. `merchant_directory` añade al final `owner_name`: la lista de clínicas
--    del superadmin enseña el médico titular en una columna. Es la misma
--    fila de `merchants` que ya lee quien lee la vista (`security_invoker`).
--
-- 2. `admin_merchant_contract_data(p_merchant_id uuid default null)`: de
--    solo lectura, para el CSV. Sin argumento, todas las clínicas; con él,
--    solo esa. Cada fila junta la clínica, su titular, su cuenta de pago y la
--    solicitud de la portada de la que nació (si nació de una). Solo personal
--    de Helios (`is_platform_admin()`, con MFA), como la cuenta de pago que
--    ya enseña la ficha.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La vista de la lista, con el titular
-- ---------------------------------------------------------------------------

-- `create or replace` solo deja AÑADIR columnas al final: las de antes van
-- igual y en el mismo orden. `security_invoker` como estaba.
create or replace view public.merchant_directory
with (security_invoker = true)
as
select
  m.id,
  m.name,
  m.legal_name,
  m.tax_id,
  m.status,
  m.created_at,
  (select count(*) from public.merchant_users mu
     where mu.merchant_id = m.id and mu.is_active) as staff_count,
  -- Desde el alta, con el mismo filtro que los 30 días: sin los de prueba.
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test) as sales_count,
  m.category,
  m.city,
  m.handle,
  m.logo_url,
  m.social_url,
  m.is_test,
  -- Los últimos 30 días operativos. Un local que vendió mucho en agosto y nada
  -- desde entonces no puede leerse igual que uno que está funcionando.
  (select count(*) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test
       and c.business_date > public.helios_business_date(now()) - 30) as sales_30d,
  -- Consumo, sin la Comisión Helios.
  (select coalesce(sum(coalesce(c.base_usd, c.amount_usd)), 0) from public.charges c
     where c.merchant_id = m.id and c.status = 'confirmed' and not c.is_test
       and c.business_date > public.helios_business_date(now()) - 30) as financed_30d,
  -- El médico titular (20261014000300).
  m.owner_name
from public.merchants m;

grant select on public.merchant_directory to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Los datos de alta, para el contrato
-- ---------------------------------------------------------------------------

create or replace function public.admin_merchant_contract_data(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_filas jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_merchant_id is not null
     and not exists (select 1 from public.merchants where id = p_merchant_id) then
    raise exception 'Esa clínica no existe' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(fila order by fila->>'name', fila->>'merchant_id'), '[]'::jsonb)
  into v_filas
  from (
    select jsonb_build_object(
      'merchant_id',      m.id,
      -- La clínica
      'name',             m.name,
      'legal_name',       m.legal_name,
      'tax_id',           m.tax_id,
      'category',         m.category,
      'specialty',        m.specialty,
      'mpps_number',      m.mpps_number,
      'phone',            m.phone,
      'email',            m.email,
      'address',          m.address,
      'city',             m.city,
      'status',           m.status,
      'is_test',          m.is_test,
      'created_at',       m.created_at,
      -- El médico titular
      'owner_name',       m.owner_name,
      'owner_document',   m.owner_document,
      'college_number',   m.college_number,
      -- Su cuenta de pago (null si no tiene)
      'bank',             pa.bank,
      'account_holder',   pa.account_holder,
      'holder_document',  pa.holder_document,
      'account_number',   pa.account_number,
      'pago_movil_bank',  pa.pago_movil_bank,
      'pago_movil_phone', pa.pago_movil_phone,
      -- La solicitud de la portada de la que nació (null si se dio de alta
      -- desde el panel). Si hubiera más de una, la última aprobada.
      'applied_at',       ap.created_at,
      'approved_at',      ap.reviewed_at
    ) as fila
    from public.merchants m
    left join public.merchant_payout_accounts pa on pa.merchant_id = m.id
    left join lateral (
      select a.created_at, a.reviewed_at
      from public.merchant_applications a
      where a.merchant_id = m.id and a.status = 'approved'
      order by a.reviewed_at desc nulls last
      limit 1
    ) ap on true
    where p_merchant_id is null or m.id = p_merchant_id
  ) t;

  return v_filas;
end;
$$;

comment on function public.admin_merchant_contract_data(uuid) is
  'Datos de alta de las clínicas (o de una) con su titular y su cuenta de pago, para redactar el contrato. Solo personal de Helios.';

revoke all on function public.admin_merchant_contract_data(uuid) from public, anon;
grant execute on function public.admin_merchant_contract_data(uuid) to authenticated;
