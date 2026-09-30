-- ============================================================================
-- Ronda — La cobranza tiene sus definiciones (esquema `metricas`, COBRANZA)
--
-- Lo que la cobranza cuenta de la cartera, escrito una vez y leído por todas
-- las RPC que lo enseñan (Métricas › Cobranza y riesgo, Por cobrar, el paso
-- entre tramos, los deudores por comportamiento):
--
--   metricas.cobranza_tramos_al(dia, local)   cada persona con cuotas al
--                                             cierre de un día, con su tramo
--                                             de atraso y lo vencido.
--   metricas.cobranza_impago(local)           lo dado por perdido sobre lo
--                                             financiado, y el punto de empate.
--   metricas.perfil_deudor_umbrales()         los umbrales de los perfiles.
--   metricas.perfil_deudor()                  una fila por persona con deuda,
--                                             con sus rasgos, su perfil, su
--                                             prioridad y su motivo.
--   metricas.cobranza_recuperacion_por_perfil(local)
--                                             cuánto se recuperó de la gente
--                                             de cada perfil, en la historia.
--
-- Todo se apoya en `metricas.cuotas` / `metricas.cuotas_al` (CIMIENTOS): una
-- cuota vencida es `estado_hoy = 'vencida'` (sin pagar, no perdida y con el
-- vencimiento pasado), y lo dado por perdido va aparte. Las personas, siempre
-- desde las cuotas.
--
-- Dinero: lo vencido es PAYABLE (lo que se paga, con el servicio y su IVA) y
-- va SIEMPRE con su desglose (`*_financed_usd` + `*_fee_usd`). Nunca un total
-- con el servicio sumado sin decir de qué está hecho.
--
-- Como el resto del esquema: `language sql`, sin `security definer` ni `set`,
-- para que el planificador las meta en la consulta que las llama. Sin acceso
-- para anon/authenticated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El tramo de atraso de cada persona al cierre de un día
-- ---------------------------------------------------------------------------

create or replace function metricas.cobranza_tramos_al(p_dia date, p_merchant_id uuid default null)
returns table (
  user_id              uuid,
  tramo                text,
  dias_atraso          integer,
  cuotas_vencidas      integer,
  vencido_payable_usd  numeric,
  vencido_financed_usd numeric,
  vencido_fee_usd      numeric,
  dia_de_referencia    date
)
language sql
stable
as $$
  select
    q.user_id,
    -- El tramo lo decide la cuota MÁS atrasada: a quien debe una de hace
    -- cinco días y otra de hace cuarenta se la llama por la de cuarenta.
    public.helios_tramo_de_atraso(
      max(q.dias_atraso) filter (where q.estado_hoy = 'vencida'),
      t.gracia, t.intervalo, t.baja, t.expulsion),
    coalesce(max(q.dias_atraso) filter (where q.estado_hoy = 'vencida'), 0)::integer,
    (count(*) filter (where q.estado_hoy = 'vencida'))::integer,
    coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'vencida'), 0)::numeric,
    coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'vencida'), 0)::numeric,
    coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'vencida'), 0)::numeric,
    max(q.dia_de_referencia)
  from metricas.cuotas_al(p_dia) q
  cross join (
    select public.helios_late_fee_grace_days()       as gracia,
           public.helios_installment_interval_days() as intervalo,
           public.helios_mora_demotion_days()        as baja,
           public.helios_mora_expulsion_days()       as expulsion
  ) t
  where p_merchant_id is null or q.merchant_id = p_merchant_id
  group by q.user_id, t.gracia, t.intervalo, t.baja, t.expulsion;
$$;

comment on function metricas.cobranza_tramos_al(date, uuid) is
  'Una fila por persona con alguna cuota al cierre de p_dia (la población de la cartera en ese corte; con p_merchant_id, las cuotas de ese local). tramo = helios_tramo_de_atraso de su cuota vencida más atrasada (al_dia si no tiene nada vencido); los cortes son late_fee_grace_days, installment_interval_days, mora_demotion_days y mora_expulsion_days, los mismos de Por cobrar. vencido_* = sus cuotas con estado vencida (sin lo dado por perdido), PAYABLE con su desglose. La mora por tramo, el paso entre tramos y el tramo de un deudor salen de aquí.';

