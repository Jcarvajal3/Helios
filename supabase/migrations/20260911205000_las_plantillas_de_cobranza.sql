-- ============================================================================
-- Ronda — Las plantillas de cobranza, editables
--
-- Los mensajes que el operador manda por WhatsApp viven en el código del panel:
-- uno por tramo, con sus variables. Cambiar una palabra es un despliegue, y
-- quien sabe qué palabra funciona —quien llama todos los días— no es quien
-- despliega.
--
-- ---------------------------------------------------------------------------
-- Por qué una tabla propia y no `notification_templates`
-- ---------------------------------------------------------------------------
-- El catálogo de avisos automáticos ya existe y tiene borrador, publicación y
-- variables. Sería tentador meter esto ahí. No encaja: aquel catálogo modela
-- **avisos que el sistema manda solo**, con su tipo de notificación, su canal y
-- su disparador. Estos son texto que una persona copia a WhatsApp — no se
-- mandan, no tienen tipo, no se disparan.
--
-- Meterlos en la misma tabla obligaría a inventarles un `notification_type` que
-- nunca se usa y un `trigger_label` que miente. Una tabla de cinco filas es más
-- barata que eso.
--
-- ---------------------------------------------------------------------------
-- Las variables son un contrato
-- ---------------------------------------------------------------------------
-- El panel rellena `{nombre}`, `{monto_usd}`, `{monto_bs}`,
-- `{fecha_vencimiento}`, `{banco}`, `{telefono_pago}` y `{cedula_pago}`. Si
-- alguien escribe `{comercio}` —que no existe— el mensaje sale con las llaves a
-- la vista. Por eso guardar valida contra la lista, igual que hacen los avisos
-- automáticos.
-- ============================================================================

create table if not exists public.collection_templates (
  -- El tramo de la escalera al que se manda. Los mismos valores que devuelve
  -- `admin_collections`.
  bucket      text primary key,
  label       text not null,
  body        text not null,
  -- El texto de fábrica. No se toca: es a lo que se vuelve si alguien deja una
  -- plantilla peor que la que había.
  default_body text not null,
  updated_by  uuid references auth.users (id),
  updated_at  timestamptz not null default now(),
  sort_order  integer not null default 100
);

comment on table public.collection_templates is
  'El mensaje de WhatsApp de cada tramo de cobranza. Es texto que una persona copia, no un aviso que el sistema manda: por eso no vive en notification_templates.';

alter table public.collection_templates enable row level security;
revoke all on table public.collection_templates from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Los cinco de hoy, los que ya están en el panel
-- ---------------------------------------------------------------------------

