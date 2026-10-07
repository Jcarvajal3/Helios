-- ============================================================================
-- Helios — En un mensaje, la moneda por defecto es el dólar
--
-- `{moneda}` (20261007000400) lo pone quien arma cada mensaje con la moneda
-- de la orden. Pero `helios_enqueue_message` se niega a encolar una plantilla
-- a la que le falta una variable, y la bienvenida o el comprobante se pueden
-- encolar por otros caminos (un reenvío, una prueba, un arreglo a mano). Para
-- que esos no se queden sin salir, `moneda` pasa a ser también una variable
-- de siempre con el valor de antes, «dólar»; la de la orden la pisa.
-- ============================================================================

do $$
declare
  v_def text := pg_get_functiondef('public.helios_message_builtins(uuid)'::regprocedure);
begin
  if position('''moneda''' in v_def) = 0 then
    v_def := replace(v_def,
      $r$    'tasa_bcv_euro', case$r$,
      $r$    -- La de la orden la pisa (20261007000600).
    'moneda', 'dólar',
    'tasa_bcv_euro', case$r$);
    execute v_def;
  end if;
end
$$;
