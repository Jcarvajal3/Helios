/**
 * Bancos venezolanos con Pago Móvil, con su código de 4 dígitos.
 *
 * Duplicada de `Ronda-app/src/features/payments/api.ts` a propósito: los dos
 * proyectos son independientes y no hay paquete compartido todavía. Si cambia
 * la lista aquí, cambia también allá.
 */
export const BANKS = [
  { code: '0102', name: 'Banco de Venezuela' },
  { code: '0104', name: 'Venezolano de Crédito' },
  { code: '0105', name: 'Mercantil' },
  { code: '0108', name: 'Provincial' },
  { code: '0114', name: 'Bancaribe' },
  { code: '0115', name: 'Exterior' },
  { code: '0128', name: 'Banco Caroní' },
  { code: '0134', name: 'Banesco' },
  { code: '0138', name: 'Banco Plaza' },
  { code: '0151', name: 'BFC Banco Fondo Común' },
  { code: '0156', name: '100% Banco' },
  { code: '0163', name: 'Banco del Tesoro' },
  { code: '0166', name: 'Banco Agrícola de Venezuela' },
  { code: '0168', name: 'Bancrecer' },
  { code: '0169', name: 'Mi Banco' },
  { code: '0171', name: 'Banco Activo' },
  { code: '0172', name: 'Bancamiga' },
  { code: '0174', name: 'Banplus' },
  { code: '0175', name: 'Banco Bicentenario' },
  { code: '0177', name: 'Banfanb' },
  { code: '0191', name: 'BNC Banco Nacional de Crédito' },
] as const

/**
 * El banco de la cuenta por la que entra el dinero.
 *
 * El estado de cuenta que se importa es siempre el de esa cuenta, así que el
 * importador arranca ahí en vez de en el primero de la lista. No es un
 * detalle de comodidad: el banco forma parte de la huella que evita
 * duplicados, y subir el mismo archivo una vez como BNC y otra como Banco de
 * Venezuela mete los mismos movimientos dos veces.
 */
export const RONDA_BANK =
  BANKS.find((b) => b.code === '0191')?.name ?? BANKS[0].name
