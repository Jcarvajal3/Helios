-- ============================================================================
-- Ronda — El asistente del super admin deja su línea y tiene límite
--
-- La Edge Function `admin-asistente` contesta preguntas del equipo con Claude
-- leyendo RPC de solo lectura. Cada pregunta cuesta dinero (tokens) y conviene
-- saber quién pregunta qué. Esta función hace las dos cosas:
--
--   1. Al empezar (sin p_log_id): comprueba el límite por persona y hora
--      (`asistente_preguntas_por_hora`, sembrado en 30) y deja la línea
--      `assistant.question` en la bitácora con la pregunta. Si el límite se
--      superó, error 22023 con el mensaje que enseña el panel; la función
--      contesta 429 y no llama a Claude.
--   2. Al terminar (con p_log_id = el id de esa línea): deja otra,
--      `assistant.answer`, con las herramientas usadas, los tokens y el modelo.
--      Solo quien hizo la pregunta puede cerrarla.
--
-- Son dos líneas y no una porque el límite tiene que pararse antes de gastar,
-- los tokens solo se saben al final y `audit.admin_actions` es de solo añadir
-- (un trigger rechaza el UPDATE). El límite cuenta solo las preguntas.
--
-- El parámetro vive en el grupo nuevo `asistente` del catálogo (el panel lo
-- pinta en «Otros» hasta que le dé título).
-- ============================================================================

alter table public.business_parameter_catalog
  drop constraint if exists business_parameter_catalog_grupo_check;
alter table public.business_parameter_catalog
  add constraint business_parameter_catalog_grupo_check
  check (grupo in ('producto', 'umbral', 'meta', 'capital', 'alerta', 'asistente'));

insert into public.business_parameter_catalog (key, label, unit, grupo) values
  ('asistente_preguntas_por_hora', 'Asistente: preguntas por persona y hora', 'preguntas', 'asistente')
on conflict (key) do nothing;

insert into public.business_parameters (key, value, effective_from, note) values
  ('asistente_preguntas_por_hora', 30, '2026-09-01',
   'Preguntas al asistente que una misma persona del equipo puede hacer en una hora.')
on conflict (key, effective_from) do nothing;

create or replace function public.admin_assistant_log(
  p_question      text,
  p_tools         text[]  default '{}',
  p_input_tokens  integer default null,
  p_output_tokens integer default null,
  p_model         text    default null,
  p_log_id        bigint  default null
)
returns bigint
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor    uuid := auth.uid();
  v_question text := left(trim(coalesce(p_question, '')), 2000);
  v_limit    integer;
  v_count    integer;
  v_id       bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- Segundo tiempo: la respuesta terminó y se anotan sus cifras.
  if p_log_id is not null then
    if not exists (
      select 1 from audit.admin_actions
       where id = p_log_id and actor = v_actor and action = 'assistant.question'
    ) then
      raise exception 'No existe esa pregunta en la bitácora' using errcode = 'P0002';
    end if;

    insert into audit.admin_actions (actor, action, target_id, detail)
    values (v_actor, 'assistant.answer', null, jsonb_build_object(
      'question_id',   p_log_id,
      'tools',         to_jsonb(coalesce(p_tools, '{}'::text[])),
      'input_tokens',  p_input_tokens,
      'output_tokens', p_output_tokens,
      'model',         p_model))
    returning id into v_id;
    return v_id;
  end if;

  if v_question = '' then
    raise exception 'La pregunta está vacía' using errcode = '22004';
  end if;

  v_limit := greatest(coalesce(public.helios_parameter('asistente_preguntas_por_hora', 30), 30), 1)::integer;

  -- Dos pestañas preguntando a la vez no se cuelan por el mismo hueco.
  perform pg_advisory_xact_lock(hashtextextended('assistant.question:' || v_actor::text, 0));

  select count(*) into v_count
    from audit.admin_actions
   where actor = v_actor
     and action = 'assistant.question'
     and created_at > now() - interval '1 hour';

  if v_count >= v_limit then
    raise exception '%', format(
      'Has hecho %s %s en la última hora; el límite es %s',
      v_count, case when v_count = 1 then 'pregunta' else 'preguntas' end, v_limit)
      using errcode = '22023';
  end if;

  insert into audit.admin_actions (actor, action, target_id, detail)
  values (v_actor, 'assistant.question', null, jsonb_build_object('question', v_question))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.admin_assistant_log(text, text[], integer, integer, text, bigint) is
  'Bitácora y límite del asistente. Sin p_log_id: comprueba asistente_preguntas_por_hora (22023 si se superó), deja assistant.question y devuelve su id. Con p_log_id: deja assistant.answer con herramientas, tokens y modelo. Cualquier admin.';

revoke all on function public.admin_assistant_log(text, text[], integer, integer, text, bigint) from public, anon;
grant execute on function public.admin_assistant_log(text, text[], integer, integer, text, bigint) to authenticated;
