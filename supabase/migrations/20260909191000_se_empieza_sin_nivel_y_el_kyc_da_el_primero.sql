-- ============================================================================
-- Ronda — Se empieza SIN nivel, y verificarse da el primero
--
-- Hasta hoy el perfil nacía en `level = 1`. Eso decía dos cosas falsas a la
-- vez: que el nivel 1 no se gana —te lo encuentras puesto antes de enseñar la
-- cédula— y, peor, que **el momento más importante del producto no existe**.
-- Terminar el KYC es cuando alguien pasa de no tener nada a tener €30 de saldo
-- sin inicial, y en la base ese instante no dejaba rastro: el nivel valía 1
-- antes y después, así que no había nada que celebrar ni nada que auditar.
--
-- Tres piezas:
--
-- 1. **El nivel 0 existe.** Peldaño real de `public.levels` con límite 0 e
--    `is_active = false`. Es lo que hace que el resto siga funcionando sin
--    tocarlo: la treintena de funciones que hacen `select monthly_limit_usd
--    into v_limit from public.levels where level = v_profile.level` siguen
--    encontrando fila, y esa fila dice 0 — que es exactamente el saldo que le
--    toca a quien no se ha verificado. Con `profiles.level` anulable habría
--    habido que revisarlas todas y cada `null` habría sido un límite abierto.
--
-- 2. **Activarse da el nivel 1**, por trigger. `docs/00-BASES §2.6` siempre
--    dijo que el requisito del nivel 1 es "KYC aprobado"; ahora se cumple de
--    verdad, y en el único sitio por el que se pasa: `profiles.status` llega a
--    `active`. Es un trigger y no una línea dentro de `kyc.advance_profile`
--    porque hay DOS caminos hasta ahí —KYC y luego PIN (`advance_profile`), o
--    PIN después del KYC (`set_user_pin`)— y una línea dentro de uno de los
--    dos dejaría fuera al otro. Mismo patrón que
--    `profiles_waitlist_on_activation` (20260909151000).
--
-- 3. **La subida queda pendiente de contar.** `level_changes.celebrated_at`
--    dice si al usuario ya se le enseñó. Es lo que permite que el cron de las
--    10:20 promocione a alguien que tiene el teléfono en el bolsillo y que la
--    pantalla le salga igual tres días después, al abrir la app. Sin una marca
--    en el servidor eso no se puede prometer: lo que se guarda en el teléfono
--    no sobrevive a reinstalar, y un aviso push no llega si no dieron permiso.
--
-- **Lo que ya estaba bien y no se toca.** `evaluate_level` rechaza las cuentas
-- que no están `active`, así que nadie sube de nivel sin haberse verificado —
-- el requisito del nivel 1 no hay que escribirlo en ningún sitio, es la puerta
-- que ya existía. Y el techo sigue saliendo de `max(level) where is_active`,
-- que con el 0 inactivo no se mueve.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. El peldaño cero
-- ---------------------------------------------------------------------------

-- El `check` original era `between 1 and 5`, escrito como restricción de
-- columna, así que Postgres le puso el nombre automático. Se sustituye por uno
-- con nombre para que la próxima vez que haya que moverlo no haya que
-- adivinarlo.
alter table public.levels drop constraint if exists levels_level_check;
alter table public.levels
  add constraint levels_level_range check (level between 0 and 5);

-- Límite 0 e inactivo. Las dos cosas importan:
--
--   · **Límite 0** es el saldo correcto de quien no se ha verificado, y lo dice
--     la misma fila que lo dice para todos los demás niveles.
--   · **`is_active = false`** lo saca de la escalera: no es un destino al que
--     se pueda promocionar (`evaluate_level` solo mira los activos), no cuenta
--     en `fetchActiveLevelCount` y no aparece en la pantalla de Niveles.
--
-- "Sin nivel" y no "Nivel 0": nadie se piensa a sí mismo como estando en el
-- nivel cero de nada, y el rótulo se lee tal cual en el historial del panel.
insert into public.levels (level, monthly_limit_usd, required_spend_usd, required_months, is_active, label)
values (0, 0.0000, 0.0000, 0, false, 'Sin nivel')
on conflict (level) do nothing;

comment on table public.levels is
  'Configuración de niveles. Editable desde el super admin; la app la lee.
   El 0 es "sin nivel": donde nace todo perfil y del que se sale al verificar
   la identidad. No es un peldaño de la escalera — is_active = false.';

