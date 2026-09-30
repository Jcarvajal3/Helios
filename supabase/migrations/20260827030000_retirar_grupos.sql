-- ============================================================================
-- Ronda — Retirar los grupos
--
-- La mesa (20260827000000) los sustituye entera. Aquí se apaga lo que queda
-- del modelo viejo en el servidor.
--
-- ---------------------------------------------------------------------------
-- Se van las RPC. Se quedan las tablas.
-- ---------------------------------------------------------------------------
-- Sin las RPC no se puede crear un grupo, entrar a uno ni cobrarle: la
-- superficie desaparece y con ella cualquier forma de usarlos, incluso desde
-- un cliente viejo que todavía tenga las pantallas.
--
-- Las TABLAS no se tiran, y no es por prudencia vaga:
--
--   · `charges.group_id` apunta a `groups`. Cada cobro repartido de la
--     historia lleva esa referencia, y tirar la tabla obligaría a romper la
--     clave ajena y a dejar huérfanos cobros que siguen teniendo cuotas vivas
--     y que soporte tiene que poder explicar por teléfono.
--   · `group_members` guarda quién autorizó qué y cuándo (`authorized_at`).
--     Es el registro del consentimiento de una deuda que en algunos casos
--     todavía se está pagando. Borrarlo es borrar la prueba de por qué alguien
--     debe dinero.
--
-- Quedan como archivo: nadie escribe en ellas y nadie las lee desde la app.
-- Cuando no quede ninguna cuota viva de un cobro de grupo se podrán tirar, y
-- ese día será una decisión de una línea.
--
-- ---------------------------------------------------------------------------
-- Por qué `group_holds_usd` SOBREVIVE, devolviendo cero
-- ---------------------------------------------------------------------------
-- Es la única pieza de grupos que tres funciones de dinero siguen llamando:
-- `my_available_balance`, `preview_charge` y `confirm_charge`. Restaba del
-- disponible lo retenido en tickets.
--
-- Sin grupos vivos ya devolvía cero por sí sola, así que fijarla en cero no
-- cambia ningún número — lo que hace es cortar la dependencia sin tener que
-- reescribir, dentro de este mismo cambio, el camino del cobro individual.
-- Ese camino es el código más delicado del producto y no tiene nada que ver
-- con lo que se está cambiando aquí; tocarlo de paso sería meter el riesgo
-- grande dentro del cambio grande.
--
-- ⬜ Pendiente, y no bloquea: sacar la llamada de esas tres funciones y
--    borrar esta. Es un cambio pequeño, aislado y fácil de revisar solo.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Nada nuevo puede entrar
-- ---------------------------------------------------------------------------

drop trigger if exists group_members_max_size on public.group_members;
drop trigger if exists charges_notify_group   on public.charges;
drop trigger if exists charges_stamp_group_name on public.charges;

drop function if exists public.enforce_group_size();
drop function if exists public.notify_group_charge();
drop function if exists public.stamp_charge_group_name();

drop function if exists public.create_group(text, numeric);
drop function if exists public.join_group(text);
drop function if exists public.leave_group(uuid);
drop function if exists public.close_group(uuid);
drop function if exists public.my_groups();
drop function if exists public.group_detail(uuid);
drop function if exists public.find_group_by_code(text);
drop function if exists public.generate_invite_code();
drop function if exists public.preview_group_charge(uuid, uuid);
drop function if exists public.confirm_charge_as_group(uuid, uuid, text, text);

-- `my_group_ids()` NO se tira, y el motivo lo dio la propia base al negarse:
-- sostiene cuatro políticas RLS —sobre `groups`, `group_members`, `profiles` y
-- `charges`— y dos de esas tablas están muy vivas. Tirarla obligaría a
-- reescribir el acceso a perfiles y cobros dentro de este cambio.
--
-- Dejarla no abre nada: nadie puede entrar a un grupo nuevo, así que para
-- cualquier usuario de aquí en adelante devuelve el conjunto vacío y esas
-- políticas no conceden nada. Para quien SÍ estuvo en un grupo, conceden
-- exactamente lo de antes: poder seguir viendo la historia que ya era suya.
--
-- La mesa no depende de ellas: sus RPC son `security definer` y deciden por su
-- cuenta a quién enseñan qué.

-- ---------------------------------------------------------------------------
-- 2. Lo retenido en grupos es cero para siempre
-- ---------------------------------------------------------------------------

create or replace function public.group_holds_usd(p_user uuid)
returns numeric
language sql
immutable
as $$
  -- Los grupos se retiraron el 2026-08-27. Nadie puede tener nada retenido
  -- porque nadie puede entrar a un grupo: no queda RPC que lo permita.
  --
  -- La firma se conserva a propósito. `my_available_balance`, `preview_charge`
  -- y `confirm_charge` la llaman, y este cambio no reescribe el cobro
  -- individual — ver la cabecera.
  select 0::numeric;
$$;

comment on function public.group_holds_usd(uuid) is
  'Muerta: devuelve 0. Sobrevive solo porque tres funciones de dinero la
   llaman. Los grupos se retiraron el 2026-08-27 (ver 20260827030000).';

revoke all on function public.group_holds_usd(uuid) from public, anon;
grant execute on function public.group_holds_usd(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Las tablas quedan como archivo
-- ---------------------------------------------------------------------------

comment on table public.groups is
  'ARCHIVO. Modelo retirado el 2026-08-27, sustituido por public.tabs (la
   mesa). No se escribe ni se lee desde la app. Se conserva porque
   charges.group_id apunta aquí y hay cobros con cuotas vivas.';

comment on table public.group_members is
  'ARCHIVO. Guarda el consentimiento (authorized_at) de deudas que en algunos
   casos todavía se están pagando: borrarlo sería borrar la prueba de por qué
   alguien debe dinero.';

-- Ninguna política de lectura nueva: las que había siguen siendo válidas para
-- que soporte y el super admin puedan mirar la historia.
