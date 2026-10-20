import { afterEach, describe, expect, it, vi } from 'vitest';
import { LinkRunway, type SdkOptions, type StorageAdapter } from '../sdk/src';
const uuidShape = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
type Sent = { path: string; body: Record<string, unknown> };
function memory() {
  const map = new Map<string, string>();
  const storage: StorageAdapter = {
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    removeItem: (key) => void map.delete(key),
  };
  return { map, storage };
}
/** A fetch double that records each request and answers with `reply`. */
function api(reply: (sent: Sent) => unknown) {
  const sent: Sent[] = [];
  const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = {
      path: new URL(String(input)).pathname.replace('/v1/', ''),
      body: JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>,
    };
    sent.push(request);
    const answer = await reply(request);
    return answer instanceof Response ? answer : Response.json(answer);
  };
  return { sent, fetcher: fetcher as typeof fetch };
}
const client = (fetcher: typeof fetch, storage?: StorageAdapter, more: Partial<SdkOptions> = {}) =>
  new LinkRunway({
    endpoint: 'https://links.example.com',
    apiKey: 'lr_pk_test',
    consent: true,
    retries: 0,
    fetch: fetcher,
    storage,
    ...more,
  });
const matched = {
  matched: true,
  method: 'REFERRER',
  clickId: 'click',
  clickToken: 'match-token',
  path: '/welcome',
  url: 'https://example.com',
  metadata: { plan: 'pro' },
};
afterEach(() => vi.useRealTimers());
describe('install identity', () => {
  it('creates the ID on first use, sends it with events, and keeps it across restarts', async () => {
    const { map, storage } = memory();
    const { sent, fetcher } = api(() => ({ id: 'event' }));
    const sdk = client(fetcher, storage);
    expect(map.size).toBe(0);
    const id = sdk.installId();
    expect(id).toMatch(uuidShape);
    expect([...map.values()].join()).toContain(id);
    await sdk.track({ eventId: '1', type: 'OPEN' });
    expect(sent[0]!.body.installId).toBe(id);
    expect(client(fetcher, storage).installId()).toBe(id);
  });
  it('creates nothing without consent and starts a new identity after a withdrawal', async () => {
    const { map, storage } = memory();
    const { sent, fetcher } = api(() => ({ id: 'event' }));
    const sdk = client(fetcher, storage, { consent: false });
    expect(sdk.installId()).toBeUndefined();
    expect(await sdk.matchInstall({ platform: 'ios' })).toBeUndefined();
    expect(map.size).toBe(0);
    sdk.setConsent(true);
    const first = sdk.installId();
    sdk.setConsent(false);
    expect(sdk.installId()).toBeUndefined();
    expect(map.size).toBe(0);
    sdk.setConsent(true);
    expect(sdk.installId()).toMatch(uuidShape);
    expect(sdk.installId()).not.toBe(first);
    expect(sent).toHaveLength(0);
  });
  it('restores state saved under an earlier grant when consent is enabled later', () => {
    const { storage } = memory();
    const { fetcher } = api(() => ({}));
    const earlier = client(fetcher, storage);
    earlier.capture('https://example.com/?lr_token=saved');
    const id = earlier.installId();
    const later = client(fetcher, storage, { consent: false });
    expect(later.attributionToken()).toBeUndefined();
    later.setConsent(true);
    expect(later.attributionToken()).toBe('saved');
    expect(later.installId()).toBe(id);
  });
  it('gives a server key no install ID and accepts an injected generator', async () => {
    const { sent, fetcher } = api(() => ({ id: 'event' }));
    const server = client(fetcher, undefined, { apiKey: 'lr_sk_test' });
    expect(server.installId()).toBeUndefined();
    await server.track({ eventId: '1', type: 'SIGNUP' });
    expect(sent[0]!.body).not.toHaveProperty('installId');
    const forwarded = '0b0e7f0c-55b4-4d5c-9d5e-0d8f3a1c2b3d';
    await server.track({ eventId: '2', type: 'SIGNUP', installId: forwarded });
    expect(sent[1]!.body.installId).toBe(forwarded);
    await expect(server.matchInstall({ platform: 'ios' })).rejects.toThrow('publishable key');
    const upper = '9F1C2D3E-4B5A-4C6D-8E7F-0A1B2C3D4E5F';
    expect(client(fetcher, undefined, { randomUUID: () => upper }).installId()).toBe(
      upper.toLowerCase(),
    );
    expect(client(fetcher, undefined, { randomUUID: () => 'nope' }).installId()).toMatch(uuidShape);
  });
});
describe('first-launch match', () => {
  it('asks once, saves the click token, and answers later calls from storage', async () => {
    const { storage } = memory();
    const { sent, fetcher } = api(() => matched);
    const sdk = client(fetcher, storage);
    const input = { platform: 'android', osVersion: '14', language: 'en_US' } as const;
    const [first, same] = await Promise.all([
      sdk.matchInstall({ ...input, referrer: 'lr_token=abc' }),
      sdk.matchInstall(input),
    ]);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toEqual({
      path: 'installs/match',
      body: {
        installId: sdk.installId(),
        platform: 'android',
        osVersion: '14',
        language: 'en-US',
        referrer: 'lr_token=abc',
        consent: true,
      },
    });
    expect(first).toEqual({ ...matched, cached: false });
    expect(same).toBe(first);
    expect(sdk.attributionToken()).toBe('match-token');
    const { clickToken: _token, ...outcome } = matched;
    expect(await sdk.matchInstall(input)).toEqual({ ...outcome, cached: true });
    const restarted = client(fetcher, storage);
    expect(restarted.installMatch()).toEqual({ ...outcome, cached: true });
    expect(await restarted.matchInstall(input)).toEqual({ ...outcome, cached: true });
    expect(sent).toHaveLength(1);
  });
  it('keeps the token of a link opened since, and stores an unmatched answer', async () => {
    const { sent, fetcher } = api(() => matched);
    const sdk = client(fetcher);
    sdk.capture('https://example.com/?lr_token=opened');
    await sdk.matchInstall({ platform: 'ios' });
    expect(sdk.attributionToken()).toBe('opened');
    const none = api(() => ({ matched: false, method: 'NONE' }));
    const other = client(none.fetcher);
    expect(await other.matchInstall({ platform: 'ios' })).toEqual({
      matched: false,
      method: 'NONE',
      cached: false,
    });
    expect((await other.matchInstall({ platform: 'ios' }))?.cached).toBe(true);
    expect(other.attributionToken()).toBeUndefined();
    expect(sent).toHaveLength(1);
    expect(none.sent).toHaveLength(1);
  });
  it('drops an answer that arrives after consent was withdrawn, and retries after a failure', async () => {
    const { map, storage } = memory();
    let complete!: (value: unknown) => void;
    const slow = api(() => new Promise((resolve) => (complete = resolve)));
    const sdk = client(slow.fetcher, storage);
    const pending = sdk.matchInstall({ platform: 'ios' });
    sdk.setConsent(false);
    complete(matched);
    expect(await pending).toBeUndefined();
    expect(map.size).toBe(0);
    let fail = true;
    const flaky = api(() => (fail ? new Response('{}', { status: 503 }) : matched));
    const retried = client(flaky.fetcher);
    await expect(retried.matchInstall({ platform: 'ios' })).rejects.toThrow();
    expect(retried.installMatch()).toBeUndefined();
    fail = false;
    expect((await retried.matchInstall({ platform: 'ios' }))?.matched).toBe(true);
    expect(flaky.sent).toHaveLength(2);
  });
  it('leaves out details the API would reject and reduces an oversized referrer to its token', async () => {
    const { sent, fetcher } = api(() => ({ matched: false, method: 'NONE' }));
    await client(fetcher).matchInstall({
      platform: 'ios',
      osVersion: '17.5.1.2',
      language: 'en-US-u-ca-gregory',
      referrer: `utm_content=${'x'.repeat(4100)}&lr_token=a%2Eb`,
    });
    expect(sent[0]!.body).toMatchObject({
      osVersion: '17.5.1',
      language: 'en-US',
      referrer: 'lr_token=a.b',
    });
    await client(fetcher).matchInstall({ platform: 'android', osVersion: 'S', language: 'und' });
    expect(sent[1]!.body).not.toHaveProperty('osVersion');
    expect(sent[1]!.body).not.toHaveProperty('language');
    expect(sent[1]!.body).not.toHaveProperty('referrer');
  });
});
describe('attestation', () => {
  it('attaches the token to events until it expires', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    const { sent, fetcher } = api(() => ({ id: 'event' }));
    const sdk = client(fetcher);
    sdk.setAttestation('attested', new Date(Date.now() + 60000).toISOString());
    await sdk.track({ eventId: '1', type: 'OPEN' });
    expect(sent[0]!.body.attestation).toBe('attested');
    vi.setSystemTime(Date.now() + 61000);
    await sdk.track({ eventId: '2', type: 'OPEN' });
    expect(sent[1]!.body).not.toHaveProperty('attestation');
  });
  it('is never stored: a queued event gets the attestation that is valid when it is sent', async () => {
    const { map, storage } = memory();
    let online = false;
    const { sent, fetcher } = api(() => {
      if (!online) throw new TypeError('offline');
      return { id: 'event' };
    });
    const sdk = client(fetcher, storage);
    sdk.setAttestation('first', Date.now() + 60000);
    expect(await sdk.track({ eventId: 'queued', type: 'OPEN' })).toEqual({ queued: true });
    expect([...map.values()].join()).not.toContain('first');
    online = true;
    sdk.setAttestation('second', Date.now() + 60000);
    await sdk.flush();
    expect(sent.at(-1)!.body).toMatchObject({ eventId: 'queued', attestation: 'second' });
  });
  it('is ignored without consent, cleared on withdrawal, and rejects unusable input', async () => {
    const { sent, fetcher } = api(() => ({ id: 'event' }));
    const sdk = client(fetcher, undefined, { consent: false });
    sdk.setAttestation('early', Date.now() + 60000);
    sdk.setConsent(true);
    await sdk.track({ eventId: '1', type: 'OPEN' });
    expect(sent[0]!.body).not.toHaveProperty('attestation');
    sdk.setAttestation('held', Date.now() + 60000);
    sdk.setConsent(false);
    sdk.setConsent(true);
    await sdk.track({ eventId: '2', type: 'OPEN' });
    expect(sent[1]!.body).not.toHaveProperty('attestation');
    expect(() => sdk.setAttestation('', Date.now())).toThrow('attestation');
    expect(() => sdk.setAttestation('token', 'not a date')).toThrow('attestation');
    expect(() => sdk.setAttestation('x'.repeat(2001), Date.now())).toThrow('attestation');
  });
});
