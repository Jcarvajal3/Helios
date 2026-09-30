-- ============================================================================
-- Ronda — Un registro es una persona verificada
--
-- Decisión de Javier (27-09): «contemos registro como alguien verificado, y
-- los que no completaron verificación quedarán solo como que solicitaron el
-- OTP». Hasta aquí un registro era un perfil real con el teléfono confirmado
-- (`public.helios_signups`, 20260920100000), contado por el día operativo en
-- que se creó el perfil.
--
-- Desde esta migración hay dos poblaciones y cada una vive en un solo sitio:
--
--   metricas.solicitudes  Toda persona real (perfil que no es de prueba) que
--                         pidió el código por SMS, se verificara o no. Es la
--                         boca del embudo. Una fila por persona, con la etapa
--                         más lejana a la que llegó.
--   metricas.personas     SOLO los registros: las solicitudes con la
--                         verificación de identidad APROBADA. Su día de
--                         registro es el día operativo en que se aprobó esa
--                         verificación.
--
-- Quien pidió el código y no llegó a verificarse no es un registro: cuenta en
-- «Solicitaron el código» y en «Confirmaron el teléfono», nunca en
-- «Registros». Como todo registro está verificado, «Verificados» y
-- «Registros» son la misma cifra: las claves `verificado`, `verificado_dia` y
-- `verified` se quedan por quien ya las lee, y valen lo mismo que el registro.
--
-- Cuándo se aprobó una verificación: la primera vez que el expediente entró
-- en `approved` según `kyc.decision_log`; si el log no lo tiene,
-- `reviewed_at`; si tampoco, `created_at`. La fórmula anterior
-- (`coalesce(reviewed_at, created_at)`) fechaba las aprobaciones automáticas
-- de Didit (149 de 162 en producción, sin `reviewed_at`) por el día en que se
-- ABRIÓ el expediente. El 27-09 las dos dan el mismo día en todos los casos,
-- en dev y en prod; el log es el instante real.
--
-- `metricas.personas` se redefine con `create or replace view` y las mismas
-- columnas, en el mismo orden y con los mismos tipos: nada que dependa de ella
-- se rompe y no hace falta `drop … cascade`. Lo nuevo va en
-- `metricas.solicitudes`, no en columnas añadidas a `personas` (así la
-- migración 20260927500000 se puede volver a aplicar encima).
--
-- `public.helios_signups` (la usan `admin_weekly_summary` y
-- `admin_daily_series`, que lee Inicio) pasa a ser los registros de
-- `metricas.solicitudes`, con sus columnas de siempre: el «new_users» del resumen
-- semanal y de la serie diaria cuenta registros verificados sin tocar esas
-- funciones.
--
-- Idempotente. Solo vistas, una función y comentarios.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Las solicitudes: quien pidió el código
-- ---------------------------------------------------------------------------
-- Un perfil nace cuando se PIDE el código por SMS (el alta de `auth.users`
-- crea el perfil), así que el día en que se pidió es el de
-- `profiles.created_at`. La etapa es la más lejana a la que llegó:
--   'verificado'            verificación de identidad aprobada: ES un registro;
--   'confirmo_el_telefono'  metió el código y no tiene la verificación aprobada;
--   'solicito_el_codigo'    pidió el código y nunca lo metió.
-- Cada persona está en una sola etapa, así que las tres suman las solicitudes.
-- «Confirmaron el teléfono» es `etapa <> 'solicito_el_codigo'`: quien está
-- verificado pasó por ahí aunque el dato falte (hoy no hay ningún caso), y
-- así el embudo siempre está anidado.

create or replace view metricas.solicitudes as
select
  p.id                                                   as user_id,
  p.created_at                                           as solicito_en,
  metricas.dia_operativo(p.created_at)                   as solicito_dia,
  metricas.lunes(metricas.dia_operativo(p.created_at))   as solicito_semana,
  (u.phone_confirmed_at is not null)                     as telefono_confirmado,
  (ap.en is not null)                                    as verificado,
  ap.en                                                  as verificado_en,
  metricas.dia_operativo(ap.en)                          as verificado_dia,
  metricas.lunes(metricas.dia_operativo(ap.en))          as verificado_semana,
  case
    when ap.en is not null                 then 'verificado'
    when u.phone_confirmed_at is not null  then 'confirmo_el_telefono'
    else                                        'solicito_el_codigo'
  end                                                    as etapa,
  p.status::text                                         as estado,
  p.level                                                as nivel
from public.profiles p
join auth.users u on u.id = p.id
left join (
  -- La primera aprobación de cada persona, entre sus expedientes aprobados.
  select v.user_id,
         min(coalesce(l.aprobada_en, v.reviewed_at, v.created_at)) as en
  from kyc.verifications v
  left join (
    select d.verification_id, min(d.created_at) as aprobada_en
    from kyc.decision_log d
    where d.to_status = 'approved'
    group by d.verification_id
  ) l on l.verification_id = v.id
  where v.status = 'approved'
  group by v.user_id
) ap on ap.user_id = p.id
where not p.is_test;

