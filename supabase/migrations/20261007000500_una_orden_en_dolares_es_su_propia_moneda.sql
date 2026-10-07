-- ============================================================================
-- Helios — Una orden en dólares es su propia moneda
--
-- `20261007000200` rellenó los montos `_cur` de las órdenes que ya había, y
-- `create_patient_charge` los escribe en las nuevas. Pero cualquier otro
-- camino que inserte o toque una orden (la ayuda de las pruebas
-- `pg_temp.prueba_cobro`, una reversa, un arreglo a mano) los dejaría vacíos,
-- y entonces los mensajes dirían «$0».
--
-- En una orden en DÓLARES, los montos en su moneda son los mismos que los del
-- libro: este trigger los copia siempre, al insertar y al actualizar. En una
-- orden en euros no hace nada: sus montos en euros los pone quien la crea
-- (`create_patient_charge`, `staff_resend_confirmation`) y no se deducen de
-- los dólares.
-- ============================================================================

create or replace function public.helios_charge_currency_amounts()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.currency = 'USD' then
    new.fx_usd_per_unit      := 1;
    new.amount_cur           := new.amount_usd;
    new.base_cur             := new.base_usd;
    new.consumer_fee_cur     := new.consumer_fee_usd;
    new.consumer_fee_vat_cur := new.consumer_fee_vat_usd;
    new.merchant_net_cur     := new.merchant_net_usd;
  end if;
  return new;
end;
$$;

revoke all on function public.helios_charge_currency_amounts() from public, anon, authenticated;

drop trigger if exists charges_currency_amounts on public.charges;
create trigger charges_currency_amounts
  before insert or update of currency, amount_usd, base_usd, consumer_fee_usd,
                             consumer_fee_vat_usd, merchant_net_usd, fx_usd_per_unit
  on public.charges
  for each row execute function public.helios_charge_currency_amounts();

-- Por si alguna quedó vacía entre la migración anterior y esta.
update public.charges
set amount_cur = amount_usd, base_cur = base_usd, consumer_fee_cur = consumer_fee_usd,
    consumer_fee_vat_cur = consumer_fee_vat_usd, merchant_net_cur = merchant_net_usd
where currency = 'USD' and amount_cur is distinct from amount_usd;
