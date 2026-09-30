-- ============================================================================
-- Batería de coherencia de Métricas › Cohortes (dev)
--
-- Una fila por comprobación: comprobacion, esperado, obtenido, ok (el formato
-- de metricas_coherencia.sql). «Esperado» es la definición canónica (esquema
-- metricas, 20260927500000) o la otra pantalla que enseña lo mismo;
-- «obtenido», lo que devuelven admin_metricas_cohortes / admin_metricas_cohorte
-- (20260927530000, y `a_cobrar` desde 20260927610000: lo que hay que cobrar de
-- la semana, la cuota 1 + la 2 con su desglose, K33-K44). Las comprobaciones
-- por semana, cuota, estado o local dan
-- una fila resumen («N filas / M cuadran») y una fila de detalle por cada una
-- que no cuadra; las de una sola cifra enseñan las dos cifras.
--
-- Solo SELECT. Se hace pasar por un admin activo poniendo request.jwt.claims
-- (con aal2). NO cambia el rol: las RPC son security definer y solo miran
-- auth.uid(), y así la misma consulta puede leer metricas.*.
--
--   node <ORQ>/bin/db.cjs dev supabase/tests/metricas_coherencia_cohortes.sql
-- ============================================================================

select set_config('request.jwt.claims',
  json_build_object('sub', (select user_id::text from public.platform_admins where is_active limit 1),
                    'role', 'authenticated', 'aal', 'aal2')::text, true) is not null as suplantando_admin;

with
h as (select metricas.hoy() as hoy, public.helios_on_time_grace_days() as gracia),
mc as (select * from metricas.consumos),
mq as (select * from metricas.cuotas),
estados(estado) as (values ('a_tiempo'), ('tarde'), ('vencida'), ('por_vencer'), ('perdida')),
semanas as (select distinct semana as lunes from mc),
locales as (select distinct merchant_id from mc),
-- Lo que pinta el panel.
r_lista as materialized (
  select (x->>'semana')::date as lunes, x
  from jsonb_array_elements(public.admin_metricas_cohortes() -> 'cohortes') x
),
r_det as materialized (
  select l.lunes, public.admin_metricas_cohorte(l.lunes) as j
  from r_lista l
),
r_cuota as (
  select l.lunes, (c->>'sequence')::int as n, c
  from r_lista l, jsonb_array_elements(l.x -> 'cuotas') c
),
r_por_local as (
  select d.lunes, (p->>'merchant_id')::uuid as merchant_id, p
  from r_det d, jsonb_array_elements(d.j -> 'por_local') p
),
-- Lo que hay que cobrar de cada semana: la cuota 1 + la 2.
r_total as (
  select l.lunes, l.x -> 'a_cobrar' as a
  from r_lista l
),

r_lista_local as materialized (
  select k.merchant_id, (x->>'semana')::date as lunes, x
  from locales k, jsonb_array_elements(public.admin_metricas_cohortes(k.merchant_id) -> 'cohortes') x
),
r_det_local as materialized (
  select l.merchant_id, l.lunes, public.admin_metricas_cohorte(l.lunes, l.merchant_id) as j
  from r_lista_local l
),
r_curva as (
  select d.lunes, (c->>'sequence')::int as n, (p->>'dia')::int as dia,
         (p->>'esta_pct')::numeric as esta_pct, (p->>'media_pct')::numeric as media_pct,
         (p->>'semanas_en_media')::int as semanas_en_media
  from r_det d, jsonb_array_elements(d.j -> 'curvas') c, jsonb_array_elements(c -> 'dias') p
),
mcv as (select * from metricas.cohorte_curva()),
-- La otra pantalla que enseña lo mismo.
r_week as (
  select (x->>'week_start')::date as lunes, x
  from jsonb_array_elements(public.admin_weekly_summary(52) -> 'rows') x
),
r_over as (select public.admin_overview(30) as j),
cart as (select * from metricas.cartera_al((select hoy from h))),

