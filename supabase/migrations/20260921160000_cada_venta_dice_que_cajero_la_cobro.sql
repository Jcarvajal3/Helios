-- ===========================================================================
-- Cada venta dice qué cajero la cobró, y el cierre las suma por persona
-- ===========================================================================
-- En un bar, la cajera se lleva una comisión por lo que vende. Si cobrar con
-- Ronda no cuenta para esa comisión, quien está en la barra tiene un motivo
-- para no ofrecerlo — y quien decide si Ronda se usa o no en un local no es el
-- dueño que firmó: es la persona que tiene delante al cliente a las 2 AM.
--
-- El local ya podía tener varias cuentas de cajero. Lo que no podía era
-- separar sus ventas, así que la comisión no se podía repartir y la pantalla
-- de Ventas no servía para cerrar la caja de nadie.
--
-- ---------------------------------------------------------------------------
-- El dato ya estaba
-- ---------------------------------------------------------------------------
-- `charges.requested_by` existe desde 20260822054000 —«Quién generó el QR en
-- el comercio»— y `request_charge` lo escribe con `auth.uid()` en cada cobro.
-- Nunca se enseñó en ninguna pantalla. Aquí no se empieza a guardar nada: se
-- saca lo que lleva un mes guardándose, y por eso el resumen funciona hacia
-- atrás desde el primer cobro del local y no desde hoy.
--
-- Que siga sirviendo para siempre depende de una decisión que ya está tomada
-- en `merchant_staff_remove`: dar de baja a alguien lo desactiva, no lo borra,
-- «porque los cobros que generó esa persona apuntan a su fila». Una cajera que
-- se fue en marzo sigue teniendo nombre en el cierre de marzo.
--
-- ---------------------------------------------------------------------------
-- Quién ve qué (decisión de Javier, 2026-09-21)
-- ---------------------------------------------------------------------------
-- **El gerente ve a todo el mundo; cada quien se ve a sí mismo.** La cifra
-- propia es lo que motiva —es el sentido entero de esto—, pero el ranking de
-- la plantilla en la tablet de la barra es del dueño y no de quien entre a
-- cobrar. Entre dos cajeras y un total del local, cualquiera puede restar; se
-- asume, y por eso esto no es un control de acceso sino una cuestión de qué
-- pantalla le pone a quién delante la comparación.
--
-- La regla se aplica FILA A FILA con `my_merchant_id_as_gerente()`, igual que
-- `merchant_charge_detail` tapa el margen: un gerente lo es de SU comercio, y
-- quien esté en dos locales no hereda en uno lo que le corresponde en el otro.
--
-- El nombre del cliente no cambia: lo que se añade es de quién es la VENTA.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0. Cómo se llama quien cobró
-- ---------------------------------------------------------------------------
-- Una cuenta de panel se crea sin fila en `profiles` —solo con el metadato de
-- auth (ver 20260917210000)— y las antiguas, dadas de alta buscando por
-- teléfono, sí la tienen. Sin el `coalesce`, media plantilla sale «Sin nombre»
-- según el año en que entró a trabajar.
--
-- El respaldo al correo es el último: el nombre es opcional en las cuentas
-- viejas, y una fila de cierre que diga «Sin nombre: €840» no sirve para
-- pagarle a nadie. El correo es justamente lo que distingue a un cajero de
-- otro cuando no hay más (lo dice el pie del sidebar del panel).
--
-- NO es la misma regla que `merchant_staff_list`, aunque se parezcan: allí el
-- nombre puede venir nulo a propósito porque la pantalla de Personal pinta el
-- correo en su propia columna. Aquí hay una sola línea y tiene que decir algo.
--
-- ⚠️ Sí es la misma que la columna «Cobrado por» del CSV de contabilidad
-- (`merchant_sales_export`, 20260917220000), que ya la lleva escrita a mano
-- con este mismo `coalesce` — o sea que el local llevaba desde el 17 pudiendo
-- sumar comisiones en una hoja de cálculo, pero no verlo en pantalla. No se
-- reescribe aquí: esa función devuelve treinta columnas y copiarla entera para
-- cambiar una línea es más riesgo que el que quita. Si la regla del nombre
-- cambia alguna vez, son los dos sitios.
create or replace function public.helios_staff_name(p_user_id uuid)
returns text
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(
           nullif(trim(p.full_name), ''),
           nullif(trim(au.raw_user_meta_data ->> 'full_name'), ''),
           au.email
         )
  from auth.users au
  left join public.profiles p on p.id = au.id
  where au.id = p_user_id;
