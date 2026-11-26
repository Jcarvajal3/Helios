-- ============================================================================
-- Helios — Helios Lab: tablas, ayudas, bucket y lector (docs/09-HELIOS-LAB.md)
--
-- Vertical nueva: el médico toma la muestra, el paciente paga por Pago Móvil a
-- Helios, un driver la lleva al laboratorio y Helios reenvía el resultado. NO
-- es pago en cuotas: no toca `charges`, `installments`, `settlements` ni el
-- libro contable.
--
--  1. Tablas `lab_*` (RLS activa, sin políticas: solo se llega por RPC).
--  2. Ayudas: `helios_puede_manejar`, `helios_lab_habilitado`,
--     `helios_lab_rol`, `helios_lab_tasa_hoy`, existencias de kits.
--  3. Bucket privado `lab-comprobantes` y sus políticas.
--  4. El lector: `lector_lab_tomar` / `lector_lab_leido` / `lector_lab_fallo` y
--     `helios_lector_despertar` con la cuarta cola.
--
-- Las RPC van en 20261126120200 (médico), 20261126120300 (equipo) y
-- 20261126120400 (ruta del driver).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------

create table public.lab_ajustes (
  id               boolean primary key default true check (id),
  modo             text not null default 'apagado' check (modo in ('apagado', 'prueba', 'todos')),
  cargo_helios_usd numeric(18,4) not null default 15 check (cargo_helios_usd >= 0),
  updated_at       timestamptz not null default now(),
  updated_by       uuid references auth.users (id)
);

insert into public.lab_ajustes (id, modo, cargo_helios_usd) values (true, 'apagado', 15);

create table public.lab_kits (
  tipo              text primary key check (tipo in ('sangre', 'orina', 'biopsia')),
  nombre            text not null,
  minimo_helios     integer not null default 0 check (minimo_helios >= 0),
  minimo_por_medico integer not null default 0 check (minimo_por_medico >= 0)
);

insert into public.lab_kits (tipo, nombre, minimo_helios, minimo_por_medico) values
  ('sangre',  'Kit de sangre',  20, 5),
  ('orina',   'Kit de orina',   20, 5),
  ('biopsia', 'Kit de biopsia', 10, 2);

