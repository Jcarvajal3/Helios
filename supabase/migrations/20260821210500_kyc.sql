-- ============================================================================
-- Ronda — Verificación de identidad (KYC)
--
-- El esquema `kyc` es inaccesible desde el cliente: no lleva políticas RLS de
-- lectura. La app consulta el estado por RPC, que devuelve solo lo mínimo.
--
-- Guardamos embeddings faciales (vectores), no las caras. Un embedding no es
-- reversible a una imagen, y con pgvector nos permite detectar a la misma
-- persona intentando registrarse con dos cédulas distintas — el fraude número
-- uno en BNPL.
-- ============================================================================

create schema if not exists kyc;
create extension if not exists vector with schema extensions;

revoke all on schema kyc from public, anon, authenticated;

-- ---------------------------------------------------------------------------

create type kyc.verification_status as enum (
  'pending',        -- creada, esperando capturas
  'processing',     -- el servicio de KYC está evaluando
  'approved',
  'rejected',
  'manual_review'   -- zona gris: la revisa una persona en el super admin
);

create type kyc.rejection_reason as enum (
  'document_unreadable',
  'face_mismatch',
  'liveness_failed',
  'underage',
  'duplicate_identity',
  'registry_mismatch',
  'document_tampered',
  'manual_rejection'
);

create table if not exists kyc.verifications (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users(id) on delete cascade,
  status             kyc.verification_status not null default 'pending',

  -- Datos extraídos por OCR de la cédula.
  extracted_name     text,
  extracted_document text,
  extracted_birth    date,
  ocr_confidence     numeric(5,4),

  -- Señales de la evaluación. Cada una alimenta el motor de decisión.
  face_match_score   numeric(5,4),   -- similitud coseno ArcFace
  liveness_score     numeric(5,4),
  registry_matched   boolean,        -- cruce con el registro oficial (CNE)

  rejection_reason   kyc.rejection_reason,
  rejection_detail   text,

  -- Referencias en Storage (bucket privado). Se borran según la política de
  -- retención; el embedding sobrevive para la detección de duplicados.
  document_path      text,
  selfie_path        text,

  reviewed_by        uuid references auth.users(id),
  reviewed_at        timestamptz,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists verifications_user_idx on kyc.verifications (user_id);
create index if not exists verifications_status_idx on kyc.verifications (status)
  where status in ('manual_review', 'processing');

alter table kyc.verifications enable row level security;
-- Sin políticas a propósito: ni siquiera el dueño lee su fila directamente.

-- ---------------------------------------------------------------------------
-- Embeddings faciales — detección de identidades duplicadas
-- ---------------------------------------------------------------------------

create table if not exists kyc.face_embeddings (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  verification_id uuid not null references kyc.verifications(id) on delete cascade,
  -- ArcFace (buffalo_l) produce 512 dimensiones.
  embedding       extensions.vector(512) not null,
  created_at      timestamptz not null default now()
);

create index if not exists face_embeddings_user_idx on kyc.face_embeddings (user_id);

-- Índice de similitud coseno para la búsqueda de duplicados.
create index if not exists face_embeddings_vector_idx
  on kyc.face_embeddings
  using hnsw (embedding extensions.vector_cosine_ops);

alter table kyc.face_embeddings enable row level security;

-- ---------------------------------------------------------------------------
-- Bitácora — toda decisión de KYC queda registrada
-- ---------------------------------------------------------------------------

create table if not exists kyc.decision_log (
  id              uuid primary key default gen_random_uuid(),
  verification_id uuid not null references kyc.verifications(id) on delete cascade,
  from_status     kyc.verification_status,
  to_status       kyc.verification_status not null,
  actor           text not null,   -- 'system' o el uuid del revisor
  signals         jsonb,           -- las señales que sustentaron la decisión
  created_at      timestamptz not null default now()
);

create index if not exists decision_log_verification_idx
  on kyc.decision_log (verification_id);

alter table kyc.decision_log enable row level security;

-- ---------------------------------------------------------------------------
-- Superficie para la app
-- ---------------------------------------------------------------------------
-- La app solo necesita saber en qué punto está y, si fue rechazada, por qué.
-- No debe ver puntajes: exponerlos le daría a un atacante una señal para
-- calibrar sus intentos.

create or replace function public.my_kyc_status()
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
declare
  v_user uuid := auth.uid();
  v_row  kyc.verifications%rowtype;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_row
  from kyc.verifications
  where user_id = v_user
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('status', 'none');
  end if;

  return jsonb_build_object(
    'status', v_row.status,
    'rejection_reason', v_row.rejection_reason,
    'full_name', v_row.extracted_name,
    'document_number', v_row.extracted_document,
    'birth_date', v_row.extracted_birth,
    'created_at', v_row.created_at
  );
end;
$$;

grant execute on function public.my_kyc_status() to authenticated;

-- Crea una verificación nueva para el usuario. Idempotente: si ya hay una en
-- curso la reutiliza, para que reintentar la captura no genere filas basura.
create or replace function public.start_kyc_verification()
returns uuid
language plpgsql
security definer
set search_path = public, kyc, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- Una identidad ya aprobada no vuelve a pasar por KYC.
  if exists (
    select 1 from kyc.verifications
    where user_id = v_user and status = 'approved'
  ) then
    raise exception 'Tu identidad ya está verificada' using errcode = '23505';
  end if;

  select id into v_id
  from kyc.verifications
  where user_id = v_user and status in ('pending', 'processing')
  order by created_at desc
  limit 1;

  if v_id is not null then
    return v_id;
  end if;

  insert into kyc.verifications (user_id, status)
  values (v_user, 'pending')
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.start_kyc_verification() to authenticated;

drop trigger if exists verifications_touch_updated_at on kyc.verifications;
create trigger verifications_touch_updated_at
  before update on kyc.verifications
  for each row execute function public.touch_updated_at();
