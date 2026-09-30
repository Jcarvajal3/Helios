-- ============================================================================
-- Ronda — Las condiciones de un comercio tienen fecha, y se guardan todas
--
-- `merchant_settlement_terms` era **una fila por comercio que se sobrescribía**.
-- Renegociar con un local borraba lo anterior, y con ello la única forma de
-- explicar por qué a una venta de agosto se le liquidó lo que se le liquidó.
--
-- Peor: el cron que genera las liquidaciones lee las condiciones **de hoy** para
-- un consumo que puede ser de hace dos semanas. Bajarle el adelanto a un local
-- el martes cambiaba, en silencio, lo que se le iba a pagar por lo que vendió
-- el viernes anterior.
--
-- ---------------------------------------------------------------------------
-- Cómo queda
-- ---------------------------------------------------------------------------
-- `merchant_terms` guarda una fila por cambio, con `effective_from`. Nunca se
-- actualiza: renegociar es insertar.
--
-- `merchant_settlement_terms` **sigue existiendo con el mismo nombre y las
-- mismas columnas**, pero ahora es una vista: la fila vigente hoy de cada
-- comercio. Así los quince sitios que la leen —el panel del local, el cobro, el
-- reparto de grupo, el libro— siguen funcionando sin tocar una línea.
--
-- Y lo que sí cambia de comportamiento: el cron y la previsión del cierre
-- resuelven las condiciones **con la fecha del consumo**, no con la de hoy.
--
-- ---------------------------------------------------------------------------
-- El histórico de antes no se puede reconstruir
-- ---------------------------------------------------------------------------
-- Las condiciones que había en agosto no se guardaron en ningún sitio. Lo que
-- hay hoy se registra como vigente desde antes de la primera venta, que es la
-- única lectura que no inventa nada: «hasta donde el sistema sabe, estas han
-- sido siempre las condiciones». Es falso para quien renegoció, pero es
-- explícito y no hay forma de hacerlo mejor.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. La tabla con historia
-- ---------------------------------------------------------------------------

create table if not exists public.merchant_terms (
  id                  uuid primary key default gen_random_uuid(),
  merchant_id         uuid not null references public.merchants(id) on delete cascade,
  upfront_pct         numeric(5,2) not null default 30.00,
  per_installment_pct numeric(5,2) not null default 35.00,
  commission_pct      numeric(5,2) not null default 10.00,
  policy              public.settlement_policy not null default 'scheduled',
  effective_from      date not null,
  note                text,
  created_by          uuid references auth.users (id),
  created_at          timestamptz not null default now(),

  -- Un comercio no puede tener dos condiciones distintas el mismo día.
  unique (merchant_id, effective_from),

  -- El adelanto y las dos liquidaciones reparten el NETO del comercio, así que
  -- suman 100 entre ellos. La comisión va aparte: es un % de la base, no un
  -- trozo del reparto.
  constraint merchant_terms_splits_net check (
    upfront_pct + (per_installment_pct * 2) = 100.00
  ),
  constraint merchant_terms_non_negative check (
    upfront_pct >= 0 and per_installment_pct >= 0 and commission_pct >= 0
  )
);

comment on table public.merchant_terms is
  'Las condiciones de liquidacion de un comercio, con fecha de vigencia. Nunca se actualiza una fila: renegociar es insertar otra. Un consumo se liquida con las vigentes el dia de la venta.';

create index if not exists merchant_terms_lookup_idx
  on public.merchant_terms (merchant_id, effective_from desc);

-- Lo que hay hoy, registrado como vigente desde antes de la primera venta.
insert into public.merchant_terms
  (merchant_id, upfront_pct, per_installment_pct, commission_pct, policy, effective_from, note)
select
  t.merchant_id, t.upfront_pct, t.per_installment_pct, t.commission_pct, t.policy,
  '2026-08-01'::date,
  'Condiciones al empezar a guardar el histórico'
from public.merchant_settlement_terms t
on conflict (merchant_id, effective_from) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Las vigentes a una fecha
-- ---------------------------------------------------------------------------

create or replace function public.helios_terms_at(p_merchant_id uuid, p_on date)
returns public.merchant_terms
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select t.*
  from public.merchant_terms t
  where t.merchant_id = p_merchant_id
    and t.effective_from <= p_on
  order by t.effective_from desc
  limit 1;
$fn$;

comment on function public.helios_terms_at(uuid, date) is
  'Las condiciones que regian ese dia. Es lo que tiene que usar todo lo que liquida un consumo: el cron lee la fecha de la venta, no la de hoy.';

