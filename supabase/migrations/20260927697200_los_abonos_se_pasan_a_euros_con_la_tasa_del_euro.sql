-- PAGOS (aplicar AUD-OPERACION, 2026-09-28). Parte de las versiones VIVAS en
-- dev: admin_unmatched_deposits viene de
-- 20260925145000_cada_aprobacion_guarda_su_movimiento_del_extracto y
-- admin_discarded_deposits de 20260925103000_la_caja_se_mira_a_si_misma.
--
-- El abono se pasaba a euros con la última tasa de `exchange_rates` anterior
-- a su día, SIN mirar la fuente: antes del 10-09 salía a la del dólar
-- ('BCV_USD') y el 09-09, que tiene las dos, a una cualquiera. Ahora solo la
-- del euro ('BCV'), como las cotizaciones. Un abono anterior a la serie del
-- euro sale sin tasa (amount_usd null), que el panel ya pinta como «sin tasa
-- BCV de su día» en vez de inventar un equivalente.

CREATE OR REPLACE FUNCTION public.admin_unmatched_deposits(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.moved_on desc), '[]'::jsonb)
  into v_rows
  from (
    select
      l.id,
      l.bank,
      l.moved_on,
      l.reference,
      l.amount_ves,
      l.description,
      l.imported_at,
      -- En euros a la tasa de ESE día, no a la de hoy: el abono entró con la
      -- tasa de su fecha y volver a convertirlo con otra inventa una
      -- diferencia que no existió.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        -- La del EURO ('BCV'); 'BCV_USD' es la serie archivada del dólar.
        where r.source = 'BCV'
          and r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd
    from public.bank_statement_lines l
    where l.status = 'sin_dueno'
      and not exists (
        select 1 from public.payment_reports pr where pr.statement_line_id = l.id
      )
      and not exists (
        select 1
        from public.payment_reports pr
        join public.payment_quotes pq on pq.id = pr.quote_id
        where pr.status = 'reconciled'
          and pr.statement_line_id is null
          and pr.reference is not null
          and l.reference like '%' || pr.reference
          and abs(l.amount_ves - pq.amount_ves) <= 1.00
          and l.moved_on between (pr.created_at::date - 5) and (pr.created_at::date + 5)
      )
    order by l.moved_on desc
    limit least(coalesce(p_limit, 100), 500)
  ) q;

  return v_rows;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discarded_deposits(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.discarded_at desc nulls last), '[]'::jsonb)
    into v_rows
  from (
    select
      l.id,
      l.bank,
      l.moved_on,
      l.reference,
      l.amount_ves,
      l.description,
      -- En euros a la tasa de ESE día, como en `admin_unmatched_deposits`.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        -- La del EURO ('BCV'); 'BCV_USD' es la serie archivada del dólar.
        where r.source = 'BCV'
          and r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd,
      l.imported_at,
      coalesce(pi.full_name, 'Alguien del equipo') as imported_by_name,
      l.resolved_at as discarded_at,
      l.resolved_by as discarded_by,
      coalesce(pa.full_name, 'Alguien del equipo') as discarded_by_name,
      l.resolution_note as reason
    from public.bank_statement_lines l
    left join public.platform_admins pa on pa.user_id = l.resolved_by
    left join public.platform_admins pi on pi.user_id = l.imported_by
    where l.status = 'descartado'
    order by l.resolved_at desc nulls last
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ) q;

  return v_rows;
end;
$function$;
