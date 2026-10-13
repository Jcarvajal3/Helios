-- ============================================================================
-- Helios — El total de la clínica va por moneda
--
-- Una clínica con $100 + €100 + $50 en el rango leía «$261,99» arriba de
-- una lista que, sumada a ojo, da 250: el total pasaba los €100 a dólares
-- (a la tasa cruzada del día del registro, $111,99) y la columna «Consulta»
-- los enseña en euros. Las dos cifras eran correctas y ninguna se entendía.
--
-- Cambia: `merchant_transactions_summary` y `merchant_sales_by_staff`
-- devuelven además `sale_by_currency`, lo registrado en cada moneda tal como
-- se registró (`[{"currency":"USD","sale":150},{"currency":"EUR","sale":100}]`,
-- el dólar primero). El panel enseña «$150 + €100» y deja el equivalente en
-- dólares (`sale_usd`, que no cambia) como pista. Lo de cada orden en su
-- moneda es lo mismo que `merchant_transactions.merchant_sale_cur`.
-- ============================================================================

/** Como en vivo (20261005000300), con `sale_by_currency`. */
create or replace function public.merchant_transactions_summary(p_from date, p_to date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
  v_orders     integer := 0;
  v_sale       numeric := 0;
  v_charged    numeric := 0;
  v_days       integer := 0;
  v_por_moneda jsonb;
begin
  select
    count(*)::integer,
    coalesce(sum(public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd)), 0),
    coalesce(sum(c.amount_usd), 0),
    count(distinct c.business_date)::integer
  into v_orders, v_sale, v_charged, v_days
  from public.charges c
  where c.merchant_id in (select public.my_merchant_ids())
    and c.status = 'confirmed'
    and c.business_date between p_from and p_to
    and (c.merchant_id = v_gerente_de or c.requested_by = v_me);

  select coalesce(jsonb_agg(jsonb_build_object('currency', m.currency, 'sale', m.sale)
                            order by m.currency <> 'USD', m.currency), '[]'::jsonb)
  into v_por_moneda
  from (
    select coalesce(c.currency, 'USD') as currency,
           round(sum(coalesce(c.base_cur,
             public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd))), 2) as sale
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    group by 1
  ) m;

  return jsonb_build_object(
    'scope',            case when v_gerente_de is null then 'self' else 'gerente' end,
    'order_count',      v_orders,
    'sale_usd',         round(v_sale, 2),
    'sale_by_currency', v_por_moneda,
    'charged_usd',      round(v_charged, 2),
    'avg_ticket_usd',   public.helios_avg_ticket_usd(v_sale, v_orders),
    'active_days',      v_days
  );
end;
$function$;

/** Como en vivo, con `sale_by_currency` por persona. */
create or replace function public.merchant_sales_by_staff(p_from date, p_to date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_gerente_de uuid := public.my_merchant_id_as_gerente();
  v_me         uuid := auth.uid();
  v_rows       jsonb;
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',          x.user_id,
           'name',             x.nombre,
           'role',             x.role,
           'is_active',        x.is_active,
           'is_self',          x.is_self,
           'order_count',      x.order_count,
           'sale_usd',         x.sale_usd,
           'sale_by_currency', (
             select coalesce(jsonb_agg(jsonb_build_object('currency', m.currency, 'sale', m.sale)
                                       order by m.currency <> 'USD', m.currency), '[]'::jsonb)
             from (
               select coalesce(c2.currency, 'USD') as currency,
                      round(sum(coalesce(c2.base_cur,
                        public.helios_merchant_sale_usd(c2.base_usd, c2.vat_usd, c2.amount_usd))), 2) as sale
               from public.charges c2
               where c2.merchant_id = x.merchant_id
                 and c2.requested_by is not distinct from x.user_id
                 and c2.status = 'confirmed'
                 and c2.business_date between p_from and p_to
               group by 1
             ) m
           ),
           'charged_usd',      x.charged_usd,
           'avg_ticket_usd',   public.helios_avg_ticket_usd(x.sale_usd, x.order_count),
           'active_days',      x.active_days,
           'last_sale_at',     x.last_sale_at,
           -- Helios: la comisión devengada por esos financiamientos.
           'commission_usd',   x.commission_usd
         ) order by x.sale_usd desc, x.nombre), '[]'::jsonb)
  into v_rows
  from (
    select c.requested_by                                as user_id,
           c.merchant_id                                 as merchant_id,
           public.helios_staff_name(c.requested_by)       as nombre,
           (select mu.role::text
              from public.merchant_users mu
             where mu.user_id = c.requested_by
               and mu.merchant_id = c.merchant_id
             order by mu.is_active desc, mu.created_at desc
             limit 1)                                    as role,
           coalesce((select bool_or(mu.is_active)
                       from public.merchant_users mu
                      where mu.user_id = c.requested_by
                        and mu.merchant_id = c.merchant_id), false) as is_active,
           c.requested_by = v_me                         as is_self,
           count(*)::integer                             as order_count,
           round(sum(public.helios_merchant_sale_usd(
             c.base_usd, c.vat_usd, c.amount_usd)), 2)   as sale_usd,
           round(sum(c.amount_usd), 2)                   as charged_usd,
           count(distinct c.business_date)::integer      as active_days,
           max(c.confirmed_at)                           as last_sale_at,
           round(coalesce(sum(sc.amount_usd) filter (where sc.status <> 'revertida'), 0), 2)
                                                         as commission_usd
    from public.charges c
    left join public.staff_commissions sc on sc.charge_id = c.id
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    group by c.requested_by, c.merchant_id
  ) x;

  return jsonb_build_object(
    'scope', case when v_gerente_de is null then 'self' else 'gerente' end,
    'rows',  v_rows
  );
end;
$function$;