revoke all on function public.helios_terms_at(uuid, date) from public, anon;
grant execute on function public.helios_terms_at(uuid, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El nombre de siempre pasa a ser la vista de hoy
-- ---------------------------------------------------------------------------
-- Mismas columnas y mismo nombre: los quince sitios que la leen no se enteran.
-- La RLS se conserva igual —las condiciones solo las ve el gerente del local—
-- con `security_invoker`, que hace que la vista respete las políticas de la
-- tabla de abajo en vez de saltárselas.

drop table if exists public.merchant_settlement_terms cascade;

create view public.merchant_settlement_terms
with (security_invoker = true)
as
select distinct on (t.merchant_id)
  t.merchant_id,
  t.upfront_pct,
  t.per_installment_pct,
  t.commission_pct,
  t.policy,
  t.created_at as updated_at
from public.merchant_terms t
where t.effective_from <= public.helios_business_date(now())
order by t.merchant_id, t.effective_from desc;

comment on view public.merchant_settlement_terms is
  'Las condiciones vigentes HOY de cada comercio. Era una tabla que se sobrescribia; ahora es la ultima fila de merchant_terms, para que todo lo que la leia siga funcionando.';

grant select on public.merchant_settlement_terms to authenticated;

alter table public.merchant_terms enable row level security;

-- Las condiciones solo las ve el personal del comercio. Nunca un cajero: es
-- información de negocio del dueño.
drop policy if exists "merchant_terms_read_staff" on public.merchant_terms;
create policy "merchant_terms_read_staff"
  on public.merchant_terms for select to authenticated
  using (
    merchant_id in (
      select merchant_id from public.merchant_users
      where user_id = auth.uid() and is_active and role = 'gerente'
    )
  );

-- ---------------------------------------------------------------------------
-- 4. Un comercio nuevo nace con sus condiciones
-- ---------------------------------------------------------------------------

create or replace function public.bootstrap_merchant()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.merchant_branches (merchant_id, name, is_default)
  values (new.id, 'Principal', true);

  -- Vigentes desde hoy: un comercio no puede tener condiciones anteriores a
  -- su propia alta.
  insert into public.merchant_terms (merchant_id, effective_from, note)
  values (new.id, public.helios_business_date(now()), 'Condiciones por defecto al dar de alta');

  return new;
end;
$$;

revoke all on function public.bootstrap_merchant() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Renegociar
-- ---------------------------------------------------------------------------

drop function if exists public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text);

create or replace function public.admin_set_settlement_terms(
  p_merchant_id         uuid,
  p_upfront_pct         numeric,
  p_per_installment_pct numeric,
  p_commission_pct      numeric,
  p_policy              text,
  p_effective_from      date default null,
  p_note                text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.helios_business_date(now());
  v_desde date;
  v_antes public.merchant_terms;
  v_name  text;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar las condiciones de un comercio'
      using errcode = '42501';
  end if;

  select name into v_name from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'No existe ese comercio' using errcode = '22023';
  end if;

  v_desde := coalesce(p_effective_from, v_today);

  -- Hacia atrás no. Cambiar las condiciones de un día que ya pasó reescribiría
  -- lo que se le liquidó al local por ventas que ya se liquidaron.
  if v_desde < v_today then
    raise exception 'Las condiciones no pueden entrar en vigor en el pasado'
      using errcode = '22023';
  end if;

  if abs(p_upfront_pct + (p_per_installment_pct * 2) - 100.00) > 0.001 then
    raise exception 'El adelanto y las dos cuotas tienen que repartir el neto entero: % + (% × 2) da %, no 100',
      p_upfront_pct, p_per_installment_pct,
      p_upfront_pct + (p_per_installment_pct * 2)
      using errcode = '22023';
  end if;

  if p_upfront_pct < 0 or p_per_installment_pct < 0 or p_commission_pct < 0 then
    raise exception 'Ningún porcentaje puede ser negativo' using errcode = '22023';
  end if;

  select * into v_antes from public.helios_terms_at(p_merchant_id, v_today);

  insert into public.merchant_terms
    (merchant_id, upfront_pct, per_installment_pct, commission_pct, policy,
     effective_from, note, created_by)
  values (
    p_merchant_id, p_upfront_pct, p_per_installment_pct, p_commission_pct,
    p_policy::public.settlement_policy, v_desde,
    nullif(trim(coalesce(p_note, '')), ''), v_actor
  )
  on conflict (merchant_id, effective_from) do update
    set upfront_pct = excluded.upfront_pct,
        per_installment_pct = excluded.per_installment_pct,
        commission_pct = excluded.commission_pct,
        policy = excluded.policy,
        note = excluded.note,
        created_by = excluded.created_by,
        created_at = now();

  perform audit.log(v_actor, 'merchant.set_terms', p_merchant_id, jsonb_build_object(
    'merchant_name', v_name,
    'effective_from', v_desde,
    'from_upfront_pct', v_antes.upfront_pct,
    'to_upfront_pct', p_upfront_pct,
    'from_per_installment_pct', v_antes.per_installment_pct,
    'to_per_installment_pct', p_per_installment_pct,
    'from_commission_pct', v_antes.commission_pct,
    'to_commission_pct', p_commission_pct,
    'from_policy', v_antes.policy,
    'to_policy', p_policy,
    'note', p_note
  ));

  return jsonb_build_object('ok', true, 'effective_from', v_desde);
end;
$$;

comment on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text) is
  'Renegocia las condiciones de un comercio desde una fecha. No reescribe el pasado: los consumos anteriores se liquidan con las suyas.';

