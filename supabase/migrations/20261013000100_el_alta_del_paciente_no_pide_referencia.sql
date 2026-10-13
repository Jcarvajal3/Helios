-- ============================================================================
-- Helios — El alta del paciente no pide contacto de referencia (2026-10-13)
--
-- Decisión de Javier: para registrar un pago en cuotas ya no se pide el
-- contacto de referencia (nombre, teléfono y parentesco), ni en el panel ni
-- en el bot de WhatsApp. `helios_patient_input` en modo estricto lo exigía;
-- desde aquí, no. Si llega uno, se valida y se guarda como antes (y su
-- teléfono sigue sin poder ser el del paciente). Las columnas de `profiles`
-- quedan: los pacientes que ya lo dieron lo conservan y el equipo lo ve y lo
-- edita en su ficha.
--
-- Lo demás de la función, idéntico a su última definición (20261008000400).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.helios_patient_input(p_patient jsonb, p_strict boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_out  jsonb := '{}'::jsonb;
  v_key  text;
  v_val  text;
  v_keys text[] := array['first_name', 'last_name', 'birth_date', 'sex', 'phone', 'email',
                         'state', 'city', 'address', 'occupation',
                         'reference_name', 'reference_phone', 'reference_relationship'];
begin
  foreach v_key in array v_keys loop
    if p_strict then
      v_val := public.helios_patient_field(v_key, p_patient->>v_key);
    else
      begin
        v_val := public.helios_patient_field(v_key, p_patient->>v_key);
      exception when others then
        v_val := null;
      end;
    end if;
    if v_val is not null then
      v_out := v_out || jsonb_build_object(v_key, v_val);
    end if;
  end loop;

  if p_strict then
    if v_out->>'first_name' is null or v_out->>'last_name' is null then
      raise exception 'Faltan los nombres y apellidos del paciente' using errcode = '22023';
    end if;
    if v_out->>'birth_date' is null then
      raise exception 'Falta la fecha de nacimiento del paciente' using errcode = '22023';
    end if;
    if v_out->>'sex' is null then
      raise exception 'El sexo debe ser F o M' using errcode = '22023';
    end if;
    if v_out->>'phone' is null then
      raise exception 'Teléfono móvil inválido' using errcode = '22023';
    end if;
    if v_out->>'email' is null then
      raise exception 'Correo inválido' using errcode = '22023';
    end if;
    -- La ciudad ya no se pide (20261008000400): si viene, se guarda.
    if v_out->>'state' is null or v_out->>'address' is null then
      raise exception 'Falta la dirección del paciente (estado y dirección)' using errcode = '22023';
    end if;
    -- El contacto de referencia ya no se pide (20261013000100): si viene,
    -- se valida y se guarda como antes.
    if v_out->>'reference_phone' = v_out->>'phone' then
      raise exception 'El teléfono del contacto de referencia tiene que ser distinto del del paciente'
        using errcode = '22023';
    end if;
  elsif v_out->>'reference_phone' = v_out->>'phone' then
    -- Para comparar con lo registrado: una referencia inválida no se propone.
    v_out := v_out - 'reference_phone';
  end if;

  return v_out;
end;
$function$;

do $$
begin
  perform public.helios_patient_input(jsonb_build_object(
    'first_name', 'Ana', 'last_name', 'Prueba', 'birth_date', '1990-04-12', 'sex', 'F',
    'phone', '04141234567', 'email', 'ana@prueba.com', 'state', 'Distrito Capital',
    'address', 'Los Palos Grandes, calle 4'), true);
exception when others then
  raise exception 'Un paciente sin contacto de referencia debía pasar: %', sqlerrm;
end
$$;