-- ---------------------------------------------------------------------------
-- 2. Se nace sin nivel
-- ---------------------------------------------------------------------------

alter table public.profiles alter column level set default 0;

-- Quien está a medio registro AHORA MISMO también empieza de cero. Si se les
-- dejara en 1, la gente que tiene la verificación a medias hoy se quedaría sin
-- la pantalla de bienvenida para siempre — y son justo los que la van a ver
-- primero.
--
-- Solo desde el 1: un perfil sin verificar en un nivel más alto no existe, y si
-- existiera sería un ajuste manual de un admin que no toca bajar por aquí.
update public.profiles
set level = 0, updated_at = now()
where status in ('pending_kyc', 'pending_pin') and level = 1;

-- ---------------------------------------------------------------------------
-- 3. Qué subidas quedan por contar
-- ---------------------------------------------------------------------------

alter table public.level_changes
  add column if not exists celebrated_at timestamptz;

comment on column public.level_changes.celebrated_at is
  'Cuándo se le enseñó al usuario la pantalla de subida de nivel. Null =
   pendiente. Solo se llena en las SUBIDAS: una bajada por mora no se celebra,
   y sus filas se quedan en null para siempre — quien lee filtra por
   to_level > from_level.';

-- Todo lo que ya pasó queda contado. Sin esto, la primera vez que alguien
-- abriera la app le saldrían fuegos artificiales por un ascenso de hace tres
-- semanas del que ya se enteró por el aviso.
update public.level_changes
set celebrated_at = created_at
where celebrated_at is null;

-- Índice parcial: la consulta que corre en CADA apertura de la app es
-- "¿tiene este usuario algo sin celebrar?", y la respuesta es que no el 99,9 %
-- de las veces. Un índice sobre las pocas filas pendientes la resuelve sin
-- tocar el historial de nadie.
create index if not exists level_changes_pending_idx
  on public.level_changes (user_id)
  where celebrated_at is null;

-- ---------------------------------------------------------------------------
-- 4. Activarse da el nivel 1
-- ---------------------------------------------------------------------------

/**
 * Se dispara cuando un perfil pasa de "a medio registro" a `active`, que es el
 * instante en que la identidad queda verificada y hay PIN.
 *
 * `before` y no `after`: así el nivel se asigna en la misma escritura que ya
 * está en curso, sin un segundo UPDATE sobre la misma fila. El trigger de la
 * lista de espera (`profiles_waitlist_on_activation`) es `after`, así que
 * cuando se le pregunte por esta persona el nivel ya estará puesto.
 *
 * **Solo la primera vez.** Volver de `frozen` o `suspended` no es registrarse:
 * quien vuelve de una mora recupera el nivel por el motor de niveles y su
 * enfriamiento, no por aquí. El `new.level >= 1` lo remata: un perfil que ya
 * tenía nivel no lo pierde ni lo vuelve a "ganar".
 */
create or replace function public.grant_first_level_on_activation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_level public.levels%rowtype;
begin
  if new.status <> 'active' or old.status not in ('pending_kyc', 'pending_pin') then
    return new;
  end if;

  if new.level >= 1 then
    return new;
  end if;

  select * into v_level from public.levels where level = 1;

  new.level := 1;
  new.updated_at := now();

  insert into public.level_changes (user_id, from_level, to_level, reason, detail)
  values (
    new.id, coalesce(old.level, 0), 1, 'kyc_approved',
    jsonb_build_object('limit_usd', v_level.monthly_limit_usd)
  );

  -- Aviso propio, sin plantilla: la de `level_up` habla de lo que se pagó
  -- ("Lo lograste pagando €X a tiempo"), y aquí no se pagó nada — se verificó
  -- la identidad. El tipo sí es el mismo, que es lo que hace que caiga en la
  -- misma bandeja.
  perform public.notify(
    new.id, 'level_up',
    format('Llegaste al %s', v_level.label),
    format('Tu identidad está verificada. Tienes €%s de saldo para gastar sin inicial.',
           trim(to_char(v_level.monthly_limit_usd, 'FM999999990.00'))),
    jsonb_build_object('level', 1, 'limit_usd', v_level.monthly_limit_usd)
  );

  return new;
end;
$$;

revoke all on function public.grant_first_level_on_activation() from public, anon, authenticated;

