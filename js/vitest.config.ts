import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';
const source = (path) => fileURLToPath(new URL(path, import.meta.url));
export default defineConfig({
  resolve: {
    alias: {"@linkrunway/sdk":source('./sdk/src/index.ts'),"@linkrunway/sdk-react-native":source('./react-native/src/index.ts')},
  },
  test: { include: ['test/**/*.test.ts'], fileParallelism: false },
});
