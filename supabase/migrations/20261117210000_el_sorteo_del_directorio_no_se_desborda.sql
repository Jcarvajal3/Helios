-- El directorio no cargaba ("value out of range: underflow", 22003).
--
-- El sorteo ponderado ordenaba por power(random(), 1 + clics): con un médico
-- que acumula muchos clics públicos en 7 días y un random() pequeño, el
-- resultado baja del mínimo de un double y Postgres lanza el error en vez de
-- devolver 0. Una sola fila así tumba toda la lista (y /consultas, que la
-- reutiliza).
--
-- Se ordena por el logaritmo, que da el mismo orden sin desbordarse:
--   power(r, k) desc  ==  k * ln(r) desc      (r en (0,1], k >= 1)
-- `greatest(random(), 1e-300)` evita ln(0), que también falla.
--
-- Misma firma, mismos permisos y mismo comentario (create or replace).

create or replace function public.helios_directorio()
 RETURNS TABLE(merchant_id uuid, name text, specialty text, specialty_key text, address text, city text, whatsapp text, social_network text, social_user text, lead_code text, slug text, updated_at timestamp with time zone, consultation_price_cur numeric, consultation_currency text, other_specialty_keys text[])
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user, l.lead_code, l.slug, l.updated_at, f.consultation_price_cur, f.consultation_currency,
         f.other_specialty_keys
    from public.helios_directorio_fichas() f
    join public.directory_listings l on l.merchant_id = f.merchant_id
    left join lateral (
      select count(*) as clics
        from public.directory_contact_clicks c
       where c.merchant_id = f.merchant_id
         and c.origin = 'publico'
         and c.created_at > now() - interval '7 days'
    ) k on true
   where f.is_visible and f.blocked_reason is null
   -- El sorteo ponderado de 20261029100000: menos clics, más probable salir
   -- arriba. En logaritmos, para que muchos clics no desborden el cálculo.
   order by (1 + coalesce(k.clics, 0)) * ln(greatest(random(), 1e-300)) desc;
$function$;
