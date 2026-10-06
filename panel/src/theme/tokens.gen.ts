/**
 * ARCHIVO GENERADO — NO EDITAR A MANO.
 *
 * Fuente: tokens/helios.tokens.json
 * Regenerar: node tokens/build.mjs   (o `npm run tokens` desde panel/)
 *
 * Basado en Material 3 Expressive. Los valores de shape, tipografía, motion,
 * state y sizing están verificados contra androidx.compose.material3.
 * Los colores salen del logo de Helios, no de la regla tonal de M3.
 */

// ─── Color ──────────────────────────────────────────────────────────────────

/** Hex crudos del logo. Prefiere `colorRoles` en componentes. */
export const brand = {
  "wordmark": "#002770",
  "blue": "#045EF3",
  "blueIsologo": "#157EFD",
  "blueLight": "#1F99FE",
  "sky": "#45A8FD",
  "skyBright": "#4EADFD",
  "skyLight": "#73C3FE"
} as const;

/**
 * Roles semánticos M3 del tema CLARO, el de por defecto. En el DOM manda el
 * CSS (`var(--color-*)`, que cambia con el tema); esto es para lo que no
 * puede leer una variable, como un canvas.
 */
export const colorRoles = {
  "primary": "#0040B8",
  "onPrimary": "#FFFFFF",
  "primaryContainer": "#DCE8FF",
  "onPrimaryContainer": "#00205E",
  "primaryDim": "#00338F",
  "primaryBright": "#015CF1",
  "secondary": "#0057D9",
  "onSecondary": "#FFFFFF",
  "secondaryContainer": "#E3F1FF",
  "onSecondaryContainer": "#00306E",
  "secondaryDim": "#0046AE",
  "secondaryBright": "#0B6FFB",
  "surface": "#FFFFFF",
  "surfaceDim": "#DDE3EC",
  "surfaceBright": "#FFFFFF",
  "surfaceContainerLowest": "#F3F6FB",
  "surfaceContainerLow": "#FFFFFF",
  "surfaceContainer": "#F7F9FC",
  "surfaceContainerHigh": "#EDF1F7",
  "surfaceContainerHighest": "#E4EAF2",
  "onSurface": "#0F1A2E",
  "onSurfaceVariant": "#44506A",
  "onSurfaceFaint": "#66728B",
  "placeholder": "#7B869C",
  "inverseSurface": "#1B2436",
  "onInverseSurface": "#F2F5FA",
  "outline": "#7D889E",
  "outlineVariant": "#D3DAE5",
  "error": "#C4221B",
  "onError": "#FFFFFF",
  "errorContainer": "#FDE8E6",
  "onErrorContainer": "#7A120D",
  "errorDim": "#9E1B15",
  "warning": "#A55300",
  "onWarning": "#FFFFFF",
  "warningContainer": "#FFF0DA",
  "onWarningContainer": "#5E3000",
  "success": "#1A7A3A",
  "onSuccess": "#FFFFFF",
  "successContainer": "#E2F4E7",
  "onSuccessContainer": "#0C4420",
  "scrim": "#0A1020",
  "shadow": "#0A1020",
  "logoWordmark": "#002770"
} as const;

/** Los mismos roles en el tema oscuro. */
export const colorRolesDark = {
  "primary": "#8FC8FF",
  "onPrimary": "#00214F",
  "primaryContainer": "#0B3E8C",
  "onPrimaryContainer": "#D9ECFF",
  "primaryDim": "#62A9F2",
  "primaryBright": "#C0E3FF",
  "secondary": "#A5D8FE",
  "onSecondary": "#002A55",
  "secondaryContainer": "#123A6B",
  "onSecondaryContainer": "#D6EBFF",
  "secondaryDim": "#78B8F0",
  "secondaryBright": "#C0E3FF",
  "surface": "#0E1626",
  "surfaceDim": "#0A0F1A",
  "surfaceBright": "#2A3A58",
  "surfaceContainerLowest": "#0A101C",
  "surfaceContainerLow": "#111A2B",
  "surfaceContainer": "#152033",
  "surfaceContainerHigh": "#1C2940",
  "surfaceContainerHighest": "#243350",
  "onSurface": "#EEF3FB",
  "onSurfaceVariant": "#B3BFD4",
  "onSurfaceFaint": "#8591A9",
  "placeholder": "#8E99AF",
  "inverseSurface": "#EEF3FB",
  "onInverseSurface": "#111A2B",
  "outline": "#7F8BA3",
  "outlineVariant": "#2A3650",
  "error": "#FF6F63",
  "onError": "#2B0300",
  "errorContainer": "#5C1611",
  "onErrorContainer": "#FFD8D3",
  "errorDim": "#D9463B",
  "warning": "#FFB84D",
  "onWarning": "#2A1700",
  "warningContainer": "#4A3000",
  "onWarningContainer": "#FFDFA6",
  "success": "#4CD27A",
  "onSuccess": "#04210E",
  "successContainer": "#10441F",
  "onSuccessContainer": "#A8F0C0",
  "scrim": "#000000",
  "shadow": "#000000",
  "logoWordmark": "#EAF3FF"
} as const;

