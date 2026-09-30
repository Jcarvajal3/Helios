-- ============================================================================
-- Ronda — El nivel 3 baja de $200 a $150
--
-- Decisión del 2026-08-30. La escalera queda 50 / 100 / 150.
--
-- **Qué pasa con quien ya está en nivel 3 y debe más de 150.** No se le reclama
-- nada ni se le toca la deuda: simplemente su disponible es 0 hasta que baje de
-- 150 lo que tiene ocupado. El esquema lo admite —`charged_usd` no está acotado
-- por el límite— y es lo correcto: el límite acota lo que se puede tomar de
-- nuevo, no lo que ya se tomó bajo las reglas de ayer.
--
-- Los requisitos para llegar al 3 no cambian ($600 pagados y 2 meses): lo que
-- cambia es lo que da el nivel, no lo que cuesta.
-- ============================================================================

update public.levels
set monthly_limit_usd = 150.0000
where level = 3;
