-- ═══════════════════════════════════════════════════════════════════════════
-- RX — Los récipes digitales
--
-- El médico arma el récipe, se genera el PDF en el navegador, se guarda en un
-- bucket privado y se le manda al paciente por correo. Es un sistema aparte
-- para probarlo antes de integrarlo al panel (rx/README.md): esta migración
-- solo AÑADE. No toca ninguna tabla, función ni trigger que ya existieran.
--
--   · `rx_perfiles`: las correcciones del médico sobre los datos de su clínica
--     en `merchants`, su firma, su logo y el último número que emitió.
--   · `rx_recipes`: los récipes. El id lo genera el cliente: reintentar no
--     gasta otro número.
--   · `rx_envios`: cada correo que se intentó mandar.
--   · El bucket privado `rx`: <merchant>/firma/…, <merchant>/logo/…,
--     <merchant>/recipes/<id>.pdf.
--   · Las RPC `rx_*`, solo para el médico titular (`gerente`): un récipe lleva
--     su firma, así que la secretaria no entra. `rx_resultado_envio` es solo
--     para la service_role (la Edge Function `rx-enviar`).
--
-- Las tablas llevan RLS sin políticas y sin permisos para anon ni
-- authenticated: todo pasa por RPC.
-- ═══════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- 1. Las tablas
-- ---------------------------------------------------------------------------

create table public.rx_perfiles (
  merchant_id   uuid primary key references public.merchants (id),
  -- Correcciones: null = vale el dato de Helios (`merchants`).
  especialidad  text,
  cedula        text,
  mpps          text,
  colegio       text,
  telefono      text,
  correo        text,
  direccion     text,
  ciudad        text,
  consultorio   text,
  -- Rutas dentro del bucket `rx`.
  firma_path    text,
  logo_path     text,
  ultimo_numero integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.rx_perfiles is
  'RX: lo que el médico corrige de los datos de su clínica, su firma, su logo y el correlativo de sus récipes. Sin fila, valen los datos de `merchants`.';

create table public.rx_recipes (
  id                 uuid primary key,
  merchant_id        uuid not null references public.merchants (id),
  numero             integer not null,
  fecha              date not null,
  creado_por         uuid not null,
  paciente_nombre    text not null,
  paciente_documento text,
  paciente_edad      text,
  paciente_correo    text,
  medicamentos       jsonb not null,
  indicaciones       text,
  pdf_path           text,
  created_at         timestamptz not null default now(),
  unique (merchant_id, numero)
);

comment on table public.rx_recipes is
  'RX: los récipes emitidos. El id lo genera el cliente, para que `rx_emitir` sea idempotente. Un récipe es dato de salud: solo lo lee su clínica, por RPC.';

create index rx_recipes_lista_idx on public.rx_recipes (merchant_id, created_at desc);
create index rx_recipes_pdf_idx on public.rx_recipes (pdf_path) where pdf_path is not null;

create table public.rx_envios (
  id          uuid primary key default gen_random_uuid(),
  recipe_id   uuid not null references public.rx_recipes (id),
  merchant_id uuid not null references public.merchants (id),
  correo      text not null,
  estado      text not null default 'pendiente' check (estado in ('pendiente', 'enviado', 'fallido')),
  provider_id text,
  error       text,
  creado_por  uuid,
  created_at  timestamptz not null default now()
);

comment on table public.rx_envios is
  'RX: cada correo que se intentó mandar con un récipe. No pasa por `outbound_messages`: lo manda la Edge Function `rx-enviar`, con el PDF adjunto.';

create index rx_envios_tope_idx on public.rx_envios (merchant_id, created_at);
create index rx_envios_recipe_idx on public.rx_envios (recipe_id, created_at desc);
create index rx_envios_dia_idx on public.rx_envios (created_at);

alter table public.rx_perfiles enable row level security;
alter table public.rx_recipes  enable row level security;
alter table public.rx_envios   enable row level security;

-- Los permisos por defecto del esquema public se los dan a anon y authenticated.
revoke all on table public.rx_perfiles from public, anon, authenticated;
revoke all on table public.rx_recipes  from public, anon, authenticated;
revoke all on table public.rx_envios   from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El bucket
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rx', 'rx', false, 5242880, array['image/png', 'image/jpeg', 'application/pdf'])
on conflict (id) do nothing;

/**
 * La clínica activa de quien llama, si es su administrador, o null. Nunca lanza
 * error: la usan las políticas de `storage.objects`, que se evalúan también en
 * las consultas de los demás buckets. El orden hace que quien administre dos
 * clínicas caiga siempre en la misma.
 */
create function public.rx_clinica_activa()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select u.merchant_id
  from public.merchant_users u
  join public.merchants m on m.id = u.merchant_id
  where u.user_id = auth.uid()
    and u.is_active
    and u.role = 'gerente'
    and m.status = 'active'
  order by u.created_at, u.merchant_id
  limit 1;
$$;

/** ¿Esa ruta es el PDF de un récipe ya emitido? Ese archivo ya no se toca. */
create function public.rx_pdf_adjunto(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.rx_recipes where pdf_path = p_name);
$$;

revoke all on function public.rx_clinica_activa() from public, anon;
revoke all on function public.rx_pdf_adjunto(text) from public, anon;
grant execute on function public.rx_clinica_activa() to authenticated;
grant execute on function public.rx_pdf_adjunto(text) to authenticated;

-- Cada clínica, solo su carpeta y solo las tres subcarpetas de RX. El PDF de un
-- récipe adjuntado no se reemplaza ni se borra. La Edge Function lo baja con la
-- service_role, y solo la ruta que la base le dio.
create policy rx_archivos_select on storage.objects
  for select to authenticated
  using (bucket_id = 'rx' and (storage.foldername(name))[1] = (select public.rx_clinica_activa())::text);

create policy rx_archivos_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'rx'
    and (storage.foldername(name))[1] = (select public.rx_clinica_activa())::text
    and (storage.foldername(name))[2] in ('firma', 'logo', 'recipes')
  );