// ─── Tipografía ─────────────────────────────────────────────────────────────

export const fontFamilies = {
  "display": "'Outfit', system-ui, -apple-system, 'Segoe UI', sans-serif",
  "body": "'Source Sans 3', system-ui, -apple-system, 'Segoe UI', sans-serif"
} as const;

export const fontWeights = {
  "regular": 400,
  "medium": 500,
  "semibold": 600,
  "bold": 700,
  "black": 900
} as const;

/** Los 15 roles tipográficos de M3 x 2 énfasis. `family` + `fontWeight` con `fontFamilies`. */
export const type = {
  "displayLarge": {
    "family": "display",
    "fontSize": 57,
    "lineHeight": 64,
    "letterSpacing": -0.25,
    "fontWeight": 400
  },
  "displayLargeEmphasized": {
    "family": "display",
    "fontSize": 57,
    "lineHeight": 64,
    "letterSpacing": 0,
    "fontWeight": 500
  },
  "displayMedium": {
    "family": "display",
    "fontSize": 45,
    "lineHeight": 52,
    "letterSpacing": 0,
    "fontWeight": 400
  },
  "displayMediumEmphasized": {
    "family": "display",
    "fontSize": 45,
    "lineHeight": 52,
    "letterSpacing": 0,
    "fontWeight": 500
  },
  "displaySmall": {
    "family": "display",
    "fontSize": 36,
    "lineHeight": 44,
    "letterSpacing": 0,
    "fontWeight": 400
  },
  "displaySmallEmphasized": {
    "family": "display",
    "fontSize": 36,
    "lineHeight": 44,
    "letterSpacing": 0,
    "fontWeight": 500
  },
  "headlineLarge": {
    "family": "display",
    "fontSize": 32,
    "lineHeight": 40,
    "letterSpacing": 0,
    "fontWeight": 400
  },
  "headlineLargeEmphasized": {
    "family": "display",
    "fontSize": 32,
    "lineHeight": 40,
    "letterSpacing": 0,
    "fontWeight": 500
  },
  "headlineMedium": {
    "family": "display",
    "fontSize": 28,
    "lineHeight": 36,
    "letterSpacing": 0,
    "fontWeight": 400
  },
  "headlineMediumEmphasized": {
    "family": "display",
    "fontSize": 28,
    "lineHeight": 36,
    "letterSpacing": 0,
    "fontWeight": 500
  },
  "headlineSmall": {
    "family": "display",
    "fontSize": 24,
    "lineHeight": 32,
    "letterSpacing": 0,
    "fontWeight": 400
  },
  "headlineSmallEmphasized": {
    "family": "display",
    "fontSize": 24,
    "lineHeight": 32,
    "letterSpacing": 0,
    "fontWeight": 500
  },
  "titleLarge": {
    "family": "display",
    "fontSize": 22,
    "lineHeight": 28,
    "letterSpacing": 0,
    "fontWeight": 400
  },
  "titleLargeEmphasized": {
    "family": "display",
    "fontSize": 22,
    "lineHeight": 28,
    "letterSpacing": 0,
    "fontWeight": 500
  },
  "titleMedium": {
    "family": "display",
    "fontSize": 16,
    "lineHeight": 24,
    "letterSpacing": 0.15,
    "fontWeight": 500
  },
  "titleMediumEmphasized": {
    "family": "display",
    "fontSize": 16,
    "lineHeight": 24,
    "letterSpacing": 0.15,
    "fontWeight": 700
  },
  "titleSmall": {
    "family": "display",
    "fontSize": 14,
    "lineHeight": 20,
    "letterSpacing": 0.1,
    "fontWeight": 500
  },
  "titleSmallEmphasized": {
    "family": "display",
    "fontSize": 14,
    "lineHeight": 20,
    "letterSpacing": 0.1,
    "fontWeight": 700
  },
  "bodyLarge": {
    "family": "body",
    "fontSize": 16,
    "lineHeight": 24,
    "letterSpacing": 0.5,
    "fontWeight": 400
  },
  "bodyLargeEmphasized": {
    "family": "body",
    "fontSize": 16,
    "lineHeight": 24,
    "letterSpacing": 0.15,
    "fontWeight": 500
  },
  "bodyMedium": {
    "family": "body",
    "fontSize": 14,
    "lineHeight": 20,
    "letterSpacing": 0.25,
    "fontWeight": 400
  },
  "bodyMediumEmphasized": {
    "family": "body",
    "fontSize": 14,
    "lineHeight": 20,
    "letterSpacing": 0.25,
    "fontWeight": 500
  },
  "bodySmall": {
    "family": "body",
    "fontSize": 12,
    "lineHeight": 16,
    "letterSpacing": 0.4,
    "fontWeight": 400
  },
  "bodySmallEmphasized": {
    "family": "body",
    "fontSize": 12,
    "lineHeight": 16,
    "letterSpacing": 0.4,
    "fontWeight": 500
  },
  "labelLarge": {
    "family": "body",
    "fontSize": 14,
    "lineHeight": 20,
    "letterSpacing": 0.1,
    "fontWeight": 500
  },
  "labelLargeEmphasized": {
    "family": "body",
    "fontSize": 14,
    "lineHeight": 20,
    "letterSpacing": 0.1,
    "fontWeight": 700
  },
  "labelMedium": {
    "family": "body",
    "fontSize": 12,
    "lineHeight": 16,
    "letterSpacing": 0.5,
    "fontWeight": 500
  },
  "labelMediumEmphasized": {
    "family": "body",
    "fontSize": 12,
    "lineHeight": 16,
    "letterSpacing": 0.5,
    "fontWeight": 700
  },
  "labelSmall": {
    "family": "body",
    "fontSize": 11,
    "lineHeight": 16,
    "letterSpacing": 0.5,
    "fontWeight": 500
  },
  "labelSmallEmphasized": {
    "family": "body",
    "fontSize": 11,
    "lineHeight": 16,
    "letterSpacing": 0.5,
    "fontWeight": 700
  }
} as const;

