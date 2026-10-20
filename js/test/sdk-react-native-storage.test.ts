import { describe, expect, it } from 'vitest';
import { LinkRunway, storageKey } from '../sdk/src';
import { createStorageBridge } from '../react-native/src';
const idle = () => new Promise((resolve) => setTimeout(resolve, 5));
describe('storage bridge', () => {
  it('writes through in order and survives a backend that fails', async () => {
    const log: string[] = [];
    const failures: unknown[] = [];
    const backend = {
      getItem: async () => 'on disk',
      setItem: async (name: string, value: string) => {
        if (value === 'broken') throw new Error('disk full');
        await idle();
        log.push(`set ${name}=${value}`);
      },
      removeItem: async (name: string) => void log.push(`remove ${name}`),
    };
    const bridge = createStorageBridge(backend, (error) => failures.push(error));
    bridge.adapter.setItem('a', '1');
    bridge.adapter.setItem('a', '2');
    bridge.adapter.setItem('b', 'broken');
    bridge.adapter.removeItem('a');
    // A value written before the read finished is newer than what is on disk.
    await bridge.hydrate('a');
    await bridge.hydrate('c');
    expect(bridge.adapter.getItem('a')).toBeNull();
    expect(bridge.adapter.getItem('b')).toBe('broken');
    expect(bridge.adapter.getItem('c')).toBe('on disk');
    await bridge.settled();
    expect(log).toEqual(['set a=1', 'remove a']);
    expect(failures).toHaveLength(1);
  });
  it('lets the core SDK read saved state at once and persists what it changes', async () => {
    const endpoint = 'https://go.example.com';
    const key = storageKey(endpoint, 'lr_pk_test');
    const map = new Map([[key, JSON.stringify({ clickToken: 'saved' })]]);
    // A synchronous store such as MMKV fits the same three methods.
    const bridge = createStorageBridge({
      getItem: (name) => map.get(name),
      setItem: (name, value) => void map.set(name, value),
      removeItem: (name) => void map.delete(name),
    });
    await bridge.hydrate(key);
    const sdk = new LinkRunway({
      endpoint,
      apiKey: 'lr_pk_test',
      consent: true,
      storage: bridge.adapter,
    });
    expect(sdk.attributionToken()).toBe('saved');
    sdk.capture('https://example.com/?lr_token=newer');
    const installId = sdk.installId();
    await bridge.settled();
    expect(JSON.parse(map.get(key)!)).toMatchObject({ clickToken: 'newer', installId });
    sdk.setConsent(false);
    await bridge.settled();
    expect(map.size).toBe(0);
  });
  it('starts empty when the backend cannot be read', async () => {
    const failures: unknown[] = [];
    const bridge = createStorageBridge(
      {
        getItem: () => Promise.reject(new Error('keychain locked')),
        setItem: () => undefined,
        removeItem: () => undefined,
      },
      (error) => failures.push(error),
    );
    await bridge.hydrate('key');
    expect(bridge.adapter.getItem('key')).toBeNull();
    expect(failures).toHaveLength(1);
  });
});