create table public.lab_laboratorios (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null check (btrim(nombre) <> ''),
  correo     text,
  telefono   text,
  direccion  text,
  activo     boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.lab_examenes (
  id          uuid primary key default gen_random_uuid(),
  codigo      text not null unique check (btrim(codigo) <> ''),
  nombre      text not null check (btrim(nombre) <> ''),
  kit_tipo    text not null references public.lab_kits (tipo),
  indicaciones text,
  activo      boolean not null default true
);

create table public.lab_precios (
  laboratorio_id uuid not null references public.lab_laboratorios (id),
  examen_id      uuid not null references public.lab_examenes (id),
  base_usd       numeric(18,4) not null check (base_usd > 0),
  activo         boolean not null default true,
  updated_at     timestamptz not null default now(),
  primary key (laboratorio_id, examen_id)
);

create table public.lab_comisiones (
  merchant_id  uuid not null references public.merchants (id),
  examen_id    uuid not null references public.lab_examenes (id),
  comision_usd numeric(18,4) not null check (comision_usd >= 0),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references auth.users (id),
  primary key (merchant_id, examen_id)
);

create table public.lab_rutas (
  id         uuid primary key default gen_random_uuid(),
  fecha      date not null unique,
  estado     text not null default 'borrador' check (estado in ('borrador', 'en_curso', 'cerrada')),
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

create table public.lab_paradas (
  id              uuid primary key default gen_random_uuid(),
  ruta_id         uuid not null references public.lab_rutas (id) on delete cascade,
  orden           integer not null,
  tipo            text not null check (tipo in ('consultorio', 'laboratorio')),
  merchant_id     uuid references public.merchants (id),
  laboratorio_id  uuid references public.lab_laboratorios (id),
  estado          text not null default 'pendiente' check (estado in ('pendiente', 'completada', 'saltada')),
  completada_at   timestamptz,
  completada_por  uuid references auth.users (id),
  nota            text,
  check ((merchant_id is not null) <> (laboratorio_id is not null)),
  check ((tipo = 'consultorio') = (merchant_id is not null))
);

create index lab_paradas_ruta_idx on public.lab_paradas (ruta_id, orden);

create table public.lab_kit_pedidos (
  id          uuid primary key default gen_random_uuid(),
  merchant_id uuid not null references public.merchants (id),
  kit_tipo    text not null references public.lab_kits (tipo),
  cantidad    integer not null check (cantidad > 0),
  nota        text,
  estado      text not null default 'pendiente' check (estado in ('pendiente', 'en_ruta', 'entregado', 'cancelado')),
  parada_id   uuid references public.lab_paradas (id) on delete set null,
  pedido_por  uuid references auth.users (id),
  created_at  timestamptz not null default now(),
  atendido_at timestamptz
);

create index lab_kit_pedidos_merchant_idx on public.lab_kit_pedidos (merchant_id, estado);

create table public.lab_parada_kits (
  parada_id uuid not null references public.lab_paradas (id) on delete cascade,
  kit_tipo  text not null references public.lab_kits (tipo),
  cantidad  integer not null check (cantidad > 0),
  pedido_id uuid references public.lab_kit_pedidos (id) on delete set null,
  primary key (parada_id, kit_tipo)
);

create sequence public.lab_muestra_codigo_seq;

create table public.lab_muestras (
  id                     uuid primary key default gen_random_uuid(),
  codigo                 text not null unique
                           default ('L-' || lpad(nextval('public.lab_muestra_codigo_seq')::text, 6, '0')),
  merchant_id            uuid not null references public.merchants (id),
  branch_id              uuid references public.merchant_branches (id),
  registrada_por         uuid not null references auth.users (id),
  paciente_nombre        text not null check (btrim(paciente_nombre) <> ''),
  paciente_whatsapp      text not null,
  paciente_correo        text,
  examen_id              uuid not null references public.lab_examenes (id),
  laboratorio_id         uuid not null references public.lab_laboratorios (id),
  kit_tipo               text not null references public.lab_kits (tipo),
  base_usd               numeric(18,4) not null check (base_usd > 0),
  cargo_helios_usd       numeric(18,4) not null check (cargo_helios_usd >= 0),
  comision_usd           numeric(18,4) not null check (comision_usd >= 0),
  precio_usd             numeric(18,4) not null,
  tasa_bcv               numeric(18,6) not null check (tasa_bcv > 0),
  monto_ves              numeric(18,2) not null check (monto_ves > 0),
  pago_referencia        text not null,
  pago_banco             text,
  comprobante_path       text,
  pago_estado            text not null default 'para_revisar'
                           check (pago_estado in ('por_leer', 'cuadra', 'para_revisar', 'verificado', 'rechazado')),
  pago_nota              text,
  pago_revisado_por      uuid references auth.users (id),
  pago_revisado_at       timestamptz,
  estado                 text not null default 'lista_para_retirar'
                           check (estado in ('lista_para_retirar', 'retirada', 'en_laboratorio',
                                             'resultado_recibido', 'resultado_entregado', 'anulada')),
  parada_retiro_id       uuid references public.lab_paradas (id) on delete set null,
  parada_entrega_id      uuid references public.lab_paradas (id) on delete set null,
  retirada_at            timestamptz,
  en_laboratorio_at      timestamptz,
  resultado_recibido_at  timestamptz,
  resultado_entregado_at timestamptz,
  resultado_canal        text check (resultado_canal in ('correo', 'whatsapp')),
  anulada_at             timestamptz,
  anulada_motivo         text,
  comision_pagada_at     timestamptz,
  comision_pago_ref      text,
  base_pagada_at         timestamptz,
  base_pago_ref          text,
  idempotency_key        text not null unique,
  created_at             timestamptz not null default now(),
  check (precio_usd = base_usd + cargo_helios_usd + comision_usd)
);

create index lab_muestras_merchant_idx on public.lab_muestras (merchant_id, created_at desc);
create index lab_muestras_estado_idx   on public.lab_muestras (estado, pago_estado);
create index lab_muestras_parada_retiro_idx  on public.lab_muestras (parada_retiro_id)  where parada_retiro_id is not null;
create index lab_muestras_parada_entrega_idx on public.lab_muestras (parada_entrega_id) where parada_entrega_id is not null;

-- Una referencia no paga dos muestras (mientras la muestra no esté anulada).
create unique index lab_muestras_referencia_uidx
  on public.lab_muestras ((regexp_replace(pago_referencia, '\D', '', 'g')))
  where estado <> 'anulada';

create table public.lab_comprobante_lecturas (
  id              uuid primary key default gen_random_uuid(),
  muestra_id      uuid not null references public.lab_muestras (id) on delete cascade,
  storage_path    text not null,
  mime            text not null default 'image/jpeg',
  status          text not null default 'pendiente' check (status in ('pendiente', 'leyendo', 'leida', 'fallida')),
  attempts        integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lectura         jsonb,
  cuadra          boolean,
  error           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index lab_comprobante_lecturas_cola_idx
  on public.lab_comprobante_lecturas (next_attempt_at) where status = 'pendiente';
create index lab_comprobante_lecturas_muestra_idx on public.lab_comprobante_lecturas (muestra_id);

create table public.lab_kit_movimientos (
  id              bigint generated always as identity primary key,
  tipo            text not null check (tipo in ('entrada', 'entrega', 'uso', 'ajuste')),
  kit_tipo        text not null references public.lab_kits (tipo),
  cantidad        integer not null check (cantidad <> 0),
  merchant_id     uuid references public.merchants (id),
  muestra_id      uuid references public.lab_muestras (id),
  parada_id       uuid references public.lab_paradas (id),
  nota            text,
  actor           uuid references auth.users (id),
  idempotency_key text not null unique,
  created_at      timestamptz not null default now(),
  check (tipo = 'ajuste' or cantidad > 0),
  check (tipo not in ('entrega', 'uso') or merchant_id is not null),
  check (tipo <> 'entrada' or merchant_id is null)
);

create index lab_kit_movimientos_merchant_idx on public.lab_kit_movimientos (merchant_id, kit_tipo);

-- Append-only, como el libro y la bitácora.
create or replace function public.lab_kit_movimientos_inmutable()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  raise exception 'Los movimientos de kits no se modifican ni se borran' using errcode = '55000';
end;
$$;

create trigger lab_kit_movimientos_inmutable
  before update or delete on public.lab_kit_movimientos
  for each row execute function public.lab_kit_movimientos_inmutable();

alter table public.lab_ajustes             enable row level security;
alter table public.lab_kits                enable row level security;
alter table public.lab_laboratorios        enable row level security;
alter table public.lab_examenes            enable row level security;
alter table public.lab_precios             enable row level security;
alter table public.lab_comisiones          enable row level security;
alter table public.lab_muestras            enable row level security;
alter table public.lab_comprobante_lecturas enable row level security;
alter table public.lab_kit_movimientos     enable row level security;
alter table public.lab_kit_pedidos         enable row level security;
alter table public.lab_rutas               enable row level security;
alter table public.lab_paradas             enable row level security;
alter table public.lab_parada_kits         enable row level security;

revoke all on public.lab_ajustes, public.lab_kits, public.lab_laboratorios, public.lab_examenes,
              public.lab_precios, public.lab_comisiones, public.lab_muestras,
              public.lab_comprobante_lecturas, public.lab_kit_movimientos, public.lab_kit_pedidos,
              public.lab_rutas, public.lab_paradas, public.lab_parada_kits
  from anon, authenticated;
revoke all on sequence public.lab_muestra_codigo_seq from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Ayudas
-- ---------------------------------------------------------------------------

/** Quién puede armar y completar la ruta: super admin, operador y driver. */
create or replace function public.helios_puede_manejar()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_es_del_equipo(array['super_admin', 'operador', 'driver']::public.platform_role[]);
$$;

comment on function public.helios_puede_manejar() is
  'Helios Lab, la ruta: super admin, operador o el rol driver, con el segundo factor si se exige.';

revoke all on function public.helios_puede_manejar() from public, anon;
grant execute on function public.helios_puede_manejar() to authenticated;

/** ¿Lab está habilitado para esa clínica? `todos`, o `prueba` y la clínica es de prueba. */
create or replace function public.helios_lab_habilitado(p_merchant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select a.modo = 'todos'
        or (a.modo = 'prueba' and coalesce((select m.is_test from public.merchants m where m.id = p_merchant_id), false))
    from public.lab_ajustes a
    where a.id
  ), false);
$$;

revoke all on function public.helios_lab_habilitado(uuid) from public, anon;
grant execute on function public.helios_lab_habilitado(uuid) to authenticated;

/** El rol de quien llama en esa clínica, con Lab habilitado; si no, 42501. */
create or replace function public.helios_lab_rol(p_merchant_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_rol text := public.helios_staff_role_in(p_merchant_id)::text;
begin
  if v_rol is null or not public.helios_lab_habilitado(p_merchant_id) then
    raise exception 'Helios Lab no está disponible para esta clínica' using errcode = '42501';
  end if;
  return v_rol;
end;
$$;

revoke all on function public.helios_lab_rol(uuid) from public, anon, authenticated;

/** La tasa BCV de hoy (Bs por dólar), o null. */
create or replace function public.helios_lab_tasa_hoy()
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.helios_fx_rate('USD', public.helios_business_date(now()));
$$;

revoke all on function public.helios_lab_tasa_hoy() from public, anon, authenticated;

/** El equipo (operación): super admin u operador. Si no, 42501. */
create or replace function public.helios_lab_assert_equipo()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;
  return auth.uid();
end;
$$;

revoke all on function public.helios_lab_assert_equipo() from public, anon, authenticated;

/** Existencias de Helios de un kit: entradas + ajustes sin médico − entregas. */
create or replace function public.helios_lab_stock_helios(p_kit text)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(case
           when tipo = 'entrada' then cantidad
           when tipo = 'ajuste' and merchant_id is null then cantidad
           when tipo = 'entrega' then -cantidad
           else 0 end), 0)::integer
  from public.lab_kit_movimientos
  where kit_tipo = p_kit;
$$;

/** Existencias de un médico: entregas − usos + ajustes con ese médico. Puede ser negativa. */
create or replace function public.helios_lab_stock_medico(p_merchant_id uuid, p_kit text)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(case
           when tipo = 'entrega' then cantidad
           when tipo = 'uso' then -cantidad
           when tipo = 'ajuste' then cantidad
           else 0 end), 0)::integer
  from public.lab_kit_movimientos
  where merchant_id = p_merchant_id and kit_tipo = p_kit;
$$;

revoke all on function public.helios_lab_stock_helios(text) from public, anon, authenticated;
revoke all on function public.helios_lab_stock_medico(uuid, text) from public, anon, authenticated;

/** Lo que dice un monto en texto («5.442,41», «1250.50») como número, o null. */
create or replace function public.helios_lab_monto_de_texto(p_texto text)
returns numeric
language plpgsql
immutable
set search_path = pg_catalog, pg_temp
as $$
declare
  v_s      text := regexp_replace(coalesce(p_texto, ''), '[^0-9.,]', '', 'g');
  v_m      text[];
  v_entero text;
  v_dec    text;
  v_n      numeric;
begin
  -- Igual que `leerMontoBs` de logica.ts: el último separador seguido de 1 o 2
  -- cifras es el decimal; los demás son de miles («5.442,41», «5,442.41», «1.250»).
  if v_s !~ '[0-9]' then
    return null;
  end if;
  v_m := regexp_match(v_s, '^(.*?)[.,]([0-9]{1,2})$');
  if v_m is not null then
    v_entero := regexp_replace(v_m[1], '[.,]', '', 'g');
    v_dec := rpad(v_m[2], 2, '0');
  else
    v_entero := regexp_replace(v_s, '[.,]', '', 'g');
    v_dec := '00';
  end if;
  v_n := (coalesce(nullif(v_entero, ''), '0') || '.' || v_dec)::numeric;
  if v_n <= 0 then
    return null;
  end if;
  return round(v_n, 2);
exception when others then
  return null;
end;
$$;

revoke all on function public.helios_lab_monto_de_texto(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Bucket privado de capturas
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lab-comprobantes', 'lab-comprobantes', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

drop policy if exists lab_comprobantes_personal_insert on storage.objects;
drop policy if exists lab_comprobantes_select on storage.objects;

-- Ruta `<merchant_id>/<uuid>.<ext>`: personal activo de esa clínica, con Lab habilitado.
create policy lab_comprobantes_personal_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'lab-comprobantes'
    and exists (
      select 1
      from public.merchant_users mu
      where mu.user_id = (select auth.uid())
        and mu.is_active
        and mu.role in ('gerente', 'cajero')
        and mu.merchant_id::text = (storage.foldername(name))[1]
        and public.helios_lab_habilitado(mu.merchant_id)
    )
  );

create policy lab_comprobantes_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'lab-comprobantes'
    and (
      (select public.is_platform_admin())
      or exists (
        select 1
        from public.merchant_users mu
        where mu.user_id = (select auth.uid())
          and mu.is_active
          and mu.role in ('gerente', 'cajero')
          and mu.merchant_id::text = (storage.foldername(name))[1]
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 4. El lector
-- ---------------------------------------------------------------------------

/** Despierta al lector (igual que 20261104120000, con la cola de Lab). */
create or replace function public.helios_lector_despertar()
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_url   text;
  v_clave text;
begin
  if not exists (
    select 1 from public.payment_receipt_reads
    where status = 'pendiente'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
  ) and not exists (
    select 1 from public.patient_id_photos
    where status = 'pendiente'
      and (taken_at is null or taken_at < now() - interval '2 minutes')
  ) and not exists (
    select 1 from public.patient_id_photo_removals
    where taken_at is null or taken_at < now() - interval '2 minutes'
  ) and not exists (
    select 1 from public.lab_comprobante_lecturas
    where status = 'pendiente' and next_attempt_at <= now()
  ) then
    return false;
  end if;

  v_url   := public.helios_vault_secret('lector_url');
  v_clave := public.helios_vault_secret('lector_clave');
  if v_url is null or v_clave is null then
    return false;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '3000');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '5000');
    perform extensions.http((
      'POST', v_url,
      array[extensions.http_header('x-helios-clave', v_clave)],
      'application/json', '{}'
    )::extensions.http_request);
  exception when others then
    raise warning 'lector: no se pudo despertar: %', sqlerrm;
    return false;
  end;
  return true;
end;
$$;

/** Lo que el lector toma: la siguiente tanda de capturas de Lab por leer. */
create or replace function public.lector_lab_tomar(p_limit integer default 3)
returns table (id uuid, muestra_id uuid, storage_path text, mime text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_id uuid;
begin
  -- Una que se quedó «leyendo» 10 minutos cuenta como fallo.
  for v_id in
    select l.id from public.lab_comprobante_lecturas l
    where l.status = 'leyendo' and l.updated_at < now() - interval '10 minutes'
    for update skip locked
  loop
    perform public.lector_lab_fallo(v_id, 'El lector no respondió en 10 minutos');
  end loop;

  return query
  with tomadas as (
    select l.id from public.lab_comprobante_lecturas l
    where l.status = 'pendiente' and l.next_attempt_at <= now()
    order by l.created_at
    limit greatest(1, least(coalesce(p_limit, 3), 10))
    for update skip locked
  )
  update public.lab_comprobante_lecturas l
     set status = 'leyendo', attempts = l.attempts + 1, updated_at = now()
    from tomadas t
   where l.id = t.id
  returning l.id, l.muestra_id, l.storage_path, l.mime;
end;
$$;

/**
 * Algo falló: tres intentos, dos minutos entre ellos. Después `fallida` y el
 * pago de la muestra a `para_revisar`.
 */
create or replace function public.lector_lab_fallo(p_id uuid, p_error text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_l public.lab_comprobante_lecturas%rowtype;
begin
  select * into v_l from public.lab_comprobante_lecturas where id = p_id for update;
  if not found or v_l.status <> 'leyendo' then
    return v_l.status;
  end if;

  if v_l.attempts < 3 then
    update public.lab_comprobante_lecturas
       set status = 'pendiente', error = left(p_error, 1000),
           next_attempt_at = now() + interval '2 minutes', updated_at = now()
     where id = v_l.id;
    return 'pendiente';
  end if;

  update public.lab_comprobante_lecturas
     set status = 'fallida', error = left(p_error, 1000), updated_at = now()
   where id = v_l.id;

  update public.lab_muestras
     set pago_estado = 'para_revisar',
         pago_nota = coalesce(pago_nota, 'No se pudo leer la captura')
   where id = v_l.muestra_id and pago_estado = 'por_leer';

  return 'fallida';
end;
$$;

/**
 * Lo que leyó el modelo, TAL CUAL (el `ESQUEMA` de logica.ts: es_comprobante,
 * estado, referencia, monto_texto…). La base normaliza (cifras de la
 * referencia, monto en bolívares) y decide: `cuadra` si es un comprobante
 * exitoso, el monto cuadra con `monto_ves` (`helios_monto_cuadra`) y la
 * referencia leída coincide con la anotada o termina igual.
 */
create or replace function public.lector_lab_leido(p_id uuid, p_lectura jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_l      public.lab_comprobante_lecturas%rowtype;
  v_m      public.lab_muestras%rowtype;
  v_ref    text := regexp_replace(coalesce(p_lectura ->> 'referencia', ''), '\D', '', 'g');
  v_mia    text;
  v_monto  numeric := public.helios_lab_monto_de_texto(p_lectura ->> 'monto_texto');
  v_ref_ok boolean;
  v_monto_ok boolean;
  v_cuadra boolean;
begin
  select * into v_l from public.lab_comprobante_lecturas where id = p_id for update;
  if not found then
    raise exception 'No existe esa lectura' using errcode = 'P0002';
  end if;
  if v_l.status <> 'leyendo' then
    return jsonb_build_object('ok', false, 'status', v_l.status);
  end if;

  select * into v_m from public.lab_muestras where id = v_l.muestra_id for update;
  v_mia := regexp_replace(coalesce(v_m.pago_referencia, ''), '\D', '', 'g');

  v_ref_ok := length(v_ref) >= 4 and length(v_mia) >= 4
              and (v_ref = v_mia or right(v_ref, length(v_mia)) = v_mia or right(v_mia, length(v_ref)) = v_ref);
  v_monto_ok := v_monto is not null and v_monto > 0 and public.helios_monto_cuadra(v_monto, v_m.monto_ves);
  v_cuadra := coalesce((p_lectura ->> 'es_comprobante')::boolean, false)
              and coalesce(p_lectura ->> 'estado', '') = 'exitosa'
              and v_ref_ok and v_monto_ok;

  update public.lab_comprobante_lecturas
     set status = 'leida', lectura = p_lectura, cuadra = v_cuadra, error = null, updated_at = now()
   where id = v_l.id;

  update public.lab_muestras
     set pago_estado = case when v_cuadra then 'cuadra' else 'para_revisar' end,
         pago_nota = case when v_cuadra then pago_nota
                          else coalesce(pago_nota, 'La captura no cuadra con el monto o la referencia') end
   where id = v_m.id and pago_estado = 'por_leer';

  return jsonb_build_object('ok', true, 'status', 'leida', 'cuadra', v_cuadra,
                            'pago_estado', case when v_cuadra then 'cuadra' else 'para_revisar' end,
                            'monto_leido', v_monto, 'referencia_leida', nullif(v_ref, ''));
end;
$$;

revoke all on function public.lector_lab_tomar(integer) from public, anon, authenticated;
revoke all on function public.lector_lab_fallo(uuid, text) from public, anon, authenticated;
revoke all on function public.lector_lab_leido(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.lector_lab_tomar(integer) to service_role;
grant execute on function public.lector_lab_fallo(uuid, text) to service_role;
grant execute on function public.lector_lab_leido(uuid, jsonb) to service_role;
