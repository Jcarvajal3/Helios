-- PAGOS (aplicar AUD-OPERACION, 2026-09-28). Parte de la versión VIVA en dev,
-- que viene de 20260927551000_la_cobranza_se_parte_por_local.
--
-- «Vencido hoy» de cada promesa sumaba las cuotas 'pending' sin mirar
-- `written_off_at`: una cuota dada por perdida sigue en 'pending', así que lo
-- «Perdido» se colaba en lo «Vencido» (y en `days_overdue`). Ahora lee la
-- definición canónica (metricas.cuotas, estado 'vencida'). Mismas claves.
--
-- OJO: `admin_collections` tiene el mismo fallo, pero su `overdue_usd` sale de
-- `helios_collection_rows`, que reestructura el orquestador: se deja escrito
-- en el informe APLICADO-PAGOS y no se toca aquí (su desglose tiene que ir a
-- la par que ese overdue_usd, o el fee saldría inflado).

CREATE OR REPLACE FUNCTION public.admin_collection_promises(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today date := public.helios_business_date(now());
  v_from  date := coalesce(p_from, public.helios_business_date(now()) - 30);
  v_rows  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  if p_to is not null and p_to < v_from then
    raise exception 'El rango de fechas está al revés' using errcode = '22023';
  end if;

  with
  -- Con un local: las promesas de personas con alguna cuota en él.
  del_local as (
    select distinct q.user_id
    from metricas.cuotas q
    where q.merchant_id = p_merchant_id
  ),
  -- Lo vencido HOY de cada usuario, con la definición canónica: cuotas en
  -- estado 'vencida' de metricas.cuotas (sin pagar, con el vencimiento antes
  -- de hoy y SIN lo dado por perdido, que es 'perdida'). Con un local, lo de
  -- ese local.
  vencido as (
    select q.user_id,
           sum(q.payable_usd)  as overdue_usd,
           sum(q.financed_usd) as overdue_financed_usd,
           max(q.dias_atraso)  as days_overdue
    from metricas.cuotas q
    where q.estado_hoy = 'vencida'
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
    group by q.user_id
  )
  select coalesce(jsonb_agg(to_jsonb(q) order by q.promise_date, q.contacted_at), '[]'::jsonb)
    into v_rows
  from (
    select
      c.id as contact_id,
      c.user_id,
      p.full_name,
      p.phone_e164,
      p.status::text as user_status,
      c.contacted_at,
      c.channel::text as channel,
      c.outcome,
      c.note,
      c.actor as actor_id,
      coalesce(pa.full_name, 'Alguien del equipo') as actor_name,
      c.promise_date,
      public.helios_promise_status(c.user_id, c.contacted_at, c.promise_date, v_today) as status,
      exists (
        select 1 from public.collection_contacts c2
        where c2.user_id = c.user_id
          and c2.promise_date is not null
          and c2.contacted_at > c.contacted_at
      ) as superseded,
      -- Lo vencido HOY (payable, con su desglose), sin lo perdido. Con un
      -- local, lo de ese local.
      coalesce(d.overdue_usd, 0)::numeric as overdue_usd,
      coalesce(d.overdue_financed_usd, 0)::numeric as overdue_financed_usd,
      coalesce(d.overdue_usd - d.overdue_financed_usd, 0)::numeric as overdue_fee_usd,
      coalesce(d.days_overdue, 0)::integer as days_overdue,
      lp.last_payment
    from public.collection_contacts c
    join public.profiles p on p.id = c.user_id
    left join public.platform_admins pa on pa.user_id = c.actor
    left join vencido d on d.user_id = c.user_id
    left join lateral (
      select jsonb_build_object(
               'report_id',  r.id,
               'created_at', r.created_at,
               'status',     r.status::text,
               'amount_usd', q2.amount_usd
             ) as last_payment
      from public.payment_reports r
      join public.payment_quotes q2 on q2.id = r.quote_id
      where r.user_id = c.user_id
        and r.created_at >= c.contacted_at
      order by r.created_at desc
      limit 1
    ) lp on true
    where c.promise_date is not null
      and c.promise_date >= v_from
      and (p_to is null or c.promise_date <= p_to)
      and not p.is_test
      and (p_merchant_id is null or c.user_id in (select dl.user_id from del_local dl))
  ) q;

  return jsonb_build_object(
    'business_date', v_today,
    'from', v_from,
    'to', p_to,
    'merchant_id', p_merchant_id,
    'summary', jsonb_build_object(
      'vence_hoy', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'vence_hoy'),
      'pendiente', (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'pendiente'),
      'cumplida',  (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'cumplida'),
      'rota',      (select count(*) from jsonb_array_elements(v_rows) e where e->>'status' = 'rota')
    ),
    'rows', v_rows
  );
end;
$function$;
