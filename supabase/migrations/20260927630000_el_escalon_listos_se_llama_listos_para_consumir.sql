-- ============================================================================
-- Ronda — El escalón «listos» del embudo de Gente se llama «Listos para consumir»
--
-- Decisión de Javier (27-09): el escalón «Terminaron de darse de alta» se
-- queda, con un nombre más claro. Es un escalón ACUMULADO: los registros
-- (identidad verificada) que además ya crearon su PIN, hayan consumido o no.
-- «Usuarios que no han consumido» mentiría (dentro están también los que ya
-- consumieron), así que se llama «Listos para consumir», y el panel dice en la
-- caída hacia «Consumieron al menos una vez» cuántos listos aún no han
-- consumido.
--
-- Solo cambia el rótulo (y los comentarios que lo nombran): la clave sigue
-- siendo `listos`, la cuenta y la firma no cambian. La función sale COPIADA
-- de su última versión (20260927591000) con `gen_630.cjs`, que exige que
-- cada trozo cambiado aparezca una sola vez.
--
-- Orden: va después de 20260927591000. Si alguien vuelve a aplicar la 591000
-- después de esta, el rótulo vuelve a ser el viejo: hay que reaplicar esta.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 3. El embudo empieza en «Solicitaron el código»
-- ---------------------------------------------------------------------------
-- La cohorte es la gente que PIDIÓ EL CÓDIGO en la ventana, se verificara o
-- no, y cada escalón es la parte de esa misma gente que llegó hasta él. Así
-- cada escalón está dentro del anterior por construcción:
--
--   pidieron     Solicitaron el código           toda la cohorte
--   confirmaron  Confirmaron el teléfono         etapa <> 'solicito_el_codigo'
--   registrados  Se registraron (identidad       etapa = 'verificado': son
--                verificada)                     registros (metricas.personas)
--   listos       Listos para consumir            registros con PIN (su estado
--                                                ya no es pending_kyc ni
--                                                pending_pin), hayan
--                                                consumido o no
--   compraron    Consumieron al menos una vez
--   repitieron   Volvieron a consumir            dos consumos o más
--
-- Las claves cambian de sentido respecto a 20260927570000: `registrados` era
-- «Confirmaron el teléfono» y pasa a ser el registro (verificado); lo del
-- teléfono va en `confirmaron`, y `verificados` desaparece porque es el
-- registro. El panel pinta los escalones tal como llegan (clave, rótulo,
-- personas).
--
-- Registrarse ya no tiene dos caminos: el atajo del super admin que activa un
-- perfil sin fila aprobada en `kyc` no es un registro (hoy no hay ningún caso
-- ni en dev ni en producción).
--
-- La cohorte es por el día en que se pidió el código; la cifra «Registros»
-- de Semana y de Gente › Resumen es por el día en que se aprobó la
-- verificación. Casi siempre es el mismo día (en la barra, minutos antes de
-- consumir); cuando no, «Registros» de una semana y el escalón `registrados`
-- del embudo de esa semana difieren en quien pidió el código una semana y se
-- verificó otra. Desde el inicio coinciden siempre.
--
-- La demora hasta el primer consumo se mide desde el día de registro (la
-- verificación), no desde la solicitud.

create or replace function public.admin_growth_funnel(
  p_from        date default null,
  p_to          date default null,
  p_merchant_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_today  date := metricas.hoy();
  v_from   date;
  v_to     date;
  v_days   integer;
  v_result jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select w.desde, w.hasta, w.dias into v_from, v_to, v_days
  from metricas.gente_ventana(p_from, p_to) w;

  if p_merchant_id is not null then
    return jsonb_build_object(
      'business_date',     v_today,
      'from',              v_from,
      'to',                v_to,
      'window_days',       v_days,
      'merchant_id',       p_merchant_id,
      'steps',             null,
      'p50_days_to_first', null,
      'p90_days_to_first', null,
      'same_day_pct',      null
    );
  end if;

  with
  -- Todo el que pidió el código en la ventana, se verificara o no. El hueco
  -- entre este escalón y el siguiente avisa de que los SMS no llegan.
  cohorte as (
    select s.user_id, s.etapa
    from metricas.solicitudes s
    where s.solicito_dia between v_from and v_to
  ),
  -- Los registros de la cohorte, con su día de registro y su estado de hoy.
  registros as (
    select p.user_id, p.registro_dia as dia, p.estado as status
    from metricas.personas p
    join cohorte c on c.user_id = p.user_id
  ),
  compras as (
    select q.user_id,
           count(distinct q.charge_id)::int as ordenes,
           min(q.business_date)             as primer_dia
    from metricas.cuotas q
    join registros r on r.user_id = q.user_id
    group by 1
  ),
  -- Días entre registrarse y estrenar. La mediana y no la media: un solo
  -- rezagado que estrena a los 90 días le sube la media a todo el mundo.
  demora as (
    select (cp.primer_dia - r.dia) as dias
    from compras cp
    join registros r on r.user_id = cp.user_id
  )
  select jsonb_build_object(
    'business_date', v_today,
    'from',          v_from,
    'to',            v_to,
    'window_days',   v_days,
    'merchant_id',   null,
    'steps', jsonb_build_array(
      jsonb_build_object('key', 'pidieron', 'label', 'Solicitaron el código',
        'users', (select count(*) from cohorte)),
      jsonb_build_object('key', 'confirmaron', 'label', 'Confirmaron el teléfono',
        'users', (select count(*) from cohorte where etapa <> 'solicito_el_codigo')),
      jsonb_build_object('key', 'registrados', 'label', 'Se registraron (identidad verificada)',
        'users', (select count(*) from registros)),
      jsonb_build_object('key', 'listos', 'label', 'Listos para consumir',
        'users', (select count(*) from registros where status not in ('pending_kyc', 'pending_pin'))),
      jsonb_build_object('key', 'compraron', 'label', 'Consumieron al menos una vez',
        'users', (select count(*) from compras)),
      jsonb_build_object('key', 'repitieron', 'label', 'Volvieron a consumir',
        'users', (select count(*) from compras where ordenes >= 2))
    ),
    'p50_days_to_first', (
      select coalesce(percentile_disc(0.5) within group (order by dias), 0)::int from demora
    ),
    'p90_days_to_first', (
      select coalesce(percentile_disc(0.9) within group (order by dias), 0)::int from demora
    ),
    -- Cuántos de los que compraron lo hicieron la misma noche del registro.
    'same_day_pct', (
      select case when (select count(*) from demora) > 0
             then round(100.0 * (select count(*) from demora where dias = 0)
                              / (select count(*) from demora), 1)
             else 0 end
    )
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.admin_growth_funnel(date, date, uuid) is
  'Métricas › Gente: el embudo de la gente que pidió el código en la ventana (solicitaron el código, confirmaron el teléfono, se registraron = identidad verificada, listos para consumir = además con PIN, consumieron, repitieron). Cada escalón está dentro del anterior. Es del registro: con p_merchant_id los escalones valen null.';

revoke all on function public.admin_growth_funnel(date, date, uuid) from public, anon;
grant execute on function public.admin_growth_funnel(date, date, uuid) to authenticated;
