-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — Los nombres de los médicos, con mayúscula inicial
--
-- Javier, 2026-10-29: los nombres llegaban como se teclearon («JESUS STANLEY
-- VELASQUEZ R», «zuleidys arellano», «Elizabeth Del valle ponte Castillo»).
-- `helios_person_name_text` (20261019000300) ya los arreglaba al enseñarlos
-- en los mensajes y el directorio, pero lo guardado seguía igual, y el
-- superadmin, el contrato y la exportación lo enseñaban tal cual.
--
-- 1. `helios_person_name_text` arregla mejor las partículas: «da», «das»,
--    «do» y «dos» van en minúscula («Lucymar da Silva», «de Abreu dos
--    Reis»), y «la», «las» y «los» solo detrás de «de» («María de la Luz»,
--    «Montes de Oca»), no sueltas («Peña La Grave», «Henríquez La Cruz»).
-- 2. Un trigger guarda el nombre del titular ya arreglado en `merchants` y
--    en `merchant_applications`: lo cubre todo, el formulario de afiliación,
--    el alta del superadmin y la ficha (`admin_set_merchant_owner`). Si el
--    nombre traía el título delante («DR. VICTOR») y la fila no tenía
--    título, se le pone: se quita del nombre, pero no se pierde.
-- 3. Se arreglan los nombres que ya estaban, sin tocar `updated_at`: no son
--    una edición del perfil.
--
-- La agenda (`doctor_leads.name`) no se toca: ahí el título va dentro del
-- nombre («Dr. Alejandro Teppa») porque no tiene columna propia. Lo que
-- llega del formulario ya entra arreglado, porque sale de la solicitud.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Las partículas
-- ---------------------------------------------------------------------------

create or replace function public.helios_person_name_text(p_name text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select nullif(string_agg(
           case when n > 1 and (lower(w) in ('de', 'del', 'y', 'da', 'das', 'do', 'dos')
                                or (lower(w) in ('la', 'las', 'los') and lower(anterior) = 'de'))
                then lower(w) else initcap(w) end,
           ' ' order by n), '')
  from (
    select w, n, lag(w) over (order by n) as anterior
      from regexp_split_to_table(
             btrim(regexp_replace(regexp_replace(coalesce(p_name, ''),
                                                 '^\s*((dra|dr|lcda|lcdo|licda|licdo)\.?|od\.)\s+', '', 'i'),
                                  '\s+', ' ', 'g')),
             ' ') with ordinality as t(w, n)
     where w <> ''
  ) palabras;
$$;

revoke all on function public.helios_person_name_text(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Se guarda arreglado
-- ---------------------------------------------------------------------------

/**
 * El título que traía escrito delante el nombre («DR. VICTOR» → 'Dr.'), con
 * la misma lista que quita `helios_person_name_text`. `null` si no trae.
 */
create or replace function public.helios_titulo_escrito_en_el_nombre(p_name text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case substring(lower(coalesce(p_name, '')) from '^\s*((?:dra|dr|lcda|lcdo|licda|licdo)\.?|od\.)\s+')
           when 'dr' then 'Dr.' when 'dr.' then 'Dr.'
           when 'dra' then 'Dra.' when 'dra.' then 'Dra.'
           when 'lcdo' then 'Lcdo.' when 'lcdo.' then 'Lcdo.' when 'licdo' then 'Lcdo.' when 'licdo.' then 'Lcdo.'
           when 'lcda' then 'Lcda.' when 'lcda.' then 'Lcda.' when 'licda' then 'Lcda.' when 'licda.' then 'Lcda.'
           when 'od.' then 'Od.'
         end
$$;

revoke all on function public.helios_titulo_escrito_en_el_nombre(text) from public, anon, authenticated;

create or replace function public.helios_arreglar_nombre_del_titular()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.owner_name is not null then
    if new.doctor_title is null then
      new.doctor_title := public.helios_titulo_escrito_en_el_nombre(new.owner_name);
    end if;
    -- Un nombre que se queda en nada se deja como vino: que lo rechace su
    -- regla, con su mensaje.
    new.owner_name := coalesce(public.helios_person_name_text(new.owner_name), new.owner_name);
  end if;
  return new;
end;
$$;

drop trigger if exists merchants_nombre_del_titular on public.merchants;
create trigger merchants_nombre_del_titular
  before insert or update of owner_name on public.merchants
  for each row execute function public.helios_arreglar_nombre_del_titular();

drop trigger if exists merchant_applications_nombre_del_titular on public.merchant_applications;
create trigger merchant_applications_nombre_del_titular
  before insert or update of owner_name on public.merchant_applications
  for each row execute function public.helios_arreglar_nombre_del_titular();

-- ---------------------------------------------------------------------------
-- 3. Los que ya estaban
-- ---------------------------------------------------------------------------

alter table public.merchants disable trigger merchants_touch_updated_at;

-- Asignarse a sí mismo dispara el trigger, que hace el arreglo.
update public.merchants
   set owner_name = owner_name
 where owner_name is distinct from public.helios_person_name_text(owner_name)
   and public.helios_person_name_text(owner_name) is not null;

alter table public.merchants enable trigger merchants_touch_updated_at;

update public.merchant_applications
   set owner_name = owner_name
 where owner_name is distinct from public.helios_person_name_text(owner_name)
   and public.helios_person_name_text(owner_name) is not null;
