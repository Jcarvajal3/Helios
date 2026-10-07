import { useEffect, useRef } from 'react'

/**
 * EL CAMPO DE PUNTOS — el semitono animado de la portada.
 * ══════════════════════════════════════════════════════════════════════════
 *
 * WebGL a mano, sin librerías, con dos escenas:
 *
 *   · `sol`   — la esfera de Helios con sus rayos, como el isotipo, sombreada
 *               en 3D y dibujada con puntos. La luz y los rayos se abren
 *               hacia el cursor, y los puntos se agrandan alrededor de él.
 *   · `marea` — un campo de ruido que fluye despacio, para el fondo de las
 *               tarjetas y del bloque oscuro de los médicos.
 *
 * Se pinta en dos pasadas. La primera calcula la escena UNA vez por celda de
 * la rejilla, en una textura diminuta (un lienzo de 1440 × 900 con celdas de
 * 7 px son ~26 000 celdas, no 1,3 millones de píxeles). La segunda dibuja en
 * cada celda un punto cuyo radio es la densidad de ese sitio: así se ve como
 * una impresión en semitono, y no como un degradado.
 *
 * Solo pinta cuando se ve (IntersectionObserver) y con la pestaña al frente.
 * Con «reducir movimiento» dibuja un fotograma y se queda quieto. Si no hay
 * WebGL el lienzo queda vacío y manda el fondo que ponga quien lo usa.
 */

export type Escena = 'sol' | 'marea'

type Props = {
  escena: Escena
  /** Lado de la celda de la rejilla, en px CSS. */
  celda?: number
  /** Tres tintas, de la más oscura a la más clara. */
  tintas?: readonly [string, string, string]
  /** Fondo del lienzo (`transparent` deja ver la página). */
  fondo?: string
  /** Centro del sol, en fracciones del lienzo (x a la derecha, y hacia arriba). */
  foco?: readonly [number, number]
  /** Radio del sol, en fracciones del alto del lienzo. */
  radio?: number
  /** Hacia dónde se abren los rayos sin cursor (vector unitario, y hacia arriba). */
  luz?: readonly [number, number]
  /** Desfase del ruido, para que dos tarjetas no se vean iguales. */
  semilla?: number
  /** Cuánto llenan los puntos (0–1). */
  intensidad?: number
  /** El cursor mueve la luz y abre una lupa de puntos. */
  interactivo?: boolean
  className?: string
}

const VERTICES = `
attribute vec2 a_pos;
void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }
`

