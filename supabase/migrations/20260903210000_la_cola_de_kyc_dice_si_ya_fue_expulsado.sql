-- ============================================================================
-- Ronda — Quien revisa un KYC tiene que ver si esa persona ya fue expulsada
--
-- `profiles.is_blacklisted` se pone en `true` cuando el motor de mora expulsa a
-- alguien, y sobrevive a la expulsión a propósito: el comentario de
-- 20260821210000 dice "si una cédula vuelve a intentar registrarse, queremos
-- saberlo". El panel de usuarios lo enseña.
--
-- La cola de KYC no. Y es justo donde hace falta.
--
-- El caso: un expulsado vuelve con la misma cédula. La comprobación de
-- duplicados de `record_didit_decision` lo caza y lo manda a `manual_review`,
-- así que llega a esta cola — pero con la nota "Esa cédula ya está registrada
-- en otra cuenta" y nada más. El operador lee eso, ve que las fotos coinciden,
-- y aprueba sin enterarse de que le está devolviendo la entrada a quien se fue
-- debiendo. La señal existía, guardada, a una tabla de distancia.
--
-- Va el motivo además de la marca: "expulsado" a secas invita a rechazar por
-- reflejo, y no todas las expulsiones pesan igual.
-- ============================================================================

create or replace function public.admin_kyc_queue()
returns jsonb
language plpgsql
security definer
set search_path = public, kyc, storage, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb)
    into v_rows
  from (
    select
      v.id,
      v.user_id,
      p.phone_e164,
      v.extracted_name,
      v.extracted_document,
      v.extracted_birth,

      -- NUEVO: lo que el revisor no podía ver. Va de la mano con el motivo,
      -- porque la marca sola no dice si fue por mora de una cuota o por algo
      -- peor.
      p.is_blacklisted,
      p.blacklist_reason,

      -- Los puntajes se redondean a un semáforo. El revisor necesita saber si
      -- la señal es buena o dudosa, no el número exacto.
      --
      -- Los cortes son los mismos de siempre (0,75 y 0,55) leídos en la escala
      -- de cada proveedor. Didit los manda de 0 a 100 y se guardan tal cual,
      -- sin convertir: reescalarlos invitaría a compararlos con los umbrales
      -- del motor propio, que estaban calibrados contra OTRO modelo y no
      -- significan lo mismo aquí.
      case
        when coalesce(v.face_match_score * 100, d.face_match_score) is null then 'sin_dato'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 75 then 'alta'
        when coalesce(v.face_match_score * 100, d.face_match_score) >= 55 then 'media'
        else 'baja'
      end as face_match,
      case
        when coalesce(v.liveness_score * 100, d.liveness_score) is null then 'sin_dato'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 75 then 'alta'
        when coalesce(v.liveness_score * 100, d.liveness_score) >= 55 then 'media'
        else 'baja'
      end as liveness,

      v.registry_matched,
      v.rejection_detail,
      v.document_path,
      v.selfie_path,

      -- De dónde salió el veredicto. El panel lo usa para no enseñar dos
      -- marcos de foto vacíos en un expediente que nunca tuvo fotos.
      case when d.verification_id is not null then 'didit' else 'propio' end as provider,

      -- Lo único que explica una duda con palabras. Didit los manda como lista
      -- y se pasan enteros: el `rejection_detail` solo se queda con los tres
      -- primeros, y el cuarto puede ser justo el que importa.
      coalesce(d.warnings, '[]'::jsonb) as warnings,
      d.document_type,
      d.issuing_state,
      d.liveness_method,

      v.created_at,
      extract(epoch from (now() - v.created_at))::bigint as waiting_seconds
    from kyc.verifications v
    join public.profiles p on p.id = v.user_id

    -- El último veredicto de Didit para este expediente.
    --
    -- Se reconoce por `warnings`: es la única clave que añade el webhook de la
    -- decisión. El renglón que escribe `attach_didit_session` al abrir la
    -- sesión también lleva `provider: didit`, pero no trae señal ninguna, así
    -- que filtrar por el proveedor traería el renglón vacío la mitad de las
    -- veces.
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

    where v.status = 'manual_review'
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_kyc_queue() from public, anon;
grant execute on function public.admin_kyc_queue() to authenticated;
