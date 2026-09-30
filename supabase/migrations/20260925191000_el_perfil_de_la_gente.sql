-- ============================================================================
-- Ronda — El perfil de la gente
--
-- Crecimiento cuenta cuánta gente entra, cuánta consume y cuánto gasta, pero
-- no dice CÓMO ES: qué edad tiene, de dónde es, con qué teléfono entra, cuándo
-- sale y dónde. Esta lectura junta en un solo viaje los rasgos que Ronda ya
-- guarda de cada persona y los devuelve agregados para la pestaña «Perfil» del
-- super admin (un «user persona» con datos de verdad).
--
-- ── De dónde sale cada rasgo ────────────────────────────────────────────────
-- Edad: `profiles.birth_date`; si falta, la del expediente más reciente que la
--   tenga (la confirmada por la persona o, si no, la leída del documento).
-- Sexo: `extracted_gender` del expediente más reciente que lo tenga.
-- Ciudad y aparato: `didit_device` del expediente más reciente que lo tenga.
--   La ciudad es la de la CONEXIÓN al verificarse, no donde vive; con VPN o
--   desde un centro de datos no dice nada y no se cuenta. Si Didit no sabe el
--   sistema, manda el de la app (`user_devices`), que también da la versión.
-- Bits: el saldo de cada persona es la suma de sus movimientos (`bits_entries`).
--   Cada cuota pagada deja entre 100 (el mismo día de la compra) y 30 (el del
--   vencimiento); pagada en mora no deja nada, y tampoco movimiento.
-- Consumo: de las cuotas, una fila por (consumo, persona) con lo que puso
--   cada quien SIN el fee (`installments.financed_usd`). `charges.amount_usd`
--   lleva el fee dentro y aquí no se usa para nada.
--
-- ── Las tres bases ──────────────────────────────────────────────────────────
-- registrados: `helios_signups` (teléfono confirmado, sin cuentas de prueba).
-- verificados: de esos, quien tiene un expediente aprobado.
-- consumieron: de esos, quien tiene al menos un consumo confirmado.
--
-- ── Privacidad ──────────────────────────────────────────────────────────────
-- Solo agregados: ninguna fila por persona. Ciudades, marcas, versiones y
-- locales con menos de tres personas se juntan en «otras». Las cuentas de
-- prueba (personas, cuotas, cargos y locales) no cuentan en nada.
--
-- Lee toda la historia a propósito: el perfil es de la gente, no de un
-- periodo, y el piloto cabe entero en unas pocas páginas de cada tabla.
-- ============================================================================

