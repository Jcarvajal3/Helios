-- ============================================================================
-- Prueba de humo de `admin_metricas_general` (Métricas › General)
--
-- Se hace pasar por un admin activo y cambia el rol a `authenticated`, como
-- llega el panel, dentro de begin/rollback. Comprueba que la RPC contesta con
-- todas sus claves, que un usuario que no es del equipo recibe 42501, que con
-- un local lo que no se parte vale null, y devuelve la respuesta entera de
-- todos los locales y la del local con más consumo para mirarla a ojo.
-- Solo lectura: no escribe nada.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_general.sql
--
-- La coherencia de las cifras con `metricas.*` y con las demás RPC está en
-- metricas_coherencia_general.sql.
-- ============================================================================

begin;

-- @ayudas
-- Helios: la base nace sin equipo; la suite crea su propio admin activo.
select pg_temp.prueba_admin() is not null as admin_de_prueba;

-- El local con más consumo, antes de perder el acceso a `metricas`.
create temp table _local on commit drop as
select k.merchant_id
from metricas.consumos k
group by k.merchant_id
order by sum(k.financed_usd) desc
limit 1;
grant select on _local to authenticated;

-- Alguien que no es del equipo: tiene que rebotar con 42501.
create temp table _rebote (codigo text) on commit drop;
grant select, insert on _rebote to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
begin
  perform public.admin_metricas_general(null);
  insert into _rebote values ('sin error');
exception when others then
  insert into _rebote values (sqlstate);
end;
$$;

-- Ahora, un admin activo (con aal2, por si el segundo factor está exigido).
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

with
t as (select public.admin_metricas_general(null) as j),
l as (select public.admin_metricas_general((select merchant_id from _local)) as j)
select jsonb_build_object(
  'rol',                   current_user,
  'sin_permiso_da_42501',  (select codigo from _rebote) = '42501',
  'claves',                (select array_agg(k order by k) from t, jsonb_object_keys(t.j) k),
  'todas_las_claves',      (select t.j ?& array['hoy', 'desde', 'local', 'gente', 'consumo', 'dinero',
                                                'riesgo', 'por_cada_100', 'curva'] from t),
  'todo_payable_con_desglose', (
    select bool_and(o ? 'financed_usd' and o ? 'fee_usd')
    from t, jsonb_path_query(t.j, 'strict $.**') o
    where jsonb_typeof(o) = 'object' and o ? 'payable_usd'
  ),
  'fee_es_payable_menos_financed', (
    select bool_and(abs((o->>'payable_usd')::numeric - (o->>'financed_usd')::numeric
                        - (o->>'fee_usd')::numeric) < 0.005)
    from t, jsonb_path_query(t.j, 'strict $.**') o
    where jsonb_typeof(o) = 'object' and o ? 'payable_usd'
  ),
  'con_local_no_se_parte', (
    select (l.j->'gente'->'registros') = 'null'::jsonb
       and (l.j->'gente'->'verificados') = 'null'::jsonb
       and (l.j->'gente'->'solicitaron') = 'null'::jsonb
       and (l.j->'gente'->'telefono_confirmado') = 'null'::jsonb
       and (l.j->'gente'->'han_comprado_pct') = 'null'::jsonb
       and (l.j->'consumo'->'locales') = 'null'::jsonb
       and (l.j->'dinero'->'caja_usd') = 'null'::jsonb
       and coalesce(bool_and((s->'registros') = 'null'::jsonb), true)
    from l left join lateral jsonb_array_elements(l.j->'curva') s on true
    group by l.j
  ),
  'sin_local_si_hay', (
    select jsonb_typeof(t.j->'gente'->'registros') = 'number'
       and jsonb_typeof(t.j->'gente'->'solicitaron') = 'number'
       and jsonb_typeof(t.j->'gente'->'telefono_confirmado') = 'number'
       and jsonb_typeof(t.j->'dinero'->'caja_usd') = 'number'
    from t
  ),
  'todos',    (select j from t),
  'un_local', (select j from l)
) as resultado;

rollback;
