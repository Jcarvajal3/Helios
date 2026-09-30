//  @ts-check

import { tanstackConfig } from '@tanstack/eslint-config'

export default [
  ...tanstackConfig,
  {
    rules: {
      'import/no-cycle': 'off',
      'import/order': 'off',
      'sort-imports': 'off',
      '@typescript-eslint/array-type': 'off',
      '@typescript-eslint/require-await': 'off',
      'pnpm/json-enforce-catalog': 'off',
    },
  },
  {
    // `.output` y `.vercel` son salida de build —ya ignoradas por git— y el
    // parser de TypeScript revienta con ellas: son .js compilados que no están
    // en ningún tsconfig, así que cada `npm run lint` tras un build escupía
    // cien "Parsing error" que no eran de nadie y tapaban los de verdad.
    ignores: ['eslint.config.js', 'prettier.config.js', '.output/**', '.vercel/**'],
  },
]
