import { useEffect, useRef } from 'react'

/**
 * LAS MANOS EN TRAMA — el fondo de la primera pantalla.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * Adaptado de «Dither Reveal», de la sección Hero 40 de Originkit
 * (`npx originkit add hero-40`), con su imagen `white-hands.png`, aquí
 * `public/portada/manos.jpg`.
 *
 * Una foto de dos manos que casi se tocan, pasada por una trama Bayer de 8×8
 * en tres tonos de azul de Helios. El fondo blanco de la foto se vuelve
 * transparente, una onda lenta la mece y, bajo el cursor, la trama se abre
 * y deja ver la foto original.
 *
 * Lo propio de Helios, frente al original: los azules de la marca, el cursor
 * se escucha en la ventana (el lienzo va debajo del texto y no recibe
 * eventos), deja de pintar fuera de pantalla o con la pestaña oculta y, con
 * «reducir movimiento», pinta un fotograma quieto.
 */

type Props = {
  src?: string
  /** Tono oscuro y claro de la trama. */
  tintas?: readonly [string, string]
  /** Lado del punto de la trama, en px CSS. */
  punto?: number
  /** Radio de la ventana que abre el cursor, en px CSS. */
  radioRevelado?: number
  /** Suavidad del borde de esa ventana (0–1). */
  suavidad?: number
  /** Altura de la foto que queda en el centro al recortar (0 abajo, 1 arriba). */
  focoY?: number
  className?: string
}

const VERTICES = `
attribute vec2 a_pos;
varying vec2 v_uv;
void main() {
  v_uv = a_pos * 0.5 + 0.5;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}
`

const FRAGMENTOS = `
precision highp float;

uniform sampler2D u_foto;
uniform float u_time;
uniform vec2  u_mouse;
uniform float u_activo;
uniform float u_radio;
uniform float u_suavidad;
uniform float u_punto;
uniform float u_aspectoLienzo;
uniform float u_aspectoFoto;
uniform vec2  u_res;
uniform float u_focoY;
uniform vec3  u_oscuro;
uniform vec3  u_claro;

varying vec2 v_uv;

const float VELOCIDAD = 0.82;
const float FRECUENCIA = 2.5;
const float AMPLITUD = 0.328;
const float MARGEN = 0.0492;

float bayer2(vec2 a) {
  a = floor(a);
  return fract(a.x * 0.5 + a.y * a.y * 0.75);
}
float bayer4(vec2 a) { return bayer2(a * 0.5) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(a * 0.5) * 0.25 + bayer2(a); }

// Tres tonos: el gris, empujado por el umbral de la matriz.
float trama(float gris) {
  float umbral = bayer8(gl_FragCoord.xy / u_punto);
  float v = gris + (umbral - 0.5) * 0.5;
  return v < 0.33 ? 0.0 : (v < 0.66 ? 0.5 : 1.0);
}

// Como background-size: cover, con un pequeño margen para la onda.
vec2 encajar(vec2 uv) {
  vec2 cubre = u_aspectoLienzo < u_aspectoFoto
    ? vec2(u_aspectoLienzo / u_aspectoFoto, 1.0)
    : vec2(1.0, u_aspectoFoto / u_aspectoLienzo);
  vec2 s = cubre / (1.0 + 2.0 * MARGEN);
  vec2 r = (uv - 0.5) * s + 0.5;
  r.y += (1.0 - s.y) * (0.5 - u_focoY) * step(s.y, 1.0);
  return r;
}

void main() {
  vec2 uv = v_uv;
  float fuerza = AMPLITUD * 0.1;
  float radioNorm = u_radio / max(min(u_res.x, u_res.y), 1.0);

  vec2 d = uv;
  d.x += sin(uv.y * FRECUENCIA + u_time * VELOCIDAD) * fuerza;
  d.y += sin(uv.x * FRECUENCIA * 0.7 + u_time * VELOCIDAD * 0.8) * fuerza * 0.5;

  if (u_activo > 0.01) {
    float dist = distance(uv, u_mouse);
    float influencia = smoothstep(radioNorm, 0.0, dist);
    float rizo = sin(dist * FRECUENCIA * 5.0 - u_time * VELOCIDAD)
      * AMPLITUD * 0.05 * influencia * u_activo;
    d += rizo;
  }

  vec2 m = encajar(d);
  vec4 color = texture2D(u_foto, m);
  vec2 dentro = step(vec2(0.0), m) * step(m, vec2(1.0));
  color *= dentro.x * dentro.y;

  float gris = dot(color.rgb, vec3(0.299, 0.587, 0.114));
  vec3 tinta = mix(u_oscuro, u_claro, trama(gris));

  float distPx = distance(uv * u_res, u_mouse * u_res);
  float interior = max(0.0, u_radio * (1.0 - u_suavidad));
  float exterior = u_radio * (1.0 + u_suavidad) + 0.001;
  float revelado = (1.0 - smoothstep(interior, exterior, distPx)) * u_activo;

  // Fuera el fondo blanco de la foto; la mano en reposo, en trama a medio
  // tono; bajo el cursor, la foto tal cual.
  float sujeto = smoothstep(0.035, 0.16, 1.0 - gris) * color.a;
  float alfa = mix(sujeto * 0.58, sujeto, revelado);
  gl_FragColor = vec4(mix(tinta, color.rgb, revelado), alfa);
}
`

