-- ===========================================================================
-- El personal ya no lee la tabla de cobros
-- ===========================================================================
-- Segunda de dos, después de 20260922220000_lo_que_el_personal_ve_de_un_cobro.
--
-- ⚠️ VA DESPUÉS DE DESPLEGAR EL PANEL que consulta el QR con
-- `merchant_charge_status` y sus líneas con `merchant_charge_items`. El panel
-- anterior las lee de las tablas: con esto aplicado, su sondeo recibe «no hay
-- fila», la tablet nunca ve el cobro pasar a pagado y el comprobante sale sin
-- líneas.
--
-- Quita las dos políticas por las que cualquier persona activa del local leía
-- la fila entera de cada venta —el `user_id` de quien compró, el dinero del
-- gerente— y las líneas de todas, se saltara o no la regla de Ventas. Lo que
-- el personal ve de un cobro sale desde aquí de RPC que deciden por rol.
--
-- Siguen en pie, y son las que usa la app de la gente: `charges_read_own`,
-- `charges_read_debtor`, `charges_read_group_member` y `charges_read_admin`
-- en `charges`, y `charge_items_read_own` en `charge_items`. La app solo lee
-- `charges` en embeds desde `installments`, que entran por la de quien debe.
--
-- De rebote, `merchant_directory` —`security_invoker`, cuenta ventas leyendo
-- `charges`— deja de darle al personal la venta de 30 días del local entero:
-- esas columnas le salen en cero. El super admin, que es quien usa la vista,
-- las sigue viendo por `charges_read_admin`.
-- ===========================================================================

-- Sin las RPC de la primera, esto dejaría ciega la pantalla del QR también con
-- el panel nuevo.
do $$
begin
  if to_regprocedure('public.merchant_charge_status(uuid)') is null
     or to_regprocedure('public.merchant_charge_items(uuid)') is null then
    raise exception 'Falta 20260922220000_lo_que_el_personal_ve_de_un_cobro: aplícala antes';
  end if;
end;
$$;

drop policy if exists "charges_read_merchant_staff" on public.charges;
drop policy if exists "charge_items_read_merchant_staff" on public.charge_items;