comment on view metricas.solicitudes is
  'Una fila por persona real (perfil que no es de prueba) que pidió el código por SMS, se verificara o no: la boca del embudo. «Solicitaron el código» = count(*); «Confirmaron el teléfono» = etapa <> ''solicito_el_codigo''; «Registros» = etapa = ''verificado'' (son las filas de metricas.personas). Las tres etapas suman las solicitudes.';
comment on column metricas.solicitudes.user_id is 'La persona (profiles.id).';
comment on column metricas.solicitudes.solicito_en is 'Cuándo pidió el código: profiles.created_at (el perfil nace al pedirlo).';
comment on column metricas.solicitudes.solicito_dia is 'Día operativo en que pidió el código.';
comment on column metricas.solicitudes.solicito_semana is 'Lunes de la semana de solicito_dia.';
comment on column metricas.solicitudes.telefono_confirmado is 'Metió el código: auth.users.phone_confirmed_at no es nulo. Es el dato crudo; para contar «Confirmaron el teléfono» se usa la etapa.';
comment on column metricas.solicitudes.verificado is 'Tiene una verificación de identidad aprobada: es un registro.';
comment on column metricas.solicitudes.verificado_en is 'Instante de su primera aprobación: la primera entrada en approved de kyc.decision_log; si falta, reviewed_at; si falta, created_at del expediente.';
comment on column metricas.solicitudes.verificado_dia is 'Día operativo de verificado_en: su día de registro.';
comment on column metricas.solicitudes.verificado_semana is 'Lunes de la semana de verificado_dia: su semana de registro.';
comment on column metricas.solicitudes.etapa is 'La etapa más lejana a la que llegó: verificado (es un registro), confirmo_el_telefono (metió el código y no está verificado) o solicito_el_codigo (nunca metió el código).';
comment on column metricas.solicitudes.estado is 'profiles.status de hoy.';
comment on column metricas.solicitudes.nivel is 'profiles.level de hoy.';

-- ---------------------------------------------------------------------------
-- 2. Las personas: solo los registros
-- ---------------------------------------------------------------------------
-- Mismas columnas, mismo orden y mismos tipos que en 20260927500000. Lo que
-- cambia es quién entra (los verificados) y el día de registro (el de la
-- aprobación). `verificado` vale siempre verdadero y `verificado_dia` es el
-- mismo que `registro_dia`.

create or replace view metricas.personas as
select
  s.user_id                                         as user_id,
  s.verificado_dia                                  as registro_dia,
  s.verificado_semana                               as registro_semana,
  s.verificado                                      as verificado,
  s.estado                                          as estado,
  s.nivel                                           as nivel,
  k.primer_dia                                      as primer_consumo_dia,
  k.primer_merchant_id                              as primer_merchant_id,
  s.verificado_dia                                  as verificado_dia,
  metricas.lunes(k.primer_dia)                      as primer_consumo_semana,
  k.ultimo_dia                                      as ultimo_consumo_dia,
  coalesce(k.consumos, 0)::integer                  as consumos,
  coalesce(k.noches, 0)::integer                    as noches,
  coalesce(k.financed, 0)::numeric                  as financed_usd
from metricas.solicitudes s
left join (
  select q.user_id,
         min(q.business_date)                   as primer_dia,
         max(q.business_date)                   as ultimo_dia,
         count(distinct q.charge_id)            as consumos,
         count(distinct q.business_date)        as noches,
         sum(q.financed_usd)                    as financed,
         (array_agg(q.merchant_id order by q.business_date, c.confirmed_at, q.charge_id))[1]
                                                as primer_merchant_id
  from metricas.cuotas q
  join public.charges c on c.id = q.charge_id
  group by q.user_id
) k on k.user_id = s.user_id
where s.verificado;

comment on view metricas.personas is
  'Una fila por registro: persona real con la verificación de identidad aprobada (metricas.solicitudes con etapa = verificado). Registro = por registro_dia, el día operativo en que se aprobó la verificación. Quien pidió el código y no se verificó no está aquí: está en metricas.solicitudes. Han comprado = primer_consumo_dia no nulo.';
