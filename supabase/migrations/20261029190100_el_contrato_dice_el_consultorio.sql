-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Los datos de alta para el contrato dicen el consultorio
--
-- Desde 20261029190000 el nombre de la clínica es el de su médico titular y
-- el nombre que traía queda en `merchants.consultorio`. El CSV del contrato
-- ya trae al titular aparte: lo que le faltaba es el consultorio.
-- La misma función de antes, con una clave más (`consultorio`).
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_merchant_contract_data(p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
      -- NUEVO (20261029190100).
      'consultorio',      m.consultorio,
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
$function$
;