create policy rx_archivos_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'rx'
    and (storage.foldername(name))[1] = (select public.rx_clinica_activa())::text
    and not public.rx_pdf_adjunto(name)
  )
  with check (
    bucket_id = 'rx'
    and (storage.foldername(name))[1] = (select public.rx_clinica_activa())::text
    and (storage.foldername(name))[2] in ('firma', 'logo', 'recipes')
  );

create policy rx_archivos_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'rx'
    and (storage.foldername(name))[1] = (select public.rx_clinica_activa())::text
    and not public.rx_pdf_adjunto(name)
  );

-- ---------------------------------------------------------------------------
-- 3. Ayudantes internos (nadie los llama desde fuera)
-- ---------------------------------------------------------------------------

/** La clínica activa de quien llama, si es su administrador. Si no, 42501. */
create function public.rx_clinica()
returns uuid
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid := public.rx_clinica_activa();
begin
  if v_clinica is null then
    raise exception 'RX es solo para el médico titular de una clínica activa.' using errcode = '42501';
  end if;
  return v_clinica;
end;
$$;

/** Un texto de un objeto jsonb: sin espacios en los bordes, vacío = null, con tope. */
create function public.rx_texto(p_datos jsonb, p_clave text, p_etiqueta text, p_tope integer)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_texto text := nullif(btrim(p_datos ->> p_clave, E' \t\r\n'), '');
begin
  if char_length(v_texto) > p_tope then
    raise exception 'Revisa %: el máximo es de % caracteres.', p_etiqueta, p_tope using errcode = '22023';
  end if;
  return v_texto;
end;
$$;

