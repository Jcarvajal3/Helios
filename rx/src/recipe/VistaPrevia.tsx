import type { CSSProperties, ReactNode } from 'react'

import type { DatosRecipe, Doctor } from '../modelo.ts'
import { fechaLatina, hayIndicaciones, sanearTexto } from './pdf.ts'
import { numeroLargo } from './util.ts'

// La vista previa del PDF en HTML: las medidas son las de recipe/pdf.ts, en
// puntos (`u(11)` son 11 pt de la hoja, escalados al ancho disponible).
const u = (n: number) => `calc(var(--u) * ${n})`

const AZUL = '#0040b8'
const GRIS = '#44506a'
const FILETE = '#d3dae5'

function unir(partes: Array<[string, string]>): string {
  return partes
    .filter(([, valor]) => valor.trim())
    .map(([rotulo, valor]) => (rotulo ? `${rotulo} ${valor.trim()}` : valor.trim()))
    .join(' · ')
}

function Encabezado({ doctor, logoUrl }: { doctor: Doctor; logoUrl: string | null }) {
  const credenciales = unir([
    ['C.I.', doctor.cedula],
    ['MPPS', doctor.mpps],
    ['C.M.', doctor.colegio],
  ])
  return (
    <header
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: u(10),
        paddingBottom: u(9),
        borderBottom: `${u(0.8)} solid ${AZUL}`,
      }}
    >
      {logoUrl && (
        <img
          src={logoUrl}
          alt=""
          style={{ width: u(46), height: u(46), objectFit: 'contain', flexShrink: 0 }}
        />
      )}
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: u(13), fontWeight: 700, lineHeight: 1.2 }}>{doctor.nombre}</div>
        {doctor.especialidad && (
          <div style={{ fontSize: u(9), color: GRIS, marginTop: u(2) }}>{doctor.especialidad}</div>
        )}
        {credenciales && (
          <div style={{ fontSize: u(7.5), color: GRIS, marginTop: u(2) }}>{credenciales}</div>
        )}
      </div>
    </header>
  )
}

function FranjaDelPaciente({ datos }: { datos: DatosRecipe }) {
  const { paciente, numero, fecha } = datos
  const estilo: CSSProperties = { fontSize: u(8.5), lineHeight: 1.4 }
  const rotulo: CSSProperties = { color: GRIS }
  return (
    <div
      style={{
        display: 'flex',
        justifyContent: 'space-between',
        gap: u(12),
        padding: `${u(8)} 0`,
        borderBottom: `${u(0.5)} solid ${FILETE}`,
      }}
    >
      <div style={{ minWidth: 0, ...estilo }}>
        <div>
          <span style={rotulo}>Paciente: </span>
          <b>{paciente.nombre || '—'}</b>
        </div>
        {(paciente.documento || paciente.edad) && (
          <div>
            {paciente.documento && (
              <>
                <span style={rotulo}>C.I.: </span>
                {paciente.documento}
              </>
            )}
            {paciente.documento && paciente.edad && '   '}
            {paciente.edad && (
              <>
                <span style={rotulo}>Edad: </span>
                {paciente.edad}
              </>
            )}
          </div>
        )}
      </div>
      <div style={{ flexShrink: 0, textAlign: 'right', ...estilo }}>
        <div>
          <span style={rotulo}>Fecha: </span>
          <b>{fechaLatina(fecha)}</b>
        </div>
        {numero !== null && (
          <div>
            <span style={rotulo}>N.º </span>
            <b>{numeroLargo(numero)}</b>
          </div>
        )}
      </div>
    </div>
  )
}

function Pie({
  doctor,
  firmaUrl,
  hoja,
  hojas,
  alPedirFirma,
}: {
  doctor: Doctor
  firmaUrl: string | null
  hoja: number
  hojas: number
  alPedirFirma?: () => void
}) {
  const contacto = [doctor.consultorio, doctor.direccion, doctor.ciudad, doctor.telefono, doctor.correo]
    .map((x) => x.trim())
    .filter(Boolean)
    .join(' · ')
  return (
    <footer style={{ marginTop: 'auto', paddingTop: u(10) }}>
      <div style={{ marginLeft: 'auto', width: u(150), textAlign: 'center' }}>
        <div style={{ height: u(48), display: 'flex', alignItems: 'flex-end', justifyContent: 'center' }}>
          {firmaUrl ? (
            <img src={firmaUrl} alt="Tu firma" style={{ maxWidth: u(120), maxHeight: u(48), objectFit: 'contain' }} />
          ) : (
            alPedirFirma && (
              <button
                type="button"
                onClick={alPedirFirma}
                style={{ fontSize: u(8), color: AZUL, textDecoration: 'underline', padding: u(4) }}
              >
                Falta tu firma
              </button>
            )
          )}
        </div>
        <div style={{ borderTop: `${u(0.6)} solid #0f1a2e`, paddingTop: u(3), fontSize: u(8), fontWeight: 700 }}>
          {doctor.nombre}
        </div>
        {doctor.mpps && <div style={{ fontSize: u(7), color: GRIS }}>MPPS {doctor.mpps}</div>}
      </div>
      {contacto && (
        <div style={{ marginTop: u(9), fontSize: u(6.5), color: GRIS, textAlign: 'center', lineHeight: 1.35 }}>
          {contacto}
        </div>
      )}
      <div style={{ marginTop: u(3), fontSize: u(6), color: '#7b869c', textAlign: 'center' }}>
        Hoja {hoja} de {hojas}
      </div>
    </footer>
  )
}

