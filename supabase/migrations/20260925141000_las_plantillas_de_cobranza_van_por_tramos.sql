-- ============================================================================
-- Ronda — Las plantillas de cobranza van por los cinco tramos de atraso
--
-- La cartera vencida se trabaja por tramos (`t1`…`t5`, los cortes de
-- `admin_collection_flow`: gracia, intervalo, baja y expulsión), pero las
-- plantillas de WhatsApp seguían escritas por los `bucket` viejos, que juntan
-- en «congelado» a quien lleva un día y a quien lleva veinte. A cada tramo le
-- pasa algo distinto y el mensaje tiene que decirlo.
--
-- Qué cambia:
--   · cinco filas nuevas, `t1`…`t5`, con un texto de fábrica escrito para lo
--     que le pasa a la persona en ese tramo. `por_vencer` y `vence_hoy` siguen
--     y valen para los dos esquemas;
--   · una variable nueva, `{dias_atraso}` («12 días»), solo para las de tramo:
--     las cifras salen de las variables, nunca escritas en el texto;
--   · `admin_collection_templates(p_tramos)`: con `true`, las siete del panel
--     nuevo (Por vencer, Vence hoy y los cinco tramos) y sus variables; sin él,
--     las cinco de siempre, para el panel de `main`;
--   · `admin_set_collection_template` acepta `{dias_atraso}` en las de tramo,
--     y `admin_reset_collection_template` dice si la plantilla no existe.
--
-- Las filas viejas (`congelado`, `baja_nivel`, `expulsion`) no se borran: el
-- panel de `main` las sigue usando.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Las cinco de tramo
-- ---------------------------------------------------------------------------

insert into public.collection_templates (bucket, label, body, default_body, sort_order)
select v.bucket, v.label, v.texto, v.texto, v.orden
from (values
  (
    't1',
    'Cupo congelado, sin cargo',
    'Hola {nombre}, te escribimos de Helios. Tu cuota del {fecha_vencimiento} está vencida y, mientras siga pendiente, tu cupo queda congelado. Son {monto_usd} ({monto_bs}). Si la pagas en los próximos días, no se te cobra el cargo por atraso. Puedes pagarla por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y reportarla desde la app. Si ya pagaste, ignora este mensaje.',
    31
  ),
  (
    't2',
    'Con cargo por atraso',
    'Hola {nombre}, te escribimos de Helios. Tu cuota del {fecha_vencimiento} lleva {dias_atraso} vencida y ya tiene el cargo por atraso. Tu cupo seguirá congelado hasta que te pongas al día. Las cuotas vencidas suman {monto_usd} ({monto_bs}); el monto exacto, con el cargo incluido, te aparece en la app al pagar. Puedes pagar por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y reportarlo desde la app. En cuanto lo aprobemos, recuperas tu cupo.',
    32
  ),
  (
    't3',
    'Dos cuotas vencidas',
    'Hola {nombre}, te escribimos de Helios. Tu deuda lleva {dias_atraso} vencida. Las cuotas vencidas suman {monto_usd} ({monto_bs}), más los cargos por atraso, que te aparecen en la app al pagar. Tu cupo sigue congelado y, si la deuda continúa pendiente, tu cuenta será suspendida y bajarás de nivel. Puedes pagar por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y reportarlo desde la app. Si necesitas acordar una fecha, respóndenos por aquí.',
    33
  ),
  (
    't4',
    'Cuenta suspendida',
    'Hola {nombre}, te escribimos de Helios. Tu cuota del {fecha_vencimiento} lleva {dias_atraso} vencida. Tu cuenta está suspendida y bajaste de nivel. Las cuotas vencidas suman {monto_usd} ({monto_bs}), más los cargos por atraso. Respóndenos por aquí para acordar cómo pagarla, o abónala por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y repórtalo desde la app.',
    34
  ),
  (
    't5',
    'Último aviso',
    'Hola {nombre}, te escribimos de Helios. Tu deuda de {monto_usd} ({monto_bs}), más los cargos por atraso, lleva {dias_atraso} vencida y tu cuenta quedó fuera del sistema. Queremos resolverlo contigo: respóndenos por aquí y buscamos juntos la forma de que te pongas al día.',
    35
  )
) as v(bucket, label, texto, orden)
on conflict (bucket) do nothing;

-- ---------------------------------------------------------------------------
-- Qué variables vale cada plantilla
-- ---------------------------------------------------------------------------
-- Un solo sitio para las dos funciones: lo que la pantalla ofrece y lo que el
-- servidor deja guardar no pueden discrepar. `{dias_atraso}` solo en las de
-- tramo: el panel de `main` no sabe rellenarla y la dejaría con las llaves a
-- la vista.

create or replace function public.helios_collection_template_variables(p_tramos boolean)
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select array['nombre', 'monto_usd', 'monto_bs', 'fecha_vencimiento',
               'banco', 'telefono_pago', 'cedula_pago']
         || case when p_tramos then array['dias_atraso'] else array[]::text[] end;