/** La forma de `Perfil` (rx/src/modelo.ts): todas las claves, '' en vez de null. */
create function public.rx_perfil_json(p_merchant_id uuid)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'merchant_id',     m.id,
    -- Solo se cambia desde Helios. Sin titular, `merchants.name`.
    'nombre',          coalesce(public.helios_doctor_name(m.id), ''),
    'especialidad',    coalesce(nullif(p.especialidad, ''), m.specialty, ''),
    'cedula',          coalesce(nullif(p.cedula, ''), m.owner_document, ''),
    'mpps',            coalesce(nullif(p.mpps, ''), m.mpps_number, ''),
    'colegio',         coalesce(nullif(p.colegio, ''), m.college_number, ''),
    'telefono',        coalesce(nullif(p.telefono, ''), m.phone, ''),
    'correo',          coalesce(nullif(p.correo, ''), m.email, ''),
    'direccion',       coalesce(nullif(p.direccion, ''), m.address, ''),
    'ciudad',          coalesce(nullif(p.ciudad, ''), m.city, ''),
    'consultorio',     coalesce(nullif(p.consultorio, ''), m.consultorio, ''),
    'logo_helios_url', coalesce(m.logo_url, ''),
    'firma_path',      coalesce(p.firma_path, ''),
    'logo_path',       coalesce(p.logo_path, '')
  )
  from public.merchants m
  left join public.rx_perfiles p on p.merchant_id = m.id
  where m.id = p_merchant_id;
$$;

/** La forma de `Recipe` (rx/src/modelo.ts), con su último envío o null. */
create function public.rx_recipe_json(p_recipe public.rx_recipes)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id',           (p_recipe).id,
    'numero',       (p_recipe).numero,
    'fecha',        (p_recipe).fecha,
    'paciente',     jsonb_build_object(
                      'nombre',    (p_recipe).paciente_nombre,
                      'documento', coalesce((p_recipe).paciente_documento, ''),
                      'edad',      coalesce((p_recipe).paciente_edad, ''),
                      'correo',    coalesce((p_recipe).paciente_correo, '')),
    'medicamentos', (p_recipe).medicamentos,
    'indicaciones', coalesce((p_recipe).indicaciones, ''),
    'pdf_path',     coalesce((p_recipe).pdf_path, ''),
    'created_at',   (p_recipe).created_at,
    'ultimo_envio', (select jsonb_build_object('correo', e.correo, 'estado', e.estado, 'at', e.created_at)
                       from public.rx_envios e
                      where e.recipe_id = (p_recipe).id
                      order by e.created_at desc
                      limit 1)
  );
$$;

revoke all on function public.rx_clinica() from public, anon, authenticated, service_role;
revoke all on function public.rx_texto(jsonb, text, text, integer) from public, anon, authenticated, service_role;
revoke all on function public.rx_perfil_json(uuid) from public, anon, authenticated, service_role;
revoke all on function public.rx_recipe_json(public.rx_recipes) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. El perfil
-- ---------------------------------------------------------------------------

/** Los datos de `merchants` con las correcciones encima. No crea la fila. */
create function public.rx_mi_perfil()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  return public.rx_perfil_json(public.rx_clinica());
end;
$$;

/**
 * Guarda las correcciones. `p_datos`: las claves de `DatosEditables`; la que no
 * venga se queda como estaba, y `nombre` se ignora (solo se cambia desde
 * Helios). Vacío, o lo mismo que ya dice Helios, no es una corrección: se guarda
 * null, para que el día que cambie en Helios también cambie aquí (el formulario
 * manda todos los campos cada vez).
 */
