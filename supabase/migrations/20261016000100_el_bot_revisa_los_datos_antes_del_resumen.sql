-- ============================================================================
-- Helios — El bot revisa los datos del paciente antes del resumen (2026-10-16)
--
-- Prueba de Javier (2026-10-16 14:43): el médico escribió el nacimiento como
-- «01011994»; el bot no lo entendió, lo dejó pasar al resumen y, al
-- confirmar, `create_patient_charge` lo rechazó («Fecha de nacimiento
-- inválida»). El bot volvió al menú y se perdió todo el formulario.
--
-- `bot_check_patient(p_phone, p_patient jsonb) → jsonb`: los datos que la
-- base rechazaría, `{campo: motivo}` (vacío si todo vale), con las MISMAS
-- reglas que el registro (`helios_patient_field`: fecha y mayoría de edad,
-- sexo, móvil venezolano, correo, largos). No escribe nada. El bot la llama
-- al recibir los datos y pide solo lo que esté mal, sin perder lo demás. Que
-- falte un dato obligatorio lo dice el propio bot. Solo `service_role`, y
-- solo desde un número del bot activo (`helios_bot_number`).
-- ============================================================================

create or replace function public.bot_check_patient(p_phone text, p_patient jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_n   public.staff_whatsapp_numbers%rowtype := public.helios_bot_number(p_phone);
  v_out jsonb := '{}'::jsonb;
  v_key text;
begin
  foreach v_key in array array['first_name', 'last_name', 'birth_date', 'sex', 'phone', 'email',
                                'state', 'city', 'address', 'occupation'] loop
    if nullif(btrim(coalesce(p_patient ->> v_key, '')), '') is not null then
      begin
        perform public.helios_patient_field(v_key, p_patient ->> v_key);
      exception when sqlstate '22023' then
        v_out := v_out || jsonb_build_object(v_key, sqlerrm);
      end;
    end if;
  end loop;
  return v_out;
end;
$$;

revoke all on function public.bot_check_patient(text, jsonb) from public, anon, authenticated;
grant execute on function public.bot_check_patient(text, jsonb) to service_role;