-- ---------------------------------------------------------------------------
-- 2. El impago: lo dado por perdido sobre lo financiado
-- ---------------------------------------------------------------------------

create or replace function metricas.cobranza_impago(p_merchant_id uuid default null)
returns table (
  perdido_payable_usd  numeric,
  perdido_financed_usd numeric,
  perdido_fee_usd      numeric,
  personas_perdidas    integer,
  financiado_usd       numeric,
  impago_pct           numeric,
  empate_pct           numeric
)
language sql
stable
as $$
  select
    coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'perdida'), 0)::numeric,
    coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)::numeric,
    coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'perdida'), 0)::numeric,
    (count(distinct q.user_id) filter (where q.estado_hoy = 'perdida'))::integer,
    coalesce(sum(q.financed_usd), 0)::numeric,
    case when coalesce(sum(q.financed_usd), 0) > 0
         then round(100 * coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'perdida'), 0)
                        / sum(q.financed_usd), 2)
    end,
    -- El impago con el que Ronda ni gana ni pierde: gana el servicio y, si
    -- alguien no paga, pierde el neto que ya le pagó al local. Empatan en
    -- servicio / (servicio + neto). El IVA no entra: se cobra y se remite.
    (select case when coalesce(sum(k.neto_local_usd + k.servicio_usd), 0) > 0
                 then round(100 * sum(k.servicio_usd) / sum(k.neto_local_usd + k.servicio_usd), 2)
            end
       from metricas.consumos k
      where p_merchant_id is null or k.merchant_id = p_merchant_id)
  from metricas.cuotas q
  where p_merchant_id is null or q.merchant_id = p_merchant_id;
$$;

comment on function metricas.cobranza_impago(uuid) is
  'El impago desde el primer día: consumo dado por perdido ÷ todo el consumo financiado (financed sobre financed, sin el servicio), y el punto de empate (servicio sin IVA ÷ (servicio + neto al local)). Es la cifra `bad_debt.rate_financed_pct` / `break_even_pct` de admin_overview. Lo perdido también en payable con su desglose.';

-- ---------------------------------------------------------------------------
-- 3. Deudores por comportamiento: los umbrales
-- ---------------------------------------------------------------------------
-- Los del contrato de la orquesta (CONTRATOS §8). No se pudieron calibrar con
-- producción: el 27-09 ninguna persona tenía todavía historia de pago con
-- atraso (la primera cuota venció el 26-09). Viven en un solo sitio para
-- moverlos cuando la haya.

create or replace function metricas.perfil_deudor_umbrales()
returns table (
  promesa_rota_dias         integer,
  sin_respuesta_gestiones   integer,
  sin_respuesta_dias_atraso integer,
  sin_respuesta_horas       integer,
  reincidente_tarde         integer,
  se_le_paso_dias           integer,
  se_le_paso_pct            numeric,
  vigilar_dias              integer,
  vigilar_pct_tarde         numeric,
  vigilar_min_pagadas       integer,
  recuperacion_dias         integer
)
language sql
immutable
as $$
  select
    14,   -- Promesa rota: rompió una promesa en los últimos 14 días.
    2,    -- Sin respuesta: al menos 2 gestiones sin pago ni promesa…
    7,    -- …y más de 7 días de atraso.
    72,   -- Una gestión «tiene respuesta» si hay un pago reportado en 72 h (la
          -- misma ventana que la efectividad de la gestión).
    2,    -- Reincidente: al menos 2 cuotas pagadas tarde antes.
    3,    -- Se le pasó: como mucho 3 días de atraso…
    80,   -- …y al menos el 80 % de sus cuotas pagadas a tiempo.
    3,    -- Vigilar: le vence una cuota en 3 días o menos…
    50,   -- …y pagó tarde al menos la mitad de sus cuotas…
    2,    -- …con al menos 2 cuotas pagadas (con una sola no hay costumbre).
    30;   -- Recuperación histórica: lo cobrado en los 30 días siguientes.
