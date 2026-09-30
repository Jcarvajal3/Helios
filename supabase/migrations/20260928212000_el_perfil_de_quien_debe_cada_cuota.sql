-- ============================================================================
-- Ronda — El perfil de quien debe cada cuota de una semana
--
-- Pedido de Javier (28-09): en Por cobrar › Cohortes, cifras que resuman
-- cómo es la gente que debe cada cuota (edad, sexo…). Para que se lean, cada
-- cuota compara a quien la DEBE (vencida, por vencer o dada por perdida) con
-- quien ya la PAGÓ: lo que distingue a unos de otros es lo que sirve.
--
--   metricas.rasgos_de_personas(uuid[])  sexo, edad, ciudad, plataforma,
--       nivel y si recibe avisos. Las mismas definiciones que
--       admin_user_persona (20260927571000): sexo y aparato de Didit, la
--       fecha de nacimiento del perfil o del documento, la ciudad por IP sin
--       VPN ni centros de datos, y una edad fuera de 18-99 es un dato mal leído.
--
--   admin_perfil_de_deudores_de_la_semana(semana, local)  por cuota (1 y 2)
--       y por grupo (deben / pagaron): personas, cuántas vencidas y su atraso
--       medio, edad (mediana y tramos), sexo, plataforma, ciudades (una
--       ciudad con menos de 3 personas va a «otras»), nivel, primera semana en
--       Ronda, consumo en grupo, consumo medio de la semana (sin fee) y sin
--       avisos. Las cuotas salen de metricas.cuotas, como las cifras de la
--       semana: quien debe aquí es quien sale en la lista de debajo.
-- ============================================================================

create or replace function metricas.rasgos_de_personas(p_users uuid[])
returns table (
  user_id         uuid,
  sexo            text,
  edad            integer,
  ciudad          text,
  plataforma      text,
  nivel           integer,
  avisos_activos  boolean
)
language sql
stable
set search_path = public, pg_temp
as $$
  with
  u as (select distinct x as user_id from unnest(p_users) x where x is not null),
  sexo as (
    select distinct on (v.user_id) v.user_id, v.extracted_gender as sexo
    from kyc.verifications v
    join u using (user_id)
    where v.extracted_gender in ('M', 'F')
    order by v.user_id, v.created_at desc
  ),
  didit as (
    select distinct on (v.user_id) v.user_id, v.didit_device as d
    from kyc.verifications v
    join u using (user_id)
    where jsonb_typeof(v.didit_device) = 'object'
    order by v.user_id, coalesce(v.didit_details_at, v.created_at) desc
  ),
  app as (
    select distinct on (d.user_id) d.user_id, lower(btrim(d.platform)) as plataforma
    from public.user_devices d
    join u using (user_id)
    order by d.user_id, d.last_seen_at desc nulls last
  ),
  crudo as (
    select
      u.user_id,
      s.sexo,
      date_part('year', age(public.helios_caracas_date(now())::timestamp,
        coalesce(p.birth_date, (
          select coalesce(v.confirmed_birth, v.extracted_birth)
          from kyc.verifications v
          where v.user_id = u.user_id
            and coalesce(v.confirmed_birth, v.extracted_birth) is not null
          order by v.created_at desc
          limit 1
        ))::timestamp))::int                                              as anios,
      nullif(btrim(d.d ->> 'os_family'), '')                             as sistema,
      case
        when lower(coalesce(d.d ->> 'is_vpn_or_tor', '')) in ('true', 't', '1')
          or lower(coalesce(d.d ->> 'is_data_center', '')) in ('true', 't', '1') then null
        else nullif(btrim(d.d ->> 'ip_city'), '')
      end                                                                as ciudad,
      a.plataforma                                                       as plataforma_app,
      p.level                                                            as nivel,
      exists (select 1 from public.push_tokens t
              where t.user_id = u.user_id and t.disabled_at is null)     as avisos_activos
    from u
    join public.profiles p on p.id = u.user_id
    left join sexo  s on s.user_id = u.user_id
    left join didit d on d.user_id = u.user_id
    left join app   a on a.user_id = u.user_id
  )
  select
    c.user_id,
    c.sexo,
    case when c.anios between 18 and 99 then c.anios end,
    c.ciudad,
    case
      when c.sistema ~* '^android' then 'android'
      when c.sistema ~* '^(ios|ipados|iphone)' then 'ios'
      when c.sistema is not null then 'web'
      when c.plataforma_app in ('android', 'ios', 'web') then c.plataforma_app
    end,
    c.nivel,
    c.avisos_activos
  from crudo c;
$$;

comment on function metricas.rasgos_de_personas(uuid[]) is
  'Sexo, edad, ciudad, plataforma, nivel y si recibe avisos de cada persona, con las definiciones de admin_user_persona. Para los perfiles de Por cobrar.';

