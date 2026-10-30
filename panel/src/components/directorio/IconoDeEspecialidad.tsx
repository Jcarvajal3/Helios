import {
  Activity,
  Apple,
  Baby,
  Bandage,
  Bean,
  Bone,
  BrainCircuit,
  BrainCog,
  BriefcaseMedical,
  Brain,
  Cross,
  Dna,
  Droplet,
  Droplets,
  Ear,
  Eye,
  FlaskRound,
  Footprints,
  Hand,
  HandHeart,
  HeartPlus,
  HeartPulse,
  Hospital,
  Microscope,
  PersonStanding,
  Ribbon,
  ScanFace,
  ScanLine,
  Scissors,
  ShieldPlus,
  Smile,
  SmilePlus,
  Soup,
  Sparkles,
  Stethoscope,
  Syringe,
  TestTubes,
  ToyBrick,
  Venus,
  WandSparkles,
  Wind,
} from 'lucide-react'
import type { ComponentType } from 'react'

import type { ClaveDeEspecialidad } from '@/features/directorio/especialidades'

type PropsDeIcono = { className?: string; strokeWidth?: number; 'aria-hidden'?: boolean }

/**
 * Un diente, con el trazo de lucide (que no trae ninguno): la odontología es
 * un tercio de las clínicas y un estetoscopio no la dice.
 */
function Diente({ className, strokeWidth = 2 }: PropsDeIcono) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden
    >
      <path d="M7.5 3C5 3 3.5 4.9 3.5 7.6c0 2.3.6 4.2 1.2 6 .6 1.9 1 3.9 1.4 5.8.3 1.4 1 2.1 1.9 2.1 1 0 1.5-.8 1.8-2.2l.6-3c.2-1 .8-1.6 1.6-1.6s1.4.6 1.6 1.6l.6 3c.3 1.4.8 2.2 1.8 2.2.9 0 1.6-.7 1.9-2.1.4-1.9.8-3.9 1.4-5.8.6-1.8 1.2-3.7 1.2-6C20.5 4.9 19 3 16.5 3c-1.7 0-2.9.9-4.5.9S9.2 3 7.5 3z" />
      <path d="M9 7.3c1 .4 2 .6 3 .6s2-.2 3-.6" />
    </svg>
  )
}

const ICONOS: Record<ClaveDeEspecialidad, ComponentType<PropsDeIcono>> = {
  anatomia_patologica: TestTubes,
  angiologia: Footprints,
  cardiologia: HeartPulse,
  cirugia_cardiaca: HeartPlus,
  cirugia_craneofacial: SmilePlus,
  cirugia_general: Scissors,
  cirugia_oncologica: Cross,
  cirugia_maxilofacial: Diente,
  cirugia_pediatrica: ToyBrick,
  cirugia_plastica: WandSparkles,
  cirugia_toracica: Bandage,
  coloproctologia: Microscope,
  cosmetologia: Sparkles,
  dermatologia: ScanFace,
  endocrinologia: Dna,
  enfermeria: BriefcaseMedical,
  fisioterapia: PersonStanding,
  gastroenterologia: Soup,
  ginecologia: Venus,
  hematologia: Droplet,
  hepatologia: FlaskRound,
  inmunologia: ShieldPlus,
  medicina_general: Stethoscope,
  medicina_interna: Activity,
  nefrologia: Bean,
  neumologia: Wind,
  neurocirugia: BrainCircuit,
  neurologia: Brain,
  nutricion: Apple,
  odontologia: Diente,
  oftalmologia: Eye,
  oncologia: Ribbon,
  ortodoncia: Smile,
  otorrinolaringologia: Ear,
  pediatria: Baby,
  psicologia: HandHeart,
  psiquiatria: BrainCog,
  radiologia: ScanLine,
  reumatologia: Hand,
  traumatologia: Bone,
  urologia: Droplets,
  vacunacion: Syringe,
  otra: Hospital,
}

/** El icono de una especialidad del directorio. Decorativo: el nombre va al lado. */
export function IconoDeEspecialidad({
  clave,
  className = 'size-5',
  strokeWidth = 1.75,
}: {
  clave: ClaveDeEspecialidad
  className?: string
  strokeWidth?: number
}) {
  const Icono = ICONOS[clave]
  return <Icono className={className} strokeWidth={strokeWidth} aria-hidden />
}
