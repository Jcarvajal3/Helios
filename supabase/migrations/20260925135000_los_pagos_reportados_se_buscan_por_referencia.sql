-- Los pagos reportados se buscan por su referencia.
--
-- La paleta del super admin (Ctrl K) buscaba pagos leyendo payment_reports
-- directamente y, en una segunda consulta, el nombre de cada persona: la tabla
-- apunta a auth.users y no a profiles. Esta función hace las dos cosas en una y
-- en cualquier estado del pago, que es lo que la cola (admin_payment_queue) no
-- sirve para buscar: trae el árbol entero de cada pago y se pide por estados.
--
-- La referencia se compara solo por sus letras y cifras (sin espacios, guiones
-- ni puntos) y sin distinguir mayúsculas. Primero la que coincide entera,
-- luego la que termina así (una referencia se dicta por sus últimas cifras), y
-- luego el resto; dentro de cada grupo, la más reciente primero.
--
-- No quita las cuentas de prueba: es un buscador, como el padrón, y devuelve
-- is_test para que la pantalla las etiquete.

create or replace function public.admin_search_payment_reports(
  p_reference text,
  p_limit     integer default 8
)
returns table (
  report_id         uuid,
  reference         text,
  bank              text,
  method            text,
  status            text,
  created_at        timestamptz,
  reviewed_at       timestamptz,
  user_id           uuid,
  full_name         text,
  phone_e164        text,
  is_test           boolean,
  amount_usd        numeric,
  amount_ves        numeric,
  installment_count smallint,
  late_fee_usd      numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_aguja text    := lower(regexp_replace(coalesce(p_reference, ''), '[^0-9A-Za-z]', '', 'g'));
  v_limit integer := greatest(least(coalesce(p_limit, 8), 50), 1);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Con una o dos cifras casa casi todo: no es una búsqueda, es la lista.
  if length(v_aguja) < 3 then
    return;
  end if;

  return query
  with pagos as (
    select r.*, lower(regexp_replace(r.reference, '[^0-9A-Za-z]', '', 'g')) as ref_limpia
    from public.payment_reports r
    where r.reference is not null
  )
  select
    r.id,
    r.reference,
    r.bank,
    r.method,
    r.status::text,
    r.created_at,
    r.reviewed_at,
    r.user_id,
    p.full_name,
    p.phone_e164,
    p.is_test,
    -- PAYABLE: lo que la persona tenía que transferir. Es la cotización: sus
    -- cuotas, con el servicio de Ronda dentro, más los cargos por atraso, que
    -- también viajan aparte en late_fee_usd.
    q.amount_usd,
    q.amount_ves,
    q.installment_count,
    q.late_fee_usd
  from pagos r
  join public.payment_quotes q on q.id = r.quote_id
  join public.profiles p on p.id = r.user_id
  where r.ref_limpia like '%' || v_aguja || '%'
  order by
    case
      when r.ref_limpia = v_aguja then 0
      when r.ref_limpia like '%' || v_aguja then 1
      else 2
    end,
    r.created_at desc
  limit v_limit;
end;
$$;

comment on function public.admin_search_payment_reports(text, integer) is
  'Pagos reportados cuya referencia contiene el texto (solo letras y cifras, al menos tres), en cualquier estado, con la persona y el monto de la cotizacion (payable). Primero la coincidencia exacta, luego la que termina asi.';

revoke all on function public.admin_search_payment_reports(text, integer) from public, anon;
grant execute on function public.admin_search_payment_reports(text, integer) to authenticated, service_role;
