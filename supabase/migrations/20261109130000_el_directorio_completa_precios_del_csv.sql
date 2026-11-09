-- ═══════════════════════════════════════════════════════════════════════════
-- Helios — El directorio completa los precios que faltaban (CSV del 2026-11-09)
--
-- Javier (2026-11-09) pasó la hoja `docs/Precio consulta/` con el precio de
-- la consulta de cada médico del directorio. Casi todos ya coincidían; faltan
-- dos, los dos en euros:
--
--   · Dra. Andreina Prieto ............. €30
--   · Dr. Victor Miguel Gómez Montaño .. €120
--
-- Sin precio a propósito: Risquez (vacunación), Ponte (tratamientos
-- estéticos), Hafouri y Gómez Fagundez (no están en la hoja o no cambian).
--
-- Cada médico se busca por el nombre de su tarjeta (o el de su clínica, que
-- es el del titular): si no aparece exactamente una clínica, la migración
-- falla y no escribe nada. Pasa por `admin_directorio_guardar`
-- identificándose como Javier dentro de esta transacción (como
-- 20261030100100), así cada cambio queda en `audit.admin_actions` a su
-- nombre, con el antes y el después.
--
-- Hace falta antes de `20261109130100` (la prueba A/B): la Dra. Prieto entra
-- en `/consultas` por su equivalente en dólares; el Dr. Gómez Montaño no
-- (pasa de $60).
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare
  c_javier constant uuid := '256a5b87-e0aa-432b-b9f4-d79610862fff';
  v        record;
  v_n      integer;
  v_id     uuid;
begin
  if not exists (select 1 from public.platform_admins
                  where user_id = c_javier and is_active and role = 'super_admin') then
    raise exception 'Falta el super admin que firma el cambio (%)', c_javier;
  end if;

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', c_javier, 'role', 'authenticated', 'aal', 'aal2')::text, true);

  for v in
    select x.nombre, x.precio, x.moneda
      from (values
        ('Dra. Andreina Prieto', '30', 'EUR'),
        ('Dr. Victor Miguel Gómez Montaño', '120', 'EUR')
      ) x(nombre, precio, moneda)
  loop
    select count(distinct f.merchant_id), min(f.merchant_id::text)::uuid
      into v_n, v_id
      from public.helios_directorio_fichas() f
     where f.name = v.nombre or f.clinic_name = v.nombre;

    if v_n <> 1 then
      raise exception 'Se esperaba exactamente una clínica de «%» y hay %', v.nombre, v_n;
    end if;

    perform public.admin_directorio_guardar(v_id, jsonb_build_object(
      'consultation_price_cur', v.precio,
      'consultation_currency', v.moneda
    ));
  end loop;
end;
$$;
