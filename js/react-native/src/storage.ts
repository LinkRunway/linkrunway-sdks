import type { StorageAdapter } from '@linkrunway/sdk';
import type { AsyncStorageLike } from './types';
export type StorageBridge = {
  /** The synchronous view the core SDK reads and writes. */
  adapter: StorageAdapter;
  /** Loads one key from the backend. Resolves even when the backend fails. */
  hydrate(key: string): Promise<void>;
  /** Resolves when every write made so far has reached the backend. */
  settled(): Promise<void>;
};
/**
 * Gives the core SDK its synchronous storage on top of an asynchronous backend: values are read
 * once into memory, and every change is written through in the order it was made.
 */
export function createStorageBridge(
  backend: AsyncStorageLike,
  onError: (error: unknown) => void = () => {},
): StorageBridge {
  const values = new Map<string, string>();
  const touched = new Set<string>();
  // The newest value per key that the backend has not received yet; null is a removal.
  const unwritten = new Map<string, string | null>();
  let writing: Promise<void> | undefined;
  const drain = async () => {
    while (unwritten.size) {
      const [key, value] = unwritten.entries().next().value as [string, string | null];
      unwritten.delete(key);
      try {
        await (value === null ? backend.removeItem(key) : backend.setItem(key, value));
      } catch (error) {
        // The value stays in memory, so the session keeps working without the backend.
        onError(error);
      }
    }
  };
  const write = (key: string, value: string | null) => {
    touched.add(key);
    unwritten.set(key, value);
    writing ??= drain().finally(() => {
      writing = undefined;
    });
  };
  return {
    adapter: {
      getItem: (key) => values.get(key) ?? null,
      setItem(key, value) {
        values.set(key, value);
        write(key, value);
      },
      removeItem(key) {
        values.delete(key);
        write(key, null);
      },
    },
    async hydrate(key) {
      try {
        const saved = await backend.getItem(key);
        // Anything written while the read was in flight is newer than what was on disk.
        if (typeof saved === 'string' && !touched.has(key)) values.set(key, saved);
      } catch (error) {
        onError(error);
      }
    },
    async settled() {
      while (writing) await writing;
    },
  };
}
