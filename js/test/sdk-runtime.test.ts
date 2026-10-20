import { afterEach, describe, expect, it, vi } from 'vitest';
import manifest from '../sdk/package.json';
import { LinkRunway, SDK_VERSION, uuid } from '../sdk/src';
import type { SdkOptions } from '../sdk/src';
import { parseUrl, urlParser } from '../sdk/src/url';
type Sent = { path: string; headers: Record<string, string>; body: Record<string, unknown> };
/** A fetch double that records each request and answers with `reply`. */
function api(reply: (sent: Sent) => unknown) {
  const sent: Sent[] = [];
  const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
    const request: Sent = {
      path: String(input).split('/v1/')[1]!,
      headers: init?.headers as Record<string, string>,
      body: JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>,
    };
    sent.push(request);
    const answer = await reply(request);
    return answer instanceof Response ? answer : Response.json(answer);
  };
  return { sent, fetcher: fetcher as typeof fetch };
}
const options = (fetcher: typeof fetch, more: Partial<SdkOptions> = {}): SdkOptions => ({
  endpoint: 'https://links.example.com',
  apiKey: 'lr_pk_test',
  consent: true,
  retries: 0,
  fetch: fetcher,
  ...more,
});
const resolved = { clickId: 'click', path: '/welcome', url: 'https://example.com', metadata: {} };
afterEach(() => {
  vi.unstubAllGlobals();
  vi.doUnmock('../sdk/src/url');
  vi.resetModules();
});
describe('link resolution', () => {
  it('treats an untracked open as successful and leaves the current attribution alone', async () => {
    const { fetcher } = api(() => ({ ...resolved, clickId: '', untracked: true }));
    const sdk = new LinkRunway(options(fetcher));
    sdk.capture('https://example.com/?lr_token=original');
    const result = await sdk.open('https://links.example.com/l/over-quota', 'ios');
    expect(result).toMatchObject({ untracked: true, path: '/welcome' });
    expect(sdk.attributionToken()).toBe('original');
    const tracked = api(() => ({ ...resolved, clickToken: 'fresh' }));
    const other = new LinkRunway(options(tracked.fetcher));
    await other.open('https://links.example.com/l/tracked');
    expect(other.attributionToken()).toBe('fresh');
  });
  it('drops an answer asked for under a consent that was withdrawn, even after a new grant', async () => {
    const waiting: ((answer: unknown) => void)[] = [];
    const { sent, fetcher } = api(() => new Promise((resolve) => waiting.push(resolve)));
    const sdk = new LinkRunway(options(fetcher));
    const opened = sdk.open('https://links.example.com/l/summer');
    const tracked = sdk.track({ eventId: 'late', type: 'OPEN' });
    sdk.setConsent(false);
    sdk.setConsent(true);
    waiting[0]!({ ...resolved, clickToken: 'late-token' });
    waiting[1]!(new Response('{}', { status: 503 }));
    expect(await opened).toBeUndefined();
    expect(await tracked).toEqual({ skipped: true });
    expect(sdk.attributionToken()).toBeUndefined();
    await sdk.flush();
    expect(sent).toHaveLength(2);
  });
});
describe('user agent', () => {
  it('is sent as a header outside browsers and never from a page', async () => {
    const { sent, fetcher } = api(() => ({ id: 'event' }));
    const userAgent = `LinkRunwaySDK/${SDK_VERSION} ReactNative`;
    const sdk = new LinkRunway(options(fetcher, { userAgent }));
    await sdk.track({ eventId: '1', type: 'OPEN' });
    expect(sent[0]!.headers['User-Agent']).toBe(userAgent);
    await new LinkRunway(options(fetcher)).track({ eventId: '2', type: 'OPEN' });
    expect(sent[1]!.headers).not.toHaveProperty('User-Agent');
    vi.stubGlobal('document', {});
    await sdk.track({ eventId: '3', type: 'OPEN' });
    expect(sent[2]!.headers).not.toHaveProperty('User-Agent');
  });
  it('matches the pattern the API recognizes and the package version', () => {
    expect(SDK_VERSION).toBe(manifest.version);
    expect(`LinkRunwaySDK/${SDK_VERSION} ReactNative`).toMatch(
      /^LinkRunwaySDK\/[0-9.]+ (iOS|Android|tvOS|AndroidTV|ReactNative|Flutter)$/,
    );
    const invalid = options(fetch, { userAgent: 'Agent\r\nX-Injected: 1' });
    expect(() => new LinkRunway(invalid)).toThrow('userAgent');
  });
});
describe('runtime independence', () => {
  // What React Native shipped for years: the getters throw and the query is never parsed.
  class Incomplete {
    static made = 0;
    constructor(readonly href: string) {
      Incomplete.made += 1;
    }
    get protocol(): string {
      throw new Error('URL.protocol is not implemented');
    }
    get hostname(): string {
      throw new Error('URL.hostname is not implemented');
    }
    get origin(): string {
      throw new Error('URL.origin is not implemented');
    }
    get pathname(): string {
      throw new Error('URL.pathname is not implemented');
    }
    searchParams = { get: () => null };
  }
  it('parses URLs as text when the runtime URL class does not work', () => {
    const parse = urlParser(Incomplete);
    for (const value of [
      'https://Go.Example.com:443/l/abc?lr_token=a%2Eb&x=1+2#top',
      'http://localhost:4210',
      'http://user:pass@127.0.0.1:8080/x',
      'myapp://open/path?lr_token=t',
    ]) {
      const [text, native] = [parse(value), parseUrl(value)];
      expect([text.protocol, text.hostname]).toEqual([native.protocol, native.hostname]);
      expect(text.param('lr_token')).toBe(native.param('lr_token'));
      if (text.protocol.startsWith('http'))
        expect([text.origin, text.pathname]).toEqual([native.origin, native.pathname]);
    }
    expect(parse('https://example.com?x=1+2').param('x')).toBe('1 2');
    expect(parse('https://example.com?x=%E0%A4%A').param('x')).toBe('%E0%A4%A');
    expect(parse('http://localhost@evil.example/').hostname).toBe('evil.example');
    expect(() => parse('not a url')).toThrow(TypeError);
    expect(urlParser(undefined)('https://example.com/a').pathname).toBe('/a');
  });
  it('runs the client end to end on the text parser', async () => {
    const textParser = vi.fn<(value: string) => ReturnType<typeof parseUrl>>();
    vi.resetModules();
    vi.doMock('../sdk/src/url', async (original) => {
      const actual = await original<typeof import('../sdk/src/url')>();
      Incomplete.made = 0;
      textParser.mockImplementation(actual.urlParser(Incomplete));
      return { ...actual, parseUrl: textParser };
    });
    const fresh = await import('../sdk/src');
    // The broken class was probed once and rejected; every later parse goes through the text parser.
    expect(Incomplete.made).toBe(1);
    const { sent, fetcher } = api(() => ({ id: 'event' }));
    const plain = options(fetcher, { endpoint: 'http://example.com' });
    expect(() => new fresh.LinkRunway(plain)).toThrow('HTTPS is required');
    expect(fresh.storageKey('https://Links.Example.com:443/', 'lr_pk_test')).toBe(
      'linkrunway:https://links.example.com:lr_pk_test',
    );
    const sdk = new fresh.LinkRunway(options(fetcher, { endpoint: 'http://localhost:4210/' }));
    sdk.capture('https://shop.example.com/products/1?lr_token=signed.token&lr_path=%2Fp');
    sdk.captureReferrer('utm_source=google&lr_token=from%2Dreferrer');
    expect(sdk.attributionToken()).toBe('from-referrer');
    await sdk.track({ eventId: '1', type: 'OPEN' });
    expect(sent[0]).toMatchObject({ path: 'track', body: { clickToken: 'from-referrer' } });
    expect(textParser.mock.calls.length).toBeGreaterThanOrEqual(5);
    expect(Incomplete.made).toBe(1);
  });
  it('creates version 4 UUIDs with whatever randomness the runtime has', () => {
    const shape = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
    const real = globalThis.crypto;
    expect(uuid()).toMatch(shape);
    vi.stubGlobal('crypto', {
      getRandomValues: (bytes: Uint8Array) => real.getRandomValues(bytes),
    });
    expect(uuid()).toMatch(shape);
    vi.stubGlobal('crypto', undefined);
    const ids = new Set(Array.from({ length: 50 }, uuid));
    expect(ids.size).toBe(50);
    for (const id of ids) expect(id).toMatch(shape);
  });
});