$$;

comment on function public.helios_staff_name(uuid) is
  'Como llamar en una linea a una cuenta de panel: su nombre, el del metadato de auth, o su correo. No abre auth.users a nadie: es security definer y devuelve texto.';

-- Sin grant a `authenticated`. Se llama solo desde dentro de las RPC de abajo,
-- que ya deciden de quién se puede saber el nombre; suelta, sería una forma de
-- preguntar «¿cómo se llama este uuid?» sobre cualquier cuenta del sistema.
revoke all on function public.helios_staff_name(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. El índice del cierre
-- ---------------------------------------------------------------------------
-- El resumen agrupa por `requested_by` dentro de un comercio y un rango de
-- días operativos. `charges_merchant_idx` es solo `(merchant_id)`, así que una
-- noche de un local con historia se resolvía leyendo todos sus cobros.
--
-- Parcial sobre `confirmed` porque es la única clase de fila que se suma: un
-- QR que caducó sin que nadie lo escaneara no es una venta de nadie.
create index if not exists charges_merchant_staff_idx
  on public.charges (merchant_id, business_date, requested_by)
  where status = 'confirmed';

-- ---------------------------------------------------------------------------
-- 2. El cierre por persona
-- ---------------------------------------------------------------------------
-- La pregunta que contesta: *al cerrar la noche, ¿cuánto vendió cada quien?*
--
-- Las cifras son las mismas que las de `merchant_transactions_summary` sobre
-- el mismo rango, y con el mismo filtro, para que las filas SUMEN el total del
-- local que la pantalla ya enseña arriba. Dos formas de contar la misma noche
-- que no cuadran es peor que no tener la segunda.
--
-- Sale quien cobró, no la plantilla. Alguien que no sacó un QR esa noche no
-- aparece con un cero: la lista contesta «quién cobró», y rellenarla con el
-- personal de inventario y los gerentes que no estuvieron convertiría el
-- cierre en una lista de gente a la que hay que explicar por qué está ahí.
--
-- `requested_by` es NOT NULL desde el principio, así que no hay ventas sin
-- dueño y ninguna se queda fuera del reparto.
create or replace function public.merchant_sales_by_staff(
  p_from date,
  p_to   date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  -- El comercio del que se es GERENTE, o null. Se resuelve desde la sesión y
  -- no se recibe por parámetro (20260822220000): recibirlo obligaría a
  -- comprobar en cada RPC que el comercio pedido es el suyo, y basta olvidarlo
  -- una vez para abrir la caja del local de al lado.
  v_gerente_de uuid := public.my_merchant_id_as_gerente();
  v_me         uuid := auth.uid();
  v_rows       jsonb;
begin
  if v_me is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',        x.user_id,
           'name',           x.nombre,
           'role',           x.role,
           'is_active',      x.is_active,
           'is_self',        x.is_self,
           'order_count',    x.order_count,
           'sale_usd',       x.sale_usd,
           'charged_usd',    x.charged_usd,
           -- El promedio sale de `helios_avg_ticket_usd` y no de una división
           -- escrita aquí: es la misma función que piden Ventas y Métricas, y
           -- tres divisiones distintas para el mismo promedio ya fue un bug
           -- (ver 20260830250000). Se le pasa el `sale_usd` YA redondeado, el
           -- mismo que se pinta, para que la fila cuadre consigo misma.
           'avg_ticket_usd', public.helios_avg_ticket_usd(x.sale_usd, x.order_count),
           'active_days',    x.active_days,
           'last_sale_at',   x.last_sale_at
         ) order by x.sale_usd desc, x.nombre), '[]'::jsonb)
  into v_rows
  from (
    select c.requested_by                                as user_id,
           public.helios_staff_name(c.requested_by)       as nombre,
           -- El rol de HOY, no el que tenía al cobrar: un cajero ascendido a
           -- gerente en junio no reescribe quién era en mayo, pero la lista se
           -- lee para pagarle a la persona que está ahora en el local. Null si
           -- ya no es personal del comercio.
           --
           -- ⚠️ `order by`, no `limit 1` a secas. UNA PERSONA PUEDE TENER
           -- VARIAS FILAS EN EL MISMO COMERCIO: la unicidad de `merchant_users`
           -- es `(user_id, merchant_id, branch_id)`, así que una cuenta con
           -- alcance general y otra atada a una sucursal conviven. En
           -- producción hay hoy justo ese caso —una fila de `gerente`
           -- desactivada sin sucursal y otra de `cajero` activa en la suya— y
           -- sin el orden salía la primera que devolviera el planificador: el
           -- cierre etiquetaba «Gerente · De baja» a quien está en la barra
           -- esta noche. La activa manda, y entre varias, la última.
           (select mu.role::text
              from public.merchant_users mu
             where mu.user_id = c.requested_by
               and mu.merchant_id = c.merchant_id
             order by mu.is_active desc, mu.created_at desc
             limit 1)                                    as role,
           -- Si sigue trabajando aquí. Una baja no borra sus ventas —y no debe
           -- hacerlo: se le paga la comisión de lo que vendió antes de irse—,
           -- pero el cierre tiene que poder decirlo en vez de dejar un nombre
           -- suelto que ya no se reconoce.
           --
           -- `bool_or` por lo mismo de arriba: la pregunta es «¿le queda
           -- ALGUNA puerta abierta en este local?», y con varias filas una
           -- cualquiera no la contesta.
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
           max(c.confirmed_at)                           as last_sale_at
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
      -- LA REGLA, en una línea y sin ramas: el gerente de ESE comercio lo ve
      -- todo; cualquier otro, solo lo suyo. Con `v_gerente_de` nulo la primera
      -- comparación da null —no verdadero—, así que un cajero cae siempre en
      -- la segunda.
      and (c.merchant_id = v_gerente_de or c.requested_by = v_me)
    group by c.requested_by, c.merchant_id
  ) x;

  return jsonb_build_object(
    -- Qué está mirando quien pregunta. Lo dice el servidor para que la
    -- pantalla no vuelva a decidir la regla por su cuenta: con 'self', lo que
    -- hay abajo es UNA fila y es la suya, no un local con una sola cajera.
    'scope', case when v_gerente_de is null then 'self' else 'gerente' end,
    'rows',  v_rows
  );
