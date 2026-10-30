-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El directorio corrige erratas y pone la ciudad de cada médico
--
-- Javier (2026-10-30) aprobó la tabla de correcciones de las tarjetas del
-- directorio, con una condición: en la dirección solo se toca lo general
-- (avenida, calle, urbanización, ciudad). El edificio, el piso, el
-- consultorio o la oficina quedan tal cual los escribió el médico, porque no
-- hay forma de saber si están bien.
--
--   · Especialidad: erratas y tildes («Traumotología» → «Traumatología»,
--     «Urologo» → «Urología»). Ninguna clave del directorio cambia.
--   · Dirección: la avenida o la urbanización que faltaba o estaba mal
--     escrita, solo cuando una fuente lo dice sin ambigüedad (la tabla con
--     las fuentes quedó en las notas de la sesión del 2026-10-30).
--   · Ciudad: ninguna tarjeta la tenía, así que el JSON-LD no publicaba
--     `addressLocality`. Se pone la que dice su dirección o la fuente.
--   · «Góméz» → «Gómez»: en la ficha (el nombre sale también en los mensajes
--     al paciente), no solo en la tarjeta.
--
-- Pasa por las RPC del superadmin (`admin_directorio_guardar`,
-- `admin_set_merchant_owner`), identificándose como Javier dentro de esta
-- transacción: así cada cambio queda en `audit.admin_actions` a su nombre,
-- con el antes y el después. En una base sin estas clínicas no hace nada.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare
  c_javier constant uuid := '256a5b87-e0aa-432b-b9f4-d79610862fff';
  v record;
