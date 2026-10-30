-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El directorio amplía su lista de especialidades
--
-- Javier (2026-10-30): el directorio sale en Google (su JSON-LD publica la
-- especialidad de cada médico) y la especialidad se escribía a mano en el
-- alta, con erratas («Traumotología», «Urologo»). Ahora `/afiliacion` la
-- elige de un desplegable con la lista cerrada, y la lista crece de 24 a 43.
--
--   1. `helios_directorio_especialidades()`: las claves nuevas, por nombre y
--      con `otra` al final, en el mismo orden que el panel
--      (`features/directorio/especialidades.ts`). El `check` de
--      `directory_listings.specialty_key` la lee en cada escritura.
--      · Nuevas: anatomía patológica, angiología y cirugía vascular, siete
--        cirugías (cardíaca, craneofacial, general, oncológica, oral y
--        maxilofacial, pediátrica, plástica y reconstructiva, torácica),
--        hematología, hepatología, inmunología, nefrología, neurocirugía,
--        ortodoncia, psiquiatría, radiodiagnóstico y reumatología.
--      · `psicologia` deja de ser «Psicología y psiquiatría»: la psiquiatría
--        tiene su clave. Ninguna tarjeta cambia (la única con `psicologia` es
--        de un psicólogo).
--      · «Ortopedia», «Cirugía ortopédica» y las de cadera, rodilla y pelvis
--        caben en `traumatologia` («Traumatología y ortopedia»), y
--        «Ginecología» y «Obstetricia» siguen juntas en `ginecologia`.
--   2. `helios_directorio_especialidad_sugerida()`: primero el nombre exacto
--      de la lista (lo que guarda el desplegable del alta: «Cirugía
--      general» es `cirugia_general`, no medicina general), y después el
--      texto libre de siempre, que ahora reconoce también las claves nuevas.
--      Las fichas que ya estaban deducen la misma clave que antes.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.helios_directorio_especialidades()
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select array[
    'anatomia_patologica', 'angiologia', 'cardiologia', 'cirugia_cardiaca',
    'cirugia_craneofacial', 'cirugia_general', 'cirugia_oncologica',
    'cirugia_maxilofacial', 'cirugia_pediatrica', 'cirugia_plastica',
    'cirugia_toracica', 'coloproctologia', 'cosmetologia', 'dermatologia',
    'endocrinologia', 'enfermeria', 'fisioterapia', 'gastroenterologia',
    'ginecologia', 'hematologia', 'hepatologia', 'inmunologia',
    'medicina_general', 'medicina_interna', 'nefrologia', 'neumologia',
    'neurocirugia', 'neurologia', 'nutricion', 'odontologia', 'oftalmologia',
    'oncologia', 'ortodoncia', 'otorrinolaringologia', 'pediatria',
    'psicologia', 'psiquiatria', 'radiologia', 'reumatologia', 'traumatologia',
    'urologia', 'vacunacion', 'otra'
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
  select coalesce(
    -- El nombre exacto de la lista, sin tildes ni mayúsculas.
    (select n.clave
       from (values
         ('anatomia patologica', 'anatomia_patologica'),
         ('angiologia y cirugia vascular', 'angiologia'),
         ('cardiologia', 'cardiologia'),
         ('cirugia cardiaca', 'cirugia_cardiaca'),
         ('cirugia craneofacial', 'cirugia_craneofacial'),
         ('cirugia general', 'cirugia_general'),
         ('cirugia oncologica', 'cirugia_oncologica'),
         ('cirugia oral y maxilofacial', 'cirugia_maxilofacial'),
         ('cirugia pediatrica', 'cirugia_pediatrica'),
         ('cirugia plastica y reconstructiva', 'cirugia_plastica'),
         ('cirugia toracica', 'cirugia_toracica'),
         ('coloproctologia', 'coloproctologia'),
         ('cosmetologia y estetica', 'cosmetologia'),
         ('dermatologia', 'dermatologia'),
         ('endocrinologia', 'endocrinologia'),
         ('enfermeria', 'enfermeria'),
         ('fisioterapia', 'fisioterapia'),
         ('gastroenterologia', 'gastroenterologia'),
         ('ginecologia y obstetricia', 'ginecologia'),
         ('hematologia', 'hematologia'),
         ('hepatologia', 'hepatologia'),
         ('inmunologia', 'inmunologia'),
         ('medicina general', 'medicina_general'),
         ('medicina interna', 'medicina_interna'),
         ('nefrologia', 'nefrologia'),
         ('neumologia', 'neumologia'),
         ('neurocirugia', 'neurocirugia'),
         ('neurologia', 'neurologia'),
         ('nutricion', 'nutricion'),
         ('odontologia', 'odontologia'),
         ('oftalmologia', 'oftalmologia'),
         ('oncologia', 'oncologia'),
         ('ortodoncia', 'ortodoncia'),
         ('otorrinolaringologia', 'otorrinolaringologia'),
         ('pediatria', 'pediatria'),
         ('psicologia', 'psicologia'),
         ('psiquiatria', 'psiquiatria'),
         ('radiodiagnostico (imagenes)', 'radiologia'),
         ('reumatologia', 'reumatologia'),
         ('traumatologia y ortopedia', 'traumatologia'),
         ('urologia', 'urologia'),
         ('vacunacion', 'vacunacion')
       ) n(nombre, clave)
      where n.nombre = t),
    -- El texto libre (las fichas de antes y «Otras especialidades»). El orden
    -- importa: lo más concreto primero («neurocirugía» antes que
    -- «neurología», «cirugía cardíaca» antes que «cardiología»).
    case
      when t = '' then
        case p_category::text
          when 'odontologia'  then 'odontologia'
          when 'cosmetologia' then 'cosmetologia'
          else 'medicina_general'
        end
      when t ~ 'ortodon'                              then 'ortodoncia'
      when t ~ 'maxilofac'                            then 'cirugia_maxilofacial'
      when t ~ 'odont|dental|dentist|endodon|periodon|bucal' then 'odontologia'
      when t ~ 'plastic|reconstruct'                  then 'cirugia_plastica'
      when t ~ 'cosmet|estetic'                       then 'cosmetologia'
      when t ~ 'dermat'                               then 'dermatologia'
      when t ~ 'neurocirug'                           then 'neurocirugia'
      when t ~ 'cirug[a-z]* pediat'                   then 'cirugia_pediatrica'
      when t ~ 'pediat|neonat'                        then 'pediatria'
      when t ~ 'vacun|inmuniz'                        then 'vacunacion'
      when t ~ 'ginec|obstet|pelvic'                  then 'ginecologia'
      when t ~ 'traum|ortoped|cadera|rodilla'         then 'traumatologia'
      when t ~ 'cirug[a-z]* card'                     then 'cirugia_cardiaca'
      when t ~ 'cardio'                               then 'cardiologia'
      when t ~ 'angio|vascul'                         then 'angiologia'
      when t ~ 'oftalm|optomet|ocular'                then 'oftalmologia'
      when t ~ 'otorrino'                             then 'otorrinolaringologia'
      when t ~ 'urolog|urolo'                         then 'urologia'
      when t ~ 'gastro'                               then 'gastroenterologia'
      when t ~ 'hepat'                                then 'hepatologia'
      when t ~ 'procto'                               then 'coloproctologia'
      when t ~ 'neurol'                               then 'neurologia'
      when t ~ 'psiqui'                               then 'psiquiatria'
      when t ~ 'psico'                                then 'psicologia'
      when t ~ 'nutri|nutrol'                         then 'nutricion'
      when t ~ 'endocrin|diabet'                      then 'endocrinologia'
      when t ~ 'neumo|pulmon'                         then 'neumologia'
      when t ~ 'cirug[a-z]* oncol'                    then 'cirugia_oncologica'
      when t ~ 'oncolog'                              then 'oncologia'
      when t ~ 'hemato'                               then 'hematologia'
      when t ~ 'nefro|renal'                          then 'nefrologia'
      when t ~ 'reumat'                               then 'reumatologia'
      when t ~ 'inmunol|alerg'                        then 'inmunologia'
      when t ~ 'radiol|radiodiag|imagenolog|ecograf'  then 'radiologia'
      when t ~ 'anatom[a-z]* patolog|^patolog'        then 'anatomia_patologica'
      when t ~ 'torac'                                then 'cirugia_toracica'
      when t ~ 'craneofac'                            then 'cirugia_craneofacial'
      when t ~ 'cirug|cirujan'                        then 'cirugia_general'
      when t ~ 'fisiot|fisiatr|rehabilit'             then 'fisioterapia'
      when t ~ 'enferm'                               then 'enfermeria'
      when t ~ 'intern'                               then 'medicina_interna'
      when t ~ 'general|familiar'                     then 'medicina_general'
      else 'otra'
    end
  )
  from (select translate(lower(regexp_replace(btrim(coalesce(p_specialty, '')), '\s+', ' ', 'g')),
                         'áéíóúü', 'aeiouu') as t) x;
$$;

revoke all on function public.helios_directorio_especialidades() from public, anon, authenticated;
revoke all on function public.helios_directorio_especialidad_sugerida(text, public.merchant_category) from public, anon, authenticated;
