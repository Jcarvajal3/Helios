-- ============================================================================
-- Helios — El financiamiento guarda sus términos y su comisión (H9 + H5, esquema)
--
-- 1. H9 — `terms_versions` guarda las CONDICIONES DEL FINANCIAMIENTO que van en
--    el comprobante (cuotas, cargo por atraso, mora). Gana un `id` uuid (la
--    clave sigue siendo `version`) para que cada financiamiento apunte a la
--    versión con la que se le comunicó al paciente. Si la tabla está vacía se
--    siembra la v1 en español con las reglas de Helios en dólares.
-- 2. `charges` gana:
--      · `concept`            texto corto («Consulta», «Consulta + eco»);
--      · `beneficiary_name`   quién se atendió, si no es el titular (D-H5);
--      · `terms_version_id`   la versión vigente al registrarlo (o null);
--      · `staff_commission_usd` y `commission_staff_id`: la INSTANTÁNEA de la
--        comisión (docs/00 §6). Si mañana cambia el parámetro, lo devengado no
--        se recalcula.
-- 3. H5 — `merchant_terms.staff_commission_usd`: la comisión pactada con una
--    clínica. Null = usa el parámetro global `staff_commission_usd`. Va con la
--    vigencia de las condiciones (`effective_from`).
-- 4. `staff_commissions`: una fila por financiamiento con comisión. Estado
--    `devengada` → `pagada` (cuando su liquidación queda pagada entera, por un
--    trigger sobre `settlements`) o `revertida` (reversa del financiamiento).
--    La lee el equipo; la clínica la ve por `merchant_commissions`.
-- 5. `merchant_payouts` gana `consultas_usd` y `comisiones_usd`: la
--    transferencia partida (docs/01 §1.5). La llena
--    `admin_report_merchant_payout`. Las filas viejas: todo era consultas.
-- 6. `helios_staff_commission_for(merchant, fecha)`: el monto que toca, con la
--    regla «la de la clínica vigente ese día, si no la global».
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las condiciones del financiamiento (H9)
-- ---------------------------------------------------------------------------

alter table public.terms_versions
  add column id uuid not null default gen_random_uuid();

alter table public.terms_versions
  add constraint terms_versions_id_key unique (id);

comment on table public.terms_versions is
  'Condiciones del financiamiento que van en el comprobante (H9). Cada financiamiento guarda el id de la versión vigente al registrarlo (charges.terms_version_id). Una versión publicada no se reescribe.';

insert into public.terms_versions (version, body, summary, is_current)
select
  'v1',
  E'Condiciones del financiamiento con Helios\n\n'
  || E'1. Helios financia el monto de tu consulta en la clínica. Lo pagas en 2 cuotas semanales, sin inicial: la primera vence 7 días después de la fecha del financiamiento y la segunda, 14 días después.\n'
  || E'2. Cada cuota incluye una parte del monto de la consulta y del servicio Helios (20 % sobre el monto de la consulta, más el IVA de ese servicio). El comprobante detalla cada monto.\n'
  || E'3. Los montos están en dólares de los Estados Unidos. Pagas en bolívares, a la tasa oficial del Banco Central de Venezuela del día en que pagues, por Pago Móvil o transferencia a las cuentas de Helios que aparecen en el comprobante. Después de pagar, envía el comprobante del pago por WhatsApp a Helios.\n'
  || E'4. Mientras tengas una cuota vencida no podrás financiar nuevas consultas con Helios.\n'
  || E'5. Si una cuota sigue sin pagar después de 3 días de su vencimiento, se suma un cargo por atraso de USD 2 a esa cuota.\n'
  || E'6. A los 30 días de atraso la cuenta se suspende. A los 60 días se cierra, la cédula queda en la lista de personas que Helios no financia y la deuda pasa a cobranza.\n'
  || E'7. Helios puede contactarte por WhatsApp, por teléfono o por correo, a ti o al contacto de referencia que diste al registrarte, para recordarte tus pagos.\n'
  || E'8. Si no reconoces un financiamiento a tu nombre, escríbenos enseguida por WhatsApp.',
  'Condiciones v1: 2 cuotas semanales sin inicial, servicio 20 % + IVA, cargo de USD 2 tras 3 días de atraso, suspensión a los 30 días y cierre a los 60.',
  true
where not exists (select 1 from public.terms_versions);

-- ---------------------------------------------------------------------------
-- 2. Lo que el financiamiento guarda
-- ---------------------------------------------------------------------------

alter table public.charges
  add column concept              text,
  add column beneficiary_name     text,
  add column terms_version_id     uuid references public.terms_versions(id),
  add column staff_commission_usd numeric(18,4),
  add column commission_staff_id  uuid references auth.users(id);

alter table public.charges
  add constraint charges_concept_check
    check (concept is null or (btrim(concept) <> '' and length(concept) <= 80)),
  add constraint charges_beneficiary_name_check
    check (beneficiary_name is null or (btrim(beneficiary_name) <> '' and length(beneficiary_name) <= 120)),
  add constraint charges_staff_commission_check
    check (staff_commission_usd is null or staff_commission_usd >= 0);