export type TypeRole = keyof typeof type;

// ─── Shape ──────────────────────────────────────────────────────────────────

export const shape = {
  "none": 0,
  "extraSmall": 4,
  "small": 8,
  "medium": 12,
  "large": 16,
  "largeIncreased": 20,
  "extraLarge": 28,
  "extraLargeIncreased": 32,
  "extraExtraLarge": 48,
  "full": 999
} as const;

export type ShapeKey = keyof typeof shape;

// ─── Espaciado y layout ─────────────────────────────────────────────────────

/** Grid de 4dp de M3. La clave es el multiplicador: `space[4] === 16 === p-4`. */
export const space = {
  "0": 0,
  "1": 4,
  "2": 8,
  "3": 12,
  "4": 16,
  "5": 20,
  "6": 24,
  "7": 28,
  "8": 32,
  "10": 40,
  "12": 48,
  "14": 56,
  "16": 64,
  "20": 80,
  "24": 96
} as const;

export const layout = {
  "breakpoint": {
    "compact": 0,
    "medium": 600,
    "expanded": 840,
    "large": 1200,
    "extraLarge": 1600
  },
  "margin": {
    "compact": 16,
    "medium": 24,
    "expanded": 24,
    "large": 24,
    "extraLarge": 24
  },
  "paneSpacing": 24,
  "touchTarget": 48
} as const;

// ─── Armazón ────────────────────────────────────────────────────────────────

/**
 * La capa semántica que comparten todas las pantallas: qué superficie, qué
 * radio, qué medida y qué hueco le toca a cada tipo de pieza. Las superficies
 * son las del tema claro; en el DOM se leen del CSS, que cambia con el tema.
 */
export const shell = {
  "surface": {
    "canvas": "#F3F6FB",
    "card": "#FFFFFF",
    "control": "#EDF1F7",
    "inset": "#E4EAF2",
    "bar": "#FFFFFF"
  },
  "radius": {
    "card": 28,
    "control": 999,
    "pressedCard": 16
  },
  "shapeKey": {
    "card": "extraLarge",
    "control": "full",
    "pressedCard": "large"
  },
  "padding": {
    "card": 20,
    "control": 20,
    "row": 16
  },
  "size": {
    "control": 56,
    "chip": 40,
    "avatar": 44,
    "meter": 10
  },
  "gap": {
    "tight": 4,
    "inner": 12,
    "group": 20,
    "block": 32,
    "section": 48,
    "stack": 8,
    "list": 12
  }
} as const;

// ─── Tamaños de componente ──────────────────────────────────────────────────

