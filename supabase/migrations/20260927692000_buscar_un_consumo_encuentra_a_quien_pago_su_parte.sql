-- ============================================================================
-- Ronda — Buscar un consumo encuentra también a quien pagó su parte
--
-- AUD-OPERACION (27-09). El buscador de Directorio › Consumos comparaba el
-- teléfono, el nombre y la cédula solo con quien abrió la cuenta
-- (`charges.user_id`). En un consumo de grupo, un usuario que solo pagó su
-- parte no encontraba ese consumo: en dev, el teléfono de Mónica Pérez, con 2
-- cuotas en la orden #4172 (Bar Nocturno, 26-09, grupo de 5), devolvía 0
-- filas. Los usuarios se cuentan por sus cuotas, y se buscan igual.
--
-- Solo cambia el `where`: un consumo también casa si alguno de los usuarios
-- con cuota en él casa. Mismo tipo de salida, así que basta con `create or
-- replace`. Copiada de 20260925133000 (la última que la define).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.admin_charges(p_search text DEFAULT NULL::text, p_merchant_id uuid DEFAULT NULL::uuid, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_limit integer DEFAULT 100)
 RETURNS TABLE(charge_id uuid, order_number bigint, amount_usd numeric, status text, business_date date, created_at timestamp with time zone, confirmed_at timestamp with time zone, void_reason text, user_id uuid, full_name text, phone_e164 text, user_status text, merchant_id uuid, merchant_name text, branch_name text, is_group boolean, is_test boolean, installments_paid integer, installments_total integer, financed_usd numeric)
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

  -- Se compara por igualdad y no por LIKE: el número es único global, así que
  -- quien escribe 1043 quiere ESA orden y no las cuarenta que empiezan por
  -- 1043.
  --
  -- El tope de 18 dígitos no es decorativo: un bigint llega hasta 19 cifras y
  -- el cast de una cadena más larga no devuelve null, revienta. Quien pegue
  -- una referencia bancaria de veinte dígitos en el buscador tiene que ver
  -- «no hay resultados», no una pantalla de error.
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
    -- Un consumo de grupo genera N cargos hermanos con el mismo grupo detrás.
    -- Marcarlo evita que alguien lea ocho filas de $12,50 como ocho consumos
    -- sueltos de una noche rara.
    ch.group_id is not null,
    ch.is_test,
    coalesce(i.paid, 0)::integer,
    coalesce(i.total, 0)::integer,
    -- El consumo, sin el servicio de Ronda. amount_usd lo lleva dentro.
    coalesce(ch.base_usd, ch.amount_usd)::numeric
  from public.charges ch
  left join public.profiles p on p.id = ch.user_id
  join public.merchants m on m.id = ch.merchant_id
  join public.merchant_branches b on b.id = ch.branch_id
  left join (
    -- `ins.` explícito: el OUT parameter de esta función también se llama
    -- `charge_id` y sin calificar la columna Postgres no sabe a cuál se
    -- refiere.
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
      -- El número de orden SUMA, no sustituye. Un teléfono venezolano son once
      -- dígitos, así que también casa el patrón de arriba: si lo del número
      -- excluyera al resto, buscar por teléfono en esta pantalla dejaría de
      -- funcionar. Y al revés no hay coste — si el texto no casa con nada, ese
      -- lado del OR simplemente no aporta filas.
      or (v_order is not null and ch.order_number = v_order)
      or p.phone_e164 ilike '%' || v_needle || '%'
      or p.full_name ilike '%' || v_needle || '%'
      or p.document_number ilike '%' || v_needle || '%'
      or m.name ilike '%' || v_needle || '%'
      -- En un consumo de grupo, también quien tiene cuota en él aunque no
      -- abriera la cuenta.
      or exists (
        select 1
        from public.installments i2
        join public.profiles p2 on p2.id = i2.user_id
        where i2.charge_id = ch.id
          and i2.user_id is distinct from ch.user_id
          and (
            p2.phone_e164 ilike '%' || v_needle || '%'
            or p2.full_name ilike '%' || v_needle || '%'
            or p2.document_number ilike '%' || v_needle || '%'
          )
      )
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$function$;

comment on function public.admin_charges(text, uuid, text, date, date, integer) is
  'La lista de consumos del super admin. Busca por número de orden (con o sin #), local, y teléfono, nombre o cédula de quien abrió la cuenta o de cualquier usuario con cuota en el consumo (en un grupo, cada uno). financed_usd es el consumo sin el service fee; amount_usd lo lleva dentro.';
revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated, service_role;
