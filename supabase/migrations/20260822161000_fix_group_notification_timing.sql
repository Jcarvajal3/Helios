-- ============================================================================
-- Ronda — El aviso del cargo de grupo cuelga del cobro, no de las cuotas
--
-- Bug detectado al probar: la notificación del cargo de grupo no llegaba
-- nunca.
--
-- Causa inmediata: el trigger colgaba de `installments` y decidía leyendo
-- `charges.group_id`, pero `confirm_charge_as_group` escribe las cuotas ANTES
-- de marcar el cobro como de grupo. Cuando el trigger corría, esa columna
-- todavía estaba en null, así que siempre concluía "esto no es de grupo" y se
-- iba sin avisar.
--
-- Causa de fondo: estaba colgado del hecho equivocado. Insertar una cuota no
-- es el suceso que hay que anunciar —de hecho ocurre N veces por consumo—; el
-- suceso es **que se confirmó un cobro repartido**, y eso pasa exactamente
-- una vez, en `charges`.
--
-- Colgándolo de ahí desaparecen los tres problemas a la vez: no depende del
-- orden de escrituras dentro de otra función, no hace falta filtrar por
-- `sequence = 1` para no avisar dos veces, y no hace falta diferirlo — cuando
-- el cobro pasa a `confirmed` ya están escritas todas las cuotas.
-- ============================================================================

drop trigger if exists installments_notify_group on public.installments;
drop function if exists public.notify_group_charge();

create or replace function public.notify_group_charge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_group    text;
  v_merchant text;
  v_who      text;
  v_member   record;
begin
  -- Solo al confirmarse, y solo si fue repartido.
  if new.status <> 'confirmed' or old.status = 'confirmed' or new.group_id is null then
    return null;
  end if;

  select g.name into v_group from public.groups g where g.id = new.group_id;
  select m.name into v_merchant from public.merchants m where m.id = new.merchant_id;
  select coalesce(p.full_name, 'Alguien') into v_who
  from public.profiles p where p.id = new.user_id;

  for v_member in
    select i.user_id, sum(i.amount_usd) as total
    from public.installments i
    where i.charge_id = new.id
      -- A quien lo inició no se le avisa: estaba delante del cajero
      -- decidiendo el reparto.
      and i.user_id <> new.user_id
    group by i.user_id
  loop
    perform public.notify(
      v_member.user_id,
      'group_charge',
      format('%s dividió una cuenta contigo', v_who),
      format('Te tocaron $%s en %s, del grupo %s. Se paga en dos cuotas.',
             trim(to_char(v_member.total, 'FM999999990.00')), v_merchant, v_group),
      jsonb_build_object(
        'charge_id', new.id,
        'group_id', new.group_id,
        'amount_usd', v_member.total,
        'initiated_by', new.user_id
      )
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_group_charge() from public, anon, authenticated;

create trigger charges_notify_group
  after update on public.charges
  for each row execute function public.notify_group_charge();