/** Pasada 1: la escena, una vez por celda. Sale (densidad, tono) en r y g. */
const ESCENA = `
precision highp float;

uniform vec2  u_res;
uniform float u_cell;
uniform float u_time;
uniform vec2  u_mouse;
uniform float u_hover;
uniform int   u_scene;
uniform vec2  u_focus;
uniform float u_radius;
uniform float u_seed;
uniform vec2  u_luz;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= 0.5;
  }
  return v;
}

vec2 escenaSol(vec2 uv, float aspect) {
  vec2 q = (uv - u_focus) * vec2(aspect, 1.0);
  float r = u_radius;
  float dist = length(q);
  float t = u_time;

  // La luz sale de donde está el cursor o, sin él, de u_luz.
  vec2 m = (u_mouse - u_focus) * vec2(aspect, 1.0);
  vec2 haciaLuz = normalize(mix(u_luz, normalize(m + 1e-4), u_hover * 0.9));
  vec3 L = normalize(vec3(haciaLuz, 0.8));

  // La esfera.
  vec2 qn = q / r;
  vec3 n = vec3(qn, sqrt(max(0.0, 1.0 - dot(qn, qn))));
  float luz = clamp(dot(n, L), 0.0, 1.0);
  float borde = pow(1.0 - n.z, 3.0);
  float plasma = fbm(n.xy * 2.2 + vec2(t * 0.045 + u_seed, -t * 0.03));
  float brillo = pow(clamp(dot(reflect(-L, n), vec3(0.0, 0.0, 1.0)), 0.0, 1.0), 12.0);
  float dEsfera = 0.12 + 0.62 * (1.0 - luz) + 0.3 * (plasma - 0.5) + 0.18 * borde;
  dEsfera = clamp(dEsfera * (1.0 - brillo * 0.75), 0.0, 1.0);

  // Los rayos: un abanico que mira hacia la luz, gira muy despacio y respira.
  vec2 dir = q / max(dist, 1e-4);
  float ang = atan(q.y, q.x);
  float onda = sin(dist * 7.0 - t * 0.8) * 0.12;
  float haz = pow(0.5 + 0.5 * cos(ang * 12.0 + t * 0.05 + onda), 26.0);
  float abanico = smoothstep(-0.35, 0.95, dot(dir, haciaLuz));
  float largo = exp(-max(dist - r, 0.0) * mix(7.0, 2.8, abanico));
  float fuera = smoothstep(r + 0.006, r + 0.05, dist);
  float corona = exp(-max(dist - r, 0.0) * 34.0) * 0.4;
  float grano = fbm(uv * vec2(aspect, 1.0) * 5.0 + vec2(t * 0.05, t * 0.02) + u_seed);
  float dRayos = fuera * (largo * (haz * (0.15 + 0.85 * abanico) * 0.8 + 0.02) + corona
               + largo * 0.14 * smoothstep(0.6, 0.85, grano));

  // La lupa del cursor.
  float dm = length((uv - u_mouse) * vec2(aspect, 1.0));
  float lupa = u_hover * exp(-dm * dm * 90.0) * 0.6;

  bool dentro = dist < r;
  float d = dentro ? dEsfera : dRayos;
  d = clamp(d + lupa * (1.0 - d), 0.0, 1.0);

  float tono = dentro ? (0.95 - 0.7 * (1.0 - luz) + 0.12 * plasma) : 0.5 + 0.5 * (1.0 - largo);
  return vec2(d, tono);
}

vec2 escenaMarea(vec2 uv, float aspect) {
  vec2 p = uv * vec2(aspect, 1.0) * 2.2 + u_seed;
  float t = u_time * 0.07;
  vec2 w = vec2(fbm(p + vec2(t, -t * 0.6)), fbm(p + vec2(5.2 - t * 0.8, 1.3 + t)));
  float v = fbm(p + 2.4 * w + vec2(t * 0.5, 0.0));

  float dm = length((uv - u_mouse) * vec2(aspect, 1.0));
  float lupa = u_hover * exp(-dm * dm * 18.0) * 0.45;

  float d = smoothstep(0.32, 0.82, v) + lupa;
  // Más denso abajo, donde va el texto de la tarjeta.
  d *= mix(0.55, 1.0, smoothstep(0.0, 0.85, 1.15 - uv.y));
  return vec2(clamp(d, 0.0, 1.0), clamp(v + lupa, 0.0, 1.0));
}

void main() {
  // En esta pasada cada fragmento ES una celda: su centro, en px del lienzo.
  vec2 uv = gl_FragCoord.xy * u_cell / u_res;
  float aspect = u_res.x / u_res.y;
  vec2 e = u_scene == 0 ? escenaSol(uv, aspect) : escenaMarea(uv, aspect);
  gl_FragColor = vec4(e, 0.0, 1.0);
}
`

/** Pasada 2: un punto por celda, del tamaño que dice la textura. */
const PUNTOS = `
precision highp float;

uniform sampler2D u_escena;
uniform vec2  u_grid;
uniform float u_cell;
uniform float u_gain;
uniform vec3  u_c0;
uniform vec3  u_c1;
uniform vec3  u_c2;
uniform vec4  u_bg;

vec3 tinta(float t) {
  t = clamp(t, 0.0, 1.0);
  return t < 0.5 ? mix(u_c0, u_c1, t * 2.0) : mix(u_c1, u_c2, t * 2.0 - 1.0);
}

void main() {
  vec2 px = gl_FragCoord.xy;
  vec2 celda = floor(px / u_cell);
  vec2 centro = (celda + 0.5) * u_cell;
  vec2 e = texture2D(u_escena, (celda + 0.5) / u_grid).rg;
  float d = e.x * u_gain;

  float radio = sqrt(clamp(d, 0.0, 1.0)) * u_cell * 0.44;
  float a = (1.0 - smoothstep(radio - 0.75, radio + 0.75, length(px - centro))) * step(0.04, d);

  vec3 col = tinta(e.y);
  gl_FragColor = vec4(col * a + u_bg.rgb * u_bg.a * (1.0 - a), a + u_bg.a * (1.0 - a));
}
`

/** «#045EF3» → [0.016, 0.369, 0.953]. */
function rgb(hex: string): [number, number, number] {
  const h = hex.replace('#', '')
  const n = parseInt(h.length === 3 ? h.replace(/./g, '$&$&') : h, 16)
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255]
}

function rgba(color: string): [number, number, number, number] {
  return color === 'transparent' ? [0, 0, 0, 0] : [...rgb(color), 1]
}

