import { describe, expect, it } from 'vitest';
import { LinkRunway, LinkRunwayError, type SdkOptions } from '../sdk/src';
type Sent = { path: string; body: Record<string, unknown> };
/** A fetch double that records each request and answers with `reply`. */
function api(reply: (sent: Sent) => unknown) {
  const sent: Sent[] = [];
  const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
    const request: Sent = {
      path: String(input).split('/v1/')[1]!,
      body: JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>,
    };
    sent.push(request);
    const answer = reply(request);
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
const refuse = (message: string, status = 400) => Response.json({ message }, { status });
const ids = (sent: Sent[]) => sent.map((request) => request.body.eventId);
describe('delivery', () => {
  it('never counts a non-JSON success as delivered and never queues a client error', async () => {
    const portal = api(() => new Response('<html>Sign in to Wi-Fi</html>', { status: 200 }));
    const sdk = client(portal.fetcher);
    expect(await sdk.track({ eventId: '1', type: 'OPEN' })).toEqual({ queued: true });
    const missing = api(() => new Response('<html>Not found</html>', { status: 404 }));
    const failure = await client(missing.fetcher)
      .track({ eventId: '2', type: 'OPEN' })
      .catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(LinkRunwayError);
    expect(failure).toMatchObject({ status: 404, message: 'Tracking request failed' });
  });
  it('drops a queued event the API refuses as invalid and keeps a conflict for later', async () => {
    let online = false;
    const { sent, fetcher } = api(({ body }) => {
      if (!online) throw new TypeError('offline');
      if (body.eventId === 'invalid') return refuse('Event timestamp is out of range');
      if (body.eventId === 'conflict') return refuse('Concurrent update', 409);
      return { id: 'event' };
    });
    const sdk = client(fetcher);
    for (const eventId of ['invalid', 'conflict', 'fine'])
      expect(await sdk.track({ eventId, type: 'OPEN' })).toEqual({ queued: true });
    online = true;
    await expect(sdk.flush()).rejects.toThrow('Event timestamp is out of range');
    expect(ids(sent.slice(3))).toEqual(['invalid', 'conflict', 'fine']);
    await expect(sdk.flush()).rejects.toThrow('Concurrent update');
    expect(ids(sent.slice(6))).toEqual(['conflict']);
  });
  it('stops a flush at a failure that would repeat, keeping every event', async () => {
    let status = 0;
    const { sent, fetcher } = api(() => {
      if (!status) throw new TypeError('offline');
      return status === 200 ? { id: 'event' } : new Response('{}', { status });
    });
    const sdk = client(fetcher);
    await sdk.track({ eventId: 'a', type: 'OPEN' });
    await sdk.track({ eventId: 'b', type: 'OPEN' });
    for (status of [503, 401, 402]) await expect(sdk.flush()).rejects.toThrow();
    expect(sent).toHaveLength(5);
    status = 200;
    await sdk.flush();
    expect(ids(sent.slice(5))).toEqual(['a', 'b']);
  });
});
describe('a click token the API no longer accepts', () => {
  const expired = 'Click token is invalid or expired';
  it('costs one retry: the event is delivered without it and the token is forgotten', async () => {
    const { sent, fetcher } = api(({ body }) =>
      body.clickToken ? refuse(expired) : { id: 'event', attributed: false },
    );
    const sdk = client(fetcher);
    sdk.capture('https://example.com/?lr_token=stale');
    expect(await sdk.track({ eventId: '1', type: 'OPEN' })).toEqual({
      id: 'event',
      attributed: false,
    });
    expect(sent.map((request) => request.body.clickToken)).toEqual(['stale', undefined]);
    expect(sdk.attributionToken()).toBeUndefined();
    await sdk.track({ eventId: '2', type: 'OPEN' });
    expect(sent).toHaveLength(3);
  });
  it('is kept when the event is refused for another reason, or when a newer token replaced it', async () => {
    const invalid = api(() => refuse('metadata: Too big'));
    const sdk = client(invalid.fetcher);
    sdk.capture('https://example.com/?lr_token=good');
    await expect(sdk.track({ eventId: '1', type: 'OPEN' })).rejects.toThrow('metadata: Too big');
    expect(invalid.sent).toHaveLength(2);
    expect(sdk.attributionToken()).toBe('good');
    let online = false;
    const { fetcher } = api(({ body }) => {
      if (!online) throw new TypeError('offline');
      return body.clickToken === 'old' ? refuse(expired) : { id: 'event' };
    });
    const later = client(fetcher);
    later.capture('https://example.com/?lr_token=old');
    await later.track({ eventId: 'queued', type: 'OPEN' });
    later.capture('https://example.com/?lr_token=new');
    online = true;
    await later.flush();
    expect(later.attributionToken()).toBe('new');
  });
  it('is reported to a backend that supplied it, and survives a failed retry', async () => {
    const server = api(() => refuse(expired));
    const backend = client(server.fetcher, { apiKey: 'lr_sk_test' });
    await expect(
      backend.track({ eventId: '1', type: 'SIGNUP', clickToken: 'from-app' }),
    ).rejects.toThrow(expired);
    expect(server.sent).toHaveLength(1);
    const { sent, fetcher } = api(({ body }) => {
      if (body.clickToken) return refuse(expired);
      throw new TypeError('connection lost');
    });
    const sdk = client(fetcher);
    sdk.capture('https://example.com/?lr_token=stale');
    expect(await sdk.track({ eventId: '2', type: 'OPEN' })).toEqual({ queued: true });
    expect(sent).toHaveLength(2);
    expect(sdk.attributionToken()).toBe('stale');
  });
});
