-- ============================================================================
-- Ronda — La app anota cuatro gestos de quien usa Ronda
--
-- Pedido de Javier (28-09): en Por cobrar, quien cobra tiene que saber qué
-- hizo cada deudor antes de escribirle. De lo que hay en la base ya salen la
-- última apertura (push_tokens.last_seen_at, en cada arranque), los avisos,
-- los pagos reportados y las gestiones. Faltaban cuatro gestos, y los anota
-- la app con `log_app_activity`:
--
--   app_open          la app vuelve a primer plano (no solo el arranque en frío)
--   pay_screen        se abre «Reportar pago» (metodo-pago)
--   pay_data_copied   se copia un dato de la cuenta destino o el monto
--   push_opened       se toca un push; `detail` es su tipo (installment_due…)
--
-- Cuentan desde el día en que sale la OTA que los anota: antes de eso no hay
-- nada, y el panel lo sabe mirando si la persona tiene alguna fila.
--
-- Una fila no es un dato del negocio: es una pista para quien cobra. Por eso
-- la tabla no guarda nada más que el gesto, y la RPC descarta el mismo gesto
-- repetido en 10 minutos (la app vuelve a primer plano muchas veces al
-- copiar un dato y pasar al banco).
-- ============================================================================

create table if not exists public.app_activity (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  kind       text not null
             check (kind in ('app_open', 'pay_screen', 'pay_data_copied', 'push_opened')),
  detail     text check (detail is null or length(detail) <= 64),
  created_at timestamptz not null default now()
);

comment on table public.app_activity is
  'Gestos de la persona en la app que sirven a la cobranza (Por cobrar › señales). Los escribe la app con log_app_activity(); no hay políticas.';

create index if not exists app_activity_user_kind_idx
  on public.app_activity (user_id, kind, created_at desc);

alter table public.app_activity enable row level security;
-- Sin políticas: se escribe por la RPC y se lee desde funciones del panel.

create or replace function public.log_app_activity(p_kind text, p_detail text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    return;
  end if;
  if p_kind not in ('app_open', 'pay_screen', 'pay_data_copied', 'push_opened') then
    raise exception 'Gesto desconocido: %', p_kind using errcode = '22023';
  end if;

  -- El mismo gesto en los últimos 10 minutos ya está anotado.
  if exists (
    select 1 from public.app_activity a
    where a.user_id = v_user
      and a.kind = p_kind
      and a.detail is not distinct from left(p_detail, 64)
      and a.created_at > now() - interval '10 minutes'
  ) then
    return;
  end if;

  insert into public.app_activity (user_id, kind, detail)
  values (v_user, p_kind, left(p_detail, 64));
end;
$$;

comment on function public.log_app_activity(text, text) is
  'Anota un gesto de la persona (app_open, pay_screen, pay_data_copied, push_opened). Idempotente en 10 minutos.';

revoke all on function public.log_app_activity(text, text) from public, anon;
grant execute on function public.log_app_activity(text, text) to authenticated;
