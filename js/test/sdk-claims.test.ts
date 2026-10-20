import { afterEach, describe, expect, it, vi } from 'vitest';
import { LinkRunway, type SdkOptions, type StorageAdapter } from '../sdk/src';
type Sent = {
  method: string;
  path: string;
  headers: Record<string, string>;
  body?: Record<string, unknown>;
};
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
function api(reply: (sent: Sent, index: number) => unknown) {
  const sent: Sent[] = [];
  const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
    const request: Sent = {
      method: init?.method ?? 'GET',
      path: new URL(String(input)).pathname.replace('/v1/', ''),
      headers: init?.headers as Record<string, string>,
      body: init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : undefined,
    };
    sent.push(request);
    const answer = reply(request, sent.length);
    return answer instanceof Response ? answer : Response.json(answer);
  };
  return { sent, fetcher: fetcher as typeof fetch };
}
const client = (fetcher: typeof fetch, more: Partial<SdkOptions> = {}) =>
  new LinkRunway({
    endpoint: 'https://links.example.com',
    apiKey: 'lr_pk_test',
    consent: true,
    retries: 0,
    fetch: fetcher,
    ...more,
  });
const pending = () => Response.json({ pending: true }, { status: 202 });
const token = 'a'.repeat(40);
afterEach(() => vi.useRealTimers());
describe('ad-network claims', () => {
  it('repeats an AdServices claim while the server answers 202, then never sends it again', async () => {
    const { storage } = memory();
    const { sent, fetcher } = api((_, index) => (index < 3 ? pending() : { network: 'APPLE_ADS' }));
    const sdk = client(fetcher, { storage });
    const result = await sdk.submitAdServicesToken(token, { delayMs: 1 });
    expect(result).toEqual({ status: 'submitted', data: { network: 'APPLE_ADS' } });
    expect(sent).toHaveLength(3);
    expect(sent[0]).toMatchObject({
      method: 'POST',
      path: 'claims/apple-ads',
      body: { installId: sdk.installId(), token, consent: true },
    });
    expect(await sdk.submitAdServicesToken(token)).toEqual({ status: 'alreadySubmitted' });
    const restarted = client(fetcher, { storage });
    expect(await restarted.submitAdServicesToken(token)).toEqual({ status: 'alreadySubmitted' });
    expect(sent).toHaveLength(3);
  });
  it('waits five seconds between at most three retries, then reports the claim as pending', async () => {
    vi.useFakeTimers();
    const { sent, fetcher } = api(pending);
    const sdk = client(fetcher);
    const first = sdk.submitAdServicesToken(token);
    await vi.advanceTimersByTimeAsync(4999);
    expect(sent).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(sent).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(10000);
    expect(await first).toEqual({ status: 'pending', data: { pending: true } });
    expect(sent).toHaveLength(4);
    // A pending claim is not remembered as done: the next call asks again.
    const again = sdk.submitAdServicesToken(token, { retries: 0 });
    expect(await again).toMatchObject({ status: 'pending' });
    expect(sent).toHaveLength(5);
  });
  it('forwards a referrer claim once, without retrying, and skips an empty referrer', async () => {
    const { sent, fetcher } = api((_, index) => (index === 1 ? pending() : { accepted: true }));
    const sdk = client(fetcher);
    expect(await sdk.submitReferrerClaim('app_1', '')).toBeUndefined();
    expect(await sdk.submitReferrerClaim('app_1', 'gclid=abc')).toMatchObject({
      status: 'pending',
    });
    expect(sent).toHaveLength(1);
    expect(await sdk.submitReferrerClaim('app_1', 'gclid=abc')).toMatchObject({
      status: 'submitted',
    });
    expect(sent[1]).toMatchObject({
      path: 'claims/referrer',
      body: { installId: sdk.installId(), appId: 'app_1', referrer: 'gclid=abc', consent: true },
    });
    expect(await sdk.submitReferrerClaim('app_1', 'gclid=abc')).toEqual({
      status: 'alreadySubmitted',
    });
    expect(sent).toHaveLength(2);
  });
  it('sends nothing without consent, stops when consent is withdrawn, and shares one request', async () => {
    const { sent, fetcher } = api(pending);
    const off = client(fetcher, { consent: false });
    expect(await off.submitAdServicesToken(token)).toBeUndefined();
    expect(await off.submitReferrerClaim('app_1', 'gclid=abc')).toBeUndefined();
    expect(sent).toHaveLength(0);
    const sdk = client(fetcher);
    const [first, second] = [
      sdk.submitAdServicesToken(token, { delayMs: 20 }),
      sdk.submitAdServicesToken(token, { delayMs: 20 }),
    ];
    expect(second).toBe(first);
    await vi.waitFor(() => expect(sent).toHaveLength(1));
    sdk.setConsent(false);
    expect(await first).toBeUndefined();
    expect(sent).toHaveLength(1);
    await expect(
      client(fetcher, { apiKey: 'lr_sk_test' }).submitAdServicesToken(token),
    ).rejects.toThrow('publishable key');
  });
});
describe('server-side helpers', () => {
  it('refuse to run with a publishable key', async () => {
    const { sent, fetcher } = api(() => ({}));
    const sdk = client(fetcher);
    await expect(sdk.recordImpression({ linkId: 'link' })).rejects.toThrow(
      'recordImpression requires a server key',
    );
    await expect(
      sdk.bindStoreAccount({ externalUserId: 'user', storeAccountToken: 'token' }),
    ).rejects.toThrow('bindStoreAccount requires a server key');
    expect(sent).toHaveLength(0);
  });
  it('report an impression and bind a store account with a server key, only with consent', async () => {
    const storeAccountToken = '5b1f8a52-7f0e-4d4f-9a53-0c3a9f6d2e11';
    const { sent, fetcher } = api((request) =>
      request.path === 'impressions'
        ? { id: 'impression', createdAt: '2026-10-10T00:00:00.000Z' }
        : { externalUserId: 'user', storeAccountToken },
    );
    const sdk = client(fetcher, { apiKey: 'lr_sk_test' });
    const impression = { linkId: 'link', platform: 'CTV', device: 'Roku', ip: '198.51.100.7' };
    expect(await sdk.recordImpression({ ...impression, platform: 'CTV' })).toEqual({
      id: 'impression',
      createdAt: '2026-10-10T00:00:00.000Z',
    });
    expect(sent[0]).toMatchObject({
      method: 'POST',
      path: 'impressions',
      body: { ...impression, consent: true },
    });
    expect(await sdk.bindStoreAccount({ externalUserId: 'user', storeAccountToken })).toEqual({
      externalUserId: 'user',
      storeAccountToken,
    });
    expect(sent[1]).toMatchObject({
      method: 'PUT',
      path: 'customers/store-account',
      body: { externalUserId: 'user', storeAccountToken, consent: true },
    });
    sdk.setConsent(false);
    expect(await sdk.recordImpression({ linkId: 'link' })).toBeUndefined();
    expect(
      await sdk.bindStoreAccount({ externalUserId: 'user', storeAccountToken }),
    ).toBeUndefined();
    expect(sent).toHaveLength(2);
  });
  it('reads the conversion configuration of an app with a plain GET', async () => {
    const config = { id: 'app/1', conversionRules: [] };
    const { sent, fetcher } = api(() => config);
    const sdk = client(fetcher);
    expect(await sdk.mobileConfig('app/1')).toEqual(config);
    expect(sent[0]).toMatchObject({ method: 'GET', path: 'mobile/config/app%2F1' });
    expect(sent[0]!.body).toBeUndefined();
    expect(sent[0]!.headers).toEqual({ Authorization: 'Bearer lr_pk_test' });
    sdk.setConsent(false);
    expect(await sdk.mobileConfig('app/1')).toBeUndefined();
    expect(sent).toHaveLength(1);
  });
});
