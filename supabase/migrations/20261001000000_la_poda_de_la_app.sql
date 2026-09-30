-- ============================================================================
-- Helios — La poda de la app
--
-- Helios es Ronda sin la app (docs/00-PLAN-DE-IMPLEMENTACION §0). Las 354
-- migraciones anteriores a esta son las de Ronda, portadas con
-- `scripts/portar-de-ronda.mjs` (ronda_ → helios_) y reproducidas tal cual.
-- Esta migración quita todo lo que en Ronda solo existía para la app móvil o
-- para la vida nocturna (clase B, docs/00 §4.2):
--
--   · PIN y dispositivos       · KYC (Didit) y su esquema `kyc`
--   · push y promociones       · grupos / mesas y el tiempo real de facturar
--   · el cobro por QR          · Bits
--   · la app (versión, actividad, avatar, métodos de pago, términos
--     aceptados, eliminación de cuenta) y las RPC `my_*` de la persona
--   · el piloto de La Quinta (bóveda, lista de espera, QA)
--   · el catálogo de productos (Helios cobra montos libres, D-H4)
--   · las métricas de noches, KYC, push y «persona»
--
-- Reglas de la poda:
--
--   1. Todo `drop` va con RESTRICT, nunca CASCADE: si algo de la clase A
--      depende de algo que se va, la migración FALLA en vez de llevárselo en
--      silencio. Cada dependencia que apareció así está arreglada abajo con un
--      `create or replace` que la quita, marcado con «PODA (Helios)».
--   2. Las RPC que el panel sigue llamando conservan la FORMA de su respuesta:
--      una clave de algo podado se queda con null, 0 o [] en vez de
--      desaparecer.
--   3. Los valores de enum de la app (`pending_kyc`, `group_charge`,
--      `bits_earned`…) se quedan: quitar un valor de un enum no compensa.
--   4. Las COLUMNAS de tablas A que apuntaban a tablas B se quedan, sin su FK
--      e inertes (`charges.group_id`, `charges.group_name`,
--      `charge_items.product_id`, `notifications.campaign_id`,
--      `profiles.avatar_emoji`, `profiles.avatar_color`): quitarlas obligaría a
--      reescribir las lecturas de Ronda que las nombran, y portar arreglos de
--      Ronda es la razón de mantener los nombres. Como en docs/00 §4.4 (H8)
--      para `charge_items.product_id`.
--   5. No toca `auth.users` ni `handle_new_user`, ni las RPC con `auth.uid()`
--      como deudor (`quote_installments`, `report_payment`): eso es H3.
--
-- Verificación: supabase/poda/verificar.sql (plpgsql_check en cero errores y
-- ninguna vista rota). Notas de cada desviación: supabase/poda/NOTAS.md.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Los trabajos de cron de la clase B
-- ─────────────────────────────────────────────────────────────────────────────
-- Se quedan: la tasa (y su reintento), la mora, las liquidaciones, los avisos
-- de cuota (se recablean en H7), la purga del registro del cron y la foto de
-- la proyección de caja.

select cron.unschedule(j.jobname)
from cron.job j
where j.jobname in (
  'helios_push_dispatch',        -- despacho de la cola de push (Expo)
  'helios_push_receipts',        -- acuses de Expo
  'helios_push_purge',           -- purga de la cola de push
  'helios_kyc_expire_stuck',     -- barrido de verificaciones de Didit
  'helios_expire_stale_charges'  -- QR que caducan sin que nadie los reclame
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Lo que se queda y dependía de algo que se va
-- ─────────────────────────────────────────────────────────────────────────────
-- Cada función es la de Ronda tal cual, salvo los trozos marcados con
-- «PODA (Helios)».

-- metricas.perfil_deudor: leía `push_tokens` (¿tiene el push activo?).
CREATE OR REPLACE FUNCTION metricas.perfil_deudor()
 RETURNS TABLE(user_id uuid, perfil text, prioridad text, orden integer, motivo text, vencido_payable_usd numeric, vencido_financed_usd numeric, vencido_fee_usd numeric, cuotas_vencidas integer, dias_atraso integer, tramo text, vencida_desde date, por_vencer_payable_usd numeric, por_vencer_financed_usd numeric, por_vencer_fee_usd numeric, proximo_vencimiento date, cuotas_pagadas integer, pagadas_a_tiempo integer, pagadas_tarde integer, atraso_medio_al_pagar numeric, promesas_hechas integer, promesas_cumplidas integer, promesas_rotas integer, ultima_promesa_rota date, gestiones integer, gestiones_sin_respuesta integer, ultima_gestion_en timestamp with time zone, dias_desde_ultima_gestion integer, reportes_rechazados integer, primer_consumo_dia date, antiguedad_dias integer, tiene_push boolean)
 LANGUAGE sql
 STABLE
AS $function$
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
      -- PODA (Helios): «tiene el push activo» (`push_tokens`). Sin app, nunca.
      false as push,
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
$function$;

-- metricas.rasgos_de_personas: leía `kyc.verifications`, `user_devices` y `push_tokens`.
CREATE OR REPLACE FUNCTION metricas.rasgos_de_personas(p_users uuid[])
 RETURNS TABLE(user_id uuid, sexo text, edad integer, ciudad text, plataforma text, nivel integer, avisos_activos boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- PODA (Helios): en Ronda el sexo, la ciudad y la plataforma salían de la
  -- verificación de identidad (`kyc.verifications`: lo que leía Didit) y de
  -- los aparatos de la app (`user_devices`), y «avisos activos» del token de
  -- push (`push_tokens`). Nada de eso existe en Helios: queda lo que dice el
  -- perfil. H3 añade `sex` y `city` al perfil del paciente y esta función
  -- debería volver a leerlos de ahí.
  with u as (select distinct x as user_id from unnest(p_users) x where x is not null)
  select
    u.user_id,
    null::text,
    case
      when date_part('year', age(public.helios_caracas_date(now())::timestamp,
                                 p.birth_date::timestamp))::int between 18 and 99
      then date_part('year', age(public.helios_caracas_date(now())::timestamp,
                                 p.birth_date::timestamp))::int
    end,
    null::text,
    null::text,
    p.level::integer,
    false
  from u
  join public.profiles p on p.id = u.user_id;
$function$;

-- metricas.senales_deudor: leía `push_tokens`, `user_devices`, `app_activity` y `push_deliveries`.
CREATE OR REPLACE FUNCTION metricas.senales_deudor(p_users uuid[])
 RETURNS TABLE(user_id uuid, senales jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with
  u as (select distinct x as user_id from unnest(p_users) x where x is not null),
  hoy as (select public.helios_business_date(now()) as dia),
  -- Desde cuándo debe algo vencido: su cuota pendiente más vieja ya vencida
  -- (sin lo dado por perdido). Los avisos se cuentan desde ese día.
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
  -- PODA (Helios): aquí iban las señales de la app —el token de push
  -- (`push_tokens`), los aparatos (`user_devices`), los gestos
  -- (`app_activity`) y los avisos entregados (`push_deliveries`)—. Sin app no
  -- existen; las claves se quedan con su valor de «sin dato».
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
      'ultima_apertura',   null::timestamptz,
      'avisos',            'nunca',
      'avisos_motivo',     null::text,
      'gestos_desde',      null::timestamptz,
      'entro_a_pagar',     null::timestamptz,
      'copio_datos',       null::timestamptz,
      'abrio_aviso',       null::timestamptz,
      'vencida_desde',     vence.desde,
      'avisos_entregados', 0,
      'avisos_abiertos',   0,
      'ultimo_reporte',    case when rep.user_id is not null then jsonb_build_object(
                             'estado',      rep.estado,
                             'en',          rep.created_at,
                             'revisado_en', rep.reviewed_at,
                             'nota',        rep.rejection_note) end,
      'en_revision_desde', rev.desde
    )
  from u
  left join vence      on vence.user_id      = u.user_id
  left join rep        on rep.user_id        = u.user_id
  left join rev        on rev.user_id        = u.user_id;
$function$;

-- public.admin_charge_detail: leía `groups`, `group_members` y `min_share_usd()`.
CREATE OR REPLACE FUNCTION public.admin_charge_detail(p_charge_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today    date := public.helios_business_date(now());
  v_charge   public.charges%rowtype;
  v_financed numeric(18,4);
  v_payers   integer;
  v_out      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  -- La cuenta del local. `base_usd` es null en los cobros anteriores a
  -- 20260830190000, cuando el fee todavía no se desglosaba: entonces el total
  -- ERA la cuenta, y eso es lo que dice el respaldo.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  select count(distinct i.user_id) into v_payers
  from public.installments i where i.charge_id = p_charge_id;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    -- Las dos clases de cifra, y nunca una suma de las dos. `amount_usd` lleva
    -- el fee dentro; `financed_usd` es lo que ocupó cupo. Quien las sume
    -- cuenta el servicio dos veces.
    'amount_usd', c.amount_usd,
    'financed_usd', v_financed,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', c.merchant_fee_usd,
    'merchant_fee_vat_usd', c.merchant_fee_vat_usd,
    'merchant_net_usd', c.merchant_net_usd,
    'is_group', c.group_id is not null,
    'group_id', c.group_id,
    'is_test', c.is_test,
    -- Con qué se reclama: el rótulo no basta, hace falta la razón social y el
    -- RIF de la empresa que cobró.
    'merchant', jsonb_build_object(
      'id', m.id, 'name', m.name, 'legal_name', m.legal_name, 'tax_id', m.tax_id
    ),
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    -- Quien puso la cuenta. En un grupo no es «el que debe»: es el que la
    -- inició, y el resto del reparto va en `split`.
    'user', case when p.id is null then null else jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone_e164', p.phone_e164
    ) end
  )
  into v_out
  from public.charges c
  join public.merchants m on m.id = c.merchant_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  -- Qué se consumió, en el orden en que lo tecleó el cajero.
  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Las cuotas, cada una con su dueño. `days_overdue` solo cuenta mientras se
  -- deba: una pagada con retraso no sigue atrasándose, y una castigada ya no
  -- se cobra.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'user_id', i.user_id,
      'full_name', pi.full_name,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status::text,
      'paid_at', i.paid_at,
      'written_off_at', i.written_off_at,
      'days_overdue', case
        when i.status = 'paid' or i.written_off_at is not null then 0
        else greatest(v_today - i.due_date, 0)
      end
    ) order by pi.full_name nulls last, i.user_id, i.sequence)
    from public.installments i
    left join public.profiles pi on pi.id = i.user_id
    where i.charge_id = p_charge_id
  ), '[]'::jsonb));

  /**
   * EL REPARTO DEL DÉBITO: quién se llevó cuánto de esta cuenta.
   *
   * Sale de las cuotas agrupadas por persona, que es donde el servidor lo
   * escribió. `financed_usd` de las partes suma la cuenta del local y
   * `payable_usd` suma el total del cargo — si alguna vez no cuadraran, es que
   * el asiento no cuadra.
   *
   * Los integrantes del grupo a los que no les tocó nada salen con las cifras
   * en null y su motivo cuando consta, para que la lista sea la mesa entera y
   * no solo los que pagaron.
   */
  v_out := v_out || jsonb_build_object('split', coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', x.user_id,
      'full_name', pr.full_name,
      'phone_e164', pr.phone_e164,
      'financed_usd', x.financed_usd,
      'payable_usd', x.payable_usd,
      'installments_paid', x.paid,
      'installments_total', x.total,
      'started_it', x.user_id = v_charge.user_id,
      -- PODA (Helios): el motivo 'too_small' era el mínimo por persona de un
      -- grupo (`min_share_usd`). Sin grupos, nadie queda fuera del reparto.
      'reason', null
    ) order by x.payable_usd desc nulls last, pr.full_name nulls last)
    from (
      select i.user_id,
             sum(i.financed_usd)                                  as financed_usd,
             sum(i.amount_usd)                                    as payable_usd,
             count(*) filter (where i.status = 'paid')::integer    as paid,
             count(*)::integer                                     as total
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.user_id
    ) x
    join public.profiles pr on pr.id = x.user_id
  ), '[]'::jsonb));

  -- PODA (Helios): el grupo y sus otras cuentas de esa noche. Sin grupos,
  -- la clave se queda (el panel la lee) y siempre vale null.
  v_out := v_out || jsonb_build_object('group', null::jsonb);

  return v_out;
