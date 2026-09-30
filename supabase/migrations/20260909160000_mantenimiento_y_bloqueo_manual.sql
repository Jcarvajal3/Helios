-- ============================================================================
-- Ronda — Mantenimiento global y bloqueo manual de una cuenta
--
-- Dos frenos de emergencia que no existían, y una abstracción que los une con
-- la lista de espera del piloto: **por qué esta persona no puede gastar, dicho
-- con un texto que se le puede enseñar**.
--
-- ---------------------------------------------------------------------------
-- 1. Mantenimiento
-- ---------------------------------------------------------------------------
-- Un interruptor global para situaciones extremas —la tasa no entra, el KYC
-- está caído, hay un fallo de cobro, se detecta un fraude en curso—: apaga el
-- saldo de TODO el mundo y enseña un aviso escrito para la ocasión.
--
-- Dos grados, porque no toda emergencia es la misma:
--
--   is_active + blocks_balance   El saldo se apaga. Nadie consume.
--   is_active sin blocks_balance Solo el aviso. Todo sigue funcionando.
--                                (mantenimiento programado, aviso de una caída
--                                 parcial, un "esta noche vamos lentos")
--
-- El texto es obligatorio y es lo único que el usuario va a leer: "Estamos en
-- mantenimiento" a secas no le dice si son diez minutos o dos días. Por eso
-- hay `expected_back`, en texto libre, que es como se dice de verdad ("hoy a
-- las 10 PM", "mañana temprano").
--
-- NO bloquea pagar ni reportar un pago. Apagar el cobro de la cartera durante
-- una emergencia convierte un problema técnico en un problema de caja, y a
-- quien tiene una cuota venciendo hoy le crea una mora que no es suya.
--
-- ---------------------------------------------------------------------------
-- 2. Bloqueo manual de una cuenta
-- ---------------------------------------------------------------------------
-- Existía a medias y con un agujero. Lo que había:
--
--   · `admin_set_user_status` mueve `profiles.status` a frozen/suspended/
--     expelled, con motivo y bitácora.
--   · Todo lo que crea deuda exige `status = 'active'`, así que en el momento
--     sí bloquea.
--
-- 🐛 El agujero: **el motor de mora lo deshace solo**. `process_mora` corre
-- todos los días a las 10:05 y hace, textualmente, "sin mora → si venía
-- bloqueado, se restablece el acceso": cualquiera en `frozen` o `suspended`
-- que no tenga una cuota vencida vuelve a `active` a la mañana siguiente. O
-- sea que sancionar a mano a alguien que no debe nada —el caso típico: fraude,
-- suplantación, abuso— dura hasta las 10 AM del día siguiente, y nadie se
-- entera de que dejó de estar sancionado.
--
-- Quedaba `expelled`, que el motor sí respeta, pero es terminal, marca la
-- cédula en la lista negra y en la app se lee como "no pagaste": es el
-- martillo, no la sanción.
--
-- La corrección no es pelearse con el motor de mora, es **sacar el bloqueo
-- manual de `profiles.status`**. Son dos dimensiones distintas:
--
--   status        lo gobierna la mora (frozen → suspended → expelled)
--   user_blocks   lo gobierna una persona del equipo, con motivo y mensaje
--
-- Así el motor puede seguir restaurando el acceso por mora sin tocar la
-- sanción, la sanción sobrevive a que el usuario pague, y se levanta a
-- propósito y por alguien con nombre.
--
-- Un bloqueo apaga TODO lo que compromete dinero: el saldo, consumir,
-- escanear, crear grupos y entrar en ellos, y asumir parte de una cuenta. NO
-- apaga pagar: cobrarle a alguien sancionado es exactamente lo que se quiere,
-- y quitarle la forma de saldar su deuda solo garantiza que no la salde.
--
-- ---------------------------------------------------------------------------
-- 3. Un solo sitio que responde "¿por qué no puedes gastar?"
-- ---------------------------------------------------------------------------
-- `helios_spend_block(user)` devuelve el motivo, con su texto ya escrito, o
-- null. De ahí beben el disponible, la pantalla de Inicio y el único sitio que
-- crea deuda. Un motivo nuevo se añade ahí y aparece en las tres a la vez.
--
-- La mora NO entra aquí a propósito: ya tiene su tratamiento en la app —la
-- tarjeta de la cuota vencida, con su importe y su botón— y meterla como un
-- aviso más sería taparlo con un cartel que no se puede accionar.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Mantenimiento
-- ---------------------------------------------------------------------------

create table if not exists public.platform_maintenance (
  -- Fila única. El check sobre la clave primaria es lo que lo garantiza: no
  -- hace falta acordarse de filtrar por id en ninguna consulta.
  id             boolean primary key default true check (id),
  is_active      boolean not null default false,
  -- Si además de avisar, apaga el saldo.
  blocks_balance boolean not null default true,
  title          text not null default 'Estamos en mantenimiento',
  message        text not null default
    'Estamos resolviendo un problema. Tu saldo vuelve en cuanto terminemos.',
  -- Texto libre: "hoy a las 10 PM", "mañana temprano". Una fecha exacta que
  -- luego se incumple es peor que no prometer nada.
  expected_back  text,
  started_at     timestamptz,
  updated_by     uuid references auth.users (id),
  updated_at     timestamptz not null default now()
);

comment on table public.platform_maintenance is
  'Freno de emergencia global: apaga el saldo de todos y enseña un aviso escrito para la ocasion. Fila unica.';

insert into public.platform_maintenance (id) values (true) on conflict (id) do nothing;

alter table public.platform_maintenance enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Bloqueo manual
-- ---------------------------------------------------------------------------

create table if not exists public.user_blocks (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  -- Para el equipo. No se le enseña al usuario.
  reason      text not null,
  -- Para el usuario. Es lo único que va a leer, así que es obligatorio y no
  -- tiene default: un bloqueo sin explicación es una app rota, y el usuario
  -- llama a soporte a preguntar qué pasó.
  message     text not null,
  blocked_by  uuid not null references auth.users (id),
  blocked_at  timestamptz not null default now(),
  lifted_at   timestamptz,
  lifted_by   uuid references auth.users (id),
  lift_note   text,
  constraint user_blocks_lift_consistency
    check ((lifted_at is null) = (lifted_by is null))
);

-- Un bloqueo abierto por persona: es lo que hace "¿está bloqueada?" una
-- pregunta con una sola respuesta.
create unique index if not exists user_blocks_one_open
  on public.user_blocks (user_id) where lifted_at is null;

create index if not exists user_blocks_user_idx
  on public.user_blocks (user_id, blocked_at desc);

comment on table public.user_blocks is
  'Sancion manual del equipo, ortogonal a profiles.status. Vive fuera del motor de mora a proposito: process_mora restaura status a active y borraria la sancion. Ver 20260909160000.';

alter table public.user_blocks enable row level security;

-- Sin políticas: todo pasa por RPC. El usuario no lee su fila —
-- `my_available_balance` ya le da el mensaje— y así el motivo interno no sale
-- nunca del panel.

-- ---------------------------------------------------------------------------
-- 3. El motivo, con su texto
-- ---------------------------------------------------------------------------
/**
 * Por qué esta persona no puede gastar, o null si puede.
 *
 *   { code, title, message, blocks_balance }
 *
 * El orden mira PRIMERO lo que de verdad apaga el saldo. Un mantenimiento
 * meramente informativo no puede tapar a un bloqueo que sí bloquea: se leería
 * "estamos en mantenimiento, todo sigue funcionando" con el saldo en cero.
 */
create or replace function public.helios_spend_block(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_m     public.platform_maintenance%rowtype;
  v_block public.user_blocks%rowtype;
  v_wait  timestamptz;
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

  -- 3. Lista de espera del piloto (20260909151000).
  if public.helios_waitlisted(p_user) then
    select entered_at into v_wait
    from public.credit_waitlist
    where user_id = p_user and released_at is null;

    return jsonb_build_object(
      'code', 'waitlist',
      'title', 'Tu saldo está en lista de espera',
      'message', 'Ya estás dentro de Helios. Te avisamos en cuanto puedas usar tu saldo.',
      'blocks_balance', true,
      'since', v_wait
    );
  end if;

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
$$;

comment on function public.helios_spend_block(uuid) is
  'Por que esta persona no puede gastar, con el texto que se le enseña: mantenimiento, bloqueo manual o lista de espera. La mora NO entra aqui, tiene su propio tratamiento en la app.';

revoke all on function public.helios_spend_block(uuid) from public, anon;
grant execute on function public.helios_spend_block(uuid) to authenticated;

/** ¿Hay algo que le apague el saldo ahora mismo? La versión de una línea. */
create or replace function public.helios_spend_blocked(p_user uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(
    (public.helios_spend_block(p_user)->>'blocks_balance')::boolean,
    false
  );
$$;

revoke all on function public.helios_spend_blocked(uuid) from public, anon;
grant execute on function public.helios_spend_blocked(uuid) to authenticated;

/** El mantenimiento, para quien no es un consumidor: el panel del comercio y
 *  el super admin. Devuelve siempre una fila, con `is_active` en falso cuando
 *  no pasa nada. */
create or replace function public.helios_maintenance()
returns jsonb
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select jsonb_build_object(
    'is_active', m.is_active,
    'blocks_balance', m.blocks_balance,
    'title', m.title,
    'message', m.message,
    'expected_back', m.expected_back,
    'started_at', m.started_at,
    'updated_at', m.updated_at
  )
  from public.platform_maintenance m;
$$;

revoke all on function public.helios_maintenance() from public, anon;
grant execute on function public.helios_maintenance() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Donde muerde
-- ---------------------------------------------------------------------------

/**
 * 🔁 Cuerpo de 20260824140000 con una condición más.
 *
 * Es la puerta que miran los grupos —crear, entrar, iniciar un cobro, asumir
 * una parte— y el consumo. Meter aquí el bloqueo cierra las seis vías a la
 * vez, que es justo lo que se pide de una sanción: que no quede un rincón por
 * el que se pueda seguir comprometiendo dinero.
 */
create or replace function public.can_take_debt(p_user uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    exists (select 1 from public.profiles where id = p_user and status = 'active')
    -- NUEVO: mantenimiento, sanción del equipo o lista de espera.
    and not public.helios_spend_blocked(p_user)
    and not exists (
      select 1 from public.installments
      where user_id = p_user
        and status = 'pending'
        and due_date < public.helios_business_date(now())
    );
$$;

revoke all on function public.can_take_debt(uuid) from public, anon;
grant execute on function public.can_take_debt(uuid) to authenticated;

/**
 * 🔁 Cuerpo de 20260909151000 con la rama de la lista de espera generalizada.
 *
 * Antes preguntaba solo por `helios_waitlisted`; ahora pregunta por el motivo,
 * sea cual sea. Un freno nuevo no vuelve a pasar por aquí.
 */
create or replace function public.available_usd(p_user uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select case
    when public.helios_in_arrears(p_user) then 0
    -- Mantenimiento, bloqueo manual o lista de espera.
    when public.helios_spend_blocked(p_user) then 0
    else greatest(
      coalesce((select l.monthly_limit_usd
                from public.profiles p
                join public.levels l on l.level = p.level
                where p.id = p_user), 0)
      - public.helios_credit_used_usd(p_user),
      0
    )
  end;
$$;

revoke all on function public.available_usd(uuid) from public, anon, authenticated;

/**
 * 🔁 Cuerpo de 20260909151000. `waitlisted` y `waitlisted_since` se van y en su
 * lugar queda **`spend_block`**: el mismo dato, generalizado, y con el texto ya
 * escrito por el servidor.
 *
 * Que el texto venga de aquí y no de la app no es un detalle: el mensaje de un
 * bloqueo manual lo escribe una persona en el panel para ese caso concreto, y
 * el del mantenimiento se redacta durante la emergencia. Ninguno de los dos
 * puede vivir en una versión de la app ya instalada.
 */
create or replace function public.my_available_balance()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user      uuid := auth.uid();
  v_level     smallint;
  v_limit     numeric(18,4);
  v_block     public.user_credit_blocks%rowtype;
  v_used      numeric(18,4) := 0;
  v_fee       numeric(18,4) := 0;
  v_to_unlock numeric(18,4) := 0;
  v_reserved  numeric(18,4) := 0;
  v_arrears   boolean := false;
  v_stop      jsonb;
  v_stopped   boolean := false;
  v_next_owed numeric(18,4);
  v_next_free numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select level into v_level from public.profiles where id = v_user;
  select monthly_limit_usd into v_limit from public.levels where level = v_level;

  v_arrears := public.helios_in_arrears(v_user);
  v_used    := public.helios_credit_used_usd(v_user);

  v_stop    := public.helios_spend_block(v_user);
  v_stopped := coalesce((v_stop->>'blocks_balance')::boolean, false);

  select * into v_block
  from public.user_credit_blocks
  where user_id = v_user and closed_at is null;

  if found then
    v_fee := v_block.fee_usd;
    v_to_unlock := v_block.charged_usd + v_block.fee_usd - v_block.paid_usd;
  end if;

  select owed, frees into v_next_owed, v_next_free
  from (
    select
      sum(i.amount_usd) filter (where i.status = 'pending') as owed,
      sum(i.financed_usd)                                   as frees
    from public.installments i
    where i.user_id = v_user
      and exists (
        select 1 from public.installments j
        where j.charge_id = i.charge_id and j.user_id = i.user_id and j.status = 'pending'
      )
    group by i.charge_id
  ) c
  order by owed
  limit 1;

  v_reserved := public.group_holds_usd(v_user);

  return jsonb_build_object(
    'limit_usd', v_limit,
    'available_usd', case
      when v_arrears or v_stopped then 0
      else greatest(v_limit - v_used - v_reserved, 0)
    end,
    'in_arrears', v_arrears,
    -- NUEVO: el motivo con su texto, o null. Null es "no hay nada que decir",
    -- y la app no pinta nada — que es lo que pasa el 99 % de los días.
    'spend_block', v_stop,
    'open_debt_usd', v_used,
    'service_fee_usd', v_fee,
    'amount_to_unlock_usd', v_to_unlock,
    'next_unlock_owed_usd', v_next_owed,
    'next_unlock_frees_usd', v_next_free,
    'reserved_in_groups_usd', v_reserved
  );
end;
$$;

revoke all on function public.my_available_balance() from public, anon;
grant execute on function public.my_available_balance() to authenticated;

/**
 * 🔁 Cuerpo de 20260909151000. El guardia de la lista de espera se generaliza
 * al motivo, sea cual sea, y el mensaje que lanza es el mismo que el usuario
 * ya tiene delante en Inicio.
 *
 * Sigue siendo el único sitio que crea deuda, así que sigue siendo el único
 * sitio donde hay que cerrar la puerta: `confirm_charge`, el cobro de grupo y
 * la adjudicación pasan todos por aquí.
 */
create or replace function public.helios_assign_debt(
  p_user          uuid,
  p_charge_id     uuid,
  p_financed_usd  numeric,
  p_payable_usd   numeric,
  p_due_1         date,
  p_due_2         date,
  p_over_limit_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_limit    numeric(18,4);
  v_block    public.user_credit_blocks%rowtype;
  v_stop     jsonb;
  v_used     numeric(18,4);
  v_first    numeric(18,4);
  v_second   numeric(18,4);
  v_fin_1    numeric(18,4);
  v_fin_2    numeric(18,4);
begin
  -- Solo si hay algo que financiar: en un reparto de grupo alguien frenado
  -- tiene capacidad 0 y puede recibir una parte de 0. Eso no es deuda y no
  -- debe tumbar la cuenta de los demás.
  if p_financed_usd > 0 then
    v_stop := public.helios_spend_block(p_user);

    if coalesce((v_stop->>'blocks_balance')::boolean, false) then
      raise exception '%', v_stop->>'message' using errcode = '22023';
    end if;
  end if;

  select monthly_limit_usd into v_limit
  from public.levels l
  join public.profiles p on p.level = l.level
  where p.id = p_user;

  select * into v_block
  from public.user_credit_blocks
  where user_id = p_user and closed_at is null
  for update;

  if not found then
    insert into public.user_credit_blocks (user_id) values (p_user)
    returning * into v_block;
  end if;

  v_used := public.helios_credit_used_usd(p_user);

  if v_used + p_financed_usd > v_limit then
    raise exception '%', p_over_limit_message using errcode = '22023';
  end if;

  v_first  := round(p_payable_usd / 2, 2);
  v_second := p_payable_usd - v_first;
  v_fin_1  := round(p_financed_usd / 2, 2);
  v_fin_2  := p_financed_usd - v_fin_1;

  insert into public.installments
    (charge_id, user_id, sequence, amount_usd, due_date, financed_usd) values
    (p_charge_id, p_user, 1, v_first,  p_due_1, v_fin_1),
    (p_charge_id, p_user, 2, v_second, p_due_2, v_fin_2);

  update public.user_credit_blocks
    set charged_usd = charged_usd + p_financed_usd,
        fee_usd     = fee_usd + (p_payable_usd - p_financed_usd)
  where id = v_block.id;

  return jsonb_build_object(
    'installment_1_usd', v_first,
    'installment_2_usd', v_second,
    'financed_usd', p_financed_usd,
    'payable_usd', p_payable_usd
  );
end;
$$;

revoke all on function public.helios_assign_debt(uuid, uuid, numeric, numeric, date, date, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Las palancas del super admin
-- ---------------------------------------------------------------------------

/**
 * Enciende o apaga el mantenimiento.
 *
 * Exige título y mensaje cuando se enciende: el aviso ES la funcionalidad. Un
 * mantenimiento sin texto deja a todo el mundo con el saldo en cero y sin
 * saber por qué, que es peor que no tener interruptor.
 */
create or replace function public.admin_set_maintenance(
  p_is_active      boolean,
  p_blocks_balance boolean,
  p_title          text,
  p_message        text,
  p_expected_back  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('encender el mantenimiento');
  v_before public.platform_maintenance%rowtype;
begin
  select * into v_before from public.platform_maintenance;

  if p_is_active then
    if p_title is null or length(trim(p_title)) < 3 then
      raise exception 'El aviso necesita un título' using errcode = '22023';
    end if;
    if p_message is null or length(trim(p_message)) < 10 then
      raise exception 'Explica qué pasa: es lo único que el usuario va a leer'
        using errcode = '22023';
    end if;
  end if;

  update public.platform_maintenance set
    is_active      = p_is_active,
    blocks_balance = p_blocks_balance,
    title          = coalesce(nullif(trim(coalesce(p_title, '')), ''), title),
    message        = coalesce(nullif(trim(coalesce(p_message, '')), ''), message),
    expected_back  = nullif(trim(coalesce(p_expected_back, '')), ''),
    -- Cuándo empezó ESTE episodio. Se conserva mientras siga encendido para
    -- poder decir cuánto lleva caído.
    started_at     = case
      when p_is_active and not v_before.is_active then now()
      when p_is_active then v_before.started_at
      else null
    end,
    updated_by     = v_actor,
    updated_at     = now()
  where id;

  perform audit.log(
    v_actor,
    case when p_is_active then 'maintenance.on' else 'maintenance.off' end,
    null,
    jsonb_build_object(
      'before', jsonb_build_object(
        'is_active', v_before.is_active,
        'blocks_balance', v_before.blocks_balance
      ),
      'after', jsonb_build_object(
        'is_active', p_is_active,
        'blocks_balance', p_blocks_balance,
        'title', p_title,
        'message', p_message,
        'expected_back', p_expected_back
      )
    )
  );

  return public.helios_maintenance();
end;
$$;

revoke all on function public.admin_set_maintenance(boolean, boolean, text, text, text)
  from public, anon;
grant execute on function public.admin_set_maintenance(boolean, boolean, text, text, text)
  to authenticated;

/**
 * Bloquea una cuenta. Dos textos, y los dos obligatorios: el motivo interno
 * —que queda en la bitácora y no se enseña— y el mensaje que lee el usuario.
 *
 * No toca `profiles.status`: el estado sigue contando la historia de la mora,
 * y esto cuenta la de la sanción. Ver la cabecera de este archivo.
 */
create or replace function public.admin_block_user(
  p_user_id uuid,
  p_reason  text,
  p_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('bloquear una cuenta');
  v_id    uuid;
begin
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'Bloquear una cuenta requiere motivo' using errcode = '22023';
  end if;

  if p_message is null or length(trim(p_message)) < 10 then
    raise exception 'Escribe lo que verá el usuario: sin eso, la app se le rompe sin explicación'
      using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'Usuario no encontrado' using errcode = 'P0002';
  end if;

  insert into public.user_blocks (user_id, reason, message, blocked_by)
  values (p_user_id, trim(p_reason), trim(p_message), v_actor)
  on conflict (user_id) where lifted_at is null do nothing
  returning id into v_id;

  if v_id is null then
    raise exception 'Esa cuenta ya está bloqueada' using errcode = '22023';
  end if;

  perform public.notify(
    p_user_id, 'account_blocked',
    'Tu cuenta está bloqueada',
    trim(p_message),
    jsonb_build_object('block_id', v_id),
    'account_blocked',
    jsonb_build_object('motivo', trim(p_message))
  );

  perform audit.log(v_actor, 'user.blocked', p_user_id, jsonb_build_object(
    'block_id', v_id, 'reason', trim(p_reason), 'message', trim(p_message)
  ));

  return jsonb_build_object('ok', true, 'block_id', v_id);
end;
$$;

revoke all on function public.admin_block_user(uuid, text, text) from public, anon;
grant execute on function public.admin_block_user(uuid, text, text) to authenticated;

/** Levanta el bloqueo. El saldo vuelve a lo que le toque por su nivel y su
 *  mora — el bloqueo nunca fue un estado, así que no hay nada que restaurar. */
create or replace function public.admin_unblock_user(p_user_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := public.helios_assert_super_admin('levantar el bloqueo de una cuenta');
  v_row   public.user_blocks%rowtype;
begin
  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Levantar un bloqueo requiere motivo' using errcode = '22023';
  end if;

  update public.user_blocks
    set lifted_at = now(), lifted_by = v_actor, lift_note = trim(p_note)
  where user_id = p_user_id and lifted_at is null
  returning * into v_row;

  if not found then
    raise exception 'Esa cuenta no está bloqueada' using errcode = 'P0002';
  end if;

  perform public.notify(
    p_user_id, 'account_unblocked',
    'Tu cuenta vuelve a estar activa',
    'Ya puedes volver a usar Helios con normalidad.',
    jsonb_build_object('block_id', v_row.id),
    'account_unblocked', '{}'::jsonb
  );

  perform audit.log(v_actor, 'user.unblocked', p_user_id, jsonb_build_object(
    'block_id', v_row.id, 'blocked_since', v_row.blocked_at, 'note', trim(p_note)
  ));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.admin_unblock_user(uuid, text) from public, anon;
grant execute on function public.admin_unblock_user(uuid, text) to authenticated;

/** El bloqueo abierto de una cuenta y los anteriores, para la ficha del panel. */
create or replace function public.admin_user_blocks(p_user_id uuid)
returns table (
  id             uuid,
  reason         text,
  message        text,
  blocked_at     timestamptz,
  blocked_by_name text,
  lifted_at      timestamptz,
  lift_note      text,
  lifted_by_name text
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    b.id, b.reason, b.message, b.blocked_at, ba.full_name,
    b.lifted_at, b.lift_note, la.full_name
  from public.user_blocks b
  left join public.platform_admins ba on ba.user_id = b.blocked_by
  left join public.platform_admins la on la.user_id = b.lifted_by
  where public.is_platform_admin()
    and b.user_id = p_user_id
  order by (b.lifted_at is not null), b.blocked_at desc;
$$;

revoke all on function public.admin_user_blocks(uuid) from public, anon;
grant execute on function public.admin_user_blocks(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Los avisos, editables desde el panel
-- ---------------------------------------------------------------------------
insert into public.notification_templates (
  key, type, label, trigger_label, help,
  variables, required_variables,
  default_title, default_body,
  editable, can_disable, cron_job, lead_days, run_at, sort_order
) values
(
  'account_blocked', 'account_blocked'::public.notification_type,
  'Cuenta bloqueada por el equipo',
  'Al bloquear una cuenta a mano desde el panel de usuarios.',
  'El cuerpo es {motivo}: el texto que quien bloquea escribe para ESE caso. Por eso {motivo} es obligatorio — sin él, el aviso diría algo genérico y el usuario no sabría qué pasó ni qué hacer.',
  array['motivo'], array['motivo'],
  'Tu cuenta está bloqueada',
  '{motivo}',
  true, false, null, null, null, 180
),
(
  'account_unblocked', 'account_unblocked'::public.notification_type,
  'Bloqueo levantado',
  'Al levantar el bloqueo de una cuenta desde el panel.',
  'No se puede apagar: es la única forma en que la persona se entera de que ya puede volver a usar la app.',
  '{}', '{}',
  'Tu cuenta vuelve a estar activa',
  'Ya puedes volver a usar Helios con normalidad.',
  true, false, null, null, null, 190
)
on conflict (key) do nothing;
