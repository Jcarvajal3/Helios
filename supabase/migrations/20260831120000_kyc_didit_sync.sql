-- ============================================================================
-- Ronda — El veredicto también se puede ir a buscar
--
-- Hasta aquí una verificación solo salía de 'processing' si el webhook de Didit
-- llegaba y cuadraba. Es un único punto de fallo, y uno silencioso: si el
-- destino del webhook apunta al otro proyecto de Supabase —hay uno de
-- desarrollo y otro de producción, y en la consola de Didit solo cabe una URL
-- por aplicación—, si el secreto compartido no es el mismo, o si la entrega se
-- pierde, nadie se entera. El expediente se queda en 'processing' PARA
-- SIEMPRE, y la app deja a la persona mirando "Verificando tu identidad" con
-- cerrar sesión como única salida, aunque en Didit su verificación esté
-- aprobada desde hace rato.
--
-- Peor: cuando el webhook llega al proyecto equivocado, esa base no conoce la
-- sesión y responde 200 para que Didit no reintente. Así que el aviso se
-- consume y no queda rastro en ninguno de los dos lados.
--
-- La salida es dejar de depender de que nos avisen: la app pide al servidor que
-- consulte `GET /v3/session/{id}/decision/` y el resultado entra por la MISMA
-- puerta de siempre, `kyc_record_didit_decision`. Esto no añade una segunda
-- forma de aprobar a nadie —el veredicto sigue siendo el de Didit y las reglas
-- de edad y de cédula única siguen donde estaban—; solo añade una segunda
-- forma de ENTERARSE.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- Cuándo se consultó por última vez
-- ---------------------------------------------------------------------------
--
-- El límite de consultas de veredicto de Didit es de la organización entera,
-- no de cada persona: sin freno, una app que reintente en bucle —o alguien con
-- su propio token en la mano— dejaría sin consultas al resto. La marca vive en
-- el expediente y no en la función de borde porque las funciones de borde son
-- efímeras y hay varias a la vez: lo único que sabe contar de verdad es la base.

alter table kyc.verifications
  add column if not exists didit_synced_at timestamptz;

comment on column kyc.verifications.didit_synced_at is
  'Última vez que se le preguntó a Didit por esta sesión. Solo sirve para no '
  'consultar más a menudo de la cuenta.';


-- ---------------------------------------------------------------------------
-- Tomar el turno de consultar
-- ---------------------------------------------------------------------------
--
-- Devuelve la sesión que toca consultar y, en el mismo movimiento, apunta que
-- se consultó. Va junto a propósito: si fueran dos llamadas, dos peticiones
-- simultáneas se llevarían las dos el turno.
--
-- `for update skip locked` cierra la otra mitad del mismo problema: dos
-- consultas a la vez sobre el mismo expediente no se esperan una a otra —eso
-- solo alargaría la petición— sino que la segunda se va de vacío.
--
-- Un `null` de vuelta no es un error: significa "no hay nada en curso" o
-- "acabas de preguntar". La app pregunta a menudo justamente para no perderse
-- el veredicto, así que lo normal es que muchas llamadas no hagan nada.

create or replace function public.kyc_claim_didit_sync(
  p_user_id      uuid,
  p_min_interval interval default interval '5 seconds'
)
returns text
language plpgsql
security definer
set search_path = public, kyc, pg_temp
as $$
declare
  v_id      uuid;
  v_session text;
begin
  select v.id, v.didit_session_id
    into v_id, v_session
  from kyc.verifications v
  where v.user_id = p_user_id
    and v.status in ('pending', 'processing')
    and v.didit_session_id is not null
    and (v.didit_synced_at is null or v.didit_synced_at < now() - p_min_interval)
  order by v.created_at desc
  limit 1
  for update skip locked;

  if v_id is null then
    return null;
  end if;

  update kyc.verifications
     set didit_synced_at = now()
   where id = v_id;

  return v_session;
end;
$$;

comment on function public.kyc_claim_didit_sync(uuid, interval) is
  'Sesión de Didit en curso de una persona, si toca consultarla. Apunta la '
  'consulta al devolverla, para que dos llamadas seguidas no valgan por dos.';

revoke all on function public.kyc_claim_didit_sync(uuid, interval)
  from public, anon, authenticated;
grant execute on function public.kyc_claim_didit_sync(uuid, interval)
  to service_role;