end;
$function$;

-- public.admin_notification_catalog: leía `push_envelope()` y `push_deliveries`.
CREATE OR REPLACE FUNCTION public.admin_notification_catalog()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo para el equipo de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_order), '[]'::jsonb)
    into v_rows
  from (
    select
      t.key, t.type::text as type, t.label, t.trigger_label, t.help,
      t.variables, t.required_variables,
      t.default_title, t.default_body,
      t.title, t.body,
      t.draft_title, t.draft_body, t.draft_at,
      t.enabled, t.editable, t.can_disable,
      t.cron_job, t.lead_days, t.run_at, t.sort_order,
      t.published_at,
      pa.full_name as published_by,
      da.full_name as draft_by,

      -- PODA (Helios): el canal y la prioridad salían del sobre del push
      -- (`push_envelope`). Sin push, null; las claves se quedan (H7 las
      -- reemplaza por el canal de `outbound_messages`).
      null::text as channel,
      null::text as priority,

      -- Los últimos 30 días.
      (select count(*) from public.notifications n
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days') as sent,
      (select count(*) from public.notifications n
        where n.template_key = t.key
          and n.created_at > now() - interval '30 days'
          and n.read_at is not null) as opened,
      -- PODA (Helios): entregados/fallidos/cancelados eran estados de
      -- `push_deliveries`. Sin push, 0.
      0::bigint as delivered,
      0::bigint as failed,
      0::bigint as cancelled,
      (select max(n.created_at) from public.notifications n
        where n.template_key = t.key) as last_sent_at
    from public.notification_templates t
    left join public.platform_admins pa on pa.user_id = t.published_by
    left join public.platform_admins da on da.user_id = t.draft_by
  ) q;

  return v_rows;
end;
$function$;

-- public.admin_overview: leía `kyc.verifications` (embudo de KYC).
CREATE OR REPLACE FUNCTION public.admin_overview(p_days integer DEFAULT 30, p_merchant_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today     date    := metricas.hoy();
  v_days      integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_from      date;
  v_prev_from date;
  v_count     integer;
  v_openers   integer;
  v_fin       numeric;
  v_prev_fin  numeric;
  v_people    integer;
  v_cartera   record;
  v_impago    record;
  v_result    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from      := v_today - (v_days - 1);
  v_prev_from := v_from - v_days;

  -- El consumo de la ventana y de la anterior, sin el servicio de Ronda.
  select coalesce(sum(k.financed_usd) filter (where k.business_date >= v_from), 0),
         coalesce(sum(k.financed_usd) filter (where k.business_date <  v_from), 0),
         (count(*) filter (where k.business_date >= v_from))::integer,
         (count(distinct k.abrio_user_id) filter (where k.business_date >= v_from))::integer
    into v_fin, v_prev_fin, v_count, v_openers
  from metricas.consumos k
  where k.business_date between v_prev_from and v_today
    and (p_merchant_id is null or k.merchant_id = p_merchant_id);

  -- La gente: todos los que tienen cuota, no quien abrió la cuenta.
  select count(distinct q.user_id)::integer into v_people
  from metricas.cuotas q
  where q.business_date between v_from and v_today
    and (p_merchant_id is null or q.merchant_id = p_merchant_id);

  v_result := jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'merchant_id',   p_merchant_id,
    'volume', jsonb_build_object(
      'financed_usd',   v_fin,
      'previous_usd',   v_prev_fin,
      'charge_count',   v_count,
      'active_users',   v_people,
      'avg_ticket_usd', case when v_count > 0 then round(v_fin / v_count, 2) else 0 end,
      'financed_volume_usd',          v_fin,
      'previous_financed_volume_usd', v_prev_fin,
      'financed_change_pct', case when v_prev_fin > 0
        then round(100 * (v_fin - v_prev_fin) / v_prev_fin, 1) else null end,
      'avg_ticket_financed_usd', case when v_count > 0 then round(v_fin / v_count, 2) else null end,
      'active_people',   v_people,
      -- Quien abrió la cuenta. En un consumo de grupo pagan más.
      'account_openers', v_openers
    )
  );

  -- La mora. Sobre lo que todavía se puede cobrar: lo dado por perdido tiene
  -- su cifra aparte.
  select * into v_cartera from metricas.cartera_al(v_today, p_merchant_id);

  v_result := v_result || jsonb_build_object('arrears', (
    select jsonb_build_object(
      'open_usd',             v_cartera.vencido_payable_usd + v_cartera.por_vencer_payable_usd,
      'open_financed_usd',    v_cartera.vencido_financed_usd + v_cartera.por_vencer_financed_usd,
      'open_fee_usd',         v_cartera.vencido_fee_usd + v_cartera.por_vencer_fee_usd,
      'overdue_usd',          v_cartera.vencido_payable_usd,
      'overdue_financed_usd', v_cartera.vencido_financed_usd,
      'overdue_fee_usd',      v_cartera.vencido_fee_usd,
      'overdue_users',        v_cartera.personas_vencidas,
      'due_today_usd',        coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'por_vencer' and q.due_date = v_today), 0),
      'rate_pct',             coalesce(v_cartera.mora_pct, 0),
      'demotion_days',        public.helios_mora_demotion_days(),
      'expulsion_days',       public.helios_mora_expulsion_days(),
      'bucket_frozen_usd',    coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso <= public.helios_mora_demotion_days()), 0),
      'bucket_demotion_usd',  coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_demotion_days()
                                   and q.dias_atraso <= public.helios_mora_expulsion_days()), 0),
      'bucket_expulsion_usd', coalesce(sum(q.payable_usd) filter (
                                 where q.estado_hoy = 'vencida'
                                   and q.dias_atraso >  public.helios_mora_expulsion_days()), 0)
    )
    from metricas.cuotas q
    where q.estado_hoy in ('vencida', 'por_vencer')
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ));

  -- Impago: lo dado por perdido, en consumo, sobre TODO lo financiado en la
  -- historia (lo que se pierde hoy nació hace meses). La tasa y el punto de
  -- empate salen de metricas.cobranza_impago, la misma función que Cobranza.
  select * into v_impago from metricas.cobranza_impago(p_merchant_id);

  v_result := v_result || jsonb_build_object('bad_debt', (
    select jsonb_build_object(
      'written_off_usd',          v_impago.perdido_financed_usd,
      'written_off_users',        v_impago.personas_perdidas,
      'financed_usd',             v_impago.financiado_usd,
      'window_usd',               coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_pct',                 coalesce(v_impago.impago_pct, 0),
      'written_off_financed_usd', v_impago.perdido_financed_usd,
      'lifetime_financed_usd',    v_impago.financiado_usd,
      'window_financed_usd',      coalesce(sum(q.financed_usd) filter (
                                     where q.estado_hoy = 'perdida'
                                       and public.helios_business_date(q.written_off_at) between v_from and v_today), 0),
      'rate_financed_pct',        v_impago.impago_pct,
      'written_off_debt_usd',     v_impago.perdido_payable_usd,
      'written_off_fee_usd',      v_impago.perdido_fee_usd,
      'break_even_pct',           v_impago.empate_pct
    )
    from metricas.cuotas q
    where q.estado_hoy = 'perdida'
      and (p_merchant_id is null or q.merchant_id = p_merchant_id)
  ));

  -- Los registros (personas verificadas) por estado y, aparte, quien pidió
  -- el código sin llegar a registrarse. Nada de esto es de un local.
  v_result := v_result || jsonb_build_object('users', case when p_merchant_id is null then (
    select jsonb_build_object(
      'total',         count(*),
      'pending_kyc',   count(*) filter (where p.estado in ('pending_kyc', 'pending_pin')),
      'active',        count(*) filter (where p.estado = 'active'),
      'frozen',        count(*) filter (where p.estado = 'frozen'),
      'suspended',     count(*) filter (where p.estado = 'suspended'),
      'expelled',      count(*) filter (where p.estado = 'expelled'),
      'blacklisted',   count(*) filter (where pr.is_blacklisted),
      'new_in_window', count(*) filter (where p.registro_dia between v_from and v_today),
      -- Pidieron el código y nunca lo metieron.
      'unconfirmed_phone', (
        select count(*) from metricas.solicitudes s where s.etapa = 'solicito_el_codigo'
      ),
      -- Todos los que pidieron el código, se verificaran o no, y los de la
      -- ventana. Los registros (`total`) son una parte de ellos.
      'requested_otp', (select count(*) from metricas.solicitudes s),
      'requested_otp_in_window', (
        select count(*) from metricas.solicitudes s
        where s.solicito_dia between v_from and v_today
      ),
      -- Metieron el código (estén o no verificados).
      'phone_confirmed', (
        select count(*) from metricas.solicitudes s where s.etapa <> 'solicito_el_codigo'
      ),
      -- Pidieron el código y no son registros.
      'not_verified', (
        select count(*) from metricas.solicitudes s where s.etapa <> 'verificado'
      )
    )
    from metricas.personas p
    join public.profiles pr on pr.id = p.user_id
  ) end);

  -- PODA (Helios): el embudo de KYC (`kyc.verifications`) se fue con el KYC.
  -- La clave se queda en null para no cambiar la forma de la respuesta.
  v_result := v_result || jsonb_build_object('kyc', null::jsonb);

  -- Colas de trabajo. Lo que se le debe al local sí se parte; los pagos por
  -- revisar son de personas, no de locales.
  v_result := v_result || jsonb_build_object('queues', jsonb_build_object(
    'payments_to_reconcile', case when p_merchant_id is null then (
      select count(*) from public.payment_reports r
      where r.status in ('reported', 'in_review')
        and not public.helios_is_test_user(r.user_id)
    ) end,
    'merchant_payouts_due', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial') and s.due_date <= v_today
        and not public.helios_is_test_merchant(s.merchant_id)
        and (p_merchant_id is null or s.merchant_id = p_merchant_id)
    ),
    'merchant_payouts_pending', (
      select coalesce(sum(s.amount_usd - s.paid_usd), 0) from public.settlements s
      where s.status in ('pending', 'partial')
        and not public.helios_is_test_merchant(s.merchant_id)
        and (p_merchant_id is null or s.merchant_id = p_merchant_id)
    )
  ));

  v_result := v_result || jsonb_build_object('merchants', case when p_merchant_id is null then (
    select jsonb_build_object(
      'total',      count(*),
      'active',     count(*) filter (where m.status = 'active'),
      'paused',     count(*) filter (where m.status = 'paused'),
      'terminated', count(*) filter (where m.status = 'terminated'),
      'selling_in_window', (
        select count(distinct k.merchant_id) from metricas.consumos k
        where k.business_date between v_from and v_today
      )
    )
    from public.merchants m
    where not m.is_test
  ) end);

  -- Tasa BCV: vale igual para cualquier local.
  v_result := v_result || jsonb_build_object('fx', (
    select jsonb_build_object(
      'rate',           e.rate,
      'effective_date', e.effective_date,
      'fetched_at',     e.fetched_at,
      'age_hours',      round(extract(epoch from (now() - e.fetched_at)) / 3600.0, 1),
      'stale',          (now() - e.fetched_at) > interval '48 hours'
    )
    from public.exchange_rates e
    order by e.effective_date desc limit 1
  ));

  -- La caja es de Ronda, no de un local.
  v_result := v_result || jsonb_build_object('cash',
    case when p_merchant_id is null then public.admin_cash_position() end);

  return v_result;
end;
$function$;

