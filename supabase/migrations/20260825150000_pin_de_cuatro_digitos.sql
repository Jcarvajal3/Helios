-- ============================================================================
-- Ronda — El PIN pasa de 6 a 4 dígitos
--
-- Decisión de producto (2026-08-25). Cuatro dígitos es lo que la gente espera
-- de un PIN —es el del cajero— y lo que se teclea sin mirar delante de una
-- cola. El PIN ahora se pide también para pagar (20260824170000_pin_to_pay),
-- así que deja de ser algo que se escribe una vez al abrir la app: se escribe
-- delante del cajero, con prisa, y dos dígitos de menos se notan ahí.
--
-- Lo que NO cambia es de dónde viene la seguridad. Ya lo decía la sección
-- "PIN de seguridad" de 20260821210000_auth_core.sql: la fortaleza no está en
-- el algoritmo ni en la longitud, sino en el bloqueo progresivo por intentos
-- (3 fallos → 30s, 5 → 5min, 7 → exige OTP). Con ese bloqueo, que el espacio
-- sean 10⁴ o 10⁶ combinaciones no cambia nada práctico: un atacante prueba
-- unas pocas y se queda fuera. Lo que sí importa más con 4 dígitos es la
-- lista de PINs triviales, porque el top-20 de PINs reales concentra una
-- parte enorme de los que la gente elige. Esa lista se amplía abajo.
--
-- ---------------------------------------------------------------------------
-- LOS PINS QUE YA EXISTEN: NO SE PUEDEN RECORTAR
-- ---------------------------------------------------------------------------
-- La idea natural es "quítale los dos últimos dígitos a cada PIN y listo".
-- No se puede: en `user_pins` no hay ningún PIN. Hay bcrypt del PIN + pepper,
-- que es de una sola dirección — de ahí no sale el PIN ni entero ni a
-- trozos, y sacarlo por fuerza bruta serían 10⁶ hashes de bcrypt con coste 12
-- por persona (decenas de horas cada una). Tampoco vale probar al vuelo los
-- 100 sufijos posibles cuando alguien teclee sus 4 dígitos: son 100 bcrypt de
-- coste 12, unos 25 segundos, muy por encima de cualquier timeout.
--
-- Y no hay copia en claro en ningún otro sitio: el teléfono no guarda el PIN
-- (la biometría solo guarda un "sí/no" en SecureStore) y el password
-- sincronizado en GoTrue también está hasheado.
--
-- Así que los PINs de 6 dígitos se INVALIDAN, y cada quien elige uno nuevo de
-- 4. No hace falta pantalla nueva ni aviso especial: el camino ya existe y
-- todo el mundo pasa por él solo.
--
--   · Con sesión abierta → `my_account_state.has_pin` pasa a false, la etapa
--     del store es 'needs_pin' y el portero manda a (auth)/pin-create.
--   · Sin sesión, en un dispositivo de confianza → `check_device_login` ya
--     responde 'otp' cuando no hay fila en user_pins, así que entra por SMS
--     y de ahí cae en pin-create igual.
--
-- Lo que ninguno de los dos hace es dejar a alguien tecleando 4 dígitos
-- contra un hash de 6 hasta bloquearse la cuenta, que es lo que pasaría si
-- solo se cambiara la validación y las filas viejas se dejaran ahí.
-- ============================================================================

-- Define o cambia el PIN del usuario autenticado.
--
-- Idéntica a la de 20260821210000_auth_core.sql salvo el formato (4 dígitos)
-- y la lista de triviales.
create or replace function public.set_user_pin(p_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  if p_pin !~ '^\d{4}$' then
    raise exception 'El PIN debe ser de 4 dígitos' using errcode = '22023';
  end if;

  -- PINs trivialmente adivinables. Bloquearlos aquí, en el servidor, evita
  -- depender de que el cliente valide.
  --
  -- La lista crece respecto a la de 6 dígitos porque con 4 el problema es
  -- otro: no es que el espacio sea pequeño —el bloqueo por intentos se ocupa
  -- de eso—, es que las elecciones de la gente se amontonan en un puñado de
  -- combinaciones. Aquí están las de siempre: repeticiones, escaleras arriba
  -- y abajo, pares alternos y las dos rectas del teclado (2580 / 0852).
  if p_pin in ('0000','1111','2222','3333','4444','5555','6666','7777',
               '8888','9999','1234','4321','0123','3210','1212','2121',
               '1122','2211','1313','1010','2580','0852','6969','1004')
  then
    raise exception 'Ese PIN es demasiado fácil de adivinar' using errcode = '22023';
  end if;

  insert into public.user_pins (user_id, pin_hash, updated_at)
  values (
    v_user,
    extensions.crypt(p_pin || public.pin_pepper(), extensions.gen_salt('bf', 12)),
    now()
  )
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash,
        updated_at = now();

  -- Un PIN nuevo limpia el historial de bloqueos.
  delete from public.pin_attempts where user_id = v_user;

  update public.profiles
    set status = case when status = 'pending_pin' then 'active' else status end,
        updated_at = now()
  where id = v_user;
end;
$$;

revoke all on function public.set_user_pin(text) from public, anon;
grant execute on function public.set_user_pin(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Fuera los PINs de 6 dígitos
-- ---------------------------------------------------------------------------
-- Todo lo que hay en la tabla en este momento es de 6 dígitos: la validación
-- de arriba es lo primero que ha permitido guardar uno de 4. Por eso se
-- vacía entera y no hace falta distinguir.
--
-- `pin_attempts` se vacía con ella: un bloqueo heredado de intentos contra un
-- PIN que ya no existe dejaría a alguien esperando 5 minutos para poder
-- estrenar el suyo.
delete from public.user_pins;
delete from public.pin_attempts;

-- El status del perfil NO se toca. Quien estaba 'active' sigue estándolo: no
-- tener PIN ya lo para en el portero de la app, y `confirm_charge` exige el
-- PIN por su cuenta. Devolverlo a 'pending_pin' solo añadiría un estado del
-- que `set_user_pin` tendría que sacarlo, con el riesgo de dejar a alguien
-- fuera si algo falla a mitad.

comment on function public.set_user_pin(text) is
  'Guarda el PIN (4 dígitos desde 2026-08-25) hasheado con bcrypt + pepper.';
