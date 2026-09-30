-- ============================================================================
-- Ronda — La cartera vencida se mueve entre tramos
--
-- La cola de cobranza es una foto: quién debe hoy y cuánto. No contesta la
-- pregunta con la que se decide dónde poner a la única persona de cobranza:
-- ¿la gente que cae en mora sale sola en la primera semana, o se queda y
-- rueda hacia la baja de nivel? Eso es una película, y se mide contando
-- cuántas personas pasan de un tramo a otro de un lunes al siguiente.
--
-- ── Los tramos ───────────────────────────────────────────────────────────────
-- Salen de los parámetros de negocio, nunca escritos a mano:
--   al_dia  sin nada vencido
--   t1      1 .. gracia                     (antes del cargo por atraso)
--   t2      gracia+1 .. intervalo           (ya con cargo; aún antes de la 2.ª cuota)
--   t3      intervalo+1 .. baja−1
--   t4      baja .. expulsión               (bajó de nivel, saldo bloqueado)
--   t5      más de expulsión                (expulsado, deuda dada por perdida)
-- Se usan los valores VIGENTES HOY para todas las semanas, a propósito: si el
-- corte de cada semana usara el parámetro de su fecha, un cambio de gracia
-- movería gente de tramo sin que nadie hubiera pagado nada, y la serie dejaría
-- de ser comparable consigo misma.
--
-- ── El corte ─────────────────────────────────────────────────────────────────
-- El lunes a las 10:00 de Caracas: el comienzo del día operativo del lunes,
-- que es lo que ve el motor de mora ese día. Una cuota está «sin pagar en el
-- corte» si ya existía (`created_at` anterior) y no se había pagado antes
-- (`paid_at` nulo o posterior). Los días de atraso de una persona son el
-- máximo, sobre esas cuotas vencidas, de (lunes − vencimiento). Las cuotas
-- dadas por perdidas siguen sin pagar: son el tramo t5, no desaparecen.
--
-- ── Quién cuenta como «al día» ───────────────────────────────────────────────
-- Toda persona con alguna cuota creada antes del corte. Así quien paga todo lo
-- que debía sale de su tramo hacia `al_dia` —que es justo la cura que se
-- quiere medir— en vez de desaparecer de la cuenta. Quien no tenía ninguna
-- cuota en el corte anterior entra como `nuevo`.
--
-- ── Rendimiento ──────────────────────────────────────────────────────────────
-- Nada se calcula por persona y por semana para toda la base. Se leen una vez
-- solo las cuotas que pueden estar vencidas en algún corte (pendientes, o
-- pagadas tarde después del primer corte) y se cruzan con ≤ 53 cortes. La
-- gente al día no se materializa: sale por aritmética (población −
-- atrasados), y la población de cada corte es un conteo sobre
-- `min(created_at)` por persona. El coste es un recorrido de `installments`
-- más O(cuotas candidatas × cortes). Medido dentro de un rollback con 10.000
-- personas y 80.000 cuotas, el 40 % en mora (un caso mucho peor que el
-- piloto): 8 semanas ≈ 0,7 s, 26 ≈ 1,5 s, 52 ≈ 2,1 s. Con los datos de dev,
-- milisegundos.
-- ============================================================================

-- Para leer las cuotas pagadas en un rango (lo recuperado, la efectividad).
create index if not exists installments_paid_at_idx
  on public.installments (paid_at)
  where status = 'paid';

-- ---------------------------------------------------------------------------
-- 1. El tramo de unos días de atraso
-- ---------------------------------------------------------------------------
-- Pura, con los umbrales como argumentos: quien la llama lee los parámetros una
-- vez y no una por fila. El orden de los `when` resuelve los solapes si algún
-- día la gracia supera al intervalo (t2 quedaría vacío, no negativo).
--
-- Sin `set search_path` a propósito: con él Postgres no puede escribirla en
-- línea y la llama fila a fila, y en el flujo eso era la mitad del tiempo. No
-- nombra ninguna tabla ni función, y los operadores de enteros salen de
-- `pg_catalog`, que se busca siempre primero.
create or replace function public.helios_tramo_de_atraso(
  p_days      integer,
  p_grace     integer,
  p_interval  integer,
  p_demotion  integer,
  p_expulsion integer
)
returns text
language sql
immutable
as $$
  select case
    when p_days is null or p_days <= 0 then 'al_dia'
    when p_days <= p_grace             then 't1'
    when p_days <= p_interval          then 't2'
    when p_days <  p_demotion          then 't3'
    when p_days <= p_expulsion         then 't4'
    else 't5'
  end
