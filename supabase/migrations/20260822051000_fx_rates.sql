-- ============================================================================
-- Ronda — Tasa de cambio USD/BCV
--
-- Decisión confirmada (docs/05-REGLAS-CONFIRMADAS.md §1): el USD es la moneda
-- canónica. Toda deuda, límite y nivel vive en USD. El VES es solo capa de
-- presentación y liquidación, a la tasa BCV vigente el día del pago.
--
-- El BCV publica una vez al día en días hábiles: la resolución de tasa usa
-- "última tasa con effective_date <= hoy", nunca una búsqueda exacta por
-- fecha, para que fines de semana y feriados resuelvan a la última publicada.
-- ============================================================================

create table if not exists public.exchange_rates (
  id             uuid primary key default gen_random_uuid(),
  source         text not null default 'BCV',
  rate           numeric(18,6) not null check (rate > 0),
  effective_date date not null,
  fetched_at     timestamptz not null default now(),
  unique (source, effective_date)
);

comment on table public.exchange_rates is
  'Tasas BCV. La ingesta es un job diario (fuera de este esquema); esta tabla solo persiste.';

create index if not exists exchange_rates_lookup_idx
  on public.exchange_rates (source, effective_date desc);

alter table public.exchange_rates enable row level security;

create policy "exchange_rates_read"
  on public.exchange_rates for select
  to authenticated
  using (true);

-- Última tasa vigente a la fecha dada (o a hoy si no se especifica).
-- "última tasa <= fecha", nunca coincidencia exacta: así resuelve fines de
-- semana y feriados a la última publicada en día hábil.
create or replace function public.current_fx_rate(p_source text default 'BCV', p_as_of date default null)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select rate
  from public.exchange_rates
  where source = p_source
    and effective_date <= coalesce(p_as_of, public.helios_business_date(now()))
  order by effective_date desc
  limit 1;
$$;

revoke all on function public.current_fx_rate(text, date) from public, anon;
grant execute on function public.current_fx_rate(text, date) to authenticated;

-- Registra la tasa del día. Lo llama el job de ingesta (service role), nunca
-- el cliente: una tasa manipulada es la forma más barata de robar a Ronda.
create or replace function public.record_fx_rate(
  p_rate           numeric,
  p_effective_date date,
  p_source         text default 'BCV'
)
returns public.exchange_rates
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.exchange_rates%rowtype;
begin
  if p_rate <= 0 then
    raise exception 'La tasa debe ser positiva' using errcode = '22023';
  end if;

  insert into public.exchange_rates (source, rate, effective_date)
  values (p_source, p_rate, p_effective_date)
  on conflict (source, effective_date) do update
    set rate = excluded.rate, fetched_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

-- Sin grant: solo el service role (el job de ingesta) puede llamarla.
revoke all on function public.record_fx_rate(numeric, date, text) from public, anon, authenticated;

-- Semilla de desarrollo. En producción la reemplaza el job de ingesta diario;
-- sin esta fila, cualquier cotización local falla por falta de tasa.
insert into public.exchange_rates (source, rate, effective_date)
values ('BCV', 40.00, current_date)
on conflict (source, effective_date) do nothing;
