-- Los días de atraso suspenden, no bloquean.
--
-- mora_demotion_days es el atraso con el que la persona pierde un nivel y su
-- cuenta pasa a «Suspendido», que es como la llama el panel. Su rótulo decía
-- «Días para bloquear», y «bloquear la cuenta» es el bloqueo manual del equipo
-- (user_blocks), que es otra cosa. Ningún otro rótulo del catálogo dice
-- «bloquear».
--
-- Solo se cambia si sigue con el texto de siembra: aplicarla otra vez no pisa
-- un rótulo que alguien haya cambiado después.

update public.business_parameter_catalog
   set label = 'Días para suspender'
 where key = 'mora_demotion_days'
   and label = 'Días para bloquear';