comment on column metricas.personas.user_id is 'La persona (profiles.id).';
comment on column metricas.personas.registro_dia is 'Su día de registro: el día operativo en que se aprobó su verificación de identidad (metricas.solicitudes.verificado_dia).';
comment on column metricas.personas.registro_semana is 'Lunes de la semana del registro.';
comment on column metricas.personas.verificado is 'Siempre verdadero: todo registro está verificado. Se queda por quien ya la lee.';
comment on column metricas.personas.estado is 'profiles.status de hoy (pending_pin, active, frozen, suspended, expelled; pending_kyc solo si se le pidió verificarse otra vez).';
comment on column metricas.personas.nivel is 'profiles.level de hoy.';
comment on column metricas.personas.primer_consumo_dia is 'Día operativo de su primera cuota (de un consumo propio o de su parte en un grupo). Nulo si nunca consumió.';
comment on column metricas.personas.primer_merchant_id is 'Local de ese primer consumo.';
comment on column metricas.personas.verificado_dia is 'El mismo día que registro_dia: el de la aprobación de su verificación.';
comment on column metricas.personas.primer_consumo_semana is 'Lunes de la semana del primer consumo.';
comment on column metricas.personas.ultimo_consumo_dia is 'Día operativo de su último consumo.';
comment on column metricas.personas.consumos is 'En cuántos consumos tiene cuota (los suyos y aquellos de grupo en que pagó su parte).';
comment on column metricas.personas.noches is 'En cuántos días operativos distintos consumió.';
comment on column metricas.personas.financed_usd is 'FINANCED. Todo lo que ha consumido, sin servicio (su parte en los grupos).';

-- ---------------------------------------------------------------------------
-- 3. helios_signups: los registros, con sus columnas de siempre
-- ---------------------------------------------------------------------------
-- La leen `admin_weekly_summary` y `admin_daily_series` (Inicio, el Resumen
-- viejo y la batería de Semana) para su `new_users`. Deja de tener su propia
-- definición: son las solicitudes verificadas, las mismas filas que
-- `metricas.personas`, con `dia` = día de registro. `status` y `level` salen
-- del perfil para conservar sus tipos.
--
-- Lee de `metricas.solicitudes` y no de `metricas.personas` a propósito:
-- 20260927500000 define `personas` sobre `helios_signups`, y si esta leyera
-- `personas`, volver a aplicar aquella migración cerraría un círculo entre
-- las dos vistas.

create or replace view public.helios_signups as
  select s.user_id                  as user_id,
         s.verificado_dia           as dia,
         p.status                   as status,
         p.level                    as level
  from metricas.solicitudes s
  join public.profiles p on p.id = s.user_id
  where s.verificado;

comment on view public.helios_signups is
  'Quien cuenta como registro: los de metricas.personas (persona real con la verificación de identidad aprobada), con dia = el día operativo en que se aprobó. Pedir el código, o meterlo sin verificarse, no es registrarse: eso está en metricas.solicitudes.';

revoke all on public.helios_signups from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. El primer día de Métricas › Gente
-- ---------------------------------------------------------------------------
-- «Desde el inicio» empieza con la primera solicitud del código (o el primer
-- consumo, si llegara antes): con el día de registro, la gente que pidió el
-- código antes de verificarse quedaría fuera de la primera ventana.

create or replace function metricas.gente_primer_dia()
returns date
language sql
stable
as $$
  -- `least` ignora los nulos: sin solicitudes, el primer consumo; sin nada, nulo.
  select least(
    (select min(s.solicito_dia) from metricas.solicitudes s),
    (select min(k.business_date) from metricas.consumos k)
  );
$$;

comment on function metricas.gente_primer_dia() is
  'El primer día operativo con actividad (una solicitud del código o un consumo). Nulo sin datos. Es el «desde el inicio» de Métricas › Gente y el «desde» de Métricas › General.';

-- ---------------------------------------------------------------------------
-- 5. Las RPC que ya cuentan bien sin cambiar su cuerpo
-- ---------------------------------------------------------------------------
-- Leen `metricas.personas` y ahora cuentan registros verificados por el día
-- de su verificación. Solo cambia lo que dicen de sí mismas.

comment on function public.admin_user_cohorts(text, integer, uuid) is
  'Métricas › Gente › Retención: cohortes de la gente que se registró junta (registro = verificación de identidad aprobada, por la semana en que se aprobó) o, con p_merchant_id, que llegó junta a ese local, y cuánta volvió a consumir en cada periodo. Personas desde las cuotas; consumo sin servicio.';

comment on function public.admin_user_behavior(date, date, uuid) is
  'Métricas › Gente › Uso: gasto por persona (mediana y media, sin servicio), tramos, concentración, y los registros (personas verificadas) por nivel y por estado. Personas desde las cuotas. Con p_merchant_id, lo del padrón (personas por nivel, estados) vale null.';

comment on function public.admin_user_persona(text, uuid) is
  'Métricas › Gente › Perfil: la persona típica de una base: consumieron (registros con algún consumo) o registrados (personas verificadas); verificados es la misma base que registrados y se acepta por los enlaces viejos. Con p_merchant_id, la gente que consumió en ese local. Solo agregados con umbral de privacidad; importes en consumo sin servicio, desde las cuotas.';

-- ---------------------------------------------------------------------------
-- 6. Permisos
-- ---------------------------------------------------------------------------
-- El esquema no se expone: ni anon ni authenticated leen estas vistas.

revoke all on metricas.solicitudes from public, anon, authenticated;
revoke all on metricas.personas from public, anon, authenticated;
revoke all on function metricas.gente_primer_dia() from public, anon, authenticated;