-- Cada comprobación: orden, nombre, entidad, esperado, obtenido y tolerancia
-- (0 = igualdad exacta, para recuentos y fechas pasadas a número).
chk(orden, comprobacion, entidad, e, o, tol) as (
  select '01', 'K1 Cohorte: consumo = Σ metricas.consumos.financed_usd', s.lunes::text,
         (select coalesce(sum(k.financed_usd), 0) from mc k where k.semana = s.lunes),
         (select (l.x->>'financed_usd')::numeric from r_lista l where l.lunes = s.lunes), 0.01
  from semanas s
  union all
  select '02', 'K2 Cohorte: consumos = count(metricas.consumos)', s.lunes::text,
         (select count(*) from mc k where k.semana = s.lunes),
         (select (l.x->>'consumos')::numeric from r_lista l where l.lunes = s.lunes), 0
  from semanas s
  union all
  select '03', 'K3 Cohorte: personas con cuotas = count(distinct metricas.cuotas.user_id)', s.lunes::text,
         (select count(distinct q.user_id) from mq q where q.semana = s.lunes),
         (select (l.x->>'personas')::numeric from r_lista l where l.lunes = s.lunes), 0
  from semanas s
  union all
  select '04', 'K4 Cohorte: consumo de la cuota 1 + consumo de la cuota 2 = consumo', l.lunes::text,
         (l.x->>'financed_usd')::numeric,
         (select coalesce(sum((c->>'financed_usd')::numeric), 0) from jsonb_array_elements(l.x -> 'cuotas') c), 0.01
  from r_lista l
  union all
  select '05', 'K5 Cohorte: volvió del consumo = Σ financed de las cuotas pagadas (metricas.cuotas)', s.lunes::text,
         (select coalesce(sum(q.financed_usd), 0) from mq q where q.semana = s.lunes and q.estado_hoy in ('a_tiempo', 'tarde')),
         (select (l.x->>'volvio_financed_usd')::numeric from r_lista l where l.lunes = s.lunes), 0.01
  from semanas s
  union all
  select '06', 'K6 Cohorte: volvió + vencido + por vencer + perdido = consumo', l.lunes::text,
         (l.x->>'financed_usd')::numeric,
         (l.x->>'volvio_financed_usd')::numeric + (l.x->>'vencido_financed_usd')::numeric
           + (l.x->>'por_vencer_financed_usd')::numeric + (l.x->>'perdido_financed_usd')::numeric, 0.01
  from r_lista l
  union all
  select '07', 'K7 Cuota: lo que se cobra = Σ metricas.cuotas.payable_usd', s.lunes::text || ' cuota ' || n.n,
         (select coalesce(sum(q.payable_usd), 0) from mq q where q.semana = s.lunes and q.sequence = n.n),
         (select (r.c->>'payable_usd')::numeric from r_cuota r where r.lunes = s.lunes and r.n = n.n), 0.01
  from semanas s cross join (values (1), (2)) n(n)
  union all
  select '08', 'K8 Cuota: service fee (IVA incluido) = lo que se cobra − consumo', r.lunes::text || ' cuota ' || r.n,
         (r.c->>'payable_usd')::numeric - (r.c->>'financed_usd')::numeric,
         (r.c->>'fee_usd')::numeric, 0.01
  from r_cuota r
  union all
  select '09', 'K9 Cuota: Σ de sus cinco estados = lo que se cobra', r.lunes::text || ' cuota ' || r.n,
         (r.c->>'payable_usd')::numeric,
         (select sum((v.value->>'payable_usd')::numeric) from jsonb_each(r.c -> 'estados') v), 0.01
  from r_cuota r
  union all
  select '10', 'K10 Cuota × estado: lo que se cobra = Σ metricas.cuotas (estado_hoy)',
         s.lunes::text || ' cuota ' || n.n || ' ' || e.estado,
         (select coalesce(sum(q.payable_usd), 0) from mq q
           where q.semana = s.lunes and q.sequence = n.n and q.estado_hoy = e.estado),
         (select (r.c->'estados'->e.estado->>'payable_usd')::numeric from r_cuota r where r.lunes = s.lunes and r.n = n.n), 0.01
  from semanas s cross join (values (1), (2)) n(n) cross join estados e
  union all
  select '11', 'K11 Cuota × estado: personas = count(distinct user_id) de metricas.cuotas',
         s.lunes::text || ' cuota ' || n.n || ' ' || e.estado,
         (select count(distinct q.user_id) from mq q
           where q.semana = s.lunes and q.sequence = n.n and q.estado_hoy = e.estado),
         (select (r.c->'estados'->e.estado->>'personas')::numeric from r_cuota r where r.lunes = s.lunes and r.n = n.n), 0
  from semanas s cross join (values (1), (2)) n(n) cross join estados e
  union all
  select '12', 'K12 Cartera: Σ vencido de todas las cuotas = metricas.cartera_al(hoy)', 'vencido',
         (select vencido_payable_usd from cart),
         (select coalesce(sum((r.c->'estados'->'vencida'->>'payable_usd')::numeric), 0) from r_cuota r), 0.01
  union all
  select '13', 'K13 Cartera: Σ por vencer de todas las cuotas = metricas.cartera_al(hoy)', 'por vencer',
         (select por_vencer_payable_usd from cart),
         (select coalesce(sum((r.c->'estados'->'por_vencer'->>'payable_usd')::numeric), 0) from r_cuota r), 0.01
  union all
  select '14', 'K14 Cartera: Σ perdido de todas las cuotas = metricas.cartera_al(hoy)', 'perdido',
         (select perdido_payable_usd from cart),
         (select coalesce(sum((r.c->'estados'->'perdida'->>'payable_usd')::numeric), 0) from r_cuota r), 0.01
  union all
  select '15', 'K15 Resumen/Cobranza: vencido de admin_overview = Σ vencido de las cohortes', 'arrears.overdue_usd',
         (select (j->'arrears'->>'overdue_usd')::numeric from r_over),
         (select coalesce(sum((r.c->'estados'->'vencida'->>'payable_usd')::numeric), 0) from r_cuota r), 0.01
  union all
  select '16', 'K16 Semana: consumo = admin_weekly_summary.financed_usd', w.lunes::text,
         (w.x->>'financed_usd')::numeric,
         coalesce((select (l.x->>'financed_usd')::numeric from r_lista l where l.lunes = w.lunes), 0), 0.01
  from r_week w
  union all
  select '17', 'K17 Semana: consumos = admin_weekly_summary.charge_count', w.lunes::text,
         (w.x->>'charge_count')::numeric,
         coalesce((select (l.x->>'consumos')::numeric from r_lista l where l.lunes = w.lunes), 0), 0
  from r_week w
  union all
  select '18', 'K18 Semana: personas = admin_weekly_summary.active_users', w.lunes::text,
         (w.x->>'active_users')::numeric,
         coalesce((select (l.x->>'personas')::numeric from r_lista l where l.lunes = w.lunes), 0), 0
  from r_week w
  union all
  select '19', 'K19 La lista y el detalle dicen lo mismo de cada semana', d.lunes::text,
         1, case when (select l.x from r_lista l where l.lunes = d.lunes) = d.j -> 'cohorte' then 1 else 0 end, 0
  from r_det d
  union all
  select '20', 'K20 Por local: Σ consumo de los locales = consumo', d.lunes::text,
         (select (l.x->>'financed_usd')::numeric from r_lista l where l.lunes = d.lunes),
         (select coalesce(sum((p.p->>'financed_usd')::numeric), 0) from r_por_local p where p.lunes = d.lunes), 0.01
  from r_det d
  union all
  select '21', 'K21 Por local: Σ consumos de los locales = consumos', d.lunes::text,
         (select (l.x->>'consumos')::numeric from r_lista l where l.lunes = d.lunes),
         (select coalesce(sum((p.p->>'consumos')::numeric), 0) from r_por_local p where p.lunes = d.lunes), 0
  from r_det d
  union all
  select '22', 'K22 Por local: Σ de los locales por cuota y estado = el total',
         r.lunes::text || ' cuota ' || r.n || ' ' || e.estado,
         (r.c->'estados'->e.estado->>'payable_usd')::numeric,
         (select coalesce(sum((cl.value->'estados'->e.estado->>'payable_usd')::numeric), 0)
            from r_por_local p, jsonb_array_elements(p.p -> 'cuotas') cl
           where p.lunes = r.lunes and (cl.value->>'sequence')::int = r.n), 0.01
  from r_cuota r cross join estados e
  union all
  select '23', 'K23 Local elegido = su fila en «Por local» (lista filtrada frente a detalle partido)',
         l.lunes::text || ' ' || coalesce((select m.name from public.merchants m where m.id = l.merchant_id), l.merchant_id::text),
         1,
         case when l.x = (select (p.p - 'merchant_id' - 'nombre') from r_por_local p
                           where p.lunes = l.lunes and p.merchant_id = l.merchant_id)
              then 1 else 0 end, 0
  from r_lista_local l
  union all
  select '24', 'K24 Local elegido: la lista y el detalle dicen lo mismo',
         d.lunes::text || ' ' || coalesce((select m.name from public.merchants m where m.id = d.merchant_id), d.merchant_id::text),
         1,
         case when (select l.x from r_lista_local l where l.lunes = d.lunes and l.merchant_id = d.merchant_id)
                   = d.j -> 'cohorte' then 1 else 0 end, 0
  from r_det_local d
  union all
  select '25', 'K25 Curva: el día de la gracia es lo cobrado a tiempo (metricas.cuotas)',
         s.lunes::text || ' cuota ' || n.n,
         (select coalesce(sum(q.payable_usd), 0) from mq q
           where q.semana = s.lunes and q.sequence = n.n and q.estado_hoy = 'a_tiempo'),
         (select v.cobrado_payable_usd from mcv v, h
           where v.semana = s.lunes and v.sequence = n.n and v.dia = h.gracia), 0.01
  from semanas s cross join (values (1), (2)) n(n)
  where exists (select 1 from mq q where q.semana = s.lunes and q.sequence = n.n)
  union all
  select '26', 'K26 Curva: nunca pasa de lo cobrado (a tiempo + tarde)', s.lunes::text || ' cuota ' || n.n,
         0,
         (select count(*) from mcv v
           where v.semana = s.lunes and v.sequence = n.n
             and v.cobrado_payable_usd > (select coalesce(sum(q.payable_usd), 0) from mq q
                                           where q.semana = s.lunes and q.sequence = n.n
                                             and q.estado_hoy in ('a_tiempo', 'tarde')) + 0.001), 0
  from semanas s cross join (values (1), (2)) n(n)
  union all
  select '27', 'K27 Curva: nunca baja de un día al siguiente (días que bajan)', s.lunes::text || ' cuota ' || n.n,
         0,
         (select count(*) from (
            select v.cobrado_payable_usd - lag(v.cobrado_payable_usd) over (order by v.dia) as paso
            from mcv v where v.semana = s.lunes and v.sequence = n.n) z
          where z.paso < 0), 0
  from semanas s cross join (values (1), (2)) n(n)
  union all
  select '28', 'K28 Curva de la semana en el panel = metricas.cohorte_curva (días cerrados)',
         c.lunes::text || ' cuota ' || c.n || ' día ' || c.dia,
         (select v.cobrado_pct from mcv v
           where v.semana = c.lunes and v.sequence = c.n and v.dia = c.dia and v.cerrado),
         c.esta_pct, 0.005
  from r_curva c
  union all
  select '29', 'K29 Media de la curva = media simple de las semanas anteriores (solo si todas cerraron el día)',
         c.lunes::text || ' cuota ' || c.n || ' día ' || c.dia,
         (select case when count(*) filter (where v.cerrado) = count(*) and count(*) > 0
                      then round(avg(v.cobrado_pct), 2) end
            from mcv v
           where v.semana between c.lunes - 28 and c.lunes - 7
             and v.sequence = c.n and v.dia = c.dia),
         c.media_pct, 0.005
  from r_curva c
  union all
  select '30', 'K30 Media de la curva: nunca más de cuatro semanas', c.lunes::text || ' cuota ' || c.n || ' día ' || c.dia,
         least(c.semanas_en_media, 4), c.semanas_en_media, 0
  from r_curva c
  union all
  select '30b', 'K30b Curva en el panel: ni esta semana ni la media bajan de un día al siguiente',
         z.lunes::text || ' cuota ' || z.n, 0,
         count(*) filter (where z.baja_esta < 0 or z.baja_media < 0), 0
  from (
    select c.lunes, c.n,
           c.esta_pct - lag(c.esta_pct) over (partition by c.lunes, c.n order by c.dia) as baja_esta,
           c.media_pct - lag(c.media_pct) over (partition by c.lunes, c.n order by c.dia) as baja_media
    from r_curva c
  ) z
  group by z.lunes, z.n
  union all
  select '31', 'K31 Solo la semana de hoy va «en curso»', l.lunes::text,
         case when l.lunes = metricas.lunes((select hoy from h)) then 1 else 0 end,
         case when (l.x->>'en_curso')::boolean then 1 else 0 end, 0
  from r_lista l
  union all
  select '32', 'K32 Todas las semanas con consumo están en la lista', 'semanas',
         (select count(*) from semanas), (select count(*) from r_lista), 0
  -- ── Lo que hay que cobrar de la semana (a_cobrar, 20260927610000) ─────────
  union all
  select '33', 'K33 A cobrar = cuota 1 + cuota 2 (payable, consumo y fee: Σ de diferencias)', l.lunes::text,
         0,
         (select abs((l.x->'a_cobrar'->>'payable_usd')::numeric  - coalesce(sum((c->>'payable_usd')::numeric), 0))
               + abs((l.x->'a_cobrar'->>'financed_usd')::numeric - coalesce(sum((c->>'financed_usd')::numeric), 0))
               + abs((l.x->'a_cobrar'->>'fee_usd')::numeric      - coalesce(sum((c->>'fee_usd')::numeric), 0))
            from jsonb_array_elements(l.x -> 'cuotas') c), 0.03
  from r_lista l
  union all
  select '34', 'K34 A cobrar = Σ metricas.cuotas.payable_usd de la semana', s.lunes::text,
         (select coalesce(sum(q.payable_usd), 0) from mq q where q.semana = s.lunes),
         (select (t.a->>'payable_usd')::numeric from r_total t where t.lunes = s.lunes), 0.01
  from semanas s
  union all
  select '35', 'K35 A cobrar: su consumo (sin fee) = el consumo de la semana', t.lunes::text,
         (select (l.x->>'financed_usd')::numeric from r_lista l where l.lunes = t.lunes),
         (t.a->>'financed_usd')::numeric, 0.01
  from r_total t
  union all
  select '36', 'K36 A cobrar: service fee = payable − consumo', t.lunes::text,
         (t.a->>'payable_usd')::numeric - (t.a->>'financed_usd')::numeric,
         (t.a->>'fee_usd')::numeric, 0.01
  from r_total t
  union all
  select '37', 'K37 A cobrar × estado = Σ metricas.cuotas (estado_hoy), las dos cuotas', s.lunes::text || ' ' || e.estado,
         (select coalesce(sum(q.payable_usd), 0) from mq q where q.semana = s.lunes and q.estado_hoy = e.estado),
         (select (t.a->'estados'->e.estado->>'payable_usd')::numeric from r_total t where t.lunes = s.lunes), 0.01
  from semanas s cross join estados e
  union all
  select '38', 'K38 A cobrar × estado: personas distintas de metricas.cuotas (sin partir por cuota)', s.lunes::text || ' ' || e.estado,
         (select count(distinct q.user_id) from mq q where q.semana = s.lunes and q.estado_hoy = e.estado),
         (select (t.a->'estados'->e.estado->>'personas')::numeric from r_total t where t.lunes = s.lunes), 0
  from semanas s cross join estados e
  union all
  select '39', 'K39 A cobrar × estado = cuota 1 + cuota 2 del mismo estado (payable, consumo y fee)', r.lunes::text || ' ' || e.estado,
         0,
         (select abs((r.a->'estados'->e.estado->>'payable_usd')::numeric  - coalesce(sum((c->'estados'->e.estado->>'payable_usd')::numeric), 0))
               + abs((r.a->'estados'->e.estado->>'financed_usd')::numeric - coalesce(sum((c->'estados'->e.estado->>'financed_usd')::numeric), 0))
               + abs((r.a->'estados'->e.estado->>'fee_usd')::numeric      - coalesce(sum((c->'estados'->e.estado->>'fee_usd')::numeric), 0))
            from r_lista l, jsonb_array_elements(l.x -> 'cuotas') c where l.lunes = r.lunes), 0.03
  from r_total r cross join estados e
  union all
  select '40', 'K40 Cobrado = a tiempo + tarde y falta = vencido + por vencer (payable, consumo y fee)', t.lunes::text,
         0,
         (select sum(abs((t.a->'cobrado'->>k)::numeric
                         - (t.a->'estados'->'a_tiempo'->>k)::numeric - (t.a->'estados'->'tarde'->>k)::numeric)
                   + abs((t.a->'falta'->>k)::numeric
                         - (t.a->'estados'->'vencida'->>k)::numeric - (t.a->'estados'->'por_vencer'->>k)::numeric))
            from unnest(array['payable_usd', 'financed_usd', 'fee_usd']) k), 0.03
  from r_total t
  union all
  select '41', 'K41 Cobrado: su consumo = «volvió del consumo»', l.lunes::text,
         (l.x->>'volvio_financed_usd')::numeric,
         (l.x->'a_cobrar'->'cobrado'->>'financed_usd')::numeric, 0.01
  from r_lista l
  union all
  select '42', 'K42 Cobrado + falta + perdido = a cobrar', t.lunes::text,
         (t.a->>'payable_usd')::numeric,
         (t.a->'cobrado'->>'payable_usd')::numeric + (t.a->'falta'->>'payable_usd')::numeric
           + (t.a->'estados'->'perdida'->>'payable_usd')::numeric, 0.01
  from r_total t
  union all
  select '43', 'K43 % cobrado y % que falta = cobrado y falta ÷ a cobrar', t.lunes::text,
         round(100 * (t.a->'cobrado'->>'payable_usd')::numeric / nullif((t.a->>'payable_usd')::numeric, 0), 2)
           + round(100 * (t.a->'falta'->>'payable_usd')::numeric / nullif((t.a->>'payable_usd')::numeric, 0), 2),
         (t.a->>'cobrado_pct')::numeric + (t.a->>'falta_pct')::numeric, 0.005
  from r_total t
  union all
  select '44', 'K44 Personas que pagaron algo = personas distintas de metricas.cuotas (a tiempo o tarde)', s.lunes::text,
         (select count(distinct q.user_id) from mq q
           where q.semana = s.lunes and q.estado_hoy in ('a_tiempo', 'tarde')),
         (select (t.a->'cobrado'->>'personas')::numeric from r_total t where t.lunes = s.lunes), 0
  from semanas s
  union all
  select '44b', 'K44b Personas que deben algo = personas distintas de metricas.cuotas (vencida o por vencer)', s.lunes::text,
         (select count(distinct q.user_id) from mq q
           where q.semana = s.lunes and q.estado_hoy in ('vencida', 'por_vencer')),
         (select (t.a->'falta'->>'personas')::numeric from r_total t where t.lunes = s.lunes), 0
  from semanas s
  union all
  select '45', 'K45 Por local: Σ de los locales = a cobrar, en total y por estado', t.lunes::text || ' ' || coalesce(e.estado, 'total'),
         coalesce((t.a->'estados'->e.estado->>'payable_usd')::numeric, (t.a->>'payable_usd')::numeric),
         (select coalesce(sum(coalesce((p.p->'a_cobrar'->'estados'->e.estado->>'payable_usd')::numeric,
                                       (p.p->'a_cobrar'->>'payable_usd')::numeric)), 0)
            from r_por_local p where p.lunes = t.lunes), 0.01
  from r_total t cross join (select estado from estados union all select null) e
),
evaluado as (
  select c.*,
         case when c.tol = 0 then c.e is not distinct from c.o
              else coalesce(abs(c.e - c.o) < c.tol, c.e is null and c.o is null) end as cuadra
  from chk c
),
r as (
  select x.orden,
         x.comprobacion,
         case when count(*) = 1 then coalesce(round(max(x.e), 2)::text, 'nulo')
              else count(*)::text || ' filas' end as esperado,
         case when count(*) = 1 then coalesce(round(max(x.o), 2)::text, 'nulo')
              else (count(*) filter (where x.cuadra))::text || ' cuadran' end as obtenido,
         coalesce(bool_and(x.cuadra), true) as ok
  from evaluado x
  group by x.orden, x.comprobacion
  union all
  select x.orden || '.' || x.entidad,
         '   ' || split_part(x.comprobacion, ' ', 1) || ' ' || x.entidad,
         coalesce(round(x.e, 2)::text, 'nulo'),
         coalesce(round(x.o, 2)::text, 'nulo'),
         false
  from evaluado x
  where not x.cuadra
    and (select count(*) from evaluado y where y.orden = x.orden) > 1
)
select comprobacion, esperado, obtenido, ok
from r
order by orden;