function Hoja({
  datos,
  firmaUrl,
  logoUrl,
  hoja,
  hojas,
  alPedirFirma,
  children,
}: {
  datos: DatosRecipe
  firmaUrl: string | null
  logoUrl: string | null
  hoja: number
  hojas: number
  alPedirFirma?: () => void
  children: ReactNode
}) {
  return (
    <div className="hoja">
      <article className="hoja-papel">
        <Encabezado doctor={datos.doctor} logoUrl={logoUrl} />
        <FranjaDelPaciente datos={datos} />
        <div style={{ paddingTop: u(12) }}>{children}</div>
        <Pie doctor={datos.doctor} firmaUrl={firmaUrl} hoja={hoja} hojas={hojas} alPedirFirma={alPedirFirma} />
      </article>
    </div>
  )
}

export function VistaPrevia({
  datos: crudos,
  firmaUrl,
  logoUrl,
  alPedirFirma,
}: {
  datos: DatosRecipe
  firmaUrl: string | null
  logoUrl: string | null
  alPedirFirma?: () => void
}) {
  // Lo que el PDF no puede escribir (un emoji, por ejemplo) tampoco se enseña.
  const datos: DatosRecipe = {
    ...crudos,
    paciente: {
      ...crudos.paciente,
      nombre: sanearTexto(crudos.paciente.nombre),
      documento: sanearTexto(crudos.paciente.documento),
      edad: sanearTexto(crudos.paciente.edad),
    },
    medicamentos: crudos.medicamentos.map((m) => ({
      medicamento: sanearTexto(m.medicamento),
      presentacion: sanearTexto(m.presentacion),
      cantidad: sanearTexto(m.cantidad),
      indicacion: sanearTexto(m.indicacion),
    })),
    indicaciones: sanearTexto(crudos.indicaciones),
  }
  const medicamentos = datos.medicamentos.filter((m) => m.medicamento.trim())
  const conIndicacion = medicamentos.filter((m) => m.indicacion.trim())
  const conHojaDos = hayIndicaciones({ ...datos, medicamentos })
  const hojas = conHojaDos ? 2 : 1
  const comun = { datos, firmaUrl, logoUrl, hojas, alPedirFirma }

  return (
    <div className="flex flex-col gap-4">
      <Hoja {...comun} hoja={1}>
        <div style={{ fontFamily: 'Times New Roman, serif', fontStyle: 'italic', fontSize: u(22), color: AZUL, lineHeight: 1 }}>
          Rp.
        </div>
        <ol style={{ marginTop: u(10), display: 'grid', gap: u(8) }}>
          {medicamentos.length === 0 && (
            <li style={{ fontSize: u(9), color: '#7b869c' }}>Aquí aparecerán los medicamentos.</li>
          )}
          {medicamentos.map((m, i) => (
            <li key={i}>
              <div style={{ fontSize: u(10), fontWeight: 700 }}>
                {i + 1}. {m.medicamento}
              </div>
              {(m.presentacion || m.cantidad) && (
                <div style={{ fontSize: u(8.5), color: GRIS, marginTop: u(1.5), paddingLeft: u(12) }}>
                  {[m.presentacion, m.cantidad].filter((x) => x.trim()).join(' · ')}
                </div>
              )}
            </li>
          ))}
        </ol>
      </Hoja>

      {conHojaDos && (
        <Hoja {...comun} hoja={2}>
          <div style={{ fontSize: u(13), fontWeight: 700 }}>Indicaciones</div>
          <div style={{ marginTop: u(10), display: 'grid', gap: u(8) }}>
            {conIndicacion.map((m, i) => (
              <div key={i}>
                <div style={{ fontSize: u(9.5), fontWeight: 700 }}>{m.medicamento}</div>
                <div style={{ fontSize: u(9), marginTop: u(1.5), whiteSpace: 'pre-wrap', lineHeight: 1.35 }}>{m.indicacion}</div>
              </div>
            ))}
            {datos.indicaciones.trim() && (
              <div style={{ marginTop: u(4) }}>
                <div style={{ fontSize: u(9.5), fontWeight: 700 }}>Indicaciones generales</div>
                <div style={{ fontSize: u(9), marginTop: u(1.5), whiteSpace: 'pre-wrap', lineHeight: 1.35 }}>{datos.indicaciones}</div>
              </div>
            )}
          </div>
        </Hoja>
      )}
    </div>
  )
}