$$;

comment on function metricas.perfil_deudor_umbrales() is
  'Los umbrales de los perfiles de deudor (CONTRATOS §8), en un solo sitio. Sin calibrar con producción: el 27-09 nadie tenía historia de pago con atraso.';

-- ---------------------------------------------------------------------------
-- 4. Dos ayudas de texto para los motivos
-- ---------------------------------------------------------------------------

create or replace function metricas.cobranza_dia_corto(d date)
returns text
language sql
immutable
as $$
  select extract(day from d)::integer::text || ' '
         || (array['ene', 'feb', 'mar', 'abr', 'may', 'jun',
                   'jul', 'ago', 'sep', 'oct', 'nov', 'dic'])[extract(month from d)::integer];
$$;

comment on function metricas.cobranza_dia_corto(date) is
  '«24 sep»: un día en los motivos de los deudores.';

create or replace function metricas.cobranza_cuantos(n numeric, uno text, varios text)
returns text
language sql
immutable
as $$
  select n::text || ' ' || case when n = 1 then uno else varios end;
$$;

comment on function metricas.cobranza_cuantos(numeric, text, text) is
  '«1 día», «3 días»: un número con su palabra en singular o en plural.';

-- ---------------------------------------------------------------------------
-- 5. Deudores por comportamiento: una fila por persona con deuda
-- ---------------------------------------------------------------------------