create function public.rx_guardar_perfil(p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica      uuid := public.rx_clinica();
  v_especialidad text;
  v_cedula       text;
  v_mpps         text;
  v_colegio      text;
  v_telefono     text;
  v_correo       text;
  v_direccion    text;
  v_ciudad       text;
  v_consultorio  text;
begin
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then
    raise exception 'Los datos del perfil no son válidos.' using errcode = '22023';
  end if;

  v_especialidad := public.rx_texto(p_datos, 'especialidad', 'la especialidad', 120);
  v_cedula       := public.rx_texto(p_datos, 'cedula', 'la cédula', 30);
  v_mpps         := public.rx_texto(p_datos, 'mpps', 'el número MPPS', 40);
  v_colegio      := public.rx_texto(p_datos, 'colegio', 'el número del colegio', 40);
  v_telefono     := public.rx_texto(p_datos, 'telefono', 'el teléfono', 40);
  v_correo       := lower(public.rx_texto(p_datos, 'correo', 'el correo', 254));
  v_direccion    := public.rx_texto(p_datos, 'direccion', 'la dirección', 300);
  v_ciudad       := public.rx_texto(p_datos, 'ciudad', 'la ciudad', 120);
  v_consultorio  := public.rx_texto(p_datos, 'consultorio', 'el consultorio', 120);

  if v_correo is not null and not public.helios_valid_email(v_correo) then
    raise exception 'El correo no parece válido.' using errcode = '22023';
  end if;

  insert into public.rx_perfiles (merchant_id) values (v_clinica)
  on conflict (merchant_id) do nothing;

  update public.rx_perfiles p set
    especialidad = case when p_datos ? 'especialidad' then nullif(v_especialidad, m.specialty) else p.especialidad end,
    cedula       = case when p_datos ? 'cedula' then nullif(v_cedula, m.owner_document) else p.cedula end,
    mpps         = case when p_datos ? 'mpps' then nullif(v_mpps, m.mpps_number) else p.mpps end,
    colegio      = case when p_datos ? 'colegio' then nullif(v_colegio, m.college_number) else p.colegio end,
    telefono     = case when p_datos ? 'telefono' then nullif(v_telefono, m.phone) else p.telefono end,
    correo       = case when p_datos ? 'correo' then nullif(v_correo, lower(m.email)) else p.correo end,
    direccion    = case when p_datos ? 'direccion' then nullif(v_direccion, m.address) else p.direccion end,
    ciudad       = case when p_datos ? 'ciudad' then nullif(v_ciudad, m.city) else p.ciudad end,
    consultorio  = case when p_datos ? 'consultorio' then nullif(v_consultorio, m.consultorio) else p.consultorio end,
    updated_at   = now()
  from public.merchants m
  where p.merchant_id = v_clinica and m.id = v_clinica;

  return public.rx_perfil_json(v_clinica);
end;
$$;

/** Deja una imagen ya subida como la firma o el logo. `null` la quita. */
create function public.rx_guardar_imagen(p_tipo text, p_path text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid := public.rx_clinica();
  v_prefijo text;
begin
  if p_tipo is null or p_tipo not in ('firma', 'logo') then
    raise exception 'El tipo de imagen debe ser firma o logo.' using errcode = '22023';
  end if;

  v_prefijo := v_clinica::text || '/' || p_tipo || '/';
  if p_path is not null
     and (not starts_with(p_path, v_prefijo)
          or char_length(p_path) <= char_length(v_prefijo)
          or char_length(p_path) > 300
          or p_path like '%..%') then
    raise exception 'Esa ruta no es de tu clínica.' using errcode = '22023';
  end if;

  insert into public.rx_perfiles (merchant_id) values (v_clinica)
  on conflict (merchant_id) do nothing;

  update public.rx_perfiles set
    firma_path = case when p_tipo = 'firma' then p_path else firma_path end,
    logo_path  = case when p_tipo = 'logo' then p_path else logo_path end,
    updated_at = now()
  where merchant_id = v_clinica;

  return public.rx_perfil_json(v_clinica);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. El récipe
-- ---------------------------------------------------------------------------

/**
 * Emite el récipe: le da su número correlativo y la fecha de hoy en Caracas.
 * Idempotente por `p_id`: reintentar devuelve el mismo récipe sin gastar otro
 * número. El número sale con la fila de `rx_perfiles` bloqueada, así que no hay
 * carreras ni huecos; la fila existe, porque sin firma no se emite.
 */
create function public.rx_emitir(p_id uuid, p_paciente jsonb, p_medicamentos jsonb, p_indicaciones text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica      uuid := public.rx_clinica();
  v_recipe       public.rx_recipes%rowtype;
  v_firma        text;
  v_numero       integer;
  v_nombre       text;
  v_documento    text;
  v_edad         text;
  v_correo       text;
  v_indicaciones text;
  v_item         jsonb;
  v_medicamento  text;
  v_lista        jsonb := '[]'::jsonb;
begin
  if p_id is null then
    raise exception 'Falta el identificador del récipe.' using errcode = '22023';
  end if;

  select * into v_recipe from public.rx_recipes where id = p_id;
  if found then
    if v_recipe.merchant_id <> v_clinica then
      raise exception 'No se pudo emitir este récipe.' using errcode = '22023';
    end if;
    return public.rx_recipe_json(v_recipe);
  end if;

  select firma_path into v_firma from public.rx_perfiles where merchant_id = v_clinica for update;
  if v_firma is null then
    raise exception 'Sube tu firma antes de emitir el récipe.' using errcode = '22023';
  end if;

  -- Otra petición con el mismo id pudo terminar mientras se esperaba el bloqueo.
  select * into v_recipe from public.rx_recipes where id = p_id;
  if found then
    if v_recipe.merchant_id <> v_clinica then
      raise exception 'No se pudo emitir este récipe.' using errcode = '22023';
    end if;
    return public.rx_recipe_json(v_recipe);
  end if;

  if p_paciente is null or jsonb_typeof(p_paciente) <> 'object' then
    raise exception 'Faltan los datos del paciente.' using errcode = '22023';
  end if;
  v_nombre    := public.rx_texto(p_paciente, 'nombre', 'el nombre del paciente', 120);
  -- El nombre abre el correo: que no sirva para colar un enlace.
  if v_nombre ~* '(https?:|www\.|://)' then
    raise exception 'Revisa el nombre del paciente: no puede llevar un enlace.' using errcode = '22023';
  end if;
  v_documento := public.rx_texto(p_paciente, 'documento', 'el documento del paciente', 20);
  v_edad      := public.rx_texto(p_paciente, 'edad', 'la edad del paciente', 20);
  v_correo    := lower(public.rx_texto(p_paciente, 'correo', 'el correo del paciente', 254));
  if v_nombre is null then
    raise exception 'Escribe el nombre del paciente.' using errcode = '22023';
  end if;
  if v_correo is not null and not public.helios_valid_email(v_correo) then
    raise exception 'El correo del paciente no parece válido.' using errcode = '22023';
  end if;

  if p_medicamentos is null or jsonb_typeof(p_medicamentos) <> 'array' or jsonb_array_length(p_medicamentos) = 0 then
    raise exception 'Agrega al menos un medicamento.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_medicamentos) > 20 then
    raise exception 'Un récipe lleva hasta 20 medicamentos.' using errcode = '22023';
  end if;
  for v_item in select value from jsonb_array_elements(p_medicamentos) loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'Los medicamentos no son válidos.' using errcode = '22023';
    end if;
    v_medicamento := public.rx_texto(v_item, 'medicamento', 'el medicamento', 160);
    if v_medicamento is null then
      raise exception 'Cada renglón necesita el nombre del medicamento.' using errcode = '22023';
    end if;
    v_lista := v_lista || jsonb_build_array(jsonb_build_object(
      'medicamento',  v_medicamento,
      'presentacion', coalesce(public.rx_texto(v_item, 'presentacion', 'la presentación', 80), ''),
      'cantidad',     coalesce(public.rx_texto(v_item, 'cantidad', 'la cantidad', 80), ''),
      'indicacion',   coalesce(public.rx_texto(v_item, 'indicacion', 'la indicación', 500), '')
    ));
  end loop;

  v_indicaciones := public.rx_texto(jsonb_build_object('t', p_indicaciones), 't', 'las indicaciones', 2000);

  update public.rx_perfiles
     set ultimo_numero = ultimo_numero + 1, updated_at = now()
   where merchant_id = v_clinica
  returning ultimo_numero into v_numero;

  begin
    insert into public.rx_recipes
      (id, merchant_id, numero, fecha, creado_por, paciente_nombre, paciente_documento,
       paciente_edad, paciente_correo, medicamentos, indicaciones)
    values
      (p_id, v_clinica, v_numero, public.helios_business_date(now()), auth.uid(), v_nombre, v_documento,
       v_edad, v_correo, v_lista, v_indicaciones)
    returning * into v_recipe;
  exception when unique_violation then
    -- El mismo id, de otra clínica y al mismo tiempo.
    raise exception 'No se pudo emitir este récipe.' using errcode = '22023';
  end;

  return public.rx_recipe_json(v_recipe);
end;
$$;

/** Guarda la ruta del PDF ya subido: exactamente <merchant>/recipes/<id>.pdf. */
create function public.rx_adjuntar_pdf(p_id uuid, p_path text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid := public.rx_clinica();
  v_recipe  public.rx_recipes%rowtype;
begin
  select * into v_recipe from public.rx_recipes
   where id = p_id and merchant_id = v_clinica
   for update;
  if not found then
    raise exception 'No encontramos ese récipe.' using errcode = 'P0002';
  end if;

  if p_path is distinct from (v_clinica::text || '/recipes/' || p_id::text || '.pdf') then
    raise exception 'Esa ruta no es la del PDF de este récipe.' using errcode = '22023';
  end if;

  update public.rx_recipes set pdf_path = p_path where id = p_id
  returning * into v_recipe;

  return public.rx_recipe_json(v_recipe);
end;
$$;

/**
 * Los récipes de su clínica, del más nuevo al más viejo. Busca sin distinguir
 * mayúsculas en el nombre y el documento del paciente, y por número exacto
 * (con o sin ceros delante).
 */
create function public.rx_listar(p_busqueda text default null, p_limite integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_clinica uuid := public.rx_clinica();
  v_q       text := nullif(btrim(coalesce(p_busqueda, '')), '');
  v_like    text;
  v_numero  integer;
  v_limite  integer := least(greatest(coalesce(p_limite, 50), 1), 200);
begin
  if v_q is not null then
    v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    if v_q ~ '^[0-9]{1,9}$' then
      v_numero := v_q::integer;
    end if;
  end if;

  return coalesce((
    select jsonb_agg(public.rx_recipe_json(x.fila) order by x.created_at desc, x.numero desc)
    from (
      select r as fila, r.created_at, r.numero
      from public.rx_recipes r
      where r.merchant_id = v_clinica
        and (v_q is null
             or r.paciente_nombre ilike v_like
             or r.paciente_documento ilike v_like
             or r.numero = v_numero)
      order by r.created_at desc, r.numero desc
      limit v_limite
    ) x
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. El envío
-- ---------------------------------------------------------------------------

/**
 * Valida, aplica el tope diario y anota el envío como `pendiente`. La llama
 * `rx-enviar` con el JWT del médico: así es la base la que decide si puede. El
 * tope cuenta también los fallidos, y se comprueba con la fila de `rx_perfiles`
 * bloqueada para que dos envíos a la vez no se lo salten.
 */
create function public.rx_preparar_envio(p_id uuid, p_correo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_tope        constant integer := 60;
  c_tope_correo constant integer := 5;
  c_tope_global constant integer := 500;
  v_clinica     uuid := public.rx_clinica();
  v_correo      text := lower(btrim(coalesce(p_correo, '')));
  v_recipe      public.rx_recipes%rowtype;
  v_desde       timestamptz;
  v_envio       uuid;
  v_doctor      text;
  v_doctor_mail text;
begin
  select * into v_recipe from public.rx_recipes
   where id = p_id and merchant_id = v_clinica;
  if not found then
    raise exception 'No encontramos ese récipe.' using errcode = 'P0002';
  end if;

  if v_recipe.pdf_path is null then
    raise exception 'Este récipe todavía no tiene su PDF.' using errcode = '22023';
  end if;

  if not public.helios_valid_email(v_correo) then
    raise exception 'El correo no parece válido.' using errcode = '22023';
  end if;

  perform 1 from public.rx_perfiles where merchant_id = v_clinica for update;

  v_desde := public.helios_business_date(now())::timestamp at time zone 'America/Caracas';
  if (select count(*) from public.rx_envios
       where merchant_id = v_clinica and created_at >= v_desde) >= c_tope then
    raise exception 'Llegaste al tope de envíos de hoy.' using errcode = '54000';
  end if;

  -- RX comparte la cuenta de Resend con los comprobantes de pago: un abuso no
  -- puede dañar la entrega de esos correos.
  if (select count(*) from public.rx_envios
       where merchant_id = v_clinica and correo = v_correo and created_at >= v_desde) >= c_tope_correo then
    raise exception 'Ya enviaste varios correos a esa dirección hoy. Intenta mañana.' using errcode = '54000';
  end if;

  if (select count(*) from public.rx_envios where created_at >= v_desde) >= c_tope_global then
    raise exception 'Hoy no se pueden enviar más correos. Intenta mañana.' using errcode = '54000';
  end if;

  insert into public.rx_envios (recipe_id, merchant_id, correo, estado, creado_por)
  values (p_id, v_clinica, v_correo, 'pendiente', auth.uid())
  returning id into v_envio;

  select public.helios_doctor_name(m.id),
         coalesce(nullif(p.correo, ''), nullif(btrim(m.email), ''), '')
    into v_doctor, v_doctor_mail
  from public.merchants m
  left join public.rx_perfiles p on p.merchant_id = m.id
  where m.id = v_clinica;

  return jsonb_build_object(
    'envio_id',        v_envio,
    'pdf_path',        v_recipe.pdf_path,
    'numero',          v_recipe.numero,
    'paciente_nombre', v_recipe.paciente_nombre,
    'doctor_nombre',   v_doctor,
    'doctor_correo',   v_doctor_mail,
    'correo',          v_correo
  );
end;
$$;

/** Lo que pasó con el envío. Solo la service_role (`rx-enviar`). */
create function public.rx_resultado_envio(p_envio_id uuid, p_estado text, p_provider_id text, p_error text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_estado is null or p_estado not in ('enviado', 'fallido') then
    raise exception 'El estado del envío debe ser enviado o fallido.' using errcode = '22023';
  end if;

  update public.rx_envios
     set estado = p_estado,
         provider_id = left(p_provider_id, 200),
         error = left(p_error, 500)
   where id = p_envio_id;
  if not found then
    raise exception 'No encontramos ese envío.' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Quién las llama
-- ---------------------------------------------------------------------------

-- Los permisos por defecto de Supabase le dan execute a anon de forma explícita:
-- no basta con quitárselo a public.
revoke all on function public.rx_mi_perfil() from public, anon;
revoke all on function public.rx_guardar_perfil(jsonb) from public, anon;
revoke all on function public.rx_guardar_imagen(text, text) from public, anon;
revoke all on function public.rx_emitir(uuid, jsonb, jsonb, text) from public, anon;
revoke all on function public.rx_adjuntar_pdf(uuid, text) from public, anon;
revoke all on function public.rx_listar(text, integer) from public, anon;
revoke all on function public.rx_preparar_envio(uuid, text) from public, anon;
revoke all on function public.rx_resultado_envio(uuid, text, text, text) from public, anon, authenticated;

grant execute on function public.rx_mi_perfil() to authenticated;
grant execute on function public.rx_guardar_perfil(jsonb) to authenticated;
grant execute on function public.rx_guardar_imagen(text, text) to authenticated;
grant execute on function public.rx_emitir(uuid, jsonb, jsonb, text) to authenticated;
grant execute on function public.rx_adjuntar_pdf(uuid, text) to authenticated;
grant execute on function public.rx_listar(text, integer) to authenticated;
grant execute on function public.rx_preparar_envio(uuid, text) to authenticated;
grant execute on function public.rx_resultado_envio(uuid, text, text, text) to service_role;
