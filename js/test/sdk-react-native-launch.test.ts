import { describe, expect, it, vi } from 'vitest';
import { createLinkRunway, type ReactNativeOptions } from '../react-native/src';
type Sent = { path: string; body: Record<string, unknown> };
const matched = { matched: true, method: 'REFERRER', clickId: 'click', clickToken: 'matched' };
/** Fakes for the pieces an app injects, and a fetch double that answers by path. */
function harness(more: Partial<ReactNativeOptions> = {}, hold?: (path: string) => unknown) {
  const sent: Sent[] = [];
  const map = new Map<string, string>();
  const listen = () => ({ remove: () => {} });
  const options: ReactNativeOptions = {
    endpoint: 'https://go.example.com',
    apiKey: 'lr_pk_test',
    consent: true,
    platform: 'android',
    retries: 0,
    linking: { getInitialURL: async () => null, addEventListener: listen },
    appState: { addEventListener: listen },
    storage: {
      getItem: async (name) => map.get(name) ?? null,
      setItem: async (name, value) => void map.set(name, value),
      removeItem: async (name) => void map.delete(name),
    },
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input).split('/v1/')[1]!;
      sent.push({ path, body: JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown> });
      await hold?.(path);
      return Response.json(path === 'installs/match' ? matched : { id: 'event' });
    }) as typeof fetch,
    ...more,
  };
  return { options, sent, paths: () => sent.map((request) => request.path) };
}
describe('install()', () => {
  it('reports INSTALL after the first-launch match, with the matched click and a fixed ID', async () => {
    let read!: (referrer: string) => void;
    const getInstallReferrer = () => new Promise<string>((resolve) => (read = resolve));
    const h = harness({ getInstallReferrer });
    const runway = createLinkRunway(h.options);
    const reported = runway.install();
    await vi.waitFor(() => expect(read).toBeDefined());
    expect(h.sent).toHaveLength(0);
    read('lr_token=abc');
    expect(await reported).toEqual({ id: 'event' });
    expect(h.paths()).toEqual(['installs/match', 'track']);
    const installId = await runway.installId();
    expect(h.sent[1]!.body).toMatchObject({
      eventId: `install-${installId}`,
      type: 'INSTALL',
      clickToken: 'matched',
      installId,
    });
    // A later launch sends the same event, which the API records once.
    await runway.install();
    expect(h.paths()).toEqual(['installs/match', 'track', 'track']);
    expect(h.sent[2]!.body.eventId).toBe(`install-${installId}`);
  });
  it('rejects while the first launch is unresolved, and skips without consent', async () => {
    const failing = harness({
      getInstallReferrer: () => Promise.reject(new Error('Play service unavailable')),
    });
    const runway = createLinkRunway(failing.options);
    await expect(runway.install()).rejects.toThrow('not resolved yet');
    expect(failing.sent).toHaveLength(0);
    const getInstallReferrer = vi.fn(async () => 'lr_token=abc');
    const off = harness({ consent: false, getInstallReferrer });
    expect(await createLinkRunway(off.options).install()).toEqual({ skipped: true });
    expect(off.sent).toHaveLength(0);
    expect(getInstallReferrer).not.toHaveBeenCalled();
  });
  it('reads the install referrer only while consent is on', async () => {
    let release!: () => void;
    const held = new Promise<void>((resolve) => (release = resolve));
    const getInstallReferrer = vi.fn(async () => 'lr_token=abc');
    const h = harness({ consent: false, getInstallReferrer }, (path) =>
      path === 'resolve' ? held : undefined,
    );
    h.options.linking.getInitialURL = async () => 'https://go.example.com/l/summer';
    const runway = createLinkRunway(h.options);
    await runway.ready;
    await new Promise((resolve) => setTimeout(resolve, 5));
    // The launch link waited for consent; consent is withdrawn again while it resolves.
    expect(h.sent).toHaveLength(0);
    runway.setConsent(true);
    await vi.waitFor(() => expect(h.paths()).toEqual(['resolve']));
    runway.setConsent(false);
    release();
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(getInstallReferrer).not.toHaveBeenCalled();
    expect(h.paths()).toEqual(['resolve']);
  });
});