function rgb(hex: string): [number, number, number] {
  const n = parseInt(hex.replace('#', ''), 16)
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255]
}

export function ManosEnTrama({
  src = '/portada/manos.jpg',
  tintas = ['#0A2F86', '#8CC4FF'],
  punto = 3.5,
  radioRevelado = 98,
  suavidad = 0.59,
  focoY = 0.5,
  className = '',
}: Props) {
  const lienzo = useRef<HTMLCanvasElement>(null)
  const params = useRef({ tintas, punto, radioRevelado, suavidad, focoY })
  params.current = { tintas, punto, radioRevelado, suavidad, focoY }

  useEffect(() => {
    const canvas = lienzo.current
    if (!canvas) return
    const gl = canvas.getContext('webgl', {
      antialias: false,
      premultipliedAlpha: false,
      depth: false,
      stencil: false,
      powerPreference: 'low-power',
    })
    if (!gl) return

    const compilar = (tipo: number, fuente: string) => {
      const s = gl.createShader(tipo)
      if (!s) return null
      gl.shaderSource(s, fuente)
      gl.compileShader(s)
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
        console.warn('[portada] manos:', gl.getShaderInfoLog(s))
        return null
      }
      return s
    }
    const vs = compilar(gl.VERTEX_SHADER, VERTICES)
    const fs = compilar(gl.FRAGMENT_SHADER, FRAGMENTOS)
    if (!vs || !fs) return
    const prog = gl.createProgram()
    gl.attachShader(prog, vs)
    gl.attachShader(prog, fs)
    gl.bindAttribLocation(prog, 0, 'a_pos')
    gl.linkProgram(prog)
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return
    gl.useProgram(prog)

    const buf = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buf)
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 3, -1, -1, 3]),
      gl.STATIC_DRAW,
    )
    gl.enableVertexAttribArray(0)
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)

    const u = (n: string) => gl.getUniformLocation(prog, n)
    const U = {
      time: u('u_time'),
      mouse: u('u_mouse'),
      activo: u('u_activo'),
      radio: u('u_radio'),
      suavidad: u('u_suavidad'),
      punto: u('u_punto'),
      aspectoLienzo: u('u_aspectoLienzo'),
      aspectoFoto: u('u_aspectoFoto'),
      res: u('u_res'),
      focoY: u('u_focoY'),
      oscuro: u('u_oscuro'),
      claro: u('u_claro'),
    }

    // Hasta que llegue la foto, un texel blanco: transparente, no se ve nada.
    const tex = gl.createTexture()
    gl.bindTexture(gl.TEXTURE_2D, tex)
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true)
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      gl.RGBA,
      1,
      1,
      0,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      new Uint8Array([255, 255, 255, 255]),
    )
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

    const quieto = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    let aspectoFoto = 1114 / 1411
    let raf = 0
    let visible = false
    let tiempo = 0
    let ultimo = performance.now()
    const raton = { x: 0.5, y: 0.5, activo: 0, meta: 0 }

    const redimensionar = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2)
      const w = Math.max(1, Math.floor(canvas.clientWidth * dpr))
      const h = Math.max(1, Math.floor(canvas.clientHeight * dpr))
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w
        canvas.height = h
      }
      gl.viewport(0, 0, w, h)
    }

    const pintar = () => {
      const p = params.current
      const dpr = canvas.width / Math.max(canvas.clientWidth, 1)
      gl.uniform1f(U.time, tiempo)
      gl.uniform2f(U.mouse, raton.x, raton.y)
      gl.uniform1f(U.activo, raton.activo)
      gl.uniform1f(U.radio, p.radioRevelado)
      gl.uniform1f(U.suavidad, p.suavidad)
      gl.uniform1f(U.punto, Math.max(p.punto * dpr, 0.25))
      gl.uniform1f(U.aspectoLienzo, canvas.width / canvas.height)
      gl.uniform1f(U.aspectoFoto, aspectoFoto)
      gl.uniform2f(U.res, canvas.clientWidth || 1, canvas.clientHeight || 1)
      gl.uniform1f(U.focoY, p.focoY)
      gl.uniform3fv(U.oscuro, rgb(p.tintas[0]))
      gl.uniform3fv(U.claro, rgb(p.tintas[1]))
      gl.drawArrays(gl.TRIANGLES, 0, 3)
    }

    const fotograma = (ahora: number) => {
      const dt = Math.min((ahora - ultimo) / 1000, 0.05)
      ultimo = ahora
      tiempo += dt
      raton.activo += (raton.meta - raton.activo) * (1 - Math.pow(0.0066, dt))
      pintar()
      raf = requestAnimationFrame(fotograma)
    }
    const arrancar = () => {
      if (quieto) return pintar()
      if (raf || !visible || document.hidden) return
      ultimo = performance.now()
      raf = requestAnimationFrame(fotograma)
    }
    const parar = () => {
      cancelAnimationFrame(raf)
      raf = 0
    }

    const foto = new Image()
    foto.decoding = 'async'
    foto.onload = () => {
      if (foto.naturalHeight > 0)
        aspectoFoto = foto.naturalWidth / foto.naturalHeight
      gl.bindTexture(gl.TEXTURE_2D, tex)
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, foto)
      canvas.dataset.listo = ''
      if (!raf) pintar()
    }
    foto.src = src

    const alMover = (e: PointerEvent) => {
      if (e.pointerType === 'touch') return
      const r = canvas.getBoundingClientRect()
      raton.x = (e.clientX - r.left) / r.width
      raton.y = 1 - (e.clientY - r.top) / r.height
      raton.meta =
        raton.x >= 0 && raton.x <= 1 && raton.y >= 0 && raton.y <= 1 ? 1 : 0
    }
    const alSalir = () => {
      raton.meta = 0
    }
    if (!quieto) {
      window.addEventListener('pointermove', alMover, { passive: true })
      document.documentElement.addEventListener('pointerleave', alSalir)
    }

    redimensionar()
    pintar()

    const io = new IntersectionObserver(([e]) => {
      visible = e.isIntersecting
      if (visible) arrancar()
      else parar()
    })
    io.observe(canvas)
    const ro = new ResizeObserver(() => {
      redimensionar()
      if (!raf) pintar()
    })
    ro.observe(canvas)
    const alCambiarPestana = () => (document.hidden ? parar() : arrancar())
    document.addEventListener('visibilitychange', alCambiarPestana)

    return () => {
      parar()
      io.disconnect()
      ro.disconnect()
      foto.onload = null
      document.removeEventListener('visibilitychange', alCambiarPestana)
      window.removeEventListener('pointermove', alMover)
      document.documentElement.removeEventListener('pointerleave', alSalir)
      gl.getExtension('WEBGL_lose_context')?.loseContext()
    }
  }, [src])

  return (
    <canvas
      ref={lienzo}
      aria-hidden
      className={`pointer-events-none block size-full ${className}`}
    />
  )
}