create or replace function metricas.perfil_deudor()
returns table (
  user_id                   uuid,
  perfil                    text,
  prioridad                 text,
  orden                     integer,
  motivo                    text,
  vencido_payable_usd       numeric,
  vencido_financed_usd      numeric,
  vencido_fee_usd           numeric,
  cuotas_vencidas           integer,
  dias_atraso               integer,
  tramo                     text,
  vencida_desde             date,
  por_vencer_payable_usd    numeric,
  por_vencer_financed_usd   numeric,
  por_vencer_fee_usd        numeric,
  proximo_vencimiento       date,
  cuotas_pagadas            integer,
  pagadas_a_tiempo          integer,
  pagadas_tarde             integer,
  atraso_medio_al_pagar     numeric,
  promesas_hechas           integer,
  promesas_cumplidas        integer,
  promesas_rotas            integer,
  ultima_promesa_rota       date,
  gestiones                 integer,
  gestiones_sin_respuesta   integer,
  ultima_gestion_en         timestamptz,
  dias_desde_ultima_gestion integer,
  reportes_rechazados       integer,
  primer_consumo_dia        date,
  antiguedad_dias           integer,
  tiene_push                boolean
)
language sql
stable
as $$
  with
  u as (select * from metricas.perfil_deudor_umbrales()),
  h as (select metricas.hoy() as hoy),
  -- Su tramo y lo vencido: la definición de la cartera, no otra.
  tr as (select * from metricas.cobranza_tramos_al(metricas.hoy())),
  -- Lo que debe y cómo ha pagado, cuota a cuota.
  hist as (
    select
      q.user_id,
      min(q.due_date) filter (where q.estado_hoy = 'vencida')                   as vencida_desde,
      coalesce(sum(q.payable_usd)  filter (where q.estado_hoy = 'por_vencer'), 0) as pv_payable,
      coalesce(sum(q.financed_usd) filter (where q.estado_hoy = 'por_vencer'), 0) as pv_financed,
      coalesce(sum(q.fee_usd)      filter (where q.estado_hoy = 'por_vencer'), 0) as pv_fee,
      min(q.due_date) filter (where q.estado_hoy = 'por_vencer')                as proximo,
      (count(*) filter (where q.status = 'paid'))::integer                       as pagadas,
      (count(*) filter (where q.estado_hoy = 'a_tiempo'))::integer               as a_tiempo,
      (count(*) filter (where q.estado_hoy = 'tarde'))::integer                  as tarde,
      round(avg(q.dias_atraso) filter (where q.status = 'paid'), 1)              as atraso_medio,
      min(q.business_date)                                                       as primer
    from metricas.cuotas q
    group by q.user_id
    -- Con deuda: algo vencido o algo por vencer. Lo dado por perdido no.
    having count(*) filter (where q.estado_hoy in ('vencida', 'por_vencer')) > 0
  ),
  -- Sus gestiones y sus promesas.
  gest as (
    select
      c.user_id,
      count(*)::integer                                            as gestiones,
      max(c.contacted_at)                                          as ultima,
      (count(*) filter (where c.promise_date is not null))::integer as promesas,
      (count(*) filter (where s.estado = 'cumplida'))::integer     as cumplidas,
      (count(*) filter (where s.estado = 'rota'))::integer         as rotas,
      max(c.promise_date) filter (
        where s.estado = 'rota' and c.promise_date >= h.hoy - u.promesa_rota_dias) as rota_reciente,
      -- Gestiones desde que le venció lo más viejo, sin promesa y sin un pago
      -- reportado en las horas siguientes: nadie contestó con nada.
      (count(*) filter (
         where x.vencida_desde is not null
           and public.helios_business_date(c.contacted_at) >= x.vencida_desde
           and c.promise_date is null
           and not exists (
             select 1 from public.payment_reports pr
             where pr.user_id = c.user_id
               and pr.status not in ('rejected', 'duplicate')
               and pr.created_at > c.contacted_at
               and pr.created_at <= c.contacted_at + make_interval(hours => u.sin_respuesta_horas))
      ))::integer                                                  as sin_respuesta
    from public.collection_contacts c
    join hist x on x.user_id = c.user_id
    cross join h
    cross join u
    cross join lateral (
      select public.helios_promise_status(c.user_id, c.contacted_at, c.promise_date, h.hoy) as estado
    ) s
    group by c.user_id
  ),
  rechazos as (
    select pr.user_id, count(*)::integer as n
    from public.payment_reports pr
    join hist x on x.user_id = pr.user_id
    where pr.status = 'rejected'
    group by pr.user_id
  ),
  base as (
    select
      x.user_id,
      coalesce(t.vencido_payable_usd, 0)  as v_payable,
      coalesce(t.vencido_financed_usd, 0) as v_financed,
      coalesce(t.vencido_fee_usd, 0)      as v_fee,
      coalesce(t.cuotas_vencidas, 0)      as v_cuotas,
      coalesce(t.dias_atraso, 0)          as dias,
      coalesce(t.tramo, 'al_dia')         as tramo,
      x.vencida_desde,
      x.pv_payable, x.pv_financed, x.pv_fee, x.proximo,
      x.pagadas, x.a_tiempo, x.tarde, x.atraso_medio, x.primer,
      coalesce(g.promesas, 0)      as promesas,
      coalesce(g.cumplidas, 0)     as cumplidas,
      coalesce(g.rotas, 0)         as rotas,
      g.rota_reciente,
      coalesce(g.gestiones, 0)     as gestiones,
      coalesce(g.sin_respuesta, 0) as sin_respuesta,
      g.ultima,
      coalesce(r.n, 0)             as rechazados,
      exists (select 1 from public.push_tokens pt
              where pt.user_id = x.user_id and pt.disabled_at is null) as push,
      h.hoy,
      u.*
    from hist x
    left join tr t   on t.user_id = x.user_id
    left join gest g on g.user_id = x.user_id
    left join rechazos r on r.user_id = x.user_id
    cross join h
    cross join u
  ),
  -- Los perfiles son excluyentes: gana el primero que encaja.
  perfilada as (
    select
      b.*,
      case
        when b.v_cuotas > 0 and b.pagadas = 0 then 'nunca_ha_pagado'
        when b.v_cuotas > 0 and b.rota_reciente is not null then 'promesa_rota'
        when b.v_cuotas > 0 and b.sin_respuesta >= b.sin_respuesta_gestiones
                            and b.dias > b.sin_respuesta_dias_atraso then 'sin_respuesta'
        when b.v_cuotas > 0 and b.tarde >= b.reincidente_tarde then 'reincidente'
        when b.v_cuotas > 0 and b.dias <= b.se_le_paso_dias
                            and b.a_tiempo * 100 >= b.se_le_paso_pct * b.pagadas then 'se_le_paso'
        when b.v_cuotas > 0 then 'paga_tarde_pero_paga'
        -- Sin estar en mora: le vence algo muy pronto y suele pagar tarde.
        when b.proximo is not null and b.proximo <= b.hoy + b.vigilar_dias
             and b.pagadas >= b.vigilar_min_pagadas
             and b.tarde * 100 >= b.vigilar_pct_tarde * b.pagadas then 'vigilar'
      end as perfil
    from base b
  ),
  priorizada as (
    select
      p.*,
      case p.perfil
        when 'nunca_ha_pagado'      then 'alta'
        when 'promesa_rota'         then 'alta'
        when 'sin_respuesta'        then 'alta'
        when 'reincidente'          then 'media'
        when 'paga_tarde_pero_paga' then 'media'
        when 'se_le_paso'           then 'baja'
        when 'vigilar'              then 'baja'
      end as prioridad,
      -- El orden de la cola: la prioridad, el perfil dentro de ella, y a
      -- igualdad, el más atrasado y el que más debe. Vigilar va al final:
      -- todavía no debe nada.
      case p.perfil
        when 'nunca_ha_pagado'      then 1
        when 'promesa_rota'         then 2
        when 'sin_respuesta'        then 3
        when 'reincidente'          then 4
        when 'paga_tarde_pero_paga' then 5
        when 'se_le_paso'           then 6
        when 'vigilar'              then 7
      end as rango
    from perfilada p
  )
  select
    p.user_id,
    p.perfil,
    p.prioridad,
    case when p.perfil is not null then
      (row_number() over (
         partition by (p.perfil is null)
         order by p.rango, p.dias desc, p.v_payable desc, p.proximo, p.user_id))::integer
    end,
    -- Una línea con cifras. Sin importes: lo vencido va en su columna, con su
    -- desglose (la regla del servicio).
    case p.perfil
      when 'nunca_ha_pagado' then
        'No ha pagado ninguna cuota y lleva '
        || metricas.cobranza_cuantos(p.dias, 'día', 'días') || ' de atraso'
      when 'promesa_rota' then
        'Prometió pagar el ' || metricas.cobranza_dia_corto(p.rota_reciente)
        || ' y no pagó; lleva ' || metricas.cobranza_cuantos(p.dias, 'día', 'días') || ' de atraso'
      when 'sin_respuesta' then
        metricas.cobranza_cuantos(p.sin_respuesta, 'gestión', 'gestiones')
        || ' sin pago ni promesa; lleva ' || metricas.cobranza_cuantos(p.dias, 'día', 'días') || ' de atraso'
      when 'reincidente' then
        'Pagó tarde ' || p.tarde || ' de ' || metricas.cobranza_cuantos(p.pagadas, 'cuota', 'cuotas')
        || ' y vuelve a deber desde hace ' || metricas.cobranza_cuantos(p.dias, 'día', 'días')
      when 'se_le_paso' then
        'Pagó a tiempo ' || p.a_tiempo || ' de ' || metricas.cobranza_cuantos(p.pagadas, 'cuota', 'cuotas')
        || '; lleva ' || metricas.cobranza_cuantos(p.dias, 'día', 'días') || ' de atraso'
      when 'paga_tarde_pero_paga' then
        'Ha pagado ' || metricas.cobranza_cuantos(p.pagadas, 'cuota', 'cuotas')
        || case when p.tarde > 0 then ' (' || p.tarde || ' tarde)' else '' end
        || '; ahora lleva ' || metricas.cobranza_cuantos(p.dias, 'día', 'días') || ' de atraso'
      when 'vigilar' then
        'Le vence una cuota el ' || metricas.cobranza_dia_corto(p.proximo)
        || ' y pagó tarde ' || p.tarde || ' de ' || metricas.cobranza_cuantos(p.pagadas, 'cuota', 'cuotas')
    end,
    p.v_payable, p.v_financed, p.v_fee,
    p.v_cuotas,
    p.dias,
    p.tramo,
    p.vencida_desde,
    p.pv_payable, p.pv_financed, p.pv_fee,
    p.proximo,
    p.pagadas, p.a_tiempo, p.tarde,
    p.atraso_medio,
    p.promesas, p.cumplidas, p.rotas,
    p.rota_reciente,
    p.gestiones,
    p.sin_respuesta,
    p.ultima,
    case when p.ultima is not null then p.hoy - public.helios_business_date(p.ultima) end,
    p.rechazados,
    p.primer,
    p.hoy - p.primer,
    p.push
  from priorizada p;
