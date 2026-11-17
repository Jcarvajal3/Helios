/**
 * Los seis rayos del isologo de Helios (brand/helios-isologo.svg), sin el
 * fondo azul y en `currentColor`: para dibujarlos grandes y girando detrás
 * de un bloque de color (`ParaMedicos`). Es decoración: siempre `aria-hidden`.
 */
export function IsologoHelios({ className = '', ...aria }: { className?: string; 'aria-hidden'?: boolean }) {
  return (
    <svg viewBox="150 150 420 420" fill="currentColor" className={`text-white ${className}`} {...aria}>
      <path d="M448.5 273.5c-6.5 7.9-5.3 19.6 2.6 26.1 8 6.5 19.7 5.4 26.2-2.6l48.5-59.4c6.5-7.9 5.4-19.6-2.6-26.1-7.9-6.5-19.7-5.4-26.2 2.6zM277.2 505c-6 8.3-4.2 19.9 4.1 26 8.3 6 20 4.1 26-4.2l38.5-53c6-8.3 4.2-20-4.1-26-8.3-6-20-4.2-26 4.1zM306.3 295.6c6.7 7.8 18.4 8.8 26.3 2.1 7.8-6.7 8.7-18.4 2-26.2l-47.2-55.4c-6.7-7.8-18.4-8.7-26.3-2-7.8 6.6-8.7 18.4-2 26.2zM373 261.4c0 10.2 8.3 18.6 18.6 18.6s18.6-8.4 18.6-18.6v-72.8c0-10.3-8.3-18.6-18.6-18.6S373 178.3 373 188.6zM272.2 362.6c10 2.6 20.2-3.3 22.8-13.2 2.7-9.9-3.2-20.1-13.1-22.8l-70.3-18.8c-9.9-2.6-20.1 3.2-22.8 13.2-2.6 9.9 3.2 20.1 13.2 22.7zM290.6 429.5c9.4-4.1 13.7-15.1 9.5-24.5-4.1-9.4-15.1-13.7-24.5-9.5L209 424.8c-9.4 4.1-13.7 15.1-9.5 24.5 4.1 9.4 15.1 13.7 24.5 9.5z" />
    </svg>
  )
}
