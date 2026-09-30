-- ============================================================================
-- Ronda — El comercio puede descartar un QR que todavía nadie escaneó
--
-- Hueco que aparece al montar el flujo de carrito: la pantalla del QR tiene
-- un "Cancelar", pero cancelar solo cambiaba de pantalla. El cobro seguía
-- **vivo cinco minutos**, y si el cajero corrige la orden y genera otro, hay
-- dos QR válidos por la misma consumición. El cliente escanea el de la
-- pantalla; el de antes lo puede reclamar cualquiera que le hiciera una foto.
--
-- Ojo con lo que NO es esto: docs/06 §2 dice que **el comercio no puede
-- revertir un cobro**, y sigue siendo cierto. Revertir es deshacer una venta
-- ya confirmada, con su deuda y sus cuotas creadas. Esto es descartar un QR
-- que nadie llegó a escanear — no hay nada que deshacer porque nunca pasó
-- nada.
--
-- Por eso las condiciones son estrictas: `pending` y sin dueño. Si el cliente
-- confirmó en el mismo segundo en que el cajero tocó Cancelar, gana el
-- cliente y la RPC falla diciéndolo.
-- ============================================================================

create or replace function public.cancel_pending_charge(p_charge_id uuid)
returns public.charges
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff   uuid := auth.uid();
  v_charge  public.charges%rowtype;
  v_allowed boolean;
begin
  if v_staff is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;

  -- FOR UPDATE serializa contra `confirm_charge`: o gana el cliente que está
  -- confirmando, o gana el cajero que cancela, pero no los dos.
  select * into v_charge from public.charges where id = p_charge_id for update;

  if not found then
    raise exception 'Cobro no encontrado' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.merchant_users
    where user_id = v_staff
      and merchant_id = v_charge.merchant_id
      and is_active
      and (branch_id is null or branch_id = v_charge.branch_id)
  ) into v_allowed;

  if not v_allowed then
    raise exception 'No autorizado sobre este cobro' using errcode = '42501';
  end if;

  if v_charge.status = 'confirmed' then
    raise exception 'Este cobro ya fue pagado: no se puede cancelar'
      using errcode = '22023';
  end if;

  if v_charge.status <> 'pending' then
    -- Cancelar dos veces no es un error que merezca asustar a nadie.
    return v_charge;
  end if;

  update public.charges
    set status      = 'voided',
        void_reason = 'Descartado por el comercio antes de escanearse',
        voided_by   = v_staff,
        voided_at   = now()
  where id = p_charge_id
  returning * into v_charge;

  return v_charge;
end;
$$;

revoke all on function public.cancel_pending_charge(uuid) from public, anon;
grant execute on function public.cancel_pending_charge(uuid) to authenticated;
