-- ============================================================================
-- Ronda — El perfil de los morosos
--
-- Pedido de Javier (29-09): «Cómo es quien debe» sale de Por cobrar ›
-- Cohortes (donde iba por semana y por cuota) y pasa a Por cobrar › Morosos,
-- en general y sin separar por cuotas.
--
-- Compara dos grupos de personas, de todas las semanas y todos los locales:
--
--   morosos   deben algo vencido hoy (una cuota vencida o dada por perdida):
--             la misma gente que la lista de Morosos.
--   al día    ya les venció alguna cuota y hoy no deben nada vencido: la
--             gente con la que se compara, porque también tuvo que pagar.
--
-- Mismos rasgos y mismas claves que admin_perfil_de_deudores_de_la_semana
-- (20260928212000), con metricas.rasgos_de_personas. Tres cambian de sentido
-- al dejar de ser de una semana:
--   nuevos     su primer consumo en Ronda fue hace menos de 4 semanas;
--   en_grupo   consumió en grupo alguna vez;
--   consumo    lo que ha consumido en Ronda, sin fee, de media por persona.
-- Las cuentas de prueba no cuentan (metricas.cuotas ya las deja fuera).
-- ============================================================================

create or replace function public.admin_perfil_de_morosos()
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
  v_out   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  with
  q as materialized (
    select * from metricas.cuotas
  ),
  -- Cada persona que ya tuvo que pagar algo, con su situación de hoy.
  pp as (
    select
      q.user_id,
      bool_or(q.estado_hoy in ('vencida', 'perdida'))                     as moroso,
      max(q.dias_atraso) filter (where q.estado_hoy in ('vencida', 'perdida')) as dias,
      bool_or(q.es_grupo)                                                 as en_grupo,
      sum(q.financed_usd)                                                 as fin,
      min(q.semana)                                                       as primera
    from q
    group by q.user_id
    having min(q.due_date) < v_today
  ),
  rasgos as materialized (
    select * from metricas.rasgos_de_personas(array(select user_id from pp))
  ),
  base as (
    select
      case when pp.moroso then 'morosos' else 'al_dia' end                as grupo,
      pp.user_id, pp.moroso, pp.dias, pp.en_grupo, pp.fin,
      r.sexo, r.edad, r.ciudad, r.plataforma, r.nivel, r.avisos_activos,
      pp.primera > metricas.lunes(v_today) - 28                            as nuevo
    from pp
    left join rasgos r on r.user_id = pp.user_id
  ),
  ciudades as (
    select b.grupo, b.ciudad, count(*)::int as n
    from base b
    where b.ciudad is not null
    group by b.grupo, b.ciudad
  ),
  ciudades_json as (
    select c.grupo,
      coalesce(jsonb_agg(jsonb_build_object('ciudad', c.ciudad, 'personas', c.n)
                         order by c.n desc, c.ciudad) filter (where c.n >= c_min), '[]'::jsonb) as top,
      coalesce(sum(c.n) filter (where c.n < c_min), 0)::int              as otras
    from ciudades c
    group by c.grupo
  ),
  resumen as (
    select
      b.grupo,
      jsonb_build_object(
        'personas',          count(*),
        'vencidas',          count(*) filter (where b.moroso),
        'atraso_medio_dias', round(avg(b.dias) filter (where b.moroso), 1),
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
    group by b.grupo
  )
  select jsonb_build_object(
    'business_date', v_today,
    'morosos', (select s.r || jsonb_build_object('ciudades', coalesce(cj.top, '[]'::jsonb), 'ciudades_otras', coalesce(cj.otras, 0))
                from resumen s left join ciudades_json cj on cj.grupo = s.grupo
                where s.grupo = 'morosos'),
    'al_dia',  (select s.r || jsonb_build_object('ciudades', coalesce(cj.top, '[]'::jsonb), 'ciudades_otras', coalesce(cj.otras, 0))
                from resumen s left join ciudades_json cj on cj.grupo = s.grupo
                where s.grupo = 'al_dia')
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.admin_perfil_de_morosos() is
  'Por cobrar › Morosos: cómo es quien debe algo vencido hoy (morosos) frente a quien ya tuvo que pagar y está al día, de todas las semanas y locales: personas, atraso medio, edad, sexo, plataforma, ciudades (menos de 3 personas van a otras), nivel, menos de 4 semanas en Helios, consumo en grupo alguna vez, consumo medio en Helios sin fee y sin avisos. Sin cuentas de prueba.';

revoke all on function public.admin_perfil_de_morosos() from public, anon;
grant execute on function public.admin_perfil_de_morosos() to authenticated, service_role;
