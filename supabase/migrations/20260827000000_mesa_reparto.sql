-- ============================================================================
-- Ronda — La mesa: compartir gastos sin grupo
--
-- Decisión del 2026-08-27. Los grupos desaparecen. En su lugar queda una sola
-- idea, y no hay que crearla ni cerrarla:
--
--   TU QR DE ESTA NOCHE. Quien lo escanea comparte gastos contigo hasta el
--   corte de las 10 AM. Cuando cualquiera de ustedes paga, se reparte entre
--   los que estén. A las 10 AM se acaba solo.
--
-- ---------------------------------------------------------------------------
-- Por qué se va el grupo
-- ---------------------------------------------------------------------------
-- El grupo no fallaba al dividir: fallaba antes. Para poder dividir había que
-- haberlo creado, dictado un código de 6 caracteres y que todos hubieran
-- aceptado un ticket **antes de salir**. Eso es un producto que solo sirve a
-- quien planifica la noche, y casi nadie planifica la noche. Encima el ticket
-- retenía saldo de verdad, así que recuperarlo exigía que alguien se acordara
-- de cerrar el grupo — y un grupo que nadie cierra deja dinero congelado para
-- siempre.
--
-- La mesa nace de un toque, muere sola y no retiene nada.
--
-- ---------------------------------------------------------------------------
-- El techo ya no retiene
-- ---------------------------------------------------------------------------
-- Cada quien pone su techo al entrar y por defecto es su saldo COMPLETO.
-- No aparta nada: es un máximo que se comprueba en cada cobro contra
-- `min(techo − gastado, disponible)`.
--
-- Se pierde la garantía de que un cobro nunca falle en la caja —quien se gastó
-- el saldo en otro sitio llega corto— y se gana no tener nada que explicar,
-- nada que devolver y nada que cerrar. El fallo duro además casi desaparece:
-- con el reparto en cascada (§2) lo que uno no cubre lo absorben los demás
-- dentro de su propio techo, y el cobro solo se cae si entre todos no llegan.
--
-- Lo que el techo sigue protegiendo es lo único que importaba: **nadie te
-- cobra más de lo que aceptaste**.
--
-- ---------------------------------------------------------------------------
-- Una mesa por noche y por persona
-- ---------------------------------------------------------------------------
-- No se puede estar en dos mesas a la vez. Si se pudiera, el techo dejaría de
-- ser un techo: aceptar $80 aquí y $80 allá es aceptar $160 sin haberlo dicho
-- nunca, y las dos mesas comprobarían el mismo saldo por separado.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las tablas
-- ---------------------------------------------------------------------------

create table if not exists public.tabs (
  id            uuid primary key default gen_random_uuid(),
  -- Quien la abrió. No le da ningún privilegio: cualquiera de la mesa puede
  -- cobrar, enseñar el QR y meter gente. Se guarda para poder decir "la mesa
  -- de Javier" y para depurar.
  opened_by     uuid not null references auth.users (id) on delete cascade,
  -- La noche. Es el único mecanismo de cierre que hay: no existe "cerrar la
  -- mesa" porque una mesa de otra noche ya no es una mesa.
  business_date date not null,
  -- Lo que va dentro del QR y del enlace. NO es un código para dictar en voz
  -- alta: se escanea o se toca. Por eso es aleatorio y largo en vez de seis
  -- caracteres legibles — un código dictable es un código adivinable, y
  -- adivinar este mete a un desconocido en tu reparto.
  token         text not null unique
                default encode(extensions.gen_random_bytes(8), 'hex'),
  created_at    timestamptz not null default now()
);

-- Abrir la mesa es idempotente: el mismo toque dos veces devuelve la misma.
create unique index if not exists tabs_one_per_night
  on public.tabs (opened_by, business_date);