-- public.admin_related_accounts: leía `user_devices` y `kyc.verifications`.
CREATE OR REPLACE FUNCTION public.admin_related_accounts(p_user_id uuid)
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

  select coalesce(jsonb_agg(to_jsonb(q) order by q.peso desc, q.created_at), '[]'::jsonb)
  into v_rows
  from (
    select
      p.id                    as user_id,
      p.full_name,
      p.phone_e164,
      p.document_number,
      p.status::text          as status,
      p.is_blacklisted,
      p.is_test,
      p.created_at,
      r.motivos,
      -- Para ordenar: el dispositivo compartido pesa más que el nombre.
      (case when 'dispositivo' = any(r.motivos) then 4 else 0 end)
      + (case when 'cedula' = any(r.motivos) then 3 else 0 end)
      + (case when 'nombre' = any(r.motivos) then 1 else 0 end) as peso
    from (
      select
        c.other as uid,
        array_agg(distinct c.motivo) as motivos
      from (
        -- PODA (Helios): aquí iba «mismo teléfono físico» (`user_devices`), la
        -- señal de la app. Sin app no hay dispositivo.
        --
        -- Misma cédula. Si coincide, es la misma persona dos veces.
        select p2.id as other, 'cedula'::text as motivo
        from public.profiles p1
        join public.profiles p2
          on p2.document_number is not null
         and p2.document_number = p1.document_number
         and p2.id <> p1.id
        where p1.id = p_user_id

        union all

        -- PODA (Helios): aquí iba la cédula leída por el KYC
        -- (`kyc.verifications`). Sin KYC, la cédula es la del perfil.

        -- Mismo nombre. Solo cuenta acompañado: dos "José García" sueltos no
        -- son nada, y solos llenarían la lista de ruido.
        select p2.id, 'nombre'::text
        from public.profiles p1
        join public.profiles p2
          on p2.full_name is not null
         and lower(trim(p2.full_name)) = lower(trim(p1.full_name))
         and p2.id <> p1.id
        where p1.id = p_user_id and p1.full_name is not null
      ) c
      group by c.other
    ) r
    join public.profiles p on p.id = r.uid
    -- El nombre a secas no basta: tiene que venir con algo más.
    where r.motivos <> array['nombre']::text[]
  ) q;

  return v_rows;
end;
$function$;

-- public.admin_report_merchant_payout: saldaba contra la bóveda (`helios_settle_from_vault`, `ledger.merchant_prepaid_balance`).
CREATE OR REPLACE FUNCTION public.admin_report_merchant_payout(p_merchant_id uuid, p_settlement_ids uuid[], p_method text, p_reference text DEFAULT NULL::text, p_amount_ves numeric DEFAULT NULL::numeric, p_fx_rate numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_amount_usd numeric DEFAULT NULL::numeric, p_paid_on date DEFAULT NULL::date, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor       uuid := auth.uid();
  v_pendiente   numeric(18,4);
  v_total       numeric(18,4);
  v_restante    numeric(18,4);
  v_aplicado    numeric(18,4);
  v_count       integer;
  v_bdate       date;
  v_paid_on     date;
  v_payout      public.merchant_payouts%rowtype;
  v_tx          uuid;
  v_acct_pay    uuid;
  v_acct_cash   uuid;
  v_fx          numeric;
  v_ves         numeric;
  v_fila        record;
  -- El motivo que pide el panel. Recortado, y vacío es null: una nota en
  -- blanco no dice nada y no debe salir en la bitácora como si dijera algo.
  v_note        text := nullif(trim(coalesce(p_note, '')), '');
begin
  -- Registrar un pago mueve la caja del libro: es del super admin.
  perform public.helios_assert_super_admin('registrar pagos a comercios');

  -- PODA (Helios): el método 'boveda' (saldar contra la garantía del piloto)
  -- y el freno de «garantía sin gastar» se fueron con la bóveda.
  if p_method = 'boveda' then
    raise exception 'Helios no tiene bóveda: registra la transferencia' using errcode = '22023';
  end if;

  if p_settlement_ids is null or array_length(p_settlement_ids, 1) is null then
    raise exception 'Selecciona al menos una liquidación' using errcode = '22023';
  end if;

  -- Se bloquean las filas antes de sumar: dos operadores pagando el mismo
  -- comercio a la vez no pueden liquidar dos veces lo mismo.
  perform 1 from public.settlements
  where id = any(p_settlement_ids) for update;

  select coalesce(sum(amount_usd - paid_usd), 0), count(*)
    into v_pendiente, v_count
  from public.settlements
  where id = any(p_settlement_ids)
    and merchant_id = p_merchant_id
    and status in ('pending', 'partial');

  if v_count <> array_length(p_settlement_ids, 1) then
    raise exception 'Alguna liquidación no es de este comercio o ya está pagada entera'
      using errcode = '22023';
  end if;

  -- Sin importe se paga todo lo marcado, que es el caso normal.
  v_total := coalesce(p_amount_usd, v_pendiente);

  if v_total <= 0 then
    raise exception 'El importe tiene que ser mayor que cero' using errcode = '22023';
  end if;

  -- Hacia arriba no: pagar de más no es un pago parcial al revés, es un error
  -- de tecleo que dejaría el libro con caja negativa contra ese comercio.
  if v_total > v_pendiente + 0.005 then
    raise exception 'No puedes registrar % cuando lo marcado suma %',
      v_total, v_pendiente using errcode = '22023';
  end if;

  v_bdate   := public.helios_business_date(now());
  v_paid_on := coalesce(p_paid_on, v_bdate);

  -- Una fecha de pago en el futuro es siempre un error de tecleo.
  if v_paid_on > v_bdate then
    raise exception 'La fecha del pago no puede ser posterior a hoy' using errcode = '22023';
  end if;

  -- La conversión, si toca. `current_fx_rate()` puede devolver null si la
  -- ingesta lleva días rota: en ese caso se guarda null, en vez de inventar
  -- una tasa. El aviso de tasa vieja del panel es lo que tiene que sonar ahí.
  if p_method in ('pago_movil', 'transferencia') then
    v_fx  := coalesce(p_fx_rate, public.current_fx_rate('BCV', v_paid_on));
    v_ves := coalesce(p_amount_ves, round(v_total * v_fx, 2));
  else
    v_fx  := p_fx_rate;
    v_ves := p_amount_ves;
  end if;

  insert into public.merchant_payouts
    (merchant_id, amount_usd, amount_ves, fx_rate, method, reference, note,
     paid_by, business_date, paid_on, receipt_path)
  values
    (p_merchant_id, v_total, v_ves, v_fx, p_method, p_reference, v_note,
     v_actor, v_bdate, v_paid_on, nullif(trim(coalesce(p_receipt_path, '')), ''))
  returning * into v_payout;

  -- El reparto: de la más antigua a la más nueva. La última que alcanza queda
  -- parcial con su resto y sigue apareciendo en el cierre.
  v_restante := v_total;

  for v_fila in
    select id, amount_usd, paid_usd, due_date
    from public.settlements
    where id = any(p_settlement_ids)
    order by due_date, id
  loop
    exit when v_restante <= 0;

    v_aplicado := least(v_restante, v_fila.amount_usd - v_fila.paid_usd);
    if v_aplicado <= 0 then
      continue;
    end if;

    update public.settlements
    set paid_usd = paid_usd + v_aplicado,
        status = case
          when paid_usd + v_aplicado >= amount_usd - 0.005 then 'paid'::public.settlement_status
          else 'partial'::public.settlement_status
        end
    where id = v_fila.id;

    insert into public.merchant_payout_items (payout_id, settlement_id, amount_usd)
    values (v_payout.id, v_fila.id, v_aplicado);

    v_restante := v_restante - v_aplicado;
  end loop;

  -- AHORA sí sale el dinero: es el momento en que de verdad salió del banco.
  v_acct_pay  := ledger.get_or_create_account('merchant_payable', p_merchant_id);
  v_acct_cash := ledger.get_or_create_account('cash', null);

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'merchant_settlement', 'payout:' || v_payout.id::text, v_bdate, v_payout.id,
    format('Pago al comercio (%s liquidaciones)', v_count)
  )
  returning id into v_tx;

  insert into ledger.entries (transaction_id, account_id, debit, credit) values
    (v_tx, v_acct_pay, v_total, 0),
    (v_tx, v_acct_cash, 0, v_total);

  perform audit.log(v_actor, 'merchant.payout', p_merchant_id,
    jsonb_build_object(
      'payout_id', v_payout.id, 'amount_usd', v_total,
      'pending_usd', v_pendiente,
      'partial', v_total < v_pendiente - 0.005,
      'settlements', v_count, 'method', p_method, 'reference', p_reference,
      'paid_on', v_paid_on, 'amount_ves', v_ves, 'fx_rate', v_fx,
      'has_receipt', p_receipt_path is not null,
      -- El motivo va con la transferencia: `note` es la clave que la bitácora
      -- del panel pinta como motivo.
      'note', v_note
    ));

  return jsonb_build_object(
    'ok', true, 'payout_id', v_payout.id,
    'amount_usd', v_total, 'pending_usd', v_pendiente, 'settlements', v_count,
    'amount_ves', v_ves, 'fx_rate', v_fx, 'paid_on', v_paid_on
  );
end;
$function$;