export const buttonSizes = {
  "xs": {
    "height": 32,
    "shapeRound": "full",
    "shapeSquare": "medium",
    "shapePressed": "small",
    "paddingX": 16,
    "icon": 20,
    "gap": 8,
    "outline": 1,
    "label": "titleSmall"
  },
  "s": {
    "height": 40,
    "shapeRound": "full",
    "shapeSquare": "medium",
    "shapePressed": "small",
    "paddingX": 16,
    "icon": 20,
    "gap": 8,
    "outline": 1,
    "label": "titleSmall"
  },
  "m": {
    "height": 56,
    "shapeRound": "full",
    "shapeSquare": "large",
    "shapePressed": "medium",
    "paddingX": 24,
    "icon": 24,
    "gap": 8,
    "outline": 1,
    "label": "titleMedium"
  },
  "l": {
    "height": 96,
    "shapeRound": "full",
    "shapeSquare": "extraLarge",
    "shapePressed": "large",
    "paddingX": 48,
    "icon": 32,
    "gap": 12,
    "outline": 2,
    "label": "headlineSmall"
  },
  "xl": {
    "height": 136,
    "shapeRound": "full",
    "shapeSquare": "extraLarge",
    "shapePressed": "large",
    "paddingX": 64,
    "icon": 40,
    "gap": 16,
    "outline": 3,
    "label": "headlineLarge"
  }
} as const;

export type ButtonSize = keyof typeof buttonSizes;

export const fabSizes = {
  "small": {
    "container": 56,
    "shape": "large",
    "icon": 24
  },
  "medium": {
    "container": 80,
    "shape": "extraLarge",
    "icon": 28
  },
  "large": {
    "container": 96,
    "shape": "extraLarge",
    "icon": 36
  }
} as const;

export const iconSizes = {
  "xs": 16,
  "s": 20,
  "m": 24,
  "l": 32,
  "xl": 40
} as const;

// ─── Motion ─────────────────────────────────────────────────────────────────

/**
 * Los 6 muelles de M3 Expressive. `damping` ya viene como COEFICIENTE, que es
 * lo que espera el spring de framer-motion; `dampingRatio` es el de la spec.
 */
export const spring = {
  "spatial": {
    "fast": {
      "stiffness": 800,
      "mass": 1,
      "damping": 33.94,
      "dampingRatio": 0.6
    },
    "default": {
      "stiffness": 380,
      "mass": 1,
      "damping": 31.19,
      "dampingRatio": 0.8
    },
    "slow": {
      "stiffness": 200,
      "mass": 1,
      "damping": 22.63,
      "dampingRatio": 0.8
    }
  },
  "effects": {
    "fast": {
      "stiffness": 3800,
      "mass": 1,
      "damping": 123.29,
      "dampingRatio": 1
    },
    "default": {
      "stiffness": 1600,
      "mass": 1,
      "damping": 80,
      "dampingRatio": 1
    },
    "slow": {
      "stiffness": 800,
      "mass": 1,
      "damping": 56.57,
      "dampingRatio": 1
    }
  }
} as const;

export const duration = {
  "short1": 50,
  "short2": 100,
  "short3": 150,
  "short4": 200,
  "medium1": 250,
  "medium2": 300,
  "medium3": 350,
  "medium4": 400,
  "long1": 450,
  "long2": 500,
  "long3": 550,
  "long4": 600,
  "extraLong1": 700,
  "extraLong2": 800,
  "extraLong3": 900,
  "extraLong4": 1000
} as const;

/** Curvas de M3 como tuplas [x1, y1, x2, y2]. */
export const easing = {
  "emphasized": [
    0.2,
    0,
    0,
    1
  ],
  "emphasizedDecelerate": [
    0.05,
    0.7,
    0.1,
    1
  ],
  "emphasizedAccelerate": [
    0.3,
    0,
    0.8,
    0.15
  ],
  "standard": [
    0.2,
    0,
    0,
    1
  ],
  "standardDecelerate": [
    0,
    0,
    0,
    1
  ],
  "standardAccelerate": [
    0.3,
    0,
    1,
    1
  ]
} as const;

export const pressScale = {
  "default": 0.96,
  "subtle": 0.98
} as const;

// ─── State layers ───────────────────────────────────────────────────────────

/** Opacidad de la capa de estado (overlay del color de contenido). */
export const stateLayer = {
  "hover": 0.08,
  "focus": 0.1,
  "press": 0.1,
  "drag": 0.16,
  "disabledContainer": 0.12,
  "disabledContent": 0.38
} as const;
