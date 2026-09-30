-- ============================================================================
-- Ronda — La ruta de QA del piloto, dentro del panel
--
-- ⚠️ TEMPORAL. Es la hoja de ruta de las pruebas del piloto: once fases y
-- ~130 casos, cada uno con un resultado (pasa / falla / bloqueo) y una nota.
-- Vivía en un artefacto compartido por enlace, y ahí tenía dos problemas: las
-- marcas se guardaban fuera del producto, y para verlas había que tener el
-- enlace. Al mudarla al panel, lo que el equipo marca queda donde está todo
-- lo demás — con la misma sesión, la misma base y la misma copia de
-- seguridad.
--
-- ---------------------------------------------------------------------------
-- Qué se guarda aquí y qué no
-- ---------------------------------------------------------------------------
-- Aquí solo vive el RESULTADO. El texto de las fases y de los casos es
-- contenido del panel (`Ronda-panel/src/features/admin/qa.ts`), no datos: se
-- escribe contra el código, se revisa en un diff y viaja con el despliegue.
-- La unión entre los dos es `case_id` —"c3-07", fase 3, caso 7— y por eso ese
-- identificador no se puede reordenar a la ligera: renumerar un caso mueve la
-- nota de alguien a otro sitio.
--
-- Una fila por caso, con la última marca. No hay historial: la pregunta que
-- contesta esta pantalla es "¿dónde vamos?", no "¿quién lo marcó en marzo?".
-- Lo que sí queda es quién puso la última marca y cuándo, que es lo que hace
-- falta para ir a preguntarle.
--
-- Un caso sin probar NO tiene fila. Se borra la fila cuando se quita la marca
-- y la nota queda vacía, así que la tabla pesa lo que se ha probado.
--
-- ---------------------------------------------------------------------------
-- Quién escribe
-- ---------------------------------------------------------------------------
-- Personal de Ronda, los dos roles. Un operador prueba tanto como un super
-- admin, y una ruta de QA en la que solo puede marcar una persona es una
-- ruta que se marca por WhatsApp. No pasa por RPC porque no hay nada que
-- decidir en el servidor: son cuatro campos y la RLS ya dice quién entra.
--
-- Cómo se quita el día que sobre: `drop table public.qa_case_marks` y fuera
-- la pantalla del panel. Nada más depende de esto.
-- ============================================================================

create table if not exists public.qa_case_marks (
  -- "c0-01" … "c10-10": fase y número de caso, como los pinta la ruta.
  case_id    text primary key check (case_id ~ '^c[0-9]{1,2}-[0-9]{2}$'),
  -- Nulo = hay nota pero todavía no hay veredicto. Es un estado real: se
  -- apunta lo que se vio antes de decidir si eso es un fallo.
  status     text check (status in ('pass', 'fail', 'blocked')),
  note       text not null default '',
  -- Quién puso la última marca. `actor` es la cuenta; `actor_name` es cómo
  -- se llamó a sí misma esa persona en la pantalla, porque en el piloto hay
  -- teléfonos y tablets que varios se pasan con la misma sesión abierta.
  actor      uuid references auth.users (id),
  actor_name text,
  updated_at timestamptz not null default now()
);

comment on table public.qa_case_marks is
  'TEMPORAL (piloto): el resultado de cada caso de la ruta de QA. El texto de los casos vive en el panel; aqui solo la marca. Ver 20260916220000.';

comment on column public.qa_case_marks.case_id is
  'Identificador del caso en Helios-panel/src/features/admin/qa.ts. Renumerar un caso mueve la marca de sitio.';

-- Para pintar la cabecera de la ruta —cuántos pasan, cuántos fallan— sin leer
-- la tabla entera fila a fila.
create index if not exists qa_case_marks_status_idx
  on public.qa_case_marks (status);

drop trigger if exists qa_case_marks_touch_updated_at on public.qa_case_marks;
create trigger qa_case_marks_touch_updated_at
  before update on public.qa_case_marks
  for each row execute function public.touch_updated_at();

alter table public.qa_case_marks enable row level security;

-- Personal de Ronda activo: lee y escribe. `is_platform_admin()` ya exige el
-- segundo factor cuando está activado (20260911208000), así que no hace falta
-- repetirlo aquí.
drop policy if exists "qa_case_marks_staff_read" on public.qa_case_marks;
create policy "qa_case_marks_staff_read"
  on public.qa_case_marks for select to authenticated
  using (public.is_platform_admin());

drop policy if exists "qa_case_marks_staff_write" on public.qa_case_marks;
create policy "qa_case_marks_staff_write"
  on public.qa_case_marks for insert to authenticated
  with check (public.is_platform_admin());

drop policy if exists "qa_case_marks_staff_update" on public.qa_case_marks;
create policy "qa_case_marks_staff_update"
  on public.qa_case_marks for update to authenticated
  using (public.is_platform_admin())
  with check (public.is_platform_admin());

-- Borrar es quitar una marca, no destruir nada: la fila vuelve a existir en
-- cuanto alguien vuelva a marcar ese caso.
drop policy if exists "qa_case_marks_staff_delete" on public.qa_case_marks;
create policy "qa_case_marks_staff_delete"
  on public.qa_case_marks for delete to authenticated
  using (public.is_platform_admin());

grant select, insert, update, delete on public.qa_case_marks to authenticated;

-- ---------------------------------------------------------------------------
-- Lo que ya se había probado
-- ---------------------------------------------------------------------------
-- Las marcas que el equipo dejó en el artefacto los días 15 y 16 de
-- septiembre de 2026, con su texto y su hora tal cual. Sin actor: el
-- artefacto no pedía sesión y nadie escribió su nombre.
--
-- `on conflict do nothing`: si la migración se vuelve a correr sobre una base
-- donde ya se está trabajando, no pisa lo que haya.

insert into public.qa_case_marks (case_id, status, note, updated_at) values
  ('c0-05', null,   'Listo',                                                        '2026-09-16T19:52:25.775Z'),
  ('c0-06', null,   'Listo',                                                        '2026-09-16T19:52:26.537Z'),
  ('c1-01', 'pass', 'Todo correcto en android',                                     '2026-09-16T20:07:17.548Z'),
  ('c1-02', 'pass', 'El flujo de registro se salta por completo la validacion KYC', '2026-09-16T21:41:04.189Z'),
  ('c1-03', 'pass', 'todo correcto en android',                                     '2026-09-16T20:12:42.510Z'),
  ('c1-04', 'pass', 'todo correcto en android',                                     '2026-09-16T21:27:35.842Z'),
  ('c1-05', 'pass', 'todo correcto en android',                                     '2026-09-16T21:27:48.070Z'),
  ('c1-06', 'pass', 'todo correcto en android',                                     '2026-09-16T22:00:52.744Z'),
  ('c1-07', 'pass', 'todo correcto en android',                                     '2026-09-16T22:00:57.806Z'),
  ('c1-11', 'pass', 'todo correcto en android',                                     '2026-09-16T22:02:31.961Z'),
  ('c1-12', 'pass', 'todo correcto en android',                                     '2026-09-16T22:02:38.595Z')
on conflict (case_id) do nothing;