create or replace function public.admin_perfil_de_deudores_de_la_semana(
  p_semana      date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  -- El umbral de privacidad de Gente › Perfil: una ciudad con menos gente
  -- va a «otras».
  c_min   constant integer := 3;
  v_today date := public.helios_business_date(now());
  v_lunes date := metricas.lunes(coalesce(p_semana, v_today));
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  q as materialized (
    select *
    from metricas.cuotas c
    where c.semana = v_lunes
      and (p_merchant_id is null or c.merchant_id = p_merchant_id)
  ),
  -- Cada persona, una vez por número de cuota: la debe si alguna de sus
  -- cuotas con ese número sigue sin pagar.
  pc as (
    select
      q.user_id,
      q.sequence::int                                                     as numero,
      bool_or(q.estado_hoy in ('vencida', 'por_vencer', 'perdida'))       as debe,
      bool_or(q.estado_hoy in ('vencida', 'perdida'))                     as vencida,
      max(q.dias_atraso) filter (where q.estado_hoy in ('vencida', 'perdida')) as dias,
      bool_or(q.es_grupo)                                                 as en_grupo
    from q
    group by q.user_id, q.sequence
  ),
  -- Lo que consumió esa semana (sin fee), sus dos cuotas.
  consumo as (
    select q.user_id, sum(q.financed_usd) as fin
    from q
    group by q.user_id
  ),
  -- Su primera semana con consumo en Ronda, en cualquier local.
  primera as (
    select c.user_id, min(c.semana) as semana
    from metricas.cuotas c
    where c.user_id in (select user_id from consumo)
    group by c.user_id
  ),
  rasgos as materialized (
    select * from metricas.rasgos_de_personas(array(select user_id from consumo))
  ),
  base as (
    select
      pc.numero,
      case when pc.debe then 'deben' else 'pagaron' end                   as grupo,
      pc.user_id, pc.vencida, pc.dias, pc.en_grupo,
      r.sexo, r.edad, r.ciudad, r.plataforma, r.nivel, r.avisos_activos,
      k.fin,
      pr.semana = v_lunes                                                  as nuevo
    from pc
    join consumo k  on k.user_id  = pc.user_id
    join primera pr on pr.user_id = pc.user_id
    left join rasgos r on r.user_id = pc.user_id
  ),
  ciudades as (
    select b.numero, b.grupo, b.ciudad, count(*)::int as n
    from base b
    where b.ciudad is not null
    group by b.numero, b.grupo, b.ciudad
  ),
  ciudades_json as (
    select c.numero, c.grupo,
      coalesce(jsonb_agg(jsonb_build_object('ciudad', c.ciudad, 'personas', c.n)
                         order by c.n desc, c.ciudad) filter (where c.n >= c_min), '[]'::jsonb) as top,
      coalesce(sum(c.n) filter (where c.n < c_min), 0)::int              as otras
    from ciudades c
    group by c.numero, c.grupo
  ),
  resumen as (
    select
      b.numero, b.grupo,
      jsonb_build_object(
        'personas',          count(*),
        'vencidas',          count(*) filter (where b.vencida),
        'atraso_medio_dias', round(avg(b.dias) filter (where b.vencida), 1),
        'edad', jsonb_build_object(
          'conocida', count(b.edad),
          'mediana',  percentile_cont(0.5) within group (order by b.edad) filter (where b.edad is not null),
          'tramos', jsonb_build_object(
            '18-24', count(*) filter (where b.edad between 18 and 24),
            '25-34', count(*) filter (where b.edad between 25 and 34),
            '35-44', count(*) filter (where b.edad between 35 and 44),
            '45+',   count(*) filter (where b.edad >= 45))),
        'sexo', jsonb_build_object(
          'F',        count(*) filter (where b.sexo = 'F'),
          'M',        count(*) filter (where b.sexo = 'M'),
          'sin_dato', count(*) filter (where b.sexo is null)),
        'plataforma', jsonb_build_object(
          'android',  count(*) filter (where b.plataforma = 'android'),
          'ios',      count(*) filter (where b.plataforma = 'ios'),
          'otra',     count(*) filter (where b.plataforma = 'web'),
          'sin_dato', count(*) filter (where b.plataforma is null)),
        'nivel_medio',       round(avg(b.nivel), 1),
        'nuevos',            count(*) filter (where b.nuevo),
        'en_grupo',          count(*) filter (where b.en_grupo),
        'sin_avisos',        count(*) filter (where not coalesce(b.avisos_activos, false)),
        'consumo_medio_usd', round(avg(b.fin), 2)
      ) as r
    from base b
    group by b.numero, b.grupo
  )
  select jsonb_build_object(
    'semana', v_lunes,
    'business_date', v_today,
    'merchant_id', p_merchant_id,
    'cuotas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'numero',  n.numero,
               'deben',   (select s.r || jsonb_build_object('ciudades', coalesce(cj.top, '[]'::jsonb), 'ciudades_otras', coalesce(cj.otras, 0))
                           from resumen s left join ciudades_json cj on cj.numero = s.numero and cj.grupo = s.grupo
                           where s.numero = n.numero and s.grupo = 'deben'),
               'pagaron', (select s.r || jsonb_build_object('ciudades', coalesce(cj.top, '[]'::jsonb), 'ciudades_otras', coalesce(cj.otras, 0))
                           from resumen s left join ciudades_json cj on cj.numero = s.numero and cj.grupo = s.grupo
                           where s.numero = n.numero and s.grupo = 'pagaron'))
             order by n.numero)
      from (select distinct numero from base) n
    ), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.admin_perfil_de_deudores_de_la_semana(date, uuid) is
  'Por cobrar › Cohortes: por cuota (1 y 2) de lo consumido la semana de p_semana, quién la debe (vencida, por vencer o perdida) frente a quién la pagó: personas, vencidas y atraso medio, edad, sexo, plataforma, ciudades (menos de 3 personas van a otras), nivel, primera semana en Helios, consumo en grupo, consumo medio sin fee y sin avisos.';

revoke all on function public.admin_perfil_de_deudores_de_la_semana(date, uuid) from public, anon;
grant execute on function public.admin_perfil_de_deudores_de_la_semana(date, uuid) to authenticated, service_role;