-- public.admin_reverse_charge: devolvía el techo de la mesa en `group_members`.
CREATE OR REPLACE FUNCTION public.admin_reverse_charge(p_charge_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'ledger', 'audit', 'pg_temp'
AS $function$
declare
  v_actor    uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_bdate    date := public.helios_business_date(now());
  v_financed numeric(18,4);
  v_payable  numeric(18,4);
  v_bloqueo  text;
  v_tx       uuid;
  v_origen   record;
  v_name     text;
  v_partes   jsonb;
  v_parte    record;
  v_n        integer;
begin
  -- Revertir mueve el libro hacia atrás: es del super admin.
  perform public.helios_assert_super_admin('revertir un consumo');

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Revertir un consumo requiere motivo' using errcode = '22023';
  end if;

  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  -- ── Las redes ───────────────────────────────────────────────────────────
  -- Las mismas que la ficha enseña antes de pulsar, con el mismo texto: las
  -- dos leen `helios_charge_reverse_blocker`. Van después del `for update`,
  -- con el consumo ya bloqueado.
  v_bloqueo := public.helios_charge_reverse_blocker(p_charge_id);
  if v_bloqueo is not null then
    raise exception '%', v_bloqueo using errcode = '22023';
  end if;

select full_name into v_name from public.profiles where id = v_charge.user_id;

  select
    coalesce(sum(financed_usd), 0),
    coalesce(sum(amount_usd), 0)
  into v_financed, v_payable
  from public.installments where charge_id = p_charge_id;

  -- Y las mismas dos cifras POR PERSONA, que es lo que de verdad hace falta
  -- para devolver algo. Se toman AQUÍ, antes de que el borrado de más abajo se
  -- lleve las cuotas por delante: después de él ya no hay dónde mirar quién
  -- puso cuánto.
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',  s.user_id,
           'financed', s.financed,
           'payable',  s.payable
         ) order by s.user_id), '[]'::jsonb)
  into v_partes
  from (
    select i.user_id,
           sum(i.financed_usd) as financed,
           sum(i.amount_usd)   as payable
    from public.installments i
    where i.charge_id = p_charge_id
    group by i.user_id
  ) s;

  v_n := jsonb_array_length(v_partes);

  -- ── 1. El asiento contrario ──────────────────────────────────────────────
  -- Se refleja lo que se escribió, pata por pata, en vez de recalcularlo: si
  -- el consumo se asentó con una comisión o un IVA distintos de los de hoy
  -- —porque los parámetros cambiaron— recalcular dejaría un residuo.

  insert into ledger.transactions (type, idempotency_key, business_date, reference_id, memo)
  values (
    'manual_adjustment',
    'reverse_charge:' || p_charge_id::text,
    v_bdate,
    p_charge_id,
    format('Consumo revertido: %s', trim(p_reason))
  )
  returning id into v_tx;

  for v_origen in
    select e.account_id, e.debit, e.credit
    from ledger.transactions t
    join ledger.entries e on e.transaction_id = t.id
    where t.reference_id = p_charge_id
      and t.type <> 'manual_adjustment'
  loop
    insert into ledger.entries (transaction_id, account_id, debit, credit)
    values (v_tx, v_origen.account_id, v_origen.credit, v_origen.debit);
  end loop;

  -- ── 2. Las cuotas ────────────────────────────────────────────────────────
  -- Se borran, no se marcan. Sin pagos detrás no dejan nada que auditar —lo
  -- que pasó está en el asiento y en la bitácora— y dejarlas con un estado
  -- nuevo obligaría a que las quince consultas que filtran por 'pending' se
  -- acordaran de excluirlo.

  -- Antes, las cotizaciones caducadas y sin reporte que tocan estas cuotas:
  -- su clave foránea impedía borrarlas. Ya no se pueden reportar
  -- (`report_payment` rechaza una caducada), así que no guardan nada. Se
  -- borran enteras, con sus líneas y cargos en cascada, aunque llevaran también
  -- cuotas de otro consumo: caducada, tampoco servía para pagar esas. Las
  -- vigentes ya frenaron arriba.
  delete from public.payment_quotes q
  where q.valid_until <= now()
    and not exists (select 1 from public.payment_reports r where r.quote_id = q.id)
    and exists (
      select 1
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id and i.charge_id = p_charge_id
    );

  delete from public.installments where charge_id = p_charge_id;

  -- ── 3. Las liquidaciones al local que no se han pagado ───────────────────

  delete from public.settlements
  where charge_id = p_charge_id and status = 'pending';

  -- ── 4. El cupo vuelve, a cada quien lo suyo ──────────────────────────────
  -- Exactamente lo contrario de lo que `helios_assign_debt` sumó al crear las
  -- cuotas: el financiado de esa persona sale de `charged_usd` y su fee —el
  -- pagadero menos el financiado— de `fee_usd`. Persona por persona, porque
  -- persona por persona se sumó.
  --
  -- El techo del grupo va en el mismo viaje. `group_members.spent_usd` es lo
  -- que esta mesa ya le cargó a cada quien esta noche, y nadie lo deshacía: un
  -- €500 tecleado en vez de €50 quemaba el techo de los cuatro y revertirlo no
  -- se lo devolvía, así que la mesa se quedaba sin sitio para el consumo bueno.
  -- Que es el caso para el que existe esta función.

  for v_parte in
    select (e->>'user_id')::uuid     as user_id,
           (e->>'financed')::numeric as financed,
           (e->>'payable')::numeric  as payable
    from jsonb_array_elements(v_partes) e
  loop
    update public.user_credit_blocks
    set charged_usd = greatest(charged_usd - v_parte.financed, 0),
        fee_usd     = greatest(fee_usd - (v_parte.payable - v_parte.financed), 0)
    where user_id = v_parte.user_id and closed_at is null;

    -- PODA (Helios): aquí se devolvía el techo de la mesa (`group_members`).
  end loop;

  -- ── 5. El consumo queda marcado ──────────────────────────────────────────

  update public.charges
  set status      = 'reverted',
      void_reason = trim(p_reason),
      voided_by   = v_actor,
      voided_at   = now()
  where id = p_charge_id;

  -- Cada quien tiene que enterarse: le desapareció una deuda y un cargo de su
  -- historial. Enterarse por sorpresa es peor que el error original.
  --
  -- TODOS los que debían, no solo quien puso la cuenta, y cada uno con SU
  -- parte: mandarle a alguien el total de la mesa es contarle mal lo que le
  -- acaba de pasar.
  for v_parte in
    select (e->>'user_id')::uuid    as user_id,
           (e->>'payable')::numeric as payable
    from jsonb_array_elements(v_partes) e
  loop
    perform public.notify(
      v_parte.user_id,
      'payment_reconciled',
      'Anulamos un consumo',
      case when v_n > 1 then
        format('Anulamos la cuenta del grupo. Tu parte de €%s ya no la debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      else
        format('Anulamos el consumo de €%s. Ya no lo debes y tu cupo vuelve a estar disponible.',
               to_char(v_parte.payable, 'FM999999990.00'))
      end
    );
  end loop;

  perform audit.log(v_actor, 'charge.reverted', p_charge_id, jsonb_build_object(
    'user_id', v_charge.user_id,
    'full_name', v_name,
    'merchant_id', v_charge.merchant_id,
    'amount_usd', v_charge.amount_usd,
    'financed_usd', v_financed,
    'payable_usd', v_payable,
    -- El reparto entero. Los totales no dicen a quién se le devolvió qué, y esa
    -- es justo la pregunta que se le hace a la bitácora cuando hay que revisar
    -- una reversión de grupo meses después.
    'debtors', v_n,
    'split', v_partes,
    'business_date', v_charge.business_date,
    'reason', trim(p_reason)
  ));

  return jsonb_build_object(
    'ok', true,
    'charge_id', p_charge_id,
    'amount_usd', v_charge.amount_usd,
    -- El total devuelto, y debajo a quién. Con un cargo de grupo el total solo
    -- no dice nada: son varios bloques de crédito los que se movieron.
    'credit_returned_usd', v_financed,
    'debtors', v_n,
    'split', v_partes
  );
end;
$function$;

-- public.admin_risk_alerts: leía `user_devices` y `kyc.verifications` (alertas de KYC y aparato).
CREATE OR REPLACE FUNCTION public.admin_risk_alerts(p_limit integer DEFAULT 200, p_kinds text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
declare
  v_today  date    := public.helios_business_date(now());
  v_limit  integer := greatest(least(coalesce(p_limit, 200), 1000), 1);
  v_window constant integer := 90;
  -- Antes de esta fecha los límites cambiaron por migración, sin bitácora.
  c_escalera constant date := date '2026-09-10';
  v_desde  date;
  v_out    jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_desde := greatest(v_today - (v_window - 1), c_escalera);

  with
  persona as (
    select p.id, p.full_name, p.status::text as status, p.created_at, p.is_test
    from public.profiles p
  ),

  -- 1. Cuentas relacionadas. Mismos cruces que `admin_related_accounts`,
  --    para todo el mundo a la vez.
  pares as (
    -- PODA (Helios): aquí iba «mismo teléfono físico» (`user_devices`).
    select p1.id as a, p2.id as b, 'cedula'::text as motivo,
           greatest(p1.created_at, p2.created_at) as desde
    from public.profiles p1
    join public.profiles p2
      on p2.document_number = p1.document_number and p2.id <> p1.id
    where p1.document_number is not null

    -- PODA (Helios): aquí iba la cédula leída por el KYC (`kyc.verifications`).

    union all
    -- El nombre solo cuenta acompañado de otra señal (el `having` de abajo).
    select p1.id, p2.id, 'nombre', greatest(p1.created_at, p2.created_at)
    from public.profiles p1
    join public.profiles p2
      on lower(trim(p2.full_name)) = lower(trim(p1.full_name)) and p2.id <> p1.id
    where p1.full_name is not null
  ),
  -- Una alerta por pareja, a nombre de la cuenta más nueva: es la que llegó a
  -- un sitio donde ya había alguien.
  relacion as (
    select
      pr.a as user_id,
      pr.b as otro_id,
      array_agg(distinct pr.motivo order by pr.motivo)      as motivos,
      min(pr.desde) filter (where pr.motivo <> 'nombre')    as desde
    from pares pr
    join persona pa on pa.id = pr.a and not pa.is_test
    join persona pb on pb.id = pr.b and not pb.is_test
    where (pa.created_at, pa.id) > (pb.created_at, pb.id)
    group by pr.a, pr.b
    having bool_or(pr.motivo <> 'nombre')
  ),

  -- 4. Consumo sobre el cupo. Cada deuda con cuándo se abrió y cuándo dejó
  --    de ocupar cupo (null: sigue ocupándolo).
  deuda as (
    select
      i.user_id,
      i.charge_id,
      min(i.created_at)                                          as abierta,
      sum(i.financed_usd)                                        as financiado,
      case when bool_and(i.status = 'paid') then max(i.paid_at) end as saldada
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where c.status = 'confirmed'
      and not c.is_test
      and not i.is_test
    group by i.user_id, i.charge_id
  ),
  sobre as (
    select
      d.*,
      coalesce((
        select sum(o.financiado) from deuda o
         where o.user_id = d.user_id
           and o.charge_id <> d.charge_id
           and o.abierta < d.abierta
           and (o.saldada is null or o.saldada > d.abierta)
      ), 0)                                                      as ocupado,
      exists (
        select 1 from public.installments j
         where j.user_id = d.user_id
           and j.charge_id <> d.charge_id
           and not j.is_test
           and j.created_at < d.abierta
           and j.due_date < public.helios_business_date(d.abierta)
           and (j.paid_at is null or j.paid_at > d.abierta)
      )                                                          as en_mora,
      coalesce(public.helios_level_at(d.user_id, d.abierta), p.level) as nivel
    from deuda d
    join public.profiles p on p.id = d.user_id
    where public.helios_business_date(d.abierta) >= v_desde
  ),
  sobre_con_limite as (
    select
      s.*,
      coalesce((
        -- El primer cambio de ese nivel DESPUÉS de la deuda dice qué límite
        -- había antes de él, que es el que regía al abrirse.
        select (a.detail -> 'before' ->> 'monthly_limit_usd')::numeric
          from audit.admin_actions a
         where a.action = 'level.configure'
           and (a.detail ->> 'level')::smallint = s.nivel
           and a.created_at > s.abierta
         order by a.created_at
         limit 1
      ), l.monthly_limit_usd)                                    as limite
    from sobre s
    join public.levels l on l.level = s.nivel
  ),
  sobre_cupo as (
    select
      x.*,
      array_remove(array[
        case when x.ocupado + x.financiado > x.limite + 0.01 then 'sobre_cupo' end,
        case when x.en_mora then 'en_mora' end
      ], null)                                                   as motivos
    from sobre_con_limite x
    where x.ocupado + x.financiado > x.limite + 0.01
       or x.en_mora
  ),

  alerta as (
    select
      'relacionada:' || r.user_id || ':' || r.otro_id                  as alert_key,
      'cuenta_relacionada'::text                                       as kind,
      case when 'cedula' = any(r.motivos) or cardinality(r.motivos) > 1
           then 'alta' else 'media' end                                as severity,
      r.user_id,
      r.desde                                                          as detected_at,
      jsonb_build_object(
        'other_user_id', r.otro_id,
        'other_name',    o.full_name,
        'other_status',  o.status,
        'reasons',       to_jsonb(r.motivos)
      )                                                                as detail
    from relacion r
    join persona o on o.id = r.otro_id

    -- PODA (Helios): las alertas 2 (`kyc_red_sospechosa`) y 3
    -- (`kyc_sistema_distinto`) salían del KYC y de los aparatos de la app.

    union all
    -- 4. Consumo sobre el cupo: siempre alta, porque no debería existir.
    select
      'sobre_cupo:' || s.user_id || ':' || s.charge_id,
      'consumo_sobre_cupo',
      'alta',
      s.user_id,
      s.abierta,
      jsonb_build_object(
        'charge_id',     s.charge_id,
        'order_number',  c.order_number,
        'business_date', c.business_date,
        'merchant_name', m.name,
        'financed_usd',  s.financiado,
        'used_usd',      s.ocupado,
        'limit_usd',     s.limite,
        'level',         s.nivel,
        'reasons',       to_jsonb(s.motivos)
      )
    from sobre_cupo s
    join public.charges   c on c.id = s.charge_id
    join public.merchants m on m.id = c.merchant_id
  ),

  completa as (
    select
      a.alert_key,
      a.kind,
      a.severity,
      a.user_id,
      pe.full_name,
      pe.status                        as user_status,
      a.detected_at,
      a.detail,
      rv.alert_key is not null         as reviewed,
      rv.reviewed_at,
      rv.reviewed_by,
      pa.full_name                     as reviewed_by_name,
      rv.note                          as review_note
    from alerta a
    join persona pe on pe.id = a.user_id and not pe.is_test
    left join public.risk_alert_reviews rv on rv.alert_key = a.alert_key
    left join public.platform_admins pa    on pa.user_id = rv.reviewed_by
  ),
  pedida as (
    select * from completa
    where p_kinds is null or kind = any(p_kinds)
  )
  select jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_window,
    -- Los tipos siempre, con o sin alertas, y sin el filtro de
    -- `p_kinds`: son los contadores de las pestañas.
    'counts', (
      select jsonb_object_agg(x.kind, jsonb_build_object(
        'total',           x.total,
        'unreviewed',      x.unreviewed,
        'unreviewed_high', x.unreviewed_high
      ))
      from (
        select
          k.kind,
          count(c.alert_key)                                                    as total,
          count(c.alert_key) filter (where not c.reviewed)                      as unreviewed,
          count(c.alert_key) filter (where not c.reviewed and c.severity = 'alta') as unreviewed_high
        from unnest(array['cuenta_relacionada', 'consumo_sobre_cupo']) as k(kind)
        left join completa c on c.kind = k.kind
        group by k.kind
      ) x
    ),
    'total',     (select count(*) from pedida),
    'truncated', (select count(*) from pedida) > v_limit,
    -- Sin revisar primero, las graves antes, y la más reciente arriba.
    'rows', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.reviewed, s.severity = 'media', s.detected_at desc, s.alert_key)
      from (
        select * from pedida
        order by reviewed, severity = 'media', detected_at desc, alert_key
        limit v_limit
      ) s
    ), '[]'::jsonb)
  )
  into v_out;

  return v_out;
