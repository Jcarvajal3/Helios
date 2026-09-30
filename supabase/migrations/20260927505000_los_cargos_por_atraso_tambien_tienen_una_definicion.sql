-- ============================================================================
-- Ronda — Los cargos por atraso también tienen una definición
--
-- El resumen semanal, la serie diaria y la economía por consumo cuentan los
-- cargos por atraso cada uno con su consulta, y la pestaña General, la de
-- Semana y la de Caja de Métricas los necesitan otra vez. Una vista en el
-- esquema `metricas` (20260927500000) y ninguna copia más.
--
-- Un cargo por atraso es ingreso de Ronda SIN IVA (lo devenga
-- `charge_late_fee`), va siempre aparte del consumo y del servicio, y se
-- cuenta por el día operativo en que se cargó. Lo condonado a mano
-- (`waived_at`) no es ingreso y no entra; lo dado por perdido sí se devengó y
-- sale con status 'written_off'. Sin cuentas de prueba.
-- ============================================================================

create or replace view metricas.cargos_por_atraso as
select
  lf.id                                             as late_fee_id,
  lf.user_id                                        as user_id,
  lf.installment_id                                 as installment_id,
  i.charge_id                                       as charge_id,
  c.merchant_id                                     as merchant_id,
  lf.business_date                                  as business_date,
  metricas.lunes(lf.business_date)                  as semana,
  lf.amount_usd::numeric                            as amount_usd,
  lf.status::text                                   as status,
  lf.paid_at                                        as paid_at,
  public.helios_business_date(lf.paid_at)            as pagado_dia,
  lf.days_late                                      as dias_atraso
from public.late_fees lf
join public.profiles p on p.id = lf.user_id and not p.is_test
left join public.installments i on i.id = lf.installment_id
left join public.charges c on c.id = i.charge_id
where lf.waived_at is null;

comment on view metricas.cargos_por_atraso is
  'Una fila por cargo por atraso devengado y no condonado de una persona real. Ingreso de Helios sin IVA, siempre aparte del consumo y del servicio. Cargado = por business_date; cobrado = status ''paid'' por pagado_dia.';
comment on column metricas.cargos_por_atraso.late_fee_id is 'El cargo (late_fees.id).';
comment on column metricas.cargos_por_atraso.user_id is 'A quién se le cargó.';
comment on column metricas.cargos_por_atraso.installment_id is 'La cuota que lo disparó. Nula en los cargos anteriores al 2026-09-02 (uno por episodio de mora).';
comment on column metricas.cargos_por_atraso.charge_id is 'El consumo de esa cuota, si la hay.';
comment on column metricas.cargos_por_atraso.merchant_id is 'El local de ese consumo, si lo hay: permite partir los cargos por local.';
comment on column metricas.cargos_por_atraso.business_date is 'Día operativo en que se cargó (se devengó).';
comment on column metricas.cargos_por_atraso.semana is 'Lunes de la semana en que se cargó.';
comment on column metricas.cargos_por_atraso.amount_usd is 'El cargo, sin IVA. Es ingreso de Helios; nunca se suma al consumo ni al servicio.';
comment on column metricas.cargos_por_atraso.status is '''pending'' (por cobrar), ''paid'' (cobrado) o ''written_off'' (dado por perdido).';
comment on column metricas.cargos_por_atraso.paid_at is 'Instante en que se aprobó el pago que lo saldó.';
comment on column metricas.cargos_por_atraso.pagado_dia is 'Día operativo de paid_at.';
comment on column metricas.cargos_por_atraso.dias_atraso is 'Días de atraso de la cuota cuando se cargó (late_fees.days_late).';

revoke all on metricas.cargos_por_atraso from public, anon, authenticated;
