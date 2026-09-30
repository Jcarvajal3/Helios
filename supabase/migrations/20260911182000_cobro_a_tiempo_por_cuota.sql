-- ============================================================================
-- Ronda — Cobro a tiempo, cuota 1 y cuota 2
--
-- El panel mide la **mora** —lo vencido sobre la deuda viva— y el **impago**
-- —lo castigado sobre lo financiado—. Las dos llegan tarde: la mora necesita
-- que la cuota ya esté vencida, y el impago, que hayan pasado sesenta días.
--
-- El cobro a tiempo es el que avisa primero. Si la cuota 1 se pagaba al día en
-- el 91 % y esta semana va por el 78 %, algo se rompió **ahora** — el cobro, el
-- recordatorio, la cuenta de cobro, el local nuevo que trajo otra clientela— y
-- todavía no ha llegado a la mora.
--
-- ---------------------------------------------------------------------------
-- Cómo se mide
-- ---------------------------------------------------------------------------
--     cuotas N pagadas dentro de su vencimiento + los días de reintento
--     ─────────────────────────────────────────────────────────────────
--            cuotas N que vencieron dentro de la ventana
--
-- **Por número de cuota y no en bloque.** La cuota 1 y la cuota 2 miden cosas
-- distintas: la primera dice si la persona entendió que debe pagar; la segunda,
-- si sigue pudiendo. Promediarlas esconde justo la diferencia que importa.
--
-- **El denominador son las que VENCIERON, no las que se crearon.** Una cuota
-- que todavía no ha vencido no puede estar ni a tiempo ni tarde, y meterla
-- abajo hundiría el porcentaje cada vez que suben las ventas.
--
-- **Los días de reintento existen porque el pago no es instantáneo**: se
-- transfiere, se reporta y alguien concilia. Dar por tarde un pago hecho el
-- mismo día que venció y aprobado al siguiente mediría a la operación, no al
-- usuario.
--
-- Todo por día operativo, como el resto: un pago de la 1 a. m. pertenece a la
-- noche anterior.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El margen, como parámetro
-- ---------------------------------------------------------------------------

create or replace function public.helios_on_time_grace_days()
returns integer
language sql
immutable
set search_path = pg_catalog, pg_temp
as $fn$ select 2 $fn$;

comment on function public.helios_on_time_grace_days() is
  'Dias despues del vencimiento que siguen contando como "a tiempo": lo que tarda un pago en transferirse, reportarse y conciliarse. No es gracia para el usuario —el cargo por atraso corre por su cuenta—, es no medir a la operacion como si fuera al cliente.';

revoke all on function public.helios_on_time_grace_days() from public, anon;
grant execute on function public.helios_on_time_grace_days() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. La cifra
-- ---------------------------------------------------------------------------

create or replace function public.admin_on_time_collection(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today date := public.helios_business_date(now());
  v_days  integer := greatest(least(coalesce(p_days, 30), 365), 1);
  v_grace integer := public.helios_on_time_grace_days();
  v_from  date;
  v_rows  jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  v_from := v_today - (v_days - 1);

  select coalesce(jsonb_object_agg(q.key, q.value), '{}'::jsonb)
  into v_rows
  from (
    select
      'cuota_' || i.sequence::text as key,
      jsonb_build_object(
        'sequence', i.sequence,
        'due_count', count(*)::integer,
        'on_time_count', count(*) filter (
          where i.status = 'paid'
            and i.paid_at is not null
            and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
        )::integer,
        'due_usd', coalesce(sum(i.amount_usd), 0),
        'on_time_usd', coalesce(sum(i.amount_usd) filter (
          where i.status = 'paid'
            and i.paid_at is not null
            and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
        ), 0),
        -- Null y no cero cuando no venció ninguna: un 0 % sin denominador es
        -- una alarma inventada, y la pantalla tiene que poder decir "todavía
        -- no hay con qué medirlo".
        'rate_pct', case
          when count(*) > 0
          then round(100.0 * count(*) filter (
                 where i.status = 'paid'
                   and i.paid_at is not null
                   and public.helios_business_date(i.paid_at) <= i.due_date + v_grace
               ) / count(*), 1)
          else null end
      ) as value
    from public.installments i
    where not i.is_test
      and i.written_off_at is null
      and i.due_date between v_from and v_today
    group by i.sequence
  ) q;

  return jsonb_build_object(
    'business_date', v_today,
    'window_days',   v_days,
    'grace_days',    v_grace,
    'installments',  v_rows
  );
end;
$$;

comment on function public.admin_on_time_collection(integer) is
  'Cobro a tiempo por numero de cuota: pagadas dentro del vencimiento mas los dias de reintento, sobre las que vencieron en la ventana. Es el indicador que avisa antes que la mora.';

revoke all on function public.admin_on_time_collection(integer) from public, anon;
grant execute on function public.admin_on_time_collection(integer) to authenticated;
