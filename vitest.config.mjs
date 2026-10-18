import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    // Os testes falam com um único banco e limpam os dados entre si: um arquivo por vez, sem paralelismo.
    fileParallelism: false,
    testTimeout: 20_000,
  },
})
