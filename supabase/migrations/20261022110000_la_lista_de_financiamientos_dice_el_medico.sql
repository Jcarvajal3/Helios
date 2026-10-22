-- ============================================================================
-- Helios — La lista de financiamientos dice el médico titular
--
-- Javier (2026-10-22): en superadmin › Financiamientos, la columna de la
-- clínica pasa a ser la del médico titular, que es como lo conoce el equipo
-- (igual que en Pagos a clínicas, 20261022100000).
--
-- `admin_charges` añade `doctor_name` al final (`helios_doctor_name`: el
-- titular con su título; sin titular, el nombre de la clínica) y el buscador
-- encuentra también por el nombre del titular. Cambia la forma de la tabla
-- que devuelve: hay que borrarla y crearla, con sus permisos.
-- ============================================================================

drop function if exists public.admin_charges(text, uuid, text, date, date, integer);

CREATE FUNCTION public.admin_charges(p_search text DEFAULT NULL::text, p_merchant_id uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_limit integer DEFAULT 100)
 RETURNS TABLE(charge_id uuid, order_number bigint, amount_usd numeric, status text, business_date date, created_at timestamp with time zone, confirmed_at timestamp with time zone, void_reason text, user_id uuid, full_name text, phone_e164 text, user_status text, merchant_id uuid, merchant_name text, branch_name text, is_group boolean, is_test boolean, installments_paid integer, installments_total integer, financed_usd numeric, concept text, beneficiary_name text, registered_by_name text, staff_commission_usd numeric, document_number text, doctor_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_needle text;
  v_order  bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');

  if v_needle ~ '^#?\d{1,18}$' then
    v_order := replace(v_needle, '#', '')::bigint;
  else
    v_order := null;
  end if;

  return query
  select
    ch.id,
    ch.order_number,
    ch.amount_usd,
    ch.status::text,
    ch.business_date,
    ch.created_at,
    ch.confirmed_at,
    ch.void_reason,
    ch.user_id,
    p.full_name,
    p.phone_e164,
    p.status::text,
    m.id,
    m.name,
    b.name,
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer,
    coalesce(ch.base_usd, ch.amount_usd)::numeric,
    ch.concept,
    ch.beneficiary_name,
    public.helios_staff_name(ch.requested_by),
    ch.staff_commission_usd,
    p.document_number,
    -- NUEVO: el médico titular con su título; sin titular, la clínica.
    public.helios_doctor_name(m.id)
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    select ins.charge_id as cid,
           count(*) filter (where ins.status = 'paid')::integer as paid,
           count(*)::integer as total
    from public.installments ins group by 1
  ) i on i.cid = ch.id
  where
    (p_merchant_id is null or ch.merchant_id = p_merchant_id)
    and (p_status is null or ch.status::text = p_status)
    and (p_from is null or ch.business_date >= p_from)
    and (p_to is null or ch.business_date <= p_to)
    and (
      v_needle is null
      or (v_order is not null and ch.order_number = v_order)
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or p.email ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
      or m.owner_name ilike '%' || v_needle || '%'
      or ch.concept ilike '%' || v_needle || '%'
      or ch.beneficiary_name ilike '%' || v_needle || '%'
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$function$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated, service_role;