$$;

comment on function metricas.perfil_deudor() is
  'Deudores por comportamiento (CONTRATOS §8). Una fila por persona con deuda (algo vencido o por vencer; lo dado por perdido no cuenta), con sus rasgos y su perfil. Perfiles excluyentes, gana el primero: nunca_ha_pagado (ninguna cuota pagada y alguna vencida; alta), promesa_rota (rompió una promesa en los últimos 14 días; alta), sin_respuesta (≥2 gestiones desde que venció sin promesa ni pago reportado en 72 h y >7 días de atraso; alta), reincidente (≥2 cuotas pagadas tarde y algo vencido; media), se_le_paso (≤3 días de atraso y ≥80 % a tiempo; baja), paga_tarde_pero_paga (el resto con algo vencido; media). Sin estar en mora: vigilar (le vence una cuota en ≤3 días, ≥2 pagadas y ≥50 % tarde; baja). perfil nulo = con deuda pero sin perfil (al día y sin señal). orden = el orden de la cola de cobro. Umbrales en metricas.perfil_deudor_umbrales(). Global: el perfil de una persona es el mismo en todos los locales.';

-- ---------------------------------------------------------------------------
-- 6. Cuánto se recuperó, en la historia, de la gente de cada perfil
-- ---------------------------------------------------------------------------
-- Un «episodio» es un momento en que alguien encajaba en un perfil; se mira
-- qué parte de lo que debía entonces pagó en los `recuperacion_dias`
-- siguientes. Solo entran los episodios con ese plazo ya cumplido.
--
--   * nunca_ha_pagado, reincidente, se_le_paso, paga_tarde_pero_paga: cada
--     cuota que llegó a vencerse, con el perfil que daba su historia de pago
--     de ANTES de vencer (las cuotas que ya había pagado ese día).
--   * promesa_rota: la primera promesa rota de cada persona; lo que debía
--     vencido al acabar el día prometido.
--   * sin_respuesta: el día de su N-ésima gestión sin promesa ni pago, si ese
--     día llevaba más de 7 días de atraso; lo que debía vencido ese día.