begin
  if not exists (select 1 from public.platform_admins
                  where user_id = c_javier and is_active and role = 'super_admin') then
    return;
  end if;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', c_javier, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  for v in
    select x.id::uuid as id, x.cambios::jsonb as cambios
      from (values
        -- Dr. Aroldo Macareño Stelling
        ('aa518a59-4c2d-4135-941d-203703195d6b', '{"specialty": "Traumatología y ortopedia", "city": "Caracas"}'),
        -- Dr. Carlos Eduardo Cuenca Cabello
        ('db1dbe76-5e90-40c1-a74a-b96b2eb0a139', '{"specialty": "Traumatología; cirugía de cadera, rodilla y pelvis", "city": "Caracas"}'),
        -- Dr. Edgard Jose Castillo Gallardo (policlinicaaltosmirandinos.com/contacto)
        ('ff9bcc5c-4cf9-4aba-a03a-7beac328de02', '{"specialty": "Medicina interna y gastroenterología", "address": "Los Teques, Miranda, final calle Guaicaipuro, callejón Almenar, sector Punta Brava, policlinica altos mirandinos", "city": "Los Teques"}'),
        -- Dr. Eleazar Wacher (clinicaracas.com/contact)
        ('80c9daff-8cd8-40e4-9a7c-25c477839629', '{"specialty": "Obstetricia y ginecología oncológica", "address": "Av. Panteón con Av. Alameda, San Bernardino", "city": "Caracas"}'),
        -- Dr. Francisco Alejandro Risquez Parra
        ('d4b6925a-2061-450a-ae7d-8c7f50554bdd', '{"specialty": "Vacunación", "city": "Caracas"}'),
        -- Dr. Gustavo Jose Villasmil Prieto (policlinicametropolitana.org/pages/contact)
        ('02338ce6-1630-450e-b450-585a06ea2375', '{"address": "Policlinica metropolitana, Calle A-1, Urb. Caurimare", "city": "Caracas"}'),
        -- Dr. Hiram Rafael Padron
        ('f313d9e6-9ae0-49b4-9a29-2814593238b0', '{"specialty": "Traumatología y ortopedia", "city": "San Antonio de los Altos"}'),
        -- Dr. Jackson Arias (policlinicaaltosmirandinos.com/contacto)
        ('3a5561e9-0571-4c4f-ba43-c20d0544d101', '{"specialty": "Ginecología y obstetricia; piso pélvico", "address": "Policlinica altos Mirandinos, final calle Guaicaipuro, callejón Almenar, sector Punta Brava, Piso 1 consultorio 2", "city": "Los Teques"}'),
        -- Dr. Jesús A Dale Páez (es.wikipedia.org/wiki/Torre_América)
        ('dbe10a37-c0d1-438d-b839-6c84958e9418', '{"address": "Torre América piso 4 oficina 412, Av. Venezuela, Bello Monte", "city": "Caracas"}'),
        -- Dr. Jesús Contreras S
        ('c1db7085-4530-4e3a-ace0-8dd6ca4027d2', '{"city": "Caracas"}'),
        -- Dr. Jesús Francisco Vivas Rodríguez
        ('4bd51422-39b3-429d-b5e7-2a92f6d48fe4', '{"specialty": "Otorrinolaringología", "city": "Caracas"}'),
        -- Dr. Jesus Stanley Velasquez R (centrosaludcaracas.com)
        ('a59ddd77-e1bb-48c7-b45e-44e86980ea90', '{"specialty": "Ginecología y obstetricia", "address": "Av. Sorocaima cruce con Av. Francisco Fajardo, San Bernardino. Edif. Centrosalud. Piso 5 Consultorio 502", "city": "Caracas"}'),
        -- Dr. Victor Miguel Góméz Montaño (policlinicametropolitana.org/pages/contact)
        ('2b8d52b4-4c41-4922-9bae-a0a64a898bd5', '{"specialty": "Urología", "address": "POLICLÍNICA METROPOLITANA, Calle A-1, Urb. Caurimare", "city": "Caracas"}'),
        -- Dra. Alejandra Jackeline Vasquez Arrieche
        ('e15e5916-e57a-4070-8fdb-a275a92c4937', '{"city": "Caracas"}'),
        -- Dra. Ana Lara (centrosaludcaracas.com)
        ('515adcb8-b90e-4f59-92bc-58d15d9be244', '{"specialty": "Dermatología", "address": "Av. Sorocaima con Av. Francisco Fajardo, San Bernardino, Centro Salud", "city": "Caracas"}'),
        -- Dra. Andrea Paola Betancourt Garrido
        ('c3a87763-f6cb-46f9-a8a1-829f14cca8a2', '{"specialty": "Ginecología y obstetricia", "city": "Caracas"}'),
        -- Dra. Ani Materan
        ('72356cd8-815b-49cc-83c8-6b6879c2b093', '{"address": "Centro empresarial Don Bosco, nivel Ofi 2 oficina 21. Avenida Francisco de Miranda, Los Cortijos", "city": "Caracas"}'),
        -- Dra. Cecil Palmero
        ('11475d4d-0964-4543-ad11-66fc7f1fc35f', '{"specialty": "Odontología", "city": "Caracas"}'),
        -- Dra. Dilia Maria Pereira Mujica (dirección fiscal de su óptica, pymesvenezuela.com)
        ('3d339fc9-a02d-4100-b579-d68bdd99e503', '{"specialty": "Oftalmología y optometría", "address": "CENTRO COMERCIAL LOS SAMANES, Av. Principal de Los Samanes, Baruta", "city": "Caracas"}'),
        -- Dra. María de Lourdes Asbati
        ('751e9287-7cba-44fa-8ffd-3f9489e17d71', '{"city": "Caracas"}'),
        -- Dra. Marianghela Karellys Martinez Galdon (mapcarta.com/es/W235548007)
        ('33c4e7de-b073-42e1-9431-6bdc61c77d95', '{"address": "Av. Francisco Solano, Centro Solano Plaza, piso 1 oficina 1f", "city": "Caracas"}'),
        -- Dra. Nadia Andi Khabbaze Alfaro
        ('96c173ed-b55a-430a-a554-1f28819bae0b', '{"specialty": "Odontología", "city": "Caracas"}'),
        -- Dra. Priscila Rodriguez Le Maitre (mapcarta.com/es/W242656285)
        ('03a4e799-a4cc-4e15-82c4-90e608a9fb5d', '{"specialty": "Ginecología y obstetricia; ginecología infantojuvenil", "address": "Av. Francisco de Miranda, Chacao, Edificio Banco del Orinoco. Piso 2, Consultorio 2D.", "city": "Caracas"}'),
        -- Dra. Zuleidys Arellano (citamedica.app/hospital/clinica-opiolid)
        ('3625fe7f-eb02-4ffd-85fe-f7c922174f68', '{"specialty": "Ginecología y obstetricia", "address": "Av. Francisco Solano López con calle Los Mangos", "city": "Caracas"}'),
        -- Lcda. Elizabeth del Valle Ponte Castillo
        ('bf39cc0e-9bdf-4e57-b0be-e3476458eb13', '{"city": "Caracas"}'),
        -- Lcdo. Daniel Álvarez (El Rosal: el consultorio de su ficha)
        ('01e3c033-82fa-4148-971c-cc07387afd7b', '{"address": "Av. Francisco de Miranda, El Rosal, Edif. Canaima, Piso 8, Oficina 602-3", "city": "Caracas"}'),
        -- Dr. Ricardo Trinidad (no publicado)
        ('14990a13-75f7-4afe-ace3-0c1c1d15dc2b', '{"specialty": "Cardiología y neumonología de adultos", "city": "Los Teques"}'),
        -- Dra. Israelys Nuñez (no publicada)
        ('eb52b001-a4ec-4426-9607-3b0b403f90ad', '{"specialty": "Ginecología"}')
      ) x(id, cambios)
     where exists (select 1 from public.merchants m where m.id = x.id::uuid)
  loop
    perform public.admin_directorio_guardar(v.id, v.cambios);
  end loop;

  if exists (select 1 from public.merchants
              where id = '2b8d52b4-4c41-4922-9bae-a0a64a898bd5' and owner_name = 'Victor Miguel Góméz Montaño') then
    perform public.admin_set_merchant_owner('2b8d52b4-4c41-4922-9bae-a0a64a898bd5',
      '{"owner_name": "Victor Miguel Gómez Montaño"}');
  end if;
end;
$$;
