import { Search } from 'lucide-react'

import { Pie } from '@/components/portada'
import { Menu } from '@/components/portada/Menu'
import { Boton, Lienzo } from '@/components/portada/piezas'
import { FUENTES_DE_LA_PORTADA } from '@/lib/fuentes'

/**
 * El 404 de las páginas del directorio: una especialidad sin médicos, un
 * médico que ya no sale o un enlace mal escrito. Lleva de vuelta al
 * directorio. Su `head` (`PAGINA_NO_ENCONTRADA`) dice a Google que no la
 * guarde.
 */
export const PAGINA_NO_ENCONTRADA = {
  meta: [
    { title: 'Página no encontrada | Helios' },
    { name: 'robots', content: 'noindex' },
    { name: 'color-scheme', content: 'light' },
  ],
  links: [FUENTES_DE_LA_PORTADA],
}

export function NoEncontrada() {
  return (
    <div className="portada-raiz min-h-screen">
      <Menu />
      <main>
        <section className="relative bg-white">
          <Lienzo className="flex flex-col items-center pb-24 pt-40 text-center sm:pt-48">
            <span className="directorio-icono grid size-14 place-items-center rounded-[18px] text-portada-azul">
              <Search className="size-6" strokeWidth={1.75} aria-hidden />
            </span>
            <h1 className="mt-6 max-w-[24ch] text-[clamp(1.6rem,1.2rem+1.6vw,2.4rem)] font-medium leading-tight tracking-[-0.04em] text-portada-tinta">
              Esta página ya no está en el directorio
            </h1>
            <p className="mt-4 max-w-[48ch] text-[1rem] leading-relaxed text-portada-tinta-2">
              Puede que el médico ya no salga o que el enlace esté mal escrito. En el directorio están todos
              los médicos que aceptan Helios.
            </p>
            <div className="mt-9">
              <Boton to="/directorio">Ver el directorio</Boton>
            </div>
          </Lienzo>
        </section>
      </main>
      <Pie />
    </div>
  )
}