$$;

revoke all on function public.helios_tramo_de_atraso(integer, integer, integer, integer, integer)
  from public, anon;
grant execute on function public.helios_tramo_de_atraso(integer, integer, integer, integer, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Los tramos, descritos con los parámetros de hoy
-- ---------------------------------------------------------------------------
-- Viajan con cada respuesta para que el panel rotule «1–3 días» sin escribir
-- el 3 en ningún sitio. Un tramo vacío (from_days > to_days) se devuelve igual.
create or replace function public.helios_tramos_de_atraso()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with p as (
    select public.helios_late_fee_grace_days()       as g,
           public.helios_installment_interval_days() as i,
           public.helios_mora_demotion_days()        as b,
           public.helios_mora_expulsion_days()       as e
  )
  select jsonb_build_object(
    'grace_days',     g,
    'interval_days',  i,
    'demotion_days',  b,
    'expulsion_days', e,
    'buckets', jsonb_build_array(
      jsonb_build_object('key', 'al_dia', 'from_days', null,  'to_days', 0),
      jsonb_build_object('key', 't1',     'from_days', 1,     'to_days', g),
      jsonb_build_object('key', 't2',     'from_days', g + 1, 'to_days', i),
      jsonb_build_object('key', 't3',     'from_days', i + 1, 'to_days', b - 1),
      jsonb_build_object('key', 't4',     'from_days', b,     'to_days', e),
      jsonb_build_object('key', 't5',     'from_days', e + 1, 'to_days', null)
    )
  )
  from p
$$;

revoke all on function public.helios_tramos_de_atraso() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. El flujo semana a semana
-- ---------------------------------------------------------------------------
create or replace function public.admin_collection_flow(p_weeks integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today     date := public.helios_business_date(now());
  v_weeks     integer := greatest(least(coalesce(p_weeks, 8), 52), 1);
  v_grace     integer := public.helios_late_fee_grace_days();
  v_interval  integer := public.helios_installment_interval_days();
  v_demotion  integer := public.helios_mora_demotion_days();
  v_expulsion integer := public.helios_mora_expulsion_days();
  v_last      date;          -- el lunes más reciente: el último corte
  v_first     date;          -- el corte ANTERIOR al primero que se devuelve
  v_first_ts  timestamptz;
  v_weeks_out jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_last     := v_today - (extract(isodow from v_today)::integer - 1);
  v_first    := v_last - 7 * v_weeks;
  v_first_ts := (v_first::timestamp + interval '10 hours') at time zone 'America/Caracas';

  -- Sobre enteros y no sobre fechas: así el planificador sabe que son
  -- `v_weeks + 1` filas y no las mil que supone para una serie de fechas (con
  -- mil, reparte la agregación en disco).
  with cuts as (
    select v_first + 7 * k as cut,
           ((v_first + 7 * k)::timestamp + interval '10 hours') at time zone 'America/Caracas' as cut_ts
    from generate_series(0, v_weeks) k
  ),
  -- Las únicas cuotas que pueden estar vencidas y sin pagar en algún corte:
  -- las pendientes, y las pagadas después del primer corte Y después de
  -- vencer (una pagada a tiempo no está atrasada en ningún lunes, y son la
  -- mayoría). Materializada: se lee una vez, en vez de una por corte.
  cand as materialized (
    select i.user_id, i.due_date, i.amount_usd, i.created_at, i.paid_at
    from public.installments i
    where not i.is_test
      and i.due_date < v_last
      and (
        i.status = 'pending'
        or (i.paid_at >= v_first_ts
            and i.paid_at >= ((i.due_date + 1)::timestamp + interval '10 hours')
                             at time zone 'America/Caracas')
      )
  ),
  -- (corte, persona) de quien estaba atrasado: días y deuda vencida (payable).
  st as (
    select a.cut, a.user_id, a.usd,
           public.helios_tramo_de_atraso(a.days, v_grace, v_interval, v_demotion, v_expulsion) as tramo
    from (
      select c.cut, x.user_id, max(c.cut - x.due_date) as days, sum(x.amount_usd) as usd
      from cand x
      join cuts c
        on x.due_date < c.cut
       and x.created_at < c.cut_ts
       and (x.paid_at is null or x.paid_at >= c.cut_ts)
      group by c.cut, x.user_id
    ) a
  ),
  firsts as (
    select i.user_id, min(i.created_at) as first_at
    from public.installments i
    where not i.is_test
    group by i.user_id
  ),
  base as (
    select c.cut,
           (select count(*) from firsts f where f.first_at < c.cut_ts)::integer as pop_n,
           (select count(*) from st where st.cut = c.cut)::integer as late_n
    from cuts c
  ),
  counts as (
    select cut, tramo, count(*)::integer as people, sum(usd) as usd
    from st
    group by cut, tramo
  ),
  -- Parejas de cortes consecutivos de quien estuvo atrasado en alguno de los
  -- dos. Quien estuvo al día en ambos no se materializa.
  pairs as (
    select coalesce(b.cut, a.cut + 7) as cut,
           coalesce(a.user_id, b.user_id) as user_id,
           a.tramo as from_t,
           b.tramo as to_t
    from (select * from st where st.cut < v_last) a
    full join (select * from st where st.cut > v_first) b
      on b.user_id = a.user_id and b.cut = a.cut + 7
  ),
  trans as (
    select p.cut,
           coalesce(p.from_t,
             case when f.first_at < ((p.cut - 7)::timestamp + interval '10 hours')
                                    at time zone 'America/Caracas'
                  then 'al_dia' else 'nuevo' end) as from_t,
           coalesce(p.to_t, 'al_dia') as to_t,
           count(*)::integer as people
    from pairs p
    join firsts f on f.user_id = p.user_id
    group by 1, 2, 3
  ),
  flows as (
    select cut, from_t, to_t, people from trans
    union all
    -- Al día en los dos cortes: los que estaban al día menos los que cayeron.
    select b.cut, 'al_dia', 'al_dia',
           (bp.pop_n - bp.late_n)
           - coalesce((select sum(t.people) from trans t
                       where t.cut = b.cut and t.from_t = 'al_dia'), 0)::integer
    from base b join base bp on bp.cut = b.cut - 7
    union all
    -- Nuevos que llegan al día: los que entraron menos los que entraron atrasados.
    select b.cut, 'nuevo', 'al_dia',
           (b.pop_n - bp.pop_n)
           - coalesce((select sum(t.people) from trans t
                       where t.cut = b.cut and t.from_t = 'nuevo'), 0)::integer
    from base b join base bp on bp.cut = b.cut - 7
  ),
  tramos(tramo, ord) as (
    values ('t1', 1), ('t2', 2), ('t3', 3), ('t4', 4), ('t5', 5)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'cut_date', b.cut,
    'people_total', b.pop_n,
    'people', jsonb_build_object('al_dia', b.pop_n - b.late_n) || (
      select jsonb_object_agg(t.tramo, coalesce(k.people, 0))
      from tramos t left join counts k on k.cut = b.cut and k.tramo = t.tramo
    ),
    -- PAYABLE: la deuda vencida y sin pagar en el corte, por tramo.
    'overdue_usd', (
      select jsonb_object_agg(t.tramo, coalesce(k.usd, 0))
      from tramos t left join counts k on k.cut = b.cut and k.tramo = t.tramo
    ),
    'transitions', coalesce((
      select jsonb_agg(jsonb_build_object('from', f.from_t, 'to', f.to_t, 'people', f.people)
                       order by array_position(array['nuevo','al_dia','t1','t2','t3','t4','t5'], f.from_t),
                                array_position(array['al_dia','t1','t2','t3','t4','t5'], f.to_t))
      from flows f
      where f.cut = b.cut and f.people > 0
    ), '[]'::jsonb),
    -- De los que estaban en el tramo el lunes anterior, cuántos están al día.
    'cure', (
      select jsonb_object_agg(t.tramo, jsonb_build_object(
        'from_people', coalesce(kp.people, 0),
        'cured', coalesce(fc.people, 0),
        'pct', case when coalesce(kp.people, 0) > 0
                    then round(100.0 * coalesce(fc.people, 0) / kp.people, 1) end
      ))
      from tramos t
      left join counts kp on kp.cut = b.cut - 7 and kp.tramo = t.tramo
      left join flows fc on fc.cut = b.cut and fc.from_t = t.tramo and fc.to_t = 'al_dia'
    )
  ) order by b.cut), '[]'::jsonb)
    into v_weeks_out
  from base b
  where b.cut > v_first;

  return jsonb_build_object(
    'business_date', v_today,
    'weeks_requested', v_weeks,
    'tramos', public.helios_tramos_de_atraso(),
    'weeks', v_weeks_out
  );
end;
$$;

revoke all on function public.admin_collection_flow(integer) from public, anon;
grant execute on function public.admin_collection_flow(integer) to authenticated;
