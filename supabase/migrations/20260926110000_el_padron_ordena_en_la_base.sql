-- ============================================================================
-- Ronda — El padrón ordena en la base
--
-- Con el padrón paginado (20260925202000), ordenar una columna en el
-- navegador solo reordenaba las 50 filas de la página: «por registro, lo más
-- nuevo arriba» enseñaba lo más nuevo DE ESAS 50, y quien se registró ayer
-- podía estar en la página 6. Ahora la columna y el sentido van aquí
-- (`p_orden`, `p_dir`), el orden se aplica al padrón entero y la página se
-- corta después.
--
-- Las columnas que se pueden pedir son una lista cerrada; cualquier otra cosa
-- se rechaza. Lo que no tiene valor (sin atraso, sin cuotas vencidas, sin
-- consumos) va al final en los dos sentidos, como en el resto de tablas del
-- panel. El orden de siempre (parecido con la búsqueda, atraso, deuda) queda
-- de desempate, y el id cierra el orden para que dos páginas no se pisen.
--
-- «Disponible hoy» no se ordena: es `helios_available_now_usd`, una función
-- cara que solo se calcula para las filas de la página.
-- ============================================================================

drop function if exists public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer);
drop function if exists public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer, text, text);

create or replace function public.admin_user_directory(
  p_search      text     default null,
  p_status      text     default null,
  p_limit       integer  default 50,
  p_level       smallint default null,
  p_is_test     boolean  default null,
  p_blacklisted boolean  default null,
  p_offset      integer  default 0,
  p_orden       text     default null,
  p_dir         text     default null
)
returns table(
  user_id uuid, full_name text, phone_e164 text, document_number text, status text,
  level smallint, level_limit_usd numeric, is_blacklisted boolean, is_test boolean,
  created_at timestamp with time zone, open_debt_usd numeric, overdue_usd numeric,
  days_overdue integer, charge_count integer, last_charge_at timestamp with time zone,
  available_usd numeric, last_merchant_name text, on_time_paid integer, on_time_total integer,
  available_now_usd numeric, available_blocked_reason text, total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := public.helios_business_date(now());
  v_grace  integer := public.helios_on_time_grace_days();
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_orden  text := nullif(trim(coalesce(p_orden, '')), '');
  v_asc    boolean := lower(coalesce(p_dir, 'asc')) = 'asc';
  v_needle text;
  v_aguja  text;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_orden is not null and v_orden not in (
    'persona', 'estado', 'nivel', 'deuda', 'vencido', 'dias-atraso',
    'a-tiempo', 'registro', 'ultimo', 'ultimo-local'
  ) then
    raise exception 'No se puede ordenar por «%»', p_orden using errcode = '22023';
  end if;
  if lower(coalesce(p_dir, 'asc')) not in ('asc', 'desc') then
    raise exception 'El sentido del orden es asc o desc' using errcode = '22023';
  end if;

  v_needle := nullif(trim(coalesce(p_search, '')), '');
  -- El nombre se compara sin tildes ni mayúsculas: «jose» encuentra a «JOSÉ».
  v_aguja  := public.helios_sin_tildes(v_needle);

  return query
  with base as (
    select
      p.id,
      p.full_name,
      p.phone_e164,
      p.document_number,
      p.status::text                                   as status,
      p.level,
      l.monthly_limit_usd,
      p.is_blacklisted,
      p.is_test,
      p.created_at,
      coalesce(d.open_debt, 0)::numeric                as open_debt,
      coalesce(d.overdue, 0)::numeric                  as overdue,
      coalesce(d.days_late, 0)::integer                as days_late,
      coalesce(c.cnt, 0)::integer                      as cnt,
      c.last_at,
      -- El cupo nominal, del bloque de crédito abierto, igual que en la ficha.
      greatest(l.monthly_limit_usd - coalesce(b.charged_usd - b.paid_usd, 0), 0)::numeric as disponible,
      c.last_merchant,
      coalesce(o.on_time, 0)::integer                  as on_time,
      coalesce(o.total, 0)::integer                    as on_time_total,
      -- Con texto, primero lo que más se parece: la coincidencia exacta, luego
      -- el nombre que empieza así, luego una palabra del nombre que empieza
      -- así, y al final el resto. Sin texto, todos en el mismo grupo.
      case
        when v_needle is null then 0
        when public.helios_sin_tildes(p.full_name) = v_aguja
          or p.phone_e164 = v_needle or p.document_number = v_needle then 0
        when public.helios_sin_tildes(p.full_name) like v_aguja || '%'
          or p.document_number ilike v_needle || '%' then 1
        when ' ' || public.helios_sin_tildes(p.full_name) like '% ' || v_aguja || '%' then 2
        else 3
      end                                              as parecido,
      count(*) over ()                                 as total
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
        (array_agg(m.name order by ch.confirmed_at desc))[1] as last_merchant
      from public.charges ch
      join public.merchants m on m.id = ch.merchant_id
      where ch.status = 'confirmed'
      group by 1
    ) c on c.uid = p.id
    -- El bloque de crédito abierto. Hay como mucho uno por persona.
    left join public.user_credit_blocks b
      on b.user_id = p.id and b.closed_at is null
    -- Cuántas de sus cuotas vencidas pagó dentro de plazo.
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
      and (p_level is null or p.level = p_level)
      and (p_is_test is null or p.is_test = p_is_test)
      and (p_blacklisted is null or p.is_blacklisted = p_blacklisted)
      and (
        v_needle is null
        or p.phone_e164 ilike '%' || v_needle || '%'
        or public.helios_sin_tildes(p.full_name) like '%' || v_aguja || '%'
        or p.document_number ilike '%' || v_needle || '%'
      )
  ),
  -- La clave de la columna pedida, en una sola columna por tipo. Lo que no
  -- tiene valor sale null y va al final (`nulls last` en los dos sentidos).
  claves as (
    select
      b.*,
      case v_orden
        when 'persona'      then lower(public.helios_sin_tildes(b.full_name))
        when 'estado'       then b.status
        when 'ultimo-local' then lower(b.last_merchant)
      end                                              as clave_texto,
      case v_orden
        when 'nivel'       then b.level::numeric
        when 'deuda'       then b.open_debt
        when 'vencido'     then b.overdue
        when 'dias-atraso' then case when b.overdue > 0 then b.days_late::numeric end
        when 'a-tiempo'    then case when b.on_time_total > 0 then b.on_time::numeric / b.on_time_total end
      end                                              as clave_numero,
      case v_orden
        when 'registro' then b.created_at
        when 'ultimo'   then b.last_at
      end                                              as clave_fecha
    from base b
  ),
  pagina as (
    select k.*
    from claves k
    order by
      case when v_asc then k.clave_texto  end asc  nulls last,
      case when not v_asc then k.clave_texto  end desc nulls last,
      case when v_asc then k.clave_numero end asc  nulls last,
      case when not v_asc then k.clave_numero end desc nulls last,
      case when v_asc then k.clave_fecha  end asc  nulls last,
      case when not v_asc then k.clave_fecha  end desc nulls last,
      -- El orden de siempre: esta lista se abre para cobrar, no para navegar
      -- el padrón. Sin columna pedida es el único; con ella, el desempate.
      k.parecido, k.days_late desc, k.open_debt desc, k.created_at desc, k.id
    limit v_limit
    offset v_offset
  )
  select
    g.id, g.full_name, g.phone_e164, g.document_number, g.status, g.level,
    g.monthly_limit_usd, g.is_blacklisted, g.is_test, g.created_at,
    g.open_debt, g.overdue, g.days_late, g.cnt, g.last_at, g.disponible,
    g.last_merchant, g.on_time, g.on_time_total,
    public.helios_available_now_usd(g.id),
    public.helios_available_blocked_reason(g.id),
    g.total
  from pagina g
  order by
    case when v_asc then g.clave_texto  end asc  nulls last,
    case when not v_asc then g.clave_texto  end desc nulls last,
    case when v_asc then g.clave_numero end asc  nulls last,
    case when not v_asc then g.clave_numero end desc nulls last,
    case when v_asc then g.clave_fecha  end asc  nulls last,
    case when not v_asc then g.clave_fecha  end desc nulls last,
    g.parecido, g.days_late desc, g.open_debt desc, g.created_at desc, g.id;
end;
$$;

comment on function public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer, text, text) is
  'El padron, paginado y ordenado en el servidor: filtros de texto, estado, nivel, prueba y marca; p_orden (lista cerrada) y p_dir; total_count en cada fila. NO excluye las cuentas de prueba por defecto: tienen que poder buscarse, y por eso devuelve is_test.';
revoke all on function public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer, text, text) from public, anon;
grant execute on function public.admin_user_directory(text, text, integer, smallint, boolean, boolean, integer, text, text) to authenticated;
