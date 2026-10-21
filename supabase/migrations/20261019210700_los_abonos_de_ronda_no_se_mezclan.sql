-- ============================================================================
-- Helios — Los abonos de Ronda no se mezclan con los de Helios
--
-- Helios y Ronda cobran en la misma cuenta del BNC, así que el extracto que
-- se importa en Helios trae también los pagos de los usuarios de Ronda. Todo
-- abono que no casa con un pago registrado salía en «Abonos sin dueño», y
-- desde ahí se le podía asignar a un paciente de Helios dinero que era de un
-- usuario de Ronda (Javier, 2026-10-19: «hay que tener cuidado en no mezclar
-- ambos pagos»).
--
-- El BNC escribe en la descripción quién pagó
-- («TELF.:584241875770 BANCO:0102 CED.:V30496254 PMPC pago»; lo mismo que lee
-- el panel en `features/admin/payer.ts`). Un abono es de Helios si su pagador
-- (cédula o teléfono) es un paciente de Helios o el pagador de un pago
-- registrado aquí. Si no, casi seguro es de Ronda: se marca y el panel lo
-- aparta, sin contarlo en Inicio y pidiendo confirmación para asignarlo.
--
-- 1. `helios_pagador_del_movimiento(descripción)`: la cédula (solo dígitos,
--    como `profiles.document_number`) y el teléfono (58 + 10 dígitos, como
--    `profiles.phone_e164`).
-- 2. `helios_movimiento_es_de_helios(descripción)`.
-- 3. `admin_unmatched_deposits` trae `de_helios` y ordena primero los de
--    Helios.
-- Solo lectura: no cambia ningún dato.
-- ============================================================================

create or replace function public.helios_pagador_del_movimiento(p_description text)
returns table(documento text, telefono text)
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  with d as (
    select coalesce(p_description, '') as t
  ),
  doc as (
    select regexp_replace(coalesce(
      -- Con palabra delante: CED.:V30496254, C.I. 30.496.254, RIF J-123456789.
      (regexp_match(d.t, '(?:c\.?\s?i\.?|ced(?:ula|\.)?|rif|doc(?:umento)?)\.?\s*:?\s*[vejpg]?\s*-?\s*(\d[\d.]{5,10})', 'i'))[1],
      -- Sin palabra, con la letra pegada: V-30496254.
      (regexp_match(d.t, '\m[vejpg]-?\s?(\d{6,9})\M', 'i'))[1]
    ), '[^0-9]', '', 'g') as v
    from d
  ),
  tel as (
    select regexp_replace(coalesce(
      (regexp_match(d.t, '(?:telf?|tlf|tel[eé]fono|m[oó]vil|movil|celular)\.?\s*:?\s*\+?\s*(\d[\d\s().-]{6,14})', 'i'))[1],
      ''), '[^0-9]', '', 'g') as v
    from d
  )
  select
    nullif(doc.v, '') as documento,
    case
      when tel.v ~ '^58\d{10}$' then tel.v
      when tel.v ~ '^0\d{10}$'  then '58' || substr(tel.v, 2)
      when tel.v ~ '^\d{10}$'   then '58' || tel.v
    end as telefono
  from doc, tel;
$$;

comment on function public.helios_pagador_del_movimiento(text) is
  'Quién pagó, sacado de la descripción del movimiento del BNC: la cédula (dígitos) y el teléfono (58 + 10 dígitos). Como features/admin/payer.ts.';

create or replace function public.helios_movimiento_es_de_helios(p_description text)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.helios_pagador_del_movimiento(p_description) x
    where (x.documento is not null and (
             exists (select 1 from public.profiles p where p.document_number = x.documento and not p.is_test)
          or exists (select 1 from public.payment_reports r
                     where regexp_replace(coalesce(r.payer_document, ''), '[^0-9]', '', 'g') = x.documento)))
       or (x.telefono is not null and (
             exists (select 1 from public.profiles p where p.phone_e164 = x.telefono and not p.is_test)
          or exists (select 1 from public.payment_reports r
                     where regexp_replace(coalesce(r.payer_phone, ''), '[^0-9]', '', 'g') in (x.telefono, '0' || substr(x.telefono, 3)))))
  );
$$;

comment on function public.helios_movimiento_es_de_helios(text) is
  'Si el pagador de un movimiento del banco (cédula o teléfono de su descripción) es un paciente de Helios o el pagador de un pago registrado aquí. Si no, el abono casi seguro es de Ronda, que cobra en la misma cuenta.';

revoke all on function public.helios_pagador_del_movimiento(text) from public, anon;
revoke all on function public.helios_movimiento_es_de_helios(text) from public, anon, authenticated;

create or replace function public.admin_unmatched_deposits(p_limit integer default 100)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.de_helios desc, q.moved_on desc), '[]'::jsonb)
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
      -- En dólares a la tasa de ESE día, no a la de hoy: el abono entró con la
      -- tasa de su fecha y volver a convertirlo con otra inventa una
      -- diferencia que no existió.
      (
        select round(l.amount_ves / r.rate, 2)
        from public.exchange_rates r
        where r.source = 'BCV'
          and r.effective_date <= l.moved_on
        order by r.effective_date desc
        limit 1
      ) as amount_usd,
      -- Helios y Ronda cobran en la misma cuenta: sin un pagador de Helios,
      -- el abono casi seguro es de Ronda.
      public.helios_movimiento_es_de_helios(l.description) as de_helios
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