create or replace function public.admin_user_persona(p_base text default 'consumieron')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  -- El umbral de privacidad: una categoría con menos gente va a «otras».
  c_min   constant integer := 3;
  v_today date := public.helios_business_date(now());
  v_hoy   date := public.helios_caracas_date(now());
  v_base  text := lower(coalesce(nullif(btrim(p_base), ''), 'consumieron'));
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if v_base not in ('consumieron', 'verificados', 'registrados') then
    raise exception 'Base desconocida: %', p_base using errcode = '22023';
  end if;

  with
  registrados as (
    select s.user_id, s.level
    from public.helios_signups s
  ),
  -- Un consumo por persona: la pareja (cargo, persona). En un consumo de grupo
  -- hay una por integrante con lo que le tocó; el cargo solo no dice quién.
  consumo as (
    select i.user_id,
           c.id                                                          as charge_id,
           c.business_date                                               as noche,
           extract(isodow from c.business_date)::int                     as dow,
           extract(hour from c.created_at at time zone 'America/Caracas')::int as hora,
           c.created_at,
           c.group_id,
           c.merchant_id,
           -- Si alguna cuota no sabe su consumo, la pareja se queda sin
           -- importe antes que colar el fee por la puerta de atrás.
           case when bool_and(i.financed_usd is not null) then sum(i.financed_usd) end as fin
    from public.installments i
    join public.charges   c on c.id = i.charge_id
    join public.merchants m on m.id = c.merchant_id
    join registrados      r on r.user_id = i.user_id
    where c.status = 'confirmed'
      and c.business_date is not null
      and not i.is_test
      and not c.is_test
      and not m.is_test
    group by i.user_id, c.id
  ),
  verificados as (
    select distinct v.user_id
    from kyc.verifications v
    join registrados r on r.user_id = v.user_id
    where v.status = 'approved'
  ),
  consumidores as (
    select distinct k.user_id from consumo k
  ),
  base as (
    select r.user_id, r.level
    from registrados r
    where v_base = 'registrados'
       or (v_base = 'verificados' and r.user_id in (select user_id from verificados))
       or (v_base = 'consumieron' and r.user_id in (select user_id from consumidores))
  ),
  consumo_base as (
    select k.*
    from consumo k
    where k.user_id in (select user_id from base)
  ),

  -- ── Lo del expediente: el más reciente que tenga cada dato ───────────────
  sexo as (
    select distinct on (v.user_id) v.user_id, v.extracted_gender as sexo
    from kyc.verifications v
    where v.user_id in (select user_id from base)
      and v.extracted_gender in ('M', 'F')
    order by v.user_id, v.created_at desc
  ),
  didit as (
    select distinct on (v.user_id) v.user_id, v.didit_device as d
    from kyc.verifications v
    where v.user_id in (select user_id from base)
      and jsonb_typeof(v.didit_device) = 'object'
    order by v.user_id, coalesce(v.didit_details_at, v.created_at) desc
  ),
  app as (
    select distinct on (u.user_id)
           u.user_id,
           lower(btrim(u.platform))          as plataforma,
           nullif(btrim(u.app_version), '')  as version
    from public.user_devices u
    where u.user_id in (select user_id from base)
    order by u.user_id, u.last_seen_at desc nulls last
  ),
  nacimiento as (
    select b.user_id,
           coalesce(p.birth_date, (
             select coalesce(v.confirmed_birth, v.extracted_birth)
             from kyc.verifications v
             where v.user_id = b.user_id
               and coalesce(v.confirmed_birth, v.extracted_birth) is not null
             order by v.created_at desc
             limit 1
           )) as nacio
    from base b
    join public.profiles p on p.id = b.user_id
  ),
  crudo as (
    select b.user_id,
           b.level,
           s.sexo,
           date_part('year', age(v_hoy::timestamp, n.nacio::timestamp))::int as anios,
           nullif(btrim(d.d ->> 'os_family'), '')                         as sistema,
           case
             when btrim(d.d ->> 'device_brand') ~* '^(generic|unknown|other)' then null
             else nullif(btrim(d.d ->> 'device_brand'), '')
           end                                                             as marca_didit,
           -- Con VPN o desde un centro de datos, la ciudad es la del servidor.
           case
             when lower(coalesce(d.d ->> 'is_vpn_or_tor', '')) in ('true', 't', '1')
               or lower(coalesce(d.d ->> 'is_data_center', '')) in ('true', 't', '1') then null
             else nullif(btrim(d.d ->> 'ip_city'), '')
           end                                                             as ciudad,
           upper(nullif(btrim(d.d ->> 'ip_country_code'), ''))             as pais,
           a.plataforma                                                    as plataforma_app,
           a.version
    from base b
    left join sexo       s on s.user_id = b.user_id
    left join nacimiento n on n.user_id = b.user_id
    left join didit      d on d.user_id = b.user_id
    left join app        a on a.user_id = b.user_id
  ),
  persona as (
    select c.user_id,
           c.level,
           c.sexo,
           -- Una fecha imposible (un menor, un siglo) es un dato mal leído.
           case when c.anios between 18 and 99 then c.anios end as edad,
           c.ciudad,
           c.pais,
           c.version,
           x.plataforma,
           case
             when c.sistema is not null then 'didit'
             when x.plataforma is not null then 'app'
           end as fuente,
           coalesce(c.marca_didit, case when x.plataforma = 'ios' then 'Apple' end) as marca
    from crudo c
    cross join lateral (
      select case
               when c.sistema ~* '^android' then 'android'
               when c.sistema ~* '^(ios|ipados|iphone)' then 'ios'
               -- Didit sabe el sistema y no es de teléfono: un ordenador.
               when c.sistema is not null then 'web'
               when c.plataforma_app in ('android', 'ios', 'web') then c.plataforma_app
             end as plataforma
    ) x
  ),

  -- ── Cómo consume cada persona ────────────────────────────────────────────
  porpersona as (
    select k.user_id,
           count(*)::int                as consumos,
           count(distinct k.noche)::int as noches,
           min(k.noche)                 as primera
    from consumo_base k
    group by k.user_id
  ),
  -- Los días entre una noche con consumo y la siguiente de la misma persona.
  -- Dos consumos de la misma noche no son dos salidas.
  saltos as (
    select n.user_id,
           n.noche - lag(n.noche) over (partition by n.user_id order by n.noche) as dias
    from (select distinct k.user_id, k.noche from consumo_base k) n
  ),
  -- El local favorito de cada quien: donde más veces consumió. Una persona,
  -- un local: así el reparto suma la gente y no las visitas.
  favorito as (
    select distinct on (x.user_id) x.user_id, x.merchant_id
    from (
      select k.user_id, k.merchant_id,
             count(*)              as n,
             coalesce(sum(k.fin), 0) as f,
             max(k.created_at)     as ultima
      from consumo_base k
      group by k.user_id, k.merchant_id
    ) x
    order by x.user_id, x.n desc, x.f desc, x.ultima desc
  ),
  ciudad_local as (
    select distinct on (x.user_id) x.user_id, x.clave, x.rotulo
    from (
      select k.user_id,
             lower(btrim(m.city)) as clave,
             min(btrim(m.city))   as rotulo,
             count(*)             as n,
             max(k.created_at)    as ultima
      from consumo_base k
      join public.merchants m on m.id = k.merchant_id
      where nullif(btrim(m.city), '') is not null
      group by k.user_id, lower(btrim(m.city))
    ) x
    order by x.user_id, x.n desc, x.ultima desc
  ),

  -- ── Los Bits de cada persona de la base, con los que no tienen en cero ──
  bits as (
    select b.user_id, coalesce(sum(e.amount), 0)::int as saldo
    from base b
    left join public.bits_entries e on e.user_id = b.user_id
    group by b.user_id
  ),
  -- Las cuotas pagadas de la base, con lo que dejó cada una. Se divide entre
  -- TODAS las pagadas y no solo las premiadas: una pagada en mora no deja
  -- movimiento, y sin contarla la puntualidad saldría inflada.
  pagadas as (
    select i.id, coalesce(sum(e.amount), 0)::int as bits
    from public.installments i
    join base b on b.user_id = i.user_id
    left join public.bits_entries e on e.installment_id = i.id and e.reason = 'installment_paid'
    where i.status = 'paid' and not i.is_test
    group by i.id
  ),

  -- ── Las categorías abiertas, con el umbral de privacidad ─────────────────
  -- Cada persona cae en UNA categoría por dimensión, así que la suma de una
  -- dimensión es la gente de la que se sabe ese dato.
  categorias as (
    select 'ciudad'::text as dim,
           lower(p.ciudad) as clave,
           mode() within group (order by p.ciudad)
             || coalesce(' (' || nullif(mode() within group (order by p.pais), 'VE') || ')', '') as rotulo,
           count(*)::int as personas
    from persona p
    where p.ciudad is not null
    group by lower(p.ciudad)
    union all
    select 'marca', lower(p.marca), mode() within group (order by p.marca), count(*)::int
    from persona p
    where p.marca is not null
    group by lower(p.marca)
    union all
    select 'version', p.version, p.version, count(*)::int
    from persona p
    where p.version is not null
    group by p.version
    union all
    select 'local', f.merchant_id::text, min(m.name), count(*)::int
    from favorito f
    join public.merchants m on m.id = f.merchant_id
    group by f.merchant_id
    union all
    select 'ciudad_local', c.clave, min(c.rotulo), count(*)::int
    from ciudad_local c
    group by c.clave
  ),
  puestos as (
    select c.*,
           row_number() over (partition by c.dim order by c.personas desc, c.rotulo) as puesto
    from categorias c
    where c.personas >= c_min
  ),
  -- Cuántas se enseñan de cada una, y sobre quién: la ciudad y el aparato son
  -- de toda la base; el local, solo de quien consumió.
  topes(dim, n, sobre) as (
    values ('ciudad', 6, 'base'), ('marca', 5, 'base'), ('version', 5, 'base'),
           ('local', 5, 'consumo'), ('ciudad_local', 6, 'consumo')
  ),
  bloques as (
    select t.dim,
           jsonb_build_object(
             'known',   k.sabidos,
             'unknown', case t.sobre when 'base' then (select count(*) from base)
                                     else (select count(*) from porpersona) end - k.sabidos,
             'rows', coalesce((
               select jsonb_agg(jsonb_build_object('key', q.clave, 'label', q.rotulo, 'users', q.personas)
                                order by q.puesto)
               from puestos q
               where q.dim = t.dim and q.puesto <= t.n
             ), '[]'::jsonb),
             'other', k.sabidos - coalesce((
               select sum(q.personas) from puestos q where q.dim = t.dim and q.puesto <= t.n
             ), 0)
           ) as j
    from topes t
    cross join lateral (
      select coalesce(sum(c.personas), 0)::int as sabidos
      from categorias c
      where c.dim = t.dim
    ) k
  )
  select jsonb_build_object(
    'business_date', v_today,
    'base',          v_base,
    'min_group',     c_min,
    -- Las tres bases, para el selector: se ven sin tener que cambiar de base.
    'bases', jsonb_build_object(
      'consumieron', (select count(*) from consumidores),
      'verificados', (select count(*) from verificados),
      'registrados', (select count(*) from registrados)
    ),
    'people',    (select count(*) from base),
    'consumers', (select count(*) from porpersona),

    'age', (
      select jsonb_build_object(
        'known',   count(p.edad),
        'unknown', count(*) - count(p.edad),
        'median',  round(percentile_cont(0.5) within group (order by p.edad))::int,
        'buckets', (
          select jsonb_agg(jsonb_build_object(
                   'key',  t.clave,
                   'from', t.desde,
                   'to',   t.hasta,
                   'users', (select count(*) from persona x
                             where x.edad >= t.desde and (t.hasta is null or x.edad <= t.hasta)),
                   'avg_ticket_usd', (select round(avg(k.fin), 2)
                                      from consumo_base k
                                      join persona x on x.user_id = k.user_id
                                      where x.edad >= t.desde and (t.hasta is null or x.edad <= t.hasta))
                 ) order by t.desde)
          from (values ('18-24', 18, 24), ('25-34', 25, 34), ('35-44', 35, 44),
                       ('45-54', 45, 54), ('55+', 55, null::int)) t(clave, desde, hasta)
        )
      )
      from persona p
    ),

    'gender', (
      select jsonb_build_object(
        'female',  count(*) filter (where p.sexo = 'F'),
        'male',    count(*) filter (where p.sexo = 'M'),
        'unknown', count(*) filter (where p.sexo is null),
        'consumers', jsonb_build_object(
          'female', count(*) filter (where p.sexo = 'F' and pp.user_id is not null),
          'male',   count(*) filter (where p.sexo = 'M' and pp.user_id is not null)
        ),
        'avg_ticket_usd', jsonb_build_object(
          'female',  (select round(avg(k.fin), 2) from consumo_base k
                      join persona x on x.user_id = k.user_id where x.sexo = 'F'),
          'male',    (select round(avg(k.fin), 2) from consumo_base k
                      join persona x on x.user_id = k.user_id where x.sexo = 'M'),
          'unknown', (select round(avg(k.fin), 2) from consumo_base k
                      join persona x on x.user_id = k.user_id where x.sexo is null)
        )
      )
      from persona p
      left join porpersona pp on pp.user_id = p.user_id
    ),

    'city', jsonb_build_object(
      'connection', (select b.j from bloques b where b.dim = 'ciudad'),
      'merchant',   (select b.j from bloques b where b.dim = 'ciudad_local')
    ),

    'device', (
      select jsonb_build_object(
        'platform', jsonb_build_object(
          'android', count(*) filter (where p.plataforma = 'android'),
          'ios',     count(*) filter (where p.plataforma = 'ios'),
          'web',     count(*) filter (where p.plataforma = 'web'),
          'unknown', count(*) filter (where p.plataforma is null)
        ),
        'source', jsonb_build_object(
          'didit', count(*) filter (where p.fuente = 'didit'),
          'app',   count(*) filter (where p.fuente = 'app')
        ),
        'brands',       (select b.j from bloques b where b.dim = 'marca'),
        'app_versions', (select b.j from bloques b where b.dim = 'version')
      )
      from persona p
    ),

    -- El ticket es lo que puso cada persona en cada consumo, sin el fee.
    'ticket', (
      select jsonb_build_object(
        'consumos',   count(k.fin),
        'avg_usd',    round(avg(k.fin), 2),
        'median_usd', round((percentile_cont(0.5) within group (order by k.fin))::numeric, 2),
        'buckets', (
          select jsonb_agg(jsonb_build_object(
                   'key',  t.clave,
                   'from', t.desde,
                   'to',   t.hasta,
                   'consumos', (select count(*) from consumo_base x
                                where x.fin is not null
                                  and (t.desde = 0 or x.fin > t.desde)
                                  and (t.hasta is null or x.fin <= t.hasta))
                 ) order by t.desde)
          from (values ('0-5', 0::numeric, 5::numeric), ('5-10', 5, 10), ('10-20', 10, 20),
                       ('20-40', 20, 40), ('40+', 40, null::numeric)) t(clave, desde, hasta)
        )
      )
      from consumo_base k
    ),

    'frequency', jsonb_build_object(
      -- El «ninguno» solo existe cuando la base incluye a quien no consumió.
      'buckets', (
        select jsonb_agg(jsonb_build_object(
                 'key',  t.clave,
                 'from', t.desde,
                 'to',   t.hasta,
                 'users', case
                            when t.desde = 0 then
                              (select count(*) from base b
                               where b.user_id not in (select user_id from porpersona))
                            else
                              (select count(*) from porpersona pp
                               where pp.consumos >= t.desde and (t.hasta is null or pp.consumos <= t.hasta))
                          end
               ) order by t.desde)
        from (values ('0', 0, 0), ('1', 1, 1), ('2-3', 2, 3), ('4-6', 4, 6), ('7+', 7, null::int))
             t(clave, desde, hasta)
        where t.desde > 0 or v_base <> 'consumieron'
      ),
      'median_consumos', (select percentile_disc(0.5) within group (order by pp.consumos) from porpersona pp),
      'avg_consumos',    (select round(avg(pp.consumos), 2) from porpersona pp),
      -- Consumos por mes desde el primero, con un mes como mínimo: con una
      -- semana de historia no se extrapola a un mes que no ha pasado.
      'per_month_median', (
        select round((percentile_cont(0.5) within group (
                 order by pp.consumos / greatest(1.0, (v_today - pp.primera + 1) / 30.0)))::numeric, 1)
        from porpersona pp
      ),
      'repeat_users', (select count(*) from porpersona pp where pp.noches >= 2),
      'median_days_between', (
        select case when count(distinct s.user_id) >= c_min
                    then round((percentile_cont(0.5) within group (order by s.dias))::numeric, 1) end
        from saltos s
        where s.dias is not null
      )
    ),

    'when', jsonb_build_object(
      'consumos', (select count(*) from consumo_base),
      -- Por día operativo: la 1 de la madrugada del sábado es del viernes.
      'weekdays', (
        select jsonb_agg(jsonb_build_object(
                 'dow', d.dow,
                 'consumos', (select count(*) from consumo_base k where k.dow = d.dow)
               ) order by d.dow)
        from generate_series(1, 7) d(dow)
      ),
      -- La hora de Caracas en que se abrió el cobro, en tramos de dos horas
      -- de 18:00 a 06:00; lo de día va junto en uno.
      'hours', (
        select jsonb_agg(jsonb_build_object(
                 'key',  t.clave,
                 'from', t.desde,
                 'to',   t.hasta,
                 'consumos', (select count(*) from consumo_base k
                              where k.hora >= t.desde and k.hora < t.hasta)
               ) order by t.orden)
        from (values (1, '18', 18, 20), (2, '20', 20, 22), (3, '22', 22, 24),
                     (4, '0', 0, 2), (5, '2', 2, 4), (6, '4', 4, 6), (7, 'dia', 6, 18))
             t(orden, clave, desde, hasta)
      )
    ),

    'social', jsonb_build_object(
      'group_consumos', (select count(*) from consumo_base k where k.group_id is not null),
      'solo_consumos',  (select count(*) from consumo_base k where k.group_id is null),
      'group_users',    (select count(distinct k.user_id) from consumo_base k where k.group_id is not null),
      'favorite_merchants', (select b.j from bloques b where b.dim = 'local'),
      'levels', (
        select jsonb_agg(jsonb_build_object(
                 'level', l.level,
                 'users', (select count(*) from base b where b.level = l.level)
               ) order by l.level)
        from (
          select lv.level from public.levels lv where lv.is_active
          union
          select b.level from base b where b.level is not null
        ) l
      )
    ),

    -- El saldo de Bits de la base (con los que tienen cero) y cuántos deja de
    -- media cada cuota pagada: la puntualidad dicha en la moneda que ve la
    -- persona (100 = el mismo día de la compra, 30 = el día del vencimiento).
    'bits', (
      select jsonb_build_object(
        'with_bits',      count(*) filter (where x.saldo > 0),
        'total',          coalesce(sum(x.saldo), 0),
        'avg_balance',    round(avg(x.saldo), 1),
        'median_balance', round((percentile_cont(0.5) within group (order by x.saldo))::numeric)::int,
        'paid_installments',    (select count(*) from pagadas),
        'per_paid_installment', (select round(avg(q.bits), 1) from pagadas q),
        'buckets', (
          select jsonb_agg(jsonb_build_object(
                   'key',   t.clave,
                   'from',  t.desde,
                   'to',    t.hasta,
                   'users', (select count(*) from bits y
                             where y.saldo >= t.desde and (t.hasta is null or y.saldo <= t.hasta))
                 ) order by t.desde)
          from (values ('0', 0, 0), ('1-99', 1, 99), ('100-299', 100, 299),
                       ('300-599', 300, 599), ('600+', 600, null::int)) t(clave, desde, hasta)
        )
      )
      from bits x
    )
  )
  into v_out;

  return v_out;
end;
$$;

comment on function public.admin_user_persona(text) is
  'El perfil agregado de la gente (registrados, verificados o consumieron): edad, sexo, ciudad de conexion al verificarse, aparato, ticket sin el fee, frecuencia, cuando sale, grupos, locales, niveles y Bits. Categorias con menos de 3 personas van a otras. Sin cuentas de prueba.';

revoke all on function public.admin_user_persona(text) from public, anon;
grant execute on function public.admin_user_persona(text) to authenticated;
