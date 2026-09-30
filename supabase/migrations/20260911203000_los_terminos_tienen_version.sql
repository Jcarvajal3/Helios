-- ============================================================================
-- Ronda — Los términos, versionados
--
-- `terms_acceptances` guarda qué versión aceptó cada persona desde el día uno.
-- Lo que no existe es **la otra mitad**: qué versiones hay, cuál es la vigente
-- y qué decía cada una. Sin eso, una aceptación es una cadena de texto suelta:
-- si alguien reclama, no se puede enseñar lo que firmó.
--
-- Y hace falta antes de crecer, no después. Los términos de un producto que
-- presta dinero cambian —cambia el fee, cambia la escalera, cambia el cargo— y
-- cada cambio deja a todo el padrón habiendo aceptado un texto que ya no es el
-- que rige. Poder decir «esta persona aceptó la v2 el 14 de agosto y decía
-- esto» es la diferencia entre tener un contrato y tener una casilla marcada.
--
-- ---------------------------------------------------------------------------
-- Publicar no es editar
-- ---------------------------------------------------------------------------
-- Una versión publicada **no se toca nunca**: hay gente que la aceptó. Corregir
-- una coma es publicar otra versión. Por eso no hay `admin_edit_terms`, solo
-- `admin_publish_terms`, y la tabla no tiene `updated_at`.
-- ============================================================================

create table if not exists public.terms_versions (
  version      text primary key,
  -- El texto completo tal y como se publicó. Guardarlo aquí y no solo enlazarlo
  -- es lo que hace que se pueda enseñar dentro de diez años, cuando la URL ya
  -- no exista.
  body         text not null,
  summary      text,
  url          text,
  published_at timestamptz not null default now(),
  published_by uuid references auth.users (id),
  -- Solo una vigente a la vez. El índice parcial lo garantiza.
  is_current   boolean not null default false
);

comment on table public.terms_versions is
  'Las versiones publicadas de los terminos. Una publicada no se edita nunca: hay gente que la acepto, y corregir una coma es publicar otra.';

create unique index if not exists terms_versions_current_idx
  on public.terms_versions (is_current) where is_current;

alter table public.terms_versions enable row level security;

-- La versión vigente la lee la app para saber qué enseñar: es pública para
-- cualquiera que haya entrado.
drop policy if exists "terms_versions_read" on public.terms_versions;
create policy "terms_versions_read"
  on public.terms_versions for select
  to authenticated
  using (true);

create or replace function public.helios_current_terms()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select to_jsonb(t) from (
    select version, body, summary, url, published_at
    from public.terms_versions where is_current limit 1
  ) t;
$fn$;

grant execute on function public.helios_current_terms() to authenticated;

-- ---------------------------------------------------------------------------
-- Publicar una versión
-- ---------------------------------------------------------------------------

create or replace function public.admin_publish_terms(
  p_version text,
  p_body    text,
  p_summary text default null,
  p_url     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede publicar los términos'
      using errcode = '42501';
  end if;

  if p_version is null or length(trim(p_version)) = 0 then
    raise exception 'La versión necesita nombre' using errcode = '22023';
  end if;

  if p_body is null or length(trim(p_body)) < 50 then
    raise exception 'El texto de los términos no puede estar vacío' using errcode = '22023';
  end if;

  -- Una versión publicada no se reescribe: hay gente que la aceptó.
  if exists (select 1 from public.terms_versions where version = trim(p_version)) then
    raise exception 'La versión % ya está publicada. Publica otra.', trim(p_version)
      using errcode = '23505';
  end if;

  update public.terms_versions set is_current = false where is_current;

  insert into public.terms_versions (version, body, summary, url, published_by, is_current)
  values (
    trim(p_version), p_body,
    nullif(trim(coalesce(p_summary, '')), ''),
    nullif(trim(coalesce(p_url, '')), ''),
    v_actor, true
  );

  perform audit.log(v_actor, 'terms.published', null, jsonb_build_object(
    'version', trim(p_version), 'summary', p_summary
  ));

  return jsonb_build_object('ok', true, 'version', trim(p_version));
end;
$$;

-- ---------------------------------------------------------------------------
-- Quién aceptó qué
-- ---------------------------------------------------------------------------

create or replace function public.admin_terms_versions()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows  jsonb;
  v_total integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select count(*)::integer into v_total from public.profiles where not is_test;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.published_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      t.version,
      t.summary,
      t.url,
      t.published_at,
      t.is_current,
      coalesce(pa.full_name, 'Alguien del equipo') as published_by_name,
      (
        select count(*)::integer
        from public.terms_acceptances a
        join public.profiles p on p.id = a.user_id
        where a.version = t.version and not p.is_test
      ) as accepted_count,
      (
        select min(a.accepted_at)
        from public.terms_acceptances a where a.version = t.version
      ) as first_accepted_at
    from public.terms_versions t
    left join public.platform_admins pa on pa.user_id = t.published_by
  ) q;

  return jsonb_build_object(
    'people_total', v_total,
    -- Quién no ha aceptado la vigente. Es el número que decide si se puede
    -- cambiar algo que dependa de los términos.
    'pending_current', (
      select count(*)::integer
      from public.profiles p
      where not p.is_test
        and not exists (
          select 1 from public.terms_acceptances a
          join public.terms_versions t on t.version = a.version
          where a.user_id = p.id and t.is_current
        )
    ),
    'rows', v_rows
  );
end;
$$;

/** Qué versión aceptó una persona y cuándo. Va en su ficha. */
create or replace function public.admin_user_terms(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.accepted_at desc), '[]'::jsonb)
  into v_rows
  from (
    select a.version, a.accepted_at, a.device_hash,
           t.summary, t.is_current
    from public.terms_acceptances a
    left join public.terms_versions t on t.version = a.version
    where a.user_id = p_user_id
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_publish_terms(text, text, text, text) from public, anon;
revoke all on function public.admin_terms_versions() from public, anon;
revoke all on function public.admin_user_terms(uuid) from public, anon;
grant execute on function public.admin_publish_terms(text, text, text, text) to authenticated;
grant execute on function public.admin_terms_versions() to authenticated;
grant execute on function public.admin_user_terms(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Las versiones que ya aceptó alguien, registradas
-- ---------------------------------------------------------------------------
-- Sin texto: no se guardó en su momento y no se puede reconstruir. Quedan
-- listadas para que el histórico de aceptaciones no apunte al vacío, y dicho
-- en el resumen que el texto no está.

insert into public.terms_versions (version, body, summary, is_current)
select distinct
  a.version,
  'El texto de esta versión no se guardó: es anterior al registro de versiones.',
  'Versión anterior al registro de versiones',
  false
from public.terms_acceptances a
where not exists (select 1 from public.terms_versions t where t.version = a.version)
on conflict (version) do nothing;