end;
$function$;

-- public.admin_terms_versions: contaba `terms_acceptances`.
CREATE OR REPLACE FUNCTION public.admin_terms_versions()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rows  jsonb;
  v_total integer;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select count(*)::integer into v_total from public.profiles where not is_test;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.published_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      t.version,
      t.summary,
      t.url,
      t.published_at,
      t.is_current,
      coalesce(pa.full_name, 'Alguien del equipo') as published_by_name,
      -- PODA (Helios): las aceptaciones eran de la app (`terms_acceptances`).
      -- En Helios los términos van en el comprobante (H9) y nadie los acepta
      -- en una pantalla: 0 y null, con la misma forma.
      0 as accepted_count,
      null::timestamptz as first_accepted_at
    from public.terms_versions t
    left join public.platform_admins pa on pa.user_id = t.published_by
  ) q;

  return jsonb_build_object(
    'people_total', v_total,
    -- Quién no ha aceptado la vigente. Es el número que decide si se puede
    -- cambiar algo que dependa de los términos.
    -- PODA (Helios): sin aceptaciones, nadie queda pendiente.
    'pending_current', 0,
    'rows', v_rows
  );
end;
$function$;

-- public.admin_user_detail: leía `avatar_colors`, `kyc.verifications`, `bits_entries` y `user_devices`.
CREATE OR REPLACE FUNCTION public.admin_user_detail(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_today  date := public.helios_business_date(now());
  v_result jsonb;
  v_block  public.user_credit_blocks%rowtype;
  v_limit  numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'user_id', p.id,
    'full_name', p.full_name,
    'phone_e164', p.phone_e164,
    'document_number', p.document_number,
    'birth_date', p.birth_date,
    'status', p.status,
    'level', p.level,
    'is_blacklisted', p.is_blacklisted,
    'blacklist_reason', p.blacklist_reason,
    'is_test', p.is_test,
    'created_at', p.created_at,
    -- PODA (Helios): el avatar lo elegía la persona en la app
    -- (`avatar_colors`, `avatar_emojis`). Las claves quedan en null.
    'avatar_emoji', null::text,
    'avatar_color', null::text
  ), l.monthly_limit_usd
  into v_result, v_limit
  from public.profiles p
  join public.levels l on l.level = p.level
  where p.id = p_user_id;

  if v_result is null then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  -- El bloque de crédito abierto explica el disponible. Es la pregunta #1 de
  -- soporte: "pagué una cuota, ¿por qué sigo en cero?" (docs/00-BASES §2.2).
  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user_id and closed_at is null;

  v_result := v_result || jsonb_build_object('credit', jsonb_build_object(
    'level_limit_usd', v_limit,
    'block_charged_usd', coalesce(v_block.charged_usd, 0),
    'block_paid_usd', coalesce(v_block.paid_usd, 0),
    'available_usd', greatest(v_limit - (coalesce(v_block.charged_usd, 0)
                                       - coalesce(v_block.paid_usd, 0)), 0),
    'to_unlock_usd', coalesce(v_block.charged_usd, 0) - coalesce(v_block.paid_usd, 0),
    'block_opened_at', v_block.opened_at,
    -- Lo que puede gastar HOY, con la misma puerta que una compra. Con una
    -- cuota vencida, la cuenta sin activar o un bloqueo, es 0.
    'available_now_usd', public.helios_available_now_usd(p_user_id),
    -- El mismo cupo, sin mirar si hoy puede gastarlo.
    'available_nominal_usd', greatest(v_limit - public.helios_credit_used_usd(p_user_id), 0),
    'available_blocked_reason', public.helios_available_blocked_reason(p_user_id)
  ));

  -- Lo dado por perdido (written_off_at) no es deuda viva: no entra en lo
  -- que debe, ni en lo vencido, ni en los días de atraso, igual que en
  -- metricas.cuotas (estado 'perdida'). Va aparte, en written_off_usd.
  -- (20260927696000; antes sumaba toda cuota 'pending'.)
  v_result := v_result || jsonb_build_object('debt', (
    select jsonb_build_object(
      'open_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null), 0),
      'overdue_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today), 0),
      'paid_usd', coalesce(sum(amount_usd) filter (where status = 'paid'), 0),
      -- FINANCED: el consumo de sus cuotas pagadas, la cifra que mide el
      -- motor de niveles (level_standing). paid_usd lleva el fee dentro.
      'paid_financed_usd', coalesce(sum(financed_usd) filter (where status = 'paid'), 0),
      'days_overdue', coalesce(max(v_today - due_date)
        filter (where status = 'pending' and written_off_at is null and due_date < v_today), 0),
      -- PAYABLE: las cuotas sin pagar dadas por perdidas, con su consumo.
      'written_off_usd', coalesce(sum(amount_usd)
        filter (where status = 'pending' and written_off_at is not null), 0),
      'written_off_financed_usd', coalesce(sum(financed_usd)
        filter (where status = 'pending' and written_off_at is not null), 0)
    )
    from public.installments where user_id = p_user_id
  ));

  v_result := v_result || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'charge_id', i.charge_id,
      -- El número de la orden de la que sale esta cuota: es lo que el equipo
      -- teclea en el buscador y lo que el local dicta por teléfono.
      'order_number', ch.order_number,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      -- Lo que esta cuota lleva de consumo, sin el servicio.
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status,
      'paid_at', i.paid_at,
      'merchant_name', m.name,
      'days_overdue', greatest(v_today - i.due_date, 0),
      -- Dada por perdida: sigue 'pending' pero ya no es deuda viva.
      'written_off_at', i.written_off_at,
      -- El día operativo en que REPORTÓ el pago que la saldó (sin reporte, el
      -- de la aprobación): el mismo que metricas.cuotas.pagada_dia.
      'paid_day', case when i.status = 'paid' then
        coalesce(metricas.dia_operativo(pr.created_at), metricas.dia_operativo(i.paid_at)) end,
      -- Cobrada a tiempo con la regla canónica (metricas.a_tiempo: el día del
      -- reporte, como mucho el vencimiento más los días de gracia).
      'on_time', case when i.status = 'paid' then
        metricas.a_tiempo(coalesce(metricas.dia_operativo(pr.created_at),
                                   metricas.dia_operativo(i.paid_at)), i.due_date) end
    ) order by i.due_date, i.sequence)
    from public.installments i
    join public.charges ch on ch.id = i.charge_id
    join public.merchants m on m.id = ch.merchant_id
    left join public.payment_reports pr on pr.id = i.paid_by_report_id
    where i.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('charges', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ch.id,
      'order_number', ch.order_number,
      'amount_usd', ch.amount_usd,
      'status', ch.status,
      'business_date', ch.business_date,
      'confirmed_at', ch.confirmed_at,
      'merchant_name', m.name,
      'branch_name', b.name,
      'void_reason', ch.void_reason,
      -- El consumo entero, sin el servicio de Ronda (amount_usd lo lleva).
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'merchant_id', ch.merchant_id
    ) order by ch.created_at desc)
    from public.charges ch
    join public.merchants m on m.id = ch.merchant_id
    join public.merchant_branches b on b.id = ch.branch_id
    where ch.user_id = p_user_id
  ), '[]'::jsonb));

  -- Los consumos en los que ESTÁ: los que puso (charges.user_id) y aquellos en
  -- los que tiene cuotas. En un grupo el cargo es de quien abrió la cuenta y
  -- las cuotas son de cada quien, así que `charges` (arriba) se queda corto.
  -- Todo en financed: la cuenta entera y su parte (la suma de sus cuotas).
  v_result := v_result || jsonb_build_object('consumos', coalesce((
    with mias as (
      select i.charge_id, sum(i.financed_usd) as parte
      from public.installments i
      where i.user_id = p_user_id
      group by i.charge_id
    ),
    ids as (
      select ch.id from public.charges ch where ch.user_id = p_user_id
      union
      select mias.charge_id from mias
    )
    select jsonb_agg(jsonb_build_object(
      'charge_id', ch.id,
      'order_number', ch.order_number,
      'status', ch.status,
      'business_date', ch.business_date,
      'created_at', ch.created_at,
      'confirmed_at', ch.confirmed_at,
      'void_reason', ch.void_reason,
      'merchant_id', ch.merchant_id,
      'merchant_name', m.name,
      'group_id', ch.group_id,
      'is_group', ch.group_id is not null,
      'started_it', coalesce(ch.user_id = p_user_id, false),
      'financed_usd', coalesce(ch.base_usd, ch.amount_usd),
      'share_financed_usd', mi.parte
    ) order by ch.created_at desc)
    from ids
    join public.charges ch on ch.id = ids.id
    join public.merchants m on m.id = ch.merchant_id
    left join mias mi on mi.charge_id = ch.id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('payments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id,
      'status', pr.status,
      'bank', pr.bank,
      'reference', pr.reference,
      'method', pr.method,
      'amount_usd', q.amount_usd,
      'amount_ves', q.amount_ves,
      'rejection_note', pr.rejection_note,
      'created_at', pr.created_at,
      -- amount_usd = cuotas (consumo + service fee) + cargos por atraso. Sus
      -- sumandos, para no enseñar un total con el fee sin desglose.
      'cuotas_payable_usd', coalesce(it.payable, 0),
      'cuotas_financed_usd', coalesce(it.financed, 0),
      'cuotas_fee_usd', coalesce(it.payable, 0) - coalesce(it.financed, 0),
      'late_fees_usd', coalesce(lf.cargos, 0)
    ) order by pr.created_at desc)
    from public.payment_reports pr
    join public.payment_quotes q on q.id = pr.quote_id
    left join lateral (
      select sum(qi.amount_usd) as payable, sum(i.financed_usd) as financed
      from public.payment_quote_items qi
      join public.installments i on i.id = qi.installment_id
      where qi.quote_id = q.id
    ) it on true
    left join lateral (
      select sum(qf.amount_usd) as cargos
      from public.payment_quote_late_fees qf
      where qf.quote_id = q.id
    ) lf on true
    where pr.user_id = p_user_id
  ), '[]'::jsonb));

  v_result := v_result || jsonb_build_object('level_changes', coalesce((
    select jsonb_agg(jsonb_build_object(
      'from_level', lc.from_level,
      'to_level', lc.to_level,
      'reason', lc.reason,
      'note', lc.note,
      'actor', lc.actor,
      'created_at', lc.created_at
    ) order by lc.created_at desc)
    from public.level_changes lc
    where lc.user_id = p_user_id
  ), '[]'::jsonb));

  -- PODA (Helios): la verificación de identidad (`kyc.verifications`), los
  -- Bits (`bits_entries`) y los aparatos de la app (`user_devices`) se fueron
  -- con la app. Las claves se quedan vacías para no cambiar la forma.
  v_result := v_result || jsonb_build_object(
    'kyc', null::jsonb,
    'bits', null::jsonb,
    'bits_entries', '[]'::jsonb,
    'devices', '[]'::jsonb
  );

  return v_result;
