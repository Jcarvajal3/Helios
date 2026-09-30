-- ============================================================================
-- Ronda — El sexo del documento y el aparato con el que se verificó
--
-- Didit lee el sexo impreso en la cédula (`id_verifications[].gender`) y
-- analiza el aparato y la red desde los que se hizo la verificación
-- (`ip_analyses[]`). Los dos llegan en cada veredicto y la traducción de
-- `_shared/didit.ts` no los copiaba.
--
-- Entran por una puerta propia y no por `record_didit_decision`, por dos
-- razones:
--   · `record_didit_decision` no vuelve a tocar un expediente resuelto (los
--     webhooks se reentregan), y recuperar lo que ya pasó es justo escribir
--     sobre expedientes resueltos;
--   · estos datos describen, no deciden: si fallan, el veredicto no cae.
--
-- Del aparato se guarda lo que sirve para contrastarlo con `user_devices`
-- (marca, modelo, sistema, navegador, huella) y la red (país, ciudad,
-- operador, VPN). La IP exacta y las coordenadas se quedan en Didit: no hacen
-- falta para esa comparación y son el dato más sensible del paquete.
-- ============================================================================

alter table kyc.verifications
  add column if not exists extracted_gender text
    check (extracted_gender in ('M', 'F')),
  add column if not exists didit_device jsonb,
  add column if not exists didit_details_at timestamptz;

comment on column kyc.verifications.extracted_gender is
  'Sexo impreso en el documento, según Didit: M o F.';
comment on column kyc.verifications.didit_device is
  'Aparato y red desde los que se verificó, según el analisis de IP de Didit. Sin IP exacta ni coordenadas.';
comment on column kyc.verifications.didit_details_at is
  'Cuándo se le pidió a Didit el sexo y el aparato por última vez, haya traído algo o no. Null = nunca.';


-- ---------------------------------------------------------------------------
-- La puerta
-- ---------------------------------------------------------------------------
--
-- Un null no borra lo que ya hay: un webhook intermedio sin datos no puede
-- vaciar lo que trajo uno anterior.

create or replace function public.kyc_record_didit_details(
  p_session_id text,
  p_gender     text  default null,
  p_device     jsonb default null
)
returns boolean
language sql
security definer
set search_path = public, kyc, pg_temp
as $$
  with u as (
    update kyc.verifications
       set extracted_gender = coalesce(p_gender, extracted_gender),
           didit_device     = coalesce(nullif(p_device, '{}'::jsonb), didit_device),
           didit_details_at = now()
     where didit_session_id = p_session_id
    returning 1
  )
  select exists (select 1 from u);
$$;

revoke all on function public.kyc_record_didit_details(text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.kyc_record_didit_details(text, text, jsonb)
  to service_role;


-- Las sesiones a las que todavía no se les ha preguntado. La recuperación las
-- toma por lotes para no gastar de una vez el límite de consultas de Didit,
-- que es de la organización entera.
create or replace function public.kyc_didit_details_pending(p_limit int default 20)
returns setof text
language sql
security definer
set search_path = public, kyc, pg_temp
stable
as $$
  select didit_session_id
  from kyc.verifications
  where didit_session_id is not null
    and didit_details_at is null
  order by created_at
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;

revoke all on function public.kyc_didit_details_pending(int)
  from public, anon, authenticated;
grant execute on function public.kyc_didit_details_pending(int)
  to service_role;


-- ---------------------------------------------------------------------------
-- La ficha lo enseña
-- ---------------------------------------------------------------------------
--
-- Cuerpo idéntico al de 20260911198000 más `gender` y `didit_device`.

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
      v.extracted_gender                                as gender,
      v.didit_device,
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
