-- ═══════════════════════════════════════════════════════════════════════════
-- Prueba A/B del directorio (docs/06): la tasa de clic cuenta solo a quien
-- visitó.
--
-- `visitantes_con_clic` contaba a todo navegador con un clic en el rango.
-- Las visitas se apuntan desde el 2026-11-09, pero los clics vienen de antes,
-- y además hay clics desde páginas que no apuntan visita (las guías del
-- paciente): la tasa podía pasar del 100%. Ahora cuenta solo los navegadores
-- con un clic de esa variante que también tienen una visita apuntada de esa
-- variante (en el rango; en la serie, ese mismo día). `clics` sigue contando
-- todos los toques.
-- ═══════════════════════════════════════════════════════════════════════════

/**
 * La prueba A/B entre `p_desde` y `p_hasta` (días de Caracas, los dos
 * incluidos; como mucho 366 días; sin `p_hasta`, hoy; sin `p_desde`, los 7
 * días que acaban en `p_hasta`). Solo lo público (`origin = 'publico'`).
 *
 *   · `variantes`: por variante, las visitas, los visitantes distintos
 *     (`coalesce(visitor_id, id)`), los clics, los visitantes distintos con
 *     algún clic de esa variante en el rango que también la visitaron (20261109140000), los interesados (por su primer
 *     mensaje) y, de esos, los convertidos (`helios_directorio_conversion`).
 *   · `dias`: todos los días del rango, también los vacíos.
 *   · `medicos`: los que entran hoy en B y cualquiera con un clic o un
 *     interesado de B en el rango, el de más clics primero.
 *   · `excluidos`: las visitas y los clics del equipo y de las clínicas.
 *   · `visitas_desde`: el día de la primera visita apuntada (o null).
 */
