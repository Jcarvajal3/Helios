-- ============================================================================
-- Ronda — La identidad, dentro de la ficha; y las cuentas relacionadas
--
-- ---------------------------------------------------------------------------
-- 1. Lo que dijo Didit vivía solo en la cola
-- ---------------------------------------------------------------------------
-- El cotejo facial, la vivacidad y las banderas se veían al revisar una
-- verificación y desaparecían al resolverla. Seis meses después, cuando alguien
-- pregunta por qué se aprobó esa cuenta, la ficha solo sabe decir «aprobada».
--
-- Esta función devuelve lo mismo que la cola pero para **una persona**, con su
-- expediente más reciente y con quién lo resolvió, cuándo y con qué motivo. El
-- veredicto se lee igual en los dos sitios porque sale del mismo sitio: el
-- último renglón del registro de decisiones que trae señales.
--
-- ---------------------------------------------------------------------------
-- 2. Cuentas relacionadas
-- ---------------------------------------------------------------------------
-- Las banderas dicen «mismo dispositivo que otra sesión» y ahí se acaban: no
-- se puede saber cuál es la otra cuenta. Y esa es la herramienta contra el
-- fraude de cuentas múltiples — alguien que se queda debiendo, lo expulsan, y
-- vuelve con otro número desde el mismo teléfono.
--
-- Se cruzan tres cosas, y cada una pesa distinto:
--
--   MISMO DISPOSITIVO  `user_devices.device_hash`. Es la señal fuerte: dos
--                      cuentas en el mismo teléfono casi nunca son casualidad.
--   MISMA CÉDULA       el documento extraído por el proveedor. Si coincide con
--                      el de otra cuenta, es la misma persona registrada dos
--                      veces, sin más.
--   MISMO NOMBRE       solo cuando además comparte algo: dos «José García»
--                      sueltos no son nada y llenarían la lista de ruido.
--
-- La marca interna del relacionado viaja con cada fila: es lo que convierte la
-- lista en una decisión. Una cuenta nueva que comparte teléfono con una
-- expulsada no se aprueba sin mirarla.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La identidad de una persona
-- ---------------------------------------------------------------------------

