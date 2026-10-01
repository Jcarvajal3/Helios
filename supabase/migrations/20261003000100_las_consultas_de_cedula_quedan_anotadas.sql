-- ============================================================================
-- Helios — Las consultas de cédula quedan anotadas (H4, parte 0)
--
-- Cada vez que el personal de una clínica consulta si un paciente es elegible
-- (`helios_patient_eligibility`) queda una fila aquí. Sirve para dos cosas:
--
--   1. El límite diario de consultas por persona del personal
--      (`helios_eligibility_lookups_per_staff_day()`).
--   2. La alerta `consultas_de_cedula_excesivas` del tablero de riesgo.
--
-- `document_key` es la cédula normalizada (la misma clave que usa
-- `profiles.document_number`), no el texto tal cual lo tecleó la secretaria.
-- `result` es lo que se le respondió: 'nuevo', 'registrado', 'no_disponible'
-- o 'limite' (la consulta que ya excedía el límite; se anota igual).
--
-- Solo el equipo la lee; nadie la escribe directo (la escribe la RPC, que es
-- security definer).
-- ============================================================================

create table public.eligibility_lookups (
  id            uuid primary key default gen_random_uuid(),
  staff_user_id uuid not null references auth.users(id),
  merchant_id   uuid references public.merchants(id),
  document_key  text not null,
  result        text not null,
  created_at    timestamptz not null default now()
);

comment on table public.eligibility_lookups is
  'Bitácora de consultas de cédula del personal de las clínicas (límite diario y alerta de consultas excesivas).';

create index eligibility_lookups_staff_created_idx
  on public.eligibility_lookups (staff_user_id, created_at);

alter table public.eligibility_lookups enable row level security;
revoke all on public.eligibility_lookups from anon, authenticated;
grant select on public.eligibility_lookups to authenticated;

create policy eligibility_lookups_read_admin on public.eligibility_lookups
  for select to authenticated
  using ((select public.is_platform_admin()));