function programa(gl: WebGLRenderingContext, fragmentos: string) {
  const compilar = (tipo: number, fuente: string) => {
    const s = gl.createShader(tipo)
    if (!s) return null
    gl.shaderSource(s, fuente)
    gl.compileShader(s)
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      console.warn('[portada] shader:', gl.getShaderInfoLog(s))
      return null
    }
    return s
  }
  const vs = compilar(gl.VERTEX_SHADER, VERTICES)
  const fs = compilar(gl.FRAGMENT_SHADER, fragmentos)
  if (!vs || !fs) return null
  const p = gl.createProgram()
  gl.attachShader(p, vs)
  gl.attachShader(p, fs)
  gl.bindAttribLocation(p, 0, 'a_pos')
  gl.linkProgram(p)
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return null
  return p
}

export function CampoDePuntos({
  escena,
  celda = 7,
  tintas = ['#002770', '#045EF3', '#73C3FE'],
  fondo = 'transparent',
  foco = [0.5, 0.5],
  radio = 0.3,
  luz = [-0.62, 0.78],
  semilla = 0,
  intensidad = 1,
  interactivo = true,
  className = '',
}: Props) {
  const lienzo = useRef<HTMLCanvasElement>(null)

  // Los parámetros se leen en cada fotograma desde aquí: cambiarlos no
  // reinicia el contexto WebGL.
  const params = useRef({
    escena,
    celda,
    tintas,
    fondo,
    foco,
    radio,
    luz,
    semilla,
    intensidad,
  })
  params.current = {
    escena,
    celda,
    tintas,
    fondo,
    foco,
    radio,
    luz,
    semilla,
    intensidad,
  }

  useEffect(() => {
    const canvas = lienzo.current
    if (!canvas) return
    const gl = canvas.getContext('webgl', {
      alpha: true,
      premultipliedAlpha: true,
      antialias: false,
      depth: false,
      stencil: false,
      powerPreference: 'low-power',
    })
    if (!gl) return

    const pEscena = programa(gl, ESCENA)
    const pPuntos = programa(gl, PUNTOS)
    if (!pEscena || !pPuntos) return

    // Un triángulo que cubre la pantalla entera.
    const buf = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buf)
    gl.bufferData(
      gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 3, -1, -1, 3]),
      gl.STATIC_DRAW,
    )
    gl.enableVertexAttribArray(0)
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0)

    const ue = (n: string) => gl.getUniformLocation(pEscena, n)
    const up = (n: string) => gl.getUniformLocation(pPuntos, n)
    const UE = {
      res: ue('u_res'),
      cell: ue('u_cell'),
      time: ue('u_time'),
      mouse: ue('u_mouse'),
      hover: ue('u_hover'),
      scene: ue('u_scene'),
      focus: ue('u_focus'),
      radius: ue('u_radius'),
      seed: ue('u_seed'),
      luz: ue('u_luz'),
    }
    const UP = {
      escena: up('u_escena'),
      grid: up('u_grid'),
      cell: up('u_cell'),
      gain: up('u_gain'),
      c0: up('u_c0'),
      c1: up('u_c1'),
      c2: up('u_c2'),
      bg: up('u_bg'),
    }

    // La textura de la escena: una celda, un texel.
    const tex = gl.createTexture()
    gl.bindTexture(gl.TEXTURE_2D, tex)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    const fbo = gl.createFramebuffer()

    const quieto = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    let dpr = 1
    let cols = 1
    let filas = 1
    let celdaPx = 1

    const redimensionar = () => {
      dpr = Math.min(window.devicePixelRatio || 1, 2)
      const w = Math.max(1, Math.round(canvas.clientWidth * dpr))
      const h = Math.max(1, Math.round(canvas.clientHeight * dpr))
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w
        canvas.height = h
      }
      celdaPx = Math.max(2, params.current.celda * dpr)
      const c = Math.ceil(w / celdaPx)
      const f = Math.ceil(h / celdaPx)
      if (c !== cols || f !== filas) {
        cols = c
        filas = f
        gl.bindTexture(gl.TEXTURE_2D, tex)
        gl.texImage2D(
          gl.TEXTURE_2D,
          0,
          gl.RGBA,
          cols,
          filas,
          0,
          gl.RGBA,
          gl.UNSIGNED_BYTE,
          null,
        )
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo)
        gl.framebufferTexture2D(
          gl.FRAMEBUFFER,
          gl.COLOR_ATTACHMENT0,
          gl.TEXTURE_2D,
          tex,
          0,
        )
        gl.bindFramebuffer(gl.FRAMEBUFFER, null)
      }
    }

    // El cursor, suavizado: la luz llega a donde está, no salta.
    const raton = { x: 0.5, y: 0.5, tx: 0.5, ty: 0.5, h: 0, th: 0 }
    const alMover = (e: PointerEvent) => {
      const r = canvas.getBoundingClientRect()
      const x = (e.clientX - r.left) / r.width
      const y = 1 - (e.clientY - r.top) / r.height
      raton.tx = x
      raton.ty = y
      raton.th = x > -0.05 && x < 1.05 && y > -0.05 && y < 1.05 ? 1 : 0
    }
    const alSalir = () => {
      raton.th = 0
    }
    if (interactivo && !quieto) {
      window.addEventListener('pointermove', alMover, { passive: true })
      document.documentElement.addEventListener('pointerleave', alSalir)
    }

    let visible = false
    let raf = 0
    let ultimo = performance.now()
    let tiempo = 3 + params.current.semilla * 7

    const pintar = () => {
      const p = params.current
      if (Math.abs(p.celda * dpr - celdaPx) > 0.01) {
        cols = 0
        redimensionar()
      }

      // 1 · La escena, en la textura.
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo)
      gl.viewport(0, 0, cols, filas)
      gl.useProgram(pEscena)
      gl.uniform2f(UE.res, canvas.width, canvas.height)
      gl.uniform1f(UE.cell, celdaPx)
      gl.uniform1f(UE.time, tiempo)
      gl.uniform2f(UE.mouse, raton.x, raton.y)
      gl.uniform1f(UE.hover, raton.h)
      gl.uniform1i(UE.scene, p.escena === 'sol' ? 0 : 1)
      gl.uniform2f(UE.focus, p.foco[0], p.foco[1])
      gl.uniform1f(UE.radius, p.radio)
      gl.uniform1f(UE.seed, p.semilla)
      gl.uniform2f(UE.luz, p.luz[0], p.luz[1])
      gl.drawArrays(gl.TRIANGLES, 0, 3)

      // 2 · Los puntos, en el lienzo.
      gl.bindFramebuffer(gl.FRAMEBUFFER, null)
      gl.viewport(0, 0, canvas.width, canvas.height)
      gl.useProgram(pPuntos)
      const [c0, c1, c2] = p.tintas.map(rgb)
      gl.activeTexture(gl.TEXTURE0)
      gl.bindTexture(gl.TEXTURE_2D, tex)
      gl.uniform1i(UP.escena, 0)
      gl.uniform2f(UP.grid, cols, filas)
      gl.uniform1f(UP.cell, celdaPx)
      gl.uniform1f(UP.gain, p.intensidad)
      gl.uniform3fv(UP.c0, c0)
      gl.uniform3fv(UP.c1, c1)
      gl.uniform3fv(UP.c2, c2)
      gl.uniform4fv(UP.bg, rgba(p.fondo))
      gl.clearColor(0, 0, 0, 0)
      gl.clear(gl.COLOR_BUFFER_BIT)
      gl.drawArrays(gl.TRIANGLES, 0, 3)
    }

    const fotograma = (ahora: number) => {
      const dt = Math.min((ahora - ultimo) / 1000, 0.05)
      ultimo = ahora
      tiempo += dt
      const k = 1 - Math.pow(0.002, dt)
      raton.x += (raton.tx - raton.x) * k
      raton.y += (raton.ty - raton.y) * k
      raton.h += (raton.th - raton.h) * (1 - Math.pow(0.03, dt))
      pintar()
      raf = requestAnimationFrame(fotograma)
    }

    const arrancar = () => {
      if (quieto) {
        pintar()
        return
      }
      if (raf || !visible || document.hidden) return
      ultimo = performance.now()
      raf = requestAnimationFrame(fotograma)
    }
    const parar = () => {
      cancelAnimationFrame(raf)
      raf = 0
    }

    redimensionar()
    pintar()
    canvas.dataset.listo = ''

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
      document.removeEventListener('visibilitychange', alCambiarPestana)
      window.removeEventListener('pointermove', alMover)
      document.documentElement.removeEventListener('pointerleave', alSalir)
      gl.getExtension('WEBGL_lose_context')?.loseContext()
    }
    // El contexto se crea una vez; los parámetros viajan por `params`.
  }, [interactivo])

  return (
    <canvas
      ref={lienzo}
      aria-hidden
      className={`portada-lienzo pointer-events-none block size-full ${className}`}
    />
  )
}