revoke all on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text)
  from public, anon;
grant execute on function public.admin_set_settlement_terms(uuid, numeric, numeric, numeric, text, date, text)
  to authenticated;

/** El histórico, para poder explicar por qué a una venta vieja se le pagó eso. */
create or replace function public.admin_merchant_terms_history(p_merchant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.effective_from desc), '[]'::jsonb)
  into v_rows
  from (
    select
      t.id, t.upfront_pct, t.per_installment_pct, t.commission_pct,
      t.policy::text as policy, t.effective_from, t.note, t.created_at,
      t.effective_from <= public.helios_business_date(now()) as is_current_or_past,
      coalesce(pa.full_name, 'Alguien del equipo') as created_by_name
    from public.merchant_terms t
    left join public.platform_admins pa on pa.user_id = t.created_by
    where t.merchant_id = p_merchant_id
  ) q;

  return v_rows;
end;
$$;

revoke all on function public.admin_merchant_terms_history(uuid) from public, anon;
grant execute on function public.admin_merchant_terms_history(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. El cron liquida con las condiciones del día de la venta
-- ---------------------------------------------------------------------------
-- Cuerpo del de 20260902120000 con un solo cambio: las condiciones salen de
-- `helios_terms_at(merchant, business_date del consumo)` en vez de las de hoy.
-- Es el arreglo del bug de arriba: bajarle el adelanto a un local el martes ya
-- no cambia lo que se le paga por lo que vendió el viernes.

create or replace function public.run_scheduled_settlements(p_business_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_charge record;
  v_terms  public.merchant_terms;
  v_amount numeric(18,4);
  v_room   numeric(18,4);
  v_count  integer := 0;
begin
  -- Un consumo por vuelta, no una cuota por vuelta: en un consumo de mesa hay
  -- una cuota por integrante venciendo el mismo día y todas hablan de la misma
  -- venta (ver 20260827080000).
  for v_charge in
    select distinct c.id as charge_id, c.merchant_id, c.business_date,
           coalesce(c.merchant_net_usd, c.amount_usd) as net_usd
    from public.installments i
    join public.charges c on c.id = i.charge_id
    where i.due_date = p_business_date
  loop
    -- Cada consumo en su propio bloque: el fallo de uno no puede llevarse la
    -- liquidación de todos los demás (20260829030000).
    begin
      -- 🔁 NUEVO (2026-09-11): las condiciones del DÍA DE LA VENTA.
      --
      -- Antes se leían las de hoy. Bajarle el adelanto a un local el martes
      -- cambiaba, en silencio, lo que se le iba a pagar por lo que vendió el
      -- viernes anterior — y el local no tenía forma de saber por qué le llegó
      -- otra cifra.
      select * into v_terms
      from public.helios_terms_at(
        v_charge.merchant_id,
        coalesce(v_charge.business_date, p_business_date)
      );

      if coalesce(v_terms.policy::text, '') <> 'scheduled' then
        continue;
      end if;

      if exists (
        select 1 from public.settlements
        where charge_id = v_charge.charge_id
          and reason = 'scheduled_installment'
          and business_date = p_business_date
      ) then
        continue;
      end if;

      v_amount := round(v_charge.net_usd * v_terms.per_installment_pct / 100, 4);

      -- NUEVO (2026-09-02): por un consumo nunca se devenga más que su neto.
      --
      -- Las ventas del 30-ago al 2-sep tienen el 100% encolado como adelanto y
      -- sus cuotas siguen venciendo; sin este techo cobrarían el 200%. Es un
      -- invariante y no una fecha de corte a propósito: también cubre el caso
      -- general —un comercio al que se le renegocian las condiciones a mitad
      -- del ciclo— sin que nadie tenga que acordarse.
      select v_charge.net_usd - coalesce(sum(s.amount_usd), 0)
        into v_room
      from public.settlements s
      where s.charge_id = v_charge.charge_id;

      v_amount := least(v_amount, v_room);

      -- Un tramo del 0% es política válida, y un techo agotado también. No hay
      -- nada que encolar, y encolarlo violaría el check (amount_usd > 0).
      if v_amount <= 0 then
        continue;
      end if;

      insert into public.settlements
        (merchant_id, charge_id, installment_id, reason, amount_usd, business_date, due_date, status)
      values
        (v_charge.merchant_id, v_charge.charge_id, null, 'scheduled_installment',
         v_amount, p_business_date, p_business_date, 'pending');

      v_count := v_count + 1;
    exception when others then
      -- Al log de Postgres, y el bucle sigue. Es un cron sin nadie delante:
      -- callar sería peor, pero parar el resto también.
      raise warning 'Liquidación programada fallida para el consumo % (comercio %): %',
        v_charge.charge_id, v_charge.merchant_id, sqlerrm;
    end;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.run_scheduled_settlements(date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Y la previsión del cierre, igual
-- ---------------------------------------------------------------------------
-- Mismo cuerpo que en 20260911191000 salvo el join de condiciones, que ahora
-- resuelve por la fecha del consumo.

create or replace function public.helios_settlement_outlook(p_merchant_id uuid)
returns table (
  today_date        date,
  next_run_date     date,
  next_run_usd      numeric,
  accrued_usd       numeric,
  accrued_count     integer,
  overdue_usd       numeric,
  oldest_due_date   date,
  upcoming_usd      numeric,
  total_pending_usd numeric,
  last_payout_on    date,
  last_payout_usd   numeric
)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    cal.today,
    cal.next_run,
    a.in_next_run + u.in_next_run,
    a.usd,
    a.n,
    a.overdue,
    a.oldest,
    u.usd,
    a.usd + u.usd,
    p.last_on,
    p.last_usd
  from (
    select public.helios_business_date(now())      as today,
           public.helios_next_settlement_run(now()) as next_run
  ) cal
  -- 1. Devengado y sin transferir. Lo que falta, no el importe original.
  cross join lateral (
    select
      coalesce(sum(s.amount_usd - s.paid_usd), 0)                              as usd,
      count(s.id)::int                                                         as n,
      min(s.due_date)                                                          as oldest,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where public.helios_settlement_run_for(s.due_date) < cal.next_run
      ), 0)                                                                    as overdue,
      coalesce(sum(s.amount_usd - s.paid_usd) filter (
        where s.due_date < cal.next_run), 0)                                   as in_next_run
    from public.settlements s
    where s.merchant_id = p_merchant_id
      and s.status in ('pending', 'partial')
  ) a
  -- 2. Lo que el cron encolará y todavía no existe, con las condiciones
  --    vigentes el día de CADA venta.
  cross join lateral (
    select
      coalesce(sum(f.amount_usd), 0)                                           as usd,
      coalesce(sum(f.amount_usd) filter (where f.due_date < cal.next_run), 0)  as in_next_run
    from (
      select
        d.due_date,
        greatest(0, least(
          d.tranche,
          d.room - coalesce(sum(d.tranche) over (
            partition by d.charge_id order by d.due_date
            rows between unbounded preceding and 1 preceding
          ), 0)
        )) as amount_usd
      from (
        select distinct
          c.id                                                   as charge_id,
          i.due_date,
          round(coalesce(c.merchant_net_usd, c.amount_usd) * t.per_installment_pct / 100, 4) as tranche,
          coalesce(c.merchant_net_usd, c.amount_usd) - coalesce((
            select sum(s2.amount_usd)
            from public.settlements s2
            where s2.charge_id = c.id
          ), 0)                                                  as room
        from public.installments i
        join public.charges c on c.id = i.charge_id
        cross join lateral public.helios_terms_at(
          c.merchant_id, coalesce(c.business_date, cal.today)
        ) t
        where c.merchant_id = p_merchant_id
          and t.policy = 'scheduled'
          and i.due_date >= cal.today
          and not exists (
            select 1 from public.settlements s3
            where s3.charge_id = c.id
              and s3.reason = 'scheduled_installment'
              and s3.business_date = i.due_date
          )
      ) d
    ) f
    where f.amount_usd > 0
  ) u
  left join lateral (
    select mp.paid_on as last_on, mp.amount_usd as last_usd
    from public.merchant_payouts mp
    where mp.merchant_id = p_merchant_id
    order by mp.paid_on desc nulls last, mp.created_at desc
    limit 1
  ) p on true;
$$;

revoke all on function public.helios_settlement_outlook(uuid) from public, anon;
grant execute on function public.helios_settlement_outlook(uuid) to authenticated;