drop trigger if exists profiles_first_level_on_activation on public.profiles;
create trigger profiles_first_level_on_activation
  before update of status on public.profiles
  for each row execute function public.grant_first_level_on_activation();

-- ---------------------------------------------------------------------------
-- 5. Lo que la app pregunta al abrirse
-- ---------------------------------------------------------------------------

/**
 * ¿Hay una subida de nivel que este usuario todavía no ha visto?
 *
 * Devuelve `null` casi siempre. Cuando no, trae todo lo que la pantalla
 * necesita pintar sin pedir nada más: el peldaño nuevo con su límite, el
 * siguiente con lo que cuesta, y **si ese saldo se puede usar hoy** — que es la
 * mitad que se olvida. A alguien del piloto que entra en lista de espera
 * (20260909151000) hay que felicitarlo igual, pero no se le puede prometer que
 * ya puede gastar: su disponible es 0 hasta que se libere el cupo.
 *
 * Si hay varias sin contar —dos ascensos en la misma semana sin abrir la app—
 * manda la ÚLTIMA, que es el nivel en el que está. `pending_count` deja que la
 * pantalla lo diga en una línea en vez de encadenar dos celebraciones.
 */
create or replace function public.my_pending_level_up()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_row   public.level_changes%rowtype;
  v_level public.levels%rowtype;
  v_next  public.levels%rowtype;
  v_count integer;
  v_from  smallint;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_row
  from public.level_changes
  where user_id = v_user
    and celebrated_at is null
    and to_level > from_level
  order by created_at desc
  limit 1;

  if not found then
    return null;
  end if;

  -- Cuántas van sin contar y, sobre todo, DE DÓNDE viene: el `from_level` que
  -- se manda es el de la más vieja sin contar, no el de la última. Con dos
  -- ascensos en la misma semana —1→2 el lunes, 2→3 el jueves, sin abrir la app—
  -- la resta contra la última daría 1 y la pantalla diría que subió un nivel,
  -- cuando subió dos y nunca llegó a ver el 2. Como los pendientes solo suben,
  -- el mínimo es el punto de partida.
  select count(*), min(from_level) into v_count, v_from
  from public.level_changes
  where user_id = v_user and celebrated_at is null and to_level > from_level;

  select * into v_level from public.levels where level = v_row.to_level;

  select * into v_next from public.levels
  where is_active and level > v_row.to_level
  order by level
  limit 1;

  return jsonb_build_object(
    'id', v_row.id,
    'from_level', v_from,
    'to_level', v_row.to_level,
    'reason', v_row.reason,
    'label', v_level.label,
    'limit_usd', v_level.monthly_limit_usd,
    'happened_at', v_row.created_at,
    'pending_count', v_count,
    -- Sobre cuántos peldaños se mide el corazón. Viaja aquí y no en una
    -- consulta aparte para que el dibujo salga bien en el PRIMER fotograma:
    -- un corazón que se pinta lleno hasta 1/5 y salta a 1/4 deshace justo la
    -- lectura que la pantalla viene a dar.
    'active_levels', (select count(*) from public.levels where is_active),
    -- Por qué NO puede gastar ese saldo todavía, con el texto ya escrito. Null
    -- el 99 % de las veces; es el mismo dato que pinta Inicio.
    'spend_block', public.helios_spend_block(v_user),
    'in_arrears', public.helios_in_arrears(v_user),
    'next_level', case when v_next.level is null then null else
      jsonb_build_object(
        'level', v_next.level,
        'label', v_next.label,
        'limit_usd', v_next.monthly_limit_usd,
        'required_spend_usd', v_next.required_spend_usd,
        'required_months', v_next.required_months
      )
    end
  );
end;
$$;

revoke all on function public.my_pending_level_up() from public, anon;
grant execute on function public.my_pending_level_up() to authenticated;

/**
 * Ya la vio.
 *
 * Marca TODAS las pendientes y no solo la que se enseñó: si alguien acumuló
 * dos ascensos, lo que se le contó es a qué nivel llegó, y volver a abrir la
 * app para que le salga el ascenso intermedio sería contarle la historia al
 * revés. Devuelve cuántas cerró, que es lo que deja auditar el flujo.
 *
 * Idempotente: llamarla dos veces —doble toque, o un reintento de red— no
 * cambia nada la segunda vez.
 */