insert into public.collection_templates (bucket, label, body, default_body, sort_order) values
  (
    'por_vencer',
    'Recordatorio antes del vencimiento',
    'Hola {nombre}, te escribimos de Helios. Tu cuota de {monto_usd} ({monto_bs}) vence el {fecha_vencimiento}. Puedes pagarla por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago}. Cuando pagues, repórtalo desde la app para que te la acreditemos. ¡Gracias!',
    'Hola {nombre}, te escribimos de Helios. Tu cuota de {monto_usd} ({monto_bs}) vence el {fecha_vencimiento}. Puedes pagarla por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago}. Cuando pagues, repórtalo desde la app para que te la acreditemos. ¡Gracias!',
    10
  ),
  (
    'vence_hoy',
    'Vence hoy',
    'Hola {nombre}, tu cuota de {monto_usd} ({monto_bs}) vence hoy. Págala por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y repórtala en la app. Si ya pagaste, ignora este mensaje.',
    'Hola {nombre}, tu cuota de {monto_usd} ({monto_bs}) vence hoy. Págala por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y repórtala en la app. Si ya pagaste, ignora este mensaje.',
    20
  ),
  (
    'congelado',
    'Atraso reciente',
    'Hola {nombre}, tu cuota del {fecha_vencimiento} sigue pendiente y tu cuenta está congelada: no puedes consumir hasta ponerte al día. Son {monto_usd} ({monto_bs}). Págalos por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y repórtalo en la app; en cuanto lo aprobemos vuelves a tener tu cupo.',
    'Hola {nombre}, tu cuota del {fecha_vencimiento} sigue pendiente y tu cuenta está congelada: no puedes consumir hasta ponerte al día. Son {monto_usd} ({monto_bs}). Págalos por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago} y repórtalo en la app; en cuanto lo aprobemos vuelves a tener tu cupo.',
    30
  ),
  (
    'baja_nivel',
    'Atraso de más de 30 días',
    'Hola {nombre}, tu cuota del {fecha_vencimiento} lleva más de 30 días vencida. Tu cuenta está bloqueada y bajaste de nivel. La deuda es de {monto_usd} ({monto_bs}). Escríbenos por aquí para acordar cómo la pagas, o abónala por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago}.',
    'Hola {nombre}, tu cuota del {fecha_vencimiento} lleva más de 30 días vencida. Tu cuenta está bloqueada y bajaste de nivel. La deuda es de {monto_usd} ({monto_bs}). Escríbenos por aquí para acordar cómo la pagas, o abónala por Pago Móvil {banco} · C.I./RIF {cedula_pago} · Tel. {telefono_pago}.',
    40
  ),
  (
    'expulsion',
    'Último aviso',
    'Hola {nombre}, tu deuda con Helios de {monto_usd} ({monto_bs}) lleva más de 60 días vencida y tu cuenta quedó fuera del sistema. Queremos resolverlo: respóndenos por aquí y buscamos la forma de que te pongas al día.',
    'Hola {nombre}, tu deuda con Helios de {monto_usd} ({monto_bs}) lleva más de 60 días vencida y tu cuenta quedó fuera del sistema. Queremos resolverlo: respóndenos por aquí y buscamos la forma de que te pongas al día.',
    50
  )
on conflict (bucket) do nothing;

-- ---------------------------------------------------------------------------
-- Leerlas y cambiarlas
-- ---------------------------------------------------------------------------

create or replace function public.admin_collection_templates()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_rows jsonb;
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
  ) q;

  return jsonb_build_object(
    -- Las variables que el panel sabe rellenar. Viajan con las plantillas para
    -- que la pantalla pueda listarlas sin tenerlas escritas dos veces.
    'variables', jsonb_build_array(
      'nombre', 'monto_usd', 'monto_bs', 'fecha_vencimiento',
      'banco', 'telefono_pago', 'cedula_pago'
    ),
    'rows', v_rows
  );
end;
$$;

create or replace function public.admin_set_collection_template(
  p_bucket text,
  p_body   text
)
returns jsonb
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor    uuid := auth.uid();
  v_antes    text;
  v_permitidas text[] := array[
    'nombre', 'monto_usd', 'monto_bs', 'fecha_vencimiento',
    'banco', 'telefono_pago', 'cedula_pago'
  ];
  v_desconocida text;
begin
  -- Cambiar el texto que se le manda a la gente es del super admin, igual que
  -- publicar un aviso automático.
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar las plantillas'
      using errcode = '42501';
  end if;

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
$$;

/** Vuelve al texto de fábrica. Es la salida cuando una edición sale peor. */
create or replace function public.admin_reset_collection_template(p_bucket text)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if not exists (
    select 1 from public.platform_admins
    where user_id = v_actor and is_active and role = 'super_admin'
  ) then
    raise exception 'Solo un super admin puede cambiar las plantillas'
      using errcode = '42501';
  end if;

  update public.collection_templates
  set body = default_body, updated_by = v_actor, updated_at = now()
  where bucket = p_bucket;

  perform audit.log(v_actor, 'collection_template.reset', null,
    jsonb_build_object('bucket', p_bucket));
end;
$$;

revoke all on function public.admin_collection_templates() from public, anon;
revoke all on function public.admin_set_collection_template(text, text) from public, anon;
revoke all on function public.admin_reset_collection_template(text) from public, anon;
grant execute on function public.admin_collection_templates() to authenticated;
grant execute on function public.admin_set_collection_template(text, text) to authenticated;
grant execute on function public.admin_reset_collection_template(text) to authenticated;
