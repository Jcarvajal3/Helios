-- ============================================================================
-- Ronda — La cola pasa a reclamar de verdad
--
-- `kyc.claim_pending` era un SELECT con `for update skip locked` y ningún
-- UPDATE: no marcaba nada. El bloqueo de fila vive lo que dura SU PROPIA
-- transacción —milisegundos— y no los 2-4 segundos que tarda el pipeline. O
-- sea que SKIP LOCKED solo protege de dos reclamaciones simultáneas al
-- microsegundo, no del caso real.
--
-- Dos consecuencias, y la segunda ya está ocurriendo:
--
--   · Varias réplicas procesan la misma verificación entera y en paralelo,
--     con doble consulta al registro civil (que se paga por uso) y resultados
--     que pueden diferir. El README promete lo contrario. Esto se activa con
--     la segunda máquina — incluido el solapamiento de máquina vieja y nueva
--     durante un despliegue rodante de Fly, que pasa en cada deploy.
--
--   · Un trabajo que revienta queda en 'processing' y, como nada lo marca, la
--     vuelta SIGUIENTE lo reclama otra vez: bucle caliente sin espera ni tope,
--     redescargando las mismas imágenes. Y con `batch_size = 5` y orden por
--     antigüedad, cinco trabajos envenenados taponan la cabecera y ninguna
--     verificación posterior se procesa nunca.
--
-- El arreglo es un lease con caducidad: reclamar ESCRIBE, y lo escrito expira.
-- De regalo trae recuperación ante caídas —si el proceso muere a mitad, el
-- lease vence y otro lo retoma— que hasta ahora funcionaba de casualidad,
-- precisamente porque no se marcaba nada.
-- ============================================================================

alter table kyc.verifications
  add column if not exists claimed_at timestamptz,
  add column if not exists attempts   int not null default 0;

comment on column kyc.verifications.claimed_at is
  'Cuándo la tomó un worker. Expira a los 10 minutos: si quien la tomó murió, '
  'otro la recoge sin intervención.';

create index if not exists verifications_claimable_idx
  on kyc.verifications (created_at)
  where status = 'processing';


-- Cuánto puede tardar el pipeline antes de dar por muerto a quien reclamó.
-- Una verificación tarda 2-4 s; diez minutos son un margen enorme a propósito,
-- porque el coste de esperar de más es latencia y el de esperar de menos es
-- procesamiento doble.
create or replace function kyc.claim_pending(p_limit int default 10)
returns table (
  verification_id uuid,
  user_id         uuid,
  document_path   text,
  selfie_path     text
)
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_lease   interval := interval '10 minutes';
  v_max_try int := 3;
begin
  -- Primero se saca de la cola lo que ya no tiene arreglo automático. Sin
  -- esto, limitar los intentos dejaría esas filas en 'processing' para
  -- siempre, invisibles: nadie las reclama y nadie las mira.
  with agotadas as (
    update kyc.verifications
       set status           = 'manual_review',
           rejection_detail = format(
             'El servicio falló %s veces al procesarla. Revísala a mano.',
             attempts
           ),
           claimed_at       = null,
           updated_at       = now()
     where status = 'processing'
       and attempts >= v_max_try
       and (claimed_at is null or claimed_at < now() - v_lease)
    returning id, attempts
  )
  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  select id, 'processing', 'manual_review', 'system',
         jsonb_build_object('reason', 'attempts_exhausted', 'attempts', attempts)
    from agotadas;

  -- Y ahora sí, reparto. El UPDATE es lo que convierte esto en una
  -- reclamación: a partir de aquí la fila lleva marca y nadie más la toca
  -- hasta que el lease venza.
  return query
  update kyc.verifications v
     set claimed_at = now(),
         attempts   = v.attempts + 1,
         updated_at = now()
   where v.id in (
     select c.id
       from kyc.verifications c
      where c.status = 'processing'
        and c.document_path is not null
        and c.selfie_path is not null
        and c.attempts < v_max_try
        and (c.claimed_at is null or c.claimed_at < now() - v_lease)
      order by c.created_at
      limit p_limit
      for update skip locked
   )
  returning v.id, v.user_id, v.document_path, v.selfie_path;
end;
$$;

revoke all on function kyc.claim_pending(int) from public, anon, authenticated;


-- Al resolverse, la marca sobra: dejarla puesta ensucia cualquier consulta
-- futura sobre trabajo en curso.
create or replace function kyc.apply_status(
  p_verification_id uuid,
  p_status          kyc.verification_status,
  p_reason          kyc.rejection_reason default null,
  p_actor           text default 'system',
  p_signals         jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = kyc, public, pg_temp
as $$
declare
  v_row kyc.verifications%rowtype;
begin
  select * into v_row from kyc.verifications
  where id = p_verification_id for update;

  if not found then
    raise exception 'Verificación no encontrada' using errcode = 'P0002';
  end if;

  update kyc.verifications
    set status           = p_status,
        rejection_reason = p_reason,
        reviewed_at      = case when p_actor <> 'system' then now() else reviewed_at end,
        claimed_at       = case when p_status = 'processing' then claimed_at else null end,
        updated_at       = now()
  where id = p_verification_id;

  insert into kyc.decision_log (verification_id, from_status, to_status, actor, signals)
  values (p_verification_id, v_row.status, p_status, p_actor, p_signals);

  -- Solo 'approved' activa; cualquier otro estado desactiva. Escribirlo así
  -- —y no enumerando los rechazos— cubre también las transiciones de vuelta:
  -- una verificación ya aprobada que un operador baja a revisión deja de
  -- reservar esa cara mientras se decide.
  update kyc.face_embeddings
    set active = (p_status = 'approved')
  where verification_id = p_verification_id;

  -- Aprobar ya no escribe nada en el perfil: eso pasa cuando la persona
  -- confirma. Si confirmó antes que llegara el veredicto —el caso de la
  -- revisión manual—, esta llamada es la que lo activa.
  if p_status = 'approved' then
    perform kyc.advance_profile(p_verification_id);
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

revoke all on function kyc.apply_status(
  uuid, kyc.verification_status, kyc.rejection_reason, text, jsonb
) from public, anon, authenticated;