create or replace function public.admin_directorio_ab(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hasta date := coalesce(p_hasta, public.helios_business_date(now()));
  v_desde date := coalesce(p_desde, coalesce(p_hasta, public.helios_business_date(now())) - 6);
  v_ini   timestamptz;
  v_fin   timestamptz;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  if v_desde > v_hasta then
    raise exception 'El rango empieza después de terminar' using errcode = '22023';
  end if;
  if v_hasta - v_desde + 1 > 366 then
    raise exception 'El rango no puede pasar de 366 días' using errcode = '22023';
  end if;

  v_ini := v_desde::timestamp at time zone 'America/Caracas';
  v_fin := (v_hasta + 1)::timestamp at time zone 'America/Caracas';

  return (
    with vis as (
      select v.variant, public.helios_business_date(v.created_at) as dia,
             coalesce(v.visitor_id, v.id::text) as quien
        from public.directory_page_views v
       where v.origin = 'publico' and v.created_at >= v_ini and v.created_at < v_fin
    ),
    cli as (
      select c.variant, c.merchant_id, public.helios_business_date(c.created_at) as dia,
             coalesce(c.visitor_id, 'clic-' || c.id::text) as quien
        from public.directory_contact_clicks c
       where c.origin = 'publico' and c.created_at >= v_ini and c.created_at < v_fin
    ),
    lea as (
      select l.variant, l.merchant_id, (cv.charge_id is not null) as convertido
        from public.directory_leads l
        left join lateral public.helios_directorio_conversion(l.merchant_id, l.phone_e164, l.first_at) cv on true
       where l.first_at >= v_ini and l.first_at < v_fin
    ),
    var as (
      select * from (values ('a', '/directorio', 1), ('b', '/consultas', 2)) x(variante, ruta, orden)
    ),
    dias as (
      select s.dia::date as dia from generate_series(v_desde, v_hasta, interval '1 day') s(dia)
    ),
    med as (
      select f.merchant_id, f.name as medico, f.consultation_price_cur, f.consultation_currency,
             (f.is_visible and f.blocked_reason is null
              and public.helios_consultas_entra(
                    public.helios_directorio_precio_usd(f.consultation_price_cur, f.consultation_currency))) as en_b,
             (select count(*) from cli where cli.merchant_id = f.merchant_id and cli.variant = 'a') as clics_a,
             (select count(*) from cli where cli.merchant_id = f.merchant_id and cli.variant = 'b') as clics_b,
             (select count(*) from lea where lea.merchant_id = f.merchant_id and lea.variant = 'b') as interesados_b,
             (select count(*) from lea where lea.merchant_id = f.merchant_id and lea.variant = 'b'
                                         and lea.convertido) as convertidos_b
        from public.helios_directorio_fichas() f
    )
    select jsonb_build_object(
      'desde', v_desde,
      'hasta', v_hasta,
      'variantes', (
        select jsonb_agg(jsonb_build_object(
                 'variante', var.variante,
                 'ruta', var.ruta,
                 'visitas', (select count(*) from vis where vis.variant = var.variante),
                 'visitantes', (select count(distinct vis.quien) from vis where vis.variant = var.variante),
                 'clics', (select count(*) from cli where cli.variant = var.variante),
                 'visitantes_con_clic', (select count(distinct cli.quien) from cli
                                           where cli.variant = var.variante
                                             and exists (select 1 from vis where vis.variant = cli.variant and vis.quien = cli.quien)),
                 'interesados', (select count(*) from lea where lea.variant = var.variante),
                 'convertidos', (select count(*) from lea where lea.variant = var.variante and lea.convertido)
               ) order by var.orden)
          from var
      ),
      'dias', (
        select jsonb_agg(jsonb_build_object(
                 'dia', dias.dia,
                 'a', jsonb_build_object(
                   'visitantes', (select count(distinct vis.quien) from vis where vis.dia = dias.dia and vis.variant = 'a'),
                   'visitantes_con_clic', (select count(distinct cli.quien) from cli where cli.dia = dias.dia and cli.variant = 'a'
                                             and exists (select 1 from vis where vis.variant = cli.variant and vis.dia = cli.dia and vis.quien = cli.quien)),
                   'clics', (select count(*) from cli where cli.dia = dias.dia and cli.variant = 'a')),
                 'b', jsonb_build_object(
                   'visitantes', (select count(distinct vis.quien) from vis where vis.dia = dias.dia and vis.variant = 'b'),
                   'visitantes_con_clic', (select count(distinct cli.quien) from cli where cli.dia = dias.dia and cli.variant = 'b'
                                             and exists (select 1 from vis where vis.variant = cli.variant and vis.dia = cli.dia and vis.quien = cli.quien)),
                   'clics', (select count(*) from cli where cli.dia = dias.dia and cli.variant = 'b'))
               ) order by dias.dia)
          from dias
      ),
      'medicos', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'merchant_id', med.merchant_id,
                 'medico', med.medico,
                 'precio_cur', trim_scale(med.consultation_price_cur),
                 'moneda', med.consultation_currency,
                 'en_b', med.en_b,
                 'clics_a', med.clics_a,
                 'clics_b', med.clics_b,
                 'interesados_b', med.interesados_b,
                 'convertidos_b', med.convertidos_b
               ) order by med.clics_a + med.clics_b desc, med.medico, med.merchant_id)
          from med
         where med.en_b or med.clics_a + med.clics_b > 0 or med.interesados_b > 0
      ), '[]'::jsonb),
      'excluidos', jsonb_build_object(
        'visitas_equipo', (
          select count(*) from public.directory_page_views v
           where v.origin <> 'publico' and v.created_at >= v_ini and v.created_at < v_fin),
        'clics_equipo', (
          select count(*) from public.directory_contact_clicks c
           where c.origin <> 'publico' and c.created_at >= v_ini and c.created_at < v_fin)
      ),
      'visitas_desde', (select min(public.helios_business_date(v.created_at)) from public.directory_page_views v)
    )
  );
end;
$$;

comment on function public.admin_directorio_ab(date, date) is
  'Prueba A/B del directorio (docs/06): entre dos días de Caracas (incluidos, hasta 366), por variante (a = /directorio, b = /consultas) las visitas, visitantes, clics, visitantes con clic, interesados y convertidos; la serie diaria; los médicos de B y los que tuvieron clics; lo excluido del equipo y el primer día con visitas. Solo lo público. Los dos roles.';

revoke all on function public.admin_directorio_ab(date, date) from public, anon;
grant execute on function public.admin_directorio_ab(date, date) to authenticated;