end;
$function$;

-- public.helios_quote_installments: excluía cuotas bloqueadas por una mesa (`installment_unlocks_at`).
CREATE OR REPLACE FUNCTION public.helios_quote_installments(p_user uuid, p_installment_ids uuid[], p_ignore_open_report boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user       uuid := p_user;
  v_bd         date := public.helios_business_date(now());
  v_left       integer;
  v_rate       numeric(18,6);
  v_total_usd  numeric(18,4);
  v_count      integer;
  v_fee_ids    uuid[];
  v_fee_usd    numeric(18,4) := 0;
  v_grand_usd  numeric(18,4);
  v_quote      public.payment_quotes%rowtype;
begin
  if v_user is null then
    raise exception 'Falta de quién es el pago' using errcode = '22023';
  end if;

  if p_installment_ids is null or array_length(p_installment_ids, 1) is null then
    raise exception 'Selecciona al menos una cuota' using errcode = '22023';
  end if;

  -- Solo cuotas propias y pendientes. Si el cliente manda una ajena o ya
  -- pagada, no se cotiza a medias: se rechaza entero.
  select coalesce(sum(amount_usd), 0), count(*)
    into v_total_usd, v_count
  from public.installments
  where id = any(p_installment_ids)
    and user_id = v_user
    and status = 'pending';

  if v_count <> array_length(p_installment_ids, 1) then
    raise exception 'Alguna de las cuotas no es tuya o ya está pagada'
      using errcode = '22023';
  end if;

  -- Cuota con un pago ya reportado y sin conciliar. Se corta AQUÍ, en la
  -- cotización, y no al reportar: entre una cosa y la otra el usuario hace la
  -- transferencia, y negarle el reporte con el dinero ya enviado es el peor
  -- momento posible para decirle que no hacía falta pagar.
  if not p_ignore_open_report and exists (
    select 1
    from public.payment_quote_items i
    join public.payment_reports r on r.quote_id = i.quote_id
    where i.installment_id = any(p_installment_ids)
      and r.user_id = v_user
      and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  -- Lo que vence hoy o antes va primero: adelantar una cuota exige llevar
  -- todas las que vencen hoy o antes y se pueden pagar.
  if exists (
    select 1 from public.installments
    where id = any(p_installment_ids) and due_date > v_bd
  ) then
    select count(*) into v_left
    from public.installments i
    where i.user_id = v_user
      and i.status = 'pending'
      and i.due_date <= v_bd
      and not (i.id = any(p_installment_ids))
      and not exists (
        select 1
        from public.payment_quote_items qi
        join public.payment_reports r on r.quote_id = qi.quote_id
        where qi.installment_id = i.id
          and r.status in ('reported', 'in_review')
      );

    if v_left > 0 then
      if p_ignore_open_report then
        -- El panel: quien asigna el abono no es quien debe.
        raise exception
          'Esta persona tiene % cuota(s) que vencen hoy o antes y no están en la selección: para adelantar una cuota hay que incluirlas.',
          v_left using errcode = '22023';
      end if;

      raise exception
        'Tienes una cuota que vence hoy o antes. Inclúyela en este pago para poder adelantar las siguientes.'
        using errcode = '22023';
    end if;
  end if;

  -- Los cargos de las cuotas elegidas, más los huérfanos. Se guardan los ids
  -- para no repetir el predicado al escribir el enlace.
  select coalesce(array_agg(f.id), '{}'::uuid[]), coalesce(sum(f.amount_usd), 0)
    into v_fee_ids, v_fee_usd
  from public.late_fees f
  left join public.installments i on i.id = f.installment_id
  where f.user_id = v_user
    and f.status = 'pending'
    and (
      f.installment_id = any(p_installment_ids)
      or f.installment_id is null
      or i.status <> 'pending'
    );

  v_grand_usd := v_total_usd + v_fee_usd;

  v_rate := public.current_fx_rate();
  if v_rate is null then
    raise exception 'No hay tasa de cambio vigente' using errcode = 'P0002';
  end if;

  insert into public.payment_quotes
    (user_id, amount_usd, fx_rate, amount_ves, installment_count, valid_until,
     late_fee_usd)
  values (
    v_user,
    v_grand_usd,
    v_rate,
    round(v_grand_usd * v_rate, 2),
    v_count,
    -- Fin del día calendario en Caracas (docs/05 §1): el BCV publica una vez
    -- al día, así que una cotización de la tarde sigue viva esa noche.
    (date_trunc('day', now() at time zone 'America/Caracas') + interval '1 day')
      at time zone 'America/Caracas',
    v_fee_usd
  )
  returning * into v_quote;

  insert into public.payment_quote_items (quote_id, installment_id, amount_usd)
  select v_quote.id, id, amount_usd
  from public.installments
  where id = any(p_installment_ids);

  -- El detalle de los cargos, con su importe congelado.
  insert into public.payment_quote_late_fees (quote_id, late_fee_id, amount_usd)
  select v_quote.id, f.id, f.amount_usd
  from public.late_fees f
  where f.id = any(v_fee_ids);

  return jsonb_build_object(
    'quote_id', v_quote.id,
    'amount_usd', v_quote.amount_usd,
    'fx_rate', v_quote.fx_rate,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    -- Partido, para que la pantalla pueda enseñar los cargos en su propia
    -- línea sin restar dos cifras que ya sabe el servidor.
    'installments_usd', v_total_usd,
    'late_fee_usd', v_quote.late_fee_usd,
    -- Cuántos son: deja escribir "2 cargos por mora" en vez de una cifra
    -- suelta que ya no se explica sola.
    'late_fee_count', coalesce(array_length(v_fee_ids, 1), 0),
    'valid_until', v_quote.valid_until,
    'destination', (
      select jsonb_build_object(
        'bank_name', bank_name, 'rif', rif, 'phone', phone, 'holder_name', holder_name
      )
      from public.payment_destinations where is_active limit 1
    )
  );
end;
$function$;

-- public.helios_spend_block: frenaba a quien estaba en la lista de espera (`credit_waitlist`, `helios_waitlisted`). Ver docs/00 §4.2.
CREATE OR REPLACE FUNCTION public.helios_spend_block(p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_m     public.platform_maintenance%rowtype;
  v_block public.user_blocks%rowtype;
begin
  select * into v_m from public.platform_maintenance;

  -- 1. Mantenimiento que apaga: manda sobre todo lo demás, porque es lo único
  --    que explica por qué le pasa a todo el mundo a la vez.
  if v_m.is_active and v_m.blocks_balance then
    return jsonb_build_object(
      'code', 'maintenance',
      'title', v_m.title,
      'message', case
        when v_m.expected_back is null or trim(v_m.expected_back) = '' then v_m.message
        else v_m.message || ' Volvemos ' || trim(v_m.expected_back) || '.'
      end,
      'blocks_balance', true
    );
  end if;

  -- 2. Sanción del equipo.
  select * into v_block
  from public.user_blocks
  where user_id = p_user and lifted_at is null;

  if found then
    return jsonb_build_object(
      'code', 'blocked',
      'title', 'Tu cuenta está bloqueada',
      'message', v_block.message,
      'blocks_balance', true
    );
  end if;

  -- 3. PODA (Helios): aquí iba la lista de espera del piloto
  --    (`credit_waitlist`, 20260909151000). Helios no la tiene.

  -- 4. Mantenimiento informativo. Va el último porque no bloquea nada.
  if v_m.is_active then
    return jsonb_build_object(
      'code', 'maintenance',
      'title', v_m.title,
      'message', case
        when v_m.expected_back is null or trim(v_m.expected_back) = '' then v_m.message
        else v_m.message || ' Volvemos ' || trim(v_m.expected_back) || '.'
      end,
      'blocks_balance', false
    );
  end if;

  return null;
end;
$function$;

-- public.report_payment: calculaba los Bits del pago (`helios_bits_for_installment`).
CREATE OR REPLACE FUNCTION public.report_payment(p_quote_id uuid, p_method text, p_bank text, p_reference text, p_payer_document text DEFAULT NULL::text, p_payer_phone text DEFAULT NULL::text, p_receipt_path text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user      uuid := auth.uid();
  v_quote     public.payment_quotes%rowtype;
  v_dest      uuid;
  v_duplicate boolean;
  v_status    public.payment_report_status;
  v_row       public.payment_reports%rowtype;
  v_early     integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_quote from public.payment_quotes where id = p_quote_id for update;
  if not found or v_quote.user_id <> v_user then
    raise exception 'Cotización no encontrada' using errcode = 'P0002';
  end if;

  if v_quote.valid_until < now() then
    raise exception 'La cotización venció, vuelve a cotizar' using errcode = '22023';
  end if;

  if p_method <> 'efectivo' and (p_reference is null or length(trim(p_reference)) = 0) then
    raise exception 'La referencia es obligatoria para %', p_method using errcode = '22023';
  end if;

  if exists (
    select 1 from public.payment_reports r
    join public.payment_quote_items i on i.quote_id = r.quote_id
    join public.payment_quote_items j on j.installment_id = i.installment_id
    where j.quote_id = p_quote_id and r.status in ('reported', 'in_review')
  ) then
    raise exception
      'Ya reportaste un pago para alguna de esas cuotas y está en revisión. Te avisamos en cuanto lo confirmemos.'
      using errcode = '22023';
  end if;

  select id into v_dest from public.payment_destinations where is_active limit 1;

  -- Coincidencia de referencia: sospechosa, no concluyente. Va a revisión.
  v_duplicate := p_reference is not null and exists (
    select 1 from public.payment_reports
    where bank = p_bank and reference = p_reference and status <> 'rejected'
  );

  v_status := case when v_duplicate then 'in_review' else 'reported' end;

  insert into public.payment_reports (
    quote_id, user_id, method, bank, reference,
    payer_document, payer_phone, destination_id, receipt_path, status,
    rejection_note
  )
  values (
    p_quote_id, v_user, p_method, p_bank, p_reference,
    p_payer_document, p_payer_phone, v_dest, p_receipt_path, v_status,
    case when v_duplicate
      then 'Referencia repetida: revisar contra el estado de cuenta antes de aprobar.'
      else null end
  )
  returning * into v_row;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  -- Cuántas de las cuotas de este pago son ADELANTO. PODA (Helios): el premio
  -- en Bits que se calculaba aquí se fue con los Bits; `bits_pending` queda
  -- en 0 para no cambiar la forma de la respuesta.
  select
    count(*) filter (where i.due_date > public.helios_business_date(v_row.created_at))
  into v_early
  from public.payment_quote_items qi
  join public.installments i on i.id = qi.installment_id
  join public.charges ch on ch.id = i.charge_id
  where qi.quote_id = p_quote_id;
  -- ─────────────────────────────────────────────────────────────────────────

  return jsonb_build_object(
    'report_id', v_row.id,
    'status', v_row.status,
    'amount_usd', v_quote.amount_usd,
    'amount_ves', v_quote.amount_ves,
    'installment_count', v_quote.installment_count,
    'reported_at', v_row.created_at,
    'early_count', v_early,
    -- NUEVO
    'bits_pending', 0
  );
end;
$function$;

-- public.run_scheduled_settlements_loop: saldaba contra la bóveda (`helios_settle_vaults`). Ver docs/00 §4.2.
CREATE OR REPLACE PROCEDURE public.run_scheduled_settlements_loop(IN p_days_back integer DEFAULT 7, IN p_batch integer DEFAULT 50)
 LANGUAGE plpgsql
AS $procedure$
declare
  v_today date := public.helios_business_date(now());
  v_day   date;
  v_after uuid;
  v_res   jsonb;
begin
  -- Del día más viejo al de hoy: lo atrasado se devenga antes que lo nuevo.
  for v_back in reverse p_days_back .. 0 loop
    v_day   := v_today - v_back;
    v_after := '00000000-0000-0000-0000-000000000000';
    loop
      v_res := public.run_scheduled_settlements_batch(v_day, v_after, p_batch);
      commit;
      exit when (v_res ->> 'seen')::integer < p_batch;
      v_after := (v_res ->> 'last')::uuid;
    end loop;
  end loop;

  -- PODA (Helios): aquí se saldaba contra la garantía del piloto
  -- (`helios_settle_vaults`). Helios no tiene bóveda.
end;
$procedure$;

-- metricas.solicitudes: «verificado» era tener el KYC aprobado
-- (`kyc.verifications` + `kyc.decision_log`). Sin KYC, una persona está
-- registrada cuando salió de los estados previos al alta (`pending_kyc`,
-- `pending_pin`), y la fecha es la de su alta. En Helios (H3) el paciente
-- nace activo, así que coincide con `created_at`.
--
-- ⚠️ H3: el `join auth.users` se queda (de ahí sale `telefono_confirmado`),
-- pero un paciente sin cuenta no está en `auth.users` y desaparecería de
-- todas las métricas que leen `metricas.personas`.
create or replace view metricas.solicitudes as
 SELECT p.id AS user_id,
    p.created_at AS solicito_en,
    metricas.dia_operativo(p.created_at) AS solicito_dia,
    metricas.lunes(metricas.dia_operativo(p.created_at)) AS solicito_semana,
    u.phone_confirmed_at IS NOT NULL AS telefono_confirmado,
    ap.en IS NOT NULL AS verificado,
    ap.en AS verificado_en,
    metricas.dia_operativo(ap.en) AS verificado_dia,
    metricas.lunes(metricas.dia_operativo(ap.en)) AS verificado_semana,
        CASE
            WHEN ap.en IS NOT NULL THEN 'verificado'::text
            WHEN u.phone_confirmed_at IS NOT NULL THEN 'confirmo_el_telefono'::text
            ELSE 'solicito_el_codigo'::text
        END AS etapa,
    p.status::text AS estado,
    p.level AS nivel
   FROM profiles p
     JOIN auth.users u ON u.id = p.id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN p.status::text <> ALL (ARRAY['pending_kyc'::text, 'pending_pin'::text])
                    THEN p.created_at
                    ELSE NULL::timestamp with time zone
                END AS en) ap
  WHERE NOT p.is_test;

-- asistente.personas: el sexo, el sistema del teléfono y el estado del KYC
-- salían de `kyc.verifications` y `user_devices`. Las columnas se quedan en
-- null (el asistente las describe en su mapa; fase 5).
create or replace view asistente.personas as
 SELECT p.id AS user_id,
    asistente.nombre_corto(p.first_name, p.last_name, p.full_name) AS nombre,
    p.created_at AS alta_at,
    (p.created_at AT TIME ZONE 'America/Caracas'::text)::date AS alta_dia,
    asistente.estado('persona'::text, p.status::text) AS estado,
    p.level AS nivel,
    p.is_blacklisted AS en_lista_negra,
    NULL::text AS sexo,
    NULL::text AS sistema,
    NULL::text AS sistema_fuente,
    NULL::text AS kyc_estado,
    c.primer_consumo_at,
    COALESCE(c.consumos, 0::bigint) AS consumos,
    COALESCE(c.consumo_eur, 0::numeric) AS consumo_eur,
    c.ultimo_consumo_at
   FROM profiles p
     LEFT JOIN LATERAL ( SELECT min(ch.confirmed_at) AS primer_consumo_at,
            max(ch.confirmed_at) AS ultimo_consumo_at,
            count(DISTINCT ch.id) AS consumos,
            sum(i.financed_usd) AS consumo_eur
           FROM installments i
             JOIN charges ch ON ch.id = i.charge_id
          WHERE i.user_id = p.id AND ch.status = 'confirmed'::charge_status AND NOT ch.is_test AND NOT i.is_test) c ON true
  WHERE NOT p.is_test;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Disparadores de tablas A que llamaban a funciones B
-- ─────────────────────────────────────────────────────────────────────────────

drop trigger charges_notify_group            on public.charges;             -- aviso al grupo
drop trigger charges_realtime                on public.charges;             -- tiempo real del QR
drop trigger installments_award_bits         on public.installments;        -- Bits al pagar
drop trigger payment_quote_items_live_group  on public.payment_quote_items; -- cuota bloqueada por la mesa
drop trigger payment_reports_cancel_pushes   on public.payment_reports;     -- cancela pushes pendientes
drop trigger payment_reports_notify_bits     on public.payment_reports;     -- aviso de Bits
drop trigger profiles_waitlist_on_activation on public.profiles;            -- lista de espera del piloto
-- Los avisos se siguen guardando en `notifications` (`notify()`), pero ya no
-- se encolan para Expo. H7 los manda a `outbound_messages`.
drop trigger notifications_enqueue_push      on public.notifications;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Políticas que leían grupos o el tiempo real
-- ─────────────────────────────────────────────────────────────────────────────

drop policy charges_read_group_member on public.charges;
drop policy profiles_read_group_mates on public.profiles;
-- Canales privados de Realtime (`charge:<id>` para el QR y los grupos).
drop policy helios_cada_quien_escucha_lo_suyo on realtime.messages;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Vistas B
-- ─────────────────────────────────────────────────────────────────────────────

drop view public.helios_group_split_gaps restrict;
drop view metricas.avisos_peldanos restrict;
drop view metricas.avisos restrict;
drop view asistente.aparatos restrict;
drop view asistente.bits restrict;
drop view asistente.envios_push restrict;
drop view asistente.grupos restrict;
drop view asistente.miembros_grupo restrict;
drop view asistente.lista_de_espera restrict;
drop view asistente.productos_vendidos restrict;
drop view asistente.productos restrict;
drop view asistente.verificaciones restrict;
drop view kyc.review_queue restrict;
drop view kyc.gate_metrics restrict;
drop view kyc.retention_status restrict;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Tablas B (primero las FK de tablas A hacia ellas; ver regla 4)
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.charges       drop constraint charges_group_id_fkey;
alter table public.charge_items  drop constraint charge_items_product_id_fkey;
alter table public.notifications drop constraint notifications_campaign_id_fkey;
alter table public.profiles      drop constraint profiles_avatar_emoji_fkey;
alter table public.profiles      drop constraint profiles_avatar_color_fkey;

comment on column public.charges.group_id is
  'Sin uso en Helios (no hay grupos; FK quitada en la poda). Siempre null.';
comment on column public.charge_items.product_id is
  'Sin uso en Helios (sin catálogo, D-H4; FK quitada en la poda). Siempre null: la línea es libre.';
comment on column public.notifications.campaign_id is
  'Sin uso en Helios (no hay promociones; FK quitada en la poda). Siempre null.';

-- Push y promociones
drop table public.push_deliveries restrict;
drop table public.push_tokens restrict;
drop table public.promo_campaigns restrict;
-- Grupos
drop table public.group_members restrict;
drop table public.groups restrict;
-- Bits
drop table public.bits_entries restrict;
-- PIN y dispositivos
drop table public.user_pins restrict;
drop table public.pin_attempts restrict;
drop table public.user_devices restrict;
-- App
drop table public.app_release restrict;
drop table public.app_activity restrict;
drop table public.user_payment_methods restrict;
drop table public.account_deletion_requests restrict;
drop table public.avatar_emojis restrict;
drop table public.avatar_colors restrict;
drop table public.terms_acceptances restrict;
-- Piloto de La Quinta
drop table public.merchant_vault_topups restrict;
drop table public.credit_waitlist restrict;
drop table public.merchant_vaults restrict;
drop table public.qa_case_marks restrict;
-- Catálogo
drop table public.products restrict;
drop table public.product_categories restrict;
-- KYC
drop table kyc.decision_log restrict;
drop table kyc.verifications restrict;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Funciones B
-- ─────────────────────────────────────────────────────────────────────────────

-- PIN y dispositivos
drop function public.set_user_pin(p_pin text) restrict;
drop function public.verify_user_pin(p_pin text) restrict;
drop function public.has_user_pin() restrict;
drop function public.pin_pepper() restrict;
drop function public.register_device(p_device_hash text, p_device_name text, p_platform text, p_app_build integer, p_app_version text, p_os_version text) restrict;
drop function public.check_device_login(p_phone text, p_device_hash text) restrict;
drop function public.record_failed_pin_login(p_phone text) restrict;
drop function public.clear_pin_lockout() restrict;

-- KYC (Didit)
drop function public.start_kyc_verification() restrict;
drop function public.confirm_kyc_data(p_verification_id uuid, p_full_name text, p_document_number text, p_birth_date date, p_first_name text, p_last_name text) restrict;
drop function public.kyc_attach_didit_session(p_verification_id uuid, p_user_id uuid, p_session_id text, p_session_url text, p_session_token text) restrict;
drop function public.kyc_claim_didit_sync(p_user_id uuid, p_min_interval interval) restrict;
drop function public.kyc_didit_details_pending(p_limit integer) restrict;
drop function public.kyc_my_pending_session() restrict;
drop function public.kyc_record_didit_decision(p_session_id text, p_status text, p_document text, p_first_name text, p_last_name text, p_full_name text, p_birth_date date, p_detail text, p_signals jsonb) restrict;
drop function public.kyc_record_didit_details(p_session_id text, p_gender text, p_device jsonb) restrict;
drop function public.kyc_verification_is_open(p_verification_id uuid, p_user_id uuid) restrict;
drop function public.notify_kyc_rejected() restrict;
drop function public.admin_kyc_queue() restrict;
drop function public.admin_kyc_stats(p_from date, p_to date) restrict;
drop function public.admin_review_kyc(p_verification_id uuid, p_approve boolean, p_note text) restrict;
drop function public.admin_user_verification(p_user_id uuid) restrict;
drop function public.admin_request_new_verification(p_user_id uuid, p_note text) restrict;

-- Push y promociones
drop function public.register_push_token(p_token text, p_device_hash text, p_platform text) restrict;
drop function public.disable_push_token(p_token text) restrict;
drop function public.dispatch_push_queue(p_batch integer) restrict;
drop procedure public.dispatch_push_queue_loop(IN p_budget interval) restrict;
drop function public.check_push_receipts() restrict;
drop procedure public.check_push_receipts_loop(IN p_budget interval) restrict;
drop function public.enqueue_push() restrict;
drop function public.purge_push_queue() restrict;
drop function public.push_envelope(p_token text, p_type notification_type, p_title text, p_body text, p_data jsonb, p_notification_id uuid) restrict;
drop function public.push_health() restrict;
drop function public.push_priority(p_type notification_type) restrict;
drop function public.promo_audience(p_audience text, p_level integer) restrict;
drop function public.admin_send_promo(p_title text, p_body text, p_audience text, p_level integer, p_href text, p_note text) restrict;
drop function public.admin_promo_history(p_limit integer) restrict;
drop function public.admin_promo_preview(p_audience text, p_level integer) restrict;
drop function public.cancel_installment_pushes_on_report() restrict;

-- Grupos / mesas
drop function public.create_group(p_name text, p_cap_usd numeric, p_pin text) restrict;
drop function public.find_group_by_code(p_code text) restrict;
drop function public.generate_invite_code() restrict;
drop function public.group_detail(p_group_id uuid) restrict;
drop function public.group_holds_usd(p_user uuid) restrict;
drop function public.group_max_days_without_payment() restrict;
drop function public.group_participants(p_group_id uuid) restrict;
drop function public.group_pot_usd(p_group_id uuid) restrict;
drop function public.installment_not_in_a_live_group() restrict;
drop function public.installment_unlocks_at(p_installment_id uuid) restrict;
drop function public.join_group(p_invite_code text, p_cap_usd numeric, p_pin text) restrict;
drop function public.leave_group(p_group_id uuid) restrict;
drop function public.max_group_members() restrict;
drop function public.min_share_usd() restrict;
drop function public.my_group_ids() restrict;
drop function public.my_group_ids_ever() restrict;
drop function public.my_groups() restrict;
drop function public.my_locked_installments() restrict;
drop function public.my_past_groups() restrict;
drop function public.notify_group_charge() restrict;
drop function public.past_group_detail(p_group_id uuid) restrict;
drop function public.preview_group_charge(p_charge_id uuid, p_group_id uuid) restrict;
drop function public.realtime_can_listen(p_topic text) restrict;
drop function public.realtime_nudge_group(p_group_id uuid, p_also uuid) restrict;
drop function public.realtime_on_charges() restrict;
drop function public.realtime_on_group_members() restrict;
drop function public.realtime_on_groups() restrict;
drop function public.helios_group_closes_at(p_business_date date) restrict;
drop function public.helios_group_expires_at(p_created_at timestamp with time zone) restrict;
drop function public.helios_group_is_open(p_business_date date, p_created_at timestamp with time zone) restrict;
drop function public.helios_group_join_plan(p_group_id uuid, p_user uuid) restrict;
drop function public.helios_group_last_night(p_business_date date, p_created_at timestamp with time zone) restrict;
drop function public.helios_group_member_financed(p_group_id uuid, p_user_id uuid) restrict;
drop function public.helios_group_open_charges(p_group_id uuid, p_user uuid) restrict;
drop function public.helios_group_resplit_charge(p_charge_id uuid, p_user uuid, p_capacity_usd numeric) restrict;
drop function public.helios_group_seat_holders(p_group_id uuid) restrict;
drop function public.helios_split_shares(p_total_usd numeric, p_participants jsonb, p_payer uuid) restrict;
drop function public.helios_payables(p_shares jsonb, p_base_usd numeric, p_total_usd numeric, p_payer uuid) restrict;
drop function public.set_my_group_cap(p_group_id uuid, p_cap_usd numeric, p_pin text) restrict;
drop function public.admin_group_metrics(p_from date, p_to date, p_merchant_id uuid) restrict;
drop function public.confirm_charge_as_group(p_charge_id uuid, p_group_id uuid, p_idempotency_key text, p_pin text, p_expected_share_usd numeric) restrict;

-- Cobro por QR (reclamo)
drop function public.preview_charge(p_charge_id uuid) restrict;
drop function public.confirm_charge(p_charge_id uuid, p_idempotency_key text, p_pin text) restrict;
drop function public.expire_stale_charges() restrict;
drop function public.cancel_pending_charge(p_charge_id uuid) restrict;
drop function public.request_charge(p_merchant_id uuid, p_branch_id uuid, p_items jsonb, p_idempotency_key text) restrict;
drop function public.charge_detail(p_charge_id uuid) restrict;
drop function public.merchant_charge_status(p_charge_id uuid) restrict;

-- Bits
drop function public.award_bits_for_installment() restrict;
drop function public.my_bits() restrict;
drop function public.notify_bits_earned() restrict;
drop function public.helios_bits_daily_step() restrict;
drop function public.helios_bits_floor() restrict;
drop function public.helios_bits_for_installment(p_purchase_date date, p_due_date date, p_paid_date date) restrict;
drop function public.helios_bits_same_day() restrict;

-- App (versión, actividad, avatar, métodos de pago, términos, eliminación)
drop function public.helios_app_gate(p_platform text, p_build integer) restrict;
drop function public.helios_app_releases() restrict;
drop function public.admin_set_app_release(p_platform text, p_min_build integer, p_latest_build integer, p_title text, p_message text, p_force_title text, p_force_message text, p_store_url text, p_reason text) restrict;
drop function public.log_app_activity(p_kind text, p_detail text) restrict;
drop function public.set_my_avatar(p_emoji text, p_color text) restrict;
drop function public.save_payment_method(p_bank text, p_payer_document text, p_payer_phone text, p_make_default boolean) restrict;
drop function public.delete_payment_method(p_id uuid) restrict;
drop function public.set_default_payment_method(p_id uuid) restrict;
drop function public.max_payment_methods() restrict;
drop function public.accept_terms(p_version text, p_device_hash text) restrict;
drop function public.admin_user_terms(p_user_id uuid) restrict;
drop function public.ack_level_up() restrict;
drop function public.my_pending_level_up() restrict;
drop function public.request_account_deletion(p_reason text) restrict;
drop function public.cancel_account_deletion() restrict;
drop function public.my_deletion_eligibility() restrict;
drop function public.admin_deletion_requests(p_status account_deletion_status) restrict;
drop function public.admin_resolve_deletion_request(p_id uuid, p_status account_deletion_status, p_note text) restrict;
drop function public.sync_phone_e164() restrict;
drop function public.mark_notifications_read(p_ids uuid[]) restrict;

-- La vista del usuario en la app (my_*)
drop function public.my_account_state() restrict;
drop function public.my_available_balance() restrict;
drop function public.my_installments_in_review() restrict;
drop function public.my_level_progress() restrict;
drop function public.my_notifications(p_limit integer) restrict;
drop function public.my_pending_late_fees() restrict;
drop function public.my_purchases(p_limit integer) restrict;
drop function public.my_merchant_vault() restrict;

-- Piloto de La Quinta (bóveda, lista de espera)
drop function public.admin_vault_overview() restrict;
drop function public.admin_vault_topup(p_merchant_id uuid, p_amount_usd numeric, p_note text) restrict;
drop function public.admin_vault_topups(p_merchant_id uuid, p_limit integer) restrict;
drop function public.admin_set_vault(p_merchant_id uuid, p_is_active boolean, p_waitlist_auto_enroll boolean, p_waitlist_blocks_balance boolean, p_threshold_pct numeric, p_capacity_usd numeric, p_note text) restrict;
drop function public.admin_waitlist(p_merchant_id uuid, p_include_released boolean, p_limit integer) restrict;
drop function public.admin_waitlist_enroll(p_user_id uuid, p_merchant_id uuid, p_note text) restrict;
drop function public.admin_waitlist_release(p_user_id uuid, p_note text) restrict;
drop function public.admin_waitlist_release_oldest(p_merchant_id uuid, p_count integer, p_note text) restrict;
drop function public.helios_waitlisted(p_user uuid) restrict;
drop function public.helios_settle_vaults() restrict;
drop function public.helios_settle_from_vault(p_merchant_id uuid, p_settlement_ids uuid[], p_amount_usd numeric, p_actor uuid, p_note text, p_strict boolean) restrict;
drop function public.helios_vault_wanting_waitlist() restrict;
drop function public.enroll_in_waitlist_on_activation() restrict;
drop function public.merchant_vault_state(p_merchant_id uuid) restrict;
drop function public.vault_topup_to_ledger() restrict;
drop function public.vault_topups_block_mutation() restrict;
drop function ledger.record_vault_deposit(p_topup_id uuid) restrict;
drop function ledger.merchant_prepaid_balance(p_merchant_id uuid) restrict;

-- Métricas de noches, KYC, push y persona
drop function public.admin_nights(p_days integer, p_merchant_id uuid, p_semana date) restrict;
drop function public.admin_growth_funnel(p_from date, p_to date, p_merchant_id uuid) restrict;
drop function public.admin_metricas_avisos(p_semana date, p_merchant_id uuid) restrict;
drop function public.admin_metricas_avisos_semanas(p_semana date, p_merchant_id uuid, p_semanas integer) restrict;
drop function public.admin_avisos_de_la_cohorte(p_semana date, p_merchant_id uuid) restrict;
drop function public.admin_avisos_proximos(p_dias integer) restrict;
drop function public.admin_user_persona(p_base text, p_merchant_id uuid) restrict;
drop function metricas.avisos_por_cohorte(p_desde date, p_hasta date, p_merchant_id uuid) restrict;
drop function metricas.avisos_escalera(p_desde date, p_hasta date, p_merchant_id uuid) restrict;
drop function metricas.avisos_destinatarios(p_desde date, p_hasta date, p_merchant_id uuid) restrict;
drop function metricas.avisos_desfase(p_clave text) restrict;
drop function metricas.avisos_motivo(p_error text) restrict;


-- El esquema `kyc` entero.
drop function kyc.advance_profile(p_verification_id uuid) restrict;
drop function kyc.apply_status(p_verification_id uuid, p_status kyc.verification_status, p_reason kyc.rejection_reason, p_actor text, p_signals jsonb) restrict;
drop function kyc.attach_didit_session(p_verification_id uuid, p_session_id text, p_session_url text, p_session_token text) restrict;
drop function kyc.birth_matches(p_ocr date, p_claimed date) restrict;
drop function kyc.document_matches(p_ocr text, p_claimed text) restrict;
drop function kyc.expire_stuck() restrict;
drop function kyc.name_matches(p_ocr text, p_claimed text) restrict;
drop function kyc.normalize_document(p_text text) restrict;
drop function kyc.normalize_name(p_text text) restrict;
drop function kyc.record_didit_decision(p_session_id text, p_status text, p_document text, p_first_name text, p_last_name text, p_full_name text, p_birth_date date, p_detail text, p_signals jsonb) restrict;
drop function kyc.review(p_verification_id uuid, p_approve boolean, p_reviewer uuid, p_note text) restrict;
drop type kyc.verification_status restrict;
drop type kyc.rejection_reason restrict;
drop schema kyc restrict;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Tipos B (los enum que solo usaban tablas podadas)
-- ─────────────────────────────────────────────────────────────────────────────

drop type public.push_status restrict;
drop type public.group_status restrict;
drop type public.group_member_status restrict;
drop type public.account_deletion_status restrict;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Storage del KYC
-- ─────────────────────────────────────────────────────────────────────────────
-- Sus políticas ya las quitó Ronda (20260923160000). Quedan los dos buckets,
-- vacíos en Helios. Storage frena el DELETE directo con el trigger de
-- sentencia `storage.protect_delete` salvo que `storage.allow_delete_query`
-- valga true; se abre solo para esta sentencia y solo si no hay archivos
-- dentro (con archivos, habría que borrarlos por la API de Storage primero).
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.buckets b
 where b.id in ('kyc-documents', 'kyc-archive')
   and not exists (select 1 from storage.objects o where o.bucket_id = b.id);
select set_config('storage.allow_delete_query', 'false', true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. Datos de Ronda que sembraron las migraciones
-- ─────────────────────────────────────────────────────────────────────────────
-- Se queda la configuración: niveles, parámetros, catálogo de parámetros,
-- plantillas de avisos y de cobranza, fuentes de la tasa y feriados.

-- El comercio de prueba «HELIOS DEMO» (en Ronda, «RONDA DEMO»; 20260911180000), con su sucursal y condiciones.
delete from public.merchant_terms
 where merchant_id in (select id from public.merchants where tax_id = 'J-000000001');
delete from public.merchant_branches
 where merchant_id in (select id from public.merchants where tax_id = 'J-000000001');
delete from public.merchants where tax_id = 'J-000000001';

-- La cuenta de cobro provisional (20260822122000). En Helios las cuentas se
-- configuran en Ajustes (H11); mientras no haya ninguna, el comprobante dice
-- que Helios escribirá con las instrucciones de pago.
delete from public.payment_destinations
 where bank_name = 'PENDIENTE POR CONFIGURAR' and rif = 'J-000000000';

-- Plantillas de avisos de funciones podadas.
delete from public.notification_templates
 where key in ('group_charge', 'group_charge.consumo', 'group_charge.entra',
               'bits_earned', 'kyc_approved', 'kyc_rejected',
               'waitlist_joined', 'waitlist_released');

-- El plazo de un QR sin reclamar: sin QR no hay plazo.
delete from public.business_parameters where key = 'charge_ttl_minutes';
delete from public.business_parameter_catalog where key = 'charge_ttl_minutes';
