-- ============================================================================
-- Ronda — La cuenta del grupo, con las partes de todos
--
-- Una cuenta pagada en grupo no tenía pantalla. En el detalle del grupo era
-- una fila fija con "tu parte de $48"; en Inicio y en el historial, una
-- tarjeta desplegable que solo sabe de TU parte (`my_purchases` lee tus
-- cuotas). El reparto completo —quién pagó qué— solo se veía ANTES de
-- confirmar, en `preview_group_charge`, y después de pagar desaparecía.
--
-- Esta RPC es el recibo: la cuenta, quién la inició, entre cuántos, lo que
-- puso cada uno, lo que te tocó a ti con sus dos cuotas, y las líneas del
-- local. Sirve a la fila del grupo, a Inicio, al historial y al aviso de
-- cargo, que es cuando la gente pregunta "¿esto qué fue?".
--
-- ── Quién puede verla ───────────────────────────────────────────────────────
--
-- · Quien tenga cuotas de la cuenta (participó en el reparto).
-- · Quien esté o haya estado en el grupo de la cuenta, aunque esa cuenta no
--   le tocara: es la misma regla que `group_detail`, que ya enseña la lista.
-- · Una cuenta individual solo la ve quien la pagó.
--
-- Lo que se enseña de los DEMÁS es su parte de ESTA cuenta, que ya se veía en
-- el reparto antes de confirmar y que docs/00 §2.7.2 decide que dentro del
-- grupo no se esconde. No se devuelve ni su saldo ni su aporte.
--
-- ── Por qué no te tocó ──────────────────────────────────────────────────────
--
-- La misma regla que `group_detail` (20260903140000): `too_small` cuando la
-- cuenta no llega a `(deudores + 1) × mínimo`, y nada en los demás casos —
-- mora y aporte agotado dependen del estado de aquel momento, que no se
-- guarda, y un motivo inventado en un recibo es peor que ninguno.
-- ============================================================================

create or replace function public.charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_user     uuid := auth.uid();
  v_charge   public.charges%rowtype;
  v_payers   integer;
  v_allowed  boolean;
begin
  if v_user is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found or v_charge.status <> 'confirmed' then
    raise exception 'Cuenta no encontrada' using errcode = 'P0002';
  end if;

  -- Participante, integrante del grupo (presente o pasado), o quien la pagó.
  v_allowed :=
    exists (select 1 from public.installments i
            where i.charge_id = v_charge.id and i.user_id = v_user)
    or (v_charge.group_id is not null and exists (
          select 1 from public.group_members m
          where m.group_id = v_charge.group_id and m.user_id = v_user))
    or v_charge.user_id = v_user;

  if not v_allowed then
    raise exception 'No puedes ver esta cuenta' using errcode = '42501';
  end if;

  select count(distinct i.user_id) into v_payers
  from public.installments i where i.charge_id = v_charge.id;

  return jsonb_build_object(
    'charge_id',            v_charge.id,
    'order_number',         v_charge.order_number,
    'merchant_name',        (select m.name from public.merchants m where m.id = v_charge.merchant_id),
    'merchant_logo_url',    (select m.logo_url from public.merchants m where m.id = v_charge.merchant_id),
    'branch_name',          (select b.name from public.merchant_branches b where b.id = v_charge.branch_id),
    'business_date',        v_charge.business_date,
    'confirmed_at',         v_charge.confirmed_at,
    'amount_usd',           v_charge.amount_usd,
    'financed_usd',         coalesce(v_charge.base_usd, v_charge.amount_usd),
    'consumer_fee_usd',     coalesce(v_charge.consumer_fee_usd, 0),
    'consumer_fee_vat_usd', coalesce(v_charge.consumer_fee_vat_usd, 0),
    'group_id',             v_charge.group_id,
    -- La copia manda sobre el join vivo, como en `my_purchases`: el nombre
    -- que tenía el grupo esa noche.
    'group_name',           coalesce(v_charge.group_name,
                              (select g.name from public.groups g where g.id = v_charge.group_id)),
    'started_by',           (select p.full_name from public.profiles p where p.id = v_charge.user_id),
    'started_by_me',        v_charge.user_id = v_user,
    'split_between',        greatest(v_payers, 1),
    'my_share_usd', (
      select sum(i.amount_usd) from public.installments i
      where i.charge_id = v_charge.id and i.user_id = v_user
    ),
    'my_installments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id',         i.id,
               'sequence',   i.sequence,
               'amount_usd', i.amount_usd,
               'due_date',   i.due_date,
               'status',     i.status
             ) order by i.sequence), '[]'::jsonb)
      from public.installments i
      where i.charge_id = v_charge.id and i.user_id = v_user
    ),
    /**
     * Quién pagó qué. La unión de los que tienen cuotas y, si es de grupo,
     * los que están en el grupo y no participaron — con su motivo si consta.
     * Ordenados por `user_id` para que la tinta por persona (app) coincida
     * con la del detalle del grupo.
     */
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id',   x.user_id,
               'name',      pr.full_name,
               'is_me',     x.user_id = v_user,
               'share_usd', x.share_usd,
               'reason',    case
                              when x.share_usd is not null then null
                              when coalesce(v_charge.base_usd, v_charge.amount_usd) <
                                   (v_payers + 1) * public.min_share_usd()
                                then 'too_small'
                              else null
                            end
             ) order by x.user_id), '[]'::jsonb)
      from (
        select i.user_id, sum(i.amount_usd) as share_usd
        from public.installments i
        where i.charge_id = v_charge.id
        group by i.user_id
        union all
        select m.user_id, null::numeric
        from public.group_members m
        where v_charge.group_id is not null
          and m.group_id = v_charge.group_id
          and m.left_at is null
          and not exists (select 1 from public.installments i2
                          where i2.charge_id = v_charge.id and i2.user_id = m.user_id)
      ) x
      join public.profiles pr on pr.id = x.user_id
    ),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'name',           ci.name,
               'quantity',       ci.quantity,
               'unit_price_usd', ci.unit_price_usd,
               'line_total_usd', ci.line_total_usd
             ) order by ci.position, ci.created_at), '[]'::jsonb)
      from public.charge_items ci
      where ci.charge_id = v_charge.id
    )
  );
end;
$$;

revoke all on function public.charge_detail(uuid) from public, anon;
grant execute on function public.charge_detail(uuid) to authenticated;

comment on function public.charge_detail(uuid) is
  'El recibo de una cuenta: quién la inició, entre cuántos, lo que puso cada uno y tus cuotas. Ver docs/00-BASES 2.7.';
