-- ============================================================================
-- Helios — La lectura ya registrada no se vuelve a ofrecer (docs/03)
--
-- `admin_receipt_read_latest` (20261021200000) rellena «Registrar pago» con
-- la última captura que el bot no registró solo. Cuando el equipo ya registró
-- un pago de ese paciente después de esa captura, la lectura está atendida:
-- se deja de ofrecer, con la misma regla del contador «para revisar» de
-- `admin_receipt_reads`.
-- ============================================================================

create or replace function public.admin_receipt_read_latest(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_r public.payment_receipt_reads%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Solo personal de Helios' using errcode = '42501';
  end if;

  select * into v_r
  from public.payment_receipt_reads x
  where x.profile_id = p_user
    and x.report_id is null
    and x.status in ('para_el_equipo', 'sombra', 'esperando_referencia', 'esperando_aviso')
    and x.created_at > now() - interval '7 days'
    and not exists (select 1 from public.payment_reports p
                    where p.user_id = x.profile_id
                      and p.created_at > x.created_at)
  order by x.created_at desc
  limit 1;

  if not found then
    return null;
  end if;
  return public.helios_admin_receipt_read(v_r);
end;
$$;
