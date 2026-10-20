import { expect, it, vi } from 'vitest';
import { LinkRunway } from '../sdk/src';
it('preserves claim IDs and clears tokens when resolution cannot attribute a visit', async () => {
  const fetcher = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(
      Response.json({ code: 'ABCDEFGHIJKL', expiresAt: '2026-10-11T00:00:00Z' }),
    )
    .mockResolvedValueOnce(
      Response.json({
        clickId: 'click',
        clickToken: 'new-token',
        path: '/welcome',
        url: 'https://example.com',
        metadata: {},
      }),
    )
    .mockResolvedValueOnce(
      Response.json({
        clickId: 'blocked',
        path: '/welcome',
        url: 'https://example.com',
        metadata: {},
      }),
    );
  const sdk = new LinkRunway({
    endpoint: 'https://links.example.com',
    apiKey: 'lr_pk_test',
    consent: true,
    fetch: fetcher,
  });
  sdk.capture('https://example.com/?lr_token=original');
  expect((await sdk.createReferralCode())?.code).toBe('ABCDEFGHIJKL');
  await sdk.claimReferralCode('ABCDEFGHIJKL', 'f507b5b6-17a1-4aab-a61c-aef710eb3b07');
  expect(sdk.attributionToken()).toBe('new-token');
  expect(JSON.parse(String(fetcher.mock.calls[1]![1]?.body))).toMatchObject({
    claimId: 'f507b5b6-17a1-4aab-a61c-aef710eb3b07',
    consent: true,
  });
  await sdk.open('https://links.example.com/l/blocked');
  expect(sdk.attributionToken()).toBeUndefined();
  sdk.setConsent(false);
  expect(await sdk.claimReferralCode('ABCDEFGHIJKL', 'id')).toBeUndefined();
  expect(fetcher).toHaveBeenCalledTimes(3);
});
it('does not persist a claim result after consent is revoked while the request is pending', async () => {
  let complete!: (value: Response) => void;
  const storage = { getItem: () => null, setItem: vi.fn(), removeItem: vi.fn() };
  const sdk = new LinkRunway({
    endpoint: 'https://links.example.com',
    apiKey: 'lr_pk_test',
    consent: true,
    storage,
    fetch: vi.fn(
      () =>
        new Promise<Response>((resolve) => {
          complete = resolve;
        }),
    ),
  });
  const pending = sdk.claimReferralCode('ABCDEFGHIJKL', 'claim-id');
  sdk.setConsent(false);
  complete(Response.json({ clickToken: 'late-token' }));
  expect(await pending).toBeUndefined();
  expect(storage.setItem).not.toHaveBeenCalled();
});
