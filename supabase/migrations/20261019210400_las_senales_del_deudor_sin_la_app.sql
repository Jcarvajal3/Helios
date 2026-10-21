-- ============================================================================
-- Helios — Las señales del deudor, sin la app
--
-- La poda (20261001000000) dejó en `metricas.senales_deudor` las claves de la
-- app de Ronda con su valor de «sin dato», y una de ellas no lo era:
-- `'avisos' = 'nunca'`. El panel la leía como «Nunca dio permiso de avisos en
-- su teléfono» y le ponía a TODO deudor la señal roja «No recibe avisos», que
-- empujaba la lectura hacia «Lo está evitando». Desde el 2026-10-13 los avisos
-- salen solos por WhatsApp y correo: era falso.
--
-- El panel ya no lee esas claves (señales de la app: abrir la app, entrar a
-- pagar, copiar los datos, tocar un aviso). Aquí se dejan de mandar: quedan
-- el vencimiento más viejo y el último pago registrado.
-- ============================================================================

create or replace function metricas.senales_deudor(p_users uuid[])
 returns table(user_id uuid, senales jsonb)
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  with
  u as (select distinct x as user_id from unnest(p_users) x where x is not null),
  hoy as (select public.helios_business_date(now()) as dia),
  -- Desde cuándo debe algo vencido: su cuota pendiente más vieja ya vencida
  -- (sin lo dado por perdido).
  vence as (
    select i.user_id, min(i.due_date) as desde
    from public.installments i
    join u using (user_id)
    cross join hoy
    where i.status = 'pending'
      and not i.is_test
      and i.written_off_at is null
      and i.due_date < hoy.dia
    group by i.user_id
  ),
  rep as (
    select distinct on (pr.user_id)
      pr.user_id, pr.status::text as estado, pr.created_at, pr.reviewed_at, pr.rejection_note
    from public.payment_reports pr
    join u using (user_id)
    where pr.status <> 'duplicate'
    order by pr.user_id, pr.created_at desc
  ),
  rev as (
    select pr.user_id, min(pr.created_at) as desde
    from public.payment_reports pr
    join u using (user_id)
    where pr.status in ('reported', 'in_review')
    group by pr.user_id
  )
  select
    u.user_id,
    jsonb_build_object(
      'vencida_desde',     vence.desde,
      'ultimo_reporte',    case when rep.user_id is not null then jsonb_build_object(
                             'estado',      rep.estado,
                             'en',          rep.created_at,
                             'revisado_en', rep.reviewed_at,
                             'nota',        rep.rejection_note) end,
      'en_revision_desde', rev.desde
    )
  from u
  left join vence on vence.user_id = u.user_id
  left join rep   on rep.user_id   = u.user_id
  left join rev   on rev.user_id   = u.user_id;
$function$;
