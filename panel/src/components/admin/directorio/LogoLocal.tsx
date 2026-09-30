/**
 * El logo de un local si tiene, y si no su inicial: lo mismo que ve la gente
 * en la app. Lo usan la lista de Locales y la cabecera de su ficha.
 */
export function LogoLocal({
  name,
  logoUrl,
  size = 'md',
}: {
  name: string
  logoUrl: string | null
  size?: 'md' | 'lg'
}) {
  const medida = size === 'lg' ? 'size-14' : 'size-10'

  if (logoUrl) {
    return (
      <img
        src={logoUrl}
        alt=""
        className={`${medida} shrink-0 rounded-panel-control object-cover`}
      />
    )
  }

  return (
    <div
      aria-hidden
      className={`flex ${medida} shrink-0 items-center justify-center rounded-panel-control bg-panel-control type-panel-control text-on-surface-variant`}
    >
      {name.charAt(0).toUpperCase()}
    </div>
  )
}