create or replace function metricas.cobranza_recuperacion_por_perfil(p_merchant_id uuid default null)
returns table (
  perfil                  text,
  episodios               integer,
  personas                integer,
  vencido_payable_usd     numeric,
  vencido_financed_usd    numeric,
  vencido_fee_usd         numeric,
  recuperado_payable_usd  numeric,
  recuperado_financed_usd numeric,
  recuperado_fee_usd      numeric,
  recuperado_pct          numeric,
  dias                    integer
)
language sql
stable
as $$
  with
  u as (select * from metricas.perfil_deudor_umbrales()),
  h as (select metricas.hoy() as hoy),
  todas as materialized (
    select q.user_id, q.installment_id, q.merchant_id, q.due_date, q.status,
           q.pagada_dia, q.estado_hoy, q.payable_usd, q.financed_usd, q.fee_usd
    from metricas.cuotas q
  ),
  -- 1. Cuotas que llegaron a vencerse, con su historia de antes.
  ep_cuota as (
    select
      c.user_id, c.installment_id, c.merchant_id, c.payable_usd, c.financed_usd, c.fee_usd,
      (c.status = 'paid' and c.pagada_dia <= c.due_date + u.recuperacion_dias) as recuperada,
      count(p.installment_id)                                  as antes_pagadas,
      count(p.installment_id) filter (where p.estado_hoy = 'a_tiempo') as antes_a_tiempo,
      count(p.installment_id) filter (where p.estado_hoy = 'tarde')    as antes_tarde,
      u.reincidente_tarde, u.se_le_paso_pct
    from todas c
    cross join u
    cross join h
    left join todas p
      on p.user_id = c.user_id
     and p.installment_id <> c.installment_id
     and p.status = 'paid'
     and p.pagada_dia <= c.due_date
    where c.due_date + u.recuperacion_dias < h.hoy
      -- Llegó a vencerse: sigue sin pagar (vencida o perdida) o se pagó
      -- después del día en que vencía.
      and (c.status = 'pending' or c.pagada_dia > c.due_date)
    group by c.user_id, c.installment_id, c.merchant_id, c.payable_usd, c.financed_usd,
             c.fee_usd, c.status, c.pagada_dia, c.due_date, u.recuperacion_dias,
             u.reincidente_tarde, u.se_le_paso_pct
  ),
  cuota_perfilada as (
    select
      case
        when e.antes_pagadas = 0 then 'nunca_ha_pagado'
        when e.antes_tarde >= e.reincidente_tarde then 'reincidente'
        when e.antes_a_tiempo * 100 >= e.se_le_paso_pct * e.antes_pagadas then 'se_le_paso'
        else 'paga_tarde_pero_paga'
      end as perfil,
      e.user_id, e.installment_id, e.merchant_id, e.payable_usd, e.financed_usd, e.fee_usd, e.recuperada
    from ep_cuota e
  ),
  -- 2. La primera promesa rota de cada persona.
  rota as (
    select distinct on (c.user_id) c.user_id, c.promise_date
    from public.collection_contacts c
    cross join u
    cross join h
    where c.promise_date is not null
      and c.promise_date + u.recuperacion_dias < h.hoy
      and public.helios_promise_status(c.user_id, c.contacted_at, c.promise_date, h.hoy) = 'rota'
    order by c.user_id, c.promise_date, c.contacted_at
  ),
  ep_rota as (
    select 'promesa_rota'::text as perfil, t.user_id, t.installment_id, t.merchant_id,
           t.payable_usd, t.financed_usd, t.fee_usd,
           (t.status = 'paid' and t.pagada_dia <= r.promise_date + u.recuperacion_dias) as recuperada
    from rota r
    cross join u
    join todas t on t.user_id = r.user_id
    where t.due_date <= r.promise_date
      and (t.status = 'pending' or t.pagada_dia > r.promise_date)
  ),
  -- 3. El día de la N-ésima gestión sin respuesta de cada persona.
  sin_resp as (
    select x.user_id, x.dia
    from (
      select c.user_id,
             public.helios_business_date(c.contacted_at) as dia,
             row_number() over (partition by c.user_id order by c.contacted_at) as n
      from public.collection_contacts c
      cross join u
      where c.promise_date is null
        and not exists (
          select 1 from public.payment_reports pr
          where pr.user_id = c.user_id
            and pr.status not in ('rejected', 'duplicate')
            and pr.created_at > c.contacted_at
            and pr.created_at <= c.contacted_at + make_interval(hours => u.sin_respuesta_horas))
    ) x
    cross join u
    where x.n = u.sin_respuesta_gestiones
  ),
  ep_sin_resp_base as (
    select s.user_id, s.dia, t.installment_id, t.merchant_id, t.due_date,
           t.payable_usd, t.financed_usd, t.fee_usd,
           (t.status = 'paid' and t.pagada_dia <= s.dia + u.recuperacion_dias) as recuperada
    from sin_resp s
    cross join u
    cross join h
    join todas t on t.user_id = s.user_id
    where s.dia + u.recuperacion_dias < h.hoy
      -- Vencida ese día: venció antes y no estaba pagada al empezar el día.
      and t.due_date < s.dia
      and (t.status = 'pending' or t.pagada_dia >= s.dia)
  ),
  ep_sin_resp as (
    select 'sin_respuesta'::text as perfil, b.user_id, b.installment_id, b.merchant_id,
           b.payable_usd, b.financed_usd, b.fee_usd, b.recuperada
    from ep_sin_resp_base b
    -- Ese día llevaba más de `sin_respuesta_dias_atraso` de atraso (el día es
    -- uno solo por persona: el de su N-ésima gestión).
    where b.user_id in (
      select e.user_id from ep_sin_resp_base e cross join u
      group by e.user_id, u.sin_respuesta_dias_atraso
      having max(e.dia - e.due_date) > u.sin_respuesta_dias_atraso)
  ),
  episodios as (
    select perfil, user_id, installment_id, merchant_id, payable_usd, financed_usd, fee_usd, recuperada
    from cuota_perfilada
    union all
    select perfil, user_id, installment_id, merchant_id, payable_usd, financed_usd, fee_usd, recuperada
    from ep_rota
    union all
    select perfil, user_id, installment_id, merchant_id, payable_usd, financed_usd, fee_usd, recuperada
    from ep_sin_resp
  ),
  perfiles(perfil, orden) as (
    values ('nunca_ha_pagado', 1), ('promesa_rota', 2), ('sin_respuesta', 3),
           ('reincidente', 4), ('paga_tarde_pero_paga', 5), ('se_le_paso', 6)
  )
  select
    f.perfil,
    count(e.installment_id)::integer,
    count(distinct e.user_id)::integer,
    coalesce(sum(e.payable_usd), 0)::numeric,
    coalesce(sum(e.financed_usd), 0)::numeric,
    coalesce(sum(e.fee_usd), 0)::numeric,
    coalesce(sum(e.payable_usd)  filter (where e.recuperada), 0)::numeric,
    coalesce(sum(e.financed_usd) filter (where e.recuperada), 0)::numeric,
    coalesce(sum(e.fee_usd)      filter (where e.recuperada), 0)::numeric,
    case when coalesce(sum(e.payable_usd), 0) > 0
         then round(100 * coalesce(sum(e.payable_usd) filter (where e.recuperada), 0)
                        / sum(e.payable_usd), 1)
    end,
    (select recuperacion_dias from u)
  from perfiles f
  left join episodios e
    on e.perfil = f.perfil
   and (p_merchant_id is null or e.merchant_id = p_merchant_id)
  group by f.perfil, f.orden
  order by f.orden;
