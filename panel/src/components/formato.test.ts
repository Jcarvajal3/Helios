/**
 * Pruebas del formato de los importes.
 *
 *   npx tsx src/components/formato.test.ts
 *
 * Lo que se vigila: que un negativo lleve el signo menos de verdad (U+2212)
 * DELANTE del símbolo —'−€16,70' y no '€-16,70'—, que el cero no tenga signo
 * aunque venga de negar una cuenta en cero (-0) o de redondear un negativo
 * diminuto, y que los positivos sigan saliendo como siempre.
 */
import { formatUsd, formatUsdShort } from './ui'

let fallos = 0

function comprueba(sale: string, espera: string, titulo: string) {
  const ok = sale === espera
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — sale ${JSON.stringify(sale)}, se esperaba ${JSON.stringify(espera)}`}`)
}

const MENOS = '−'

console.log('── formatUsd ─────────────────────────────────────────────────')
comprueba(formatUsd(150), '$150,00', 'un positivo, con sus céntimos')
comprueba(formatUsd(1284.5), '$1.284,50', 'con el punto de millar')
comprueba(formatUsd(-16.7), `${MENOS}$16,70`, 'un negativo, con el signo delante del símbolo')
comprueba(formatUsd(-1284.5), `${MENOS}$1.284,50`, 'un negativo con millares')
comprueba(formatUsd(0), '$0,00', 'el cero')
comprueba(formatUsd(-0), '$0,00', '-0 sale sin signo')
comprueba(formatUsd(-0.001), '$0,00', 'un negativo que se redondea a cero sale sin signo')
comprueba(formatUsd(-0.005), `${MENOS}$0,01`, 'un negativo que se redondea a un céntimo lleva signo')
comprueba(formatUsd(0.1 + 0.2), '$0,30', 'la coma flotante no asoma')

console.log('── formatUsdShort ────────────────────────────────────────────')
comprueba(formatUsdShort(450), '$450', 'cientos, sin decimales')
comprueba(formatUsdShort(1284.5), '$1,3 k', 'miles')
comprueba(formatUsdShort(2_400_000), '$2,4 M', 'millones')
comprueba(formatUsdShort(2.5), '$2,5', 'menos de diez, con decimales')
comprueba(formatUsdShort(-16.7), `${MENOS}$16,7`, 'un negativo')
comprueba(formatUsdShort(-1284.5), `${MENOS}$1,3 k`, 'un negativo en miles')
comprueba(formatUsdShort(-2_400_000), `${MENOS}$2,4 M`, 'un negativo en millones')
comprueba(formatUsdShort(0), '$0', 'el cero')
comprueba(formatUsdShort(-0), '$0', '-0 sale sin signo')
comprueba(formatUsdShort(-0.001), '$0', 'un negativo que se redondea a cero sale sin signo')

console.log(fallos === 0 ? '\nTodo bien.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