comment on column public.charges.concept is 'Qué se financió, en texto corto («Consulta»). También es el nombre de su única línea en charge_items.';
comment on column public.charges.beneficiary_name is 'Quién se atendió, si no es el titular de la deuda (el menor que atendieron; D-H5).';
comment on column public.charges.terms_version_id is 'Versión de las condiciones (terms_versions) vigente al registrar el financiamiento: la que va en el comprobante.';
comment on column public.charges.staff_commission_usd is 'Instantánea de la comisión de quien lo registró (H5). No se recalcula si cambia el parámetro.';
comment on column public.charges.commission_staff_id is 'Quién gana la comisión (el personal que lo registró).';

-- ---------------------------------------------------------------------------
-- 3. La comisión pactada con una clínica
-- ---------------------------------------------------------------------------

alter table public.merchant_terms
  add column staff_commission_usd numeric(18,4);

alter table public.merchant_terms
  add constraint merchant_terms_staff_commission_check
    check (staff_commission_usd is null
           or (staff_commission_usd >= 0 and staff_commission_usd = round(staff_commission_usd, 2)));

comment on column public.merchant_terms.staff_commission_usd is
  'Comisión por financiamiento para el personal de esta clínica. Null = el parámetro global staff_commission_usd.';

-- ---------------------------------------------------------------------------
-- 4. Las comisiones
-- ---------------------------------------------------------------------------

create table public.staff_commissions (
  id            uuid primary key default gen_random_uuid(),
  charge_id     uuid not null unique references public.charges(id),
  merchant_id   uuid not null references public.merchants(id),
  staff_user_id uuid not null references auth.users(id),
  amount_usd    numeric(18,4) not null check (amount_usd > 0),
  -- `on delete set null`: la reversa borra la liquidación pendiente (como
  -- hace con las de las cuotas) y la comisión queda `revertida`.
  settlement_id uuid references public.settlements(id) on delete set null,
  status        text not null default 'devengada'
                check (status in ('devengada', 'pagada', 'revertida')),
  created_at    timestamptz not null default now()
);

comment on table public.staff_commissions is
  'Comisión de la secretaria por financiamiento confirmado (H5, docs/00 §6). Se paga a la clínica dentro de la transferencia del lunes (settlements.reason = staff_commission).';

create index staff_commissions_merchant_idx on public.staff_commissions (merchant_id, created_at);
create index staff_commissions_staff_idx    on public.staff_commissions (staff_user_id, created_at);
create index staff_commissions_settlement_idx on public.staff_commissions (settlement_id)
  where settlement_id is not null;

alter table public.staff_commissions enable row level security;
revoke all on public.staff_commissions from anon, authenticated;
grant select on public.staff_commissions to authenticated;

create policy staff_commissions_read_admin on public.staff_commissions
  for select to authenticated
  using ((select public.is_platform_admin()));

/**
 * La comisión sigue a su liquidación: pagada entera → `pagada`; si vuelve a
 * quedar pendiente o parcial (no debería), `devengada`. Una revertida no se
 * toca. Así cualquier forma de pagar una liquidación (entera, parcial en
 * varias transferencias) deja la comisión bien.
 */
create or replace function public.helios_sync_staff_commission_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.reason = 'staff_commission' and new.status is distinct from old.status then
    update public.staff_commissions
       set status = case when new.status = 'paid' then 'pagada' else 'devengada' end
     where settlement_id = new.id
       and status <> 'revertida';
  end if;
  return new;
end;
$$;

revoke all on function public.helios_sync_staff_commission_status() from public, anon, authenticated;

create trigger settlements_sync_staff_commission
  after update of status on public.settlements
  for each row execute function public.helios_sync_staff_commission_status();

-- ---------------------------------------------------------------------------
-- 5. La transferencia partida
-- ---------------------------------------------------------------------------

alter table public.merchant_payouts
  add column consultas_usd  numeric(18,4) not null default 0,
  add column comisiones_usd numeric(18,4) not null default 0;

update public.merchant_payouts set consultas_usd = amount_usd where consultas_usd = 0;

comment on column public.merchant_payouts.consultas_usd  is 'Parte de la transferencia que paga consultas (liquidaciones que no son comisión).';
comment on column public.merchant_payouts.comisiones_usd is 'Parte de la transferencia que paga comisiones del personal (settlements.reason = staff_commission).';

-- ---------------------------------------------------------------------------
-- 6. Cuánto es la comisión
-- ---------------------------------------------------------------------------

/**
 * La comisión por financiamiento en una clínica un día dado: la pactada en
 * sus condiciones vigentes ese día (`merchant_terms.staff_commission_usd`) o,
 * si es null, el parámetro global vigente ese día.
 */
create or replace function public.helios_staff_commission_for(p_merchant_id uuid, p_on date)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select t.staff_commission_usd from public.helios_terms_at(p_merchant_id, p_on) t),
    (select p.value
       from public.business_parameters p
      where p.key = 'staff_commission_usd' and p.effective_from <= p_on
      order by p.effective_from desc
      limit 1),
    0.50
  )::numeric(18,4);
$$;

revoke all on function public.helios_staff_commission_for(uuid, date) from public, anon, authenticated;