$$;

comment on function metricas.cobranza_recuperacion_por_perfil(uuid) is
  'Cuánto se recuperó en la historia de la gente de cada perfil de deudor: de lo que debía vencido en cada episodio, la parte pagada en los recuperacion_dias (30) siguientes. Episodios: cada cuota que llegó a vencerse, con el perfil que daba su historia de pago de antes de vencer (nunca_ha_pagado, reincidente, se_le_paso, paga_tarde_pero_paga); la primera promesa rota de cada persona (promesa_rota); el día de su 2.ª gestión sin promesa ni pago con más de 7 días de atraso (sin_respuesta). Solo episodios con el plazo cumplido. PAYABLE con desglose; recuperado_pct sobre payable. Con p_merchant_id, las cuotas de ese local.';

-- ---------------------------------------------------------------------------
-- 7. Permisos (como el resto del esquema)
-- ---------------------------------------------------------------------------

revoke all on function metricas.cobranza_tramos_al(date, uuid) from public, anon, authenticated;
revoke all on function metricas.cobranza_impago(uuid) from public, anon, authenticated;
revoke all on function metricas.perfil_deudor_umbrales() from public, anon, authenticated;
revoke all on function metricas.cobranza_dia_corto(date) from public, anon, authenticated;
revoke all on function metricas.cobranza_cuantos(numeric, text, text) from public, anon, authenticated;
revoke all on function metricas.perfil_deudor() from public, anon, authenticated;
revoke all on function metricas.cobranza_recuperacion_por_perfil(uuid) from public, anon, authenticated;
