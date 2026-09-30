-- ============================================================================
-- Ronda — Una cuota que no se puede pagar tiene que VERSE que no se puede
--
-- Desde el 2026-09-03 rige la regla 2 de `installment_not_in_a_live_group`:
-- mientras el grupo vive, sus cuotas no se cotizan. Es correcta y no se toca —
-- rehacer un reparto solo es seguro mientras ningún dinero se haya movido.
--
-- Lo que estaba mal era el CAMINO hasta esa regla. La lista de Cuotas no sabe
-- nada de ella: pinta esas cuotas marcables, el usuario las marca, pulsa
-- Pagar, y el "no" llega en la pantalla del método de pago con el título "No
-- pudimos preparar el pago". Recorrer el embudo entero para chocar al final es
-- lo mismo que hacía el pago ya reportado antes de `my_installments_in_review`
-- (migración 20260824110000), y se arregla igual: la lista pregunta antes.
--
-- ── Por qué la respuesta la tiene que dar el SERVIDOR ───────────────────────
--
-- La tentación es resolverlo en el cliente con un join a `groups` y comparar
-- `business_date` con el día operativo. No vale: `my_group_ids()` solo
-- devuelve grupos de hoy con `left_at is null`, así que **quien sale del grupo
-- conserva sus cuotas pero deja de ver el grupo por RLS**. Esa cuota seguiría
-- bloqueada por el trigger y la app la pintaría pagable — el mismo error de
-- hoy, en el único caso en que además nadie lo entendería.
--
-- ── Un solo sitio que decide "está bloqueada" ───────────────────────────────
--
-- El predicado estaba dentro del trigger. Ahora vive en
-- `installment_unlocks_at`, que devuelve CUÁNDO se abre en vez de un sí/no: el
-- trigger lo lee como un booleano y la lista lo enseña como una hora. Dos
-- copias del mismo predicado son el día en que la app deja marcar una cuota
-- que el servidor rechaza, que es exactamente el bug que se está cerrando.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Cuándo se abre una cuota, o null si no está cerrada
-- ---------------------------------------------------------------------------
/**
 * El instante en que esta cuota se podrá pagar, o null si ya se puede.
 *
 * Hoy solo la cierra una cosa —el grupo del que salió sigue vivo— y se abre
 * cuando ese grupo muere: el final de su día operativo, las 10 AM del día
 * siguiente (`helios_business_day_end`). Devolver el instante y no un booleano
 * es lo que deja a la app decir "se paga desde las 10 AM" sin volver a
 * calcular por su cuenta una regla que es del servidor.
 */
create or replace function public.installment_unlocks_at(p_installment_id uuid)
returns timestamptz
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select public.helios_business_day_end(g.business_date)
  from public.installments i
  join public.charges c on c.id = i.charge_id
  join public.groups   g on g.id = c.group_id
  where i.id = p_installment_id
    and g.business_date = public.helios_business_date(now())
$$;

comment on function public.installment_unlocks_at(uuid) is
  'Cuándo se podrá pagar esta cuota, o null si ya. Único sitio que decide si una cuota está cerrada por grupo vivo: lo leen el trigger de la cotización y my_locked_installments().';

revoke all on function public.installment_unlocks_at(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. El trigger, leyendo del sitio único
-- ---------------------------------------------------------------------------
/**
 * Mismo guardia y mismo mensaje que el del 2026-09-03; lo que cambia es de
 * dónde sale el veredicto. El texto se queda tal cual: es el que lee alguien
 * que ya transfirió mentalmente el dinero, y ahora además se va a ver de
 * verdad (antes la app lo tiraba: `error instanceof Error` es false para un
 * error de PostgREST, que llega como objeto plano).
 */
create or replace function public.installment_not_in_a_live_group()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.installment_unlocks_at(new.installment_id) is not null then
    raise exception
      'Esa compra es de un grupo que sigue abierto: todavía puede entrar alguien y bajarte la parte. Podrás pagarla a partir de las 10 AM.'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

revoke all on function public.installment_not_in_a_live_group() from public, anon, authenticated;

drop trigger if exists payment_quote_items_live_group on public.payment_quote_items;
create trigger payment_quote_items_live_group
  before insert on public.payment_quote_items
  for each row execute function public.installment_not_in_a_live_group();

-- ---------------------------------------------------------------------------
-- 3. Qué cuotas mías están cerradas, y hasta cuándo
-- ---------------------------------------------------------------------------
/**
 * Hermana de `my_installments_in_review()`, y por el mismo motivo: la lista de
 * Cuotas tiene que poder marcar lo que no se puede pagar ANTES de que el
 * usuario lo marque él.
 *
 * `security definer` porque la respuesta cruza `groups`, y ahí la RLS del
 * usuario no llega cuando ya salió del grupo (ver la cabecera).
 *
 * Solo las pendientes: una cuota pagada no se marca de nada.
 */
create or replace function public.my_locked_installments()
returns table (
  installment_id uuid,
  unlocks_at     timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select i.id, public.installment_unlocks_at(i.id)
  from public.installments i
  where i.user_id = (select auth.uid())
    and i.status = 'pending'
    and public.installment_unlocks_at(i.id) is not null
$fn$;

comment on function public.my_locked_installments() is
  'Cuotas del usuario que hoy no se pueden pagar porque su grupo sigue abierto, con la hora a la que se abren. La app las marca y las deja fuera de la selección, para que el rechazo no llegue en la pantalla del método de pago.';

revoke all on function public.my_locked_installments() from public, anon;
grant execute on function public.my_locked_installments() to authenticated;
