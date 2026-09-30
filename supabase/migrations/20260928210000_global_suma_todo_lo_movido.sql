-- ============================================================================
-- Ronda — Global suma todo lo movido
--
-- Pedido de Javier (28-09): en Métricas › Global, una cifra con el monto
-- total movido desde el primer día, consumo + service fee, sin importar si se
-- cobró o no. Es la suma de TODAS las cuotas de los consumos confirmados
-- (metricas.cuotas): pagadas, por pagar y dadas por perdidas. Cuadra por
-- construcción con lo cobrado + lo por cobrar + lo perdido de la misma
-- respuesta, y su consumo (financed) es el mismo que el de 'consumo'.
--
-- admin_metricas_general gana dinero.movido {payable_usd, financed_usd,
-- fee_usd, cuotas, consumos}. Copia exacta de 20260927591000 salvo eso.
-- ============================================================================

create or replace function public.admin_metricas_general(p_merchant_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_hoy        date    := metricas.hoy();
  -- «Activos» es haber consumido en los últimos 30 días operativos, hoy
  -- incluido: la misma ventana que `admin_overview(30)`.
  v_ventana    integer := 30;
  v_gracia     integer := public.helios_on_time_grace_days();
  -- Lo que tarda un consumo en tener su impago definitivo: la última cuota
  -- vence y recorre la escalera entera (la «temporada» de las cosechas).
  v_temporada  integer := 2 * public.helios_installment_interval_days()
                        + public.helios_mora_expulsion_days();
  v_todos      boolean := p_merchant_id is null;
  v_desde      date;
  v_k          record;
  v_q          record;
  v_p          record;
  v_s          record;
  v_c          record;
  v_l          record;
  v_cartera    record;
  v_repiten    integer;
  v_caja       numeric;
  v_curva      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  -- ── Los consumos ──────────────────────────────────────────────────────────
  select
    coalesce(sum(k.financed_usd), 0)                                   as financed,
    count(*)::integer                                                  as consumos,
    coalesce(sum(k.servicio_usd), 0)                                   as servicio,
    coalesce(sum(k.iva_usd), 0)                                        as iva,
    min(k.business_date)                                               as primero,
    count(distinct k.merchant_id)::integer                             as locales,
    (count(distinct k.merchant_id) filter (
       where k.business_date between v_hoy - (v_ventana - 1) and v_hoy))::integer as locales_ventana,
    -- El impago con el que Ronda ni gana ni pierde, como en admin_overview:
    -- servicio ÷ (neto transferido al local + servicio). El IVA no entra.
    case when coalesce(sum(k.neto_local_usd + k.servicio_usd), 0) > 0
         then round(100 * sum(k.servicio_usd) / sum(k.neto_local_usd + k.servicio_usd), 2)
    end                                                                as empate,
    -- El consumo cuya cosecha ya terminó su ciclo de cobro.
    coalesce(sum(k.financed_usd) filter (where k.business_date + v_temporada <= v_hoy), 0) as maduro
  into v_k
  from metricas.consumos k
  where v_todos or k.merchant_id = p_merchant_id;

  -- ── Las cuotas: las personas, lo cobrado, lo perdido y el cobro a tiempo ──
  select
    count(distinct q.user_id)::integer                                 as personas,
    (count(distinct q.user_id) filter (
       where q.business_date between v_hoy - (v_ventana - 1) and v_hoy))::integer as activos,
    coalesce(sum(q.payable_usd)  filter (where q.status = 'paid'), 0)  as cobrado_payable,
    coalesce(sum(q.financed_usd) filter (where q.status = 'paid'), 0)  as cobrado_financed,
    coalesce(sum(q.fee_usd)      filter (where q.status = 'paid'), 0)  as cobrado_fee,
    (count(*) filter (where q.status = 'paid'))::integer               as cobrado_cuotas,
    -- Todo lo movido: todas las cuotas de los consumos confirmados, pagadas,
    -- por pagar o dadas por perdidas. Es lo cobrado + lo por cobrar + lo perdido.
    coalesce(sum(q.payable_usd), 0)                                    as movido_payable,
    coalesce(sum(q.fee_usd), 0)                                        as movido_fee,
    count(*)::integer                                                  as movido_cuotas,
    coalesce(sum(q.financed_usd), 0)                                   as financiado,
    (count(distinct q.user_id) filter (where q.estado_hoy = 'perdida'))::integer as perdido_personas,
    (count(distinct q.user_id) filter (where q.estado_hoy in ('vencida', 'por_vencer')))::integer as deben_personas,
    (count(*) filter (where q.estado_hoy in ('vencida', 'por_vencer')))::integer as vivas_cuotas,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 1))::integer as juzgadas_1,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 1 and q.estado_hoy = 'a_tiempo'))::integer as a_tiempo_1,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 2))::integer as juzgadas_2,
    (count(*) filter (where q.plazo_cerrado and q.sequence = 2 and q.estado_hoy = 'a_tiempo'))::integer as a_tiempo_2
  into v_q
  from metricas.cuotas q
  where v_todos or q.merchant_id = p_merchant_id;

  -- Repiten: personas con cuota en dos noches distintas o más (en ese local,
  -- si hay local: son sus `personas_por_local.noches`).
  select count(*)::integer into v_repiten
  from (
    select q.user_id
    from metricas.cuotas q
    where v_todos or q.merchant_id = p_merchant_id
    group by q.user_id
    having count(distinct q.business_date) >= 2
  ) r;

  -- ── La cartera de hoy: por cobrar, vencido, perdido y la mora ────────────
  select * into v_cartera from metricas.cartera_al(v_hoy, p_merchant_id);

  -- ── Los cargos por atraso: ingreso aparte, sin IVA ────────────────────────
  select
    coalesce(sum(a.amount_usd), 0)                                     as devengado,
    coalesce(sum(a.amount_usd) filter (where a.status = 'paid'), 0)    as cobrado,
    count(*)::integer                                                  as cargos
  into v_c
  from metricas.cargos_por_atraso a
  where v_todos or a.merchant_id = p_merchant_id;

  -- ── Lo que se les debe a los locales, como en Pagos a locales ────────────
  -- La lista de `admin_merchant_payables` y la suma sin los locales de
  -- prueba, que es lo que pinta Caja (`payablesTotals`).
  select
    coalesce(sum((x->>'total_pending_usd')::numeric), 0)               as total,
    coalesce(sum((x->>'overdue_usd')::numeric), 0)                     as atrasado,
    (count(*) filter (where (x->>'total_pending_usd')::numeric > 0))::integer as locales
  into v_l
  from jsonb_array_elements(coalesce(public.admin_merchant_payables(), '[]'::jsonb)) x
  where coalesce((x->>'is_test')::boolean, false) = false
    and (v_todos or (x->>'merchant_id')::uuid = p_merchant_id);

  -- ── Lo que no es de ningún local ──────────────────────────────────────────
  -- Con local la consulta no lee nada (`where v_todos`) y sus cifras salen
  -- como null más abajo; se hace igual para que `v_p` siempre tenga forma.
  select
    count(*)::integer                                                  as registros,
    (count(*) filter (where p.verificado))::integer                    as verificados,
    (count(*) filter (where p.primer_consumo_dia is not null))::integer as han_comprado
  into v_p
  from metricas.personas p
  where v_todos;

  -- Quien pidió el código, se verificara o no (la boca del embudo), y quien
  -- además lo metió. No son registros; tampoco son de ningún local.
  select
    count(*)::integer                                                  as solicitaron,
    (count(*) filter (where s.etapa <> 'solicito_el_codigo'))::integer as telefono_confirmado
  into v_s
  from metricas.solicitudes s
  where v_todos;

  if v_todos then
    -- La caja del libro, la misma que Caja y el Resumen.
    v_caja := (public.admin_cash_position() ->> 'cash')::numeric;
    -- La primera solicitud del código o el primer consumo: el mismo «desde el
    -- inicio» que Métricas › Gente.
    v_desde := metricas.gente_primer_dia();
  else
    v_desde := v_k.primero;
  end if;

  -- ── La curva: semana a semana y su acumulado ─────────────────────────────
  if v_desde is null then
    v_curva := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'semana',            c.semana,
             'registros',         case when v_todos then c.registros end,
             'registros_acum',    case when v_todos then c.registros_acum end,
             'consumos',          c.consumos,
             'financed_usd',      c.financed,
             'financed_acum_usd', c.financed_acum
           ) order by c.semana), '[]'::jsonb)
    into v_curva
    from (
      select
        s.semana,
        coalesce(r.n, 0)                                               as registros,
        sum(coalesce(r.n, 0)) over (order by s.semana)                 as registros_acum,
        coalesce(k.n, 0)                                               as consumos,
        coalesce(k.f, 0)                                               as financed,
        sum(coalesce(k.f, 0)) over (order by s.semana)                 as financed_acum
      from generate_series(metricas.lunes(v_desde), metricas.lunes(v_hoy), interval '7 days') g(d)
      cross join lateral (select g.d::date as semana) s
      left join (
        select p.registro_semana as semana, count(*)::integer as n
        from metricas.personas p
        where v_todos
        group by 1
      ) r on r.semana = s.semana
      left join (
        select k.semana, count(*)::integer as n, sum(k.financed_usd) as f
        from metricas.consumos k
        where v_todos or k.merchant_id = p_merchant_id
        group by 1
      ) k on k.semana = s.semana
    ) c;
  end if;

  return jsonb_build_object(
    'hoy',   v_hoy,
    'desde', v_desde,
    'local', p_merchant_id,
    'ventana_dias',   v_ventana,
    'gracia_dias',    v_gracia,
    'temporada_dias', v_temporada,

    'gente', jsonb_build_object(
      'solicitaron',         case when v_todos then v_s.solicitaron end,
      'telefono_confirmado', case when v_todos then v_s.telefono_confirmado end,
      -- Registros = personas verificadas; `verificados` es la misma cifra.
      'registros',        case when v_todos then v_p.registros end,
      'verificados',      case when v_todos then v_p.verificados end,
      'han_comprado',     case when v_todos then v_p.han_comprado end,
      'han_comprado_pct', case when v_todos and v_p.registros > 0
                               then round(100.0 * v_p.han_comprado / v_p.registros, 1) end,
      'activos',          v_q.activos,
      'repiten',          v_repiten
    ),

    'consumo', jsonb_build_object(
      'financed_usd',    v_k.financed,
      'consumos',        v_k.consumos,
      'ticket_usd',      case when v_k.consumos > 0 then round(v_k.financed / v_k.consumos, 2) end,
      'personas',        v_q.personas,
      'locales',         case when v_todos then v_k.locales end,
      'locales_activos', case when v_todos then v_k.locales_ventana end
    ),

    'dinero', jsonb_build_object(
      'movido', jsonb_build_object(
        'payable_usd',  v_q.movido_payable,
        'financed_usd', v_q.financiado,
        'fee_usd',      v_q.movido_fee,
        'cuotas',       v_q.movido_cuotas,
        'consumos',     v_k.consumos
      ),
      'por_cobrar', jsonb_build_object(
        'payable_usd',  v_cartera.vencido_payable_usd  + v_cartera.por_vencer_payable_usd,
        'financed_usd', v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
        'fee_usd',      v_cartera.vencido_fee_usd      + v_cartera.por_vencer_fee_usd,
        'cuotas',       v_q.vivas_cuotas,
        'personas',     v_q.deben_personas
      ),
      'vencido', jsonb_build_object(
        'payable_usd',  v_cartera.vencido_payable_usd,
        'financed_usd', v_cartera.vencido_financed_usd,
        'fee_usd',      v_cartera.vencido_fee_usd,
        'cuotas',       v_cartera.cuotas_vencidas,
        'personas',     v_cartera.personas_vencidas
      ),
      'cobrado', jsonb_build_object(
        'payable_usd',  v_q.cobrado_payable,
        'financed_usd', v_q.cobrado_financed,
        'fee_usd',      v_q.cobrado_fee,
        'cuotas',       v_q.cobrado_cuotas
      ),
      -- Lo que Ronda ha ganado, cada cosa en su cifra.
      'servicio_usd', v_k.servicio,
      'cargos_por_atraso', jsonb_build_object(
        'devengado_usd', v_c.devengado,
        'cobrado_usd',   v_c.cobrado,
        'cargos',        v_c.cargos
      ),
      'perdido', jsonb_build_object(
        'payable_usd',  v_cartera.perdido_payable_usd,
        'financed_usd', v_cartera.perdido_financed_usd,
        'fee_usd',      v_cartera.perdido_fee_usd,
        'personas',     v_q.perdido_personas
      ),
      'caja_usd', case when v_todos then v_caja end,
      'por_pagar_locales', jsonb_build_object(
        'total_usd',    v_l.total,
        'atrasado_usd', v_l.atrasado,
        'locales',      v_l.locales
      )
    ),

    'riesgo', jsonb_build_object(
      'mora_pct',    v_cartera.mora_pct,
      -- Consumo perdido y sin pagar sobre todo el consumo, como el impago de
      -- admin_overview. Nulo sin consumo.
      'impago_pct',  case when v_q.financiado > 0
                          then round(100 * v_cartera.perdido_financed_usd / v_q.financiado, 2) end,
      'empate_pct',  v_k.empate,
      'a_tiempo', jsonb_build_array(
        jsonb_build_object(
          'cuota', 1, 'juzgadas', v_q.juzgadas_1, 'a_tiempo', v_q.a_tiempo_1,
          'pct', case when v_q.juzgadas_1 > 0 then round(100.0 * v_q.a_tiempo_1 / v_q.juzgadas_1, 1) end
        ),
        jsonb_build_object(
          'cuota', 2, 'juzgadas', v_q.juzgadas_2, 'a_tiempo', v_q.a_tiempo_2,
          'pct', case when v_q.juzgadas_2 > 0 then round(100.0 * v_q.a_tiempo_2 / v_q.juzgadas_2, 1) end
        )
      )
    ),

    -- Por cada 100 € de consumo: los tres sumandos del margen, cada uno con
    -- su signo, y el consumo cuya cosecha ya está cerrada.
    'por_cada_100', jsonb_build_object(
      'financed_usd',        v_k.financed,
      'consumos',            v_k.consumos,
      'financed_maduro_usd', v_k.maduro,
      'servicio_usd',        v_k.servicio,
      'cargos_usd',          v_c.devengado,
      'perdido_usd',         v_cartera.perdido_financed_usd,
      'por_100', case when v_k.financed > 0 then jsonb_build_object(
        'servicio_usd', round(100 * v_k.servicio / v_k.financed, 2),
        'cargos_usd',   round(100 * v_c.devengado / v_k.financed, 2),
        'perdido_usd',  round(100 * v_cartera.perdido_financed_usd / v_k.financed, 2),
        'margen_usd',   round(100 * (v_k.servicio + v_c.devengado - v_cartera.perdido_financed_usd)
                              / v_k.financed, 2)
      ) end
    ),

    'curva', v_curva
  );
end;
$$;


comment on function public.admin_metricas_general(uuid) is
  'Métricas › General: lo global del negocio desde el primer día (dinero.movido: todo lo movido, consumo + service fee de todas las cuotas, cobradas o no; gente: quien pidió el código, quien lo metió, registros = personas verificadas, han comprado, activos, repiten; consumo, dinero, riesgo, por cada 100 € y la curva semanal acumulada), de todos los locales o de uno. Lee de metricas.*, de admin_cash_position (caja) y de admin_merchant_payables (por pagar a locales). Todo payable_usd va con financed_usd y fee_usd; lo que no se parte por local vale null.';

revoke all on function public.admin_metricas_general(uuid) from public, anon;
grant execute on function public.admin_metricas_general(uuid) to authenticated;
