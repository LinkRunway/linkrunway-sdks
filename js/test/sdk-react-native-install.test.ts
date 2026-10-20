import { describe, expect, it, vi } from 'vitest';
import { storageKey } from '../sdk/src';
import {
  createLinkRunway,
  type ReactNativeOptions,
  type RunwayLink,
} from '../react-native/src';
const endpoint = 'https://go.example.com';
const key = storageKey(endpoint, 'lr_pk_test');
type Sent = { path: string; body: Record<string, unknown> };
const matched = {
  matched: true,
  method: 'REFERRER',
  clickId: 'click',
  clickToken: 'matched',
  path: '/product/1',
  url: 'https://shop.example.com/p/1',
  metadata: { sku: 'A1' },
};
/** Fakes for the pieces an app injects, and a fetch double that answers by path. */
function harness(more: Partial<ReactNativeOptions> = {}, saved?: Record<string, unknown>) {
  const sent: Sent[] = [];
  const state = { held: false, release: () => {} };
  const map = new Map<string, string>(saved ? [[key, JSON.stringify(saved)]] : []);
  const gate = new Promise<void>((resolve) => (state.release = resolve));
  const urls = new Set<(event: { url: string }) => void>();
  const changes = new Set<(state: string) => void>();
  const listen = <T>(set: Set<T>, handler: T) => {
    set.add(handler);
    return { remove: () => void set.delete(handler) };
  };
  const options: ReactNativeOptions = {
    endpoint,
    apiKey: 'lr_pk_test',
    consent: true,
    platform: 'android',
    retries: 0,
    linking: {
      getInitialURL: async () => null,
      addEventListener: (_type, handler) => listen(urls, handler),
    },
    appState: { addEventListener: (_type, handler) => listen(changes, handler) },
    storage: {
      getItem: async (name) => {
        if (state.held) await gate;
        return map.get(name) ?? null;
      },
      setItem: async (name, value) => void map.set(name, value),
      removeItem: async (name) => void map.delete(name),
    },
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input).split('/v1/')[1]!;
      sent.push({ path, body: JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown> });
      if (path === 'installs/match') return Response.json(matched);
      if (path === 'resolve') return Response.json({ ...matched, clickToken: 'resolved' });
      return Response.json({ id: 'event' });
    }) as typeof fetch,
    ...more,
  };
  return {
    options,
    sent,
    state,
    map,
    paths: (path: string) => sent.filter((request) => request.path === path),
    stored: () => JSON.parse(map.get(key) ?? '{}') as Record<string, unknown>,
    open: (url: string) => urls.forEach((handler) => handler({ url })),
    appState: (value: string) => changes.forEach((handler) => handler(value)),
  };
}
const idle = () => new Promise((resolve) => setTimeout(resolve, 5));
const referrer = 'utm_source=google-play&lr_token=abc';
const link = 'https://go.example.com/l/summer';
describe('first launch', () => {
  it('matches the install once, with the injected referrer, and never again', async () => {
    const getInstallReferrer = vi.fn(async () => referrer);
    const first = harness({ osVersion: '14', language: 'en_US', getInstallReferrer });
    const runway = createLinkRunway(first.options);
    const links: RunwayLink[] = [];
    runway.subscribe((value) => links.push(value));
    await vi.waitFor(() => expect(links).toHaveLength(1));
    expect(first.paths('installs/match')[0]!.body).toEqual({
      installId: await runway.installId(),
      platform: 'android',
      osVersion: '14',
      language: 'en-US',
      referrer,
      consent: true,
    });
    const { clickToken: _token, matched: _matched, url, ...rest } = matched;
    expect(links[0]).toEqual({ ...rest, source: 'install', destination: url });
    expect(await runway.attributionToken()).toBe('matched');
    first.appState('active');
    await vi.waitFor(() => expect(first.stored().match).toMatchObject({ matched: true }));
    // The next launch finds the answer in storage: no request, no referrer read, no second link.
    const again = harness({ getInstallReferrer }, first.stored());
    const relaunched = createLinkRunway(again.options);
    const later: RunwayLink[] = [];
    relaunched.subscribe((value) => later.push(value));
    await relaunched.ready;
    again.appState('active');
    await idle();
    expect(again.paths('installs/match')).toHaveLength(0);
    expect(first.paths('installs/match')).toHaveLength(1);
    expect(getInstallReferrer).toHaveBeenCalledTimes(1);
    expect(later).toHaveLength(0);
  });
  it('does not match without the referrer when reading it failed, and tries again later', async () => {
    const failures: unknown[] = [];
    const getInstallReferrer = vi
      .fn<() => Promise<string | null>>()
      .mockRejectedValueOnce(new Error('Play service unavailable'))
      .mockResolvedValue(null);
    const h = harness({
      getInstallReferrer,
      onError: (error, stage) => failures.push([stage, (error as Error).message]),
    });
    const runway = createLinkRunway(h.options);
    await runway.ready;
    await idle();
    expect(h.paths('installs/match')).toHaveLength(0);
    expect(failures).toEqual([['install', 'Play service unavailable']]);
    h.appState('active');
    await vi.waitFor(() => expect(h.paths('installs/match')).toHaveLength(1));
    expect(h.paths('installs/match')[0]!.body).not.toHaveProperty('referrer');
  });
  it('lets the link that launched the app win over the deferred one', async () => {
    const h = harness();
    h.options.linking.getInitialURL = async () => link;
    const runway = createLinkRunway(h.options);
    const links: RunwayLink[] = [];
    runway.subscribe((value) => links.push(value));
    await vi.waitFor(() => expect(h.paths('installs/match')).toHaveLength(1));
    await idle();
    expect(h.sent.map((request) => request.path).slice(0, 2)).toEqual([
      'resolve',
      'installs/match',
    ]);
    expect(links.map((value) => value.source)).toEqual(['initial']);
    expect(await runway.attributionToken()).toBe('resolved');
    expect((await runway.ready).installMatch()).toMatchObject({ matched: true, cached: true });
  });
});
describe('consent', () => {
  it('holds the launch link in memory and touches nothing until consent is given', async () => {
    const getInstallReferrer = vi.fn(async () => referrer);
    const h = harness({ consent: false, getInstallReferrer });
    h.options.linking.getInitialURL = async () => link;
    const runway = createLinkRunway(h.options);
    await runway.ready;
    expect(await runway.track({ type: 'OPEN' })).toEqual({ skipped: true });
    h.appState('active');
    await idle();
    expect(h.sent).toHaveLength(0);
    expect(h.map.size).toBe(0);
    expect(getInstallReferrer).not.toHaveBeenCalled();
    runway.setConsent(true);
    await vi.waitFor(() => expect(h.paths('installs/match')).toHaveLength(1));
    expect(h.paths('resolve')[0]!.body.url).toBe(link);
    expect(runway.lastLink()).toMatchObject({ source: 'initial' });
  });
  it('erases saved state on an explicit refusal, even one made while storage was loading', async () => {
    const saved = { clickToken: 'saved', installId: '3f0c8a52-91d7-4c1e-8a55-0b9e7d6c5a41' };
    const h = harness({ consent: false }, saved);
    h.state.held = true;
    const runway = createLinkRunway(h.options);
    runway.setConsent(false);
    runway.setConsent(true);
    h.state.release();
    await vi.waitFor(() => expect(h.paths('installs/match')).toHaveLength(1));
    expect(await runway.installId()).not.toBe(saved.installId);
    expect(h.stored().clickToken).toBe('matched');
    h.open(link);
    runway.setConsent(false);
    await vi.waitFor(() => expect(h.map.size).toBe(0));
    expect(await runway.attributionToken()).toBeUndefined();
    // A link that arrives after a refusal is dropped, not kept for a later grant.
    runway.setConsent(true);
    await vi.waitFor(() => expect(h.paths('installs/match')).toHaveLength(2));
    expect(h.paths('resolve')).toHaveLength(0);
    // Starting without consent is not a refusal: what an earlier session saved is kept.
    const kept = harness({ consent: false }, saved);
    const quiet = createLinkRunway(kept.options);
    await quiet.ready;
    await idle();
    expect(kept.stored()).toEqual(saved);
  });
});
describe('attestation', () => {
  it('asks the app for a token once per validity period and attaches it to events', async () => {
    const expiresAt = new Date(Date.now() + 3600000).toISOString();
    const getAttestation = vi.fn(async () => ({ attestation: 'attested', expiresAt }));
    const h = harness({ getAttestation });
    const runway = createLinkRunway(h.options);
    await vi.waitFor(() => expect(getAttestation).toHaveBeenCalledTimes(1));
    expect(getAttestation).toHaveBeenCalledWith({ installId: await runway.installId() });
    await idle();
    await runway.track({ type: 'OPEN' });
    expect(h.paths('track')[0]!.body.attestation).toBe('attested');
    h.appState('active');
    await idle();
    expect(getAttestation).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(h.stored())).not.toContain('attested');
  });
  it('sends events unattested when the app cannot attest, without asking on every foreground', async () => {
    const failures: string[] = [];
    const getAttestation = vi.fn(async () => {
      throw new Error('App Attest is not supported on this device');
    });
    const h = harness({ getAttestation, onError: (_error, stage) => failures.push(stage) });
    const runway = createLinkRunway(h.options);
    await vi.waitFor(() => expect(failures).toEqual(['attestation']));
    h.appState('active');
    await idle();
    expect(getAttestation).toHaveBeenCalledTimes(1);
    expect(await runway.track({ type: 'OPEN' })).toEqual({ id: 'event' });
    expect(h.paths('track')[0]!.body).not.toHaveProperty('attestation');
  });
});
