-- ============================================================================
-- Ronda — La ficha de un consumo dice lo mismo que el recibo de la app
--
-- `admin_charge_detail` contestaba mal tres preguntas y no contestaba dos.
--
-- ---------------------------------------------------------------------------
-- 1. El reparto de un grupo no está en los cargos hermanos
-- ---------------------------------------------------------------------------
-- La versión anterior buscaba «quiénes se unieron» entre los cargos que
-- comparten `group_id`. Eso no es el reparto: un consumo de grupo es UN cargo
-- con una cuota por persona (`helios_assign_debt` escribe dos filas de
-- `installments` por integrante, todas con el mismo `charge_id`). Los cargos
-- hermanos son las OTRAS cuentas que ese grupo puso esa noche — otra pregunta,
-- igual de legítima, pero otra.
--
-- Por eso una cuenta repartida entre cuatro enseñaba un solo integrante: el que
-- la puso. Y si el grupo había puesto dos cuentas, enseñaba dos «integrantes»
-- con el importe entero de cada cuenta.
--
-- El reparto sale de `installments` agrupadas por `user_id`, que es donde está
-- escrito. Se añaden los integrantes del grupo a los que no les tocó nada, con
-- su motivo cuando consta, igual que hace `charge_detail` para la app.
--
-- ---------------------------------------------------------------------------
-- 2. Las cuotas no decían de quién eran
-- ---------------------------------------------------------------------------
-- Venían todas las del cargo sin `user_id`: cuatro filas numeradas 1, 1, 2, 2
-- en una cuenta de dos personas. Ahora cada una dice de quién es.
--
-- ---------------------------------------------------------------------------
-- 3. `amount_usd` no es el principal
-- ---------------------------------------------------------------------------
-- Es el total CON el fee dentro; el principal es `base_usd`. La ficha sumaba
-- `amount_usd + consumer_fee_usd` y presentaba el resultado como «a pagar», o
-- sea el fee contado dos veces. Se manda `financed_usd` —la cuenta del local—
-- y el IVA del servicio, que son las piezas que faltaban para que el desglose
-- cuadre con el que el cliente lee en su teléfono.
--
-- ---------------------------------------------------------------------------
-- 4 y 5. Lo que no había: las líneas y los datos fiscales
-- ---------------------------------------------------------------------------
-- `charge_items` existe desde 20260822250000 y la ficha del equipo era el
-- único sitio que no las leía: el panel del local las enseña en su
-- comprobante y la app en «Qué se consumió». Van con el RIF y la razón social,
-- que es lo que hace falta cuando alguien reclama.
--
-- Solo lectura. No toca ni un dato.
-- ============================================================================

