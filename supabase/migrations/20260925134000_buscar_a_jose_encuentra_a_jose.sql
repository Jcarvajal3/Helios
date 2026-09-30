-- Buscar a «jose» encuentra a «JOSÉ».
--
-- El padrón comparaba el nombre con ILIKE, que distingue las tildes: quien
-- escribe «jose», «nunez» o «maria» no encontraba a nadie, porque Didit guarda
-- los nombres como vienen en la cédula. Y con texto seguía ordenando por
-- atraso, así que la persona buscada podía quedar debajo de otras que solo se
-- le parecían.
--
-- unaccent no está instalada en dev (ni pg_trgm). En vez de traer una
-- extensión se usa una función propia, inmutable, que quita las tildes del
-- español (y la diéresis, la ñ y la ç) y pasa a minúsculas. Con texto, la
-- lista se ordena por parecido; sin texto, el orden de siempre.

create or replace function public.helios_sin_tildes(p_texto text)
returns text
language sql
immutable
parallel safe
set search_path = pg_catalog
as $$
  select lower(translate(
    p_texto,
    'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
    'AAAAAEEEEIIIIOOOOOUUUUNCaaaaaeeeeiiiiooooouuuunc'
  ));
$$;

comment on function public.helios_sin_tildes(text) is
  'Minúsculas y sin tildes (también ü, ñ y ç), para comparar nombres. Inmutable: sirve en un índice si algún día hace falta.';

revoke all on function public.helios_sin_tildes(text) from public, anon, authenticated;
grant execute on function public.helios_sin_tildes(text) to service_role;

-- Se borra antes de crearla: si al volver a aplicar esta migración la función ya
-- tiene las columnas que le añade 20260925139500, create or replace no puede
-- cambiarle el tipo de salida.
drop function if exists public.admin_user_directory(text, text, integer);
CREATE OR REPLACE FUNCTION public.admin_user_directory(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(user_id uuid, full_name text, phone_e164 text, document_number text, status text, level smallint, level_limit_usd numeric, is_blacklisted boolean, is_test boolean, created_at timestamp with time zone, open_debt_usd numeric, overdue_usd numeric, days_overdue integer, charge_count integer, last_charge_at timestamp with time zone, available_usd numeric, last_merchant_name text, on_time_paid integer, on_time_total integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_grace  integer := public.helios_on_time_grace_days();
  v_needle text;
  v_aguja  text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');
  -- El nombre se compara sin tildes ni mayúsculas: «jose» encuentra a «JOSÉ».
  v_aguja  := public.helios_sin_tildes(v_needle);

  return query
  select
    p.id,
    p.full_name,
    p.phone_e164,
    p.document_number,
    p.status::text,
    p.level,
    l.monthly_limit_usd,
    p.is_blacklisted,
    p.is_test,
    p.created_at,
    coalesce(d.open_debt, 0)::numeric,
    coalesce(d.overdue, 0)::numeric,
    coalesce(d.days_late, 0)::integer,
    coalesce(c.cnt, 0)::integer,
    c.last_at,
    -- El disponible sale del bloque de crédito abierto, igual que en la
    -- ficha: el cupo vuelve entero al saldar la deuda completa, nunca cuota a
    -- cuota, y restar la deuda viva del límite daría otro número.
    greatest(l.monthly_limit_usd - coalesce(b.charged_usd - b.paid_usd, 0), 0)::numeric,
    c.last_merchant,
    coalesce(o.on_time, 0)::integer,
    coalesce(o.total, 0)::integer
  from public.profiles p
  join public.levels l on l.level = p.level
  left join (
    select
      i.user_id as uid,
      sum(i.amount_usd) as open_debt,
      sum(i.amount_usd) filter (where i.due_date < v_today) as overdue,
      max(v_today - i.due_date) filter (where i.due_date < v_today) as days_late
    from public.installments i
    where i.status = 'pending'
    group by 1
  ) d on d.uid = p.id
  left join (
    select
      ch.user_id as uid,
      count(*)::integer as cnt,
      max(ch.confirmed_at) as last_at,
      -- El local del último consumo. `distinct on` sería más limpio pero no
      -- se puede agregar con el resto en la misma pasada.
      (array_agg(m.name order by ch.confirmed_at desc))[1] as last_merchant
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    where ch.status = 'confirmed'
    group by 1
  ) c on c.uid = p.id
  -- El bloque de crédito abierto. Hay como mucho uno por persona.
  left join public.user_credit_blocks b
    on b.user_id = p.id and b.closed_at is null
  -- Cuántas de sus cuotas vencidas pagó dentro de plazo. Es el historial que
  -- decide si a alguien se le sube el nivel a mano o se le dice que no.
  left join (
    select
      i.user_id as uid,
      count(*) filter (
        where i.status = 'paid' and i.paid_at is not null
          and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
      )::integer as on_time,
      count(*)::integer as total
    from public.installments i
    where i.due_date <= v_today and i.written_off_at is null
    group by 1
  ) o on o.uid = p.id
  where
    (p_status is null or p.status::text = p_status)
    and (
      v_needle is null
      or p.phone_e164 ilike '%' || v_needle || '%'
      or public.helios_sin_tildes(p.full_name) like '%' || v_aguja || '%'
      or p.document_number ilike '%' || v_needle || '%'
    )
  -- Con texto, primero lo que más se parece: la coincidencia exacta, luego el
  -- nombre que empieza así, luego una palabra del nombre que empieza así, y al
  -- final el resto. Dentro de cada grupo (y sin texto, siempre) primero quien
  -- más atrasado está: esta lista se abre para cobrar, no para navegar el
  -- padrón.
  order by
    case
      when v_needle is null then 0
      when public.helios_sin_tildes(p.full_name) = v_aguja
        or p.phone_e164 = v_needle or p.document_number = v_needle then 0
      when public.helios_sin_tildes(p.full_name) like v_aguja || '%'
        or p.document_number ilike v_needle || '%' then 1
      when ' ' || public.helios_sin_tildes(p.full_name) like '% ' || v_aguja || '%' then 2
      else 3
    end,
    coalesce(d.days_late, 0) desc, coalesce(d.open_debt, 0) desc, p.created_at desc
  limit least(coalesce(p_limit, 50), 200);
end;
$function$;

comment on function public.admin_user_directory(text, text, integer) is
  'El padron. NO filtra las cuentas de prueba: tienen que poder buscarse y abrirse, y por eso devuelve is_test para que la pantalla las etiquete.';
revoke all on function public.admin_user_directory(text, text, integer) from public, anon;
grant execute on function public.admin_user_directory(text, text, integer) to authenticated, service_role;
