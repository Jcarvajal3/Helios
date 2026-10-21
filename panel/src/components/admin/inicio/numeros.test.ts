/**
 * Pruebas de lo que Inicio calcula fuera de las colas: el reloj, «Bloquea la
 * operación» y las cuentas pequeñas de «Hoy en cifras».
 *
 *   npx tsx src/components/admin/inicio/numeros.test.ts
 *
 * Lo que se vigila: que el día operativo cambie a medianoche en Caracas y no
 * antes, que cada bloqueo salga solo cuando hay algo que arreglar, que el
 * semáforo del pago a clínicas mire hasta la víspera y solo sea rojo cuando
 * esperar ya no basta, y que el último mes maduro no sea uno a medias.
 */
import { formatWaitingHours } from '@/components/ui'
import {
  bloqueoDeCuenta,
  bloqueoDeExtracto,
  bloqueoDeTasa,
} from './bloqueos'
import { ultimoMesMaduro, veredictoDelCierre } from './numeros'
import {
  diaCortoConNombre,
  horaDeCaracas,
  horaYMinutoDeCaracas,
  hoyOperativo,
} from './reloj'

let fallos = 0

function comprueba(ok: boolean, titulo: string, detalle = '') {
  if (!ok) fallos++
  console.log(`${ok ? '  ok  ' : ' FALLA'}  ${titulo}${ok ? '' : ` — ${detalle}`}`)
}

console.log('── El reloj ─────────────────────────────────────────────────')
{
  // Caracas es UTC−4 todo el año.
  comprueba(hoyOperativo(new Date('2026-09-25T03:59:00Z')) === '2026-09-24', 'a las 23:59 sigue siendo ayer')
  comprueba(hoyOperativo(new Date('2026-09-25T04:00:00Z')) === '2026-09-25', 'a medianoche empieza hoy')
  comprueba(hoyOperativo(new Date('2026-09-25T13:59:00Z')) === '2026-09-25', 'a las 9:59 ya es hoy: el corte no es a las 10')
  comprueba(hoyOperativo(new Date('2026-09-26T03:30:00Z')) === '2026-09-25', 'a las 23:30 sigue siendo hoy')

  const t = horaYMinutoDeCaracas(new Date('2026-09-25T19:15:00Z'))
  comprueba(t.hora === 15 && t.minuto === 15, 'las 19:15 UTC son las 15:15 en Caracas')
  comprueba(horaYMinutoDeCaracas(new Date('2026-09-25T04:05:00Z')).hora === 0, 'la medianoche es la hora 0, no la 24')

  comprueba(diaCortoConNombre('2026-09-25') === 'Viernes 25 sep', 'el día con nombre, corto', diaCortoConNombre('2026-09-25'))
  comprueba(diaCortoConNombre('2026-10-04') === 'Domingo 4 oct', 'sin cero delante del día')

  // El formato de es-VE usa espacios finos distintos según la versión de ICU.
  const hora = horaDeCaracas(new Date('2026-09-25T19:15:00Z')).replace(/\s/g, ' ')
  comprueba(hora.startsWith('3:15'), 'la hora sin cero delante, como se dice', hora)
}

console.log('\n── Bloquea la operación ─────────────────────────────────────')
{
  const sinTasa = bloqueoDeTasa({ rate: null, isStale: false, ageHours: null })
  comprueba(sinTasa?.arreglo.rotulo === 'Cargar la tasa', 'sin tasa, bloquea y lleva a cargarla')
  const vieja = bloqueoDeTasa({ rate: 1000, isStale: true, ageHours: 60 })
  comprueba(
    vieja?.texto === `La tasa BCV no se actualiza desde hace ${formatWaitingHours(60)}.`,
    'una tasa de más de 48 h dice cuánto lleva',
    String(vieja?.texto),
  )
  comprueba(bloqueoDeTasa({ rate: 1000, isStale: false, ageHours: 3 }) === null, 'una tasa al día no bloquea')
  const euroVieja = bloqueoDeTasa({ rate: 1100, isStale: true, ageHours: 60 }, 'EUR')
  comprueba(euroVieja?.id === 'tasa-eur' && euroVieja.texto.includes('del euro'), 'la del euro vieja también bloquea, con su nombre')
}
{
  comprueba(
    bloqueoDeCuenta([])?.texto === 'No hay ninguna cuenta de cobro activa.',
    'sin cuenta activa, bloquea',
  )
  comprueba(
    bloqueoDeCuenta([{ isActive: true, rif: 'J-000000000' }])?.texto ===
      'La única cuenta de cobro activa es la de relleno.',
    'la cuenta de relleno también bloquea',
  )
  comprueba(
    bloqueoDeCuenta([
      { isActive: false, rif: 'J-000000000' },
      { isActive: true, rif: 'J-412345678' },
    ]) === null,
    'una cuenta activa de verdad no bloquea',
  )
  comprueba(
    bloqueoDeCuenta([
      { isActive: true, rif: 'J-000000000' },
      { isActive: true, rif: 'J-412345678' },
    ]) === null,
    'con varias activas (Helios), basta una de verdad aunque siga la de relleno',
  )
  comprueba(
    bloqueoDeCuenta([{ isActive: false, rif: 'J-412345678' }]) !== null,
    'una cuenta buena pero apagada no sirve',
  )
}
{
  comprueba(
    bloqueoDeExtracto(null)?.texto === 'Nunca se ha importado el extracto del banco.',
    'un extracto nunca importado bloquea',
  )
  comprueba(bloqueoDeExtracto(2) === null, 'dos días no bloquean')
  comprueba(
    bloqueoDeExtracto(3)?.texto === 'Hace 3 días que no se importa el extracto del banco.',
    'a los tres días, bloquea',
  )
}

console.log('\n── Caja ─────────────────────────────────────────────────────')
{
  comprueba(veredictoDelCierre({ salen: 100, caja: 100 }) === 'cubre', 'con la caja justa, cubre')
  comprueba(veredictoDelCierre({ salen: 100, caja: 40 }) === 'urgente', 'si no alcanza, no cubre: el pago es hoy')
  comprueba(veredictoDelCierre({ salen: 0, caja: 0 }) === 'cubre', 'sin nada que pagar, cubre')
}

console.log('\n── Riesgo ───────────────────────────────────────────────────')
{
  const filas = [
    { clave: '2026-09', maduras: 0, enGracia: 7 },
    { clave: '2026-08', maduras: 5, enGracia: 2 },
    { clave: '2026-07', maduras: 4, enGracia: 0 },
    { clave: '2026-06', maduras: 9, enGracia: 0 },
  ]
  comprueba(ultimoMesMaduro(filas)?.clave === '2026-07', 'el más reciente sin cuotas en la gracia', String(ultimoMesMaduro(filas)?.clave))
  comprueba(ultimoMesMaduro(filas.slice(0, 2)) === null, 'un mes a medias no cuenta como maduro')
}

console.log(fallos === 0 ? '\nTodo en orden.' : `\n${fallos} fallo(s).`)
if (fallos > 0) process.exit(1)
