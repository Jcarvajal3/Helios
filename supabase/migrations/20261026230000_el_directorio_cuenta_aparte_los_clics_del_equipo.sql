-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — La pestaña del directorio dice cuántos clics del equipo dejó fuera
--
-- Los toques al botón de WhatsApp que hace alguien con sesión del equipo o del
-- personal de una clínica se guardan con `origin` `equipo` o `clinica` y no
-- cuentan en las cifras (20261026190000). Bien, pero quien probaba el
-- directorio con el superadmin abierto en el mismo navegador veía la pestaña
-- en cero y creía que el registro de clics estaba roto (Javier, 2026-10-26).
--
-- `admin_directorio()` añade a `totales` lo que dejó fuera en los últimos 30
-- días operativos: `clics_internos_30d` y `ultimo_interno`. Las demás cifras
-- no cambian.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_directorio()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy   date := public.helios_business_date(now());
  v_desde date := public.helios_business_date(now()) - 29;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'hoy', v_hoy,
    'desde', v_desde,
    'totales', (
      select jsonb_build_object(
        'clics_total', count(*),
        'clics_7d', count(*) filter (where d.dia > v_hoy - 7),
        'clics_30d', count(*) filter (where d.dia >= v_desde),
        'clics_30d_anteriores', count(*) filter (where d.dia between v_desde - 30 and v_desde - 1),
        'visitantes_30d', count(distinct c.visitor_id) filter (where d.dia >= v_desde),
        'medicos_contactados_30d', count(distinct c.merchant_id) filter (where d.dia >= v_desde)
      )
      from public.directory_contact_clicks c
      cross join lateral (select public.helios_business_date(c.created_at) as dia) d
      where c.origin = 'publico'
    ) || (
      -- Los del equipo y los del personal de las clínicas: no cuentan, pero se
      -- dice cuántos hubo para que una prueba no parezca un fallo.
      select jsonb_build_object(
        'clics_internos_30d', count(*),
        'ultimo_interno', max(c.created_at)
      )
      from public.directory_contact_clicks c
      where c.origin <> 'publico'
        and c.created_at >= (v_desde::timestamp at time zone 'America/Caracas')
    ),
    'por_dia', (
      select jsonb_agg(jsonb_build_object(
               'dia', s.dia,
               'clics', coalesce(x.clics, 0),
               'visitantes', coalesce(x.visitantes, 0)
             ) order by s.dia)
        from (select generate_series(v_desde, v_hoy, interval '1 day')::date as dia) s
        left join lateral (
          select count(*) as clics, count(distinct c.visitor_id) as visitantes
            from public.directory_contact_clicks c
           where c.origin = 'publico'
             and c.created_at >= (s.dia::timestamp at time zone 'America/Caracas')
             and c.created_at <  ((s.dia + 1)::timestamp at time zone 'America/Caracas')
        ) x on true
    ),
    'medicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'merchant_id', f.merchant_id,
               'clinic_name', f.clinic_name,
               'status', f.status,
               'is_test', f.is_test,
               'is_visible', f.is_visible,
               'blocked_reason', f.blocked_reason,
               'published_at', f.published_at,
               'updated_at', f.updated_at,
               'listing', jsonb_build_object(
                 'name', f.name, 'specialty', f.specialty, 'specialty_key', f.specialty_key,
                 'address', f.address, 'city', f.city, 'whatsapp', f.whatsapp,
                 'social_network', f.social_network, 'social_user', f.social_user),
               'base', jsonb_build_object(
                 'name', f.base_name, 'specialty', f.base_specialty, 'specialty_key', f.base_specialty_key,
                 'address', f.base_address, 'city', f.base_city, 'whatsapp', f.base_whatsapp,
                 'social_network', f.base_social_network, 'social_user', f.base_social_user),
               'clics', jsonb_build_object(
                 'total', coalesce(k.total, 0),
                 'd7', coalesce(k.d7, 0),
                 'd30', coalesce(k.d30, 0),
                 'visitantes_30d', coalesce(k.visitantes_30d, 0),
                 'ultimo', k.ultimo,
                 'por_dia', (
                   select jsonb_agg(coalesce(p.n, 0) order by s.dia)
                     from (select generate_series(v_desde, v_hoy, interval '1 day')::date as dia) s
                     left join (
                       select public.helios_business_date(c.created_at) as dia, count(*) as n
                         from public.directory_contact_clicks c
                        where c.merchant_id = f.merchant_id and c.origin = 'publico'
                          and c.created_at >= (v_desde::timestamp at time zone 'America/Caracas')
                        group by 1
                     ) p on p.dia = s.dia
                 )
               )
             ) order by f.is_visible desc, coalesce(k.d30, 0) desc, f.name)
        from public.helios_directorio_fichas() f
        left join lateral (
          select count(*) as total,
                 count(*) filter (where d.dia > v_hoy - 7) as d7,
                 count(*) filter (where d.dia >= v_desde) as d30,
                 count(distinct c.visitor_id) filter (where d.dia >= v_desde) as visitantes_30d,
                 max(c.created_at) as ultimo
            from public.directory_contact_clicks c
            cross join lateral (select public.helios_business_date(c.created_at) as dia) d
           where c.merchant_id = f.merchant_id and c.origin = 'publico'
        ) k on true
    ), '[]'::jsonb)
  );
end;
$$;

