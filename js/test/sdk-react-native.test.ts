import { describe, expect, it, vi } from 'vitest';
import { storageKey } from '../sdk/src';
import {
  createLinkRunway,
  linkKind,
  type ReactNativeOptions,
  type RunwayLink,
} from '../react-native/src';
const endpoint = 'https://go.example.com';
const key = storageKey(endpoint, 'lr_pk_test');
type Sent = { path: string; headers: Record<string, string>; body: Record<string, unknown> };
const resolved = {
  clickId: 'click',
  clickToken: 'resolved',
  path: '/product/1',
  url: 'https://shop.example.com/p/1',
  metadata: { sku: 'A1' },
};
/** Fakes for the pieces an app injects, and a fetch double that answers by path. */
function harness(more: Partial<ReactNativeOptions> = {}, saved?: Record<string, unknown>) {
  const sent: Sent[] = [];
  const state = { online: true, held: false, release: () => {} };
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
    platform: 'ios',
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
      const body = JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>;
      sent.push({ path, headers: init?.headers as Record<string, string>, body });
      if (!state.online) throw new TypeError('offline');
      if (path === 'resolve') return Response.json(resolved);
      if (path === 'installs/match') return Response.json({ matched: false, method: 'NONE' });
      return Response.json({ id: 'event' });
    }) as typeof fetch,
    ...more,
  };
  return {
    options,
    sent,
    state,
    listeners: () => urls.size + changes.size,
    paths: (path: string) => sent.filter((request) => request.path === path),
    stored: () => JSON.parse(map.get(key) ?? '{}') as Record<string, unknown>,
    open: (url: string) => urls.forEach((handler) => handler({ url })),
    appState: (value: string) => changes.forEach((handler) => handler(value)),
  };
}
const idle = () => new Promise((resolve) => setTimeout(resolve, 5));
const installId = '3f0c8a52-91d7-4c1e-8a55-0b9e7d6c5a41';
const link = 'https://go.example.com/l/summer?s=share1';
describe('storage hydration', () => {
  it('keeps events tracked before storage has loaded and sends them with the saved state', async () => {
    const h = harness(
      {},
      {
        clickToken: 'saved',
        installId,
        queue: [{ eventId: 'old', type: 'OPEN', occurredAt: '2026-10-09T08:00:00.000Z' }],
        match: { matched: false, method: 'NONE' },
      },
    );
    h.state.held = true;
    const runway = createLinkRunway(h.options);
    const early = runway.track({ type: 'OPEN', eventId: 'early' });
    const calledAt = Date.now();
    await idle();
    expect(h.sent).toHaveLength(0);
    h.state.release();
    expect(await early).toEqual({ id: 'event' });
    const first = h.paths('track').find((request) => request.body.eventId === 'early')!;
    expect(first.body).toMatchObject({ clickToken: 'saved', installId, consent: true });
    expect(Date.parse(String(first.body.occurredAt))).toBeLessThanOrEqual(calledAt);
    expect(first.headers['User-Agent']).toMatch(/^LinkRunwaySDK\/[0-9.]+ ReactNative$/);
    await vi.waitFor(() => expect(h.stored().queue).toEqual([]));
    const old = h.paths('track').find((request) => request.body.eventId === 'old')!;
    expect(old.body.occurredAt).toBe('2026-10-09T08:00:00.000Z');
    expect(h.stored()).toMatchObject({ clickToken: 'saved', installId });
    expect(h.paths('installs/match')).toHaveLength(0);
    expect(await runway.installId()).toBe(installId);
  });
  it('gives an event an ID when the app supplies none, and refuses a server key', async () => {
    const h = harness({ randomUUID: () => 'f47ac10b-58cc-4372-a567-0e02b2c3d479' });
    const runway = createLinkRunway(h.options);
    await runway.track({ type: 'CUSTOM', name: 'viewed' });
    expect(h.paths('track')[0]!.body).toMatchObject({
      eventId: 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
      installId: 'f47ac10b-58cc-4372-a567-0e02b2c3d479',
      name: 'viewed',
    });
    expect(() => createLinkRunway({ ...h.options, apiKey: 'lr_sk_secret' })).toThrow(
      'publishable key',
    );
    const web = { ...h.options, platform: 'web' } as unknown as ReactNativeOptions;
    expect(() => createLinkRunway(web)).toThrow('platform');
  });
});
describe('incoming links', () => {
  it('resolves the link that launched the app and tells subscribers', async () => {
    const h = harness({ platform: 'android' });
    h.options.linking.getInitialURL = async () => link;
    const runway = createLinkRunway(h.options);
    const links: RunwayLink[] = [];
    runway.subscribe((value) => links.push(value));
    await vi.waitFor(() => expect(links).toHaveLength(1));
    expect(links[0]).toEqual({
      source: 'initial',
      url: link,
      path: '/product/1',
      destination: 'https://shop.example.com/p/1',
      metadata: { sku: 'A1' },
      clickId: 'click',
    });
    expect(h.paths('resolve')[0]!.body).toEqual({ url: link, platform: 'android', consent: true });
    expect(runway.lastLink()).toBe(links[0]);
    expect(await runway.attributionToken()).toBe('resolved');
  });
  it('resolves later links, captures tokens, and leaves every other URL to the app', async () => {
    const h = harness({ domains: ['go.example.com', 'links.brand.example'] });
    const runway = createLinkRunway(h.options);
    const links: RunwayLink[] = [];
    const unsubscribe = runway.subscribe((value) => links.push(value));
    await runway.ready;
    for (const url of [
      'https://other.example.com/l/summer',
      'https://go.example.com/products/1',
      'https://go.example.com/l/summer/extra',
      'myapp://l/summer',
      'not a url',
    ])
      h.open(url);
    await idle();
    expect(h.paths('resolve')).toHaveLength(0);
    h.open('https://shop.example.com/p/1?lr_token=from-web&lr_path=%2Fp%2F1');
    await idle();
    expect(await runway.attributionToken()).toBe('from-web');
    expect(links).toHaveLength(0);
    h.open('https://links.brand.example/l/winter');
    await vi.waitFor(() => expect(links).toHaveLength(1));
    expect(links[0]).toMatchObject({ source: 'open', path: '/product/1' });
    unsubscribe();
    expect(await runway.open('https://go.example.com/l/push')).toMatchObject({ source: 'open' });
    expect(links).toHaveLength(1);
    expect(h.paths('resolve')).toHaveLength(2);
    expect(linkKind('https://GO.example.com/l/summer?s=1', ['Go.Example.com'])).toBe('link');
    expect(linkKind('myapp://open?lr_token=signed', [])).toBe('token');
    expect(linkKind('https://go.example.com/pricing', ['go.example.com'])).toBeUndefined();
  });
  it('counts a URL delivered twice at launch as one open, and stops listening when destroyed', async () => {
    const h = harness();
    h.options.linking.getInitialURL = async () => link;
    const runway = createLinkRunway(h.options);
    h.open(link);
    h.open(link);
    await idle();
    expect(h.paths('resolve')).toHaveLength(1);
    expect(h.listeners()).toBe(2);
    runway.destroy();
    expect(h.listeners()).toBe(0);
  });
  it('reports a failed resolution to onError instead of leaving a rejected promise', async () => {
    const failures: string[] = [];
    const h = harness({ onError: (_error, stage) => failures.push(stage) });
    h.state.online = false;
    const runway = createLinkRunway(h.options);
    await runway.ready;
    h.open(link);
    await vi.waitFor(() => expect(failures).toContain('link'));
    await expect(runway.open(link)).rejects.toThrow('offline');
  });
});
describe('offline queue', () => {
  it('is flushed when the app returns to the foreground', async () => {
    const h = harness();
    const runway = createLinkRunway(h.options);
    await runway.ready;
    await idle();
    h.state.online = false;
    expect(await runway.track({ type: 'OPEN', eventId: 'queued' })).toEqual({ queued: true });
    h.state.online = true;
    h.appState('background');
    h.appState('inactive');
    await idle();
    expect(h.paths('track')).toHaveLength(1);
    h.appState('active');
    await vi.waitFor(() => expect(h.paths('track')).toHaveLength(2));
    expect(h.paths('track')[1]!.body.eventId).toBe('queued');
    await vi.waitFor(() => expect(h.stored().queue).toEqual([]));
  });
});