$fn$;

comment on function public.helios_collection_template_variables(boolean) is
  'Las variables de las plantillas de cobranza; con true, también {dias_atraso}, que solo vale en las de tramo (t1…t5).';

revoke all on function public.helios_collection_template_variables(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- La lectura
-- ---------------------------------------------------------------------------
-- Cambia la firma (gana `p_tramos`): se borra la vieja. La llamada sin
-- argumentos sigue encontrando esta, con el default.

drop function if exists public.admin_collection_templates();

create or replace function public.admin_collection_templates(p_tramos boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_tramos boolean := coalesce(p_tramos, false);
  v_rows   jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_order), '[]'::jsonb)
  into v_rows
  from (
    select
      t.bucket, t.label, t.body, t.default_body, t.sort_order, t.updated_at,
      t.body is distinct from t.default_body as edited,
      coalesce(pa.full_name, 'Alguien del equipo') as updated_by_name
    from public.collection_templates t
    left join public.platform_admins pa on pa.user_id = t.updated_by
    where case
      when v_tramos then t.bucket in ('por_vencer', 'vence_hoy', 't1', 't2', 't3', 't4', 't5')
      else t.bucket in ('por_vencer', 'vence_hoy', 'congelado', 'baja_nivel', 'expulsion')
    end
  ) q;

  return jsonb_build_object(
    -- Las variables que el panel sabe rellenar. Viajan con las plantillas para
    -- que la pantalla pueda listarlas sin tenerlas escritas dos veces.
    'variables', to_jsonb(public.helios_collection_template_variables(v_tramos)),
    'rows', v_rows
  );
end;
$fn$;

comment on function public.admin_collection_templates(boolean) is
  'Plantillas de WhatsApp de cobranza. p_tramos = true: por_vencer, vence_hoy y t1…t5 (panel nuevo); sin él, los cinco bucket de siempre.';

-- ---------------------------------------------------------------------------
-- Guardar
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_collection_template(p_bucket text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor       uuid := auth.uid();
  v_antes       text;
  v_permitidas  text[] := public.helios_collection_template_variables(p_bucket ~ '^t[1-5]$');
  v_desconocida text;
begin
  -- Cambiar el texto que se le manda a la gente es del super admin, igual que
  -- publicar un aviso automático.
  perform public.helios_assert_super_admin('cambiar las plantillas de cobranza');

  select body into v_antes from public.collection_templates where bucket = p_bucket;
  if not found then
    raise exception 'No existe la plantilla %', p_bucket using errcode = '22023';
  end if;

  if p_body is null or length(trim(p_body)) < 20 then
    raise exception 'El mensaje no puede estar vacío' using errcode = '22023';
  end if;

  -- Una variable que no existe sale con las llaves a la vista en el teléfono
  -- de alguien. Se corta aquí.
  select m[1] into v_desconocida
  from regexp_matches(p_body, '\{(\w+)\}', 'g') m
  where not (m[1] = any(v_permitidas))
  limit 1;

  if v_desconocida is not null then
    raise exception 'La plantilla usa {%}, que no existe. Las disponibles son: %',
      v_desconocida, array_to_string(v_permitidas, ', ')
      using errcode = '22023';
  end if;

  update public.collection_templates
  set body = trim(p_body), updated_by = v_actor, updated_at = now()
  where bucket = p_bucket;

  perform audit.log(v_actor, 'collection_template.set', null, jsonb_build_object(
    'bucket', p_bucket,
    'from_body', v_antes,
    'to_body', trim(p_body)
  ));

  return jsonb_build_object('ok', true, 'bucket', p_bucket);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Volver al texto de fábrica
-- ---------------------------------------------------------------------------

create or replace function public.admin_reset_collection_template(p_bucket text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
begin
  perform public.helios_assert_super_admin('cambiar las plantillas de cobranza');

  update public.collection_templates
  set body = default_body, updated_by = v_actor, updated_at = now()
  where bucket = p_bucket;

  -- Sin esto, una clave mal escrita dejaba una línea en la bitácora de algo
  -- que no pasó.
  if not found then
    raise exception 'No existe la plantilla %', p_bucket using errcode = '22023';
  end if;

  perform audit.log(v_actor, 'collection_template.reset', null,
    jsonb_build_object('bucket', p_bucket));
end;
$fn$;

revoke all on function public.admin_collection_templates(boolean) from public, anon;
revoke all on function public.admin_set_collection_template(text, text) from public, anon;
revoke all on function public.admin_reset_collection_template(text) from public, anon;
grant execute on function public.admin_collection_templates(boolean) to authenticated;
grant execute on function public.admin_set_collection_template(text, text) to authenticated;
grant execute on function public.admin_reset_collection_template(text) to authenticated;