create or replace function public.admin_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_today    date := public.helios_business_date(now());
  v_charge   public.charges%rowtype;
  v_financed numeric(18,4);
  v_payers   integer;
  v_out      jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_charge from public.charges where id = p_charge_id;
  if not found then
    raise exception 'No existe ese consumo' using errcode = 'P0002';
  end if;

  -- La cuenta del local. `base_usd` es null en los cobros anteriores a
  -- 20260830190000, cuando el fee todavía no se desglosaba: entonces el total
  -- ERA la cuenta, y eso es lo que dice el respaldo.
  v_financed := coalesce(v_charge.base_usd, v_charge.amount_usd);

  select count(distinct i.user_id) into v_payers
  from public.installments i where i.charge_id = p_charge_id;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    -- Las dos clases de cifra, y nunca una suma de las dos. `amount_usd` lleva
    -- el fee dentro; `financed_usd` es lo que ocupó cupo. Quien las sume
    -- cuenta el servicio dos veces.
    'amount_usd', c.amount_usd,
    'financed_usd', v_financed,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    'merchant_fee_usd', c.merchant_fee_usd,
    'merchant_fee_vat_usd', c.merchant_fee_vat_usd,
    'merchant_net_usd', c.merchant_net_usd,
    'is_group', c.group_id is not null,
    'group_id', c.group_id,
    'is_test', c.is_test,
    -- Con qué se reclama: el rótulo no basta, hace falta la razón social y el
    -- RIF de la empresa que cobró.
    'merchant', jsonb_build_object(
      'id', m.id, 'name', m.name, 'legal_name', m.legal_name, 'tax_id', m.tax_id
    ),
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end,
    -- Quien puso la cuenta. En un grupo no es «el que debe»: es el que la
    -- inició, y el resto del reparto va en `split`.
    'user', case when p.id is null then null else jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'phone_e164', p.phone_e164
    ) end
  )
  into v_out
  from public.charges c
  join public.merchants m on m.id = c.merchant_id
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  -- Qué se consumió, en el orden en que lo tecleó el cajero.
  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Las cuotas, cada una con su dueño. `days_overdue` solo cuenta mientras se
  -- deba: una pagada con retraso no sigue atrasándose, y una castigada ya no
  -- se cobra.
  v_out := v_out || jsonb_build_object('installments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id,
      'user_id', i.user_id,
      'full_name', pi.full_name,
      'sequence', i.sequence,
      'amount_usd', i.amount_usd,
      'financed_usd', i.financed_usd,
      'due_date', i.due_date,
      'status', i.status::text,
      'paid_at', i.paid_at,
      'written_off_at', i.written_off_at,
      'days_overdue', case
        when i.status = 'paid' or i.written_off_at is not null then 0
        else greatest(v_today - i.due_date, 0)
      end
    ) order by pi.full_name nulls last, i.user_id, i.sequence)
    from public.installments i
    left join public.profiles pi on pi.id = i.user_id
    where i.charge_id = p_charge_id
  ), '[]'::jsonb));

  /**
   * EL REPARTO DEL DÉBITO: quién se llevó cuánto de esta cuenta.
   *
   * Sale de las cuotas agrupadas por persona, que es donde el servidor lo
   * escribió. `financed_usd` de las partes suma la cuenta del local y
   * `payable_usd` suma el total del cargo — si alguna vez no cuadraran, es que
   * el asiento no cuadra.
   *
   * Los integrantes del grupo a los que no les tocó nada salen con las cifras
   * en null y su motivo cuando consta, para que la lista sea la mesa entera y
   * no solo los que pagaron.
   */
  v_out := v_out || jsonb_build_object('split', coalesce((
    select jsonb_agg(jsonb_build_object(
      'user_id', x.user_id,
      'full_name', pr.full_name,
      'phone_e164', pr.phone_e164,
      'financed_usd', x.financed_usd,
      'payable_usd', x.payable_usd,
      'installments_paid', x.paid,
      'installments_total', x.total,
      'started_it', x.user_id = v_charge.user_id,
      'reason', case
        when x.payable_usd is not null then null
        when v_financed < (v_payers + 1) * public.min_share_usd() then 'too_small'
        else null
      end
    ) order by x.payable_usd desc nulls last, pr.full_name nulls last)
    from (
      select i.user_id,
             sum(i.financed_usd)                                  as financed_usd,
             sum(i.amount_usd)                                    as payable_usd,
             count(*) filter (where i.status = 'paid')::integer    as paid,
             count(*)::integer                                     as total
      from public.installments i
      where i.charge_id = p_charge_id
      group by i.user_id
      union all
      select gm.user_id, null::numeric, null::numeric, 0, 0
      from public.group_members gm
      where v_charge.group_id is not null
        and gm.group_id = v_charge.group_id
        and gm.left_at is null
        and not exists (
          select 1 from public.installments i2
          where i2.charge_id = p_charge_id and i2.user_id = gm.user_id
        )
    ) x
    join public.profiles pr on pr.id = x.user_id
  ), '[]'::jsonb));

  -- El grupo, y las OTRAS cuentas que puso esa noche. Esto sí son los cargos
  -- hermanos, y con ese nombre: no se confunden con el reparto de arriba.
  v_out := v_out || jsonb_build_object('group', case
    when v_charge.group_id is null then null
    else (
      select jsonb_build_object(
        'group_id', g.id,
        -- La copia del cargo manda sobre el join vivo: el nombre que tenía el
        -- grupo el día del consumo, no el de hoy.
        'name', coalesce(v_charge.group_name, g.name),
        'business_date', g.business_date,
        'other_charges', coalesce((
          select jsonb_agg(jsonb_build_object(
            'charge_id', c2.id,
            'order_number', c2.order_number,
            'merchant_name', m2.name,
            'amount_usd', c2.amount_usd,
            'financed_usd', coalesce(c2.base_usd, c2.amount_usd),
            'status', c2.status::text,
            'confirmed_at', c2.confirmed_at,
            'split_between', (
              select count(distinct i3.user_id)::integer
              from public.installments i3 where i3.charge_id = c2.id
            )
          ) order by c2.created_at)
          from public.charges c2
          join public.merchants m2 on m2.id = c2.merchant_id
          where c2.group_id = g.id and c2.id <> p_charge_id
        ), '[]'::jsonb)
      )
      from public.groups g where g.id = v_charge.group_id
    )
  end);

  return v_out;
end;
$$;

comment on function public.admin_charge_detail(uuid) is
  'La factura de un consumo para el equipo: el desglose consumo/servicio/total, las lineas del local, el reparto del debito por persona, las cuotas de cada quien y las otras cuentas del grupo esa noche.';

revoke all on function public.admin_charge_detail(uuid) from public, anon;
grant execute on function public.admin_charge_detail(uuid) to authenticated;