end;
$$;

comment on function public.merchant_sales_by_staff(date, date) is
  'Ventas por persona que cobro, en un rango de dias operativos. El gerente ve a todo el personal; cualquier otro, solo lo suyo.';

revoke all on function public.merchant_sales_by_staff(date, date) from public, anon;
grant execute on function public.merchant_sales_by_staff(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. La lista de ventas dice quién cobró cada una
-- ---------------------------------------------------------------------------
-- Copia literal de 20260919120000 con una columna más. El tipo de retorno
-- cambia, así que hay que soltarla antes: `create or replace` no puede cambiar
-- la firma de una función que devuelve table.
drop function if exists public.merchant_transactions(date, date, integer);

create or replace function public.merchant_transactions(
  p_from  date,
  p_to    date,
  p_limit integer default 500
)
returns table (
  charge_id         uuid,
  order_number      bigint,
  business_date     date,
  confirmed_at      timestamptz,
  /** Lo que se le cobró al cliente: la venta más el fee del servicio y su IVA. */
  amount_usd        numeric,
  /** La venta del comercio, con su IVA dentro. Es "tu venta" en pantalla. */
  merchant_sale_usd numeric,
  /** Entre cuántas personas se repartió la cuenta. 1 en un cobro normal. */
  payer_count       integer,
  /** El nombre de quien compró, y nada más de esa persona (20260919120000). */
  customer_name     text,
  /**
   * QUIÉN DEL LOCAL SACÓ ESTE COBRO.
   *
   * Sale de `charges.requested_by`, que se escribe en `request_charge`. Es la
   * cuenta que generó el QR, no quien lo escaneó: en un cobro de grupo la
   * venta es de esta persona por mucho que la cuenta se reparta entre cinco.
   *
   * Null cuando quien mira no puede saberlo: para un cajero, en las ventas de
   * sus compañeros. La suya sí la ve — reconocer el propio trabajo en la lista
   * es la mitad del asunto.
   */
  staff_name        text,
  cuota_1_due       date,
  /** El lunes de cierre en que el comercio cobra esa cuota. */
  cuota_1_run       date,
  cuota_2_due       date,
  cuota_2_run       date
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  -- El tope existe porque el rango es abierto: un gerente puede pedir un año
  -- desde la tablet y esta pantalla no pagina. Los totales NO salen de aquí
  -- —los da `merchant_transactions_summary` sobre el rango entero— para que
  -- recortar la lista no recorte también las cifras.
  v_limit      integer := greatest(least(coalesce(p_limit, 500), 500), 1);
  v_gerente_de uuid    := public.my_merchant_id_as_gerente();
  v_me         uuid    := auth.uid();
begin
  return query
  with mias as (
    select c.id,
           c.order_number as num,
           c.business_date as bdate,
           c.confirmed_at as conf,
           c.amount_usd as charged,
           public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd) as sale,
           c.user_id as quien,
           c.merchant_id as local,
           c.requested_by as cobro
    from public.charges c
    where c.merchant_id in (select public.my_merchant_ids())
      and c.status = 'confirmed'
      and c.business_date between p_from and p_to
    order by c.business_date desc, c.confirmed_at desc
    limit v_limit
  ),
  -- Una fila por cuota de la orden, con el lunes en que se cobra.
  --
  -- En un cobro de grupo la cuota es una POR PERSONA pero todas vencen el mismo
  -- día y hablan de la misma venta: al comercio se le paga por consumo y fecha,
  -- no por deudor, así que la fecha de cobro es una sola por muchos que se
  -- repartieran la cuenta.
  cuotas as (
    select i.charge_id                                            as cid,
           i.sequence                                             as seq,
           min(i.due_date)                                        as due,
           public.helios_settlement_run_for(min(i.due_date))       as run
    from public.installments i
    join mias m on m.id = i.charge_id
    group by i.charge_id, i.sequence
  ),
  quienes as (
    select i.charge_id as cid, count(distinct i.user_id)::integer as n
    from public.installments i
    join mias m on m.id = i.charge_id
    group by i.charge_id
  )
  select m.id,
         m.num,
         m.bdate,
         m.conf,
         m.charged,
         m.sale,
         coalesce(q.n, 1),
         p.full_name,
         -- La misma regla que el resumen, fila a fila: el gerente de ese local
         -- lo ve siempre; los demás, solo en lo que cobraron ellos.
         case when m.local = v_gerente_de or m.cobro = v_me
              then public.helios_staff_name(m.cobro) end,
         c1.due,
         c1.run,
         c2.due,
         c2.run
  from mias m
  left join public.profiles p on p.id = m.quien
  left join quienes q on q.cid = m.id
  left join cuotas c1 on c1.cid = m.id and c1.seq = 1
  left join cuotas c2 on c2.cid = m.id and c2.seq = 2
  order by m.bdate desc, m.conf desc;
end;
$$;

revoke all on function public.merchant_transactions(date, date, integer) from public, anon;
grant execute on function public.merchant_transactions(date, date, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. La ficha de una orden, también
-- ---------------------------------------------------------------------------
-- Es donde se entra cuando alguien discute una orden concreta —«la 1043 de
-- anoche»—, y «quién la cobró» es parte de esa respuesta. Copia de
-- 20260919120000 con `staff_name` añadido; el resto no se toca.
create or replace function public.merchant_charge_detail(p_charge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_charge  public.charges%rowtype;
  v_gerente boolean;
  v_out     jsonb;
begin
  select * into v_charge from public.charges where id = p_charge_id;

  -- El mismo error exista o no la orden: con dos mensajes distintos, probar
  -- identificadores a ciegas diría cuáles son de otro local.
  if not found or v_charge.merchant_id not in (select public.my_merchant_ids()) then
    raise exception 'No existe esa orden' using errcode = 'P0002';
  end if;

  v_gerente := public.my_merchant_id_as_gerente() = v_charge.merchant_id;

  select jsonb_build_object(
    'charge_id', c.id,
    'order_number', c.order_number,
    'status', c.status::text,
    'business_date', c.business_date,
    'created_at', c.created_at,
    'confirmed_at', c.confirmed_at,
    'void_reason', c.void_reason,
    'is_test', c.is_test,
    -- EL NOMBRE DE QUIEN COMPRÓ, y nada más de esa persona. Sin tapar por
    -- rol: el cajero es justo quien la atendió. Null mientras nadie haya
    -- escaneado el QR.
    'customer_name', p.full_name,
    -- QUIÉN LA COBRÓ. El gerente lo ve siempre; el cajero, en las suyas.
    'staff_name', case when v_gerente or c.requested_by = auth.uid()
                       then public.helios_staff_name(c.requested_by) end,
    -- TU VENTA: la del comercio con su IVA dentro. No es `amount_usd`, que
    -- desde la facturación por cuenta de terceros es lo que debe el
    -- consumidor (docs/00-BASES §2.11).
    'merchant_sale_usd', public.helios_merchant_sale_usd(c.base_usd, c.vat_usd, c.amount_usd),
    'base_usd', c.base_usd,
    'vat_usd', c.vat_usd,
    -- LO QUE PAGA EL CLIENTE, con el servicio de Ronda y su IVA dentro.
    'amount_usd', c.amount_usd,
    'consumer_fee_usd', c.consumer_fee_usd,
    'consumer_fee_vat_usd', c.consumer_fee_vat_usd,
    -- Lo que se le paga al local, y lo que Ronda le cobra a él. Del gerente.
    'merchant_fee_usd', case when v_gerente then c.merchant_fee_usd end,
    'merchant_fee_vat_usd', case when v_gerente then c.merchant_fee_vat_usd end,
    'merchant_net_usd', case when v_gerente then c.merchant_net_usd end,
    'is_gerente', v_gerente,
    'branch', case when b.id is null then null else jsonb_build_object(
      'id', b.id, 'name', b.name, 'address', b.address
    ) end
  )
  into v_out
  from public.charges c
  left join public.merchant_branches b on b.id = c.branch_id
  left join public.profiles p on p.id = c.user_id
  where c.id = p_charge_id;

  -- Qué se vendió, en el orden en que lo tecleó el cajero.
  v_out := v_out || jsonb_build_object('items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', ci.name,
      'quantity', ci.quantity,
      'unit_price_usd', ci.unit_price_usd,
      'line_total_usd', ci.line_total_usd
    ) order by ci.position, ci.created_at)
    from public.charge_items ci where ci.charge_id = p_charge_id
  ), '[]'::jsonb));

  -- Entre cuántos se repartió la cuenta. Sigue siendo UNA orden y UNA venta:
  -- se dice porque explica el «entre 4» del que habla el cliente, no porque
  -- cambie nada de lo que el local cobra.
  v_out := v_out || jsonb_build_object('payer_count', (
    select count(distinct i.user_id)::integer
    from public.installments i where i.charge_id = p_charge_id
  ));

  /**
   * CUÁNDO SE LE PAGA AL LOCAL CADA MITAD.
   *
   * La fecha es el lunes de cierre que corresponde al vencimiento, y la
   * calcula `helios_settlement_run_for`: el calendario del cierre vive en un
   * solo sitio y no repartido entre las pantallas que lo pintan.
   *
   * El importe viene de `settlements` **cuando ya existe la fila**, que es al
   * vencer la cuota (`run_scheduled_settlements`). Antes de eso se manda en
   * null en vez de estimarlo: el reparto por tramos y el residuo del último
   * los decide esa función, y una segunda copia de esa aritmética aquí sería
   * la tercera cifra para la misma pregunta.
   *
   * En un cobro de grupo hay una cuota POR PERSONA venciendo el mismo día y
   * todas hablan de la misma venta —al comercio se le paga por consumo y
   * fecha, no por deudor—, así que se agrupa por `sequence` y sale una fila
   * por mitad, no por integrante.
   */
  v_out := v_out || jsonb_build_object('payouts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'kind', x.kind,
      'sequence', x.seq,
      'due_date', x.due,
      'run_date', public.helios_settlement_run_for(x.due),
      'amount_usd', case when v_gerente then x.amount end,
      'paid_usd', case when v_gerente then x.paid end,
      'status', case when v_gerente then x.status end
    ) order by x.due, x.seq nulls first)
    from (
      -- El adelanto al vender, si el local lo tiene pactado.
      select 'advance'::text    as kind,
             null::smallint     as seq,
             s.due_date         as due,
             s.amount_usd       as amount,
             s.paid_usd         as paid,
             s.status::text     as status
      from public.settlements s
      where s.charge_id = p_charge_id and s.reason = 'advance'

      union all

      select 'installment',
             m.seq,
             m.due,
             s.amount_usd,
             s.paid_usd,
             s.status::text
      from (
        select i.sequence as seq, min(i.due_date) as due
        from public.installments i
        where i.charge_id = p_charge_id
        group by i.sequence
      ) m
      left join public.settlements s
        on s.charge_id = p_charge_id
       and s.reason = 'scheduled_installment'
       and s.business_date = m.due
    ) x
  ), '[]'::jsonb));

  return v_out;
end;
$$;
