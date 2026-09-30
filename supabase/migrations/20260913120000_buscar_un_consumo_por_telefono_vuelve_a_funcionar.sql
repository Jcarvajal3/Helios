-- ============================================================================
-- Buscar un consumo por teléfono vuelve a funcionar
-- ============================================================================
--
-- Corrige dos fallos de `admin_charges` que entraron con 20260913100000, la
-- migración que le dio el número de orden. Va aparte y no editando aquella
-- porque una migración ya aplicada no se vuelve a ejecutar: cambiar su fichero
-- solo hace que la base y el repo digan cosas distintas.
--
-- ---------------------------------------------------------------------------
-- 1. La búsqueda por teléfono había dejado de funcionar
-- ---------------------------------------------------------------------------
-- Un número de orden se teclea en dígitos, y un teléfono venezolano también:
-- «04121234567» son once dígitos. La versión anterior, al ver dígitos, daba
-- por hecho que era una orden, buscaba `order_number = 4121234567`, no
-- encontraba nada — y se saltaba entera la búsqueda por teléfono, nombre,
-- cédula y local. O sea: la pantalla de Consumos dejó de encontrar a nadie por
-- teléfono, que es como más se busca, mientras su propio campo seguía diciendo
-- «Buscar por número de orden, teléfono, nombre…».
--
-- El número de orden SUMA, no sustituye. Si el texto no casa con nada, ese
-- lado del OR simplemente no aporta filas; no había ninguna razón para que
-- fueran excluyentes.
--
-- ---------------------------------------------------------------------------
-- 2. Una referencia larga tiraba la consulta
-- ---------------------------------------------------------------------------
-- El patrón era `^#?\d+$`, sin tope. Pegar en el buscador una referencia
-- bancaria de veinte dígitos entraba por ahí y el cast a bigint no devolvía
-- null: reventaba con un error de desbordamiento, y la pantalla enseñaba un
-- fallo donde tenía que enseñar «no hay resultados». Un bigint llega a 19
-- cifras, así que 18 es siempre seguro.
--
-- No toca datos ni firmas: es la misma función con el WHERE arreglado.
-- ============================================================================

create or replace function public.admin_charges(
  p_search      text default null,
  p_merchant_id uuid default null,
  p_status      text default null,
  p_from        date default null,
  p_to          date default null,
  p_limit       integer default 100
)
returns table (
  charge_id      uuid,
  order_number   bigint,
  amount_usd     numeric,
  status         text,
  business_date  date,
  created_at     timestamptz,
  confirmed_at   timestamptz,
  void_reason    text,
  user_id        uuid,
  full_name      text,
  phone_e164     text,
  user_status    text,
  merchant_id    uuid,
  merchant_name  text,
  branch_name    text,
  is_group       boolean,
  is_test        boolean,
  installments_paid integer,
  installments_total integer
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
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
    coalesce(i.total, 0)::integer
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
    )
  order by ch.created_at desc
  limit least(coalesce(p_limit, 100), 500);
end;
$$;

revoke all on function public.admin_charges(text, uuid, text, date, date, integer) from public, anon;
grant execute on function public.admin_charges(text, uuid, text, date, date, integer) to authenticated;

comment on function public.admin_charges(text, uuid, text, date, date, integer) is
  'La lista de consumos del super admin. Busca por número de orden (con o sin #), teléfono, nombre, cédula y local.';