create or replace function public.ack_level_up()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_count integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  update public.level_changes
    set celebrated_at = now()
  where user_id = v_user
    and celebrated_at is null
    and to_level > from_level;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.ack_level_up() from public, anon;
grant execute on function public.ack_level_up() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. El 0 no se configura desde el panel
-- ---------------------------------------------------------------------------

/**
 * Cuerpo de 20260822202000 con una guarda nueva delante.
 *
 * El nivel 0 no es un peldaño: es la ausencia de peldaño. Ponerle límite desde
 * el panel le daría saldo a quien no ha enseñado la cédula, que es exactamente
 * lo que el KYC existe para impedir — y sería un clic, no un despliegue.
 */
create or replace function public.admin_set_level_config(
  p_level             smallint,
  p_monthly_limit_usd numeric,
  p_required_spend_usd numeric,
  p_required_months   smallint,
  p_is_active         boolean,
  p_label             text default null
)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := auth.uid();
  v_before jsonb;
begin
  if not public.is_super_admin(v_actor) then
    raise exception 'Solo el super admin puede configurar niveles' using errcode = '42501';
  end if;

  -- ── NUEVO ────────────────────────────────────────────────────────────────
  if p_level = 0 then
    raise exception 'El nivel 0 no se configura: es no tener nivel, y se sale de él verificando la identidad'
      using errcode = '22023';
  end if;

  if p_monthly_limit_usd < 0 or p_required_spend_usd < 0 or p_required_months < 0 then
    raise exception 'Los valores de un nivel no pueden ser negativos'
      using errcode = '22023';
  end if;

  -- Activar un nivel con límite cero le daría a quien ascienda un cupo de
  -- cero: subiría de nivel para no poder gastar.
  if p_is_active and p_monthly_limit_usd <= 0 then
    raise exception 'Un nivel activo necesita un límite mayor que cero'
      using errcode = '22023';
  end if;

  select to_jsonb(l) into v_before from public.levels l where l.level = p_level;
  if v_before is null then
    raise exception 'Nivel no encontrado' using errcode = 'P0002';
  end if;

  update public.levels
    set monthly_limit_usd  = p_monthly_limit_usd,
        required_spend_usd = p_required_spend_usd,
        required_months    = p_required_months,
        is_active          = p_is_active,
        label              = coalesce(nullif(trim(p_label), ''), label),
        updated_at         = now()
  where level = p_level;

  perform audit.log(v_actor, 'level.configure', null, jsonb_build_object(
    'level', p_level,
    'before', v_before,
    'after', (select to_jsonb(l) from public.levels l where l.level = p_level)
  ));
end;
$$;

revoke all on function public.admin_set_level_config(smallint, numeric, numeric, smallint, boolean, text)
  from public, anon;
grant execute on function public.admin_set_level_config(smallint, numeric, numeric, smallint, boolean, text)
  to authenticated;

/**
 * Y tampoco se lista. Cuerpo de 20260822202000 con `where l.level >= 1`.
 *
 * La pestaña del panel se llama "Niveles y límites" y pinta cada fila como una
 * tarjeta con sus tres campos editables: una fila que el guardado rechaza
 * siempre no es información, es una trampa. Cuánta gente está sin verificar ya
 * lo dice el resumen, en el tramo `pending_kyc`.
 */
create or replace function public.admin_level_config()
returns table (
  level              smallint,
  label              text,
  monthly_limit_usd  numeric,
  required_spend_usd numeric,
  required_months    smallint,
  is_active          boolean,
  user_count         integer,
  exposure_usd       numeric
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  return query
  select
    l.level, l.label, l.monthly_limit_usd, l.required_spend_usd,
    l.required_months, l.is_active,
    coalesce(u.cnt, 0)::integer,
    coalesce(u.debt, 0)::numeric
  from public.levels l
  left join (
    select p.level as lvl, count(*)::integer as cnt,
           sum(coalesce(d.open_debt, 0)) as debt
    from public.profiles p
    left join (
      select ins.user_id as uid, sum(ins.amount_usd) as open_debt
      from public.installments ins where ins.status = 'pending' group by 1
    ) d on d.uid = p.id
    group by 1
  ) u on u.lvl = l.level
  where l.level >= 1
  order by l.level;
end;
$$;

revoke all on function public.admin_level_config() from public, anon;
grant execute on function public.admin_level_config() to authenticated;
