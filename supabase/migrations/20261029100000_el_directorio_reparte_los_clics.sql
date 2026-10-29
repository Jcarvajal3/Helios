-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El orden del directorio reparte los clics
--
-- Javier (2026-10-29): hasta hoy `/directorio` enseñaba a los médicos por
-- orden alfabético, y el de arriba se llevaba casi todos los clics por estar
-- primero. Ahora el orden cambia en cada visita y favorece a quien menos
-- contactos ha recibido, para que los clics se repartan.
--
-- El algoritmo es un sorteo ponderado (Efraimidis–Spirakis): a cada médico se
-- le sortea u ∈ (0, 1) y se ordena por u^(1 + c) de mayor a menor, donde c son
-- sus clics públicos de los últimos 7 días. Es lo mismo que sacar médicos de
-- una urna, uno a uno, con un peso de 1 / (1 + c):
--
--   · con los mismos clics, cada uno sale primero igual de veces: el orden
--     rota entre visitas;
--   · entre uno con a clics y otro con b, el primero sale por encima con
--     probabilidad (1 + b) / (2 + a + b): con 0 y 9, 10 de cada 11 veces;
--   · nadie queda fijo arriba ni abajo, y un médico recién publicado (0 clics)
--     tiende a salir arriba.
--
-- Solo cuentan los clics públicos (`origin = 'publico'`): los del equipo y
-- los del personal de las clínicas no mueven el orden. La ventana de 7 días
-- hace que el reparto se ajuste rápido y que un pico de hace un mes no
-- castigue a nadie. El sorteo va en la base y no en el navegador: la página
-- lo recibe ya ordenado (y lo pinta igual en el servidor y en el navegador).
--
-- Cambia solo el orden y la volatilidad (el sorteo hace que dos llamadas
-- seguidas no devuelvan lo mismo); las columnas son las mismas.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.helios_directorio()
returns table (
  merchant_id    uuid,
  name           text,
  specialty      text,
  specialty_key  text,
  address        text,
  city           text,
  whatsapp       text,
  social_network text,
  social_user    text,
  lead_code      text
)
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  select f.merchant_id, f.name, f.specialty, f.specialty_key, f.address, f.city, f.whatsapp,
         f.social_network, f.social_user, l.lead_code
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
   -- El sorteo ponderado: menos clics, más probable salir arriba.
   order by power(random(), 1 + coalesce(k.clics, 0)) desc;
$$;

comment on function public.helios_directorio() is
  'Directorio de médicos: las clínicas publicadas (visibles, activas, no de prueba y con WhatsApp) con lo que enseña su tarjeta, red social y código (DIR-XXXX) incluidos, en un orden sorteado en cada llamada que favorece a quien tiene menos clics públicos en 7 días. Pública.';

revoke all on function public.helios_directorio() from public;
grant execute on function public.helios_directorio() to anon, authenticated;
