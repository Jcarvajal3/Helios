-- ============================================================================
-- Ronda — Corrige la búsqueda de personal por teléfono
--
-- Bug detectado al asignar un cajero desde el panel: escribir el número en
-- forma nacional (`0424 111-1111`) no encontraba a la persona, aunque su
-- cuenta existía con el teléfono `584241111111`.
--
-- Causa: `admin_add_merchant_staff` comparaba las cadenas de dígitos en
-- crudo. Pero en Venezuela el mismo número se escribe de dos formas
-- igualmente válidas:
--
--   0424 111 1111   → 11 dígitos, forma nacional con el 0 inicial
--   +58 424 1111111 → 12 dígitos, E.164 con código de país
--
-- Ninguna es "la correcta": GoTrue guarda la segunda, y el super admin va a
-- teclear la primera, que es la que le dicta el dueño del local.
--
-- Solución: comparar por los ÚLTIMOS 10 DÍGITOS, que son el número nacional
-- significativo (prefijo de operadora + abonado) y no cambian entre formatos.
-- Es la misma normalización que ya hace la app en
-- `src/features/auth/phone.ts`.
--
-- Por qué el test no lo detectó: usaba `+58 414-000.0053`, que normalizaba
-- exactamente a los dígitos guardados. Comprobaba la implementación, no el
-- caso real. El test se amplía para cubrir ambas formas.
-- ============================================================================

/** Número nacional significativo: los últimos 10 dígitos. Estable entre
 *  `0424...`, `58424...` y `+58 424 ...`. */
create or replace function public.phone_national_key(p_phone text)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
$$;

revoke all on function public.phone_national_key(text) from public, anon, authenticated;

create or replace function public.admin_add_merchant_staff(
  p_merchant_id uuid,
  p_phone       text,
  p_role        public.merchant_role,
  p_branch_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_user   uuid;
  v_branch uuid := p_branch_id;
  v_key    text;
  v_count  integer;
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede asignar personal' using errcode = '42501';
  end if;

  v_key := public.phone_national_key(p_phone);

  if length(v_key) < 10 then
    raise exception 'El teléfono % está incompleto', p_phone using errcode = '22023';
  end if;

  select count(*) into v_count from auth.users
  where public.phone_national_key(phone) = v_key;

  if v_count = 0 then
    raise exception 'No hay ninguna cuenta con el teléfono %. Pídele que se registre primero en la app.', p_phone
      using errcode = 'P0002';
  end if;

  -- Dos cuentas con el mismo número nacional no debería pasar nunca, pero si
  -- pasa hay que pararlo: asignar "una cualquiera" daría acceso al cobro a la
  -- persona equivocada.
  if v_count > 1 then
    raise exception 'Hay % cuentas con ese teléfono. Resuélvelo antes de asignar.', v_count
      using errcode = '22023';
  end if;

  select id into v_user from auth.users
  where public.phone_national_key(phone) = v_key;

  -- Un cajero siempre trabaja en una sucursal concreta (lo exige el check
  -- cajero_requires_branch). Si no se indica, va a la principal.
  if p_role = 'cajero' and v_branch is null then
    select id into v_branch from public.merchant_branches
    where merchant_id = p_merchant_id and is_default;
  end if;

  insert into public.merchant_users (user_id, merchant_id, branch_id, role)
  values (v_user, p_merchant_id, v_branch, p_role)
  on conflict (user_id, merchant_id, branch_id) do update
    set role = excluded.role, is_active = true;

  perform audit.log(v_actor, 'merchant.staff_added', p_merchant_id,
    jsonb_build_object('user_id', v_user, 'role', p_role));

  return jsonb_build_object('ok', true, 'user_id', v_user, 'branch_id', v_branch);
end;
$$;

revoke all on function public.admin_add_merchant_staff(uuid, text, public.merchant_role, uuid)
  from public, anon;
grant execute on function public.admin_add_merchant_staff(uuid, text, public.merchant_role, uuid)
  to authenticated;
