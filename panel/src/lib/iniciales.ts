/** «Dra. Ana Lara» → «AL»: las iniciales del orbe, sin el título. */
export function inicialesDe(nombre: string): string {
  const palabras = nombre
    .replace(/^(dra?|lcd[oa]|lic|od|psic)\.?\s+/i, '')
    .split(/\s+/)
    .filter((p) => /^\p{L}/u.test(p))
  const primera = palabras[0]?.[0] ?? ''
  const ultima = palabras.length > 1 ? (palabras[palabras.length - 1]?.[0] ?? '') : ''
  return (primera + ultima).toUpperCase()
}