create or replace function public.admin_user_verification(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
declare
  v_out jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select to_jsonb(q) into v_out
  from (
    select
      v.id,
      v.status::text                                    as status,
      v.extracted_name,
      v.extracted_document,
      v.extracted_birth,
      v.confirmed_name,
      v.registry_matched,
      v.rejection_reason::text                          as rejection_reason,
      v.rejection_detail,
      v.document_path,
      v.selfie_path,
      v.created_at,
      v.reviewed_at,
      -- Quién lo resolvió. Si fue el motor no hay nadie en `platform_admins`
      -- y sale null, que es exactamente lo que hay que enseñar: "lo resolvió
      -- el sistema" y no un nombre inventado.
      pa.full_name                                      as reviewed_by_name,
      v.didit_session_id,
      v.didit_session_url,
      v.didit_synced_at,

      -- El mismo criterio que la cola, para que el veredicto se lea igual en
      -- los dos sitios. Tres tramos, no un porcentaje: el número exacto invita
      -- a calibrar intentos, y esto es para decidir.
      case
        when coalesce(v.face_match_score * 100, d.face_match_score) is null then 'sin_dato'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 75 then 'alta'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 55 then 'media'
        else 'baja'
      end                                               as face_match,
      case
        when coalesce(v.liveness_score * 100, d.liveness_score) is null then 'sin_dato'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 75 then 'alta'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 55 then 'media'
        else 'baja'
      end                                               as liveness,

      case when d.verification_id is not null then 'didit' else 'propio' end as provider,
      coalesce(d.warnings, '[]'::jsonb)                 as warnings,
      d.document_type,
      d.issuing_state,
      d.liveness_method
    from kyc.verifications v
    left join public.platform_admins pa on pa.user_id = v.reviewed_by
    left join lateral (
      select
        l.verification_id,
        (l.signals ->> 'face_match_score')::numeric as face_match_score,
        (l.signals ->> 'liveness_score')::numeric   as liveness_score,
        l.signals ->> 'liveness_method'             as liveness_method,
        l.signals ->> 'document_type'               as document_type,
        l.signals ->> 'issuing_state'               as issuing_state,
        l.signals -> 'warnings'                     as warnings
      from kyc.decision_log l
      where l.verification_id = v.id
        and l.signals ? 'warnings'
      order by l.created_at desc
      limit 1
    ) d on true
    where v.user_id = p_user_id
    order by v.created_at desc
    limit 1
  ) q;

  return v_out;
end;
$$;

comment on function public.admin_user_verification(uuid) is
  'El expediente de identidad mas reciente de una persona, con lo que dijo el proveedor y quien lo resolvio. Lo mismo que ve la cola, pero sin que desaparezca al resolverlo.';

revoke all on function public.admin_user_verification(uuid) from public, anon;
grant execute on function public.admin_user_verification(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Cuentas relacionadas
-- ---------------------------------------------------------------------------

create or replace function public.admin_related_accounts(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.peso desc, q.created_at), '[]'::jsonb)
  into v_rows
  from (
    select
      p.id                    as user_id,
      p.full_name,
      p.phone_e164,
      p.document_number,
      p.status::text          as status,
      p.is_blacklisted,
      p.is_test,
      p.created_at,
      r.motivos,
      -- Para ordenar: el dispositivo compartido pesa más que el nombre.
      (case when 'dispositivo' = any(r.motivos) then 4 else 0 end)
      + (case when 'cedula' = any(r.motivos) then 3 else 0 end)
      + (case when 'nombre' = any(r.motivos) then 1 else 0 end) as peso
    from (
      select
        c.other as uid,
        array_agg(distinct c.motivo) as motivos
      from (
        -- Mismo teléfono físico. La señal fuerte.
        select d2.user_id as other, 'dispositivo'::text as motivo
        from public.user_devices d1
        join public.user_devices d2
          on d2.device_hash = d1.device_hash and d2.user_id <> d1.user_id
        where d1.user_id = p_user_id

        union all

        -- Misma cédula. Si coincide, es la misma persona dos veces.
        select p2.id, 'cedula'::text
        from public.profiles p1
        join public.profiles p2
          on p2.document_number is not null
         and p2.document_number = p1.document_number
         and p2.id <> p1.id
        where p1.id = p_user_id

        union all

        -- Misma cédula según el proveedor, aunque el perfil no la tenga
        -- todavía. Pasa con quien está a mitad de verificación.
        select v2.user_id, 'cedula'::text
        from kyc.verifications v1
        join kyc.verifications v2
          on v2.extracted_document is not null
         and v2.extracted_document = v1.extracted_document
         and v2.user_id <> v1.user_id
        where v1.user_id = p_user_id
          and v1.extracted_document is not null

        union all

        -- Mismo nombre. Solo cuenta acompañado: dos "José García" sueltos no
        -- son nada, y solos llenarían la lista de ruido.
        select p2.id, 'nombre'::text
        from public.profiles p1
        join public.profiles p2
          on p2.full_name is not null
         and lower(trim(p2.full_name)) = lower(trim(p1.full_name))
         and p2.id <> p1.id
        where p1.id = p_user_id and p1.full_name is not null
      ) c
      group by c.other
    ) r
    join public.profiles p on p.id = r.uid
    -- El nombre a secas no basta: tiene que venir con algo más.
    where r.motivos <> array['nombre']::text[]
  ) q;

  return v_rows;
end;
$$;

comment on function public.admin_related_accounts(uuid) is
  'Otras cuentas que comparten dispositivo, cedula o nombre con esta. El nombre solo cuenta acompañado. Es la herramienta contra el fraude de cuentas multiples: quien se fue debiendo y vuelve con otro numero desde el mismo telefono.';

revoke all on function public.admin_related_accounts(uuid) from public, anon;
grant execute on function public.admin_related_accounts(uuid) to authenticated;

create index if not exists user_devices_hash_idx on public.user_devices (device_hash);