create table if not exists public.tab_members (
  tab_id        uuid not null references public.tabs (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  -- Denormalizado desde `tabs`. Es lo que hace posible el índice de "una sola
  -- mesa por noche" sin un trigger: un índice único no puede mirar otra tabla.
  business_date date not null,
  -- EL TECHO de la noche. Por defecto, el saldo disponible entero.
  cap_usd       numeric(18,4) not null,
  -- Lo que esta mesa ya le cargó. El techo es acumulativo por la noche: si
  -- fuera por cobro, cinco rondas se saltarían el techo cinco veces.
  spent_usd     numeric(18,4) not null default 0 check (spent_usd >= 0),
  joined_at     timestamptz not null default now(),
  left_at       timestamptz,
  primary key (tab_id, user_id),
  constraint tab_members_cap_floor check (cap_usd >= 2.50),
  constraint tab_members_spent_le_cap check (spent_usd <= cap_usd)
);

comment on constraint tab_members_cap_floor on public.tab_members is
  'El suelo del techo es el mínimo por persona (public.min_share_usd()). Va
   escrito porque un CHECK con una función es una trampa al restaurar un dump;
   si el mínimo cambia, esta restricción cambia con él.';

create unique index if not exists tab_members_one_per_night
  on public.tab_members (user_id, business_date) where left_at is null;

create index if not exists tab_members_tab_idx
  on public.tab_members (tab_id) where left_at is null;

alter table public.tabs        enable row level security;
alter table public.tab_members enable row level security;

-- Solo la propia fila por tabla directa. Lo de los demás sale por RPC, que es
-- donde se puede calcular la capacidad y filtrar a quien no es de la mesa.
create policy "tab_members_read_own"
  on public.tab_members for select to authenticated
  using (user_id = (select auth.uid()));

-- Sin políticas de escritura: la mesa solo la mueven las RPC.

-- El cobro recuerda en qué mesa se repartió.
alter table public.charges
  add column if not exists tab_id uuid references public.tabs (id);

-- ---------------------------------------------------------------------------
-- 2. El reparto en cascada
-- ---------------------------------------------------------------------------
/**
 * Reparte `p_total_usd` lo más parejo posible sin pasarse del techo de nadie.
 *
 * La regla, en una línea: **todos pagan lo mismo salvo quien no llegue, que
 * paga su máximo, y lo que falte se reparte otra vez entre los demás.**
 *
 * Eso no es una heurística ni depende del orden en que se mire a la gente:
 * tiene solución cerrada y única. Lo que calcula es un NIVEL común `λ` tal que
 * cada quien paga `min(techo, λ)` y la suma da el total. El bucle es cómo se
 * encuentra λ:
 *
 *     λ = lo que queda / los que aún no están topados
 *     si alguien no llega a λ  → paga su techo, sale del reparto, se repite
 *     si nadie se topa         → todos los abiertos pagan λ y se acabó
 *
 * λ solo puede SUBIR en cada vuelta, nunca bajar. De ahí sale la propiedad que
 * permite comprobar el mínimo por persona UNA sola vez, al principio: si el
 * primer λ ya llega a $2,50, todos los siguientes también.
 *
 * ---------------------------------------------------------------------------
 * Lo que hay que tener presente y no se ve en el código
 * ---------------------------------------------------------------------------
 * La cascada respeta el techo de todo el mundo —nadie paga más de lo que
 * aceptó, que es la garantía de la que cuelga todo— pero **sí te puede hacer
 * pagar más de lo parejo**. Con el techo por defecto puesto al saldo entero,
 * quien no lo toca acaba absorbiendo lo de quien sí. Es una decisión
 * consentida (pusiste ese techo), pero no es la que la gente se imagina, así
 * que el reparto se enseña entero antes del PIN y a quien absorbe le llega un
 * aviso diciendo por qué su parte subió.
 *
 * Todo en CÉNTIMOS y con enteros: en dinero repartido no puede sobrar ni
 * faltar un céntimo por redondeo, y `numeric` dividido no lo garantiza.
 */
create or replace function public.helios_split_shares(
  p_total_usd    numeric,
  p_participants jsonb   -- [{"user_id": uuid, "capacity_usd": numeric}, ...]
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_ids      uuid[]    := '{}';
  v_cap      bigint[]  := '{}';
  v_share    bigint[]  := '{}';
  v_fixed    boolean[] := '{}';
  v_excluded uuid[]    := '{}';
  v_min      bigint := round(public.min_share_usd() * 100)::bigint;
  v_left     bigint := round(p_total_usd * 100)::bigint;
  v_capacity bigint := 0;
  v_open     integer;
  v_level    bigint;
  v_capped   integer;
  v_i        integer;
  v_n        integer;
  v_row      jsonb;
  v_out      jsonb := '[]'::jsonb;
begin
  /**
   * Quien no llega al mínimo por persona queda FUERA del reparto, no dentro
   * con una parte diminuta. Si entrara, la cascada le asignaría su techo
   * —pongamos $1,80— y sus dos cuotas serían de $0,90, por debajo del suelo
   * que el resto del sistema da por cierto. Sale, y su parte la absorben los
   * demás.
   */
  for v_row in select * from jsonb_array_elements(p_participants) loop
    if round((v_row->>'capacity_usd')::numeric * 100)::bigint >= v_min then
      v_ids   := v_ids   || (v_row->>'user_id')::uuid;
      v_cap   := v_cap   || round((v_row->>'capacity_usd')::numeric * 100)::bigint;
      v_share := v_share || 0::bigint;
      v_fixed := v_fixed || false;
    else
      v_excluded := v_excluded || (v_row->>'user_id')::uuid;
    end if;
  end loop;

  v_n := coalesce(array_length(v_ids, 1), 0);
  select coalesce(sum(c), 0) into v_capacity from unnest(v_cap) as c;

  if v_n = 0 then
    return jsonb_build_object(
      'ok', false, 'reason', 'not_enough',
      'capacity_usd', 0, 'split_between', 0,
      'excluded', to_jsonb(v_excluded)
    );
  end if;

  -- El suelo del reparto. No se puede dividir $8 entre 5: la app lo dice y
  -- ofrece pagarla entera, que es la única salida real.
  if v_left < v_n * v_min then
    return jsonb_build_object(
      'ok', false, 'reason', 'too_small',
      'min_total_usd', round((v_n * v_min)::numeric / 100, 2),
      'split_between', v_n,
      'capacity_usd', round(v_capacity::numeric / 100, 2),
      'excluded', to_jsonb(v_excluded)
    );
  end if;

  if v_left > v_capacity then
    return jsonb_build_object(
      'ok', false, 'reason', 'not_enough',
      'capacity_usd', round(v_capacity::numeric / 100, 2),
      'split_between', v_n,
      'excluded', to_jsonb(v_excluded)
    );
  end if;

  loop
    v_open := 0;
    for v_i in 1..v_n loop
      if not v_fixed[v_i] then v_open := v_open + 1; end if;
    end loop;

    -- No puede pasar: ya se comprobó que la capacidad total llega. Si pasara,
    -- salir en silencio repartiría menos dinero del que se cobró.
    exit when v_open = 0;

    v_level := v_left / v_open;

    v_capped := 0;
    for v_i in 1..v_n loop
      if not v_fixed[v_i] and v_cap[v_i] <= v_level then
        v_share[v_i] := v_cap[v_i];
        v_fixed[v_i] := true;
        v_left       := v_left - v_cap[v_i];
        v_capped     := v_capped + 1;
      end if;
    end loop;

    if v_capped = 0 then
      -- Nadie más se topa: los abiertos se llevan el nivel...
      for v_i in 1..v_n loop
        if not v_fixed[v_i] then
          v_share[v_i] := v_level;
          v_left       := v_left - v_level;
        end if;
      end loop;

      /**
       * ...y los céntimos que la división entera dejó fuera van de uno en uno.
       *
       * Van a quien AÚN TIENE HUECO bajo su techo, en orden de user_id. El
       * orden fijo es lo que hace que dos reintentos del mismo cobro repartan
       * idéntico. Sobran menos céntimos que gente abierta, así que alcanza:
       * nadie abierto está topado, luego todos tienen al menos un céntimo de
       * hueco.
       */
      v_i := 1;
      while v_left > 0 and v_i <= v_n loop
        if not v_fixed[v_i] and v_share[v_i] < v_cap[v_i] then
          v_share[v_i] := v_share[v_i] + 1;
          v_left       := v_left - 1;
        end if;
        v_i := v_i + 1;
      end loop;

      exit;
    end if;
  end loop;

  for v_i in 1..v_n loop
    v_out := v_out || jsonb_build_object(
      'user_id',   v_ids[v_i],
      'share_usd', round(v_share[v_i]::numeric / 100, 2),
      -- Permite decir "puso su máximo" sin enseñar CUÁNTO es su máximo.
      'at_cap',    v_share[v_i] = v_cap[v_i]
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'shares', v_out,
    'split_between', v_n,
    'capacity_usd', round(v_capacity::numeric / 100, 2),
    'excluded', to_jsonb(v_excluded)
  );
end;
$$;

revoke all on function public.helios_split_shares(numeric, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Abrir, entrar, salir
-- ---------------------------------------------------------------------------

/**
 * Cuándo se acaba una noche: las 10:00 AM del día siguiente, hora de Caracas.
 *
 * El día operativo `d` cubre [d 10:00, d+1 10:00), así que el final de `d` es
 * el principio de `d+1`. Va como función y no calculado en la app porque es la
 * hora que la mesa le PROMETE al usuario ("esto se cierra a las 10 AM"), y una
 * promesa que cada cliente recalcula a su manera acaba diciendo cosas
 * distintas en dos teléfonos.
 */
create or replace function public.helios_business_day_end(p_business_date date)
returns timestamptz
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select ((p_business_date + 1)::timestamp + interval '10 hours')
           at time zone 'America/Caracas';
$$;

revoke all on function public.helios_business_day_end(date) from public, anon;
grant execute on function public.helios_business_day_end(date) to authenticated;

/** Mi mesa de esta noche, o null. Un solo sitio que resuelve "¿cuál es?". */
create or replace function public.my_open_tab_id()
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select m.tab_id
  from public.tab_members m
  where m.user_id = auth.uid()
    and m.left_at is null
    and m.business_date = public.helios_business_date(now());
$$;

revoke all on function public.my_open_tab_id() from public, anon;
grant execute on function public.my_open_tab_id() to authenticated;

/**
 * Abrir la mesa. Es el único acto de creación que queda, y es un toque.
 *
 * No hay nombre que poner ni cifra que componer: el techo entra por defecto
 * con el saldo disponible ENTERO. Quien no quiera pensar, no piensa — y quien
 * quiera acotarlo lo cambia después con `set_my_tab_cap`.
 *
 * Es idempotente por (persona, noche): tocarlo dos veces devuelve la misma
 * mesa y el mismo QR. Y si ya estoy en la mesa de otro, devuelve ESA — no se
 * abre una segunda, porque no se puede estar en dos.
 */
create or replace function public.open_my_tab()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_tab   public.tabs%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_avail numeric(18,4);
  v_exist uuid;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_exist := public.my_open_tab_id();
  if v_exist is not null then
    select * into v_tab from public.tabs where id = v_exist;
    return jsonb_build_object('tab_id', v_tab.id, 'token', v_tab.token, 'created', false);
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes compartir gastos' using errcode = '22023';
  end if;

  v_avail := (public.my_available_balance()->>'available_usd')::numeric;

  if v_avail < public.min_share_usd() then
    raise exception 'Te quedan $% y el mínimo por persona es $%',
      v_avail, public.min_share_usd() using errcode = '22023';
  end if;

  -- `on conflict` y no un `if not exists`: dos toques simultáneos desde el
  -- mismo teléfono no pueden acabar en dos mesas.
  insert into public.tabs (opened_by, business_date)
  values (v_user, v_bdate)
  on conflict (opened_by, business_date) do update set opened_by = excluded.opened_by
  returning * into v_tab;

  insert into public.tab_members (tab_id, user_id, business_date, cap_usd)
  values (v_tab.id, v_user, v_bdate, floor(v_avail * 100) / 100)
  on conflict (tab_id, user_id) do nothing;

  return jsonb_build_object('tab_id', v_tab.id, 'token', v_tab.token, 'created', true);
end;
$$;

revoke all on function public.open_my_tab() from public, anon;
grant execute on function public.open_my_tab() to authenticated;

/**
 * El saldo disponible de CUALQUIERA, para uso interno.
 *
 * `my_available_balance()` solo sabe del que llama, y el reparto necesita el
 * de todos. Misma cuenta que aquella (docs/00 §2.2: el disponible cae con lo
 * cargado, no con lo pagado), en una función parametrizada.
 *
 * Sin grant para `authenticated`: se llama desde las RPC de la mesa, que son
 * las que deciden a quién se le puede enseñar.
 */
create or replace function public.available_usd(p_user uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select greatest(
    coalesce((select l.monthly_limit_usd
              from public.profiles p
              join public.levels l on l.level = p.level
              where p.id = p_user), 0)
    - coalesce((select b.charged_usd
                from public.user_credit_blocks b
                where b.user_id = p_user and b.closed_at is null), 0),
    0
  );
$$;

revoke all on function public.available_usd(uuid) from public, anon, authenticated;

/**
 * El estado de mi mesa: quién está, con qué techo y cuánto puede poner.
 *
 * Enseña las cifras de TODOS los integrantes, no solo las mías — decisión del
 * 2026-08-27. La alternativa era esconder la capacidad ajena, porque
 * `min(techo − gastado, disponible)` deja ver el saldo de crédito de un amigo.
 * Se descartó: quien va a pagar tiene que poder ver el desglose completo antes
 * de poner el PIN, y una mesa donde no sabes con qué cuentas es justo la
 * conversación que este producto viene a quitar de la barra.
 *
 * Entrar a la mesa es, por tanto, aceptar también esto: los demás ven tu techo
 * y cuánto te queda de él. Se dice en la pantalla de entrada, no se descubre
 * después.
 */
create or replace function public.my_tab()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user  uuid := auth.uid();
  v_tab   public.tabs%rowtype;
  v_id    uuid;
  v_mine  public.tab_members%rowtype;
  v_avail numeric(18,4);
  v_rows  jsonb;
  v_cap   numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_id := public.my_open_tab_id();
  if v_id is null then
    return jsonb_build_object('tab', null);
  end if;

  select * into v_tab  from public.tabs where id = v_id;
  select * into v_mine from public.tab_members
    where tab_id = v_id and user_id = v_user;

  v_avail := public.available_usd(v_user);

  select coalesce(jsonb_agg(x order by x->>'joined_at'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
             'user_id',   m.user_id,
             'name',      p.full_name,
             'is_me',     m.user_id = v_user,
             'is_opener', m.user_id = v_tab.opened_by,
             'cap_usd',   m.cap_usd,
             'spent_usd', m.spent_usd,
             -- Lo que esta persona puede poner en el próximo cobro. Es el
             -- número que manda en el reparto, así que es el que hay que ver.
             'capacity_usd',
               greatest(least(m.cap_usd - m.spent_usd, public.available_usd(m.user_id)), 0),
             -- Una cuota vencida deja a alguien fuera del reparto sin que
             -- nadie lo decida (docs/00 §2.7). Enseñarlo evita la pregunta.
             'can_take_debt', public.can_take_debt(m.user_id),
             'joined_at', m.joined_at
           ) as x
    from public.tab_members m
    join public.profiles p on p.id = m.user_id
    where m.tab_id = v_id and m.left_at is null
  ) s;

  v_cap := greatest(least(v_mine.cap_usd - v_mine.spent_usd, v_avail), 0);

  return jsonb_build_object(
    'tab', jsonb_build_object(
      'tab_id',        v_tab.id,
      'token',         v_tab.token,
      'business_date', v_tab.business_date,
      -- La promesa que la mesa le hace al usuario, calculada en el servidor.
      'closes_at',     public.helios_business_day_end(v_tab.business_date),
      'opened_by_me',  v_tab.opened_by = v_user,
      'members',       v_rows,
      'my_cap_usd',    v_mine.cap_usd,
      'my_spent_usd',  v_mine.spent_usd,
      'my_left_usd',   v_cap,
      'my_max_cap_usd', v_mine.spent_usd + v_avail,
      'min_share_usd', public.min_share_usd()
    )
  );
end;
$$;

revoke all on function public.my_tab() from public, anon;
grant execute on function public.my_tab() to authenticated;

/**
 * Lo que ve quien acaba de escanear el QR, ANTES de comprometer nada.
 *
 * Mirar no compromete —igual que buscar un grupo por código no comprometía—,
 * así que esto no escribe. Devuelve el motivo por el que no se puede entrar en
 * vez de lanzar: la pantalla tiene que poder explicarlo, y un error de
 * PostgREST no se puede maquetar.
 */
create or replace function public.preview_tab(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user   uuid := auth.uid();
  v_tab    public.tabs%rowtype;
  v_bdate  date := public.helios_business_date(now());
  v_avail  numeric(18,4);
  v_count  integer;
  v_opener text;
  v_mine   uuid;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_tab from public.tabs where token = trim(p_token);
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- Una mesa de anoche no es una mesa. No hace falta cerrarla para que deje
  -- de servir: el día operativo ya la cerró.
  if v_tab.business_date <> v_bdate then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  select p.full_name into v_opener from public.profiles p where p.id = v_tab.opened_by;

  select count(*) into v_count from public.tab_members
  where tab_id = v_tab.id and left_at is null;

  v_mine := public.my_open_tab_id();

  if v_mine = v_tab.id then
    return jsonb_build_object(
      'ok', false, 'reason', 'already_in',
      'opener_name', v_opener, 'member_count', v_count
    );
  end if;

  if v_mine is not null then
    -- Estar en dos mesas haría del techo una promesa doble. Salir de la otra
    -- es un toque, así que la salida existe: solo no es automática.
    return jsonb_build_object('ok', false, 'reason', 'in_another_tab');
  end if;

  if not public.can_take_debt(v_user) then
    return jsonb_build_object('ok', false, 'reason', 'overdue');
  end if;

  if v_count >= 8 then
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;

  v_avail := (public.my_available_balance()->>'available_usd')::numeric;

  if v_avail < public.min_share_usd() then
    return jsonb_build_object(
      'ok', false, 'reason', 'no_balance',
      'available_usd', v_avail, 'min_share_usd', public.min_share_usd()
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'tab_id',           v_tab.id,
    'opener_name',      v_opener,
    'member_count',     v_count,
    -- La pantalla de entrada tiene que decir hasta cuándo dura ESTO, porque
    -- es la mitad de lo que se está aceptando.
    'closes_at',        public.helios_business_day_end(v_tab.business_date),
    -- El techo que propone la app: el saldo entero. Es el defecto, no una
    -- obligación; la pantalla deja bajarlo antes de aceptar.
    'suggested_cap_usd', floor(v_avail * 100) / 100,
    'max_cap_usd',       floor(v_avail * 100) / 100,
    'min_cap_usd',       public.min_share_usd()
  );
end;
$$;

revoke all on function public.preview_tab(text) from public, anon;
grant execute on function public.preview_tab(text) to authenticated;

/**
 * Entrar a la mesa poniendo mi techo. Exige PIN.
 *
 * Aquí ocurre TODO el consentimiento: a partir de este instante, cualquiera de
 * la mesa puede generarme deuda hasta ese techo sin volver a preguntarme. Eso
 * es exactamente lo que autorizaba entrar a un grupo, y por el mismo motivo
 * pide PIN: es un acto que compromete crédito, no una preferencia.
 *
 * El PIN se DEVUELVE fallido en vez de lanzarse, igual que en los cobros: un
 * `raise` revertiría el intento recién anotado y convertiría esta función en
 * un oráculo para probar PINes sin dejar rastro (ver 20260824170000).
 */
create or replace function public.join_tab(
  p_token   text,
  p_cap_usd numeric,
  p_pin     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_pin   jsonb;
  v_tab   public.tabs%rowtype;
  v_bdate date := public.helios_business_date(now());
  v_avail numeric(18,4);
  v_count integer;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_pin := public.verify_user_pin(p_pin);
  if not coalesce((v_pin->>'ok')::boolean, false) then
    return v_pin;
  end if;

  select * into v_tab from public.tabs where token = trim(p_token) for update;
  if not found then
    raise exception 'Ese código no corresponde a ninguna mesa' using errcode = 'P0002';
  end if;

  if v_tab.business_date <> v_bdate then
    raise exception 'Esa mesa era de otra noche' using errcode = '22023';
  end if;

  if public.my_open_tab_id() is not null then
    raise exception 'Ya estás compartiendo gastos en otra mesa' using errcode = '22023';
  end if;

  if not public.can_take_debt(v_user) then
    raise exception 'Con una cuota vencida no puedes compartir gastos' using errcode = '22023';
  end if;

  select count(*) into v_count from public.tab_members
  where tab_id = v_tab.id and left_at is null;

  -- El mismo 8 de los grupos (docs/00 §2.7): por encima, el mínimo por persona
  -- sube tanto que la mesa deja de poder pagar cuentas normales.
  if v_count >= 8 then
    raise exception 'La mesa ya tiene 8 personas' using errcode = '22023';
  end if;

  v_avail := (public.my_available_balance()->>'available_usd')::numeric;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de $%', public.min_share_usd()
      using errcode = '22023';
  end if;

  if p_cap_usd > v_avail then
    raise exception 'Tu techo sería de $% y tienes $% disponibles', p_cap_usd, v_avail
      using errcode = '22023';
  end if;

  /**
   * Volver a entrar después de haber salido empieza de cero: techo nuevo y
   * `spent_usd` a 0. No es un agujero — lo ya gastado siguió siendo deuda suya
   * y sigue descontando de su disponible, así que el saldo real ya lo acota.
   */
  insert into public.tab_members (tab_id, user_id, business_date, cap_usd, spent_usd, left_at)
  values (v_tab.id, v_user, v_bdate, p_cap_usd, 0, null)
  on conflict (tab_id, user_id) do update
    set cap_usd   = excluded.cap_usd,
        spent_usd = 0,
        left_at   = null,
        joined_at = now();

  return jsonb_build_object('ok', true, 'tab_id', v_tab.id, 'cap_usd', p_cap_usd);
end;
$$;

revoke all on function public.join_tab(text, numeric, text) from public, anon;
grant execute on function public.join_tab(text, numeric, text) to authenticated;

/**
 * Subir (o bajar) mi techo a mitad de la noche.
 *
 * Esto NO es la "recarga" que se descartó con los grupos. Aquello reabría una
 * autorización permanente que ya se había agotado; esto es cada quien
 * moviendo su propio máximo, desde su propio teléfono, para una mesa que se
 * muere sola a las 10 AM. Sin ello, agotar el techo a las 3 AM es un callejón
 * sin salida: con los grupos había que cerrar el grupo y abrir otro.
 *
 * No se puede bajar por debajo de lo ya gastado: esa deuda ya existe.
 */
create or replace function public.set_my_tab_cap(p_cap_usd numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := auth.uid();
  v_id    uuid;
  v_mine  public.tab_members%rowtype;
  v_avail numeric(18,4);
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_id := public.my_open_tab_id();
  if v_id is null then
    raise exception 'No estás en ninguna mesa' using errcode = 'P0002';
  end if;

  select * into v_mine from public.tab_members
  where tab_id = v_id and user_id = v_user for update;

  if p_cap_usd < v_mine.spent_usd then
    raise exception 'Ya llevas $% en esta mesa, el techo no puede bajar de ahí',
      v_mine.spent_usd using errcode = '22023';
  end if;

  if p_cap_usd < public.min_share_usd() then
    raise exception 'Tu techo no puede bajar de $%', public.min_share_usd()
      using errcode = '22023';
  end if;

  v_avail := (public.my_available_balance()->>'available_usd')::numeric;

  -- El disponible ya tiene descontado lo gastado, así que el techo máximo es
  -- lo gastado más lo que queda.
  if p_cap_usd > v_mine.spent_usd + v_avail then
    raise exception 'Tu techo sería de $% y solo puedes llegar a $%',
      p_cap_usd, v_mine.spent_usd + v_avail using errcode = '22023';
  end if;

  update public.tab_members set cap_usd = p_cap_usd
  where tab_id = v_id and user_id = v_user;

  return jsonb_build_object('ok', true, 'cap_usd', p_cap_usd);
end;
$$;

revoke all on function public.set_my_tab_cap(numeric) from public, anon;
grant execute on function public.set_my_tab_cap(numeric) to authenticated;

/**
 * Salir de la mesa. Un toque, efecto inmediato, nada que devolver.
 *
 * Con el grupo, salir devolvía el ticket retenido y era media pantalla de
 * explicación. Aquí no se retuvo nada: salir solo significa que los cobros
 * siguientes ya no te incluyen. La deuda que ya asumiste sigue siendo tuya,
 * como debe ser.
 */
create or replace function public.leave_tab()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  v_id := public.my_open_tab_id();
  if v_id is null then
    return jsonb_build_object('ok', true, 'already_out', true);
  end if;

  update public.tab_members set left_at = now()
  where tab_id = v_id and user_id = v_user and left_at is null;

  return jsonb_build_object('ok', true, 'tab_id', v_id);
end;
$$;

revoke all on function public.leave_tab() from public, anon;
grant execute on function public.leave_tab() to authenticated;
