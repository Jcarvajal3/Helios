-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El directorio tiene la categoría «Vacunación»
--
-- Javier (2026-10-28): el Dr. Francisco Alejandro Risquez Parra (pediatría y
-- vacunación) estaba en «Enfermería» —se la puso a su tarjeta alguien del
-- equipo, porque no había otra— y debe salir en una categoría propia.
--
--   1. `helios_directorio_especialidades()` añade `vacunacion` (antes de
--      `otra`). El `check` de `directory_listings.specialty_key` la lee en
--      cada escritura, así que no hay nada más que tocar. El panel tiene la
--      misma lista (`features/directorio/especialidades.ts`).
--   2. `helios_directorio_especialidad_sugerida()`: un texto que habla de
--      vacunación y no de pediatría («Vacunación», «Vacunas a domicilio») se
--      deduce como `vacunacion`; con pediatría delante («Pediatría,
--      vacunación») sigue siendo pediatría.
--   3. La tarjeta del Dr. Risquez pasa de `enfermeria` a `vacunacion`. Solo si
--      todavía está en `enfermeria`: si alguien la cambió a mano antes de
--      aplicar esto, no se pisa. Va aquí y no por `admin_directorio_guardar`
--      porque la bitácora exige un autor; el motivo queda en esta migración.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.helios_directorio_especialidades()
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select array[
    'medicina_general', 'medicina_interna', 'pediatria', 'ginecologia',
    'traumatologia', 'cardiologia', 'dermatologia', 'oftalmologia',
    'otorrinolaringologia', 'urologia', 'gastroenterologia', 'coloproctologia',
    'neurologia', 'psicologia', 'nutricion', 'endocrinologia', 'neumologia',
    'oncologia', 'fisioterapia', 'enfermeria', 'vacunacion', 'odontologia',
    'cosmetologia', 'otra'
  ]::text[];
$$;

create or replace function public.helios_directorio_especialidad_sugerida(
  p_specialty text,
  p_category  public.merchant_category default null
)
returns text
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select case
    when t = '' then
      case p_category::text
        when 'odontologia'  then 'odontologia'
        when 'cosmetologia' then 'cosmetologia'
        else 'medicina_general'
      end
    when t ~ 'odont|dental|dentist|ortodon|endodon|periodon|maxilofac|bucal' then 'odontologia'
    when t ~ 'cosmet|estetic'                       then 'cosmetologia'
    when t ~ 'dermat'                               then 'dermatologia'
    when t ~ 'pediat|neonat'                        then 'pediatria'
    when t ~ 'vacun|inmuniz'                        then 'vacunacion'
    when t ~ 'ginec|obstet|pelvic'                  then 'ginecologia'
    when t ~ 'traum|ortoped|cadera|rodilla'         then 'traumatologia'
    when t ~ 'cardio'                               then 'cardiologia'
    when t ~ 'oftalm|optomet|ocular'                then 'oftalmologia'
    when t ~ 'otorrino'                             then 'otorrinolaringologia'
    when t ~ 'urolog|urolo'                         then 'urologia'
    when t ~ 'gastro'                               then 'gastroenterologia'
    when t ~ 'procto'                               then 'coloproctologia'
    when t ~ 'neurol'                               then 'neurologia'
    when t ~ 'psico|psiqui'                         then 'psicologia'
    when t ~ 'nutri'                                then 'nutricion'
    when t ~ 'endocrin|diabet'                      then 'endocrinologia'
    when t ~ 'neumo|pulmon'                         then 'neumologia'
    when t ~ 'oncolog'                              then 'oncologia'
    when t ~ 'fisiot|fisiatr|rehabilit'             then 'fisioterapia'
    when t ~ 'enferm'                               then 'enfermeria'
    when t ~ 'intern'                               then 'medicina_interna'
    when t ~ 'general|familiar'                     then 'medicina_general'
    else 'otra'
  end
  from (select translate(lower(btrim(coalesce(p_specialty, ''))), 'áéíóúü', 'aeiouu') as t) x;
$$;

-- El Dr. Risquez: de «Enfermería» a «Vacunación».
update public.directory_listings
   set specialty_key = 'vacunacion',
       updated_at = now()
 where merchant_id = 'd4b6925a-2061-450a-ae7d-8c7f50554bdd'
   and specialty_key = 'enfermeria';
