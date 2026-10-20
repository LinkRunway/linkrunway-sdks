type RuntimeCrypto = {
  randomUUID?: () => string;
  getRandomValues?: (bytes: Uint8Array) => unknown;
};
const shape = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
/** A lowercase RFC 9562 UUID, which is the only form the API accepts for install IDs. */
export const isUuid = (value: unknown): value is string =>
  typeof value === 'string' && shape.test(value);
/**
 * A random version 4 UUID. It uses the runtime's cryptographic source when there is one. A runtime
 * without `crypto` (React Native without a polyfill) falls back to `Math.random`, which is not
 * cryptographically strong: pass `randomUUID` in the SDK options there.
 */
export function uuid(): string {
  const source = (globalThis as { crypto?: RuntimeCrypto }).crypto;
  if (typeof source?.randomUUID === 'function') return source.randomUUID().toLowerCase();
  const bytes = new Uint8Array(16);
  if (typeof source?.getRandomValues === 'function') source.getRandomValues(bytes);
  else for (let index = 0; index < 16; index++) bytes[index] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join('-');
}
